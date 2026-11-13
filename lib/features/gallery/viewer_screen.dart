import 'dart:io';
import 'dart:ui' as ui;

import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';

import '../../app/theme/theme.dart';
import '../../core/export/exporter.dart';
import '../../core/image_processing/look_engine.dart';
import '../../core/media/media_library.dart';
import '../../core/storage/app_state.dart';
import '../../shared/widgets/common.dart';

class ViewerArgs {
  const ViewerArgs(this.assets, this.index);
  final List<AssetEntity> assets;
  final int index;
}

const _months = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];

String formatDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';
String formatTime(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
String monthLabel(DateTime d) => '${_months[d.month - 1]} ${d.year}';

/// Full-screen, immersive viewing with pinch zoom and swipe between frames.
class ViewerScreen extends ConsumerStatefulWidget {
  const ViewerScreen(this.args, {super.key});
  final ViewerArgs args;

  @override
  ConsumerState<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends ConsumerState<ViewerScreen> {
  late final List<AssetEntity> _assets = [...widget.args.assets];
  late int _index = widget.args.index.clamp(0, _assets.length - 1);
  late final _pages = PageController(initialPage: _index);
  bool _chrome = true, _zoomed = false, _busy = false;

  AssetEntity get _cur => _assets[_index];

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pages.dispose();
    super.dispose();
  }

  void _toggleChrome() {
    setState(() => _chrome = !_chrome);
    SystemChrome.setEnabledSystemUIMode(_chrome ? SystemUiMode.edgeToEdge : SystemUiMode.immersive);
  }

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      'delete?',
      'This removes the original ${isVideo(_cur) ? 'video' : 'photograph'} from your device. It cannot be undone from eski.',
      'delete',
    );
    if (!ok) return;
    final a = _cur;
    final gone = await ref.read(libraryProvider.notifier).delete([a]);
    if (!gone.contains(a.id) || !mounted) return;
    ref.read(editsProvider.notifier).remove(a.id);
    ref.read(favoritesProvider.notifier).toggle(a.id, false);
    setState(() {
      _assets.removeAt(_index);
      if (_index >= _assets.length) _index = _assets.length - 1;
    });
    if (_assets.isEmpty) context.pop();
  }

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      await Exporter.shareAssets([_cur], ref.read(editsProvider), ref.read(settingsProvider));
    } catch (_) {
      if (mounted) toast(context, 'this item could not be shared');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_assets.isEmpty) return const Scaffold(backgroundColor: Colors.black);
    final a = _cur;
    final fav = ref.watch(favoritesProvider.select((f) => f.contains(a.id)));
    final edited = ref.watch(editsProvider.select((m) => m.containsKey(a.id)));
    final accent = ref.watch(settingsProvider.select((s) => s.accent));
    return Theme(
      data: eskiTheme(Brightness.dark, accent),
      child: Builder(builder: (context) {
        final c = context.c;
        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              PageView.builder(
                controller: _pages,
                physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
                itemCount: _assets.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) => isVideo(_assets[i])
                    ? _VideoPage(_assets[i], key: ValueKey(_assets[i].id), onTap: _toggleChrome)
                    : _PhotoPage(
                        _assets[i],
                        key: ValueKey(_assets[i].id),
                        onTap: _toggleChrome,
                        onZoom: (z) {
                          if (z != _zoomed) setState(() => _zoomed = z);
                        },
                      ),
              ),
              AnimatedOpacity(
                opacity: _chrome ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: IgnorePointer(
                  ignoring: !_chrome,
                  child: SafeArea(
                    child: Column(
                      children: [
                        Row(
                          children: [
                            IconBtn(Icons.arrow_back, color: Colors.white, onTap: () => context.pop(), tooltip: 'back'),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(formatDate(a.createDateTime), style: context.label(Colors.white, 13)),
                                  Text(
                                    '${formatTime(a.createDateTime)}${edited ? '  ·  edited' : ''}${isRaw(a) ? '  ·  raw' : ''}',
                                    style: context.num(c.dim, 10.5),
                                  ),
                                ],
                              ),
                            ),
                            Text('${_index + 1} / ${_assets.length}', style: context.num(c.dim, 11)),
                            const SizedBox(width: 16),
                          ],
                        ),
                        const Spacer(),
                        if (_busy) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('preparing…', style: context.num(c.dim))),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconBtn(
                                fav ? Icons.favorite : Icons.favorite_border,
                                color: fav ? c.accent : Colors.white,
                                tooltip: 'favorite',
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  ref.read(favoritesProvider.notifier).toggle(a.id);
                                },
                              ),
                              IconBtn(Icons.ios_share, color: Colors.white, onTap: _busy ? null : _share, tooltip: 'share'),
                              if (!isVideo(a))
                                IconBtn(Icons.tune, color: Colors.white, tooltip: 'edit', onTap: () => context.push('/editor', extra: a))
                              else
                                const SizedBox(width: 44),
                              IconBtn(Icons.info_outline, color: Colors.white, onTap: () => showInfo(context, a), tooltip: 'details'),
                              IconBtn(Icons.delete_outline, color: Colors.white, onTap: _delete, tooltip: 'delete'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

class _PhotoPage extends ConsumerStatefulWidget {
  const _PhotoPage(this.asset, {super.key, required this.onTap, required this.onZoom});
  final AssetEntity asset;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoom;

  @override
  ConsumerState<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends ConsumerState<_PhotoPage> {
  final _tc = TransformationController();
  ui.Image? _img;
  bool _original = false;
  Offset _tapPos = Offset.zero;

  @override
  void initState() {
    super.initState();
    _img = Thumbs.peek(widget.asset.id, 1800) ?? Thumbs.peek(widget.asset.id);
    Thumbs.get(widget.asset, 1800).then((i) {
      if (mounted && i != null) setState(() => _img = i);
    });
    _tc.addListener(() => widget.onZoom(_tc.value.getMaxScaleOnAxis() > 1.02));
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _img;
    if (img == null) return const SizedBox.expand();
    final edit = ref.watch(editsProvider.select((m) => m[widget.asset.id]));
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _tapPos = d.localPosition,
      onDoubleTap: () {
        if (_tc.value.getMaxScaleOnAxis() > 1.02) {
          _tc.value = Matrix4.identity();
        } else {
          const s = 2.5;
          _tc.value = Matrix4.identity()
            ..translateByDouble(-_tapPos.dx * (s - 1), -_tapPos.dy * (s - 1), 0, 1)
            ..scaleByDouble(s, s, 1, 1);
        }
      },
      onLongPressStart: edit == null ? null : (_) => setState(() => _original = true),
      onLongPressEnd: edit == null ? null : (_) => setState(() => _original = false),
      child: InteractiveViewer(
        transformationController: _tc,
        maxScale: 8,
        child: SizedBox.expand(
          child: edit == null
              ? RawImage(image: img, fit: BoxFit.contain, filterQuality: FilterQuality.medium)
              : EditedImage(image: img, edit: edit, original: _original),
        ),
      ),
    );
  }
}

class _VideoPage extends ConsumerStatefulWidget {
  const _VideoPage(this.asset, {super.key, required this.onTap});
  final AssetEntity asset;
  final VoidCallback onTap;

  @override
  ConsumerState<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends ConsumerState<_VideoPage> {
  VideoPlayerController? _vc;

  @override
  void initState() {
    super.initState();
    widget.asset.file.then((f) async {
      if (f == null || !mounted) return;
      final vc = VideoPlayerController.file(f);
      await vc.initialize();
      if (!mounted) {
        vc.dispose();
        return;
      }
      vc.setLooping(true);
      vc.addListener(() {
        if (mounted) setState(() {});
      });
      setState(() => _vc = vc);
    });
  }

  @override
  void dispose() {
    _vc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vc = _vc;
    if (vc == null) return const SizedBox.expand();
    final edit = ref.watch(editsProvider.select((m) => m[widget.asset.id]));
    final preset = LookEngine.preset(edit?.presetId);
    final ar = vc.value.aspectRatio;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: ar,
              // The look saved with the clip is applied live during playback.
              child: LookFilter(
                look: preset == null ? ResolvedLook.neutral : resolveLook(preset: preset, intensity: edit!.intensity),
                frameAspect: ar,
                animateGrain: vc.value.isPlaying,
                child: VideoPlayer(vc),
              ),
            ),
          ),
          GestureDetector(
            onTap: () => vc.value.isPlaying ? vc.pause() : vc.play(),
            child: AnimatedOpacity(
              opacity: vc.value.isPlaying ? 0 : 1,
              duration: const Duration(milliseconds: 160),
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 1.5)),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 30),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Details sheet: file facts and EXIF.
void showInfo(BuildContext context, AssetEntity a) {
  showEskiSheet<void>(
    context,
    (ctx) => FutureBuilder<List<(String, String)>>(
      future: _readInfo(a),
      builder: (ctx, snap) {
        final rows = snap.data ?? const <(String, String)>[];
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
            children: [
              Text('details', style: ctx.display(28)),
              const SizedBox(height: 12),
              if (!snap.hasData) Text('reading…', style: ctx.num(ctx.c.dim)),
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 110, child: Text(r.$1, style: ctx.label(ctx.c.dim, 12))),
                      Expanded(child: Text(r.$2, style: ctx.num(ctx.c.text, 12.5))),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}

Future<List<(String, String)>> _readInfo(AssetEntity a) async {
  final out = <(String, String)>[];
  final file = await a.originFile;
  final title = a.title ?? (file == null ? null : file.uri.pathSegments.last);
  if (title != null && title.isNotEmpty) out.add(('file', title));
  out.add(('taken', '${formatDate(a.createDateTime)}, ${formatTime(a.createDateTime)}'));
  out.add(('dimensions', '${a.orientatedWidth} × ${a.orientatedHeight}  (${(a.width * a.height / 1e6).toStringAsFixed(1)} MP)'));
  if (isVideo(a)) out.add(('duration', '${a.duration}s'));
  if (file != null) {
    final bytes = await file.length();
    out.add(('size', '${(bytes / 1048576).toStringAsFixed(1)} MB'));
    if (!isVideo(a)) {
      try {
        final tags = await readExifFromFile(File(file.path));
        String? t(String k) {
          final v = tags[k]?.printable.trim();
          return v == null || v.isEmpty ? null : v;
        }

        double? ratio(String k) {
          final v = tags[k]?.values.toList();
          if (v == null || v.isEmpty) return null;
          final x = v.first;
          return x is Ratio ? (x.denominator == 0 ? null : x.numerator / x.denominator) : (x is num ? x.toDouble() : null);
        }

        final make = t('Image Make'), model = t('Image Model');
        if (model != null) out.add(('camera', make != null && !model.startsWith(make) ? '$make $model' : model));
        final lens = t('EXIF LensModel');
        if (lens != null) out.add(('lens', lens));
        final f = ratio('EXIF FNumber'), fl = ratio('EXIF FocalLength'), iso = t('EXIF ISOSpeedRatings');
        final exp = t('EXIF ExposureTime');
        final parts = [
          if (exp != null) '${exp}s',
          if (f != null) 'f/${f.toStringAsFixed(1)}',
          if (iso != null) 'ISO $iso',
          if (fl != null) '${fl.toStringAsFixed(fl < 10 ? 1 : 0)}mm',
        ];
        if (parts.isNotEmpty) out.add(('exposure', parts.join('   ')));
        final bias = ratio('EXIF ExposureBiasValue');
        if (bias != null && bias != 0) out.add(('compensation', '${bias > 0 ? '+' : ''}${bias.toStringAsFixed(1)} EV'));
        final wb = t('EXIF WhiteBalance'), flash = t('EXIF Flash');
        if (wb != null) out.add(('white balance', wb.toLowerCase()));
        if (flash != null) out.add(('flash', flash.toLowerCase()));
        final sw = t('Image Software');
        if (sw != null) out.add(('software', sw));
        if (tags.containsKey('GPS GPSLatitude')) out.add(('location', 'recorded in file'));
      } catch (_) {}
    }
  }
  return out;
}
