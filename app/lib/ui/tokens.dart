import 'package:flutter/material.dart';

/// Design tokens. A quiet, almost monochrome language: paper-coloured canvas,
/// hierarchy carried by lightness instead of hue, one small accent, and a
/// five-step tone ramp ([tones]) for data such as the repository map.
@immutable
class Palette extends ThemeExtension<Palette> {
  /// Window background behind the content.
  final Color canvas;

  /// Sidebar background, a shade darker than [canvas].
  final Color sidebar;

  /// Panels, list containers, inputs.
  final Color panel;

  /// Row hover / selected-row fill.
  final Color hover;
  final Color selected;

  /// Hairline borders and dividers.
  final Color line;

  /// Stronger border for focused-but-not-accented controls.
  final Color lineStrong;

  final Color text;
  final Color textMuted;
  final Color textFaint;

  final Color accent;
  final Color accentSoft;
  final Color onAccent;

  final Color success;
  final Color warning;
  final Color danger;

  /// Lightness ramp for data blocks, lightest (0) to darkest (4) in light mode;
  /// in dark mode index 0 is the brightest block too, so meaning is stable.
  final List<Color> tones;

  /// Hairline for contour fills (the repository map's 未整理 area).
  final Color contour;

  const Palette({
    required this.canvas,
    required this.sidebar,
    required this.panel,
    required this.hover,
    required this.selected,
    required this.line,
    required this.lineStrong,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.success,
    required this.warning,
    required this.danger,
    required this.tones,
    required this.contour,
  });

  static const light = Palette(
    canvas: Color(0xFFF1EFE7),
    sidebar: Color(0xFFEAE7DE),
    panel: Color(0xFFF8F7F2),
    hover: Color(0x0D1D1C1A),
    selected: Color(0x171D1C1A),
    line: Color(0xFFE0DCD1),
    lineStrong: Color(0xFFC4BFB2),
    text: Color(0xFF1D1C1A),
    textMuted: Color(0xFF69675F),
    textFaint: Color(0xFF9D9A90),
    accent: Color(0xFFC96442),
    accentSoft: Color(0xFFF4E6DD),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF5B8A66),
    warning: Color(0xFFB08537),
    danger: Color(0xFFB8564C),
    tones: [
      Color(0xFFE4E1D6),
      Color(0xFFD3CFC3),
      Color(0xFF9E9B91),
      Color(0xFF74726A),
      Color(0xFF2D2C29),
    ],
    contour: Color(0x611D1C1A),
  );

  static const dark = Palette(
    canvas: Color(0xFF1B1B1A),
    sidebar: Color(0xFF171716),
    panel: Color(0xFF232322),
    hover: Color(0x0FFFFFFF),
    selected: Color(0x1AFFFFFF),
    line: Color(0xFF2F2E2C),
    lineStrong: Color(0xFF4A4945),
    text: Color(0xFFEBE9E2),
    textMuted: Color(0xFFA4A29A),
    textFaint: Color(0xFF75736D),
    accent: Color(0xFFDB7A59),
    accentSoft: Color(0xFF3D2D27),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF86AE8F),
    warning: Color(0xFFD2A65A),
    danger: Color(0xFFD9867D),
    tones: [
      Color(0xFFE6E3D8),
      Color(0xFF908E87),
      Color(0xFF4A4946),
      Color(0xFF353533),
      Color(0xFF2A2A28),
    ],
    contour: Color(0x66EBE9E2),
  );

  static Palette of(BuildContext context) =>
      Theme.of(context).extension<Palette>() ?? light;

  @override
  Palette copyWith() => this;

  /// Same palette with another accent; the soft tint is mixed from it and the
  /// text on it flips to stay readable (the 墨 accent is near-white in dark).
  Palette withAccent(Color a) => Palette(
    canvas: canvas,
    sidebar: sidebar,
    panel: panel,
    hover: hover,
    selected: selected,
    line: line,
    lineStrong: lineStrong,
    text: text,
    textMuted: textMuted,
    textFaint: textFaint,
    accent: a,
    accentSoft: Color.alphaBlend(
      a.withValues(alpha: panel.computeLuminance() > 0.5 ? 0.13 : 0.22),
      panel,
    ),
    onAccent: a.computeLuminance() > 0.5 ? canvas : const Color(0xFFFFFFFF),
    success: success,
    warning: warning,
    danger: danger,
    tones: tones,
    contour: contour,
  );

  @override
  Palette lerp(Palette? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return Palette(
      canvas: l(canvas, other.canvas),
      sidebar: l(sidebar, other.sidebar),
      panel: l(panel, other.panel),
      hover: l(hover, other.hover),
      selected: l(selected, other.selected),
      line: l(line, other.line),
      lineStrong: l(lineStrong, other.lineStrong),
      text: l(text, other.text),
      textMuted: l(textMuted, other.textMuted),
      textFaint: l(textFaint, other.textFaint),
      accent: l(accent, other.accent),
      accentSoft: l(accentSoft, other.accentSoft),
      onAccent: l(onAccent, other.onAccent),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      danger: l(danger, other.danger),
      tones: [
        for (var i = 0; i < tones.length; i++) l(tones[i], other.tones[i]),
      ],
      contour: l(contour, other.contour),
    );
  }
}

/// Spacing / radius scale.
abstract final class Space {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

abstract final class Radii {
  static const sm = 5.0;
  static const md = 6.0;
  static const lg = 10.0;
  static const xl = 12.0;

  /// Map blocks and other "pebble" shapes.
  static const pebble = 34.0;
}

/// Platform UI font (SF + PingFang on macOS, Segoe + YaHei on Windows).
const sansFallback = [
  'PingFang SC',
  'Hiragino Sans GB',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
];
const monoFamily = 'Menlo';
const monoFallback = ['SF Mono', 'Consolas', 'monospace'];

/// macOS type scale (points).
abstract final class TypeScale {
  /// Hero numbers (repository size, pending count): large and thin.
  static const display = 64.0;
  static const title = 24.0;
  static const headline = 15.0;
  static const body = 13.0;
  static const small = 11.5;
}

/// Hairline width: one physical pixel on Retina.
const hairline = 0.5;

/// Soft drop shadow for floating surfaces (menus, sheets, floating bars).
List<BoxShadow> floatShadow([double strength = 1]) => [
  BoxShadow(
    color: Colors.black.withValues(alpha: 0.10 * strength),
    blurRadius: 28,
    offset: const Offset(0, 10),
  ),
  BoxShadow(
    color: Colors.black.withValues(alpha: 0.06 * strength),
    blurRadius: 3,
    offset: const Offset(0, 1),
  ),
];

/// Barely-there lift for inset panels.
List<BoxShadow> panelShadow() => [
  BoxShadow(
    color: Colors.black.withValues(alpha: 0.035),
    blurRadius: 2,
    offset: const Offset(0, 1),
  ),
];
