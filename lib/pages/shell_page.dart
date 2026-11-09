import 'package:flutter/material.dart';

import '../core/design_system.dart';
import '../widgets/responsive_navigation.dart';
import 'home_page.dart';
import 'settings_page.dart';
import 'transfer_page.dart';
import 'workspace_list_page.dart';

/// 导航壳：工作空间 / 工具（默认）/ 数据传输 / 设置。
///
/// 电脑端为 244px 未来感侧边栏，手机端为浮动胶囊底栏（由
/// [ResponsiveScaffold] 按 900px 断点自动切换）。设置页纳入 tab，
/// 两端都能一步直达外观切换，无需再从隐藏的齿轮入口进入。
///
/// 切 tab 时用淡入 + 轻微上移过渡包住 [IndexedStack]：
/// 三个工具页与设置页的 Element 不会重建，滚动位置 / 输入内容 / Provider 数据不丢。
class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage>
    with SingleTickerProviderStateMixin {
  /// 默认停留在「工具」页。
  int _index = 1;

  late final AnimationController _transitionController = AnimationController(
    vsync: this,
    duration: AppMotion.normal,
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
          selectedIcon: Icons.folder_rounded,
        ),
        ResponsiveDestination(
          label: '工具',
          icon: Icons.grid_view_outlined,
          selectedIcon: Icons.grid_view_rounded,
        ),
        ResponsiveDestination(
          label: '数据传输',
          icon: Icons.wifi_outlined,
          selectedIcon: Icons.wifi_rounded,
        ),
        ResponsiveDestination(
          label: '设置',
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings_rounded,
        ),
      ];

  @override
  void initState() {
    super.initState();
    _transitionController.forward(from: 0);
  }

  @override
  void dispose() {
    _transitionController.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    _transitionController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = <Widget>[
      const WorkspacesPage(),
      const HomePage(),
      const TransferPage(),
      const SettingsPage(),
    ];

    return ResponsiveScaffold(
      selectedIndex: _index,
      onDestinationSelected: _select,
      destinations: _destinations,
      child: FadeTransition(
        opacity: _fade,
        child: SlideTransition(
          position: _slide,
          child: IndexedStack(index: _index, children: pages),
        ),
      ),
    );
  }
}
