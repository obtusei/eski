import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/theme.dart';
import '../../core/image_processing/adjustments.dart';
import '../../core/image_processing/look_engine.dart';
import '../../core/image_processing/renderer.dart';
import '../../shared/widgets/common.dart';

const borderStyles = ['none', 'white', 'black', 'print', '35mm'];

/// A value chip in a tool's parameter row.
class ParamChip extends StatelessWidget {
  const ParamChip({super.key, required this.label, required this.value, required this.active, required this.onTap});
  final String label, value;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final changed = value != '0' && value != '—';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(value, style: context.num(changed ? c.accentInk : c.faint, 11.5)),
            const SizedBox(height: 4),
            Text(label, style: context.label(active ? c.text : c.dim, 11.5)),
            const SizedBox(height: 4),
            Container(width: 14, height: 1.5, color: active ? c.text : Colors.transparent),
          ],
        ),
      ),
    );
  }
}

String _pct(double v) => v == 0 ? '0' : '${v > 0 ? '+' : ''}${(v * 100).round()}';

/// Generic adjustment tool: one ruler, a scrolling row of parameters.
class AdjPanel extends StatefulWidget {
  const AdjPanel({super.key, required this.adjs, required this.values, required this.onChanged, required this.onEnd});
  final List<Adj> adjs;
  final Adjustments values;
  final void Function(Adj, double) onChanged;
  final VoidCallback onEnd;

  @override
  State<AdjPanel> createState() => _AdjPanelState();
}

class _AdjPanelState extends State<AdjPanel> {
  late Adj _sel = widget.adjs.first;

  @override
  Widget build(BuildContext context) {
    if (!widget.adjs.contains(_sel)) _sel = widget.adjs.first;
    final v = widget.values[_sel];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_sel == Adj.borderStyle)
          SizedBox(
            height: 44,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < borderStyles.length; i++)
                  TextTab(borderStyles[i], active: v.round() == i, onTap: () {
                    widget.onChanged(Adj.borderStyle, i.toDouble());
                    if (i > 0 && widget.values[Adj.borderSize] == 0) widget.onChanged(Adj.borderSize, 0.4);
                    widget.onEnd();
                  }),
              ],
            ),
          )
        else
          Ruler(
            value: v,
            min: _sel.min,
            max: 1,
            onChanged: (x) => widget.onChanged(_sel, x),
            onEnd: widget.onEnd,
          ),
        SizedBox(
          height: 58,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              for (final a in widget.adjs)
                ParamChip(
                  label: a.label,
                  value: switch (a) {
                    Adj.borderStyle => borderStyles[widget.values[a].round()],
                    Adj.motionAngle => widget.values[a] == 0 ? '0' : '${(widget.values[a] * 180).round()}°',
                    _ => _pct(widget.values[a]),
                  },
                  active: a == _sel,
                  onTap: () => setState(() => _sel = a),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Tone curve editor. Drag points, tap empty space to add, double-tap a
/// point to remove it.
class CurveEditor extends StatefulWidget {
  const CurveEditor({super.key, required this.curves, required this.onChanged, required this.onEnd});
  final CurveSet curves;
  final ValueChanged<CurveSet> onChanged;
  final VoidCallback onEnd;

  @override
  State<CurveEditor> createState() => _CurveEditorState();
}

class _CurveEditorState extends State<CurveEditor> {
  int _ch = 0;
  int? _drag;
  static const _names = ['rgb', 'red', 'green', 'blue'];
  static const _colors = [Colors.white, Color(0xFFE5484D), Color(0xFF55B36A), Color(0xFF3F7FE0)];

  List<Offset> get _pts => widget.curves.channel(_ch);

  Offset _norm(Offset local, Size s) => Offset((local.dx / s.width).clamp(0.0, 1.0), (1 - local.dy / s.height).clamp(0.0, 1.0));

  int? _near(Offset n, Size s) {
    int? best;
    var bd = 30.0;
    for (var i = 0; i < _pts.length; i++) {
      final d = Offset((_pts[i].dx - n.dx) * s.width, (_pts[i].dy - n.dy) * s.height).distance;
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    return best;
  }

  void _emit(List<Offset> p) => widget.onChanged(widget.curves.withChannel(_ch, p));

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 6),
          child: AspectRatio(
            aspectRatio: 2.1,
            child: LayoutBuilder(builder: (context, box) {
              final s = box.biggest;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) {
                  final n = _norm(d.localPosition, s);
                  var i = _near(n, s);
                  if (i == null) {
                    final p = [..._pts, n]..sort((a, b) => a.dx.compareTo(b.dx));
                    i = p.indexOf(n);
                    _emit(p);
                  }
                  _drag = i;
                },
                onPanUpdate: (d) {
                  final i = _drag;
                  if (i == null || i >= _pts.length) return;
                  final n = _norm(d.localPosition, s);
                  final p = [..._pts];
                  final end = i == 0 || i == p.length - 1;
                  final lo = i == 0 ? 0.0 : p[i - 1].dx + 0.02, hi = i == p.length - 1 ? 1.0 : p[i + 1].dx - 0.02;
                  p[i] = Offset(end ? p[i].dx : n.dx.clamp(lo, math.max(lo, hi)), n.dy);
                  _emit(p);
                },
                onPanEnd: (_) {
                  _drag = null;
                  widget.onEnd();
                },
                onDoubleTapDown: (d) {
                  final i = _near(_norm(d.localPosition, s), s);
                  if (i == null || i == 0 || i == _pts.length - 1) return;
                  HapticFeedback.lightImpact();
                  _emit([..._pts]..removeAt(i));
                  widget.onEnd();
                },
                onDoubleTap: () {},
                child: CustomPaint(painter: _CurvePainter(_pts, _colors[_ch], c.line, c.dim)),
              );
            }),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < 4; i++) TextTab(_names[i], active: _ch == i, onTap: () => setState(() => _ch = i)),
            TextTab('reset', active: false, dot: false, onTap: () {
              _emit(identityCurve);
              widget.onEnd();
            }),
          ],
        ),
      ],
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.pts, this.color, this.grid, this.diag);
  final List<Offset> pts;
  final Color color, grid, diag;

  @override
  void paint(Canvas canvas, Size size) {
    final g = Paint()
      ..color = grid
      ..strokeWidth = 0.6;
    for (var i = 0; i <= 4; i++) {
      canvas.drawLine(Offset(size.width * i / 4, 0), Offset(size.width * i / 4, size.height), g);
      canvas.drawLine(Offset(0, size.height * i / 4), Offset(size.width, size.height * i / 4), g);
    }
    canvas.drawLine(Offset(0, size.height), Offset(size.width, 0), Paint()..color = diag.withValues(alpha: 0.4)..strokeWidth = 0.6);
    final lut = sampleCurve(pts, 96);
    final path = Path();
    for (var i = 0; i < lut.length; i++) {
      final p = Offset(size.width * i / (lut.length - 1), size.height * (1 - lut[i]));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    for (final p in pts) {
      final o = Offset(p.dx * size.width, (1 - p.dy) * size.height);
      canvas.drawCircle(o, 4.5, Paint()..color = color);
      canvas.drawCircle(o, 2, Paint()..color = Colors.black);
    }
  }

  @override
  bool shouldRepaint(_CurvePainter o) => o.pts != pts || o.color != color;
}

/// Per-colour hue, saturation and luminance.
class HslPanel extends StatefulWidget {
  const HslPanel({super.key, required this.values, required this.onChanged, required this.onEnd});
  final Adjustments values;
  final void Function(int index, double v) onChanged;
  final VoidCallback onEnd;

  @override
  State<HslPanel> createState() => _HslPanelState();
}

class _HslPanelState extends State<HslPanel> {
  int _band = 0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final h = widget.values.hsl;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, name) in const ['hue', 'saturation', 'luminance'].indexed)
          Row(
            children: [
              SizedBox(width: 86, child: Padding(padding: const EdgeInsets.only(left: 22), child: Text(name, style: context.label(c.dim, 11)))),
              Expanded(
                child: Ruler(
                  value: h[i * 8 + _band],
                  height: 34,
                  onChanged: (v) => widget.onChanged(i * 8 + _band, v),
                  onEnd: widget.onEnd,
                ),
              ),
              SizedBox(width: 44, child: Text(_pct(h[i * 8 + _band]), style: context.num(c.dim))),
            ],
          ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var b = 0; b < 8; b++)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _band = b),
                child: Semantics(
                  label: hslBandNames[b],
                  button: true,
                  child: Padding(
                    padding: const EdgeInsets.all(9),
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: hslBandColors[b],
                        shape: BoxShape.circle,
                        border: Border.all(color: _band == b ? c.text : Colors.transparent, width: 2),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

/// Three-way colour grading: a hue/saturation wheel each for shadows,
/// midtones and highlights, with level and balance.
class GradePanel extends StatefulWidget {
  const GradePanel({super.key, required this.values, required this.onChanged, required this.onEnd});
  final Adjustments values;
  final void Function(Map<Adj, double>) onChanged;
  final VoidCallback onEnd;

  @override
  State<GradePanel> createState() => _GradePanelState();
}

class _GradePanelState extends State<GradePanel> {
  int _sel = 0;
  bool _balance = false;
  static const _zones = [
    ('shadows', Adj.shHue, Adj.shSat, Adj.shLum),
    ('midtones', Adj.midHue, Adj.midSat, Adj.midLum),
    ('highlights', Adj.hiHue, Adj.hiSat, Adj.hiLum),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final v = widget.values;
    final adj = _balance ? Adj.balance : _zones[_sel].$4;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final (i, z) in _zones.indexed)
                Column(
                  children: [
                    _Wheel(
                      hue: v[z.$2],
                      sat: v[z.$3],
                      active: _sel == i && !_balance,
                      onStart: () => setState(() {
                        _sel = i;
                        _balance = false;
                      }),
                      onChanged: (h, s) => widget.onChanged({z.$2: h, z.$3: s}),
                      onEnd: widget.onEnd,
                    ),
                    const SizedBox(height: 6),
                    Text(z.$1, style: context.label(_sel == i && !_balance ? c.text : c.dim, 11)),
                  ],
                ),
            ],
          ),
        ),
        Row(
          children: [
            TextTab(_balance ? 'balance' : 'level', active: true, dot: false, onTap: () => setState(() => _balance = !_balance)),
            Expanded(
              child: Ruler(value: v[adj], height: 38, onChanged: (x) => widget.onChanged({adj: x}), onEnd: widget.onEnd),
            ),
            SizedBox(width: 44, child: Text(_pct(v[adj]), style: context.num(c.dim))),
          ],
        ),
      ],
    );
  }
}

class _Wheel extends StatelessWidget {
  const _Wheel({required this.hue, required this.sat, required this.active, required this.onStart, required this.onChanged, required this.onEnd});
  final double hue, sat;
  final bool active;
  final VoidCallback onStart, onEnd;
  final void Function(double hue, double sat) onChanged;
  static const _size = 88.0;

  void _set(Offset local) {
    final d = local - const Offset(_size / 2, _size / 2);
    final s = (d.distance / (_size / 2)).clamp(0.0, 1.0);
    final h = (math.atan2(d.dy, d.dx) / (2 * math.pi)) % 1.0;
    onChanged(h, s < 0.06 ? 0 : s);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onPanStart: (d) {
          onStart();
          _set(d.localPosition);
        },
        onPanUpdate: (d) => _set(d.localPosition),
        onPanEnd: (_) => onEnd(),
        onTap: onStart,
        onDoubleTap: () {
          onChanged(0, 0);
          onEnd();
        },
        child: CustomPaint(
          size: const Size(_size, _size),
          painter: _WheelPainter(hue, sat, active ? context.c.text : context.c.line),
        ),
      );
}

class _WheelPainter extends CustomPainter {
  _WheelPainter(this.hue, this.sat, this.ring);
  final double hue, sat;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero), r = size.width / 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r - 1,
      Paint()
        ..shader = SweepGradient(
          colors: [for (var i = 0; i <= 6; i++) HSVColor.fromAHSV(1, (i * 60) % 360, 0.75, 0.8).toColor()],
        ).createShader(rect),
    );
    canvas.drawCircle(
      c,
      r - 1,
      Paint()..shader = const RadialGradient(colors: [Color(0xFF3A3836), Color(0x003A3836)], stops: [0.1, 1]).createShader(rect),
    );
    canvas.drawCircle(
      c,
      r - 1,
      Paint()
        ..color = ring
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    final a = hue * 2 * math.pi;
    final k = c + Offset(math.cos(a), math.sin(a)) * (sat * (r - 6));
    canvas.drawCircle(k, 5.5, Paint()..color = Colors.white);
    canvas.drawCircle(k, 3.5, Paint()..color = sat == 0 ? const Color(0xFF3A3836) : HSVColor.fromAHSV(1, hue * 360, 0.8, 0.9).toColor());
  }

  @override
  bool shouldRepaint(_WheelPainter o) => o.hue != hue || o.sat != sat || o.ring != ring;
}

/// Crop aspect choices as (label, width / height); 0 is free, -1 original.
const cropAspects = [
  ('free', 0.0), ('original', -1.0), ('1:1', 1.0), ('4:5', 0.8), ('5:4', 1.25), ('3:2', 1.5), ('2:3', 2 / 3), //
  ('4:3', 4 / 3), ('3:4', 0.75), ('16:9', 16 / 9), ('9:16', 9 / 16),
];

/// Draggable crop rectangle over the uncropped frame. [aspect] is the locked
/// normalised width/height, or null when free.
class CropOverlay extends StatefulWidget {
  const CropOverlay({super.key, required this.rect, required this.onChanged, required this.onEnd, this.aspect});
  final Rect rect;
  final double? aspect;
  final ValueChanged<Rect> onChanged;
  final VoidCallback onEnd;

  @override
  State<CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<CropOverlay> {
  int _handle = -1; // 0..3 corners (tl, tr, bl, br), 4 move
  late Rect _start;
  late Offset _origin;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final s = box.biggest;
        final r = widget.rect;
        final px = Rect.fromLTRB(r.left * s.width, r.top * s.height, r.right * s.width, r.bottom * s.height);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) {
            final p = d.localPosition;
            final corners = [px.topLeft, px.topRight, px.bottomLeft, px.bottomRight];
            _handle = -1;
            for (var i = 0; i < 4; i++) {
              if ((corners[i] - p).distance < 40) _handle = i;
            }
            if (_handle < 0 && px.contains(p)) _handle = 4;
            _start = r;
            _origin = p;
          },
          onPanUpdate: (d) {
            if (_handle < 0) return;
            final dx = (d.localPosition.dx - _origin.dx) / s.width, dy = (d.localPosition.dy - _origin.dy) / s.height;
            const minSize = 0.08;
            Rect n;
            if (_handle == 4) {
              final sx = dx.clamp(-_start.left, 1 - _start.right), sy = dy.clamp(-_start.top, 1 - _start.bottom);
              n = _start.shift(Offset(sx, sy));
            } else {
              var l = _start.left, t = _start.top, rr = _start.right, b = _start.bottom;
              final left = _handle == 0 || _handle == 2, top = _handle == 0 || _handle == 1;
              if (left) {
                l = (l + dx).clamp(0.0, rr - minSize);
              } else {
                rr = (rr + dx).clamp(l + minSize, 1.0);
              }
              if (top) {
                t = (t + dy).clamp(0.0, b - minSize);
              } else {
                b = (b + dy).clamp(t + minSize, 1.0);
              }
              final a = widget.aspect;
              if (a != null) {
                // Keep the ratio by deriving height from width, anchored at the opposite corner.
                var w = rr - l;
                var h = w / a;
                final maxH = top ? b : 1 - t;
                if (h > maxH) {
                  h = maxH;
                  w = h * a;
                }
                if (left) {
                  l = rr - w;
                } else {
                  rr = l + w;
                }
                if (top) {
                  t = b - h;
                } else {
                  b = t + h;
                }
              }
              n = Rect.fromLTRB(l, t, rr, b);
            }
            widget.onChanged(n);
          },
          onPanEnd: (_) => widget.onEnd(),
          child: CustomPaint(painter: _CropPainter(px)),
        );
      });
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.r);
  final Rect r;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(r),
      Paint()..color = Colors.black.withValues(alpha: 0.6),
    );
    final line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(r, line);
    final thin = Paint()
      ..color = Colors.white38
      ..strokeWidth = 0.5;
    for (final f in const [1 / 3, 2 / 3]) {
      canvas.drawLine(Offset(r.left + r.width * f, r.top), Offset(r.left + r.width * f, r.bottom), thin);
      canvas.drawLine(Offset(r.left, r.top + r.height * f), Offset(r.right, r.top + r.height * f), thin);
    }
    final bold = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.square;
    const l = 16.0;
    for (final (o, sx, sy) in [(r.topLeft, 1.0, 1.0), (r.topRight, -1.0, 1.0), (r.bottomLeft, 1.0, -1.0), (r.bottomRight, -1.0, -1.0)]) {
      canvas.drawLine(o, o + Offset(l * sx, 0), bold);
      canvas.drawLine(o, o + Offset(0, l * sy), bold);
    }
  }

  @override
  bool shouldRepaint(_CropPainter o) => o.r != r;
}

/// On-image handles for a local adjustment mask. Coordinates are normalised
/// to the (uncropped) image shown underneath.
class MaskOverlay extends StatefulWidget {
  const MaskOverlay({super.key, required this.mask, required this.onChanged, required this.onEnd});
  final MaskLayer mask;
  final ValueChanged<MaskLayer> onChanged;
  final VoidCallback onEnd;

  @override
  State<MaskOverlay> createState() => _MaskOverlayState();
}

class _MaskOverlayState extends State<MaskOverlay> {
  int _mode = 0; // linear: 0 a, 1 b · radial: 0 centre, 1 radius · brush: stroke

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final s = box.biggest;
        final m = widget.mask;
        Offset n(Offset p) => Offset((p.dx / s.width).clamp(0.0, 1.0), (p.dy / s.height).clamp(0.0, 1.0));
        Offset px(Offset q) => Offset(q.dx * s.width, q.dy * s.height);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) {
            final p = d.localPosition;
            switch (m.type) {
              case MaskType.linear:
                _mode = (px(m.a) - p).distance <= (px(m.b) - p).distance ? 0 : 1;
              case MaskType.radial:
                _mode = ((px(m.a) - p).distance - m.radius * s.width).abs() < 30 ? 1 : 0;
              case MaskType.brush:
                widget.onChanged(m.copyWith(strokes: [...m.strokes, [n(p)]]));
            }
          },
          onPanUpdate: (d) {
            final p = d.localPosition;
            switch (m.type) {
              case MaskType.linear:
                widget.onChanged(_mode == 0 ? m.copyWith(a: n(p)) : m.copyWith(b: n(p)));
              case MaskType.radial:
                widget.onChanged(_mode == 0
                    ? m.copyWith(a: n(p))
                    : m.copyWith(radius: ((px(m.a) - p).distance / s.width).clamp(0.04, 1.5)));
              case MaskType.brush:
                if (m.strokes.isEmpty) return;
                final last = [...m.strokes.last, n(p)];
                widget.onChanged(m.copyWith(strokes: [...m.strokes.sublist(0, m.strokes.length - 1), last]));
            }
          },
          onPanEnd: (_) => widget.onEnd(),
          child: CustomPaint(painter: _MaskOverlayPainter(m, context.c.accent)),
        );
      });
}

class _MaskOverlayPainter extends CustomPainter {
  _MaskOverlayPainter(this.m, this.accent);
  final MaskLayer m;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.saveLayer(r, Paint()..color = Colors.white.withValues(alpha: 0.38));
    paintMaskAlpha(canvas, r, m, BlendMode.srcOver, tint: accent);
    canvas.restore();
    Offset px(Offset q) => Offset(q.dx * size.width, q.dy * size.height);
    final line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    void dot(Offset o) {
      canvas.drawCircle(o, 7, Paint()..color = Colors.white);
      canvas.drawCircle(o, 4, Paint()..color = accent);
    }

    switch (m.type) {
      case MaskType.linear:
        canvas.drawLine(px(m.a), px(m.b), line);
        dot(px(m.a));
        canvas.drawCircle(px(m.b), 6, line);
      case MaskType.radial:
        canvas.drawCircle(px(m.a), m.radius * size.width, line);
        dot(px(m.a));
      case MaskType.brush:
        break;
    }
  }

  @override
  bool shouldRepaint(_MaskOverlayPainter o) => o.m != m;
}
