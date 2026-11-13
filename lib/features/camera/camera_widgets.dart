import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/theme.dart';
import '../../core/camera/native_camera.dart';

String formatShutter(double s) {
  if (s <= 0) return '—';
  if (s >= 0.4) return '${s.toStringAsFixed(s >= 10 ? 0 : 1)}s';
  return '1/${(1 / s).round()}';
}

String formatClock(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
}

/// Shutter release. A ring with a disc for stills; a red disc that becomes a
/// square while recording.
class ShutterButton extends StatefulWidget {
  const ShutterButton({super.key, required this.onTap, required this.video, required this.recording, this.busy = false});
  final VoidCallback onTap;
  final bool video, recording, busy;

  @override
  State<ShutterButton> createState() => _ShutterButtonState();
}

class _ShutterButtonState extends State<ShutterButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final red = const Color(0xFFE5402F);
    final inner = widget.recording ? 26.0 : (_down ? 50.0 : 58.0);
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) {
        setState(() => _down = false);
        widget.onTap();
      },
      child: Semantics(
        button: true,
        label: widget.video ? (widget.recording ? 'stop recording' : 'record') : 'take photo',
        child: Container(
          width: 74,
          height: 74,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: widget.busy ? 0.4 : 1), width: 2.5),
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            width: inner,
            height: inner,
            decoration: BoxDecoration(
              color: widget.video ? red : Colors.white.withValues(alpha: widget.busy ? 0.5 : 1),
              borderRadius: BorderRadius.circular(widget.recording ? 6 : 40),
            ),
          ),
        ),
      ),
    );
  }
}

class HistogramView extends StatelessWidget {
  const HistogramView({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<int>>(
        valueListenable: NativeCamera.histogram,
        builder: (context, bins, _) => bins.isEmpty
            ? const SizedBox.shrink()
            : CustomPaint(size: const Size(84, 40), painter: _HistogramPainter(bins)),
      );
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.bins);
  final List<int> bins;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black.withValues(alpha: 0.35));
    final path = Path()..moveTo(0, size.height);
    for (var i = 0; i < bins.length; i++) {
      final x = size.width * i / (bins.length - 1);
      path.lineTo(x, size.height - size.height * math.sqrt(bins[i] / 255) * 0.94);
    }
    path
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.white.withValues(alpha: 0.8));
    // Clipping warnings at either end.
    if (bins.last > 60) {
      canvas.drawRect(Rect.fromLTWH(size.width - 2, 0, 2, size.height), Paint()..color = const Color(0xFFE5402F));
    }
    if (bins.first > 60) {
      canvas.drawRect(Rect.fromLTWH(0, 0, 2, size.height), Paint()..color = const Color(0xFF4A8FE0));
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter o) => o.bins != bins;
}

/// Composition guides: 1 thirds, 2 golden, 3 square crosshair.
/// Composition guides, indexed by the `grid` setting.
const gridNames = ['grid off', 'thirds', 'golden', 'centre', 'diagonals', 'thirds + diagonals'];

class GridPainter extends CustomPainter {
  GridPainter(this.type);
  final int type;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 0.6;
    final w = size.width, h = size.height;
    final fr = switch (type) {
      1 || 5 => const [1 / 3, 2 / 3],
      2 => const [0.382, 0.618],
      3 => const [0.5],
      _ => const <double>[],
    };
    for (final f in fr) {
      canvas.drawLine(Offset(w * f, 0), Offset(w * f, h), p);
      canvas.drawLine(Offset(0, h * f), Offset(w, h * f), p);
    }
    if (type == 4 || type == 5) {
      // Corner to corner.
      canvas.drawLine(Offset.zero, Offset(w, h), p);
      canvas.drawLine(Offset(w, 0), Offset(0, h), p);
    }
    if (type == 4) {
      // The diagonal method: 45° from every corner.
      final d = math.min(w, h);
      canvas.drawLine(Offset.zero, Offset(d, d), p);
      canvas.drawLine(Offset(w, 0), Offset(w - d, d), p);
      canvas.drawLine(Offset(0, h), Offset(d, h - d), p);
      canvas.drawLine(Offset(w, h), Offset(w - d, h - d), p);
    }
  }

  @override
  bool shouldRepaint(GridPainter o) => o.type != type;
}

/// Horizon level: a line that stays with gravity and lights up when flat.
class LevelView extends StatelessWidget {
  const LevelView({super.key});

  @override
  Widget build(BuildContext context) {
    final accent = context.c.accent;
    return ValueListenableBuilder<double>(
      valueListenable: NativeCamera.roll,
      builder: (context, roll, _) {
        final flat = roll.abs() < 0.8;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 14, height: 1, color: Colors.white54),
            const SizedBox(width: 6),
            Transform.rotate(
              angle: -roll * math.pi / 180,
              child: Container(width: 86, height: flat ? 1.5 : 1, color: flat ? accent : Colors.white),
            ),
            const SizedBox(width: 6),
            Container(width: 14, height: 1, color: Colors.white54),
          ],
        );
      },
    );
  }
}

/// Focus reticle that settles into place where the user tapped.
class FocusReticle extends StatelessWidget {
  const FocusReticle({super.key, required this.locked});
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final accent = context.c.accent;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.5, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, s, child) => Transform.scale(scale: s, child: child),
      child: SizedBox(
        width: 68,
        height: 68,
        child: CustomPaint(
          painter: _ReticlePainter(locked ? accent : Colors.white),
          child: locked
              ? Align(
                  alignment: const Alignment(0, 1.5),
                  child: Text('AE/AF lock', style: context.num(accent, 9.5)),
                )
              : null,
        ),
      ),
    );
  }
}

class _ReticlePainter extends CustomPainter {
  _ReticlePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    const l = 12.0;
    final w = size.width, h = size.height;
    for (final (o, dx, dy) in [
      (Offset.zero, 1.0, 1.0),
      (Offset(w, 0), -1.0, 1.0),
      (Offset(0, h), 1.0, -1.0),
      (Offset(w, h), -1.0, -1.0),
    ]) {
      canvas.drawLine(o, o + Offset(l * dx, 0), p);
      canvas.drawLine(o, o + Offset(0, l * dy), p);
    }
    canvas.drawCircle(Offset(w / 2, h / 2), 1.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ReticlePainter o) => o.color != color;
}

/// One read-out in the control tray: a label above a live value.
class Dial extends StatelessWidget {
  const Dial({super.key, required this.label, required this.value, required this.active, required this.manual, this.onTap});
  final String label, value;
  final bool active, manual;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: context.label(active ? c.accent : c.dim, 9.5)),
            const SizedBox(height: 3),
            Text(value, style: context.num(manual || active ? Colors.white : Colors.white70, 12)),
          ],
        ),
      ),
    );
  }
}
