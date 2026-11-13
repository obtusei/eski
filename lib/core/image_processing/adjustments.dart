import 'dart:math' as math;
import 'dart:ui';

const _u = Object();

/// Every scalar parameter of the look engine. All values are neutral at 0.
/// [bipolar] parameters range -1..1, the rest 0..1.
enum Adj {
  exposure('exposure', true),
  brightness('brightness', true),
  contrast('contrast', true),
  highlights('highlights', true),
  shadows('shadows', true),
  whites('whites', true),
  blacks('blacks', true),
  saturation('saturation', true),
  vibrance('vibrance', true),
  temperature('temperature', true),
  tint('tint', true),
  hue('hue', true),
  sharpness('sharpness', false),
  clarity('clarity', true),
  texture('texture', true),
  dehaze('dehaze', true),
  fade('fade', false),
  grain('grain', false),
  grainSize('grain size', false),
  vignette('vignette', true),
  bloom('bloom', false),
  glow('glow', false),
  halation('halation', false),
  blur('blur', false),
  chroma('aberration', false),
  leak('light leak', false),
  leakSeed('leak shape', false),
  dust('dust', false),
  borderStyle('border', false),
  borderSize('border size', false),
  shHue('shadow hue', false),
  shSat('shadow tint', false),
  shLum('shadow level', true),
  midHue('midtone hue', false),
  midSat('midtone tint', false),
  midLum('midtone level', true),
  hiHue('highlight hue', false),
  hiSat('highlight tint', false),
  hiLum('highlight level', true),
  balance('balance', true),
  noise('noise', false),
  motion('motion blur', false),
  motionAngle('motion angle', false),
  smudge('smudge', false),

  /// Background blur for portrait shots; applied only through the subject cut-out.
  lensBlur('lens blur', false);

  const Adj(this.label, this.bipolar);
  final String label;
  final bool bipolar;

  double get min => bipolar ? -1 : 0;

  /// Parameters that select rather than scale; not multiplied by intensity.
  bool get discrete =>
      this == shHue || this == midHue || this == hiHue || this == leakSeed || this == borderStyle || this == motionAngle;
}

const lightAdjs = [
  Adj.exposure, Adj.brightness, Adj.contrast, Adj.highlights, Adj.shadows, Adj.whites, Adj.blacks, //
];
const colorAdjs = [Adj.temperature, Adj.tint, Adj.saturation, Adj.vibrance, Adj.hue];
const detailAdjs = [Adj.sharpness, Adj.clarity, Adj.texture, Adj.dehaze, Adj.fade];
const effectAdjs = [
  Adj.grain, Adj.grainSize, Adj.noise, Adj.vignette, Adj.bloom, Adj.glow, Adj.halation, Adj.blur, Adj.motion, //
  Adj.motionAngle, Adj.smudge, Adj.chroma, Adj.leak, Adj.dust,
];
const maskAdjs = [
  Adj.exposure, Adj.contrast, Adj.highlights, Adj.shadows, Adj.saturation, Adj.temperature, Adj.tint, //
  Adj.clarity, Adj.sharpness, Adj.dehaze, Adj.blur,
];

const hslBandNames = ['red', 'orange', 'yellow', 'green', 'aqua', 'blue', 'purple', 'magenta'];
const hslBandColors = [
  Color(0xFFE5484D), Color(0xFFF08A3C), Color(0xFFE8C63A), Color(0xFF55B36A), //
  Color(0xFF3FBFC0), Color(0xFF3F7FE0), Color(0xFF8E5BD8), Color(0xFFD957B4),
];

const List<double> _zero24 = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
];

class Adjustments {
  const Adjustments([this.v = const {}, this.hsl = _zero24]);

  final Map<Adj, double> v;

  /// 24 values: hue[0..8), saturation[8..16), luminance[16..24).
  final List<double> hsl;

  double operator [](Adj a) => v[a] ?? 0;

  Adjustments set(Adj a, double x) {
    final m = Map<Adj, double>.of(v);
    if (x == 0) {
      m.remove(a);
    } else {
      m[a] = x;
    }
    return Adjustments(m, hsl);
  }

  Adjustments setHsl(int index, double x) {
    final l = List<double>.of(hsl);
    l[index] = x;
    return Adjustments(v, l);
  }

  bool get hasHsl => hsl.any((e) => e != 0);
  bool get isNeutral => v.isEmpty && !hasHsl;

  /// Scales every continuous parameter (used for preset intensity).
  Adjustments scaled(double k) => Adjustments(
        {for (final e in v.entries) e.key: e.key.discrete ? e.value : e.value * k},
        [for (final x in hsl) x * k],
      );

  Map<String, dynamic> toJson() => {
        'v': {for (final e in v.entries) e.key.name: e.value},
        if (hasHsl) 'hsl': hsl,
      };

  factory Adjustments.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const Adjustments();
    final m = <Adj, double>{};
    (j['v'] as Map? ?? {}).forEach((k, val) {
      for (final a in Adj.values) {
        if (a.name == k) m[a] = (val as num).toDouble();
      }
    });
    final h = (j['hsl'] as List?)?.map((e) => (e as num).toDouble()).toList();
    return Adjustments(m, h != null && h.length == 24 ? h : _zero24);
  }
}

const List<Offset> identityCurve = [Offset(0, 0), Offset(1, 1)];

List<Offset> _pts(dynamic j) {
  if (j is! List || j.length < 4) return identityCurve;
  return [for (var i = 0; i + 1 < j.length; i += 2) Offset((j[i] as num).toDouble(), (j[i + 1] as num).toDouble())];
}

List<double> _flat(List<Offset> p) => [for (final o in p) ...[o.dx, o.dy]];

bool _isIdentity(List<Offset> p) =>
    p.length == 2 && p[0] == const Offset(0, 0) && p[1] == const Offset(1, 1);

class CurveSet {
  const CurveSet({
    this.master = identityCurve,
    this.r = identityCurve,
    this.g = identityCurve,
    this.b = identityCurve,
  });

  final List<Offset> master, r, g, b;

  bool get isIdentity => _isIdentity(master) && _isIdentity(r) && _isIdentity(g) && _isIdentity(b);

  List<Offset> channel(int i) => [master, r, g, b][i];

  CurveSet withChannel(int i, List<Offset> p) => CurveSet(
        master: i == 0 ? p : master,
        r: i == 1 ? p : r,
        g: i == 2 ? p : g,
        b: i == 3 ? p : b,
      );

  String get key => isIdentity ? '' : [master, r, g, b].map((c) => _flat(c).map((e) => e.toStringAsFixed(3)).join(',')).join('|');

  Map<String, dynamic> toJson() => {'m': _flat(master), 'r': _flat(r), 'g': _flat(g), 'b': _flat(b)};

  factory CurveSet.fromJson(Map<String, dynamic>? j) => j == null
      ? const CurveSet()
      : CurveSet(master: _pts(j['m']), r: _pts(j['r']), g: _pts(j['g']), b: _pts(j['b']));
}

class Geometry {
  const Geometry({
    this.flipH = false,
    this.quarterTurns = 0,
    this.straighten = 0,
    this.perspX = 0,
    this.perspY = 0,
    this.crop = const Rect.fromLTRB(0, 0, 1, 1),
  });

  final bool flipH;
  final int quarterTurns;

  /// Radians, within ±45°.
  final double straighten;
  final double perspX, perspY;

  /// Normalised crop inside the rotated frame.
  final Rect crop;

  bool get isIdentity =>
      !flipH && quarterTurns == 0 && straighten == 0 && perspX == 0 && perspY == 0 && crop == const Rect.fromLTRB(0, 0, 1, 1);

  Geometry copyWith({bool? flipH, int? quarterTurns, double? straighten, double? perspX, double? perspY, Rect? crop}) =>
      Geometry(
        flipH: flipH ?? this.flipH,
        quarterTurns: (quarterTurns ?? this.quarterTurns) % 4,
        straighten: straighten ?? this.straighten,
        perspX: perspX ?? this.perspX,
        perspY: perspY ?? this.perspY,
        crop: crop ?? this.crop,
      );

  Map<String, dynamic> toJson() => {
        'f': flipH,
        'q': quarterTurns,
        's': straighten,
        'px': perspX,
        'py': perspY,
        'c': [crop.left, crop.top, crop.right, crop.bottom],
      };

  factory Geometry.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const Geometry();
    final c = (j['c'] as List?)?.map((e) => (e as num).toDouble()).toList();
    return Geometry(
      flipH: j['f'] == true,
      quarterTurns: (j['q'] as num?)?.toInt() ?? 0,
      straighten: (j['s'] as num?)?.toDouble() ?? 0,
      perspX: (j['px'] as num?)?.toDouble() ?? 0,
      perspY: (j['py'] as num?)?.toDouble() ?? 0,
      crop: c != null && c.length == 4 ? Rect.fromLTRB(c[0], c[1], c[2], c[3]) : const Rect.fromLTRB(0, 0, 1, 1),
    );
  }
}

enum MaskType { linear, radial, brush }

/// A local adjustment. Coordinates are normalised to the source image.
class MaskLayer {
  const MaskLayer({
    required this.type,
    this.a = const Offset(0.5, 0.25),
    this.b = const Offset(0.5, 0.75),
    this.radius = 0.3,
    this.feather = 0.5,
    this.invert = false,
    this.strokes = const [],
    this.adj = const Adjustments(),
  });

  final MaskType type;

  /// linear: full effect at [a] fading to none at [b]. radial: centre [a].
  final Offset a, b;
  final double radius, feather;
  final bool invert;
  final List<List<Offset>> strokes;
  final Adjustments adj;

  MaskLayer copyWith({Offset? a, Offset? b, double? radius, double? feather, bool? invert, List<List<Offset>>? strokes, Adjustments? adj}) =>
      MaskLayer(
        type: type,
        a: a ?? this.a,
        b: b ?? this.b,
        radius: radius ?? this.radius,
        feather: feather ?? this.feather,
        invert: invert ?? this.invert,
        strokes: strokes ?? this.strokes,
        adj: adj ?? this.adj,
      );

  Map<String, dynamic> toJson() => {
        't': type.index,
        'a': [a.dx, a.dy],
        'b': [b.dx, b.dy],
        'r': radius,
        'fe': feather,
        'i': invert,
        if (strokes.isNotEmpty) 's': [for (final s in strokes) _flat(s)],
        'adj': adj.toJson(),
      };

  factory MaskLayer.fromJson(Map<String, dynamic> j) {
    Offset o(dynamic l) => Offset((l[0] as num).toDouble(), (l[1] as num).toDouble());
    return MaskLayer(
      type: MaskType.values[(j['t'] as num).toInt()],
      a: o(j['a']),
      b: o(j['b']),
      radius: (j['r'] as num).toDouble(),
      feather: (j['fe'] as num).toDouble(),
      invert: j['i'] == true,
      strokes: [
        for (final s in (j['s'] as List? ?? []))
          [for (var i = 0; i + 1 < (s as List).length; i += 2) Offset((s[i] as num).toDouble(), (s[i + 1] as num).toDouble())],
      ],
      adj: Adjustments.fromJson((j['adj'] as Map?)?.cast<String, dynamic>()),
    );
  }
}

/// How the second frame of a double exposure combines with the first.
enum ExposureBlend {
  screen('screen', BlendMode.screen),
  lighten('lighten', BlendMode.lighten),
  add('add', BlendMode.plus),
  softLight('soft light', BlendMode.softLight),
  overlay('overlay', BlendMode.overlay),
  multiply('multiply', BlendMode.multiply),
  darken('darken', BlendMode.darken),
  difference('difference', BlendMode.difference);

  const ExposureBlend(this.label, this.mode);
  final String label;
  final BlendMode mode;
}

/// A second photograph exposed onto the first, as on a film camera's
/// multiple-exposure mode. Geometry is normalised to the base source image:
/// [offset] moves the frame centre, [scale] is relative to filling the base.
class DoubleExposure {
  const DoubleExposure({
    required this.assetId,
    this.blend = ExposureBlend.screen,
    this.opacity = 0.8,
    this.tone = 0,
    this.offset = Offset.zero,
    this.scale = 1,
    this.rotation = 0,
    this.flipH = false,
    this.mask,
  });

  final String assetId;
  final ExposureBlend blend;
  final double opacity;

  /// Luminance key on the second frame: above 0 keeps its highlights,
  /// below 0 its shadows.
  final double tone;
  final Offset offset;
  final double scale, rotation;
  final bool flipH;

  /// Where the second frame shows; null exposes it everywhere.
  final MaskLayer? mask;

  DoubleExposure copyWith({
    String? assetId,
    ExposureBlend? blend,
    double? opacity,
    double? tone,
    Offset? offset,
    double? scale,
    double? rotation,
    bool? flipH,
    Object? mask = _u,
  }) =>
      DoubleExposure(
        assetId: assetId ?? this.assetId,
        blend: blend ?? this.blend,
        opacity: opacity ?? this.opacity,
        tone: tone ?? this.tone,
        offset: offset ?? this.offset,
        scale: scale ?? this.scale,
        rotation: rotation ?? this.rotation,
        flipH: flipH ?? this.flipH,
        mask: mask == _u ? this.mask : mask as MaskLayer?,
      );

  Map<String, dynamic> toJson() => {
        'a': assetId,
        'b': blend.name,
        'o': opacity,
        't': tone,
        'xy': [offset.dx, offset.dy],
        's': scale,
        'r': rotation,
        'f': flipH,
        if (mask != null) 'm': mask!.toJson(),
      };

  factory DoubleExposure.fromJson(Map<String, dynamic> j) {
    double d(dynamic v, double fallback) => (v as num?)?.toDouble() ?? fallback;
    final xy = j['xy'] as List?;
    return DoubleExposure(
      assetId: j['a'] as String,
      blend: ExposureBlend.values.where((b) => b.name == j['b']).firstOrNull ?? ExposureBlend.screen,
      opacity: d(j['o'], 0.8),
      tone: d(j['t'], 0),
      offset: xy == null ? Offset.zero : Offset(d(xy[0], 0), d(xy[1], 0)),
      scale: d(j['s'], 1),
      rotation: d(j['r'], 0),
      flipH: j['f'] == true,
      mask: j['m'] == null ? null : MaskLayer.fromJson((j['m'] as Map).cast<String, dynamic>()),
    );
  }
}

/// Portrait blur: the background is rendered through a wide lens blur while
/// the subject stays sharp. The subject comes from an on-device person
/// [matte] when one was found, otherwise from a radial focus area.
class PortraitBlur {
  const PortraitBlur({
    this.amount = 0.6,
    this.matte,
    this.center = const Offset(0.5, 0.45),
    this.radius = 0.3,
    this.feather = 0.5,
  });

  /// 0..1, shown as an aperture from f/16 to f/1.2.
  final double amount;

  /// Path of a PNG whose alpha marks the subject, aligned to the source.
  final String? matte;

  /// Focus area, normalised to the source, used without a matte.
  final Offset center;
  final double radius, feather;

  double get fNumber => 16 * math.pow(1.2 / 16, amount).toDouble();

  /// The focus area as a mask that covers the background.
  MaskLayer get area => MaskLayer(type: MaskType.radial, a: center, radius: radius, feather: feather, invert: true);

  PortraitBlur copyWith({double? amount, Object? matte = _u, Offset? center, double? radius, double? feather}) => PortraitBlur(
        amount: amount ?? this.amount,
        matte: matte == _u ? this.matte : matte as String?,
        center: center ?? this.center,
        radius: radius ?? this.radius,
        feather: feather ?? this.feather,
      );

  Map<String, dynamic> toJson() => {
        'a': amount,
        if (matte != null) 'm': matte,
        'c': [center.dx, center.dy],
        'r': radius,
        'f': feather,
      };

  factory PortraitBlur.fromJson(Map<String, dynamic> j) {
    final c = j['c'] as List?;
    return PortraitBlur(
      amount: (j['a'] as num?)?.toDouble() ?? 0.6,
      matte: j['m'] as String?,
      center: c == null ? const Offset(0.5, 0.45) : Offset((c[0] as num).toDouble(), (c[1] as num).toDouble()),
      radius: (j['r'] as num?)?.toDouble() ?? 0.3,
      feather: (j['f'] as num?)?.toDouble() ?? 0.5,
    );
  }
}

/// The complete non-destructive recipe for one photograph.
class EditState {
  const EditState({
    this.presetId,
    this.intensity = 1,
    this.adj = const Adjustments(),
    this.curves = const CurveSet(),
    this.geo = const Geometry(),
    this.masks = const [],
    this.dx,
    this.portrait,
  });

  final String? presetId;
  final double intensity;
  final Adjustments adj;
  final CurveSet curves;
  final Geometry geo;
  final List<MaskLayer> masks;

  /// Double exposure; null for a single frame.
  final DoubleExposure? dx;

  /// Background blur around a sharp subject; null when off.
  final PortraitBlur? portrait;

  bool get isNeutral =>
      presetId == null &&
      adj.isNeutral &&
      curves.isIdentity &&
      geo.isIdentity &&
      masks.isEmpty &&
      dx == null &&
      portrait == null;

  EditState copyWith({
    String? presetId,
    bool clearPreset = false,
    double? intensity,
    Adjustments? adj,
    CurveSet? curves,
    Geometry? geo,
    List<MaskLayer>? masks,
    Object? dx = _u,
    Object? portrait = _u,
  }) =>
      EditState(
        presetId: clearPreset ? null : presetId ?? this.presetId,
        intensity: intensity ?? this.intensity,
        adj: adj ?? this.adj,
        curves: curves ?? this.curves,
        geo: geo ?? this.geo,
        masks: masks ?? this.masks,
        dx: dx == _u ? this.dx : dx as DoubleExposure?,
        portrait: portrait == _u ? this.portrait : portrait as PortraitBlur?,
      );

  Map<String, dynamic> toJson() => {
        if (presetId != null) 'p': presetId,
        'i': intensity,
        'adj': adj.toJson(),
        if (!curves.isIdentity) 'cv': curves.toJson(),
        if (!geo.isIdentity) 'geo': geo.toJson(),
        if (masks.isNotEmpty) 'masks': [for (final m in masks) m.toJson()],
        if (dx != null) 'dx': dx!.toJson(),
        if (portrait != null) 'pb': portrait!.toJson(),
      };

  factory EditState.fromJson(Map<String, dynamic> j) => EditState(
        presetId: j['p'] as String?,
        intensity: (j['i'] as num?)?.toDouble() ?? 1,
        adj: Adjustments.fromJson((j['adj'] as Map?)?.cast<String, dynamic>()),
        curves: CurveSet.fromJson((j['cv'] as Map?)?.cast<String, dynamic>()),
        geo: Geometry.fromJson((j['geo'] as Map?)?.cast<String, dynamic>()),
        masks: [for (final m in (j['masks'] as List? ?? [])) MaskLayer.fromJson((m as Map).cast<String, dynamic>())],
        dx: j['dx'] == null ? null : DoubleExposure.fromJson((j['dx'] as Map).cast<String, dynamic>()),
        portrait: j['pb'] == null ? null : PortraitBlur.fromJson((j['pb'] as Map).cast<String, dynamic>()),
      );
}
