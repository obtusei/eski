import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// eski's palette: warm darkroom blacks or paper whites, one accent.
class EskiColors extends ThemeExtension<EskiColors> {
  const EskiColors({
    required this.bg,
    required this.surface,
    required this.line,
    required this.text,
    required this.dim,
    required this.faint,
    required this.accent,
  });

  final Color bg, surface, line, text, dim, faint, accent;

  /// Text or icon colour that reads on top of an accent fill.
  Color get onAccent => accent.computeLuminance() > 0.45 ? const Color(0xFF141311) : Colors.white;

  /// The accent as a text colour. Light accents (yellow, paper) vanish on a
  /// light background, so there they are deepened until they read.
  Color get accentInk {
    final la = accent.computeLuminance(), lb = bg.computeLuminance();
    final ratio = (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
    if (ratio >= 3) return accent;
    final hsl = HSLColor.fromColor(accent);
    return hsl.withLightness(lb > 0.5 ? 0.3 : 0.7).withSaturation((hsl.saturation * 1.1).clamp(0.0, 1.0)).toColor();
  }

  /// Destructive actions keep their own colour whatever the accent is.
  static const danger = Color(0xFFD8432E);

  static EskiColors dark(Color accent) => EskiColors(
        bg: const Color(0xFF0B0A09),
        surface: const Color(0xFF171513),
        line: const Color(0xFF2B2724),
        text: const Color(0xFFEDE8DF),
        dim: const Color(0xFF948C80),
        faint: const Color(0xFF5C564E),
        accent: accent,
      );

  static EskiColors light(Color accent) => EskiColors(
        bg: const Color(0xFFF4F0E8),
        surface: const Color(0xFFE9E4DA),
        line: const Color(0xFFD6CFC2),
        text: const Color(0xFF1B1916),
        dim: const Color(0xFF6F685E),
        faint: const Color(0xFFA69E91),
        accent: accent,
      );

  @override
  EskiColors copyWith() => this;

  @override
  EskiColors lerp(EskiColors? other, double t) => other == null
      ? this
      : EskiColors(
          bg: Color.lerp(bg, other.bg, t)!,
          surface: Color.lerp(surface, other.surface, t)!,
          line: Color.lerp(line, other.line, t)!,
          text: Color.lerp(text, other.text, t)!,
          dim: Color.lerp(dim, other.dim, t)!,
          faint: Color.lerp(faint, other.faint, t)!,
          accent: Color.lerp(accent, other.accent, t)!,
        );
}

const accentChoices = <String, Color>{
  'yellow': Color(0xFFF5C518),
  'safelight': Color(0xFFE8502F),
  'moss': Color(0xFF8FA65A),
  'cyan': Color(0xFF58B5C4),
  'iris': Color(0xFF8E86E0),
  'paper': Color(0xFFD9D2C5),
};

const serif = 'InstrumentSerif';
const sans = 'HankenGrotesk';
const mono = 'DMMono';

extension EskiContext on BuildContext {
  EskiColors get c => Theme.of(this).extension<EskiColors>()!;

  /// Editorial display type.
  TextStyle display([double size = 34]) =>
      TextStyle(fontFamily: serif, fontSize: size, height: 1.05, color: c.text, letterSpacing: -0.3);

  /// Lowercase interface label.
  TextStyle label([Color? color, double size = 12.5]) => TextStyle(
        fontFamily: sans,
        fontSize: size,
        letterSpacing: 0.4,
        color: color ?? c.text,
        fontVariations: const [FontVariation('wght', 500)],
      );

  TextStyle body([Color? color]) => TextStyle(
        fontFamily: sans,
        fontSize: 14.5,
        height: 1.4,
        color: color ?? c.text,
        fontVariations: const [FontVariation('wght', 400)],
      );

  /// Technical read-outs: ISO, shutter, values.
  TextStyle num([Color? color, double size = 11.5]) =>
      TextStyle(fontFamily: mono, fontSize: size, color: color ?? c.text, letterSpacing: 0.2);
}

ThemeData eskiTheme(Brightness b, Color accent) {
  final c = b == Brightness.dark ? EskiColors.dark(accent) : EskiColors.light(accent);
  return ThemeData(
    brightness: b,
    useMaterial3: true,
    fontFamily: sans,
    scaffoldBackgroundColor: c.bg,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: b).copyWith(
      primary: accent,
      surface: c.bg,
      onSurface: c.text,
    ),
    extensions: [c],
    textSelectionTheme: TextSelectionThemeData(cursorColor: accent, selectionColor: accent.withValues(alpha: 0.3)),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(10))),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.text,
      contentTextStyle: TextStyle(fontFamily: sans, color: c.bg, fontSize: 13.5),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      systemOverlayStyle: b == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),
  );
}
