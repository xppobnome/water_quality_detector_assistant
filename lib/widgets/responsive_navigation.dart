import 'package:flutter/material.dart';

import '../core/design_system.dart';
import '../widgets/futuristic.dart';

/// 导航项描述。
class ResponsiveDestination {
  const ResponsiveDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// ============================================================================
/// 响应式导航壳（AQUA v2）
/// ============================================================================
/// - 宽度 >= [AppLayout.sidebarBreakpoint]（电脑 / 平板横屏）：
///   左侧 244px 未来感侧边栏：品牌区、发光选中态、系统状态卡、主题快捷切换。
/// - 宽度 < 断点（手机 / 窄窗口）：
///   底部浮动玻璃胶囊导航，4 项均分，选中项带渐变指示。
///
/// 两种形态共用同一份 [destinations] 与 [selectedIndex]，切换 tab 不重建页面，
/// 保留滚动位置、输入内容与 Provider 状态。
class ResponsiveScaffold extends StatelessWidget {
  const ResponsiveScaffold({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.child,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<ResponsiveDestination> destinations;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= AppLayout.sidebarBreakpoint) {
          return _desktop(context);
        }
        return _mobile(context);
      },
    );
  }

  Widget _desktop(BuildContext context) {
    return Scaffold(
      body: Row(
        children: <Widget>[
          _Sidebar(
            selectedIndex: selectedIndex,
            onDestinationSelected: onDestinationSelected,
            destinations: destinations,
          ),
          // 细渐变分割：比 1px 实线更有层次，且不影响布局宽度。
          Container(
            width: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  context.cs.primary.withValues(alpha: 0.30),
                  context.ds.cardBorder,
                  context.ds.cardBorder,
                ],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _mobile(BuildContext context) {
    return Scaffold(
      body: child,
      bottomNavigationBar: _MobileNavBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: onDestinationSelected,
        destinations: destinations,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 桌面侧边栏
// ---------------------------------------------------------------------------

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<ResponsiveDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final AppThemeExtension ds = context.ds;
    final ColorScheme cs = context.cs;
    return Container(
      width: AppLayout.sidebarWidth,
      decoration: BoxDecoration(
        color: ds.sidebar,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: ds.glow.withValues(alpha: 0.25),
            blurRadius: 28,
            offset: const Offset(2, 0),
          ),
        ],
      ),
      child: Stack(
        children: <Widget>[
          const Positioned.fill(
            child: AquaBackdrop(showGrid: false, glowStrength: 1.5),
          ),
          SafeArea(
            right: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.xxl,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _brand(context),
                  const SizedBox(height: AppSpacing.xxl),
                  _navLabel(context, '工作区'),
                  const SizedBox(height: AppSpacing.sm),
                  for (int i = 0; i < destinations.length; i++) ...<Widget>[
                    _SideNavItem(
                      destination: destinations[i],
                      selected: i == selectedIndex,
                      onTap: () => onDestinationSelected(i),
                    ),
                    if (i != destinations.length - 1)
                      const SizedBox(height: AppSpacing.xs),
                  ],
                  const Spacer(),
                  _statusCard(context),
                  const SizedBox(height: AppSpacing.md),
                  Container(
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: <Color>[
                          cs.primary.withValues(alpha: 0.35),
                          ds.cardBorder,
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  const AquaThemeToggle(),
                  const SizedBox(height: AppSpacing.xs),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.bolt_rounded,
                          size: 12,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'AQUA Lab · v1.0',
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
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
    );
  }

  Widget _brand(BuildContext context) {
    final ColorScheme cs = context.cs;
    return Row(
      children: <Widget>[
        const AquaLogo(size: 44),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ShaderMask(
                shaderCallback: (Rect bounds) =>
                    context.ds.accentGradient.createShader(bounds),
                child: Text(
                  'AQUA LAB',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '水质检测仪助手',
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _navLabel(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: context.cs.onSurfaceVariant,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.6,
        ),
      ),
    );
  }

  Widget _statusCard(BuildContext context) {
    final ColorScheme cs = context.cs;
    final AppThemeExtension ds = context.ds;
    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      elevated: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: ds.success,
                  shape: BoxShape.circle,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: ds.success.withValues(alpha: 0.6),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '系统就绪',
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '识别引擎本地运行 · 数据离线保存',
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 10.5,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _SideNavItem extends StatelessWidget {
  const _SideNavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final ResponsiveDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = context.cs;
    final AppThemeExtension ds = context.ds;
    return Semantics(
      selected: selected,
      button: true,
      label: destination.label,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: Curves.easeOut,
        height: AppLayout.minTouchTarget + 4,
        decoration: BoxDecoration(
          color: selected ? null : Colors.transparent,
          gradient: selected
              ? LinearGradient(
                  colors: <Color>[
                    ds.sidebarActive,
                    ds.sidebarActive.withValues(alpha: 0.55),
                  ],
                )
              : null,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected
                ? cs.primary.withValues(alpha: 0.30)
                : Colors.transparent,
            width: 1,
          ),
          boxShadow: selected ? ds.glowShadow(blur: 14) : null,
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Stack(
            children: <Widget>[
              if (selected)
                Positioned(
                  left: 0,
                  top: 12,
                  bottom: 12,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      gradient: ds.accentGradient,
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(3),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: Row(
                  children: <Widget>[
                    Icon(
                      selected ? destination.selectedIcon : destination.icon,
                      size: 20,
                      color: selected ? cs.primary : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        destination.label,
                        style: TextStyle(
                          color: selected ? cs.primary : cs.onSurface,
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: cs.primary.withValues(alpha: 0.7),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 移动端浮动胶囊导航
// ---------------------------------------------------------------------------

class _MobileNavBar extends StatelessWidget {
  const _MobileNavBar({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<ResponsiveDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final AppThemeExtension ds = context.ds;
    final double bottomInset = MediaQuery.paddingOf(context).bottom;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ds.navPill,
        border: Border(top: BorderSide(color: ds.cardBorder, width: 1)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: ds.glow.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.sm,
          right: AppSpacing.sm,
          top: AppSpacing.sm,
          bottom: (bottomInset > 0 ? bottomInset : AppSpacing.sm) + 2,
        ),
        child: Row(
          children: <Widget>[
            for (int i = 0; i < destinations.length; i++)
              Expanded(
                child: _MobileNavItem(
                  destination: destinations[i],
                  selected: i == selectedIndex,
                  onTap: () => onDestinationSelected(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MobileNavItem extends StatelessWidget {
  const _MobileNavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final ResponsiveDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = context.cs;
    final AppThemeExtension ds = context.ds;
    return Semantics(
      selected: selected,
      button: true,
      label: destination.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: Curves.easeOut,
          height: 56,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: selected ? null : Colors.transparent,
            gradient: selected
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      cs.primaryContainer,
                      cs.primaryContainer.withValues(alpha: 0.55),
                    ],
                  )
                : null,
            borderRadius: BorderRadius.circular(AppRadius.md),
            boxShadow: selected ? ds.glowShadow(blur: 12) : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                selected ? destination.selectedIcon : destination.icon,
                size: 21,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(height: 3),
              Text(
                destination.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                  fontSize: 10.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
