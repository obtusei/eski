import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'adjustments.dart';
import 'look_engine.dart';

/// Decodes an image file, optionally downsampled so its long edge fits [maxEdge].
Future<ui.Image> decodeImageFile(String path, {int? maxEdge}) async {
  final buf = await ui.ImmutableBuffer.fromFilePath(path);
  final desc = await ui.ImageDescriptor.encoded(buf);
  int? tw, th;
  if (maxEdge != null && math.max(desc.width, desc.height) > maxEdge) {
    if (desc.width >= desc.height) {
      tw = maxEdge;
    } else {
      th = maxEdge;
    }
  }
  final codec = await desc.instantiateCodec(targetWidth: tw, targetHeight: th);
  final frame = await codec.getNextFrame();
  codec.dispose();
  desc.dispose();
  buf.dispose();
  return frame.image;
}

/// Subject mattes for portrait blur, decoded once and shared by every
/// painter. Painters listen to [ready] to repaint once one arrives.
class Mattes {
  static final ready = ValueNotifier<int>(0);
  static final _cache = <String, ui.Image>{};
  static final _missing = <String>{};
  static final _pending = <String, Future<ui.Image?>>{};

  /// The decoded matte, or null while it loads or if it is gone.
  static ui.Image? of(String? path) {
    if (path == null || _missing.contains(path)) return null;
    final hit = _cache[path];
    if (hit != null) return hit;
    load(path).then((_) => ready.value++);
    return null;
  }

  static Future<ui.Image?> load(String? path) {
    if (path == null || _missing.contains(path)) return Future.value(null);
    final hit = _cache[path];
    if (hit != null) return Future.value(hit);
    return _pending[path] ??= () async {
      try {
        final img = await decodeImageFile(path, maxEdge: 1600);
        if (_cache.length > 16) _cache.remove(_cache.keys.first);
        return _cache[path] = img;
      } catch (_) {
        _missing.add(path);
        return null;
      } finally {
        _pending.remove(path);
      }
    }();
  }
}

/// Pixel size of the edited frame for a source of [src] pixels.
Size frameSize(Size src, Geometry g) {
  final odd = g.quarterTurns.isOdd;
  final w = odd ? src.height : src.width, h = odd ? src.width : src.height;
  return Size(w * g.crop.width, h * g.crop.height);
}

double _fill(double w, double h, Geometry g) {
  final t = g.straighten.abs();
  final rot = math.cos(t) + math.max(w / h, h / w) * math.sin(t);
  final persp = 1 / (1 - 0.25 * (g.perspX.abs() + g.perspY.abs()));
  return rot * persp;
}

/// Paints an [EditState] with the look shader. One instance per painter; it
/// pools shader objects so each layer keeps its own uniforms.
class EditRenderer {
  final _pool = <ui.FragmentShader>[];
  var _used = 0;

  // Last double-exposure composite and what it was built from.
  ui.Image? _comp, _compSrc, _compOver;
  DoubleExposure? _compDx;

  ui.Image _composite(ui.Image src, ui.Image over, DoubleExposure dx) {
    final hit = _comp;
    if (hit != null && identical(_compSrc, src) && identical(_compOver, over) && identical(_compDx, dx)) return hit;
    hit?.dispose();
    final pic = compositePicture(src, over, dx);
    final img = pic.toImageSync(src.width, src.height);
    pic.dispose();
    _compSrc = src;
    _compOver = over;
    _compDx = dx;
    return _comp = img;
  }

  ui.FragmentShader _next() {
    if (_used == _pool.length) _pool.add(LookEngine.shader());
    return _pool[_used++];
  }

  void dispose() {
    for (final s in _pool) {
      s.dispose();
    }
    _pool.clear();
    _comp?.dispose();
    _comp = _compSrc = _compOver = null;
  }

  void paint(
    Canvas canvas,
    Size out,
    ui.Image src,
    EditState st, {
    bool original = false,
    double seed = 0,
    ui.FilterQuality quality = ui.FilterQuality.medium,
    ui.Image? overlay,
  }) {
    _used = 0;
    // Both frames are merged before development, as a camera does.
    final dx = st.dx;
    if (!original && dx != null && overlay != null) src = _composite(src, overlay, dx);
    final g = st.geo;
    final sw = src.width.toDouble(), sh = src.height.toDouble();
    final odd = g.quarterTurns.isOdd;
    final fw = odd ? sh : sw, fh = odd ? sw : sh;
    final crop = g.crop;
    final cw = crop.width * fw, ch = crop.height * fh;
    final fill = _fill(fw, fh, g);
    final srcRect = Rect.fromLTWH(0, 0, sw, sh);

    canvas.save();
    canvas.clipRect(Offset.zero & out);
    canvas.scale(out.width / cw, out.height / ch);
    canvas.translate(-crop.left * fw, -crop.top * fh);
    canvas.translate(fw / 2, fh / 2);
    if (g.perspX != 0 || g.perspY != 0) {
      final m = Matrix4.identity()
        ..setEntry(3, 0, g.perspX * 0.5 / fw)
        ..setEntry(3, 1, g.perspY * 0.5 / fh);
      canvas.transform(m.storage);
    }
    canvas.rotate(g.straighten);
    canvas.scale(fill);
    canvas.rotate(g.quarterTurns * math.pi / 2);
    if (g.flipH) canvas.scale(-1, 1);
    canvas.translate(-sw / 2, -sh / 2);

    if (original) {
      canvas.drawImage(src, Offset.zero, Paint()..filterQuality = quality);
      canvas.restore();
      return;
    }

    // Where the output frame sits inside the source, for frame-space effects.
    var cx = crop.center.dx - 0.5, cy = crop.center.dy - 0.5;
    for (var i = 0; i < g.quarterTurns; i++) {
      final t = cx;
      cx = cy;
      cy = -t;
    }
    if (g.flipH) cx = -cx;
    final uw = (odd ? crop.height : crop.width) / fill, uh = (odd ? crop.width : crop.height) / fill;
    final cropUv = Rect.fromCenter(center: Offset(cx / fill + 0.5, cy / fill + 0.5), width: uw, height: uh);
    final preset = LookEngine.preset(st.presetId);

    void layer(Adjustments? local) {
      final s = _next();
      final look = resolveLook(preset: preset, intensity: st.intensity, adj: st.adj, curves: st.curves, local: local);
      LookEngine.apply(
        s,
        look,
        image: src,
        size: Size(sw, sh),
        crop: cropUv,
        frameAspect: cw / ch,
        quarterTurns: g.quarterTurns,
        seed: seed,
      );
      canvas.drawRect(srcRect, Paint()..shader = s);
    }

    layer(null);

    for (final m in st.masks) {
      if (m.adj.isNeutral) continue;
      canvas.saveLayer(srcRect, Paint());
      layer(m.adj);
      paintMaskAlpha(canvas, srcRect, m, ui.BlendMode.dstIn);
      canvas.restore();
    }

    // Portrait: a lens-blurred layer with the subject cut out of it.
    final pb = st.portrait;
    if (pb != null && pb.amount > 0) {
      final matte = Mattes.of(pb.matte);
      if (pb.matte == null || matte != null) {
        canvas.saveLayer(srcRect, Paint());
        layer(Adjustments({Adj.lensBlur: pb.amount}));
        paintSubjectCut(canvas, srcRect, pb, matte);
        canvas.restore();
      }
    }
    canvas.restore();
  }
}

/// Removes the subject from the current layer: through the matte's alpha,
/// softened by the feather, or outside the radial focus area.
void paintSubjectCut(Canvas canvas, Rect r, PortraitBlur pb, ui.Image? matte) {
  if (matte == null) {
    paintMaskAlpha(canvas, r, pb.area, ui.BlendMode.dstIn);
    return;
  }
  final sigma = 0.5 + pb.feather * r.shortestSide * 0.008;
  canvas.drawImageRect(
    matte,
    Rect.fromLTWH(0, 0, matte.width.toDouble(), matte.height.toDouble()),
    r,
    Paint()
      ..blendMode = ui.BlendMode.dstOut
      ..filterQuality = ui.FilterQuality.medium
      ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
  );
}

/// Draws a mask's coverage. With [ui.BlendMode.dstIn] it cuts the current
/// layer; with srcOver and a [tint] it draws an overlay for the mask editor.
void paintMaskAlpha(Canvas canvas, Rect r, MaskLayer m, ui.BlendMode mode, {Color tint = const Color(0xFFFFFFFF)}) {
  final clear = tint.withValues(alpha: 0);
  Offset px(Offset n) => Offset(r.left + n.dx * r.width, r.top + n.dy * r.height);
  switch (m.type) {
    case MaskType.linear:
      final paint = Paint()
        ..blendMode = mode
        ..shader = ui.Gradient.linear(px(m.a), px(m.b), m.invert ? [clear, tint] : [tint, clear]);
      canvas.drawRect(r, paint);
    case MaskType.radial:
      final inner = (1 - m.feather).clamp(0.0, 0.98);
      final paint = Paint()
        ..blendMode = mode
        ..shader = ui.Gradient.radial(
          px(m.a),
          math.max(1, m.radius * r.width),
          m.invert ? [clear, clear, tint] : [tint, tint, clear],
          [0, inner, 1],
        );
      canvas.drawRect(r, paint);
    case MaskType.brush:
      canvas.saveLayer(r, Paint()..blendMode = mode);
      if (m.invert) canvas.drawRect(r, Paint()..color = tint);
      final width = math.max(1.0, m.radius * r.width * 0.5);
      final paint = Paint()
        ..color = tint
        ..blendMode = m.invert ? ui.BlendMode.dstOut : ui.BlendMode.srcOver
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = width
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 0.35 * m.feather + 0.01);
      for (final s in m.strokes) {
        if (s.isEmpty) continue;
        final path = Path()..moveTo(px(s.first).dx, px(s.first).dy);
        for (final p in s.skip(1)) {
          path.lineTo(px(p).dx, px(p).dy);
        }
        if (s.length == 1) path.lineTo(px(s.first).dx + 0.01, px(s.first).dy);
        canvas.drawPath(path, paint);
      }
      canvas.restore();
  }
}

/// Luminance key as a colour matrix: alpha follows brightness for [tone] > 0
/// and darkness for [tone] < 0, with extra contrast as the key strengthens.
ColorFilter? _toneKey(double tone) {
  if (tone == 0) return null;
  final s = tone.abs(), c = 1 + 1.5 * s;
  const w = [0.2126, 0.7152, 0.0722];
  final sign = tone > 0 ? 1.0 : -1.0;
  final offset = tone > 0 ? (1 - s) - s * (c - 1) / 2 : 1 + s * (c - 1) / 2;
  return ColorFilter.matrix([
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    sign * s * c * w[0], sign * s * c * w[1], sign * s * c * w[2], 0, offset * 255,
  ]);
}

/// Exposes [over] onto whatever is already drawn in [r] (the base frame):
/// placed, keyed, masked, then blended at its opacity.
void paintDoubleExposure(Canvas canvas, Rect r, ui.Image over, DoubleExposure d, {ui.FilterQuality quality = ui.FilterQuality.medium}) {
  if (d.opacity <= 0) return;
  canvas.saveLayer(
    r,
    Paint()
      ..blendMode = d.blend.mode
      ..color = Color.fromRGBO(0, 0, 0, d.opacity.clamp(0.0, 1.0)),
  );
  canvas.clipRect(r);
  final ow = over.width.toDouble(), oh = over.height.toDouble();
  final k = math.max(r.width / ow, r.height / oh) * d.scale;
  canvas.save();
  canvas.translate(r.left + r.width * (0.5 + d.offset.dx), r.top + r.height * (0.5 + d.offset.dy));
  canvas.rotate(d.rotation);
  canvas.scale(d.flipH ? -k : k, k);
  final paint = Paint()..filterQuality = quality;
  final key = _toneKey(d.tone);
  if (key != null) paint.colorFilter = key;
  canvas.drawImage(over, Offset(-ow / 2, -oh / 2), paint);
  canvas.restore();
  final m = d.mask;
  if (m != null) paintMaskAlpha(canvas, r, m, ui.BlendMode.dstIn);
  canvas.restore();
}

/// The base frame with the second exposure merged in, at the base's size.
ui.Picture compositePicture(ui.Image base, ui.Image over, DoubleExposure d) {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  final r = Rect.fromLTWH(0, 0, base.width.toDouble(), base.height.toDouble());
  canvas.drawImage(base, Offset.zero, Paint());
  paintDoubleExposure(canvas, r, over, d, quality: ui.FilterQuality.high);
  return rec.endRecording();
}

/// Renders the edit at full quality. The long edge is limited to [maxEdge].
/// [overlay] is the second frame of a double exposure, if the edit has one.
Future<ui.Image> renderEdit(ui.Image src, EditState st, {int maxEdge = 8192, ui.Image? overlay}) async {
  await Mattes.load(st.portrait?.matte);
  final dx = st.dx;
  if (dx != null && overlay != null) {
    final pic = compositePicture(src, overlay, dx);
    final merged = await pic.toImage(src.width, src.height);
    pic.dispose();
    try {
      return await renderEdit(merged, st.copyWith(dx: null), maxEdge: maxEdge);
    } finally {
      merged.dispose();
    }
  }
  final preset = LookEngine.preset(st.presetId);
  await LookEngine.ensureLut(resolveLook(preset: preset, intensity: st.intensity, curves: st.curves));
  var size = frameSize(Size(src.width.toDouble(), src.height.toDouble()), st.geo);
  final k = math.min(1.0, maxEdge / math.max(size.width, size.height));
  size = Size((size.width * k).roundToDouble(), (size.height * k).roundToDouble());
  final rec = ui.PictureRecorder();
  final r = EditRenderer();
  r.paint(Canvas(rec), size, src, st, quality: ui.FilterQuality.high);
  final pic = rec.endRecording();
  try {
    return await pic.toImage(size.width.toInt(), size.height.toInt());
  } finally {
    pic.dispose();
    r.dispose();
  }
}
