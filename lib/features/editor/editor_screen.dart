import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../app/theme/theme.dart';
import '../../core/export/exporter.dart';
import '../../core/image_processing/adjustments.dart';
import '../../core/image_processing/renderer.dart';
import '../../core/storage/app_state.dart';
import '../../shared/widgets/common.dart';
import '../gallery/photo_picker.dart';
import '../presets/preset_strip.dart';
import 'editor_controller.dart';
import 'panels.dart';

enum Tool { looks, light, color, detail, effects, grade, crop, mask, portrait, multi }

String _toolLabel(Tool t) => t == Tool.multi ? 'double' : t.name;

IconData _toolIcon(Tool t) => switch (t) {
      Tool.looks => Icons.filter_vintage_outlined,
      Tool.light => Icons.wb_sunny_outlined,
      Tool.color => Icons.palette_outlined,
      Tool.detail => Icons.center_focus_strong_outlined,
      Tool.effects => Icons.auto_awesome_outlined,
      Tool.grade => Icons.tune,
      Tool.crop => Icons.crop,
      Tool.mask => Icons.brush_outlined,
      Tool.portrait => Icons.portrait_outlined,
      Tool.multi => Icons.layers_outlined,
    };

const _full = Rect.fromLTRB(0, 0, 1, 1);
const _effects = [
  Adj.grain, Adj.grainSize, Adj.noise, Adj.vignette, Adj.bloom, Adj.glow, Adj.halation, Adj.blur, Adj.motion, //
  Adj.motionAngle, Adj.smudge, Adj.chroma, Adj.leak, Adj.leakSeed, Adj.dust, Adj.borderStyle, Adj.borderSize,
];

class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen(this.asset, {super.key});
  final AssetEntity asset;

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  Tool _tool = Tool.looks;
  int _colorTab = 0, _mask = -1, _cropParam = 0;
  double _cropAspect = 0;
  Object _maskParam = 'feather';
  bool _original = false, _working = false;

  // Double exposure: selected parameter, whether gestures edit the mask, and
  // the layer as it was when a gesture began.
  String _dxParam = 'opacity';
  bool _dxMaskEdit = false;
  DoubleExposure? _dx0;
  String _pbParam = 'aperture';

  EditorController get _ctl => ref.read(editorProvider.notifier);
  EditState get _edit => ref.read(editorProvider).edit;
  void _live(EditState Function(EditState) f) => _ctl.update(f(_edit));
  void _apply(EditState Function(EditState) f) => _ctl.apply(f(_edit));

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _ctl.load(widget.asset));
  }

  Future<void> _run(String done, Future<void> Function() job) async {
    setState(() => _working = true);
    try {
      await job();
      if (mounted && done.isNotEmpty) toast(context, done);
    } catch (e) {
      if (mounted) toast(context, 'That did not work — the original is untouched');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(editorProvider);
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Row(
                  children: [
                    IconBtn(Icons.close, onTap: () => Navigator.of(context).maybePop(), tooltip: 'close'),
                    const Spacer(),
                    IconBtn(Icons.undo, onTap: st.canUndo ? _ctl.undo : null, tooltip: 'undo'),
                    IconBtn(Icons.redo, onTap: st.canRedo ? _ctl.redo : null, tooltip: 'redo'),
                    const Spacer(),
                    IconBtn(Icons.more_horiz, onTap: () => _more(context), tooltip: 'more'),
                    TextTab('export', active: true, dot: false, onTap: () => _export(context)),
                  ],
                ),
                Expanded(child: _canvas(context, st)),
                AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  alignment: Alignment.bottomCenter,
                  child: _panel(context, st),
                ),
                _toolBar(),
              ],
            ),
            if (_working)
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

  Widget _toolBar() {
    final s = ref.watch(settingsProvider);
    final chips = s.toolStyle == 1;
    void pick(Tool t) {
      HapticFeedback.selectionClick();
      setState(() => _tool = t);
    }

    return SizedBox(
      height: chips ? 54 : 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: chips ? 12 : 8),
        children: [
          for (final t in Tool.values)
            chips
                ? ToolChip(_toolLabel(t), active: t == _tool, icon: s.toolIcons ? _toolIcon(t) : null, onTap: () => pick(t))
                : TextTab(_toolLabel(t), active: t == _tool, onTap: () => pick(t)),
        ],
      ),
    );
  }

  // ── Canvas ────────────────────────────────────────────────────────────

  Widget _canvas(BuildContext context, EditorState st) {
    final img = st.image ?? st.thumb;
    if (st.error != null) return Center(child: Text(st.error!, style: context.body(context.c.dim)));
    if (img == null) return const SizedBox.expand();
    final e = st.edit;
    final shown = switch (_tool) {
      Tool.crop => e.copyWith(geo: e.geo.copyWith(crop: _full)),
      Tool.mask || Tool.multi || Tool.portrait => e.copyWith(geo: const Geometry()),
      _ => e,
    };
    final frame = frameSize(Size(img.width.toDouble(), img.height.toDouble()), shown.geo);
    return LayoutBuilder(builder: (context, box) {
      final avail = Size(box.maxWidth - 24, box.maxHeight - 16);
      final dest = applyBoxFit(BoxFit.contain, frame, avail).destination;
      final rect = Alignment.center.inscribe(dest, Offset.zero & box.biggest);
      final picture = EditedImage(image: img, edit: shown, original: _original, fit: BoxFit.fill, overlay: st.overlay);
      if (_tool == Tool.crop) {
        final na = _normAspect(frame);
        return Stack(children: [
          Positioned.fromRect(rect: rect, child: picture),
          Positioned.fromRect(
            rect: rect,
            child: CropOverlay(
              rect: e.geo.crop,
              aspect: na,
              onChanged: (r) => _live((s) => s.copyWith(geo: s.geo.copyWith(crop: r))),
              onEnd: _ctl.commit,
            ),
          ),
        ]);
      }
      if (_tool == Tool.mask) {
        final has = _mask >= 0 && _mask < e.masks.length;
        return Stack(children: [
          Positioned.fromRect(rect: rect, child: picture),
          if (has)
            Positioned.fromRect(
              rect: rect,
              child: MaskOverlay(
                mask: e.masks[_mask],
                onChanged: (m) => _live((s) => s.copyWith(masks: [...s.masks]..[_mask] = m)),
                onEnd: _ctl.commit,
              ),
            ),
        ]);
      }
      if (_tool == Tool.portrait) {
        final pb = e.portrait;
        return Stack(children: [
          Positioned.fromRect(rect: rect, child: picture),
          if (pb != null && pb.matte == null)
            Positioned.fromRect(
              rect: rect,
              child: MaskOverlay(
                mask: pb.area,
                onChanged: (m) => _setPb((x) => x.copyWith(center: m.a, radius: m.radius)),
                onEnd: _ctl.commit,
              ),
            ),
        ]);
      }
      if (_tool == Tool.multi) {
        final d = e.dx;
        return Stack(children: [
          Positioned.fromRect(rect: rect, child: picture),
          if (d != null && _dxMaskEdit && d.mask != null)
            Positioned.fromRect(
              rect: rect,
              child: MaskOverlay(
                mask: d.mask!,
                onChanged: (m) => _setDx((x) => x.copyWith(mask: m)),
                onEnd: _ctl.commit,
              ),
            )
          else if (d != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (_) => _dx0 = _edit.dx,
                onScaleUpdate: (g) {
                  final d0 = _dx0;
                  if (d0 == null) return;
                  _setDx((x) => x.copyWith(
                        offset: x.offset + Offset(g.focalPointDelta.dx / rect.width, g.focalPointDelta.dy / rect.height),
                        scale: (d0.scale * g.scale).clamp(0.25, 3.0),
                        rotation: d0.rotation + g.rotation,
                      ));
                },
                onScaleEnd: (_) => _ctl.commit(),
              ),
            ),
        ]);
      }
      return GestureDetector(
        onLongPressStart: (_) {
          HapticFeedback.selectionClick();
          setState(() => _original = true);
        },
        onLongPressEnd: (_) => setState(() => _original = false),
        child: InteractiveViewer(
          maxScale: 8,
          child: SizedBox.expand(
            child: Stack(children: [
              Positioned.fromRect(rect: rect, child: picture),
              if (_original)
                Positioned(
                  left: rect.left + 10,
                  top: rect.top + 10,
                  child: Text('original', style: context.num(Colors.white, 11)),
                ),
            ]),
          ),
        ),
      );
    });
  }

  /// Locked crop ratio in normalised frame units, or null when free.
  double? _normAspect(Size frame) {
    if (_cropAspect == 0) return null;
    final a = _cropAspect < 0 ? frame.width / frame.height : _cropAspect;
    return a * frame.height / frame.width;
  }

  // ── Panels ────────────────────────────────────────────────────────────

  Widget _panel(BuildContext context, EditorState st) {
    final e = st.edit;
    final c = context.c;
    Widget adj(List<Adj> list) => AdjPanel(
          key: ValueKey(list.first),
          adjs: list,
          values: e.adj,
          onChanged: (a, v) => _live((s) => s.copyWith(adj: s.adj.set(a, v))),
          onEnd: _ctl.commit,
        );
    switch (_tool) {
      case Tool.looks:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (e.presetId != null)
              Row(
                children: [
                  const SizedBox(width: 20),
                  Text('intensity', style: context.label(c.dim, 11)),
                  Expanded(
                    child: Ruler(
                      value: e.intensity,
                      min: 0,
                      max: 1,
                      neutral: 1,
                      height: 38,
                      onChanged: (v) => _live((s) => s.copyWith(intensity: v)),
                      onEnd: _ctl.commit,
                    ),
                  ),
                  SizedBox(width: 44, child: Text('${(e.intensity * 100).round()}', style: context.num(c.dim))),
                ],
              ),
            PresetStrip(
              selected: e.presetId,
              thumb: st.thumb,
              onCreate: _saveLook,
              onSelect: (id) => _apply((s) => id == null ? s.copyWith(clearPreset: true) : s.copyWith(presetId: id, intensity: 1)),
            ),
          ],
        );
      case Tool.light:
        return adj(lightAdjs);
      case Tool.detail:
        return adj(detailAdjs);
      case Tool.effects:
        return adj(_effects);
      case Tool.color:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            switch (_colorTab) {
              1 => CurveEditor(
                  curves: e.curves,
                  onChanged: (cv) => _live((s) => s.copyWith(curves: cv)),
                  onEnd: _ctl.commit,
                ),
              2 => HslPanel(
                  values: e.adj,
                  onChanged: (i, v) => _live((s) => s.copyWith(adj: s.adj.setHsl(i, v))),
                  onEnd: _ctl.commit,
                ),
              _ => adj(colorAdjs),
            },
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final (i, n) in const ['white balance', 'curves', 'hsl'].indexed)
                  TextTab(n, active: _colorTab == i, dot: false, onTap: () => setState(() => _colorTab = i)),
              ],
            ),
          ],
        );
      case Tool.grade:
        return GradePanel(
          values: e.adj,
          onChanged: (m) => _live((s) {
            var a = s.adj;
            m.forEach((k, v) => a = a.set(k, v));
            return s.copyWith(adj: a);
          }),
          onEnd: _ctl.commit,
        );
      case Tool.crop:
        return _cropPanel(context, e);
      case Tool.mask:
        return _maskPanel(context, e);
      case Tool.multi:
        return _multiPanel(context, e);
      case Tool.portrait:
        return _portraitPanel(context, e);
    }
  }

  Widget _cropPanel(BuildContext context, EditState e) {
    final g = e.geo;
    final value = [g.straighten / (math.pi / 4), g.perspY, g.perspX][_cropParam];
    void setAspect(double a) {
      setState(() => _cropAspect = a);
      final img = ref.read(editorProvider).image ?? ref.read(editorProvider).thumb;
      if (img == null) return;
      final frame = frameSize(Size(img.width.toDouble(), img.height.toDouble()), g.copyWith(crop: _full));
      final na = _normAspect(frame);
      if (na == null) return;
      final w = na >= 1 ? 1.0 : na, h = na >= 1 ? 1 / na : 1.0;
      _apply((s) => s.copyWith(geo: s.geo.copyWith(crop: Rect.fromCenter(center: const Offset(0.5, 0.5), width: w, height: h))));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Ruler(
          value: value,
          onChanged: (v) => _live((s) => s.copyWith(
                geo: switch (_cropParam) {
                  0 => s.geo.copyWith(straighten: v * math.pi / 4),
                  1 => s.geo.copyWith(perspY: v),
                  _ => s.geo.copyWith(perspX: v),
                },
              )),
          onEnd: _ctl.commit,
        ),
        SizedBox(
          height: 44,
          child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            for (final (i, n) in const ['straighten', 'vertical', 'horizontal'].indexed)
              TextTab(n, active: _cropParam == i, dot: false, onTap: () => setState(() => _cropParam = i)),
            IconBtn(Icons.rotate_90_degrees_cw_outlined, size: 20, tooltip: 'rotate', onTap: () {
              setState(() => _cropAspect = 0);
              _apply((s) => s.copyWith(geo: s.geo.copyWith(quarterTurns: s.geo.quarterTurns + 1, crop: _full)));
            }),
            IconBtn(Icons.flip, size: 20, tooltip: 'flip', onTap: () => _apply((s) => s.copyWith(geo: s.geo.copyWith(flipH: !s.geo.flipH)))),
            TextTab('reset', active: false, dot: false, onTap: () {
              setState(() => _cropAspect = 0);
              _apply((s) => s.copyWith(geo: const Geometry()));
            }),
          ],
        )),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final a in cropAspects) TextTab(a.$1, active: _cropAspect == a.$2, dot: false, onTap: () => setAspect(a.$2)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _maskPanel(BuildContext context, EditState e) {
    final c = context.c;
    final has = _mask >= 0 && _mask < e.masks.length;
    final m = has ? e.masks[_mask] : null;
    void setMask(MaskLayer Function(MaskLayer) f, {bool commit = false}) {
      _live((s) => s.copyWith(masks: [...s.masks]..[_mask] = f(s.masks[_mask])));
      if (commit) _ctl.commit();
    }

    void add(MaskType t) {
      final count = e.masks.length;
      _apply((s) => s.copyWith(masks: [
            ...s.masks,
            MaskLayer(type: t, a: t == MaskType.radial ? const Offset(0.5, 0.5) : const Offset(0.5, 0.25), adj: const Adjustments({Adj.exposure: 0.25})),
          ]));
      setState(() {
        _mask = count;
        _maskParam = Adj.exposure;
      });
    }

    final params = <Object>['feather', if (m != null && m.type != MaskType.linear) 'size', ...maskAdjs];
    if (!params.contains(_maskParam)) _maskParam = params.first;
    final p = _maskParam;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (m != null) ...[
          Ruler(
            value: p is Adj ? m.adj[p] : (p == 'feather' ? m.feather : (m.radius / 0.8).clamp(0.0, 1.0)),
            min: p is Adj ? p.min : 0,
            max: 1,
            onChanged: (v) => setMask((x) => p is Adj
                ? x.copyWith(adj: x.adj.set(p, v))
                : (p == 'feather' ? x.copyWith(feather: v) : x.copyWith(radius: math.max(0.02, v * 0.8)))),
            onEnd: _ctl.commit,
          ),
          SizedBox(
            height: 58,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                for (final q in params)
                  ParamChip(
                    label: q is Adj ? q.label : q as String,
                    value: q is Adj
                        ? (m.adj[q] == 0 ? '0' : '${m.adj[q] > 0 ? '+' : ''}${(m.adj[q] * 100).round()}')
                        : '${((q == 'feather' ? m.feather : m.radius / 0.8) * 100).round()}',
                    active: q == p,
                    onTap: () => setState(() => _maskParam = q),
                  ),
              ],
            ),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 14, 28, 6),
            child: Text(
              'Local adjustments. Add a gradient, a radial area or paint with a brush, then tune only that part of the photograph.',
              textAlign: TextAlign.center,
              style: context.body(c.dim).copyWith(fontSize: 13),
            ),
          ),
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (var i = 0; i < e.masks.length; i++)
                TextTab('${e.masks[i].type.name} ${i + 1}', active: i == _mask, onTap: () => setState(() => _mask = i == _mask ? -1 : i)),
              for (final t in MaskType.values) TextTab('+ ${t.name}', active: false, dot: false, onTap: () => add(t)),
              if (m != null) ...[
                TextTab(m.invert ? 'inverted' : 'invert', active: m.invert, dot: false, onTap: () => setMask((x) => x.copyWith(invert: !x.invert), commit: true)),
                if (m.type == MaskType.brush)
                  TextTab('clear', active: false, dot: false, onTap: () => setMask((x) => x.copyWith(strokes: const []), commit: true)),
                TextTab('delete', active: false, dot: false, onTap: () {
                  final i = _mask;
                  setState(() => _mask = -1);
                  _apply((s) => s.copyWith(masks: [...s.masks]..removeAt(i)));
                }),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ── Portrait ──────────────────────────────────────────────────────────

  void _setPb(PortraitBlur Function(PortraitBlur) f, {bool commit = false}) {
    _live((s) => s.portrait == null ? s : s.copyWith(portrait: f(s.portrait!)));
    if (commit) _ctl.commit();
  }

  /// Finds the person on-device and keeps the sharp area to them.
  Future<void> _detectSubject() => _run('', () async {
        final f = await widget.asset.originFile;
        final matte = f == null ? null : await Exporter.detectSubject(f.path);
        if (!mounted) return;
        _apply((s) => s.copyWith(portrait: (s.portrait ?? const PortraitBlur()).copyWith(matte: matte)));
        if (matte == null) toast(context, 'no person found — place the focus area on your subject');
      });

  Widget _portraitPanel(BuildContext context, EditState e) {
    final c = context.c;
    final pb = e.portrait;
    if (pb == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
            child: Text(
              'Portrait blur. eski finds the person on this device and opens the aperture behind them. Without a person, place a focus area instead.',
              textAlign: TextAlign.center,
              style: context.body(c.dim).copyWith(fontSize: 13),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextTab('find the subject', active: true, dot: false, onTap: _detectSubject),
              TextTab('focus area', active: false, dot: false, onTap: () => _apply((s) => s.copyWith(portrait: const PortraitBlur()))),
            ],
          ),
          const SizedBox(height: 6),
        ],
      );
    }
    final params = ['aperture', 'feather', if (pb.matte == null) 'area'];
    if (!params.contains(_pbParam)) _pbParam = 'aperture';
    final p = _pbParam;
    String chip(String q) => switch (q) {
          'aperture' => 'f/${pb.fNumber.toStringAsFixed(1)}',
          'feather' => '${(pb.feather * 100).round()}',
          _ => '${(pb.radius * 100).round()}',
        };
    final value = switch (p) {
      'aperture' => pb.amount,
      'feather' => pb.feather,
      _ => ((pb.radius - 0.05) / 0.75).clamp(0.0, 1.0),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Ruler(
          value: value,
          min: 0,
          max: 1,
          neutral: p == 'aperture' ? 0.6 : 0.5,
          onChanged: (v) => _setPb((x) => switch (p) {
                'aperture' => x.copyWith(amount: v),
                'feather' => x.copyWith(feather: v),
                _ => x.copyWith(radius: 0.05 + v * 0.75),
              }),
          onEnd: _ctl.commit,
        ),
        SizedBox(
          height: 58,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              for (final q in params) ParamChip(label: q, value: chip(q), active: q == p, onTap: () => setState(() => _pbParam = q)),
            ],
          ),
        ),
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              TextTab('subject', active: pb.matte != null, onTap: pb.matte != null ? null : _detectSubject),
              TextTab('focus area', active: pb.matte == null, onTap: () => _setPb((x) => x.copyWith(matte: null), commit: true)),
              if (pb.matte != null) TextTab('find again', active: false, dot: false, onTap: _detectSubject),
              TextTab('remove', active: false, dot: false, onTap: () => _apply((s) => s.copyWith(portrait: null))),
            ],
          ),
        ),
      ],
    );
  }

  // ── Double exposure ───────────────────────────────────────────────────

  void _setDx(DoubleExposure Function(DoubleExposure) f, {bool commit = false}) {
    _live((s) => s.dx == null ? s : s.copyWith(dx: f(s.dx!)));
    if (commit) _ctl.commit();
  }

  Future<void> _pickSecond() async {
    final a = await showEskiSheet<AssetEntity>(
      context,
      (_) => PhotoPicker(title: 'second exposure', exclude: widget.asset.id),
    );
    if (a == null || !mounted) return;
    _apply((s) => s.copyWith(dx: s.dx?.copyWith(assetId: a.id) ?? DoubleExposure(assetId: a.id)));
    setState(() => _dxMaskEdit = false);
  }

  static const _minScale = 0.25, _maxScale = 3.0;

  Widget _multiPanel(BuildContext context, EditState e) {
    final c = context.c;
    final d = e.dx;
    if (d == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
            child: Text(
              'Double exposure. Expose a second photograph onto this one, then blend, place and mask it as on film.',
              textAlign: TextAlign.center,
              style: context.body(c.dim).copyWith(fontSize: 13),
            ),
          ),
          TextTab('choose the second exposure', active: true, dot: false, onTap: _pickSecond),
          const SizedBox(height: 6),
        ],
      );
    }
    final m = d.mask;
    final params = [
      'blend', 'opacity', 'tone key', 'scale', 'rotate', //
      if (m != null) 'feather',
      if (m != null && m.type != MaskType.linear) 'size',
    ];
    if (!params.contains(_dxParam)) _dxParam = 'opacity';
    final p = _dxParam;
    final logScale = math.log(_maxScale / _minScale);
    double scaleT(double v) => math.log(v / _minScale) / logScale;

    String chip(String q) => switch (q) {
          'blend' => d.blend.label,
          'opacity' => '${(d.opacity * 100).round()}',
          'tone key' => d.tone == 0 ? '0' : '${d.tone > 0 ? 'hi ' : 'lo '}${(d.tone.abs() * 100).round()}',
          'scale' => d.scale == 1 ? '0' : '${d.scale > 1 ? '+' : ''}${((d.scale - 1) * 100).round()}',
          'rotate' => d.rotation == 0 ? '0' : '${(d.rotation * 180 / math.pi).round()}°',
          'feather' => '${(m!.feather * 100).round()}',
          _ => '${(m!.radius / 0.8 * 100).round()}',
        };

    final (value, min, neutral) = switch (p) {
      'opacity' => (d.opacity, 0.0, 0.8),
      'tone key' => (d.tone, -1.0, 0.0),
      'scale' => (scaleT(d.scale).clamp(0.0, 1.0), 0.0, scaleT(1)),
      'rotate' => ((d.rotation / math.pi).clamp(-1.0, 1.0), -1.0, 0.0),
      'feather' => (m!.feather, 0.0, 0.0),
      _ => ((m?.radius ?? 0) / 0.8, 0.0, 0.0),
    };
    void set(double v) => _setDx((x) => switch (p) {
          'opacity' => x.copyWith(opacity: v),
          'tone key' => x.copyWith(tone: v),
          'scale' => x.copyWith(scale: _minScale * math.exp(v * logScale)),
          'rotate' => x.copyWith(rotation: v * math.pi),
          'feather' => x.copyWith(mask: x.mask?.copyWith(feather: v)),
          _ => x.copyWith(mask: x.mask?.copyWith(radius: math.max(0.02, v * 0.8))),
        });

    void setMask(MaskType? t) {
      _setDx(
        (x) => x.copyWith(
          mask: t == null
              ? null
              : x.mask?.type == t
                  ? x.mask
                  : MaskLayer(
                      type: t,
                      a: t == MaskType.radial ? const Offset(0.5, 0.5) : const Offset(0.5, 0.3),
                      b: const Offset(0.5, 0.75),
                      radius: t == MaskType.brush ? 0.12 : 0.35,
                      feather: 0.6,
                    ),
        ),
        commit: true,
      );
      setState(() => _dxMaskEdit = t != null);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (p == 'blend')
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final b in ExposureBlend.values)
                  TextTab(b.label, active: d.blend == b, onTap: () => _setDx((x) => x.copyWith(blend: b), commit: true)),
              ],
            ),
          )
        else
          Ruler(value: value, min: min, max: 1, neutral: neutral, onChanged: set, onEnd: _ctl.commit),
        SizedBox(
          height: 58,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              for (final q in params) ParamChip(label: q, value: chip(q), active: q == p, onTap: () => setState(() => _dxParam = q)),
            ],
          ),
        ),
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              TextTab('move', active: !_dxMaskEdit || m == null, onTap: () => setState(() => _dxMaskEdit = false)),
              TextTab('no mask', active: m == null, onTap: () => setMask(null)),
              for (final t in MaskType.values)
                TextTab(t.name, active: m?.type == t && _dxMaskEdit, onTap: () => setMask(t)),
              if (m != null) ...[
                TextTab(m.invert ? 'inverted' : 'invert', active: m.invert, dot: false, onTap: () => _setDx((x) => x.copyWith(mask: m.copyWith(invert: !m.invert)), commit: true)),
                if (m.type == MaskType.brush)
                  TextTab('clear', active: false, dot: false, onTap: () => _setDx((x) => x.copyWith(mask: m.copyWith(strokes: const [])), commit: true)),
              ],
              TextTab('flip', active: d.flipH, dot: false, onTap: () => _setDx((x) => x.copyWith(flipH: !x.flipH), commit: true)),
              TextTab('reset place', active: false, dot: false, onTap: () => _setDx((x) => x.copyWith(offset: Offset.zero, scale: 1, rotation: 0), commit: true)),
              TextTab('replace', active: false, dot: false, onTap: _pickSecond),
              TextTab('remove', active: false, dot: false, onTap: () {
                setState(() => _dxMaskEdit = false);
                _apply((s) => s.copyWith(dx: null));
              }),
            ],
          ),
        ),
      ],
    );
  }

  /// Turns the current look and adjustments into a reusable preset, then
  /// switches the photograph over to it.
  Future<void> _saveLook() async {
    final e = _edit;
    if (e.adj.isNeutral && e.curves.isIdentity && (e.presetId == null || e.intensity == 1)) {
      toast(context, 'adjust the photograph first, then save it as a look');
      return;
    }
    final name = await promptText(context, 'name this look');
    if (name == null || name.isEmpty || !mounted) return;
    final p = ref.read(userPresetsProvider.notifier).add(name, e);
    _apply((s) => EditState(presetId: p.id, geo: s.geo, masks: s.masks, dx: s.dx, portrait: s.portrait));
    toast(context, 'saved to my looks');
  }

  // ── Sheets ────────────────────────────────────────────────────────────

  void _export(BuildContext context) {
    final s = ref.read(settingsProvider);
    showEskiSheet<void>(
      context,
      (ctx) => Consumer(builder: (ctx, ref, _) {
        final fmt = ref.watch(settingsProvider.select((x) => x.exportFormat));
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 18),
            Text('export', style: ctx.display(28)),
            const SizedBox(height: 6),
            Text('A new file is written. Your original stays as it is.', style: ctx.body(ctx.c.dim).copyWith(fontSize: 13)),
            const SizedBox(height: 10),
            Row2('save a copy to the library', onTap: () {
              Navigator.pop(ctx);
              _run('saved to your library', () async {
                final f = await Exporter.render(widget.asset, _edit, ref.read(settingsProvider));
                final a = await Exporter.saveImage(f);
                ref.read(exportsProvider.notifier).toggle(a.id, true);
                f.delete().ignore();
              });
            }),
            Row2('share', onTap: () {
              Navigator.pop(ctx);
              _run('', () async => Exporter.shareFiles([await Exporter.render(widget.asset, _edit, ref.read(settingsProvider))]));
            }),
            Row2('format', value: fmt, onTap: () => ref.read(settingsProvider.notifier).set('exportFormat', fmt == 'jpeg' ? 'png' : 'jpeg')),
            Row2('long edge limit', value: '${s.maxEdge} px'),
            const SizedBox(height: 14),
          ],
        );
      }),
    );
  }

  void _more(BuildContext context) {
    final clip = ref.read(clipboardProvider);
    showEskiSheet<void>(
      context,
      (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Row2('copy edits', onTap: () {
            ref.read(clipboardProvider.notifier).copy(_edit);
            Navigator.pop(ctx);
            toast(context, 'edits copied');
          }),
          if (clip != null)
            Row2('paste edits', onTap: () {
              Navigator.pop(ctx);
              _apply((s) => s.copyWith(
                    presetId: clip.presetId,
                    clearPreset: clip.presetId == null,
                    intensity: clip.intensity,
                    adj: clip.adj,
                    curves: clip.curves,
                  ));
            }),
          Row2('save as a new look', onTap: () {
            Navigator.pop(ctx);
            _saveLook();
          }),
          Row2('reset all edits', onTap: () {
            Navigator.pop(ctx);
            _ctl.apply(const EditState());
          }),
          Row2('revert to original', danger: true, onTap: () async {
            Navigator.pop(ctx);
            if (await confirm(context, 'revert?', 'This clears every edit and the edit history for this photograph.', 'revert')) {
              _ctl.revert();
            }
          }),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}
