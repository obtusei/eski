import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/theme.dart';
import '../../core/camera/native_camera.dart';
import '../../core/image_processing/adjustments.dart';
import '../../core/image_processing/look_engine.dart';
import '../../core/image_processing/renderer.dart';
import '../../core/media/media_library.dart';
import '../../core/storage/app_state.dart';
import '../../shared/widgets/common.dart';
import '../editor/panels.dart';
import '../gallery/asset_thumb.dart';
import '../gallery/viewer_screen.dart';
import '../presets/preset_strip.dart';
import 'camera_controller.dart';
import 'camera_widgets.dart';

double _log(double t, double a, double b) => a * math.pow(b / a, t);
double _unlog(double v, double a, double b) => (math.log(v / a) / math.log(b / a)).clamp(0.0, 1.0);

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> with WidgetsBindingObserver {
  String? _dial;
  double _zoomStart = 1;
  Offset _swipe = Offset.zero;
  bool _pinching = false, _covered = false, _resumed = true;
  String? _lookLabel;
  Timer? _labelTimer;

  CameraController get _ctl => ref.read(cameraProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _labelTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _resumed = false;
    if (state == AppLifecycleState.resumed) _resumed = true;
    _sync();
  }

  /// The sensor runs only while the viewfinder is actually on screen.
  void _sync() {
    final on = ref.read(tabProvider) == 0 && _resumed && !_covered;
    on ? _ctl.activate() : _ctl.deactivate();
  }

  Future<void> _openLast(CamState cam) async {
    final assets = ref.read(libraryProvider).assets;
    final last = cam.last ?? assets.firstOrNull;
    if (last == null) return;
    final i = assets.indexWhere((a) => a.id == last.id);
    _covered = true;
    _sync();
    await context.push('/viewer', extra: ViewerArgs(i < 0 ? [last] : assets, math.max(0, i)));
    _covered = false;
    _sync();
  }

  void _stepPreset(int delta) {
    final list = <String?>[null, ...orderedPresets(ref).map((p) => p.id)];
    final i = list.indexOf(ref.read(cameraProvider).presetId);
    final id = list[(i + delta) % list.length];
    HapticFeedback.selectionClick();
    _ctl.setPreset(id);
    _flash(LookEngine.preset(id)?.name.toLowerCase() ?? 'none');
  }

  /// Shows a word over the viewfinder for a moment.
  void _flash(String label) {
    _labelTimer?.cancel();
    setState(() => _lookLabel = label);
    _labelTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _lookLabel = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    ref.listen(tabProvider, (_, _) => _sync());
    ref.listen(cameraProvider.select((c) => c.error), (_, e) {
      if (e != null) {
        toast(context, e);
        _ctl.clearError();
      }
    });
    return Theme(
      data: eskiTheme(Brightness.dark, s.accent),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Builder(builder: (context) {
          final cam = ref.watch(cameraProvider);
          return Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              bottom: false,
              child: cam.permission == false
                  ? _denied(context)
                  : Column(
                      children: [
                        Expanded(child: _viewfinder(context, cam, s)),
                        _tray(context, cam),
                        PresetStrip(selected: cam.presetId, onSelect: _ctl.setPreset),
                        _modeRow(context, cam),
                        _shutterRow(context, cam),
                      ],
                    ),
            ),
          );
        }),
      ),
    );
  }

  Widget _denied(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('the camera is off', style: context.display(30)),
              const SizedBox(height: 12),
              Text(
                'eski needs camera access to take photographs. Allow it in system settings, then try again.',
                textAlign: TextAlign.center,
                style: context.body(context.c.dim),
              ),
              const SizedBox(height: 20),
              TextTab('try again', active: true, onTap: _ctl.activate),
            ],
          ),
        ),
      );

  // ── Viewfinder ────────────────────────────────────────────────────────

  Widget _viewfinder(BuildContext context, CamState cam, Settings s) {
    final p = cam.preview;
    if (p == null) {
      return const Center(child: SplashMark(dark: true));
    }
    final video = cam.mode == CamMode.video;
    final front = cam.camera?.front ?? false;
    final w = p.width.toDouble(), h = p.height.toDouble();
    final crop = video ? const Rect.fromLTRB(0, 0, 1, 1) : cropForRatio(w, h, ratios[cam.ratio].$2);
    final preset = LookEngine.preset(cam.presetId);
    final look = preset == null ? ResolvedLook.neutral : resolveLook(preset: preset, intensity: cam.intensity);

    final mirrored = front && s.mirrorFront;
    final multi = cam.multi && !video;
    final held = multi ? cam.firstImage : null;
    final maskEdit = multi && _dial == 'mask' && cam.dx.mask != null;
    Widget tex = Texture(textureId: p.textureId);
    if (p.quarterTurns != 0) tex = RotatedBox(quarterTurns: p.quarterTurns, child: tex);
    // The first frame of a double exposure sits on the live image, inside the
    // look, exactly as the two will be developed together.
    if (held != null) {
      tex = Stack(fit: StackFit.expand, children: [tex, CustomPaint(painter: _ExposurePainter(held, cam.dx))]);
    }
    if (cam.mode == CamMode.portrait) {
      final sub = mirrored ? Offset(1 - cam.subject.dx, cam.subject.dy) : cam.subject;
      tex = _PortraitPreview(subject: sub, aperture: cam.aperture, area: cam.area, child: tex);
    }
    if (mirrored) tex = Transform.flip(flipX: true, child: tex);

    return Center(
      child: AspectRatio(
        aspectRatio: w / h,
        child: LayoutBuilder(builder: (context, box) {
          final size = box.biggest;
          final frame = Rect.fromLTWH(
            crop.left * size.width,
            crop.top * size.height,
            crop.width * size.width,
            crop.height * size.height,
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: LookFilter(
                  look: look,
                  crop: crop,
                  frameAspect: frame.width / frame.height,
                  peaking: cam.peaking && cam.mode == CamMode.pro,
                  animateGrain: true,
                  child: tex,
                ),
              ),
              if (crop != const Rect.fromLTRB(0, 0, 1, 1)) CustomPaint(painter: _MaskPainter(frame)),
              if (s.grid != 0)
                Positioned.fromRect(rect: frame, child: IgnorePointer(child: CustomPaint(painter: GridPainter(s.grid)))),
              if (s.level) const Center(child: IgnorePointer(child: LevelView())),
              if (cam.focusPoint != null)
                Positioned(
                  left: cam.focusPoint!.dx * size.width - 34,
                  top: cam.focusPoint!.dy * size.height - 34,
                  child: IgnorePointer(
                    child: FocusReticle(key: ValueKey(cam.focusPoint), locked: cam.locked),
                  ),
                ),
              // Shutter blink.
              IgnorePointer(
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(cam.shots),
                  tween: Tween(begin: cam.shots == 0 ? 0 : 0.85, end: 0),
                  duration: const Duration(milliseconds: 260),
                  builder: (_, v, _) => ColoredBox(color: Colors.black.withValues(alpha: v)),
                ),
              ),
              if (maskEdit)
                Transform.flip(
                  flipX: mirrored,
                  child: MaskOverlay(
                    mask: cam.dx.mask!,
                    onChanged: (m) => _ctl.setDx((d) => d.copyWith(mask: m)),
                    onEnd: () {},
                  ),
                )
              else
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _ctl.focusAt(Offset(d.localPosition.dx / size.width, d.localPosition.dy / size.height)),
                onLongPressStart: (d) => _ctl.focusAt(
                  Offset(d.localPosition.dx / size.width, d.localPosition.dy / size.height),
                  lock: true,
                ),
                onScaleStart: (_) {
                  _zoomStart = cam.zoom;
                  _swipe = Offset.zero;
                  _pinching = false;
                },
                onScaleUpdate: (d) {
                  if (d.pointerCount >= 2) {
                    _pinching = true;
                    _ctl.setZoom(_zoomStart * d.scale);
                  } else {
                    _swipe += d.focalPointDelta;
                  }
                },
                onScaleEnd: (_) {
                  if (_pinching) return;
                  final dx = _swipe.dx, dy = _swipe.dy;
                  if (dx.abs() > 56 && dx.abs() > dy.abs() * 1.4) {
                    final i = (cam.mode.index + (dx < 0 ? 1 : -1)).clamp(0, CamMode.values.length - 1);
                    _ctl.setMode(CamMode.values[i]);
                  } else if (dy.abs() > 56 && dy.abs() > dx.abs() * 1.4) {
                    _stepPreset(dy < 0 ? 1 : -1);
                  }
                },
              ),
              if (cam.countdown > 0)
                Center(
                  child: IgnorePointer(
                    child: Text('${cam.countdown}', style: context.display(120).copyWith(color: Colors.white)),
                  ),
                ),
              Positioned(top: 0, left: 0, right: 0, child: _topBar(context, cam, s)),
              if (s.histogram && p.analysis)
                const Positioned(top: 52, right: 12, child: IgnorePointer(child: HistogramView())),
              if (multi || cam.mode == CamMode.portrait)
                Positioned(
                  top: 52,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(12)),
                        child: Text(
                          [
                            if (cam.mode == CamMode.portrait) 'portrait  ·  tap your subject',
                            if (multi) held == null ? 'double exposure  ·  first frame' : 'double exposure  ·  second frame',
                          ].join('\n'),
                          textAlign: TextAlign.center,
                          style: context.num(Colors.white, 11),
                        ),
                      ),
                    ),
                  ),
                ),
              if (cam.recording)
                Positioned(
                  top: 56,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: cam.paused ? Colors.white54 : const Color(0xFFE5402F),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(formatClock(cam.elapsed), style: context.num(Colors.white, 14)),
                      ],
                    ),
                  ),
                ),
              Positioned(
                bottom: 46,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _lookLabel == null ? 0 : 1,
                    duration: const Duration(milliseconds: 180),
                    child: Center(
                      child: Text(_lookLabel ?? '', style: context.display(30).copyWith(color: Colors.white, fontStyle: FontStyle.italic)),
                    ),
                  ),
                ),
              ),
              Positioned(bottom: 8, left: 0, right: 0, child: Center(child: _lenses(context, cam))),
            ],
          );
        }),
      ),
    );
  }

  Widget _topBar(BuildContext context, CamState cam, Settings s) {
    final c = context.c;
    final set = ref.read(settingsProvider.notifier).set;
    final pro = cam.mode == CamMode.pro, video = cam.mode == CamMode.video;
    Widget quick(Widget child, VoidCallback onTap, String label, {VoidCallback? onAfter}) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
            onAfter?.call();
          },
          child: Semantics(
            button: true,
            label: label,
            child: SizedBox(width: 44, height: 44, child: Center(child: child)),
          ),
        );
    Icon ic(IconData d, bool on) => Icon(d, size: 19, color: on ? c.accent : Colors.white);

    final items = <Widget>[
      for (final id in s.controls)
        switch (id) {
          'flash' when cam.camera?.flash == true => quick(
              ic(
                switch (cam.flash) {
                  'auto' => Icons.flash_auto,
                  'on' => Icons.flash_on,
                  'torch' => Icons.highlight,
                  _ => Icons.flash_off,
                },
                cam.flash != 'off',
              ),
              _ctl.cycleFlash,
              'flash ${cam.flash}',
            ),
          'timer' when !video => quick(
              cam.timer == 0
                  ? ic(Icons.timer_outlined, false)
                  : Text('${cam.timer}s', style: context.num(c.accent, 13)),
              _ctl.cycleTimer,
              'self timer',
            ),
          'ratio' when !video => quick(
              Text(ratios[cam.ratio].$1, style: context.num(cam.ratio == 0 ? Colors.white : c.accent, 12.5)),
              _ctl.cycleRatio,
              'aspect ratio',
            ),
          'grid' => quick(ic(Icons.grid_3x3, s.grid != 0), () {
              final next = (s.grid + 1) % gridNames.length;
              set('grid', next);
              _flash(gridNames[next]);
            }, 'grid'),
          'level' => quick(ic(Icons.horizontal_rule, s.level), () {
              set('level', !s.level);
              NativeCamera.setLevelEnabled(!s.level);
            }, 'level'),
          'histogram' when cam.preview?.analysis == true =>
            quick(ic(Icons.bar_chart, s.histogram), () => set('histogram', !s.histogram), 'histogram'),
          'peaking' when pro => quick(ic(Icons.center_focus_strong_outlined, cam.peaking), _ctl.togglePeaking, 'focus peaking'),
          _ => const SizedBox.shrink(),
        },
    ];
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x66000000), Color(0x00000000)],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: box.maxWidth),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: items),
                Row(
                  children: [
          if (!video)
            quick(
              Icon(Icons.layers_outlined, size: 19, color: cam.multi ? c.accent : Colors.white),
              _ctl.toggleMulti,
              cam.multi ? 'double exposure on' : 'double exposure off',
              onAfter: () => _flash(cam.multi ? 'single frame' : 'double exposure'),
            ),
          if (pro && cam.camera?.raw == true)
            quick(Text('RAW', style: context.num(cam.raw ? c.accent : Colors.white60, 12.5)), _ctl.toggleRaw, 'raw capture'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _lenses(BuildContext context, CamState cam) {
    final cur = cam.camera;
    if (cur == null) return const SizedBox.shrink();
    final lenses = cur.front
        ? [cur]
        : ([...cam.cameras.where((c) => !c.front)]..sort((a, b) => a.zoomLabel.compareTo(b.zoomLabel)));
    String fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final l in lenses)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => l.id == cur.id ? _ctl.setZoom(1) : _ctl.selectCamera(l),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(
                  l.id == cur.id ? '${fmt(l.zoomLabel * cam.zoom)}×' : fmt(l.zoomLabel),
                  style: context.num(l.id == cur.id ? context.c.accent : Colors.white, 12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Control tray ──────────────────────────────────────────────────────

  Widget _tray(BuildContext context, CamState cam) {
    final info = cam.camera;
    if (info == null || cam.preview == null) return const SizedBox(height: 46);
    final pro = cam.mode == CamMode.pro;
    final manualExposure = cam.iso != null || cam.shutter != null;
    final multi = cam.multi && cam.mode != CamMode.video;
    final ids = [
      // Double exposure first, so its blend and mask are always in reach.
      if (multi) ...['blend', 'opacity', 'tone', 'mask'],
      if (cam.mode == CamMode.portrait) ...['aperture', 'area'],
      if (pro && info.manualExposure) ...['iso', 's'],
      if (pro && (info.manualWb || Platform.isAndroid)) 'wb',
      if (pro && info.manualFocus) 'mf',
      if (info.maxEv > info.minEv && !manualExposure) 'ev',
      if (info.maxZoom > info.minZoom) 'zoom',
      if (cam.presetId != null) 'look',
    ];
    final active = ids.contains(_dial) ? _dial : null;

    return ValueListenableBuilder<LiveValues>(
      valueListenable: NativeCamera.live,
      builder: (context, live, _) {
        String value(String id) => switch (id) {
              'iso' => (cam.iso ?? live.iso).round().toString(),
              's' => formatShutter(cam.shutter ?? live.shutter),
              'wb' => cam.kelvin == null ? 'auto' : '${cam.kelvin!.round()}K',
              'mf' => cam.focus == null ? 'auto' : cam.focus!.toStringAsFixed(2),
              'ev' => '${cam.ev >= 0 ? '+' : ''}${cam.ev.toStringAsFixed(1)}',
              'zoom' => '${cam.zoom.toStringAsFixed(1)}×',
              'blend' => cam.dx.blend.label,
              'opacity' => '${(cam.dx.opacity * 100).round()}',
              'tone' => cam.dx.tone == 0 ? 'off' : '${cam.dx.tone > 0 ? 'hi' : 'lo'} ${(cam.dx.tone.abs() * 100).round()}',
              'mask' => cam.dx.mask == null ? 'none' : cam.dx.mask!.type.name,
              'aperture' => 'f/${PortraitBlur(amount: cam.aperture).fNumber.toStringAsFixed(1)}',
              'area' => '${(cam.area * 100).round()}',
              _ => '${(cam.intensity * 100).round()}',
            };
        bool manual(String id) => switch (id) {
              'iso' => cam.iso != null,
              's' => cam.shutter != null,
              'wb' => cam.kelvin != null,
              'mf' => cam.focus != null,
              'tone' => cam.dx.tone != 0,
              'mask' => cam.dx.mask != null,
              _ => false,
            };
        // Position of the active dial on its ruler (0..1) and how to set it.
        double t = 0, neutral = 0;
        void Function(double)? setT;
        VoidCallback? auto;
        Widget? choices;
        switch (active) {
          case 'iso':
            t = _unlog(cam.iso ?? math.max(live.iso, info.minIso), info.minIso, info.maxIso);
            setT = (v) => _ctl.setIso(_log(v, info.minIso, info.maxIso).roundToDouble());
            auto = () => _ctl.setIso(null);
          case 's':
            t = _unlog(cam.shutter ?? math.max(live.shutter, info.minShutter), info.minShutter, info.maxShutter);
            setT = (v) => _ctl.setShutter(_log(v, info.minShutter, info.maxShutter));
            auto = () => _ctl.setShutter(null);
          case 'wb':
            t = ((cam.kelvin ?? 5500) - 2000) / 8000;
            setT = (v) => _ctl.setKelvin((2000 + v * 8000) ~/ 50 * 50.0);
            auto = () => _ctl.setKelvin(null);
          case 'mf':
            t = cam.focus ?? live.focus.clamp(0.0, 1.0);
            setT = _ctl.setFocus;
            auto = () => _ctl.setFocus(null);
          case 'ev':
            t = (cam.ev - info.minEv) / (info.maxEv - info.minEv);
            neutral = -info.minEv / (info.maxEv - info.minEv);
            setT = (v) => _ctl.setEv(((info.minEv + v * (info.maxEv - info.minEv)) * 10).round() / 10);
          case 'zoom':
            t = _unlog(cam.zoom, info.minZoom, info.maxZoom);
            neutral = _unlog(1, info.minZoom, info.maxZoom);
            setT = (v) => _ctl.setZoom(_log(v, info.minZoom, info.maxZoom));
          case 'look':
            t = cam.intensity;
            neutral = 1;
            setT = _ctl.setIntensity;
          case 'aperture':
            t = cam.aperture;
            neutral = 0.6;
            setT = _ctl.setAperture;
          case 'area':
            t = (cam.area - 0.08) / 0.6;
            neutral = (0.3 - 0.08) / 0.6;
            setT = (v) => _ctl.setArea(0.08 + v * 0.6);
          case 'opacity':
            t = cam.dx.opacity;
            neutral = 0.8;
            setT = (v) => _ctl.setDx((d) => d.copyWith(opacity: v));
          case 'tone':
            t = (cam.dx.tone + 1) / 2;
            neutral = 0.5;
            setT = (v) => _ctl.setDx((d) => d.copyWith(tone: (v * 2 - 1).abs() < 0.04 ? 0 : v * 2 - 1));
          case 'blend':
            choices = _choices([
              for (final b in ExposureBlend.values)
                TextTab(b.label, active: cam.dx.blend == b, onTap: () => _ctl.setDx((d) => d.copyWith(blend: b))),
            ]);
          case 'mask':
            final m = cam.dx.mask;
            void setMask(MaskType? t) => _ctl.setDx((d) => d.copyWith(
                  mask: t == null
                      ? null
                      : d.mask?.type == t
                          ? d.mask
                          : MaskLayer(
                              type: t,
                              a: t == MaskType.radial ? const Offset(0.5, 0.5) : const Offset(0.5, 0.3),
                              b: const Offset(0.5, 0.75),
                              radius: t == MaskType.brush ? 0.12 : 0.35,
                              feather: 0.6,
                            ),
                ));
            choices = _choices([
              TextTab('none', active: m == null, onTap: () => setMask(null)),
              for (final t in MaskType.values) TextTab(t.name, active: m?.type == t, onTap: () => setMask(t)),
              if (m != null)
                TextTab(m.invert ? 'inverted' : 'invert', active: m.invert, dot: false, onTap: () => _ctl.setDx((d) => d.copyWith(mask: m.copyWith(invert: !m.invert)))),
              if (m != null && m.type == MaskType.brush)
                TextTab('clear', active: false, dot: false, onTap: () => _ctl.setDx((d) => d.copyWith(mask: m.copyWith(strokes: const [])))),
            ]);
        }
        return AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.bottomCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ?choices,
              if (setT != null)
                Row(
                  children: [
                    Expanded(child: Ruler(value: t.clamp(0.0, 1.0), min: 0, max: 1, neutral: neutral, height: 40, onChanged: setT)),
                    if (auto != null)
                      TextTab('auto', active: !manual(active!), dot: false, onTap: auto)
                    else
                      const SizedBox(width: 12),
                  ],
                ),
              SizedBox(
                height: 46,
                child: LayoutBuilder(
                  builder: (context, box) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minWidth: box.maxWidth),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final id in ids)
                            Dial(
                              label: id == 's' ? 'shutter' : id,
                              value: value(id),
                              active: id == active,
                              manual: manual(id),
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _dial = _dial == id ? null : id);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _choices(List<Widget> children) => SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: children),
      );

  Widget _modeRow(BuildContext context, CamState cam) => SizedBox(
        height: 34,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final m in CamMode.values)
              TextTab(m.name, active: m == cam.mode, onTap: cam.recording ? null : () => _ctl.setMode(m)),
          ],
        ),
      );

  Widget _shutterRow(BuildContext context, CamState cam) {
    final video = cam.mode == CamMode.video;
    final last = cam.last ?? ref.watch(libraryProvider.select((l) => l.assets.firstOrNull));
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (cam.firstImage != null)
            GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                _ctl.discardFirst();
              },
              child: Semantics(
                button: true,
                label: 'discard the first frame',
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(border: Border.all(color: context.c.accent)),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RawImage(image: cam.firstImage, fit: BoxFit.cover),
                      const ColoredBox(color: Colors.black38),
                      const Icon(Icons.close, size: 18, color: Colors.white),
                    ],
                  ),
                ),
              ),
            )
          else
          GestureDetector(
            onTap: () => _openLast(cam),
            child: Semantics(
              button: true,
              label: 'latest photograph',
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(border: Border.all(color: Colors.white24)),
                child: last == null ? null : AssetThumb(last, key: ValueKey(last.id)),
              ),
            ),
          ),
          ShutterButton(
            video: video,
            recording: cam.recording,
            busy: cam.busy,
            onTap: video ? _ctl.toggleRecord : _ctl.capture,
          ),
          SizedBox(
            width: 46,
            child: cam.recording
                ? (_ctl.canPause
                    ? IconBtn(cam.paused ? Icons.play_arrow : Icons.pause, color: Colors.white, onTap: _ctl.togglePause, tooltip: 'pause')
                    : null)
                : IconBtn(Icons.cached, color: Colors.white, onTap: _ctl.flip, tooltip: 'switch camera'),
          ),
        ],
      ),
    );
  }
}

/// Dims the area outside the chosen aspect ratio.
class _MaskPainter extends CustomPainter {
  _MaskPainter(this.frame);
  final Rect frame;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(frame);
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.72));
  }

  @override
  bool shouldRepaint(_MaskPainter o) => o.frame != frame;
}

/// The held first frame of a double exposure, over the live image.
class _ExposurePainter extends CustomPainter {
  _ExposurePainter(this.image, this.dx);
  final ui.Image image;
  final DoubleExposure dx;

  @override
  void paint(Canvas canvas, Size size) => paintDoubleExposure(canvas, Offset.zero & size, image, dx, quality: ui.FilterQuality.low);

  @override
  bool shouldRepaint(_ExposurePainter o) => o.image != image || o.dx != dx;
}

/// Live portrait preview: the frame blurred, with the subject area kept
/// sharp. The capture refines this with the detected person.
class _PortraitPreview extends StatelessWidget {
  const _PortraitPreview({required this.subject, required this.aperture, required this.area, required this.child});
  final Offset subject;
  final double aperture, area;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final sigma = 0.5 + aperture * math.max(box.maxWidth, box.maxHeight) * 0.012;
        return Stack(
          fit: StackFit.expand,
          children: [
            ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp), child: child),
            ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (r) => ui.Gradient.radial(
                Offset(subject.dx * r.width, subject.dy * r.height),
                math.max(1, area * r.width),
                const [Colors.white, Colors.white, Color(0x00FFFFFF)],
                const [0, 0.5, 1],
              ),
              child: child,
            ),
          ],
        );
      });
}
