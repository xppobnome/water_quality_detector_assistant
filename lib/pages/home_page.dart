import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../models/workspace.dart';
import '../providers/workspace_provider.dart';
import '../widgets/workspace_picker_sheet.dart';
import 'calculation_page.dart';
import 'image_to_excel_page.dart';
import 'settings_page.dart';
import 'verification/workspace_detail_page.dart';

/// 工具页（中间 tab，默认展示）：3 个正方形小格入口 + 右上角齿轮设置。
///
/// 不包含「数据传输」（已独立为右侧 tab）。
/// 进入任一子工具，执行完成后均可通过「创建 / 保存到工作空间」归档成果。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  /// 欢迎卡片的一次性淡入（260ms，easeOut）。
  /// 用单例 tween（Tween 构造非 const）保证父级 rebuild 时不会重播动画。
  static final Tween<double> _entryTween = Tween<double>(begin: 0.0, end: 1.0);

  @override
  Widget build(BuildContext context) {
    final List<_FeatureTile> tiles = <_FeatureTile>[
      _FeatureTile(
        icon: Icons.table_chart_outlined,
        title: '图片转 Excel',
        subtitle: '拍照/选图 → 四角裁剪 → 自动识别表格 → 勾选行列 → 导出',
        onTap: () => _push(context, const ImageToExcelPage()),
      ),
      _FeatureTile(
        icon: Icons.calculate_outlined,
        title: '大肠杆菌计算',
        subtitle: '自己拍照/导入数据 → 吸光度拟合 → JSON+PNG+Excel 归档',
        onTap: () => _push(context, const CalculationPage()),
      ),
      _FeatureTile(
        icon: Icons.verified_outlined,
        title: '国标验证',
        subtitle: '选择工作空间 → OCR/手输数据 → 按国标公式计算与标红预警',
        onTap: () => _openVerification(context),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('工具'),
        actions: <Widget>[
          IconButton(
            tooltip: '设置（OCR 引擎）',
            onPressed: () => _push(context, const SettingsPage()),
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          int columns;
          if (constraints.maxWidth < 520) {
            columns = 2;
          } else {
            columns = 3;
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // 轻量隐式动画：仅欢迎卡片整体淡入 + 轻微上移（260ms，easeOut）。
                // 不给功能网格 / 列表逐项加动画，避免明显卡顿。
                TweenAnimationBuilder<double>(
                  tween: _entryTween,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOut,
                  builder: (BuildContext ctx, double value, Widget? child) {
                    return Opacity(
                      opacity: value,
                      child: Transform.translate(
                        offset: Offset(0, 10 * (1 - value)),
                        child: child,
                      ),
                    );
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: kPrimaryLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '水质检测仪助手',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: kPrimaryColor,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          '采集 → 识别 → 计算 → 国标验证 → 工作空间归档 → 数据传输',
                          style: TextStyle(color: Color(0xFF546E7A)),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    Text(
                      '功能入口',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => _openVerification(context),
                      icon: const Icon(Icons.folder_copy_outlined, size: 16),
                      label: const Text(
                        '从工作空间进入国标验证',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1,
                  ),
                  itemCount: tiles.length,
                  itemBuilder: (BuildContext context, int index) =>
                      tiles[index],
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: kPrimaryLight.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        Icons.lightbulb_outline,
                        color: kPrimaryColor,
                        size: 18,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '每个工具执行结束后，都可以「创建 / 保存到工作空间」，'
                          '生成的文件支持自定义名称，并按项目文件夹统一归档。',
                          style: TextStyle(fontSize: 12, color: kPrimaryColor),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context)
        .push<void>(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<void> _openVerification(BuildContext context) async {
    final Workspace? ws = await WorkspacePickerSheet.show(context);
    if (ws == null || !context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => WorkspaceDetailPage(workspaceId: ws.id),
      ),
    );
    if (context.mounted) {
      await context.read<WorkspaceProvider>().refresh();
    }
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          // 真机 140x140 格子：收紧内边距与字号，避免 RenderFlex 底部溢出。
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE0E0E0)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: kPrimaryLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: kPrimaryColor, size: 24),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: kPrimaryColor,
                ),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: kNeutralGrey),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
