import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../app/theme/theme.dart';
import '../../core/image_processing/adjustments.dart';
import '../../core/image_processing/look_engine.dart';
import '../../core/image_processing/renderer.dart';
import '../../core/media/media_library.dart';

/// The eski wordmark from the launch screen, shown while something loads.
class SplashMark extends StatelessWidget {
  const SplashMark({super.key, this.dark, this.width = 150});

  /// Forces the dark (light mark) version; follows the theme when null.
  final bool? dark;
  final double width;

  @override
  Widget build(BuildContext context) {
    final d = dark ?? Theme.of(context).brightness == Brightness.dark;
    return Image.asset(
      d ? 'assets/icons/splash_dark.png' : 'assets/icons/splash_light.png',
      width: width,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'eski',
    );
  }
}

/// Bare icon button with a comfortable hit target.
class IconBtn extends StatelessWidget {
  const IconBtn(this.icon, {super.key, this.onTap, this.color, this.size = 22, this.tooltip});
  final IconData icon;
  final VoidCallback? onTap;
  final Color? color;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final w = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Icon(icon, size: size, color: onTap == null ? context.c.faint : (color ?? context.c.text)),
      ),
    );
    return tooltip == null ? w : Semantics(label: tooltip, button: true, child: w);
  }
}

/// Lowercase text tab; the active one takes the text colour and an accent dot.
class TextTab extends StatelessWidget {
  const TextTab(this.text, {super.key, required this.active, this.onTap, this.onLongPress, this.dot = true});
  final String text;
  final bool active;
  final bool dot;
  final VoidCallback? onTap, onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 160),
              style: context.label(active ? c.text : c.dim),
              child: Text(text),
            ),
            if (dot)
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                margin: const EdgeInsets.only(top: 4),
                width: 3,
                height: 3,
                decoration: BoxDecoration(color: active ? c.accent : Colors.transparent, shape: BoxShape.circle),
              ),
          ],
        ),
      ),
    );
  }
}

/// A pill-shaped tab with a faded fill and hairline border, optionally led
/// by an icon; the active one takes an accent tint.
class ToolChip extends StatelessWidget {
  const ToolChip(this.text, {super.key, required this.active, this.icon, this.onTap});
  final String text;
  final bool active;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fg = active ? c.text : c.dim;
    return Semantics(
      button: true,
      selected: active,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: EdgeInsets.fromLTRB(icon == null ? 16 : 12, 0, 16, 0),
            decoration: BoxDecoration(
              color: active ? c.accent.withValues(alpha: 0.16) : c.text.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: active ? c.accent.withValues(alpha: 0.6) : c.line),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 17, color: active ? c.accent : fg),
                  const SizedBox(width: 7),
                ],
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 160),
                  style: context.label(fg, 13.5),
                  child: Text(text),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A ruler-style slider: drag anywhere, double-tap to reset, with a haptic
/// detent at the neutral point.
class Ruler extends StatefulWidget {
  const Ruler({
    super.key,
    required this.value,
    required this.onChanged,
    this.onEnd,
    this.min = -1,
    this.max = 1,
    this.neutral = 0,
    this.height = 44,
  });

  final double value, min, max, neutral, height;
  final ValueChanged<double> onChanged;
  final VoidCallback? onEnd;

  @override
  State<Ruler> createState() => _RulerState();
}

class _RulerState extends State<Ruler> {
  double _start = 0, _startValue = 0;

  void _set(double v) {
    final range = widget.max - widget.min;
    var x = v.clamp(widget.min, widget.max);
    if ((x - widget.neutral).abs() < range * 0.012) x = widget.neutral;
    if (x == widget.neutral && widget.value != widget.neutral) HapticFeedback.selectionClick();
    if (x != widget.value) widget.onChanged(x);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) {
          _start = d.localPosition.dx;
          _startValue = widget.value;
        },
        onHorizontalDragUpdate: (d) =>
            _set(_startValue + (d.localPosition.dx - _start) / (w - 48) * (widget.max - widget.min)),
        onHorizontalDragEnd: (_) => widget.onEnd?.call(),
        onDoubleTap: () {
          HapticFeedback.lightImpact();
          widget.onChanged(widget.neutral);
          widget.onEnd?.call();
        },
        child: CustomPaint(
          size: Size(w, widget.height),
          painter: _RulerPainter(
            t: (widget.value - widget.min) / (widget.max - widget.min),
            n: (widget.neutral - widget.min) / (widget.max - widget.min),
            line: c.faint,
            text: c.text,
            accent: c.accent,
          ),
        ),
      );
    });
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({required this.t, required this.n, required this.line, required this.text, required this.accent});
  final double t, n;
  final Color line, text, accent;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 24.0;
    final w = size.width - pad * 2, cy = size.height / 2;
    final p = Paint()..strokeWidth = 1;
    const ticks = 40;
    for (var i = 0; i <= ticks; i++) {
      final x = pad + w * i / ticks;
      final major = i % 5 == 0;
      p.color = line.withValues(alpha: major ? 0.9 : 0.45);
      canvas.drawLine(Offset(x, cy - (major ? 6 : 3)), Offset(x, cy + (major ? 6 : 3)), p);
    }
    final x0 = pad + w * n, x1 = pad + w * t;
    canvas.drawLine(Offset(x0, cy), Offset(x1, cy), Paint()..color = accent..strokeWidth = 1.5);
    canvas.drawCircle(Offset(x0, cy), 2, Paint()..color = text);
    canvas.drawLine(Offset(x1, cy - 13), Offset(x1, cy + 13), Paint()..color = text..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_RulerPainter o) => o.t != t || o.n != n || o.accent != accent || o.text != text;
}

/// Paints a ui.Image through the look engine with an [EditState].
class EditedImage extends StatefulWidget {
  const EditedImage({
    super.key,
    required this.image,
    required this.edit,
    this.original = false,
    this.fit = BoxFit.contain,
    this.overlay,
  });

  final ui.Image image;
  final EditState edit;
  final bool original;
  final BoxFit fit;

  /// Second frame of a double exposure; a cached thumbnail is used if null.
  final ui.Image? overlay;

  @override
  State<EditedImage> createState() => _EditedImageState();
}

class _EditedImageState extends State<EditedImage> {
  final _renderer = EditRenderer();

  @override
  void dispose() {
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = frameSize(Size(widget.image.width.toDouble(), widget.image.height.toDouble()), widget.edit.geo);
    return FittedBox(
      fit: widget.fit,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _EditPainter(widget.image, widget.edit, widget.original, _renderer, widget.overlay),
          ),
        ),
      ),
    );
  }
}

class _EditPainter extends CustomPainter {
  _EditPainter(this.image, this.edit, this.original, this.renderer, this.overlay)
      : super(repaint: Listenable.merge([LookEngine.lutReady, Overlays.ready, Mattes.ready]));
  final ui.Image image;
  final EditState edit;
  final bool original;
  final EditRenderer renderer;
  final ui.Image? overlay;

  @override
  void paint(Canvas canvas, Size size) => renderer.paint(
        canvas,
        size,
        image,
        edit,
        original: original,
        overlay: overlay ?? Overlays.of(edit.dx, image),
      );

  @override
  bool shouldRepaint(_EditPainter o) => o.image != image || o.edit != edit || o.original != original || o.overlay != overlay;
}

/// Applies a look to any widget (camera preview, video) as a GPU image filter.
class LookFilter extends StatefulWidget {
  const LookFilter({
    super.key,
    required this.look,
    required this.child,
    this.crop = const Rect.fromLTWH(0, 0, 1, 1),
    this.frameAspect = 1,
    this.peaking = false,
    this.animateGrain = false,
  });

  final ResolvedLook look;
  final Rect crop;
  final double frameAspect;
  final bool peaking, animateGrain;
  final Widget child;

  @override
  State<LookFilter> createState() => _LookFilterState();
}

class _LookFilterState extends State<LookFilter> with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  Ticker? _ticker;
  double _seed = 0;
  int _lastTick = 0;

  bool get _grain => widget.animateGrain && (widget.look.u[17] > 0 || widget.look.u[75] > 0);

  void _syncTicker() {
    if (_grain && _ticker == null) {
      _ticker = createTicker((d) {
        final t = d.inMilliseconds ~/ 42; // ~24 grain frames per second
        if (t != _lastTick) {
          _lastTick = t;
          setState(() => _seed = (t % 97) / 97);
        }
      })
        ..start();
    } else if (!_grain && _ticker != null) {
      _ticker!.dispose();
      _ticker = null;
    }
  }

  @override
  void initState() {
    super.initState();
    LookEngine.lutReady.addListener(_onLut);
  }

  void _onLut() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    LookEngine.lutReady.removeListener(_onLut);
    _ticker?.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncTicker();
    final neutral = identical(widget.look, ResolvedLook.neutral) && !widget.peaking;
    if (neutral || !ui.ImageFilter.isShaderFilterSupported) return widget.child;
    // A fresh shader per configuration guarantees the filter repaints.
    final old = _shader;
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    final s = _shader = LookEngine.shader();
    LookEngine.apply(
      s,
      widget.look,
      crop: widget.crop,
      frameAspect: widget.frameAspect,
      seed: _seed,
      filterMode: true,
      peaking: widget.peaking,
      accent: context.c.accent,
    );
    return ImageFiltered(imageFilter: ui.ImageFilter.shader(s), child: widget.child);
  }
}

/// End-of-list sentinel: asks for the next page whenever it comes into view.
class LoadMore extends StatelessWidget {
  const LoadMore({super.key, required this.active, required this.onLoad});
  final bool active;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    if (active) WidgetsBinding.instance.addPostFrameCallback((_) => onLoad());
    return SizedBox(
      height: 56,
      child: active ? Center(child: Text('loading more…', style: context.num(context.c.faint))) : null,
    );
  }
}

Future<T?> showEskiSheet<T>(BuildContext context, Widget Function(BuildContext) builder) => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: builder(ctx),
      ),
    );

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
}

/// A plain list row for sheets and settings.
class Row2 extends StatelessWidget {
  const Row2(this.title, {super.key, this.value, this.onTap, this.trailing, this.danger = false});
  final String title;
  final String? value;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
        child: Row(
          children: [
            Expanded(child: Text(title, style: context.body(danger ? EskiColors.danger : c.text))),
            if (value != null) Text(value!, style: context.num(c.dim, 12.5)),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// The primary action in a dialog: an accent fill with contrasting text, so
/// it reads with any accent colour in either theme.
class AccentButton extends StatelessWidget {
  const AccentButton(this.text, {super.key, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Material(
          color: context.c.accent,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Text(text, style: context.label(context.c.onAccent, 14)),
            ),
          ),
        ),
      );
}

Future<bool> confirm(BuildContext context, String title, String body, String action) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: ctx.display(26)),
        content: Text(body, style: ctx.body(ctx.c.dim)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('cancel', style: ctx.label(ctx.c.dim, 14))),
          AccentButton(action, onTap: () => Navigator.pop(ctx, true)),
        ],
      ),
    ) ??
    false;

Future<String?> promptText(BuildContext context, String title, {String initial = '', String action = 'save'}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: ctx.display(26)),
      content: TextField(
        controller: ctl,
        autofocus: true,
        style: ctx.body(),
        decoration: InputDecoration(
          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: ctx.c.line)),
          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: ctx.c.accent)),
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text('cancel', style: ctx.label(ctx.c.dim, 14))),
        AccentButton(action, onTap: () => Navigator.pop(ctx, ctl.text.trim())),
      ],
    ),
  );
}

/// A small procedural scene used for look thumbnails before any photo exists.
Future<ui.Image> buildSampleScene() {
  const w = 120.0, h = 150.0;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  const r = Rect.fromLTWH(0, 0, w, h);
  canvas.drawRect(
    r,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        const Offset(0, h * 0.62),
        const [Color(0xFF5E8FC7), Color(0xFFBFD3E6), Color(0xFFF3D9B0)],
        const [0, 0.7, 1],
      ),
  );
  canvas.drawCircle(const Offset(w * 0.7, h * 0.3), 13, Paint()..color = const Color(0xFFFFF4D6));
  final far = Path()
    ..moveTo(0, h * 0.6)
    ..lineTo(w * 0.3, h * 0.42)
    ..lineTo(w * 0.55, h * 0.58)
    ..lineTo(w * 0.8, h * 0.46)
    ..lineTo(w, h * 0.56)
    ..lineTo(w, h)
    ..lineTo(0, h)
    ..close();
  canvas.drawPath(far, Paint()..color = const Color(0xFF6C7F8E));
  final near = Path()
    ..moveTo(0, h * 0.72)
    ..quadraticBezierTo(w * 0.4, h * 0.6, w, h * 0.74)
    ..lineTo(w, h)
    ..lineTo(0, h)
    ..close();
  canvas.drawPath(near, Paint()..color = const Color(0xFF4F7A45));
  canvas.drawRect(const Rect.fromLTWH(0, h * 0.86, w, h * 0.14), Paint()..color = const Color(0xFF2B3A2A));
  canvas.drawCircle(const Offset(w * 0.3, h * 0.8), 10, Paint()..color = const Color(0xFFD9A07E));
  canvas.drawRect(const Rect.fromLTWH(w * 0.62, h * 0.7, 16, 26), Paint()..color = const Color(0xFFC0392B));
  final rnd = math.Random(4);
  for (var i = 0; i < 14; i++) {
    canvas.drawCircle(
      Offset(rnd.nextDouble() * w, h * (0.74 + rnd.nextDouble() * 0.2)),
      1.5,
      Paint()..color = const Color(0xFFE8D36B),
    );
  }
  return rec.endRecording().toImage(w.toInt(), h.toInt());
}
