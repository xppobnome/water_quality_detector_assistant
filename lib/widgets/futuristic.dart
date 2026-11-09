import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/design_system.dart';
import '../providers/theme_provider.dart';

/// ============================================================================
/// AQUA 未来感基础组件
/// ============================================================================
/// 纯 CustomPaint / BoxDecoration 实现，不依赖图片资源与 BackdropFilter，
/// 在低端手机与 Windows 桌面端都能稳定 60fps。
/// ============================================================================

// ---------------------------------------------------------------------------
// 氛围背景：细网格 + 双径向光晕
// ---------------------------------------------------------------------------

class AquaBackdrop extends StatelessWidget {
  const AquaBackdrop({
    super.key,
    this.child,
    this.gridSize = 30,
    this.showGrid = true,
    this.glowStrength = 1,
  });

  final Widget? child;
  final double gridSize;
  final bool showGrid;
  final double glowStrength;

  @override
  Widget build(BuildContext context) {
    final AppThemeExtension ds = context.ds;
    return CustomPaint(
      painter: _AquaBackdropPainter(
        gridColor: ds.grid,
        glowColor: ds.glow,
        accent: ds.accentColors.first,
        gridSize: gridSize,
        showGrid: showGrid,
        glowStrength: glowStrength,
      ),
      child: child ?? const SizedBox.expand(),
    );
  }
}

class _AquaBackdropPainter extends CustomPainter {
  const _AquaBackdropPainter({
    required this.gridColor,
    required this.glowColor,
    required this.accent,
    required this.gridSize,
    required this.showGrid,
    required this.glowStrength,
  });

  final Color gridColor;
  final Color glowColor;
  final Color accent;
  final double gridSize;
  final bool showGrid;
  final double glowStrength;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    // 两处柔和光晕：右上角主色 + 左下角强调色，形成对角纵深。
    _drawGlow(
      canvas,
      center: Offset(size.width * 0.92, size.height * 0.04),
      radius: (size.width * 0.62 + 120) * glowStrength,
      color: glowColor,
    );
    _drawGlow(
      canvas,
      center: Offset(size.width * 0.02, size.height * 0.96),
      radius: (size.width * 0.42 + 90) * glowStrength,
      color: accent.withValues(alpha: 0.10),
    );

    if (!showGrid) return;
    final Paint gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.7;
    for (double x = 0; x <= size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y <= size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    // 交叉点用小圆点强调科技感（间距放大一倍，控制绘制量）。
    final Paint dotPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.10)
      ..strokeWidth = 1;
    for (double x = 0; x <= size.width; x += gridSize * 2) {
      for (double y = 0; y <= size.height; y += gridSize * 2) {
        canvas.drawCircle(Offset(x, y), 1.1, dotPaint);
      }
    }
  }

  void _drawGlow(
    Canvas canvas, {
    required Offset center,
    required double radius,
    required Color color,
  }) {
    final Paint paint = Paint()
      ..shader = RadialGradient(
        colors: <Color>[color, color.withValues(alpha: 0)],
        stops: const <double>[0, 1],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawRect(Rect.fromCircle(center: center, radius: radius), paint);
  }

  @override
  bool shouldRepaint(covariant _AquaBackdropPainter old) =>
      old.gridColor != gridColor ||
      old.glowColor != glowColor ||
      old.accent != accent ||
      old.gridSize != gridSize ||
      old.showGrid != showGrid ||
      old.glowStrength != glowStrength;
}

/// 页面 body 背景包装：氛围层在下，内容在上。
class AquaBody extends StatelessWidget {
  const AquaBody({
    super.key,
    required this.child,
    this.gridSize = 30,
    this.glowStrength = 1,
    this.showGrid = true,
  });

  final Widget child;
  final double gridSize;
  final double glowStrength;
  final bool showGrid;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: AquaBackdrop(
            gridSize: gridSize,
            glowStrength: glowStrength,
            showGrid: showGrid,
          ),
        ),
        child,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 品牌标识
// ---------------------------------------------------------------------------

class AquaLogo extends StatelessWidget {
  const AquaLogo({super.key, this.size = 44, this.showGlow = true});

  final double size;
  final bool showGlow;

  @override
  Widget build(BuildContext context) {
    final AppThemeExtension ds = context.ds;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: ds.accentGradient,
        borderRadius: BorderRadius.circular(size * 0.30),
        border: Border.all(
          color: Colors.white.withValues(alpha: ds.isDark ? 0.12 : 0.45),
          width: 1,
        ),
        boxShadow: showGlow ? ds.glowShadow(blur: 18) : null,
      ),
      child: Icon(
        Icons.water_drop_rounded,
        size: size * 0.52,
        color: ds.isDark ? const Color(0xFF06162E) : Colors.white,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 玻璃卡片
// ---------------------------------------------------------------------------

class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.xl),
    this.margin,
    this.onTap,
    this.radius = AppRadius.lg,
    this.fill,
    this.elevated = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final double radius;
  final Color? fill;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final AppThemeExtension ds = context.ds;
    Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: fill ?? ds.glass,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: ds.glassBorder, width: 1),
        boxShadow: elevated
            ? <BoxShadow>[
                BoxShadow(
                  color: ds.glow,
                  blurRadius: 22,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: child,
    );
    if (onTap != null) {
      content = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Semantics(
          button: true,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(radius),
            child: content,
          ),
        ),
      );
    }
    return margin == null ? content : Padding(padding: margin!, child: content);
  }
}

/// 带渐变底 + 柔和辉光的图标块，用于功能入口、设置项。
class GlowIcon extends StatelessWidget {
  const GlowIcon({
    super.key,
    required this.icon,
    this.size = 48,
    this.iconSize,
    this.tint,
  });

  final IconData icon;
  final double size;
  final double? iconSize;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = context.cs;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            cs.primaryContainer,
            cs.secondaryContainer.withValues(alpha: 0.85),
          ],
        ),
        borderRadius: BorderRadius.circular(size * 0.30),
        border: Border.all(color: cs.primary.withValues(alpha: 0.16), width: 1),
      ),
      child: Icon(
        icon,
        size: iconSize ?? size * 0.48,
        color: tint ?? cs.primary,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 排版组件
// ---------------------------------------------------------------------------

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final Widget? action;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = context.cs;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: 18, color: cs.primary),
          const SizedBox(width: AppSpacing.sm),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (action != null) ...<Widget>[
          const SizedBox(width: AppSpacing.md),
          action!,
        ],
      ],
    );
  }
}

/// 小型信息胶囊（状态、版本号、标签）。
class AquaPill extends StatelessWidget {
  const AquaPill({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.filled = true,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = context.cs;
    final Color c = color ?? cs.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: filled ? c.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: c.withValues(alpha: 0.32), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 13, color: c),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: c,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 主题切换
// ---------------------------------------------------------------------------

/// 顶栏 / 侧栏一键切换按钮（浅色 <-> 深色）。
class AquaThemeToggle extends StatelessWidget {
  const AquaThemeToggle({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ThemeProvider theme = context.watch<ThemeProvider>();
    final Brightness platform = MediaQuery.platformBrightnessOf(context);
    final bool dark = theme.resolvedDark(platform);
    final ColorScheme cs = context.cs;
    if (compact) {
      return IconButton(
        tooltip: dark ? '切换到浅色模式' : '切换到深色模式',
        onPressed: () => theme.toggle(platform),
        icon: Icon(dark ? Icons.wb_sunny_outlined : Icons.nights_stay_outlined),
        color: cs.onSurface,
      );
    }
    return Tooltip(
      message: dark ? '切换到浅色模式' : '切换到深色模式',
      child: InkWell(
        onTap: () => theme.toggle(platform),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                dark ? Icons.wb_sunny_outlined : Icons.nights_stay_outlined,
                size: 18,
                color: cs.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                dark ? '浅色模式' : '深色模式',
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 设置页外观选择卡片：跟随系统 / 浅色 / 深色，含迷你预览与选中态。
class ThemeModeSelector extends StatelessWidget {
  const ThemeModeSelector({super.key});

  static const List<AppThemeMode> _modes = <AppThemeMode>[
    AppThemeMode.system,
    AppThemeMode.light,
    AppThemeMode.dark,
  ];

  @override
  Widget build(BuildContext context) {
    final AppThemeMode current = context.watch<ThemeProvider>().mode;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool narrow = constraints.maxWidth < 460;
        if (narrow) {
          return Column(
            children: <Widget>[
              for (final AppThemeMode mode in _modes) ...<Widget>[
                _ThemeOption(mode: mode, selected: mode == current),
                if (mode != _modes.last) const SizedBox(height: AppSpacing.sm),
              ],
            ],
          );
        }
        return Row(
          children: <Widget>[
            for (final AppThemeMode mode in _modes) ...<Widget>[
              Expanded(
                child: _ThemeOption(mode: mode, selected: mode == current),
              ),
              if (mode != _modes.last) const SizedBox(width: AppSpacing.md),
            ],
          ],
        );
      },
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({required this.mode, required this.selected});

  final AppThemeMode mode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = context.cs;
    final AppThemeExtension ds = context.ds;
    final bool darkPreview = mode == AppThemeMode.dark;
    return Semantics(
      selected: selected,
      button: true,
      label: '外观模式：${mode.label}',
      child: AnimatedContainer(
        duration: AppMotion.normal,
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: selected
              ? cs.primaryContainer.withValues(alpha: 0.55)
              : cs.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? cs.primary : ds.cardBorder,
            width: selected ? 1.8 : 1,
          ),
          boxShadow: selected ? ds.glowShadow(blur: 16) : null,
        ),
        child: InkWell(
          onTap: () => context.read<ThemeProvider>().setMode(mode),
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 迷你界面预览：模拟侧栏 + 内容块，直观表达明暗。
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.xs),
                child: SizedBox(
                  height: 52,
                  child: Row(
                    children: <Widget>[
                      Container(
                        width: 18,
                        color: darkPreview
                            ? const Color(0xFF0C1626)
                            : const Color(0xFFE4F0FF),
                      ),
                      Expanded(
                        child: Container(
                          color: darkPreview
                              ? const Color(0xFF14243A)
                              : const Color(0xFFF2F7FF),
                          padding: const EdgeInsets.all(7),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Container(
                                width: 42,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: darkPreview
                                      ? const Color(0xFF6BB0FF)
                                      : const Color(0xFF1F6FEB),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Expanded(
                                child: Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: darkPreview
                                              ? const Color(0xFF1B3050)
                                              : Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            3,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    Expanded(
                                      child: mode == AppThemeMode.system
                                          ? Row(
                                              children: <Widget>[
                                                Expanded(
                                                  child: Container(
                                                    color: const Color(
                                                      0xFFDCEBFF,
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  child: Container(
                                                    color: const Color(
                                                      0xFF1B3050,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            )
                                          : Container(
                                              decoration: BoxDecoration(
                                                color: darkPreview
                                                    ? const Color(0xFF1B3050)
                                                    : Colors.white,
                                                borderRadius:
                                                    BorderRadius.circular(3),
                                              ),
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: <Widget>[
                  Icon(
                    mode.icon,
                    size: 16,
                    color: selected ? cs.primary : cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      mode.label,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 16,
                      color: cs.primary,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
