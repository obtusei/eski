import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../app/theme/theme.dart';
import '../../core/export/exporter.dart';
import '../../core/image_processing/adjustments.dart';
import '../../core/image_processing/look_engine.dart';
import '../../core/image_processing/renderer.dart';
import '../../core/media/media_library.dart';
import '../../core/storage/app_state.dart';
import '../../shared/widgets/common.dart';
import '../gallery/photo_picker.dart';
import '../gallery/viewer_screen.dart';
import '../presets/preset_strip.dart';
import 'studio_model.dart';

const _swatches = [paper, cream, 0xFFFFFFFF, ink, 0xFF050505, 0xFFB8452C, 0xFFE8A13A, 0xFF38463A, 0xFF2B3A55];

/// The studio tab: pick a format and a template.
class StudioScreen extends ConsumerStatefulWidget {
  const StudioScreen({super.key});

  @override
  ConsumerState<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends ConsumerState<StudioScreen> {
  final _pages = PageController();
  int _format = 0;
  (int, int)? _custom;

  /// The custom page comes after the preset formats.
  bool get _onCustom => _format == studioFormats.length;

  (int, int)? _sizeOf(int page) =>
      page < studioFormats.length ? (studioFormats[page].$2, studioFormats[page].$3) : _custom;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _goTo(int page) {
    HapticFeedback.selectionClick();
    _pages.animateToPage(page, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  Future<void> _pickCustom() async {
    final v = await promptText(context, 'custom size', initial: '1080x1440', action: 'use');
    final m = v == null ? null : RegExp(r'^(\d{3,4})\s*[x×*]\s*(\d{3,4})$').firstMatch(v.trim().toLowerCase());
    if (m == null) {
      if (v != null && mounted) toast(context, 'use a size like 1080x1440');
      return;
    }
    setState(() => _custom = (int.parse(m[1]!), int.parse(m[2]!)));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final c = context.c;
    final size = _sizeOf(_format);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(s.pad, 14, s.pad, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('studio', style: context.display(40)),
                  const SizedBox(height: 4),
                  Text(
                    'layouts for stories, posts and covers${size == null ? '' : '  ·  ${size.$1} × ${size.$2}'}',
                    style: context.num(c.dim),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: s.pad - 11),
                children: [
                  for (final (i, f) in studioFormats.indexed) TextTab(f.$1, active: i == _format, onTap: () => _goTo(i)),
                  TextTab('custom', active: _onCustom, onTap: () {
                    _goTo(studioFormats.length);
                    if (_custom == null) _pickCustom();
                  }),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pages,
                itemCount: studioFormats.length + 1,
                onPageChanged: (i) => setState(() => _format = i),
                itemBuilder: (context, i) => _page(context, s, i),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Templates laid out for one format; swiping moves between formats.
  Widget _page(BuildContext context, Settings s, int page) {
    final saved = ref.watch(savedTemplatesProvider);
    final c = context.c;
    final size = _sizeOf(page);
    if (size == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('any size', style: context.display(30).copyWith(fontStyle: FontStyle.italic)),
            const SizedBox(height: 8),
            Text('Set your own canvas in pixels.', style: context.body(c.dim)),
            const SizedBox(height: 12),
            TextTab('set a size', active: true, onTap: _pickCustom),
          ],
        ),
      );
    }
    final (w, h) = size;
    final wide = MediaQuery.sizeOf(context).width > 700;
    Widget tile(Comp comp, {VoidCallback? onLongPress}) => GestureDetector(
          onTap: () => context.push('/studio/edit', extra: comp.clone()),
          onLongPress: onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: comp.w / comp.h,
                    child: DecoratedBox(
                      decoration: BoxDecoration(border: Border.all(color: c.line)),
                      child: CustomPaint(painter: _PreviewPainter(comp)),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(comp.name, style: context.label(c.dim, 12)),
            ],
          ),
        );
    SliverGrid grid(List<Widget> children) => SliverGrid.count(
          crossAxisCount: wide ? 4 : 2,
          mainAxisSpacing: 22,
          crossAxisSpacing: 18,
          childAspectRatio: 0.68,
          children: children,
        );
    return CustomScrollView(
      key: PageStorageKey('studio-$page'),
      slivers: [
        if (page == studioFormats.length)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(s.pad - 11, 4, s.pad, 0),
              child: Align(alignment: Alignment.centerLeft, child: TextTab('change size', active: false, dot: false, onTap: _pickCustom)),
            ),
          ),
        if (saved.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(s.pad, 14, s.pad, 12),
              child: Text('your templates', style: context.display(22).copyWith(fontStyle: FontStyle.italic)),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: s.pad),
            sliver: grid([
              for (final t in saved)
                tile(t, onLongPress: () async {
                  if (await confirm(context, 'remove template?', '“${t.name}” will be removed from your templates.', 'remove')) {
                    ref.read(savedTemplatesProvider.notifier).remove(t);
                  }
                }),
            ]),
          ),
        ],
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(s.pad, 18, s.pad, 12),
            child: Text('templates', style: context.display(22).copyWith(fontStyle: FontStyle.italic)),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: s.pad),
          sliver: grid([for (final t in studioTemplates) tile(t.$2(w, h))]),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.comp);
  final Comp comp;

  @override
  void paint(Canvas canvas, Size size) {
    final dark = Color(comp.bg).computeLuminance() < 0.3;
    CompPainter().paint(
      canvas,
      size,
      comp,
      image: (_) => null,
      editOf: (_) => null,
      placeholder: dark ? const Color(0x33FFFFFF) : const Color(0x22000000),
    );
  }

  @override
  bool shouldRepaint(_PreviewPainter o) => o.comp != comp;
}

/// The composition editor.
class StudioEditor extends ConsumerStatefulWidget {
  const StudioEditor(this.comp, {super.key});
  final Comp comp;

  @override
  ConsumerState<StudioEditor> createState() => _StudioEditorState();
}

class _StudioEditorState extends ConsumerState<StudioEditor> {
  late final Comp _c = widget.comp;
  final _painter = CompPainter();
  final _images = <String, ui.Image>{};
  final _assets = <String, AssetEntity>{};
  int? _photo, _text;
  String _panel = '';
  bool _busy = false;
  int _tick = 0;

  // Gesture start values.
  double _s0 = 1, _r0 = 0;

  @override
  void dispose() {
    _painter.dispose();
    super.dispose();
  }

  void _changed() => setState(() => _tick++);

  Future<void> _pickPhoto(int index) async {
    final a = await showEskiSheet<AssetEntity>(context, (_) => const PhotoPicker());
    if (a == null) return;
    final first = _c.photos.every((p) => p.assetId == null);
    final p = _c.photos[index]
      ..assetId = a.id
      ..offset = Offset.zero
      ..scale = 1
      ..rotation = 0;
    _assets[a.id] = a;
    if (first) {
      for (final t in _c.texts.where((t) => t.auto == 'date')) {
        t.text = formatDate(a.createDateTime);
      }
    }
    _photo = index;
    _text = null;
    _changed();
    final img = await Thumbs.get(a, 1800);
    if (img != null && mounted && p.assetId == a.id) {
      _images[a.id] = img;
      _changed();
    }
  }

  Future<void> _editText(TextLayer t) async {
    final v = await promptText(context, 'text', initial: t.text, action: 'done');
    if (v == null) return;
    t
      ..text = v
      ..auto = null;
    _changed();
  }

  void _tap(Offset p, Size size) {
    for (var i = _c.texts.length - 1; i >= 0; i--) {
      if (textRect(_c.texts[i], size).contains(p)) {
        if (_text == i) {
          _editText(_c.texts[i]);
        } else {
          setState(() {
            _text = i;
            _photo = null;
            _panel = '';
          });
        }
        return;
      }
    }
    final n = Offset(p.dx / size.width, p.dy / size.height);
    for (var i = _c.photos.length - 1; i >= 0; i--) {
      if (_c.photos[i].frame.contains(n)) {
        if (_c.photos[i].assetId == null) {
          _pickPhoto(i);
        } else {
          setState(() {
            _photo = i;
            _text = null;
            _panel = '';
          });
        }
        return;
      }
    }
    setState(() {
      _photo = null;
      _text = null;
    });
  }

  Future<ui.Image> _render() async {
    final edits = ref.read(editsProvider);
    final full = <String, ui.Image>{}, overs = <String, ui.Image>{};
    final painter = CompPainter();
    try {
      for (final p in _c.photos) {
        final id = p.assetId;
        final a = id == null ? null : _assets[id];
        if (id == null || a == null || full.containsKey(id)) continue;
        full[id] = await loadAssetImage(a, maxEdge: 3000);
        final over = await loadOverlayImage(edits[id]?.dx, maxEdge: 3000);
        if (over != null) overs[id] = over;
        final e = p.presetId != null ? EditState(presetId: p.presetId) : (edits[id] ?? const EditState());
        await LookEngine.ensureLut(resolveLook(preset: LookEngine.preset(e.presetId), intensity: e.intensity, curves: e.curves));
      }
      final rec = ui.PictureRecorder();
      painter.paint(
        Canvas(rec),
        _c.size,
        _c,
        image: (id) => full[id],
        editOf: (id) => edits[id],
        overlayOf: (id) => overs[id],
        placeholder: const Color(0x00000000),
      );
      final pic = rec.endRecording();
      var img = await pic.toImage(_c.w, _c.h);
      pic.dispose();
      if (!_c.overlay.isNeutral) {
        final filmed = await renderEdit(img, EditState(adj: _c.overlay));
        img.dispose();
        img = filmed;
      }
      return img;
    } finally {
      painter.dispose();
      for (final i in [...full.values, ...overs.values]) {
        i.dispose();
      }
    }
  }

  Future<void> _export(bool share) async {
    setState(() => _busy = true);
    try {
      final img = await _render();
      final file = await Exporter.encode(img, ref.read(settingsProvider), name: 'eski_studio_${Exporter.stamp()}');
      img.dispose();
      if (share) {
        await Exporter.shareFiles([file]);
      } else {
        await Exporter.saveImage(file);
        file.delete().ignore();
        if (mounted) toast(context, 'saved to your library');
      }
    } catch (_) {
      if (mounted) toast(context, 'the export did not finish');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final edits = ref.watch(editsProvider);
    final overlay = _c.overlay;
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Row(
                  children: [
                    IconBtn(Icons.close, onTap: () => context.pop(), tooltip: 'close'),
                    Expanded(child: Text('${_c.name}  ·  ${_c.w} × ${_c.h}', style: context.num(c.dim))),
                    TextTab('save template', active: false, dot: false, onTap: () async {
                      final name = await promptText(context, 'template name', initial: _c.name);
                      if (name == null || name.isEmpty || !context.mounted) return;
                      _c.name = name;
                      ref.read(savedTemplatesProvider.notifier).add(_c);
                      toast(context, 'template saved');
                    }),
                    TextTab('export', active: true, dot: false, onTap: () {
                      showEskiSheet<void>(
                        context,
                        (ctx) => Consumer(builder: (ctx, ref, _) {
                          final fmt = ref.watch(settingsProvider.select((x) => x.exportFormat));
                          return Column(mainAxisSize: MainAxisSize.min, children: [
                            const SizedBox(height: 12),
                            Row2('save to the library', onTap: () {
                              Navigator.pop(ctx);
                              _export(false);
                            }),
                            Row2('share', onTap: () {
                              Navigator.pop(ctx);
                              _export(true);
                            }),
                            Row2('format', value: fmt, onTap: () => ref.read(settingsProvider.notifier).set('exportFormat', fmt == 'jpeg' ? 'png' : 'jpeg')),
                            const SizedBox(height: 14),
                          ]);
                        }),
                      );
                    }),
                  ],
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: LayoutBuilder(builder: (context, box) {
                      final size = applyBoxFit(BoxFit.contain, _c.size, box.biggest).destination;
                      return Center(
                        child: GestureDetector(
                          onTapUp: (d) => _tap(d.localPosition, size),
                          onScaleStart: (_) {
                            final p = _photo == null ? null : _c.photos[_photo!];
                            final t = _text == null ? null : _c.texts[_text!];
                            _s0 = p?.scale ?? t?.size ?? 1;
                            _r0 = p?.rotation ?? t?.rotation ?? 0;
                          },
                          onScaleUpdate: (d) {
                            if (_text != null) {
                              final t = _c.texts[_text!];
                              t.pos = Offset(
                                (t.pos.dx + d.focalPointDelta.dx / size.width).clamp(0.0, 1.0),
                                (t.pos.dy + d.focalPointDelta.dy / size.height).clamp(0.0, 1.0),
                              );
                              if (d.pointerCount > 1) {
                                t.size = (_s0 * d.scale).clamp(0.012, 0.6);
                                t.rotation = _r0 + d.rotation;
                              }
                              _changed();
                            } else if (_photo != null) {
                              final p = _c.photos[_photo!];
                              final fw = p.frame.width * size.width, fh = p.frame.height * size.height;
                              p.offset = Offset(
                                (p.offset.dx + d.focalPointDelta.dx / fw * 2 / p.scale).clamp(-1.0, 1.0),
                                (p.offset.dy + d.focalPointDelta.dy / fh * 2 / p.scale).clamp(-1.0, 1.0),
                              );
                              if (d.pointerCount > 1) {
                                p.scale = (_s0 * d.scale).clamp(1.0, 6.0);
                                p.rotation = _r0 + d.rotation;
                              }
                              _changed();
                            }
                          },
                          child: SizedBox.fromSize(
                            size: size,
                            child: LookFilter(
                              look: overlay.isNeutral ? ResolvedLook.neutral : resolveLook(adj: overlay),
                              frameAspect: _c.w / _c.h,
                              child: CustomPaint(
                                painter: _CanvasPainter(_c, _painter, _images, edits, _tick, _photo, _text, c.accent),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 160),
                  alignment: Alignment.bottomCenter,
                  child: _panelFor(context),
                ),
              ],
            ),
            if (_busy)
              Positioned.fill(
                child: ColoredBox(
                  color: c.bg.withValues(alpha: 0.82),
                  child: Center(child: Text('developing…', style: context.display(30).copyWith(fontStyle: FontStyle.italic))),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _swatchRow(int current, ValueChanged<int> onPick) => SizedBox(
        height: 46,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final s in _swatches)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onPick(s),
                child: Padding(
                  padding: const EdgeInsets.all(7),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Color(s),
                      shape: BoxShape.circle,
                      border: Border.all(color: s == current ? context.c.accent : context.c.line, width: s == current ? 2 : 1),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _slider(String label, double value, ValueChanged<double> set, {double max = 1}) => Row(
        children: [
          SizedBox(width: 74, child: Padding(padding: const EdgeInsets.only(left: 20), child: Text(label, style: context.label(context.c.dim, 11)))),
          Expanded(child: Ruler(value: value, min: 0, max: max, height: 34, onChanged: set)),
          const SizedBox(width: 14),
        ],
      );

  Widget _panelFor(BuildContext context) {
    Widget tabs(List<Widget> children) => SizedBox(
          height: 42,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: children),
        );
    void toggle(String p) => setState(() => _panel = _panel == p ? '' : p);

    if (_text != null) {
      final t = _c.texts[_text!];
      return Column(mainAxisSize: MainAxisSize.min, children: [
        if (_panel == 'color') _swatchRow(t.color, (v) {
          t.color = v;
          _changed();
        }),
        if (_panel == 'size') ...[
          _slider('size', t.size, (v) {
            t.size = v.clamp(0.012, 0.6);
            _changed();
          }, max: 0.4),
          _slider('spacing', t.spacing, (v) {
            t.spacing = v;
            _changed();
          }, max: 6),
        ],
        tabs([
          TextTab('edit', active: false, dot: false, onTap: () => _editText(t)),
          for (final f in const ['serif', 'italic', 'sans', 'mono'])
            TextTab(f, active: t.font == f, onTap: () {
              t.font = f;
              _changed();
            }),
          TextTab('size', active: _panel == 'size', dot: false, onTap: () => toggle('size')),
          TextTab('color', active: _panel == 'color', dot: false, onTap: () => toggle('color')),
          TextTab('delete', active: false, dot: false, onTap: () {
            _c.texts.removeAt(_text!);
            _text = null;
            _changed();
          }),
        ]),
      ]);
    }
    if (_photo != null) {
      final p = _c.photos[_photo!];
      return Column(mainAxisSize: MainAxisSize.min, children: [
        if (_panel == 'look')
          PresetStrip(
            selected: p.presetId,
            thumb: p.assetId == null ? null : Thumbs.peek(p.assetId!),
            onSelect: (id) {
              p.presetId = id;
              _changed();
            },
          ),
        tabs([
          TextTab('replace', active: false, dot: false, onTap: () => _pickPhoto(_photo!)),
          TextTab('look', active: _panel == 'look', dot: false, onTap: () => toggle('look')),
          TextTab('reset position', active: false, dot: false, onTap: () {
            p
              ..offset = Offset.zero
              ..scale = 1
              ..rotation = 0;
            _changed();
          }),
          TextTab('remove photo', active: false, dot: false, onTap: () {
            p.assetId = null;
            _photo = null;
            _changed();
          }),
        ]),
      ]);
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (_panel == 'bg') _swatchRow(_c.bg, (v) {
        _c.bg = v;
        _changed();
      }),
      if (_panel == 'film') ...[
        _slider('grain', _c.grain, (v) {
          _c.grain = v;
          _changed();
        }),
        _slider('light leak', _c.leak, (v) {
          _c.leak = v;
          _changed();
        }),
        _slider('dust', _c.dust, (v) {
          _c.dust = v;
          _changed();
        }),
      ],
      tabs([
        TextTab('+ text', active: false, dot: false, onTap: () {
          final dark = Color(_c.bg).computeLuminance() < 0.3;
          _c.texts.add(TextLayer('your words', const Offset(0.5, 0.5), size: 0.07, color: dark ? paper : ink, font: 'italic'));
          _text = _c.texts.length - 1;
          _changed();
        }),
        TextTab('+ date', active: false, dot: false, onTap: () {
          final dark = Color(_c.bg).computeLuminance() < 0.3;
          final id = _c.photos.map((p) => p.assetId).nonNulls.firstOrNull;
          final d = _assets[id]?.createDateTime ?? DateTime.now();
          _c.texts.add(TextLayer('${formatDate(d)}  ·  ${formatTime(d)}', const Offset(0.5, 0.9), size: 0.026, color: dark ? paper : ink, font: 'mono', spacing: 2));
          _text = _c.texts.length - 1;
          _changed();
        }),
        TextTab('background', active: _panel == 'bg', dot: false, onTap: () => toggle('bg')),
        TextTab('film overlay', active: _panel == 'film', dot: false, onTap: () => toggle('film')),
      ]),
    ]);
  }
}

class _CanvasPainter extends CustomPainter {
  _CanvasPainter(this.comp, this.painter, this.images, this.edits, this.tick, this.photo, this.text, this.accent)
      : super(repaint: Listenable.merge([LookEngine.lutReady, Overlays.ready, Mattes.ready]));
  final Comp comp;
  final CompPainter painter;
  final Map<String, ui.Image> images;
  final Map<String, EditState> edits;
  final int tick;
  final int? photo, text;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final dark = Color(comp.bg).computeLuminance() < 0.3;
    painter.paint(
      canvas,
      size,
      comp,
      image: (id) => images[id],
      editOf: (id) => edits[id],
      placeholder: dark ? const Color(0x33FFFFFF) : const Color(0x22000000),
      guides: true,
    );
    final line = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    if (photo != null && photo! < comp.photos.length) {
      final f = comp.photos[photo!].frame;
      canvas.drawRect(Rect.fromLTRB(f.left * size.width, f.top * size.height, f.right * size.width, f.bottom * size.height), line);
    }
    if (text != null && text! < comp.texts.length) canvas.drawRect(textRect(comp.texts[text!], size), line);
  }

  @override
  bool shouldRepaint(_CanvasPainter o) => o.tick != tick || o.photo != photo || o.text != text || o.edits != edits;
}
