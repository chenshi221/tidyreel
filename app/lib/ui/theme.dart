import 'package:flutter/material.dart';

import 'tokens.dart';

/// App theme from [Palette], sized like a native macOS app: 13pt body,
/// 30pt controls, no ripples, no floating labels. Quiet by design: controls
/// are ink outlines or plain text, selection is ink, and the accent is kept
/// for the one primary action on a screen.
ThemeData buildTheme(Brightness brightness, {Color? accent}) {
  final palette = brightness == Brightness.light ? Palette.light : Palette.dark;
  final p = accent == null ? palette : palette.withAccent(accent);
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
    surfaceContainerHigh: p.sidebar,
    surfaceContainerHighest: p.sidebar,
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
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
  TextStyle? t(
    TextStyle? s,
    double size, {
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? height,
    double? spacing,
  }) => s?.copyWith(
    fontSize: size,
    fontWeight: weight,
    color: color ?? p.text,
    height: height,
    letterSpacing: spacing ?? 0,
    fontFamilyFallback: sansFallback,
  );
  final bt = base.textTheme;
  final text = bt.copyWith(
    displayLarge: t(
      bt.displayLarge,
      TypeScale.display,
      weight: FontWeight.w200,
      height: 1,
      spacing: -2,
    ),
    displaySmall: t(
      bt.displaySmall,
      30,
      weight: FontWeight.w300,
      spacing: -0.6,
    ),
    headlineSmall: t(
      bt.headlineSmall,
      TypeScale.title,
      weight: FontWeight.w500,
      spacing: -0.4,
    ),
    titleLarge: t(bt.titleLarge, 17, weight: FontWeight.w500, spacing: -0.2),
    titleMedium: t(bt.titleMedium, TypeScale.headline, weight: FontWeight.w500),
    titleSmall: t(bt.titleSmall, TypeScale.body, weight: FontWeight.w500),
    bodyLarge: t(bt.bodyLarge, 14, height: 1.4),
    bodyMedium: t(bt.bodyMedium, TypeScale.body, height: 1.38),
    bodySmall: t(
      bt.bodySmall,
      TypeScale.small,
      color: p.textMuted,
      height: 1.35,
    ),
    labelLarge: t(bt.labelLarge, TypeScale.body, weight: FontWeight.w500),
    labelMedium: t(bt.labelMedium, 12, weight: FontWeight.w500),
    labelSmall: t(
      bt.labelSmall,
      11,
      weight: FontWeight.w500,
      color: p.textFaint,
    ),
  );

  RoundedRectangleBorder rounded(
    double r, [
    BorderSide side = BorderSide.none,
  ]) => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(r),
    side: side,
  );
  final line = BorderSide(color: p.line, width: hairline);
  const buttonPadding = EdgeInsets.symmetric(horizontal: 14, vertical: 7);
  const buttonSize = Size(0, 30);
  final ink = BorderSide(color: p.text.withValues(alpha: 0.78), width: 1);
  const buttonText = TextStyle(
    fontSize: TypeScale.body,
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
    focusColor: p.text.withValues(alpha: 0.10),
    dividerColor: p.line,
    textTheme: text,
    iconTheme: IconThemeData(color: p.textMuted, size: 16),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: p.panel,
      surfaceTintColor: Colors.transparent,
      shape: rounded(Radii.lg, line),
    ),
    dividerTheme: DividerThemeData(
      color: p.line,
      thickness: hairline,
      space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        disabledBackgroundColor: p.selected,
        disabledForegroundColor: p.textFaint,
        padding: buttonPadding,
        minimumSize: buttonSize,
        textStyle: buttonText,
        shape: rounded(Radii.lg),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        backgroundColor: Colors.transparent,
        disabledForegroundColor: p.textFaint,
        padding: buttonPadding,
        minimumSize: buttonSize,
        textStyle: buttonText,
        side: ink,
        shape: rounded(Radii.lg),
        elevation: 0,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.text,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        minimumSize: buttonSize,
        textStyle: buttonText,
        shape: rounded(Radii.lg),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: p.textMuted,
        shape: rounded(Radii.md),
        hoverColor: p.hover,
        padding: const EdgeInsets.all(6),
        minimumSize: const Size(28, 28),
        iconSize: 17,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: const WidgetStatePropertyAll(buttonText),
        shape: WidgetStatePropertyAll(rounded(Radii.lg)),
        side: WidgetStatePropertyAll(ink),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? p.selected
              : Colors.transparent,
        ),
        foregroundColor: WidgetStatePropertyAll(p.text),
        iconColor: WidgetStatePropertyAll(p.textMuted),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.transparent,
      selectedColor: p.selected,
      side: BorderSide(color: p.lineStrong, width: hairline),
      shape: rounded(Radii.lg),
      labelStyle: TextStyle(
        fontSize: 12.5,
        color: p.text,
        fontFamilyFallback: sansFallback,
      ),
      secondaryLabelStyle: TextStyle(
        fontSize: 12.5,
        color: p.text,
        fontFamilyFallback: sansFallback,
      ),
      checkmarkColor: p.text,
      iconTheme: IconThemeData(color: p.textMuted, size: 14),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      labelPadding: const EdgeInsets.symmetric(horizontal: 6),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.transparent,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      hintStyle: TextStyle(color: p.textFaint, fontSize: TypeScale.body),
      labelStyle: TextStyle(color: p.textMuted, fontSize: TypeScale.body),
      floatingLabelBehavior: FloatingLabelBehavior.never,
      helperStyle: TextStyle(color: p.textFaint, fontSize: TypeScale.small),
      errorStyle: TextStyle(color: p.danger, fontSize: TypeScale.small),
      helperMaxLines: 3,
      prefixIconColor: p.textFaint,
      suffixIconColor: p.textFaint,
      prefixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 28),
      suffixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 28),
      border: inputBorder(p.lineStrong),
      enabledBorder: inputBorder(p.lineStrong),
      focusedBorder: inputBorder(p.text.withValues(alpha: 0.78), 1.2),
      errorBorder: inputBorder(p.danger, 1),
      focusedErrorBorder: inputBorder(p.danger, 2),
      disabledBorder: inputBorder(p.line, hairline),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.text,
      selectionColor: p.text.withValues(alpha: 0.16),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      // Shadow is drawn by the dialog content (see MacSheet): Material's
      // elevation shadow is too hard-edged for a macOS sheet.
      elevation: 0,
      shape: rounded(Radii.xl, line),
      titleTextStyle: text.titleMedium,
      contentTextStyle: text.bodyMedium,
      barrierColor: Colors.black.withValues(alpha: 0.08),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      shape: rounded(Radii.lg, line),
      textStyle: TextStyle(
        fontSize: TypeScale.body,
        color: p.text,
        fontFamilyFallback: sansFallback,
      ),
      menuPadding: const EdgeInsets.all(5),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.panel),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(rounded(Radii.lg, line)),
        elevation: const WidgetStatePropertyAll(10),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.panel),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(rounded(Radii.lg, line)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: rounded(Radii.lg),
      selectedColor: p.text,
      selectedTileColor: p.selected,
      iconColor: p.textMuted,
      textColor: p.text,
      dense: true,
      minVerticalPadding: 6,
      horizontalTitleGap: 10,
      titleTextStyle: text.bodyMedium,
      subtitleTextStyle: text.bodySmall,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.text,
      unselectedLabelColor: p.textMuted,
      indicatorColor: p.text,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: p.line,
      labelStyle: const TextStyle(
        fontSize: TypeScale.body,
        fontWeight: FontWeight.w500,
        fontFamilyFallback: sansFallback,
      ),
      unselectedLabelStyle: const TextStyle(
        fontSize: TypeScale.body,
        fontFamilyFallback: sansFallback,
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      labelPadding: const EdgeInsets.symmetric(horizontal: 12),
    ),
    checkboxTheme: CheckboxThemeData(
      // Square ink boxes, like a paper form.
      shape: rounded(4),
      side: BorderSide(color: p.text.withValues(alpha: 0.7), width: 1.2),
      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.text : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(p.canvas),
    ),
    radioTheme: RadioThemeData(
      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.text : p.lineStrong,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.text : p.selected,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbIcon: const WidgetStatePropertyAll(null),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.text,
      linearTrackColor: p.selected,
      circularTrackColor: Colors.transparent,
      linearMinHeight: 3,
      borderRadius: BorderRadius.circular(2),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.text,
      thumbColor: Colors.white,
      inactiveTrackColor: p.selected,
      trackHeight: 3,
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: p.text,
      textColor: p.canvas,
      textStyle: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: p.line, width: hairline),
        boxShadow: floatShadow(0.6),
      ),
      textStyle: TextStyle(
        color: p.text,
        fontSize: 11.5,
        fontFamilyFallback: sansFallback,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      waitDuration: const Duration(milliseconds: 600),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.text,
      contentTextStyle: TextStyle(
        color: p.canvas,
        fontSize: TypeScale.body,
        fontFamilyFallback: sansFallback,
      ),
      actionTextColor: p.accentSoft,
      shape: rounded(Radii.lg),
      elevation: 6,
      width: 420,
    ),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final t in TargetPlatform.values) t: const _FadeUpTransitions(),
      },
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(p.lineStrong),
    ),
  );
}

/// Page change: fade in while rising 12px (desktop apps don't slide sideways).
class _FadeUpTransitions extends PageTransitionsBuilder {
  const _FadeUpTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    final a = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: a,
      child: AnimatedBuilder(
        animation: a,
        builder: (_, c) => Transform.translate(
          offset: Offset(0, 12 * (1 - a.value)),
          child: c,
        ),
        child: child,
      ),
    );
  }
}
