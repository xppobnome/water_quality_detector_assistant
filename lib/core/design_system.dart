import 'package:flutter/material.dart';

/// ============================================================================
/// AQUA Design System v2 —— 「淡蓝 / 深空」双主题设计令牌
/// ============================================================================
///
/// 设计原则：
/// 1. **令牌先行**：所有颜色、间距、圆角、动效集中在此，页面不写魔法数字。
/// 2. **语义而非字面**：业务代码用 `primary / surface / onSurfaceVariant`，
///    而不是 `#1976D2`；主题切换时所有页面自动跟随。
/// 3. **WCAG AA**：正文与背景对比度 >= 4.5:1，大字/图标 >= 3:1；
///    交互目标最小 44x44；焦点态始终可见。
/// 4. **响应式**：900px 为「桌面侧栏 / 移动底栏」断点，内容区最大 1180px。
/// 5. **性能**：背景网格由单个 CustomPainter 绘制，无图片资源、无 blur 堆叠。
///
/// 用法：
/// ```dart
/// final ds = context.ds;       // 扩展令牌（渐变、玻璃、辉光、语义色）
/// final cs = context.cs;       // Material ColorScheme
/// final dark = context.isDark; // 当前亮度
/// ```
/// ============================================================================

// ---------------------------------------------------------------------------
// 主题模式
// ---------------------------------------------------------------------------

/// 外观模式。`system` 会跟随操作系统亮度自动切换（含运行中的系统切换）。
enum AppThemeMode { system, light, dark }

extension AppThemeModeX on AppThemeMode {
  String get label => switch (this) {
    AppThemeMode.system => '跟随系统',
    AppThemeMode.light => '浅色',
    AppThemeMode.dark => '深色',
  };

  String get description => switch (this) {
    AppThemeMode.system => '随设备外观自动在淡蓝 / 深空之间切换',
    AppThemeMode.light => '始终使用淡蓝未来感界面',
    AppThemeMode.dark => '始终使用深空蓝界面',
  };

  IconData get icon => switch (this) {
    AppThemeMode.system => Icons.brightness_auto_outlined,
    AppThemeMode.light => Icons.wb_sunny_outlined,
    AppThemeMode.dark => Icons.nights_stay_outlined,
  };

  ThemeMode get materialThemeMode => switch (this) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };

  String get storageValue => name;

  static AppThemeMode fromStorage(String? value) => switch (value) {
    'light' => AppThemeMode.light,
    'dark' => AppThemeMode.dark,
    _ => AppThemeMode.system,
  };
}

// ---------------------------------------------------------------------------
// 尺度令牌
// ---------------------------------------------------------------------------

/// 4px 基准的间距节奏。
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 40;
  static const double section = 48;
}

/// 圆角层级：小标签 → 卡片 → 大容器 → 胶囊。
abstract final class AppRadius {
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 26;
  static const double pill = 999;
  static BorderRadius get card => BorderRadius.circular(lg);
  static BorderRadius get sheet => BorderRadius.circular(xl);
}

/// 动效时长（全部 <= 420ms，避免明显卡顿；尊重 reduce motion 由系统控制）。
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 420);
}

/// 布局断点与尺寸。
abstract final class AppLayout {
  /// >= 该宽度显示桌面侧边栏；小于则使用移动端浮动底栏。
  static const double sidebarBreakpoint = 900;

  /// 内容区最大宽度，超宽屏下居中，保持舒适阅读行长。
  static const double contentMaxWidth = 1180;

  /// 展开侧栏宽度。
  static const double sidebarWidth = 244;

  /// 最小交互目标（WCAG 2.5.5 / Material）。
  static const double minTouchTarget = 44;
}

// ---------------------------------------------------------------------------
// 调色板
// ---------------------------------------------------------------------------

/// 双主题原始色板。业务代码应优先使用 [AppThemeExtension] 的语义字段。
abstract final class AppPalette {
  // ── 浅色：淡蓝未来感 ──────────────────────────────────────────────────
  static const Color lightBackground = Color(0xFFF2F7FF);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceContainer = Color(0xFFF7FBFF);
  static const Color lightSurfaceHigh = Color(0xFFEAF3FF);
  static const Color lightPrimary = Color(0xFF1F6FEB);
  static const Color lightOnPrimary = Color(0xFFFFFFFF);
  static const Color lightPrimaryContainer = Color(0xFFDCEBFF);
  static const Color lightOnPrimaryContainer = Color(0xFF0A4BA8);
  static const Color lightSecondary = Color(0xFF0E8FA8);
  static const Color lightSecondaryContainer = Color(0xFFD6F4FA);
  static const Color lightText = Color(0xFF0D2137);
  static const Color lightTextMuted = Color(0xFF536B86);
  static const Color lightOutline = Color(0xFFD5E3F5);
  static const Color lightOutlineStrong = Color(0xFFB9D0EC);
  static const Color lightGrid = Color(0x0A1F6FEB);
  static const Color lightGlow = Color(0x332F8BFF);
  static const Color lightGlass = Color(0x99FFFFFF);
  static const Color lightGlassBorder = Color(0xCCFFFFFF);
  static const Color lightSuccess = Color(0xFF0B8F68);
  static const Color lightWarning = Color(0xFFB96A08);
  static const Color lightError = Color(0xFFD13B4E);
  static const Color lightInfo = Color(0xFF1F6FEB);
  static const List<Color> lightHero = <Color>[
    Color(0xFFEAF3FF),
    Color(0xFFD8EAFF),
    Color(0xFFE7F0FF),
  ];
  static const Color lightHeroInk = Color(0xFF0B2C55);
  static const List<Color> lightAccent = <Color>[
    Color(0xFF1F6FEB),
    Color(0xFF22B8E0),
  ];
  static const Color lightSidebar = Color(0xFFFFFFFF);
  static const Color lightSidebarActive = Color(0xFFE4F0FF);
  static const Color lightNavPill = Color(0xEFFFFFFF);

  // ── 深色：深空蓝 ──────────────────────────────────────────────────────
  static const Color darkBackground = Color(0xFF070D18);
  static const Color darkSurface = Color(0xFF0F1B2C);
  static const Color darkSurfaceContainer = Color(0xFF14243A);
  static const Color darkSurfaceHigh = Color(0xFF1B3050);
  static const Color darkPrimary = Color(0xFF6BB0FF);
  static const Color darkOnPrimary = Color(0xFF06162E);
  static const Color darkPrimaryContainer = Color(0xFF173B63);
  static const Color darkOnPrimaryContainer = Color(0xFFD3E7FF);
  static const Color darkSecondary = Color(0xFF4FE0D8);
  static const Color darkSecondaryContainer = Color(0xFF123C48);
  static const Color darkText = Color(0xFFE9F2FF);
  static const Color darkTextMuted = Color(0xFF96AEC8);
  static const Color darkOutline = Color(0xFF223A58);
  static const Color darkOutlineStrong = Color(0xFF345684);
  static const Color darkGrid = Color(0x126BB0FF);
  static const Color darkGlow = Color(0x4D3B92FF);
  static const Color darkGlass = Color(0x1A274468);
  static const Color darkGlassBorder = Color(0x334F7CB8);
  static const Color darkSuccess = Color(0xFF45D6A8);
  static const Color darkWarning = Color(0xFFFFB45C);
  static const Color darkError = Color(0xFFFF7C8C);
  static const Color darkInfo = Color(0xFF6BB0FF);
  static const List<Color> darkHero = <Color>[
    Color(0xFF102C50),
    Color(0xFF173E6B),
    Color(0xFF152A55),
  ];
  static const Color darkHeroInk = Color(0xFFEAF4FF);
  static const List<Color> darkAccent = <Color>[
    Color(0xFF6BB0FF),
    Color(0xFF4FE0D8),
  ];
  static const Color darkSidebar = Color(0xFF0C1626);
  static const Color darkSidebarActive = Color(0xFF1A3557);
  static const Color darkNavPill = Color(0xE6122034);
}

// ---------------------------------------------------------------------------
// 主题扩展（自定义令牌）
// ---------------------------------------------------------------------------

/// 注入 `ThemeData.extensions` 的自定义设计令牌。
///
/// 实现 [lerp] 让 `themeMode` 切换 / 系统亮度变化时颜色平滑插值，
/// 而不是生硬跳变。`copyWith()` 返回自身即可：扩展整体替换，不做局部覆盖。
class AppThemeExtension extends ThemeExtension<AppThemeExtension> {
  const AppThemeExtension({
    required this.brightness,
    required this.heroColors,
    required this.heroInk,
    required this.accentColors,
    required this.glass,
    required this.glassBorder,
    required this.grid,
    required this.glow,
    required this.success,
    required this.warning,
    required this.error,
    required this.info,
    required this.sidebar,
    required this.sidebarActive,
    required this.navPill,
    required this.cardBorder,
    required this.softSurface,
  });

  final Brightness brightness;

  /// Hero 渐变（3 个色标）。
  final List<Color> heroColors;

  /// Hero 上的主文字色，与 [heroColors] 保证 >= 7:1 对比。
  final Color heroInk;

  /// 品牌强调渐变（Logo、选中条、进度）。
  final List<Color> accentColors;

  /// 玻璃拟态填充 / 描边。
  final Color glass;
  final Color glassBorder;

  /// 背景网格线色。
  final Color grid;

  /// 辉光色（已带 alpha）。
  final Color glow;

  /// 语义状态色（两套主题分别校准对比度）。
  final Color success;
  final Color warning;
  final Color error;
  final Color info;

  /// 导航壳专用。
  final Color sidebar;
  final Color sidebarActive;
  final Color navPill;
  final Color cardBorder;
  final Color softSurface;

  bool get isDark => brightness == Brightness.dark;

  LinearGradient get heroGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: heroColors,
  );

  LinearGradient get accentGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: accentColors,
  );

  /// 统一的玻璃卡片装饰。
  BoxDecoration glassDecoration({double radius = AppRadius.lg}) =>
      BoxDecoration(
        color: glass,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: glassBorder, width: 1),
      );

  /// 统一辉光阴影（深色模式更强，浅色模式更柔）。
  List<BoxShadow> glowShadow({double blur = 26, double spread = 0}) =>
      <BoxShadow>[
        BoxShadow(
          color: glow,
          blurRadius: blur,
          spreadRadius: spread,
          offset: const Offset(0, 6),
        ),
      ];

  static final AppThemeExtension light = AppThemeExtension(
    brightness: Brightness.light,
    heroColors: AppPalette.lightHero,
    heroInk: AppPalette.lightHeroInk,
    accentColors: AppPalette.lightAccent,
    glass: AppPalette.lightGlass,
    glassBorder: AppPalette.lightGlassBorder,
    grid: AppPalette.lightGrid,
    glow: AppPalette.lightGlow,
    success: AppPalette.lightSuccess,
    warning: AppPalette.lightWarning,
    error: AppPalette.lightError,
    info: AppPalette.lightInfo,
    sidebar: AppPalette.lightSidebar,
    sidebarActive: AppPalette.lightSidebarActive,
    navPill: AppPalette.lightNavPill,
    cardBorder: AppPalette.lightOutline,
    softSurface: AppPalette.lightSurfaceHigh,
  );

  static final AppThemeExtension dark = AppThemeExtension(
    brightness: Brightness.dark,
    heroColors: AppPalette.darkHero,
    heroInk: AppPalette.darkHeroInk,
    accentColors: AppPalette.darkAccent,
    glass: AppPalette.darkGlass,
    glassBorder: AppPalette.darkGlassBorder,
    grid: AppPalette.darkGrid,
    glow: AppPalette.darkGlow,
    success: AppPalette.darkSuccess,
    warning: AppPalette.darkWarning,
    error: AppPalette.darkError,
    info: AppPalette.darkInfo,
    sidebar: AppPalette.darkSidebar,
    sidebarActive: AppPalette.darkSidebarActive,
    navPill: AppPalette.darkNavPill,
    cardBorder: AppPalette.darkOutline,
    softSurface: AppPalette.darkSurfaceHigh,
  );

  @override
  AppThemeExtension copyWith() => this;

  @override
  ThemeExtension<AppThemeExtension> lerp(
    covariant ThemeExtension<AppThemeExtension>? other,
    double t,
  ) {
    if (other is! AppThemeExtension) return this;
    return AppThemeExtension(
      brightness: t < 0.5 ? brightness : other.brightness,
      heroColors: _lerpColors(heroColors, other.heroColors, t),
      heroInk: Color.lerp(heroInk, other.heroInk, t) ?? heroInk,
      accentColors: _lerpColors(accentColors, other.accentColors, t),
      glass: Color.lerp(glass, other.glass, t) ?? glass,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t) ?? glassBorder,
      grid: Color.lerp(grid, other.grid, t) ?? grid,
      glow: Color.lerp(glow, other.glow, t) ?? glow,
      success: Color.lerp(success, other.success, t) ?? success,
      warning: Color.lerp(warning, other.warning, t) ?? warning,
      error: Color.lerp(error, other.error, t) ?? error,
      info: Color.lerp(info, other.info, t) ?? info,
      sidebar: Color.lerp(sidebar, other.sidebar, t) ?? sidebar,
      sidebarActive:
          Color.lerp(sidebarActive, other.sidebarActive, t) ?? sidebarActive,
      navPill: Color.lerp(navPill, other.navPill, t) ?? navPill,
      cardBorder: Color.lerp(cardBorder, other.cardBorder, t) ?? cardBorder,
      softSurface: Color.lerp(softSurface, other.softSurface, t) ?? softSurface,
    );
  }

  static List<Color> _lerpColors(List<Color> a, List<Color> b, double t) {
    final int count = a.length < b.length ? a.length : b.length;
    return List<Color>.generate(
      count,
      (int i) => Color.lerp(a[i], b[i], t) ?? a[i],
      growable: false,
    );
  }
}

// ---------------------------------------------------------------------------
// BuildContext 便捷访问
// ---------------------------------------------------------------------------

extension AquaThemeContext on BuildContext {
  /// 自定义设计令牌（若主题未注入扩展则回退到浅色令牌，保证健壮）。
  AppThemeExtension get ds =>
      Theme.of(this).extension<AppThemeExtension>() ?? AppThemeExtension.light;

  ColorScheme get cs => Theme.of(this).colorScheme;

  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  TextTheme get text => Theme.of(this).textTheme;
}
