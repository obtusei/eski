import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'adjustments.dart';

/// A film look: a named, tunable recipe that feeds the same engine as manual edits.
class Preset {
  const Preset({
    required this.id,
    required this.name,
    required this.collection,
    required this.adj,
    this.curves = const CurveSet(),
    this.user = false,
  });

  final String id, name, collection;
  final Adjustments adj;
  final CurveSet curves;
  final bool user;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'col': collection, 'adj': adj.toJson(), 'cv': curves.toJson()};

  factory Preset.fromJson(Map<String, dynamic> j) => Preset(
        id: j['id'] as String,
        name: j['name'] as String,
        collection: j['col'] as String? ?? 'My Looks',
        adj: Adjustments.fromJson((j['adj'] as Map?)?.cast<String, dynamic>()),
        curves: CurveSet.fromJson((j['cv'] as Map?)?.cast<String, dynamic>()),
        user: true,
      );
}

/// Shader-ready parameters for one layer of an edit.
class ResolvedLook {
  ResolvedLook(this.u, this.lutKey, this._presetCurves, this._presetK, this._userCurves);

  /// 80 floats, starting at uniform `uA` (float index 8).
  final Float32List u;
  final String lutKey;
  final CurveSet _presetCurves;
  final double _presetK;
  final CurveSet _userCurves;

  static final neutral = resolveLook();
}

Offset _tint(double hue, double sat) => Offset(hue, sat);

List<double> _tintRgb(Offset t) {
  if (t.dy == 0) return const [0, 0, 0];
  final c = HSVColor.fromAHSV(1, (t.dx % 1.0) * 360, 1, 1).toColor();
  final l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
  final k = t.dy * 0.22;
  return [(c.r - l) * k, (c.g - l) * k, (c.b - l) * k];
}

ResolvedLook resolveLook({
  Preset? preset,
  double intensity = 1,
  Adjustments adj = const Adjustments(),
  CurveSet curves = const CurveSet(),
  Adjustments? local,
}) {
  final p = preset == null ? const Adjustments() : preset.adj.scaled(intensity);
  double s(Adj a, [double lo = -1, double hi = 1]) =>
      (p[a] + adj[a] + (local?[a] ?? 0)).clamp(a.bipolar ? lo : 0, hi).toDouble();
  double pick(Adj a) => adj[a] != 0 ? adj[a] : p[a];

  final u = Float32List(80);
  var i = 0;
  void put(List<double> l) {
    for (final x in l) {
      u[i++] = x;
    }
  }

  put([s(Adj.exposure), s(Adj.brightness), s(Adj.contrast), s(Adj.highlights)]);
  put([s(Adj.shadows), s(Adj.whites), s(Adj.blacks), s(Adj.saturation)]);
  put([s(Adj.vibrance), s(Adj.temperature), s(Adj.tint), s(Adj.hue)]);
  put([s(Adj.sharpness), s(Adj.clarity), s(Adj.texture), s(Adj.dehaze)]);
  put([s(Adj.fade), s(Adj.grain), s(Adj.grainSize), s(Adj.vignette)]);
  put([s(Adj.bloom), s(Adj.glow), s(Adj.halation), s(Adj.blur)]);
  put([s(Adj.chroma), s(Adj.leak), s(Adj.dust), s(Adj.borderSize)]);
  final hslOn = p.hasHsl || adj.hasHsl;
  put([pick(Adj.borderStyle), pick(Adj.leakSeed) * 20, 0, hslOn ? 1 : 0]);

  for (final t in const [
    (Adj.shHue, Adj.shSat, Adj.shLum),
    (Adj.midHue, Adj.midSat, Adj.midLum),
    (Adj.hiHue, Adj.hiSat, Adj.hiLum),
  ]) {
    final a = _tintRgb(_tint(p[t.$1], p[t.$2]));
    final b = _tintRgb(_tint(adj[t.$1], adj[t.$2]));
    put([a[0] + b[0], a[1] + b[1], a[2] + b[2], s(t.$3)]);
  }
  put([s(Adj.balance), 0, 1, 0]);
  for (var k = 0; k < 24; k++) {
    u[i++] = (p.hsl[k] + adj.hsl[k]).clamp(-1.0, 1.0);
  }
  put([1, 0.3, 0.2, s(Adj.noise)]);
  put([s(Adj.motion), pick(Adj.motionAngle), s(Adj.smudge), s(Adj.lensBlur)]);

  final pc = preset?.curves ?? const CurveSet();
  final key = pc.isIdentity && curves.isIdentity
      ? ''
      : '${pc.key}@${pc.isIdentity ? 0 : intensity.toStringAsFixed(2)}#${curves.key}';
  return ResolvedLook(u, key, pc, intensity, curves);
}

/// Monotone cubic interpolation through control points, sampled at [n] steps.
Float64List sampleCurve(List<Offset> pts, [int n = 256]) {
  final out = Float64List(n);
  final p = [...pts]..sort((a, b) => a.dx.compareTo(b.dx));
  final k = p.length;
  if (k < 2) {
    for (var i = 0; i < n; i++) {
      out[i] = i / (n - 1);
    }
    return out;
  }
  final d = List<double>.filled(k - 1, 0), m = List<double>.filled(k, 0);
  for (var i = 0; i < k - 1; i++) {
    final dx = math.max(1e-6, p[i + 1].dx - p[i].dx);
    d[i] = (p[i + 1].dy - p[i].dy) / dx;
  }
  m[0] = d[0];
  m[k - 1] = d[k - 2];
  for (var i = 1; i < k - 1; i++) {
    m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2;
  }
  for (var i = 0; i < k - 1; i++) {
    if (d[i] == 0) {
      m[i] = 0;
      m[i + 1] = 0;
    } else {
      final a = m[i] / d[i], b = m[i + 1] / d[i];
      final h = a * a + b * b;
      if (h > 9) {
        final t = 3 / math.sqrt(h);
        m[i] = t * a * d[i];
        m[i + 1] = t * b * d[i];
      }
    }
  }
  var seg = 0;
  for (var i = 0; i < n; i++) {
    final x = i / (n - 1);
    if (x <= p.first.dx) {
      out[i] = p.first.dy;
      continue;
    }
    if (x >= p.last.dx) {
      out[i] = p.last.dy;
      continue;
    }
    while (seg < k - 2 && x > p[seg + 1].dx) {
      seg++;
    }
    final h = math.max(1e-6, p[seg + 1].dx - p[seg].dx);
    final t = (x - p[seg].dx) / h;
    final t2 = t * t, t3 = t2 * t;
    out[i] = ((2 * t3 - 3 * t2 + 1) * p[seg].dy +
            (t3 - 2 * t2 + t) * h * m[seg] +
            (-2 * t3 + 3 * t2) * p[seg + 1].dy +
            (t3 - t2) * h * m[seg + 1])
        .clamp(0.0, 1.0);
  }
  return out;
}

double _lookup(Float64List lut, double x) {
  final f = x.clamp(0.0, 1.0) * (lut.length - 1);
  final i = f.floor();
  if (i >= lut.length - 1) return lut.last;
  return lut[i] + (lut[i + 1] - lut[i]) * (f - i);
}

class LookEngine {
  static late ui.FragmentProgram program;
  static late ui.Image identityLut;
  static final _luts = <String, ui.Image>{};
  static final _pending = <String, Future<ui.Image>>{};

  /// Fires whenever a curve LUT finishes building so painters can repaint.
  static final lutReady = ValueNotifier<int>(0);

  /// All known looks (built-in and user), registered by the presets feature.
  static final presets = <String, Preset>{};
  static Preset? preset(String? id) => id == null ? null : presets[id];

  static Future<void> init() async {
    program = await ui.FragmentProgram.fromAsset('shaders/look.frag');
    identityLut = await _build(const CurveSet(), 0, const CurveSet());
  }

  static ui.FragmentShader shader() => program.fragmentShader();

  static Future<ui.Image> _build(CurveSet pc, double k, CurveSet uc) {
    final pm = sampleCurve(pc.master), um = sampleCurve(uc.master);
    final bytes = Uint8List(256 * 4);
    for (var ch = 0; ch < 3; ch++) {
      final pch = sampleCurve(pc.channel(ch + 1)), uch = sampleCurve(uc.channel(ch + 1));
      for (var i = 0; i < 256; i++) {
        final x = i / 255;
        final preset = _lookup(pch, _lookup(pm, x));
        final y = _lookup(uch, _lookup(um, x + (preset - x) * k));
        bytes[i * 4 + ch] = (y * 255).round().clamp(0, 255);
      }
    }
    for (var i = 0; i < 256; i++) {
      bytes[i * 4 + 3] = 255;
    }
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(bytes, 256, 1, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  /// Returns the LUT if built; otherwise starts building and returns identity.
  static ui.Image lutFor(ResolvedLook l) {
    if (l.lutKey.isEmpty) return identityLut;
    final hit = _luts[l.lutKey];
    if (hit != null) return hit;
    ensureLut(l).then((_) => lutReady.value++);
    return identityLut;
  }

  static Future<ui.Image> ensureLut(ResolvedLook l) {
    if (l.lutKey.isEmpty) return Future.value(identityLut);
    final hit = _luts[l.lutKey];
    if (hit != null) return Future.value(hit);
    return _pending[l.lutKey] ??= _build(l._presetCurves, l._presetK, l._userCurves).then((img) {
      if (_luts.length > 96) _luts.remove(_luts.keys.first);
      _luts[l.lutKey] = img;
      _pending.remove(l.lutKey);
      return img;
    });
  }

  /// Writes all uniforms. In [filterMode] the engine supplies size and input.
  static void apply(
    ui.FragmentShader s,
    ResolvedLook look, {
    ui.Image? image,
    Size size = const Size(1, 1),
    Rect crop = const Rect.fromLTWH(0, 0, 1, 1),
    double frameAspect = 1,
    int quarterTurns = 0,
    double scale = 1,
    double seed = 0,
    bool filterMode = false,
    bool peaking = false,
    Color accent = const Color(0xFFFF5A36),
  }) {
    s.setFloat(0, size.width);
    s.setFloat(1, size.height);
    s.setFloat(2, crop.left);
    s.setFloat(3, crop.top);
    s.setFloat(4, crop.width);
    s.setFloat(5, crop.height);
    s.setFloat(6, scale);
    s.setFloat(7, seed);
    final u = look.u;
    for (var i = 0; i < 80; i++) {
      s.setFloat(8 + i, u[i]);
    }
    s.setFloat(8 + 30, peaking ? 1 : 0);
    s.setFloat(8 + 45, filterMode ? 1 : 0);
    s.setFloat(8 + 46, frameAspect);
    s.setFloat(8 + 47, quarterTurns.toDouble());
    s.setFloat(8 + 72, accent.r);
    s.setFloat(8 + 73, accent.g);
    s.setFloat(8 + 74, accent.b);
    if (image != null) s.setImageSampler(0, image, filterQuality: ui.FilterQuality.medium);
    s.setImageSampler(1, lutFor(look), filterQuality: ui.FilterQuality.low);
  }
}
