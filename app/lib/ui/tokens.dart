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
    canvas: Color(0xFFFAF9F5),
    sidebar: Color(0xFFF3F1EA),
    panel: Color(0xFFFFFFFF),
    hover: Color(0xFFF0EEE6),
    selected: Color(0xFFEAE7DD),
    line: Color(0xFFE8E6DC),
    lineStrong: Color(0xFFD1CFC5),
    text: Color(0xFF1F1E1D),
    textMuted: Color(0xFF6B6A63),
    textFaint: Color(0xFF9C9A92),
    accent: Color(0xFFC96442),
    accentSoft: Color(0xFFF6E7DF),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF4F8A5B),
    warning: Color(0xFFB7791F),
    danger: Color(0xFFBF4D43),
  );

  static const dark = Palette(
    canvas: Color(0xFF262624),
    sidebar: Color(0xFF1F1E1D),
    panel: Color(0xFF30302E),
    hover: Color(0xFF353532),
    selected: Color(0xFF3D3D3A),
    line: Color(0xFF3B3A37),
    lineStrong: Color(0xFF55544F),
    text: Color(0xFFECEBE4),
    textMuted: Color(0xFFA6A59D),
    textFaint: Color(0xFF7B7A73),
    accent: Color(0xFFD97757),
    accentSoft: Color(0xFF45322A),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF7FB38A),
    warning: Color(0xFFDDA54A),
    danger: Color(0xFFE07A70),
  );

  static Palette of(BuildContext context) =>
      Theme.of(context).extension<Palette>() ?? light;

  @override
  Palette copyWith() => this;

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
  static const sm = 6.0;
  static const md = 8.0;
  static const lg = 12.0;
  static const xl = 16.0;
}

/// Serif for page titles (Latin glyphs from Georgia, Chinese from Songti on
/// macOS / SimSun on Windows); everything else uses the platform UI font.
const serifFamily = 'Georgia';
const serifFallback = [
  'Songti SC',
  'STSong',
  'Noto Serif CJK SC',
  'Source Han Serif SC',
  'SimSun',
  'serif',
];
const sansFallback = [
  'PingFang SC',
  'Hiragino Sans GB',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
];
const monoFamily = 'Menlo';
const monoFallback = ['SF Mono', 'Consolas', 'monospace'];
