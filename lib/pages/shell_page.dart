import 'package:flutter/material.dart';

import '../widgets/responsive_navigation.dart';
import 'home_page.dart';
import 'transfer_page.dart';
import 'workspace_list_page.dart';

/// 导航壳：左「工作空间」/ 中「工具」（默认）/ 右「数据传输」。
///
/// 桌面端为左侧 NavigationRail，移动端为底部 NavigationBar（由
/// [ResponsiveScaffold] 自动按宽度切换），保证 Android + Windows 一致体验。
/// 切换 tab 时用淡入 + 轻微上移过渡包住 [IndexedStack]，页面状态不丢。
class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage>
    with SingleTickerProviderStateMixin {
  /// 默认停留在中间的「工具」页。
  int _index = 1;

  /// 切 tab 过渡：260ms 淡入 + 轻微上移，easeOutCubic。
  /// 只驱动外层过渡 widget，[IndexedStack] 及其三个页面的 Element 不会被替换。
  late final AnimationController _transitionController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  late final Animation<double> _fade = CurvedAnimation(
    parent: _transitionController,
    curve: Curves.easeOutCubic,
  );

  late final Animation<Offset> _slide =
      Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _transitionController,
          curve: Curves.easeOutCubic,
        ),
      );

  static const List<ResponsiveDestination> _destinations =
      <ResponsiveDestination>[
        ResponsiveDestination(
          label: '工作空间',
          icon: Icons.folder_outlined,
          selectedIcon: Icons.folder,
        ),
        ResponsiveDestination(
          label: '工具',
          icon: Icons.grid_view_outlined,
          selectedIcon: Icons.grid_view,
        ),
        ResponsiveDestination(
          label: '数据传输',
          icon: Icons.wifi_outlined,
          selectedIcon: Icons.wifi,
        ),
      ];

  @override
  void initState() {
    super.initState();
    // 首次进入也淡入，避免生硬出现。
    _transitionController.forward(from: 0);
  }

  @override
  void dispose() {
    _transitionController.dispose();
    super.dispose();
  }

  void _select(int index) {
    setState(() => _index = index);
    _transitionController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = <Widget>[
      const WorkspacesPage(),
      const HomePage(),
      const TransferPage(),
    ];

    return ResponsiveScaffold(
      selectedIndex: _index,
      onDestinationSelected: _select,
      destinations: _destinations,
      child: FadeTransition(
        opacity: _fade,
        child: SlideTransition(
          position: _slide,
          // IndexedStack 必须保留：三个页面的滚动位置、provider 数据、
          // 输入框内容在切 tab 后都不会因页面重建而丢失。
          child: IndexedStack(index: _index, children: pages),
        ),
      ),
    );
  }
}
