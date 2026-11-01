import 'package:flutter/material.dart';

/// Design tokens. Warm neutrals + one terracotta accent, flat surfaces separated
/// by hairlines (design language borrowed from Claude's apps).
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
  });

  static const light = Palette(
    canvas: Color(0xFFFBFAF7),
    sidebar: Color(0xFFF1EFE8),
    panel: Color(0xFFFFFFFF),
    hover: Color(0x0A1F1E1D),
    selected: Color(0x141F1E1D),
    line: Color(0xFFE6E3DA),
    lineStrong: Color(0xFFCFCCC2),
    text: Color(0xFF1F1E1D),
    textMuted: Color(0xFF6E6D66),
    textFaint: Color(0xFFA09E96),
    accent: Color(0xFFC96442),
    accentSoft: Color(0xFFF7E9E2),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF3F8A55),
    warning: Color(0xFFB7791F),
    danger: Color(0xFFC2453A),
  );

  static const dark = Palette(
    canvas: Color(0xFF242422),
    sidebar: Color(0xFF1C1C1A),
    panel: Color(0xFF2D2D2B),
    hover: Color(0x0FFFFFFF),
    selected: Color(0x1AFFFFFF),
    line: Color(0xFF3A3936),
    lineStrong: Color(0xFF52514C),
    text: Color(0xFFEDECE6),
    textMuted: Color(0xFFA8A79F),
    textFaint: Color(0xFF7A7973),
    accent: Color(0xFFDB7A59),
    accentSoft: Color(0xFF43302A),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF7DB58A),
    warning: Color(0xFFDDA54A),
    danger: Color(0xFFE5776C),
  );

  static Palette of(BuildContext context) =>
      Theme.of(context).extension<Palette>() ?? light;

  @override
  Palette copyWith() => this;

  /// Same palette with another accent; the soft tint is mixed from it.
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
    onAccent: onAccent,
    success: success,
    warning: warning,
    danger: danger,
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
  static const title = 22.0;
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
