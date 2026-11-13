import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/theme.dart';
import '../../core/image_processing/adjustments.dart';
import '../../core/image_processing/renderer.dart';
import '../../core/media/media_library.dart';
import '../../core/storage/db.dart';
import '../gallery/viewer_screen.dart';

/// Output formats as (name, width, height).
const studioFormats = [
  ('story', 1080, 1920),
  ('post', 1080, 1350),
  ('square', 1080, 1080),
  ('reel cover', 1080, 1920),
  ('wallpaper', 1290, 2796),
];

const paper = 0xFFF2EEE6, ink = 0xFF141311, cream = 0xFFE9E2D3;

class PhotoLayer {
  PhotoLayer(this.frame, {this.assetId, this.presetId});
  Rect frame; // normalised
  String? assetId, presetId;
  Offset offset = Offset.zero; // -1..1 within the overflow
  double scale = 1, rotation = 0;

  Map<String, dynamic> toJson() => {
        't': 'p',
        'f': [frame.left, frame.top, frame.right, frame.bottom],
        'a': assetId,
        'p': presetId,
        'o': [offset.dx, offset.dy],
        's': scale,
        'r': rotation,
      };
}

class TextLayer {
  TextLayer(this.text, this.pos, {this.size = 0.05, this.color = ink, this.font = 'serif', this.auto, this.spacing = 0});
  String text;
  Offset pos; // normalised centre
  double size; // fraction of canvas width
  int color;
  String font; // serif | italic | sans | mono
  double rotation = 0, spacing;

  /// 'date' keeps the text in step with the first photograph's date.
  String? auto;

  Map<String, dynamic> toJson() => {
        't': 't',
        'x': text,
        'p': [pos.dx, pos.dy],
        's': size,
        'c': color,
        'f': font,
        'r': rotation,
        'ls': spacing,
        'au': auto,
      };
}

/// A composition: canvas, photo frames, typography and film overlays.
class Comp {
  Comp(this.name, this.w, this.h, {this.bg = paper, List<PhotoLayer>? photos, List<TextLayer>? texts})
      : photos = photos ?? [],
        texts = texts ?? [];
  String name;
  int w, h, bg;
  List<PhotoLayer> photos;
  List<TextLayer> texts;
  double grain = 0, leak = 0, dust = 0;

  Size get size => Size(w.toDouble(), h.toDouble());

  Adjustments get overlay => Adjustments({
        if (grain > 0) Adj.grain: grain,
        if (grain > 0) Adj.grainSize: 0.4,
        if (leak > 0) Adj.leak: leak,
        if (leak > 0) Adj.leakSeed: 0.35,
        if (dust > 0) Adj.dust: dust,
      });

  Map<String, dynamic> toJson({bool keepPhotos = true}) => {
        'n': name,
        'w': w,
        'h': h,
        'bg': bg,
        'g': grain,
        'lk': leak,
        'd': dust,
        'ph': [for (final p in photos) p.toJson()..['a'] = keepPhotos ? p.assetId : null],
        'tx': [for (final t in texts) t.toJson()],
      };

  factory Comp.fromJson(Map<String, dynamic> j) {
    double d(dynamic v) => (v as num).toDouble();
    final c = Comp(j['n'] as String, j['w'] as int, j['h'] as int, bg: j['bg'] as int)
      ..grain = d(j['g'])
      ..leak = d(j['lk'])
      ..dust = d(j['d']);
    for (final p in j['ph'] as List) {
      final f = p['f'] as List;
      c.photos.add(PhotoLayer(Rect.fromLTRB(d(f[0]), d(f[1]), d(f[2]), d(f[3])), assetId: p['a'] as String?, presetId: p['p'] as String?)
        ..offset = Offset(d(p['o'][0]), d(p['o'][1]))
        ..scale = d(p['s'])
        ..rotation = d(p['r']));
    }
    for (final t in j['tx'] as List) {
      c.texts.add(TextLayer(t['x'] as String, Offset(d(t['p'][0]), d(t['p'][1])),
          size: d(t['s']), color: t['c'] as int, font: t['f'] as String, auto: t['au'] as String?, spacing: d(t['ls'] ?? 0))
        ..rotation = d(t['r']));
    }
    return c;
  }

  Comp clone() => Comp.fromJson(toJson());
}

/// Built-in editorial templates, laid out for any canvas shape.
final List<(String, Comp Function(int w, int h))> studioTemplates = [
  ('full bleed', (w, h) => Comp('full bleed', w, h, bg: ink, photos: [PhotoLayer(const Rect.fromLTRB(0, 0, 1, 1))])),
  (
    'print',
    (w, h) {
      final m = 0.07, mv = m * w / h;
      return Comp('print', w, h, photos: [
        PhotoLayer(Rect.fromLTRB(m, mv, 1 - m, 1 - mv * 2.6)),
      ], texts: [
        TextLayer(formatDate(DateTime.now()), Offset(0.5, 1 - mv * 1.3), size: 0.026, font: 'mono', auto: 'date', spacing: 1.5),
      ]);
    }
  ),
  (
    'travel journal',
    (w, h) => Comp('travel journal', w, h, bg: cream, photos: [
          PhotoLayer(const Rect.fromLTRB(0.08, 0.06, 0.92, 0.66)),
        ], texts: [
          TextLayer('somewhere quiet', const Offset(0.5, 0.75), size: 0.1, font: 'italic'),
          TextLayer('N 00° 00′  ·  E 00° 00′', const Offset(0.5, 0.83), size: 0.026, font: 'mono', spacing: 2),
          TextLayer(formatDate(DateTime.now()), const Offset(0.5, 0.92), size: 0.026, font: 'mono', auto: 'date', spacing: 2),
        ])
  ),
  (
    'magazine',
    (w, h) => Comp('magazine', w, h, bg: ink, photos: [
          PhotoLayer(const Rect.fromLTRB(0, 0, 1, 1)),
        ], texts: [
          TextLayer('eski', const Offset(0.5, 0.11), size: 0.3, color: paper, font: 'serif'),
          TextLayer('ISSUE 01  ·  LESS ORDINARY MOMENTS', const Offset(0.5, 0.93), size: 0.024, color: paper, font: 'mono', spacing: 2.5),
        ])
  ),
  (
    'contact sheet',
    (w, h) {
      final rows = h / w > 1.5 ? 4 : 3;
      const mx = 0.08, gap = 0.03;
      final top = 0.1, bottom = 0.92;
      final ch = (bottom - top - gap * (rows - 1) * w / h) / rows, cw = (1 - mx * 2 - gap) / 2;
      final c = Comp('contact sheet', w, h, bg: ink);
      for (var r = 0; r < rows; r++) {
        for (var k = 0; k < 2; k++) {
          final l = mx + k * (cw + gap), t = top + r * (ch + gap * w / h);
          c.photos.add(PhotoLayer(Rect.fromLTWH(l, t, cw, ch)));
          c.texts.add(TextLayer('${r * 2 + k + 1}A', Offset(l + 0.03, t + ch + 0.012 * w / h), size: 0.018, color: 0xFFE8A13A, font: 'mono'));
        }
      }
      c.texts.add(TextLayer('ESKI 400  ·  SAFETY FILM', const Offset(0.5, 0.05), size: 0.024, color: 0xFFE8A13A, font: 'mono', spacing: 3));
      c.grain = 0.2;
      return c;
    }
  ),
  (
    'diptych',
    (w, h) => Comp('diptych', w, h, photos: [
          PhotoLayer(const Rect.fromLTRB(0.06, 0.05, 0.94, 0.485)),
          PhotoLayer(const Rect.fromLTRB(0.06, 0.515, 0.94, 0.95)),
        ])
  ),
  (
    'triptych',
    (w, h) => Comp('triptych', w, h, bg: ink, photos: [
          PhotoLayer(const Rect.fromLTRB(0.06, 0.05, 0.94, 0.335)),
          PhotoLayer(const Rect.fromLTRB(0.06, 0.357, 0.94, 0.643)),
          PhotoLayer(const Rect.fromLTRB(0.06, 0.665, 0.94, 0.95)),
        ])
  ),
  (
    'four up',
    (w, h) => Comp('four up', w, h, photos: [
          PhotoLayer(const Rect.fromLTRB(0.05, 0.05, 0.49, 0.49)),
          PhotoLayer(const Rect.fromLTRB(0.51, 0.05, 0.95, 0.49)),
          PhotoLayer(const Rect.fromLTRB(0.05, 0.51, 0.49, 0.95)),
          PhotoLayer(const Rect.fromLTRB(0.51, 0.51, 0.95, 0.95)),
        ])
  ),
  (
    'instant',
    (w, h) {
      final side = 0.8, sh = side * w / h, top = (1 - sh * 1.22) / 2;
      return Comp('instant', w, h, bg: cream, photos: [
        PhotoLayer(Rect.fromLTWH(0.1, top, side, sh)),
      ], texts: [
        TextLayer('a small note', Offset(0.5, top + sh * 1.12), size: 0.07, font: 'italic'),
      ]);
    }
  ),
  (
    'cinema',
    (w, h) {
      final fh = (1 / 2.39) * w / h;
      return Comp('cinema', w, h, bg: 0xFF050505, photos: [
        PhotoLayer(Rect.fromLTWH(0, 0.5 - fh / 2, 1, fh)),
      ], texts: [
        TextLayer('— and then the light changed.', Offset(0.5, 0.5 + fh / 2 + 0.05), size: 0.034, color: paper, font: 'italic'),
      ])
        ..grain = 0.25;
    }
  ),
];

TextStyle studioTextStyle(TextLayer t, double width) => TextStyle(
      fontFamily: switch (t.font) { 'sans' => sans, 'mono' => mono, _ => serif },
      fontStyle: t.font == 'italic' ? FontStyle.italic : FontStyle.normal,
      fontVariations: t.font == 'sans' ? const [FontVariation('wght', 600)] : null,
      fontSize: t.size * width,
      height: 1.05,
      letterSpacing: t.spacing * t.size * width * 0.06,
      color: Color(t.color),
    );

TextPainter layoutText(TextLayer t, Size size) => TextPainter(
      text: TextSpan(text: t.text, style: studioTextStyle(t, size.width)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width * 0.96);

Rect textRect(TextLayer t, Size size) {
  final tp = layoutText(t, size);
  final r = Rect.fromCenter(center: Offset(t.pos.dx * size.width, t.pos.dy * size.height), width: tp.width, height: tp.height);
  tp.dispose();
  return r.inflate(size.width * 0.02);
}

/// Paints a composition at any size; used for previews and for export.
class CompPainter {
  final _renderers = <int, EditRenderer>{};

  void dispose() {
    for (final r in _renderers.values) {
      r.dispose();
    }
  }

  void paint(
    Canvas canvas,
    Size size,
    Comp comp, {
    required ui.Image? Function(String assetId) image,
    required EditState? Function(String assetId) editOf,
    ui.Image? Function(String assetId)? overlayOf,
    Color placeholder = const Color(0x22888888),
    bool guides = false,
  }) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Color(comp.bg));
    for (final (i, p) in comp.photos.indexed) {
      final fr = Rect.fromLTRB(p.frame.left * size.width, p.frame.top * size.height, p.frame.right * size.width, p.frame.bottom * size.height);
      final img = p.assetId == null ? null : image(p.assetId!);
      if (img == null) {
        canvas.drawRect(fr, Paint()..color = placeholder);
        if (guides) {
          final line = Paint()
            ..color = placeholder.withValues(alpha: 0.9)
            ..strokeWidth = math.max(1, size.width * 0.002);
          final c = fr.center, l = math.min(fr.width, fr.height) * 0.08;
          canvas.drawLine(c - Offset(l, 0), c + Offset(l, 0), line);
          canvas.drawLine(c - Offset(0, l), c + Offset(0, l), line);
        }
        continue;
      }
      final saved = editOf(p.assetId!);
      final edit = p.presetId != null
          ? EditState(presetId: p.presetId, geo: saved?.geo ?? const Geometry(), dx: saved?.dx, portrait: saved?.portrait)
          : (saved ?? const EditState());
      final cs = frameSize(Size(img.width.toDouble(), img.height.toDouble()), edit.geo);
      final k = math.max(fr.width / cs.width, fr.height / cs.height) * p.scale;
      final d = cs * k;
      final center = fr.center + Offset(p.offset.dx * (d.width - fr.width) / 2, p.offset.dy * (d.height - fr.height) / 2);
      canvas.save();
      canvas.clipRect(fr);
      canvas.translate(center.dx, center.dy);
      canvas.rotate(p.rotation);
      canvas.translate(-d.width / 2, -d.height / 2);
      (_renderers[i] ??= EditRenderer()).paint(
        canvas,
        d,
        img,
        edit,
        quality: ui.FilterQuality.high,
        overlay: overlayOf?.call(p.assetId!) ?? Overlays.of(edit.dx, img),
      );
      canvas.restore();
    }
    for (final t in comp.texts) {
      if (t.text.isEmpty) continue;
      final tp = layoutText(t, size);
      canvas.save();
      canvas.translate(t.pos.dx * size.width, t.pos.dy * size.height);
      canvas.rotate(t.rotation);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
      tp.dispose();
    }
  }
}

/// Templates the user saved for reuse.
class SavedTemplates extends Notifier<List<Comp>> {
  @override
  List<Comp> build() {
    Db.kv('templates').then((v) {
      if (v is List) state = [for (final j in v) Comp.fromJson((j as Map).cast<String, dynamic>())];
    });
    return [];
  }

  void add(Comp c) {
    state = [...state, Comp.fromJson(c.toJson(keepPhotos: false))];
    _save();
  }

  void remove(Comp c) {
    state = [for (final t in state) if (t != c) t];
    _save();
  }

  void _save() => Db.setKv('templates', [for (final t in state) t.toJson(keepPhotos: false)]);
}

final savedTemplatesProvider = NotifierProvider<SavedTemplates, List<Comp>>(SavedTemplates.new);
