import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../core/camera/native_camera.dart';
import '../../core/export/exporter.dart';
import '../../core/image_processing/adjustments.dart';
import '../../core/image_processing/renderer.dart';
import '../../core/media/media_library.dart';
import '../../core/storage/app_state.dart';

enum CamMode { photo, portrait, pro, video }

/// Capture aspect ratios as (label, long side / short side).
const ratios = [('4:3', 4 / 3), ('3:2', 3 / 2), ('16:9', 16 / 9), ('1:1', 1.0)];

const _u = Object();

class CamState {
  const CamState({
    this.permission,
    this.cameras = const [],
    this.camera,
    this.preview,
    this.mode = CamMode.photo,
    this.presetId,
    this.intensity = 1,
    this.flash = 'off',
    this.timer = 0,
    this.ratio = 0,
    this.raw = false,
    this.peaking = false,
    this.zoom = 1,
    this.ev = 0,
    this.iso,
    this.shutter,
    this.kelvin,
    this.focus,
    this.locked = false,
    this.focusPoint,
    this.recording = false,
    this.paused = false,
    this.elapsed = Duration.zero,
    this.busy = false,
    this.countdown = 0,
    this.last,
    this.error,
    this.shots = 0,
    this.multi = false,
    this.first,
    this.firstImage,
    this.dx = const DoubleExposure(assetId: ''),
    this.subject = const Offset(0.5, 0.45),
    this.aperture = 0.6,
    this.area = 0.3,
  });

  final bool? permission;
  final List<CameraInfo> cameras;
  final CameraInfo? camera;
  final PreviewInfo? preview;
  final CamMode mode;
  final String? presetId;
  final double intensity;
  final String flash;
  final int timer, ratio;
  final bool raw, peaking;
  final double zoom, ev;

  /// Manual values; null means automatic.
  final double? iso, shutter, kelvin, focus;
  final bool locked;
  final Offset? focusPoint;
  final bool recording, paused;
  final Duration elapsed;
  final bool busy;
  final int countdown;
  final AssetEntity? last;
  final String? error;

  /// Increments on every exposure, to drive the shutter blink.
  final int shots;

  /// Double exposure is armed: the next two frames are exposed together.
  final bool multi;

  /// The first frame, once taken, and its pixels for the viewfinder overlay.
  final AssetEntity? first;
  final ui.Image? firstImage;

  /// How the first frame is exposed onto the second; [DoubleExposure.assetId]
  /// is filled in at capture.
  final DoubleExposure dx;

  /// Portrait mode: where the subject is (normalised, as displayed), the
  /// blur strength (0..1, f/16..f/1.2) and the size of the sharp area.
  final Offset subject;
  final double aperture, area;

  CamState copyWith({
    bool? permission,
    List<CameraInfo>? cameras,
    CameraInfo? camera,
    Object? preview = _u,
    CamMode? mode,
    Object? presetId = _u,
    double? intensity,
    String? flash,
    int? timer,
    int? ratio,
    bool? raw,
    bool? peaking,
    double? zoom,
    double? ev,
    Object? iso = _u,
    Object? shutter = _u,
    Object? kelvin = _u,
    Object? focus = _u,
    bool? locked,
    Object? focusPoint = _u,
    bool? recording,
    bool? paused,
    Duration? elapsed,
    bool? busy,
    int? countdown,
    AssetEntity? last,
    Object? error = _u,
    int? shots,
    bool? multi,
    Object? first = _u,
    Object? firstImage = _u,
    DoubleExposure? dx,
    Offset? subject,
    double? aperture,
    double? area,
  }) =>
      CamState(
        permission: permission ?? this.permission,
        cameras: cameras ?? this.cameras,
        camera: camera ?? this.camera,
        preview: preview == _u ? this.preview : preview as PreviewInfo?,
        mode: mode ?? this.mode,
        presetId: presetId == _u ? this.presetId : presetId as String?,
        intensity: intensity ?? this.intensity,
        flash: flash ?? this.flash,
        timer: timer ?? this.timer,
        ratio: ratio ?? this.ratio,
        raw: raw ?? this.raw,
        peaking: peaking ?? this.peaking,
        zoom: zoom ?? this.zoom,
        ev: ev ?? this.ev,
        iso: iso == _u ? this.iso : iso as double?,
        shutter: shutter == _u ? this.shutter : shutter as double?,
        kelvin: kelvin == _u ? this.kelvin : kelvin as double?,
        focus: focus == _u ? this.focus : focus as double?,
        locked: locked ?? this.locked,
        focusPoint: focusPoint == _u ? this.focusPoint : focusPoint as Offset?,
        recording: recording ?? this.recording,
        paused: paused ?? this.paused,
        elapsed: elapsed ?? this.elapsed,
        busy: busy ?? this.busy,
        countdown: countdown ?? this.countdown,
        last: last ?? this.last,
        error: error == _u ? this.error : error as String?,
        shots: shots ?? this.shots,
        multi: multi ?? this.multi,
        first: first == _u ? this.first : first as AssetEntity?,
        firstImage: firstImage == _u ? this.firstImage : firstImage as ui.Image?,
        dx: dx ?? this.dx,
        subject: subject ?? this.subject,
        aperture: aperture ?? this.aperture,
        area: area ?? this.area,
      );
}

/// Normalised crop that turns a 4:3 frame of [w]×[h] pixels into [ratio].
Rect cropForRatio(double w, double h, double ratio) {
  final long = w >= h ? w : h, short = w >= h ? h : w;
  final native = long / short;
  if ((native - ratio).abs() < 0.02) return const Rect.fromLTRB(0, 0, 1, 1);
  // Wider than native trims the short side; squarer trims the long side.
  final trimShort = ratio > native;
  final f = trimShort ? native / ratio : ratio / native;
  final alongWidth = trimShort ? w < h : w >= h;
  return alongWidth
      ? Rect.fromLTRB((1 - f) / 2, 0, (1 + f) / 2, 1)
      : Rect.fromLTRB(0, (1 - f) / 2, 1, (1 + f) / 2);
}

class CameraController extends Notifier<CamState> {
  Future<void> _chain = Future.value();
  Timer? _recTimer, _focusTimer;
  bool _active = false;
  StreamSubscription<String>? _errors;

  @override
  CamState build() {
    _errors = NativeCamera.errors.stream.listen((m) => state = state.copyWith(error: m));
    ref.onDispose(() {
      _errors?.cancel();
      state.firstImage?.dispose();
    });
    return const CamState();
  }

  Settings get _s => ref.read(settingsProvider);

  Future<void> _enqueue(Future<void> Function() job) => _chain = _chain.then((_) => job()).catchError((_) {});

  Future<void> activate() async {
    _active = true;
    if (state.permission != true) {
      final ok = await NativeCamera.requestPermission();
      state = state.copyWith(permission: ok);
      if (!ok) return;
    }
    if (state.cameras.isEmpty) {
      final cams = await NativeCamera.cameras();
      final back = cams.where((c) => !c.front && c.lens == 'wide').firstOrNull ?? cams.firstOrNull;
      state = state.copyWith(cameras: cams, camera: back);
    }
    if (state.camera == null) {
      state = state.copyWith(error: 'No camera found on this device');
      return;
    }
    await _reopen();
  }

  Future<void> deactivate() async {
    _active = false;
    if (state.recording) await toggleRecord();
    await _enqueue(() async {
      await NativeCamera.close();
      state = state.copyWith(preview: null);
    });
  }

  Future<void> _reopen() => _enqueue(() async {
        if (!_active) return;
        final cam = state.camera!;
        final video = state.mode == CamMode.video;
        state = state.copyWith(preview: null, error: null);
        try {
          if (video) await NativeCamera.requestPermission(audio: true);
          final sizes = cam.photoSizes;
          final size = sizes.isEmpty ? const [0, 0] : sizes[_s.photoMp.clamp(0, sizes.length - 1)];
          final modes = cam.videoSizes;
          final vm = modes.where((m) => m[1] == _s.videoHeight).firstOrNull ?? modes.firstOrNull;
          final p = await NativeCamera.open(
            cameraId: cam.id,
            video: video,
            raw: state.raw && cam.raw,
            photoWidth: size[0],
            photoHeight: size[1],
            videoHeight: vm?[1] ?? 1080,
            fps: vm == null ? 30 : _s.videoFps.clamp(24, vm[2]),
            stabilization: _s.stabilization,
          );
          if (!_active) {
            await NativeCamera.close();
            return;
          }
          final wantedRaw = state.raw;
          state = state.copyWith(
            preview: p,
            raw: wantedRaw && p.raw,
            zoom: 1,
            ev: 0,
            iso: null,
            shutter: null,
            kelvin: null,
            focus: null,
            locked: false,
            focusPoint: null,
            flash: video && state.flash != 'off' ? 'off' : state.flash,
            error: wantedRaw && !p.raw ? 'RAW is not available on this lens' : null,
          );
          await NativeCamera.setLevelEnabled(_s.level);
          await NativeCamera.setControls({'flash': state.flash});
        } on PlatformException catch (e) {
          state = state.copyWith(error: e.message ?? 'The camera could not be opened');
        }
      });

  void clearError() => state = state.copyWith(error: null);

  // ── Mode, lens, look ──────────────────────────────────────────────────

  void setMode(CamMode m) {
    if (m == state.mode || state.recording || state.busy) return;
    final was = state.mode;
    HapticFeedback.selectionClick();
    if (m == CamMode.video && state.multi) toggleMulti();
    state = state.copyWith(mode: m, raw: m == CamMode.pro ? state.raw : false, peaking: m == CamMode.pro && state.peaking);
    final needsReopen = (was == CamMode.video) != (m == CamMode.video) || (was == CamMode.pro && state.preview?.raw == true);
    if (needsReopen) {
      _reopen();
    } else if (was == CamMode.pro) {
      state = state.copyWith(iso: null, shutter: null, kelvin: null, focus: null);
      NativeCamera.setControls({'autoExposure': true, 'iso': null, 'shutter': null, 'wbAuto': true, 'focusAuto': true});
    }
  }

  void selectCamera(CameraInfo c) {
    if (c.id == state.camera?.id || state.recording) return;
    HapticFeedback.selectionClick();
    state = state.copyWith(camera: c);
    _reopen();
  }

  void flip() {
    final front = state.camera?.front ?? false;
    final next = state.cameras.where((c) => c.front != front && (c.front || c.lens == 'wide')).firstOrNull ??
        state.cameras.where((c) => c.front != front).firstOrNull;
    if (next != null) selectCamera(next);
  }

  void setPreset(String? id) => state = state.copyWith(presetId: id, intensity: 1);
  void setIntensity(double v) => state = state.copyWith(intensity: v);

  void toggleRaw() {
    if (state.camera?.raw != true || state.busy) return;
    state = state.copyWith(raw: !state.raw);
    _reopen();
  }

  void togglePeaking() => state = state.copyWith(peaking: !state.peaking);

  void cycleFlash() {
    if (state.camera?.flash != true) return;
    final order = state.mode == CamMode.video ? const ['off', 'torch'] : const ['off', 'auto', 'on', 'torch'];
    final next = order[(order.indexOf(state.flash) + 1) % order.length];
    state = state.copyWith(flash: next);
    NativeCamera.setControls({'flash': next});
  }

  void cycleTimer() => state = state.copyWith(timer: const {0: 3, 3: 10, 10: 0}[state.timer]);
  void cycleRatio() => state = state.copyWith(ratio: (state.ratio + 1) % ratios.length);

  // ── Double exposure ───────────────────────────────────────────────────

  void toggleMulti() {
    if (state.mode == CamMode.video || state.busy) return;
    if (state.multi) discardFirst();
    state = state.copyWith(multi: !state.multi);
  }

  /// Drops the held first frame; the photograph itself stays in the library.
  void discardFirst() {
    final img = state.firstImage;
    state = state.copyWith(first: null, firstImage: null);
    if (img != null) SchedulerBinding.instance.addPostFrameCallback((_) => img.dispose());
  }

  void setDx(DoubleExposure Function(DoubleExposure) f) => state = state.copyWith(dx: f(state.dx));

  // ── Portrait ──────────────────────────────────────────────────────────

  void setAperture(double v) => state = state.copyWith(aperture: v);
  void setArea(double v) => state = state.copyWith(area: v);

  // ── Exposure, focus, zoom ─────────────────────────────────────────────

  void setZoom(double z) {
    final cam = state.camera;
    if (cam == null) return;
    final v = z.clamp(cam.minZoom, cam.maxZoom).toDouble();
    state = state.copyWith(zoom: v);
    NativeCamera.setControls({'zoom': v});
  }

  void setEv(double v) {
    state = state.copyWith(ev: v);
    NativeCamera.setControls({'ev': v});
  }

  void _pushExposure() => NativeCamera.setControls({
        'autoExposure': state.iso == null && state.shutter == null,
        'iso': state.iso,
        'shutter': state.shutter,
      });

  void setIso(double? v) {
    state = state.copyWith(iso: v);
    _pushExposure();
  }

  void setShutter(double? v) {
    state = state.copyWith(shutter: v);
    _pushExposure();
  }

  void setKelvin(double? v) {
    state = state.copyWith(kelvin: v);
    NativeCamera.setControls({'wbAuto': v == null, 'temperature': ?v});
  }

  void setFocus(double? v) {
    state = state.copyWith(focus: v, focusPoint: null, locked: false);
    NativeCamera.setControls({'focusAuto': v == null, 'focusDistance': ?v, 'focusReset': v == null});
  }

  /// Tap to focus and meter at a point (normalised, as displayed).
  void focusAt(Offset p, {bool lock = false}) {
    if (state.preview == null) return;
    HapticFeedback.selectionClick();
    final mirrored = (state.camera?.front ?? false) && _s.mirrorFront;
    NativeCamera.focusAt(mirrored ? 1 - p.dx : p.dx, p.dy);
    if (lock) NativeCamera.setControls({'aeLock': true});
    if (!lock && state.locked) NativeCamera.setControls({'aeLock': false});
    state = state.copyWith(focusPoint: p, locked: lock, subject: state.mode == CamMode.portrait ? p : null);
    _focusTimer?.cancel();
    if (!lock) _focusTimer = Timer(const Duration(seconds: 5), resetFocus);
  }

  void resetFocus() {
    _focusTimer?.cancel();
    if (state.focusPoint == null && !state.locked) return;
    state = state.copyWith(focusPoint: null, locked: false);
    NativeCamera.setControls({'aeLock': false, 'focusReset': true, 'focusAuto': state.focus == null});
  }

  // ── Capture ───────────────────────────────────────────────────────────

  EditState _recipe({Rect crop = const Rect.fromLTRB(0, 0, 1, 1), DoubleExposure? dx, PortraitBlur? portrait}) => EditState(
        presetId: state.presetId,
        intensity: state.intensity,
        geo: Geometry(crop: crop, flipH: (state.camera?.front ?? false) && _s.mirrorFront),
        dx: dx,
        portrait: portrait,
      );

  /// The portrait recipe for a shot: the detected person if there is one,
  /// otherwise the focus area around the subject point.
  PortraitBlur _portrait(String? matte) {
    final mirrored = (state.camera?.front ?? false) && _s.mirrorFront;
    final s = state.subject;
    return PortraitBlur(
      amount: state.aperture,
      matte: matte,
      center: Offset(mirrored ? 1 - s.dx : s.dx, s.dy),
      radius: state.area,
    );
  }

  Future<void> capture() async {
    if (state.busy || state.preview == null || state.mode == CamMode.video) return;
    state = state.copyWith(busy: true);
    try {
      for (var t = state.timer; t > 0; t--) {
        state = state.copyWith(countdown: t);
        if (_s.haptics) HapticFeedback.selectionClick();
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!_active) return;
      }
      state = state.copyWith(countdown: 0, shots: state.shots + 1);
      if (_s.haptics) HapticFeedback.mediumImpact();
      final raw = state.raw && state.mode == CamMode.pro;
      // In double exposure the held first frame is exposed onto this one.
      final multi = state.multi, first = multi ? state.first : null;
      final dx = first == null ? null : state.dx.copyWith(assetId: first.id);
      final r = await NativeCamera.takePhoto(jpeg: true, raw: raw);
      final name = 'eski_${Exporter.stamp()}';
      final folder = Platform.isAndroid ? 'Pictures/eski' : null;
      AssetEntity? jpeg, dng;
      final jp = r['jpeg'] as String?, rp = r['raw'] as String?;
      ui.Image? held;
      PortraitBlur? portrait;
      if (jp != null) {
        if (state.mode == CamMode.portrait) portrait = _portrait(await Exporter.detectSubject(jp));
        jpeg = await PhotoManager.editor.saveImageWithPath(jp, title: '$name.jpg', relativePath: folder);
        if (multi && first == null) {
          try {
            held = await decodeImageFile(jp, maxEdge: 1600);
          } catch (_) {}
        }
        File(jp).delete().ignore();
      }
      if (rp != null) {
        dng = await PhotoManager.editor.saveImageWithPath(rp, title: '$name.dng', relativePath: folder);
        File(rp).delete().ignore();
      }
      final edits = ref.read(editsProvider.notifier);
      final lib = ref.read(libraryProvider.notifier);
      for (final a in [dng, jpeg].nonNulls) {
        final size = a.orientatedSize;
        final recipe = _recipe(crop: cropForRatio(size.width, size.height, ratios[state.ratio].$2), dx: dx, portrait: portrait);
        if (!recipe.isNeutral) edits.put(a.id, recipe);
        lib.prepend(a);
      }
      final main = jpeg ?? dng;
      state = state.copyWith(last: main);
      if (multi && first == null && jpeg != null) {
        state = held == null
            ? state.copyWith(error: 'The first frame could not be held — take it again')
            : state.copyWith(first: jpeg, firstImage: held);
      } else if (first != null) {
        discardFirst();
      }
      // Double exposures and portraits are always written out whole so other
      // apps see the finished picture.
      if (jpeg != null && (_s.saveFiltered || dx != null || portrait != null)) {
        final recipe = ref.read(editsProvider)[jpeg.id];
        if (recipe != null) unawaited(_saveFilteredCopy(jpeg, recipe));
      }
    } on PlatformException catch (e) {
      state = state.copyWith(error: e.message ?? 'Capture failed');
    } catch (e) {
      state = state.copyWith(error: 'The photo could not be saved');
    } finally {
      state = state.copyWith(busy: false, countdown: 0);
    }
  }

  /// Writes a rendered copy to the device library so other apps see the look.
  Future<void> _saveFilteredCopy(AssetEntity source, EditState recipe) async {
    try {
      final file = await Exporter.render(source, recipe, _s);
      final copy = await Exporter.saveImage(file);
      ref.read(exportsProvider.notifier).toggle(copy.id, true);
      file.delete().ignore();
    } catch (_) {}
  }

  Future<void> toggleRecord() async {
    if (state.mode != CamMode.video || state.preview == null || state.busy) return;
    if (!state.recording) {
      try {
        await NativeCamera.startVideo();
        if (_s.haptics) HapticFeedback.mediumImpact();
        state = state.copyWith(recording: true, paused: false, elapsed: Duration.zero);
        _recTimer?.cancel();
        _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!state.paused) state = state.copyWith(elapsed: state.elapsed + const Duration(seconds: 1));
        });
      } on PlatformException catch (e) {
        state = state.copyWith(error: e.message ?? 'Recording could not start');
      }
      return;
    }
    _recTimer?.cancel();
    state = state.copyWith(busy: true);
    try {
      final path = await NativeCamera.stopVideo();
      if (_s.haptics) HapticFeedback.mediumImpact();
      if (path != null) {
        final ext = path.split('.').last;
        final a = await PhotoManager.editor.saveVideo(
          File(path),
          title: 'eski_${Exporter.stamp()}.$ext',
          relativePath: Platform.isAndroid ? 'Movies/eski' : null,
        );
        File(path).delete().ignore();
        final recipe = EditState(presetId: state.presetId, intensity: state.intensity);
        if (!recipe.isNeutral) ref.read(editsProvider.notifier).put(a.id, recipe);
        ref.read(libraryProvider.notifier).prepend(a);
        state = state.copyWith(last: a);
      }
    } catch (_) {
      state = state.copyWith(error: 'The video could not be saved');
    } finally {
      state = state.copyWith(recording: false, paused: false, busy: false);
    }
  }

  /// Pause is offered only where the platform recorder supports it.
  bool get canPause => Platform.isAndroid;

  Future<void> togglePause() async {
    if (!state.recording || !canPause) return;
    if (state.paused) {
      await NativeCamera.resumeVideo();
      state = state.copyWith(paused: false);
    } else if (await NativeCamera.pauseVideo()) {
      state = state.copyWith(paused: true);
    }
  }
}

final cameraProvider = NotifierProvider<CameraController, CamState>(CameraController.new);

/// Index of the visible bottom-navigation tab.
class TabIndex extends Notifier<int> {
  @override
  int build() => 0;
  void set(int i) => state = i;
}

final tabProvider = NotifierProvider<TabIndex, int>(TabIndex.new);
