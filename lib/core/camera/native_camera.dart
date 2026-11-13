import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One physical camera and what its hardware actually supports.
class CameraInfo {
  CameraInfo(this.m);
  final Map m;

  String get id => m['id'] as String;
  bool get front => m['facing'] == 'front';

  /// 'ultrawide' | 'wide' | 'tele'
  String get lens => m['lens'] as String? ?? 'wide';
  double get zoomLabel => (m['zoomLabel'] as num?)?.toDouble() ?? 1;
  bool get manualExposure => m['manualExposure'] == true;
  bool get manualFocus => m['manualFocus'] == true;
  bool get manualWb => m['manualWb'] == true;
  bool get raw => m['raw'] == true;
  bool get flash => m['flash'] == true;
  bool get ois => m['ois'] == true;
  bool get videoStabilization => m['videoStabilization'] == true;
  double get minIso => (m['minIso'] as num?)?.toDouble() ?? 0;
  double get maxIso => (m['maxIso'] as num?)?.toDouble() ?? 0;

  /// Seconds.
  double get minShutter => (m['minShutter'] as num?)?.toDouble() ?? 0;
  double get maxShutter => (m['maxShutter'] as num?)?.toDouble() ?? 0;
  double get minEv => (m['minEv'] as num?)?.toDouble() ?? 0;
  double get maxEv => (m['maxEv'] as num?)?.toDouble() ?? 0;
  double get minZoom => (m['minZoom'] as num?)?.toDouble() ?? 1;
  double get maxZoom => (m['maxZoom'] as num?)?.toDouble() ?? 1;

  /// Still sizes as [width, height], largest first.
  List<List<int>> get photoSizes => [for (final s in (m['photoSizes'] as List? ?? [])) (s as List).cast<int>()];

  /// Video modes as [width, height, maxFps].
  List<List<int>> get videoSizes => [for (final s in (m['videoSizes'] as List? ?? [])) (s as List).cast<int>()];
}

class PreviewInfo {
  PreviewInfo(this.textureId, this.width, this.height, this.quarterTurns, this.analysis, this.raw);
  final int textureId;

  /// Size of the upright image as displayed.
  final int width, height;

  /// Whether RAW capture is active for this session.
  final bool raw;

  /// Clockwise quarter turns Flutter must apply to show the buffer upright.
  final int quarterTurns;

  /// Whether live histogram frames are being delivered.
  final bool analysis;
}

/// Live exposure read-out from the sensor.
class LiveValues {
  const LiveValues({this.iso = 0, this.shutter = 0, this.focus = 0, this.aperture = 0});
  final double iso, shutter, focus, aperture;
}

/// Bridge to the platform camera engines (Camera2 on Android, AVFoundation on
/// iOS), which expose the manual controls Flutter's camera plugin does not.
class NativeCamera {
  static const _ch = MethodChannel('eski/camera');
  static const _ev = EventChannel('eski/camera/events');

  static final live = ValueNotifier<LiveValues>(const LiveValues());
  static final histogram = ValueNotifier<List<int>>(const []);

  /// Device roll in degrees relative to the nearest upright orientation.
  static final roll = ValueNotifier<double>(0);
  static final errors = StreamController<String>.broadcast();
  static StreamSubscription? _sub;

  static void _listen() {
    _sub ??= _ev.receiveBroadcastStream().listen((e) {
      if (e is! Map) return;
      switch (e['type']) {
        case 'state':
          live.value = LiveValues(
            iso: (e['iso'] as num?)?.toDouble() ?? 0,
            shutter: (e['shutter'] as num?)?.toDouble() ?? 0,
            focus: (e['focus'] as num?)?.toDouble() ?? 0,
            aperture: (e['aperture'] as num?)?.toDouble() ?? 0,
          );
        case 'histogram':
          histogram.value = (e['bins'] as List).cast<int>();
        case 'level':
          roll.value = (e['roll'] as num).toDouble();
        case 'error':
          errors.add('${e['message']}');
      }
    }, onError: (_) {});
  }

  static Future<bool> requestPermission({bool audio = false}) async =>
      await _ch.invokeMethod<bool>('requestPermission', {'audio': audio}) ?? false;

  static Future<List<CameraInfo>> cameras() async {
    final l = await _ch.invokeMethod<List>('getCameras') ?? [];
    return [for (final c in l) CameraInfo(c as Map)];
  }

  static Future<PreviewInfo> open({
    required String cameraId,
    required bool video,
    bool raw = false,
    int photoWidth = 0,
    int photoHeight = 0,
    int videoHeight = 1080,
    int fps = 30,
    bool stabilization = true,
  }) async {
    _listen();
    final r = await _ch.invokeMethod<Map>('open', {
      'cameraId': cameraId,
      'video': video,
      'raw': raw,
      'photoWidth': photoWidth,
      'photoHeight': photoHeight,
      'videoHeight': videoHeight,
      'fps': fps,
      'stabilization': stabilization,
    });
    return PreviewInfo(
      r!['textureId'] as int,
      r['width'] as int,
      r['height'] as int,
      r['quarterTurns'] as int? ?? 0,
      r['analysis'] == true,
      r['raw'] == true,
    );
  }

  static Future<void> close() => _ch.invokeMethod('close');

  /// Any subset of: iso, shutter (s), ev, autoExposure, aeLock, wbAuto,
  /// temperature (K), focusAuto, focusDistance (0 far..1 near), zoom, flash
  /// ('off' | 'auto' | 'on' | 'torch').
  static Future<void> setControls(Map<String, Object?> c) => _ch.invokeMethod('setControls', c);

  static Future<void> focusAt(double x, double y) => _ch.invokeMethod('focusAt', {'x': x, 'y': y});

  static Future<void> setLevelEnabled(bool on) => _ch.invokeMethod('setLevel', {'enabled': on});

  /// Returns {'jpeg': path?, 'raw': path?}.
  static Future<Map> takePhoto({required bool jpeg, required bool raw}) async =>
      await _ch.invokeMethod<Map>('takePhoto', {'jpeg': jpeg, 'raw': raw}) ?? {};

  static Future<void> startVideo({bool audio = true}) => _ch.invokeMethod('startVideo', {'audio': audio});
  static Future<bool> pauseVideo() async => await _ch.invokeMethod<bool>('pauseVideo') ?? false;
  static Future<void> resumeVideo() => _ch.invokeMethod('resumeVideo');
  static Future<String?> stopVideo() => _ch.invokeMethod<String>('stopVideo');

  /// Encodes straight RGBA pixels as a JPEG using the platform encoder.
  static Future<void> encodeJpeg(Uint8List rgba, int width, int height, int quality, String path) =>
      _ch.invokeMethod('encodeJpeg', {'rgba': rgba, 'width': width, 'height': height, 'quality': quality, 'path': path});

  /// Finds the person in a photograph on-device and writes a PNG to [out]
  /// whose alpha marks them, aligned to the upright image. Returns [out], or
  /// null when nobody is found or the platform cannot segment.
  static Future<String?> segmentSubject(String path, String out) async {
    try {
      return await _ch.invokeMethod<String>('segmentSubject', {'path': path, 'out': out});
    } catch (_) {
      return null;
    }
  }

  /// Develops a RAW file with the platform RAW decoder; returns an image path.
  static Future<String?> developRaw(String path) => _ch.invokeMethod<String>('developRaw', {'path': path});
}
