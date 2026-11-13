import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../app/theme/theme.dart';
import '../../core/export/exporter.dart';
import '../../core/media/media_library.dart';
import '../../core/storage/app_state.dart';
import '../../shared/widgets/common.dart';
import 'asset_thumb.dart';
import 'viewer_screen.dart';

const _filters = ['all', 'favorites', 'edited', 'raw', 'videos', 'exports'];

class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  final _search = TextEditingController();
  late PageController _pages = PageController();
  String _filter = 'all', _query = '';
  bool _searching = false, _busy = false;

  /// One scroll position per page, so swiping keeps each page where it was.
  final _scrolls = <String, ScrollController>{};

  /// Album being browsed: an eski [Album] or a device [AssetPathEntity].
  Object? _album;

  /// Assets resolved by id or album for views not backed by the paged list,
  /// per slot as (key, assets).
  final _slots = <String, (String, List<AssetEntity>)>{};
  final _inFlight = <String>{};
  static const _albumPage = 120;
  int _albumLimit = _albumPage;
  final _selected = <String>{};
  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(libraryProvider.notifier).init());
  }

  @override
  void dispose() {
    for (final c in _scrolls.values) {
      c.dispose();
    }
    _pages.dispose();
    _search.dispose();
    super.dispose();
  }

  String get _pageKey => _album != null ? 'album' : _filter;

  ScrollController _scrollFor(String key) => _scrolls[key] ??= () {
        final c = ScrollController();
        if (const ['all', 'raw', 'videos'].contains(key)) {
          c.addListener(() {
            if (c.position.extentAfter < 900) ref.read(libraryProvider.notifier).loadMore();
          });
        }
        return c;
      }();

  void _goTo(int page) {
    HapticFeedback.selectionClick();
    _pages.animateToPage(page, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  /// Favourites, edits, exports and albums are id sets that may reach beyond
  /// the pages loaded so far, so they are resolved directly. Returns null
  /// until the first result for [slot] arrives; with [keep] the previous
  /// result stands in while a newer [key] loads.
  List<AssetEntity>? _resolve(String slot, String key, Future<List<AssetEntity>> Function() load, {bool keep = true}) {
    final cur = _slots[slot];
    if (cur != null && cur.$1 == key) return cur.$2;
    if (_inFlight.add(key)) {
      load().then((list) {
        list.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
        if (mounted) setState(() => _slots[slot] = (key, list));
      }).catchError((_) {}).whenComplete(() => _inFlight.remove(key));
    }
    return keep ? cur?.$2 : null;
  }

  Future<List<AssetEntity>> _byIds(Iterable<String> ids) async {
    final loaded = {for (final a in ref.read(libraryProvider).assets) a.id: a};
    final out = <AssetEntity>[];
    for (final id in ids) {
      final a = loaded[id] ?? await AssetEntity.fromId(id);
      if (a != null) out.add(a);
    }
    return out;
  }

  /// What a page shows, and whether it has finished resolving.
  (List<AssetEntity>, bool) _visible(LibraryState lib, String filter) {
    final exports = ref.watch(exportsProvider);
    List<AssetEntity>? got;
    var paged = false;
    List<AssetEntity> base;
    final album = _album;
    bool same(String prefix) => _slots['album']?.$1.startsWith(prefix) ?? false;
    if (album is Album) {
      final live = ref.watch(albumsProvider).where((a) => a.id == album.id).firstOrNull;
      final ids = live?.items ?? const <String>{};
      got = _resolve('album', 'album:${album.id}:${ids.length}', () => _byIds(ids), keep: same('album:${album.id}:'));
      base = got ?? const [];
    } else if (album is AssetPathEntity) {
      // Device albums load a page at a time as the list is scrolled.
      got = _resolve('album', 'path:${album.id}:$_albumLimit', () => album.getAssetListRange(start: 0, end: _albumLimit),
          keep: same('path:${album.id}:'));
      base = got ?? const [];
    } else {
      paged = const ['all', 'raw', 'videos'].contains(filter);
      switch (filter) {
        case 'favorites':
          final ids = ref.watch(favoritesProvider);
          got = _resolve('fav', 'fav:${ids.length}', () => _byIds(ids));
          base = got ?? const [];
        case 'edited':
          final ids = ref.watch(editsProvider.select((m) => m.keys.toSet()));
          got = _resolve('edit', 'edit:${ids.length}', () => _byIds(ids));
          base = got ?? const [];
        case 'exports':
          got = _resolve('exp', 'exp:${exports.length}', () => _byIds(exports));
          base = got ?? const [];
        case 'raw':
          base = [for (final a in lib.assets) if (isRaw(a)) a];
        case 'videos':
          base = [for (final a in lib.assets) if (isVideo(a)) a];
        default:
          base = [for (final a in lib.assets) if (!exports.contains(a.id)) a];
      }
    }
    final ready = paged || got != null;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return (base, ready);
    return (
      [
        for (final a in base)
          if ((a.title ?? '').toLowerCase().contains(q) ||
              monthLabel(a.createDateTime).contains(q) ||
              formatDate(a.createDateTime).contains(q))
            a,
      ],
      ready,
    );
  }

  // ── Selection ─────────────────────────────────────────────────────────

  void _toggle(String id) {
    HapticFeedback.selectionClick();
    setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));
  }

  /// While a long-press drag is under way, select every tile the finger crosses.
  void _dragSelect(Offset global) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, global, View.of(context).viewId);
    for (final e in result.path) {
      final t = e.target;
      if (t is RenderMetaData && t.metaData is String) {
        final id = t.metaData as String;
        if (_selected.add(id)) {
          HapticFeedback.selectionClick();
          setState(() {});
        }
        break;
      }
    }
    final h = MediaQuery.sizeOf(context).height;
    final sc = _scrollFor(_pageKey);
    if (sc.hasClients) {
      if (global.dy > h - 150) sc.jumpTo(math.min(sc.offset + 14, sc.position.maxScrollExtent));
      if (global.dy < 130) sc.jumpTo(math.max(sc.offset - 14, 0));
    }
  }

  Future<void> _batch(String done, Future<void> Function(List<AssetEntity>) job, List<AssetEntity> all) async {
    final items = [for (final a in all) if (_selected.contains(a.id)) a];
    if (items.isEmpty) return;
    setState(() => _busy = true);
    try {
      await job(items);
      if (mounted && done.isNotEmpty) toast(context, done);
    } catch (_) {
      if (mounted) toast(context, 'that did not finish — nothing was changed');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _selected.clear();
        });
      }
    }
  }

  Future<void> _deleteSelected(List<AssetEntity> all) async {
    final n = _selected.length;
    final ok = await confirm(
      context,
      'delete $n?',
      'This removes the original ${n == 1 ? 'item' : 'items'} from your device. It cannot be undone from eski.',
      'delete',
    );
    if (!ok) return;
    await _batch('', (items) async {
      final gone = await ref.read(libraryProvider.notifier).delete(items);
      for (final id in gone) {
        ref.read(editsProvider.notifier).remove(id);
        ref.read(favoritesProvider.notifier).toggle(id, false);
      }
      _slots.clear();
    }, all);
  }

  void _addToAlbum(List<AssetEntity> all) {
    final ids = _selected.toList();
    showEskiSheet<void>(
      context,
      (ctx) => Consumer(builder: (ctx, ref, _) {
        final albums = ref.watch(albumsProvider);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 18),
            Text('add to album', style: ctx.display(28)),
            const SizedBox(height: 8),
            for (final a in albums)
              Row2(a.name, value: '${a.items.length}', onTap: () {
                ref.read(albumsProvider.notifier).addTo(a.id, ids);
                Navigator.pop(ctx);
                setState(_selected.clear);
              }),
            Row2('new album…', onTap: () async {
              Navigator.pop(ctx);
              final name = await promptText(context, 'new album', action: 'create');
              if (name == null || name.isEmpty) return;
              await ref.read(albumsProvider.notifier).create(name, ids);
              if (mounted) setState(_selected.clear);
            }),
            const SizedBox(height: 14),
          ],
        );
      }),
    );
  }

  void _albums() {
    showEskiSheet<void>(
      context,
      (ctx) => Consumer(builder: (ctx, ref, _) {
        final mine = ref.watch(albumsProvider);
        final device = ref.watch(deviceAlbumsProvider).value ?? const [];
        void pick(Object? a) {
          Navigator.pop(ctx);
          setState(() {
            if (a == null && _album != null) _leaveAlbum();
            _album = a;
            _albumLimit = _albumPage;
            _slots.remove('album');
            final old = _scrolls.remove('album');
            if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
          });
        }

        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(padding: const EdgeInsets.fromLTRB(22, 20, 22, 8), child: Text('albums', style: ctx.display(28))),
              Row2('everything', onTap: () => pick(null)),
              for (final a in mine)
                GestureDetector(
                  onLongPress: () async {
                    if (await confirm(ctx, 'remove album?', 'The album “${a.name}” is removed. Its photographs stay in your library.', 'remove')) {
                      ref.read(albumsProvider.notifier).delete(a.id);
                    }
                  },
                  child: Row2(a.name, value: '${a.items.length}', onTap: () => pick(a)),
                ),
              Row2('new album…', onTap: () async {
                final name = await promptText(ctx, 'new album', action: 'create');
                if (name != null && name.isNotEmpty) ref.read(albumsProvider.notifier).create(name);
              }),
              if (device.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 6),
                  child: Text('on this device', style: ctx.label(ctx.c.dim, 11.5)),
                ),
              for (final p in device) Row2(p.name.isEmpty ? 'untitled' : p.name.toLowerCase(), onTap: () => pick(p)),
              const SizedBox(height: 16),
            ],
          ),
        );
      }),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────

  /// Back to the filter pages, on the page that was open before.
  void _leaveAlbum() {
    _pages.dispose();
    _pages = PageController(initialPage: _filters.indexOf(_filter));
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final s = ref.watch(settingsProvider);
    final c = context.c;
    final album = _album;
    final current = lib.granted == true ? _visible(lib, _filter).$1 : const <AssetEntity>[];
    final title = album is Album ? album.name : (album is AssetPathEntity ? album.name.toLowerCase() : 'library');

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(s.pad, 14, 6, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: _searching
                            ? TextField(
                                controller: _search,
                                autofocus: true,
                                style: context.display(30),
                                cursorColor: c.accent,
                                decoration: InputDecoration(
                                  border: InputBorder.none,
                                  hintText: 'name or month',
                                  hintStyle: context.display(30).copyWith(color: c.faint),
                                  isDense: true,
                                ),
                                onChanged: (v) => setState(() => _query = v),
                              )
                            : Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.display(40)),
                      ),
                      IconBtn(_searching ? Icons.close : Icons.search, tooltip: 'search', onTap: () {
                        setState(() {
                          _searching = !_searching;
                          if (!_searching) {
                            _query = '';
                            _search.clear();
                          }
                        });
                      }),
                      IconBtn(
                        s.galleryLayout == 0 ? Icons.grid_view : Icons.view_quilt_outlined,
                        tooltip: 'layout',
                        onTap: () => ref.read(settingsProvider.notifier).set('galleryLayout', 1 - s.galleryLayout),
                      ),
                      IconBtn(Icons.folder_open, tooltip: 'albums', onTap: _albums),
                    ],
                  ),
                ),
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.symmetric(horizontal: s.pad - 11),
                    children: album != null
                        ? [
                            TextTab('← everything', active: false, dot: false, onTap: () => setState(() {
                                  _leaveAlbum();
                                  _album = null;
                                })),
                          ]
                        : [
                            for (final (i, f) in _filters.indexed) TextTab(f, active: f == _filter, onTap: () => _goTo(i)),
                          ],
                  ),
                ),
                Expanded(
                  child: album != null
                      ? _page(context, lib, s, null)
                      : PageView.builder(
                          controller: _pages,
                          itemCount: _filters.length,
                          onPageChanged: (i) => setState(() {
                            _filter = _filters[i];
                            _selected.clear();
                          }),
                          itemBuilder: (context, i) => _page(context, lib, s, _filters[i]),
                        ),
                ),
              ],
            ),
            if (_selecting)
              Positioned(left: 0, right: 0, bottom: 0, child: _selectionBar(context, album != null ? _visible(lib, '').$1 : current)),
          ],
        ),
      ),
    );
  }

  /// One swipeable page of the library; [filter] is null inside an album.
  Widget _page(BuildContext context, LibraryState lib, Settings s, String? filter) {
    final key = filter ?? 'album';
    final (assets, ready) = lib.granted == true ? _visible(lib, filter ?? '') : (const <AssetEntity>[], true);
    final album = _album;
    final paged = filter != null && const ['all', 'raw', 'videos'].contains(filter);
    final albumCount = _slots['album']?.$2.length ?? 0;
    return CustomScrollView(
      key: PageStorageKey('library-$key-${album is Album ? album.id : album is AssetPathEntity ? album.id : ''}'),
      controller: _scrollFor(key),
      slivers: [
        if (lib.granted == false)
          _message('the library is closed', 'eski needs access to your photographs to show them here. Nothing ever leaves your device.',
              action: 'open settings', onAction: PhotoManager.openSetting)
        else if (assets.isEmpty && !lib.loading && ready)
          _message(
            _query.isNotEmpty ? 'nothing matches' : 'nothing here yet',
            filter == 'all' ? 'Photographs you take will appear here.' : 'This view is empty for now.',
          )
        else
          ..._sections(context, assets, s),
        SliverToBoxAdapter(
          child: album is AssetPathEntity
              ? LoadMore(
                  active: albumCount >= _albumLimit,
                  onLoad: () {
                    if (albumCount >= _albumLimit) setState(() => _albumLimit += _albumPage);
                  },
                )
              : LoadMore(
                  active: lib.granted == true && album == null && paged && lib.hasMore,
                  onLoad: ref.read(libraryProvider.notifier).loadMore,
                ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 70)),
      ],
    );
  }

  Widget _message(String title, String body, {String? action, VoidCallback? onAction}) => SliverFillRemaining(
        hasScrollBody: false,
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(title, style: context.display(30).copyWith(fontStyle: FontStyle.italic)),
              const SizedBox(height: 10),
              Text(body, textAlign: TextAlign.center, style: context.body(context.c.dim)),
              if (action != null) ...[const SizedBox(height: 16), TextTab(action, active: true, onTap: onAction)],
            ],
          ),
        ),
      );

  List<Widget> _sections(BuildContext context, List<AssetEntity> assets, Settings s) {
    final out = <Widget>[];
    final width = MediaQuery.sizeOf(context).width;
    final columns = width > 700 ? s.columns + 3 : s.columns;
    var start = 0;
    while (start < assets.length) {
      final d = assets[start].createDateTime;
      var end = start + 1;
      while (end < assets.length &&
          assets[end].createDateTime.year == d.year &&
          assets[end].createDateTime.month == d.month) {
        end++;
      }
      final from = start, count = end - start;
      out.add(SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(s.pad, 22, s.pad, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(monthLabel(d), style: context.display(22).copyWith(fontStyle: FontStyle.italic)),
              const Spacer(),
              Text('$count', style: context.num(context.c.faint)),
            ],
          ),
        ),
      ));
      if (s.galleryLayout == 0) {
        out.add(SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: s.gap,
            crossAxisSpacing: s.gap,
          ),
          delegate: SliverChildBuilderDelegate((context, i) => _tile(assets, from + i), childCount: count),
        ));
      } else {
        // Mosaic: rows justified to the full width, keeping each frame's shape.
        final target = width / (columns - 0.4);
        final rows = <List<int>>[];
        var row = <int>[];
        var sum = 0.0;
        for (var i = from; i < end; i++) {
          row.add(i);
          sum += _aspect(assets[i]);
          if (sum * target >= width) {
            rows.add(row);
            row = [];
            sum = 0;
          }
        }
        if (row.isNotEmpty) rows.add(row);
        out.add(SliverList(
          delegate: SliverChildBuilderDelegate((context, r) {
            final items = rows[r];
            final total = items.fold<double>(0, (a, i) => a + _aspect(assets[i]));
            final h = math.min((width - s.gap * (items.length - 1)) / total, target * 1.5);
            return Padding(
              padding: EdgeInsets.only(bottom: s.gap),
              child: SizedBox(
                height: h,
                child: Row(
                  children: [
                    for (final (k, i) in items.indexed) ...[
                      if (k > 0) SizedBox(width: s.gap),
                      SizedBox(width: h * _aspect(assets[i]), child: _tile(assets, i)),
                    ],
                  ],
                ),
              ),
            );
          }, childCount: rows.length),
        ));
      }
      start = end;
    }
    return out;
  }

  double _aspect(AssetEntity a) {
    final w = a.orientatedWidth, h = a.orientatedHeight;
    return w <= 0 || h <= 0 ? 1 : (w / h).clamp(0.5, 2.2);
  }

  Widget _tile(List<AssetEntity> assets, int index) {
    final a = assets[index];
    final c = context.c;
    final sel = _selected.contains(a.id);
    final fav = ref.watch(favoritesProvider.select((f) => f.contains(a.id)));
    final edited = ref.watch(editsProvider.select((m) => m.containsKey(a.id)));
    return MetaData(
      metaData: a.id,
      behavior: HitTestBehavior.opaque,
      child: GestureDetector(
        onTap: () => _selecting ? _toggle(a.id) : context.push('/viewer', extra: ViewerArgs(assets, index)),
        onLongPressStart: (_) {
          if (!_selected.contains(a.id)) _toggle(a.id);
        },
        onLongPressMoveUpdate: (d) => _dragSelect(d.globalPosition),
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedPadding(
              duration: const Duration(milliseconds: 120),
              padding: EdgeInsets.all(sel ? 7 : 0),
              child: AssetThumb(a, key: ValueKey(a.id)),
            ),
            if (isVideo(a))
              Positioned(
                right: 6,
                bottom: 5,
                child: Text(
                  '${a.duration ~/ 60}:${(a.duration % 60).toString().padLeft(2, '0')}',
                  style: context.num(Colors.white, 10.5).copyWith(shadows: const [Shadow(blurRadius: 4)]),
                ),
              ),
            if (isRaw(a))
              Positioned(
                left: 6,
                top: 5,
                child: Text('RAW', style: context.num(Colors.white, 9.5).copyWith(shadows: const [Shadow(blurRadius: 4)])),
              ),
            // A single accent dot marks an edited original.
            if (edited)
              Positioned(
                left: 6,
                bottom: 6,
                child: Container(width: 5, height: 5, decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle)),
              ),
            if (fav)
              const Positioned(
                right: 5,
                top: 5,
                child: Icon(Icons.favorite, size: 11, color: Colors.white, shadows: [Shadow(blurRadius: 4)]),
              ),
            if (sel)
              Positioned(
                right: 2,
                bottom: 2,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                  child: Icon(Icons.check, size: 12, color: c.onAccent),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _selectionBar(BuildContext context, List<AssetEntity> assets) {
    final c = context.c;
    final album = _album;
    return Container(
      color: c.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconBtn(Icons.close, onTap: () => setState(_selected.clear), tooltip: 'clear selection'),
          Text(_busy ? 'working…' : '${_selected.length} selected', style: context.num(c.text, 12.5)),
          const Spacer(),
          IconBtn(Icons.favorite_border, tooltip: 'favorite', onTap: _busy ? null : () {
            final favs = ref.read(favoritesProvider.notifier);
            for (final id in _selected) {
              favs.toggle(id, true);
            }
            setState(_selected.clear);
          }),
          IconBtn(Icons.ios_share, tooltip: 'share', onTap: _busy ? null : () => _batch('', (items) =>
              Exporter.shareAssets(items, ref.read(editsProvider), ref.read(settingsProvider)), assets)),
          IconBtn(Icons.download_outlined, tooltip: 'export copies', onTap: _busy ? null : () => _batch('copies saved to your library', (items) async {
            final edits = ref.read(editsProvider);
            for (final a in items) {
              final e = edits[a.id];
              if (e == null || isVideo(a)) continue;
              final f = await Exporter.render(a, e, ref.read(settingsProvider));
              final copy = await Exporter.saveImage(f);
              ref.read(exportsProvider.notifier).toggle(copy.id, true);
              f.delete().ignore();
            }
          }, assets)),
          if (album is Album)
            IconBtn(Icons.folder_off_outlined, tooltip: 'remove from album', onTap: _busy ? null : () {
              ref.read(albumsProvider.notifier).removeFrom(album.id, _selected.toList());
              setState(_selected.clear);
            })
          else
            IconBtn(Icons.create_new_folder_outlined, tooltip: 'add to album', onTap: _busy ? null : () => _addToAlbum(assets)),
          IconBtn(Icons.delete_outline, tooltip: 'delete', onTap: _busy ? null : () => _deleteSelected(assets)),
        ],
      ),
    );
  }
}
