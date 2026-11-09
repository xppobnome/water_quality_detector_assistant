/// 构建「淡蓝未来感」浅色主题与「深空蓝」深色主题。
///
/// 两套主题共用同一套组件规格（圆角 / 字号 / 间距 / 动效），仅色彩令牌不同，
/// 因此 `themeMode` 切换时布局零跳动。`ThemeData.extensions` 注入
/// [AppThemeExtension]，页面通过 `context.ds` 读取自定义令牌。
///
/// 兼容性：保留 [buildAppTheme] 作为浅色主题的别名，避免旧调用点失效。
library;

import 'package:flutter/material.dart';

import 'design_system.dart';

ThemeData buildLightTheme() => _build(Brightness.light);

ThemeData buildDarkTheme() => _build(Brightness.dark);

/// 旧 API 兼容别名。
ThemeData buildAppTheme() => buildLightTheme();

ThemeData _build(Brightness brightness) {
  final bool dark = brightness == Brightness.dark;
  final AppThemeExtension ds = dark
      ? AppThemeExtension.dark
      : AppThemeExtension.light;
  final ColorScheme cs = _colorScheme(brightness, ds);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: cs,
    extensions: <ThemeExtension<dynamic>>[ds],
    // 不透明底色：保证 push 出来的二级页面也有可靠的背景，
    // 氛围装饰由导航壳 / Hero 卡片各自绘制，避免路由不透明优化导致露底。
    scaffoldBackgroundColor: dark
        ? AppPalette.darkBackground
        : AppPalette.lightBackground,
    canvasColor: cs.surface,
    cardColor: cs.surface,
    dividerColor: ds.cardBorder,
    // 统一的轻量焦点态，满足键盘导航可见性。
    focusColor: cs.primary.withValues(alpha: 0.12),
    hoverColor: cs.primary.withValues(alpha: 0.06),
    splashFactory: InkSparkle.splashFactory,
    textTheme: _textTheme(brightness, cs, ds),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: cs.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: AppSpacing.xl,
      iconTheme: IconThemeData(color: cs.onSurface, size: 22),
      actionsIconTheme: IconThemeData(color: cs.onSurface, size: 21),
      titleTextStyle: TextStyle(
        color: cs.onSurface,
        fontSize: 19,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
    ),
    iconTheme: IconThemeData(color: cs.onSurfaceVariant, size: 20),
    cardTheme: CardThemeData(
      color: cs.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: ds.glow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.card,
        side: BorderSide(color: ds.cardBorder, width: 1),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return cs.onSurface.withValues(alpha: 0.08);
          }
          return cs.primary;
        }),
        foregroundColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return cs.onSurface.withValues(alpha: 0.38);
          }
          return cs.onPrimary;
        }),
        elevation: WidgetStateProperty.all<double>(0),
        padding: WidgetStateProperty.all<EdgeInsetsGeometry>(
          const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
        minimumSize: WidgetStateProperty.all<Size>(
          const Size(64, AppLayout.minTouchTarget),
        ),
        shape: WidgetStateProperty.all<RoundedRectangleBorder>(
          RoundedRectangleBorder(borderRadius: AppRadius.card),
        ),
        textStyle: WidgetStateProperty.all<TextStyle>(
          const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.all<Color>(cs.primary),
        side: WidgetStateProperty.all<BorderSide>(
          BorderSide(color: ds.cardBorder, width: 1.2),
        ),
        elevation: WidgetStateProperty.all<double>(0),
        padding: WidgetStateProperty.all<EdgeInsetsGeometry>(
          const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
        minimumSize: WidgetStateProperty.all<Size>(
          const Size(64, AppLayout.minTouchTarget),
        ),
        shape: WidgetStateProperty.all<RoundedRectangleBorder>(
          RoundedRectangleBorder(borderRadius: AppRadius.card),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.all<Color>(cs.primary),
        minimumSize: WidgetStateProperty.all<Size>(
          const Size(48, AppLayout.minTouchTarget),
        ),
        shape: WidgetStateProperty.all<RoundedRectangleBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
        ),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.all<Color>(cs.primary),
        foregroundColor: WidgetStateProperty.all<Color>(cs.onPrimary),
        elevation: WidgetStateProperty.all<double>(0),
        minimumSize: WidgetStateProperty.all<Size>(
          const Size(64, AppLayout.minTouchTarget),
        ),
        shape: WidgetStateProperty.all<RoundedRectangleBorder>(
          RoundedRectangleBorder(borderRadius: AppRadius.card),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: cs.surfaceContainerHighest.withValues(alpha: dark ? 0.5 : 0.7),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      labelStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
      hintStyle: TextStyle(
        color: cs.onSurfaceVariant.withValues(alpha: 0.75),
        fontSize: 13,
      ),
      prefixIconColor: cs.onSurfaceVariant,
      suffixIconColor: cs.onSurfaceVariant,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: BorderSide(color: ds.cardBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: BorderSide(color: ds.cardBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: BorderSide(color: cs.primary, width: 1.8),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: BorderSide(color: ds.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: BorderSide(color: ds.error, width: 1.8),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: cs.surfaceContainerHighest,
      selectedColor: cs.primaryContainer,
      labelStyle: TextStyle(
        color: cs.onSurface,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      secondaryLabelStyle: TextStyle(
        color: cs.onPrimaryContainer,
        fontSize: 12,
      ),
      side: BorderSide(color: ds.cardBorder),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      showCheckmark: false,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return cs.onSurface.withValues(alpha: 0.35);
          }
          return states.contains(WidgetState.selected)
              ? cs.onPrimaryContainer
              : cs.onSurfaceVariant;
        }),
        backgroundColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return cs.surfaceContainerHighest.withValues(alpha: 0.4);
          }
          return states.contains(WidgetState.selected)
              ? cs.primaryContainer
              : cs.surfaceContainerHighest.withValues(alpha: 0.55);
        }),
        side: WidgetStateProperty.all<BorderSide>(
          BorderSide(color: ds.cardBorder),
        ),
        shape: WidgetStateProperty.all<RoundedRectangleBorder>(
          RoundedRectangleBorder(borderRadius: AppRadius.card),
        ),
        minimumSize: WidgetStateProperty.all<Size>(
          const Size(64, AppLayout.minTouchTarget),
        ),
        textStyle: WidgetStateProperty.all<TextStyle>(
          const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: cs.onSurfaceVariant,
      textColor: cs.onSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      minVerticalPadding: 10,
    ),
    dividerTheme: DividerThemeData(
      color: ds.cardBorder,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? AppPalette.darkSurfaceHigh : AppPalette.lightText,
      contentTextStyle: TextStyle(
        color: dark ? AppPalette.darkText : Colors.white,
        fontSize: 13,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      elevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.sheet),
      titleTextStyle: TextStyle(
        color: cs.onSurface,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
      contentTextStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? AppPalette.darkSurfaceHigh : AppPalette.lightText,
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      textStyle: TextStyle(
        color: dark ? AppPalette.darkText : Colors.white,
        fontSize: 12,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: cs.primary,
      linearTrackColor: cs.primaryContainer,
      circularTrackColor: cs.primaryContainer,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: ds.navPill,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: cs.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>((
        Set<WidgetState> states,
      ) {
        final bool selected = states.contains(WidgetState.selected);
        return TextStyle(
          color: selected ? cs.primary : cs.onSurfaceVariant,
          fontSize: 11,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith<IconThemeData>((
        Set<WidgetState> states,
      ) {
        return IconThemeData(
          color: states.contains(WidgetState.selected)
              ? cs.primary
              : cs.onSurfaceVariant,
          size: 22,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: ds.sidebar,
      indicatorColor: ds.sidebarActive,
      selectedIconTheme: IconThemeData(color: cs.primary),
      unselectedIconTheme: IconThemeData(color: cs.onSurfaceVariant),
      selectedLabelTextStyle: TextStyle(
        color: cs.primary,
        fontWeight: FontWeight.w700,
        fontSize: 12,
      ),
      unselectedLabelTextStyle: TextStyle(
        color: cs.onSurfaceVariant,
        fontSize: 12,
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: ZoomPageTransitionsBuilder(),
        TargetPlatform.iOS: ZoomPageTransitionsBuilder(),
        TargetPlatform.windows: ZoomPageTransitionsBuilder(),
        TargetPlatform.macOS: ZoomPageTransitionsBuilder(),
        TargetPlatform.linux: ZoomPageTransitionsBuilder(),
      },
    ),
  );
}

ColorScheme _colorScheme(Brightness brightness, AppThemeExtension ds) {
  final bool dark = ds.isDark;
  final ColorScheme base = ColorScheme.fromSeed(
    seedColor: dark ? AppPalette.darkPrimary : AppPalette.lightPrimary,
    brightness: brightness,
  );
  return base.copyWith(
    primary: dark ? AppPalette.darkPrimary : AppPalette.lightPrimary,
    onPrimary: dark ? AppPalette.darkOnPrimary : AppPalette.lightOnPrimary,
    primaryContainer: dark
        ? AppPalette.darkPrimaryContainer
        : AppPalette.lightPrimaryContainer,
    onPrimaryContainer: dark
        ? AppPalette.darkOnPrimaryContainer
        : AppPalette.lightOnPrimaryContainer,
    secondary: dark ? AppPalette.darkSecondary : AppPalette.lightSecondary,
    secondaryContainer: dark
        ? AppPalette.darkSecondaryContainer
        : AppPalette.lightSecondaryContainer,
    onSecondaryContainer: dark ? AppPalette.darkText : AppPalette.lightText,
    surface: dark ? AppPalette.darkSurface : AppPalette.lightSurface,
    onSurface: dark ? AppPalette.darkText : AppPalette.lightText,
    surfaceContainer: dark
        ? AppPalette.darkSurfaceContainer
        : AppPalette.lightSurfaceContainer,
    surfaceContainerLow: dark
        ? AppPalette.darkSurface
        : AppPalette.lightSurfaceContainer,
    surfaceContainerHigh: dark
        ? AppPalette.darkSurfaceHigh
        : AppPalette.lightSurfaceHigh,
    surfaceContainerHighest: dark
        ? AppPalette.darkSurfaceHigh
        : AppPalette.lightSurfaceHigh,
    onSurfaceVariant: dark
        ? AppPalette.darkTextMuted
        : AppPalette.lightTextMuted,
    outline: ds.cardBorder,
    outlineVariant: ds.cardBorder,
    error: ds.error,
    onError: dark ? const Color(0xFF2A050B) : Colors.white,
    errorContainer: ds.error.withValues(alpha: dark ? 0.18 : 0.10),
    onErrorContainer: ds.error,
    surfaceTint: Colors.transparent,
    shadow: Colors.black,
    scrim: Colors.black54,
  );
}

TextTheme _textTheme(
  Brightness brightness,
  ColorScheme cs,
  AppThemeExtension ds,
) {
  final TextTheme base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
  ).textTheme;
  final TextTheme applied = base.apply(
    bodyColor: cs.onSurface,
    displayColor: cs.onSurface,
    decorationColor: cs.onSurface,
  );
  return applied.copyWith(
    titleMedium: applied.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.1,
    ),
    titleLarge: applied.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
    ),
    headlineSmall: applied.headlineSmall?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: -0.5,
    ),
    labelSmall: applied.labelSmall?.copyWith(color: cs.onSurfaceVariant),
    bodySmall: applied.bodySmall?.copyWith(color: cs.onSurfaceVariant),
  );
}
