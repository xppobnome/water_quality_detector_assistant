import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/design_system.dart';
import '../models/workspace.dart';
import '../providers/workspace_provider.dart';
import '../widgets/futuristic.dart';
import '../widgets/workspace_picker_sheet.dart';
import 'calculation_page.dart';
import 'image_to_excel_page.dart';
import 'verification/workspace_detail_page.dart';

/// ============================================================================
/// 工具中枢（首页 / 默认 tab）
/// ============================================================================
/// 布局：氛围背景 → 渐变 Hero → 响应式功能矩阵（无冗余说明卡）。
/// - 手机（<620px）：功能入口改为单列横向列表卡，信息密度与触控面积兼顾。
/// - 电脑（>=620px）：三列玻璃功能卡，整体最大宽度 1180px 居中。
/// 全部颜色取自设计令牌，浅色 / 深色自动适配。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static final Tween<double> _entryTween = Tween<double>(begin: 0.0, end: 1.0);

  static const List<_FeatureSpec> _features = <_FeatureSpec>[
    _FeatureSpec(
      index: '01',
      icon: Icons.table_chart_outlined,
      title: '图片转 Excel',
      subtitle: '拍照 / 选图 → 四角裁剪 → 自动识别表格 → 勾选行列 → 导出',
      tag: 'OCR 识别',
    ),
    _FeatureSpec(
      index: '02',
      icon: Icons.calculate_outlined,
      title: '大肠杆菌计算',
      subtitle: '吸光度拟合 → A / B / R² 计算 → JSON + PNG + Excel 归档',
      tag: '数据拟合',
    ),
    _FeatureSpec(
      index: '03',
      icon: Icons.verified_outlined,
      title: '国标验证',
      subtitle: '工作空间 → 数据导入 → 按国标公式逐项计算与合规判定',
      tag: 'HJ 103',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.hub_outlined, size: 19, color: context.cs.primary),
            const SizedBox(width: AppSpacing.sm),
            const Text('工具中枢'),
          ],
        ),
        actions: <Widget>[
          const AquaThemeToggle(compact: true),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: AquaBody(
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.section,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppLayout.contentMaxWidth,
              ),
              child: TweenAnimationBuilder<double>(
                tween: _entryTween,
                duration: AppMotion.slow,
                curve: Curves.easeOutCubic,
                builder: (BuildContext ctx, double value, Widget? child) {
                  return Opacity(
                    opacity: value,
                    child: Transform.translate(
                      offset: Offset(0, 14 * (1 - value)),
                      child: child,
                    ),
                  );
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const _HeroCard(),
                    const SizedBox(height: AppSpacing.xxl),
                    LayoutBuilder(
                      builder:
                          (BuildContext context, BoxConstraints constraints) {
                            final bool narrow = constraints.maxWidth < 560;
                            return SectionHeader(
                              title: '功能矩阵',
                              subtitle: '从现场采集到国标判定，一条完整的数据链路',
                              icon: Icons.apps_rounded,
                              action: narrow
                                  ? IconButton(
                                      tooltip: '从工作空间进入国标验证',
                                      onPressed: () =>
                                          _openVerification(context),
                                      icon: const Icon(
                                        Icons.folder_copy_outlined,
                                        size: 18,
                                      ),
                                    )
                                  : TextButton.icon(
                                      onPressed: () =>
                                          _openVerification(context),
                                      icon: const Icon(
                                        Icons.folder_copy_outlined,
                                        size: 15,
                                      ),
                                      label: const Text(
                                        '从工作空间进入国标验证',
                                        style: TextStyle(fontSize: 11.5),
                                      ),
                                    ),
                            );
                          },
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    LayoutBuilder(
                      builder:
                          (BuildContext context, BoxConstraints constraints) {
                            final bool compact = constraints.maxWidth < 620;
                            if (compact) {
                              return Column(
                                children: <Widget>[
                                  for (
                                    int i = 0;
                                    i < _features.length;
                                    i++
                                  ) ...<Widget>[
                                    _FeatureRow(
                                      spec: _features[i],
                                      onTap: () => _onFeatureTap(context, i),
                                    ),
                                    if (i != _features.length - 1)
                                      const SizedBox(height: AppSpacing.md),
                                  ],
                                ],
                              );
                            }
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                for (
                                  int i = 0;
                                  i < _features.length;
                                  i++
                                ) ...<Widget>[
                                  Expanded(
                                    child: _FeatureCard(
                                      spec: _features[i],
                                      onTap: () => _onFeatureTap(context, i),
                                    ),
                                  ),
                                  if (i != _features.length - 1)
                                    const SizedBox(width: AppSpacing.lg),
                                ],
                              ],
                            );
                          },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onFeatureTap(BuildContext context, int index) {
    switch (index) {
      case 0:
        _push(context, const ImageToExcelPage());
      case 1:
        _push(context, const CalculationPage());
      case 2:
        _openVerification(context);
    }
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

// ---------------------------------------------------------------------------
// 规格模型
// ---------------------------------------------------------------------------

class _FeatureSpec {
  const _FeatureSpec({
    required this.index,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tag,
  });

  final String index;
  final IconData icon;
  final String title;
  final String subtitle;
  final String tag;
}

// ---------------------------------------------------------------------------
// Hero
// ---------------------------------------------------------------------------

class _HeroCard extends StatelessWidget {
  const _HeroCard();

  @override
  Widget build(BuildContext context) {
    final AppThemeExtension ds = context.ds;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 208),
      decoration: BoxDecoration(
        gradient: ds.heroGradient,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: ds.glassBorder, width: 1),
        boxShadow: ds.glowShadow(blur: 32),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: CustomPaint(
              painter: _HeroPatternPainter(
                lineColor: ds.accentColors.first,
                dotColor: ds.accentColors.last,
              ),
            ),
          ),
          Positioned(
            right: -46,
            top: -62,
            child: _HeroOrb(colors: ds.accentColors, dark: ds.isDark),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                AquaPill(
                  label: 'AQUA LAB  ·  智能检测工作流',
                  icon: Icons.auto_awesome_rounded,
                  color: ds.heroInk,
                  filled: false,
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  '水质检测仪助手',
                  style: TextStyle(
                    color: ds.heroInk,
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.8,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '采集 → 识别 → 计算 → 国标验证 → 工作空间归档 → 数据传输',
                  style: TextStyle(
                    color: ds.heroInk.withValues(alpha: 0.72),
                    fontSize: 12.5,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: <Widget>[
                    _HeroMetric(
                      icon: Icons.extension_outlined,
                      label: '3 项核心工具',
                      ink: ds.heroInk,
                    ),
                    _HeroMetric(
                      icon: Icons.wifi_off_rounded,
                      label: '离线 OCR 识别',
                      ink: ds.heroInk,
                    ),
                    _HeroMetric(
                      icon: Icons.devices_rounded,
                      label: '手机 · 电脑协同',
                      ink: ds.heroInk,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroMetric extends StatelessWidget {
  const _HeroMetric({
    required this.icon,
    required this.label,
    required this.ink,
  });

  final IconData icon;
  final String label;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: ink.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: ink.withValues(alpha: 0.85)),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: ink,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroOrb extends StatelessWidget {
  const _HeroOrb({required this.colors, required this.dark});

  final List<Color> colors;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 250,
      height: 250,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: <Color>[
            colors.last.withValues(alpha: dark ? 0.42 : 0.30),
            colors.first.withValues(alpha: dark ? 0.22 : 0.14),
            Colors.transparent,
          ],
          stops: const <double>[0, 0.55, 1],
        ),
      ),
      child: CustomPaint(
        painter: _OrbRingPainter(color: colors.last, dark: dark),
      ),
    );
  }
}

class _OrbRingPainter extends CustomPainter {
  const _OrbRingPainter({required this.color, required this.dark});

  final Color color;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    for (double r = 44; r <= 112; r += 22) {
      paint.color = color.withValues(
        alpha: (dark ? 0.26 : 0.20) * (1 - (r - 44) / 140),
      );
      canvas.drawCircle(center, r, paint);
    }
    // 中心水滴标记
    final Paint dot = Paint()
      ..color = color.withValues(alpha: dark ? 0.55 : 0.40)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 8, dot);
    canvas.drawCircle(center, 3, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _OrbRingPainter old) =>
      old.color != color || old.dark != dark;
}

class _HeroPatternPainter extends CustomPainter {
  const _HeroPatternPainter({required this.lineColor, required this.dotColor});

  final Color lineColor;
  final Color dotColor;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint grid = Paint()
      ..color = lineColor.withValues(alpha: 0.07)
      ..strokeWidth = 0.8;
    const double step = 26;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final Paint dots = Paint()
      ..color = dotColor.withValues(alpha: 0.16)
      ..strokeWidth = 1.4;
    for (double x = step; x <= size.width; x += step * 3) {
      for (double y = step; y <= size.height; y += step * 3) {
        canvas.drawCircle(Offset(x, y), 1.2, dots);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HeroPatternPainter old) =>
      old.lineColor != lineColor || old.dotColor != dotColor;
}

// ---------------------------------------------------------------------------
// 功能入口：电脑端三列卡片 / 手机端单列横向卡
// ---------------------------------------------------------------------------

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.spec, required this.onTap});

  final _FeatureSpec spec;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = context.cs;
    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: SizedBox(
        height: 166,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                GlowIcon(icon: spec.icon, size: 46),
                const Spacer(),
                Text(
                  spec.index,
                  style: TextStyle(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              spec.title,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Text(
                spec.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 11.5,
                  height: 1.45,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: <Widget>[
                AquaPill(label: spec.tag, color: cs.primary),
                const Spacer(),
                Text(
                  '进入',
                  style: TextStyle(
                    color: cs.primary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 3),
                Icon(Icons.arrow_forward_rounded, size: 14, color: cs.primary),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.spec, required this.onTap});

  final _FeatureSpec spec;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = context.cs;
    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: <Widget>[
          GlowIcon(icon: spec.icon, size: 46),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  spec.title,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  spec.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Icon(
            Icons.arrow_forward_ios_rounded,
            size: 15,
            color: cs.primary.withValues(alpha: 0.75),
          ),
        ],
      ),
    );
  }
}
