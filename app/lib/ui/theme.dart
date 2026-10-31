import 'package:flutter/material.dart';

import 'tokens.dart';

/// App theme built from [Palette]: flat, hairline borders, no ripples.
ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.light ? Palette.light : Palette.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.accent,
    onPrimary: p.onAccent,
    primaryContainer: p.accentSoft,
    onPrimaryContainer: p.text,
    secondary: p.textMuted,
    onSecondary: p.panel,
    secondaryContainer: p.selected,
    onSecondaryContainer: p.text,
    tertiary: p.success,
    onTertiary: p.onAccent,
    error: p.danger,
    onError: p.onAccent,
    errorContainer: p.danger.withValues(alpha: 0.12),
    onErrorContainer: p.danger,
    surface: p.canvas,
    onSurface: p.text,
    onSurfaceVariant: p.textMuted,
    surfaceContainerLowest: p.panel,
    surfaceContainerLow: p.sidebar,
    surfaceContainer: p.panel,
    surfaceContainerHigh: p.hover,
    surfaceContainerHighest: p.selected,
    outline: p.lineStrong,
    outlineVariant: p.line,
    shadow: Colors.black,
    inverseSurface: p.text,
    onInverseSurface: p.canvas,
    inversePrimary: p.accentSoft,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    fontFamilyFallback: sansFallback,
    visualDensity: VisualDensity.compact,
  );
  final text = base.textTheme.apply(
    bodyColor: p.text,
    displayColor: p.text,
    fontFamilyFallback: sansFallback,
  );

  RoundedRectangleBorder rounded(
    double r, [
    BorderSide side = BorderSide.none,
  ]) => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(r),
    side: side,
  );
  final hairline = BorderSide(color: p.line);
  const buttonPadding = EdgeInsets.symmetric(horizontal: 14, vertical: 10);
  const buttonText = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w500,
    fontFamilyFallback: sansFallback,
  );
  OutlineInputBorder inputBorder(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(Radii.md),
    borderSide: BorderSide(color: c, width: w),
  );

  return base.copyWith(
    extensions: [p],
    scaffoldBackgroundColor: p.canvas,
    canvasColor: p.canvas,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: p.hover,
    focusColor: p.hover,
    dividerColor: p.line,
    textTheme: text.copyWith(
      headlineSmall: text.headlineSmall?.copyWith(
        fontFamily: serifFamily,
        fontFamilyFallback: serifFallback,
        fontSize: 26,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.2,
      ),
      titleLarge: text.titleLarge?.copyWith(
        fontFamily: serifFamily,
        fontFamilyFallback: serifFallback,
        fontSize: 20,
        fontWeight: FontWeight.w500,
      ),
      titleMedium: text.titleMedium?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: text.titleSmall?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 14, height: 1.45),
      bodySmall: text.bodySmall?.copyWith(
        fontSize: 12.5,
        color: p.textMuted,
        height: 1.4,
      ),
      labelLarge: text.labelLarge?.copyWith(
        fontSize: 13.5,
        fontWeight: FontWeight.w500,
      ),
      labelSmall: text.labelSmall?.copyWith(
        fontSize: 11.5,
        color: p.textFaint,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    ),
    iconTheme: IconThemeData(color: p.textMuted, size: 20),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: p.panel,
      surfaceTintColor: Colors.transparent,
      shape: rounded(Radii.lg, hairline),
    ),
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        disabledBackgroundColor: p.selected,
        disabledForegroundColor: p.textFaint,
        padding: buttonPadding,
        textStyle: buttonText,
        shape: rounded(Radii.md),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        backgroundColor: p.panel,
        padding: buttonPadding,
        textStyle: buttonText,
        side: BorderSide(color: p.lineStrong),
        shape: rounded(Radii.md),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.text,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        textStyle: buttonText,
        shape: rounded(Radii.md),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: p.textMuted,
        shape: rounded(Radii.md),
        hoverColor: p.hover,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: const WidgetStatePropertyAll(buttonText),
        shape: WidgetStatePropertyAll(rounded(Radii.md)),
        side: WidgetStatePropertyAll(BorderSide(color: p.lineStrong)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.selected : p.panel,
        ),
        foregroundColor: WidgetStatePropertyAll(p.text),
        iconColor: WidgetStatePropertyAll(p.textMuted),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.panel,
      selectedColor: p.accentSoft,
      side: BorderSide(color: p.line),
      shape: rounded(Radii.md),
      labelStyle: TextStyle(
        fontSize: 13,
        color: p.text,
        fontFamilyFallback: sansFallback,
      ),
      secondaryLabelStyle: TextStyle(
        fontSize: 13,
        color: p.text,
        fontFamilyFallback: sansFallback,
      ),
      checkmarkColor: p.accent,
      iconTheme: IconThemeData(color: p.textMuted, size: 16),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.panel,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      hintStyle: TextStyle(color: p.textFaint, fontSize: 14),
      labelStyle: TextStyle(color: p.textMuted, fontSize: 14),
      floatingLabelStyle: TextStyle(color: p.textMuted),
      helperStyle: TextStyle(color: p.textFaint, fontSize: 12),
      helperMaxLines: 3,
      prefixIconColor: p.textFaint,
      suffixIconColor: p.textFaint,
      border: inputBorder(p.lineStrong),
      enabledBorder: inputBorder(p.line),
      focusedBorder: inputBorder(p.accent, 1.5),
      errorBorder: inputBorder(p.danger),
      focusedErrorBorder: inputBorder(p.danger, 1.5),
      disabledBorder: inputBorder(p.line),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      shape: rounded(Radii.xl, hairline),
      titleTextStyle: text.titleLarge?.copyWith(
        fontFamily: serifFamily,
        fontFamilyFallback: serifFallback,
        fontSize: 20,
        fontWeight: FontWeight.w500,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      shape: rounded(Radii.lg, hairline),
      textStyle: TextStyle(fontSize: 13.5, color: p.text),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.panel),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(rounded(Radii.lg, hairline)),
        elevation: const WidgetStatePropertyAll(6),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.panel),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(rounded(Radii.lg, hairline)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: rounded(Radii.md),
      selectedColor: p.text,
      selectedTileColor: p.selected,
      iconColor: p.textMuted,
      textColor: p.text,
      dense: true,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.text,
      unselectedLabelColor: p.textMuted,
      indicatorColor: p.accent,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: p.line,
      labelStyle: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        fontFamilyFallback: sansFallback,
      ),
      unselectedLabelStyle: const TextStyle(
        fontSize: 14,
        fontFamilyFallback: sansFallback,
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: rounded(4),
      side: BorderSide(color: p.lineStrong, width: 1.5),
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(p.onAccent),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : p.lineStrong,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.onAccent : p.textFaint,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : p.selected,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : p.lineStrong,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.line,
      circularTrackColor: Colors.transparent,
      linearMinHeight: 4,
      borderRadius: BorderRadius.circular(2),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.accent,
      thumbColor: p.accent,
      inactiveTrackColor: p.line,
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: p.accent,
      textColor: p.onAccent,
      textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.text,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      textStyle: TextStyle(color: p.canvas, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.text,
      contentTextStyle: TextStyle(color: p.canvas, fontSize: 13.5),
      actionTextColor: p.accentSoft,
      shape: rounded(Radii.lg),
      elevation: 4,
      width: 440,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(p.lineStrong),
    ),
  );
}
