import 'package:flutter/material.dart';

import 'constants.dart';

/// 构建蓝白配色主题。
///
/// 主色 `#1976D2`，浅蓝底 `#E3F2FD`，辅以白/中性灰；语义色用于成功/警示/错误。
ThemeData buildAppTheme() {
  final ColorScheme colorScheme = ColorScheme.fromSeed(
    seedColor: kPrimaryColor,
    primary: kPrimaryColor,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: Colors.white,
    appBarTheme: const AppBarTheme(
      backgroundColor: kPrimaryColor,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: kPrimaryLight,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          color: selected ? kPrimaryColor : kNeutralGrey,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(color: selected ? kPrimaryColor : kNeutralGrey);
      }),
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: Colors.white,
      indicatorColor: kPrimaryLight,
      selectedIconTheme: IconThemeData(color: kPrimaryColor),
      unselectedIconTheme: IconThemeData(color: kNeutralGrey),
      selectedLabelTextStyle: TextStyle(
        color: kPrimaryColor,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: TextStyle(color: kNeutralGrey),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kPrimaryColor,
        foregroundColor: Colors.white,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(foregroundColor: kPrimaryColor),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      enabledBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: kNeutralGrey),
        borderRadius: BorderRadius.circular(8),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: kPrimaryColor, width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dividerTheme: const DividerThemeData(color: Color(0xFFE0E0E0)),
    // 全平台统一轻量淡入转场：home_page 的 _push、设置页、裁剪页、预览页等
    // 所有 MaterialPageRoute 自动获得过渡。内置的
    // FadeForwardsPageTransitionsBuilder 时长为 450ms，超出「200~300ms、
    // 避免卡顿」的约束，故选用约 300ms 的 Zoom（缩放 + 淡入）；无第三方依赖。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: ZoomPageTransitionsBuilder(),
        TargetPlatform.iOS: ZoomPageTransitionsBuilder(),
        TargetPlatform.windows: ZoomPageTransitionsBuilder(),
      },
    ),
  );
}
