import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../models/crop_quad.dart';
import '../models/water_quality_row.dart';
import '../providers/calculation_provider.dart';
import '../utils/number_utils.dart';
import '../widgets/camera_capture_page.dart';
import '../widgets/crop_flow.dart';
import '../widgets/fit_chart.dart';
import '../widgets/floating_image_window.dart';
import '../widgets/image_preview.dart';
import '../widgets/image_source_actions.dart';
import '../widgets/save_to_workspace_button.dart';

/// 大肠杆菌计算页（增量版）：自己拍照 / 导入数据，独立完成拟合与归档。
class CalculationPage extends StatefulWidget {
  const CalculationPage({super.key});

  @override
  State<CalculationPage> createState() => _CalculationPageState();
}

class _CalculationPageState extends State<CalculationPage> {
  /// 原图对照小窗是否显示，由 AppBar 右上角按钮手动开关。
  bool _showFloating = false;

  late final TextEditingController _concentrationController;
  late final TextEditingController _unitController;

  @override
  void initState() {
    super.initState();
    _concentrationController = TextEditingController(
      text: kDefaultConcentration.toInt().toString(),
    );
    _unitController = TextEditingController(text: kDefaultUnit);
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    final CalculationProvider provider = context.read<CalculationProvider>();
    await provider.init();
    if (!mounted) return;
    setState(() {
      _concentrationController.text = NumberUtils.format(
        provider.concentration,
        fractionDigits: 0,
      );
      _unitController.text = provider.unit;
    });
  }

  @override
  void dispose() {
    _concentrationController.dispose();
    _unitController.dispose();
    super.dispose();
  }

  /// 自定义拍照：可连续拍多张，取景框已对齐表格，直接逐张进入四点裁剪。
  /// 多张共用第一张的建议四点作为初始框，用户仍可逐张单独微调。
  Future<void> _onCaptured(List<CameraCaptureResult> results) async {
    if (results.isEmpty) return;
    final List<String> paths = results
        .map((CameraCaptureResult r) => r.path)
        .toList();
    final CropQuad initial = results.first.frame;
    final List<String> finalPaths = await runCropFlow(
      context,
      paths,
      initial: initial,
    );
    if (!mounted || finalPaths.isEmpty) return;
    context.read<CalculationProvider>().addImagePaths(finalPaths);
  }

  /// 相册 / 桌面选图：直接进入四点裁剪，不再弹窗询问。
  Future<void> _onPaths(List<String> paths) async {
    final List<String> finalPaths = await runCropFlow(context, paths);
    if (!mounted || finalPaths.isEmpty) return;
    context.read<CalculationProvider>().addImagePaths(finalPaths);
  }

  /// 预览图片；若用户在预览页完成裁剪，用新图片替换原图片。
  Future<void> _previewImage(String path) async {
    final String? cropped = await ImagePreview.show(context, imagePath: path);
    if (cropped == null || !mounted) return;
    context.read<CalculationProvider>().replaceImage(path, cropped);
  }

  Future<void> _manualEntry() async {
    final TextEditingController blank = TextEditingController();
    final TextEditingController detection = TextEditingController();
    final TextEditingController label = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('手动录入一组读数'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: label,
                decoration: const InputDecoration(labelText: '标签（可选）'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: blank,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '空白读数 *'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: detection,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '检测读数 *'),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      context.read<CalculationProvider>().addManualRow(
        blank: blank.text.trim(),
        detection: detection.text.trim(),
        label: label.text.trim(),
      );
    }
    blank.dispose();
    detection.dispose();
    label.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CalculationProvider calc = context.watch<CalculationProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('大肠杆菌计算'),
        actions: <Widget>[
          IconButton(
            icon: Icon(
              _showFloating
                  ? Icons.picture_in_picture_alt
                  : Icons.picture_in_picture_alt_outlined,
            ),
            tooltip: '原图对照小窗',
            onPressed: calc.imagePaths.isEmpty
                ? null
                : () => setState(() => _showFloating = !_showFloating),
          ),
        ],
      ),
      body: FloatingImageHost(
        imagePaths: calc.imagePaths,
        visible: _showFloating,
        onClose: () => setState(() => _showFloating = false),
        childBuilder: (ScrollController controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            // ------------------------------------------------ 数据采集
            const CaptureGuideCard(),
            const SizedBox(height: 12),
            Text('1. 采集数据', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              '本工具独立采集数据：拍照（取景框对齐表格）/ 相册 / 导入 Excel / 手动录入，'
              '识别后由本页自行完成拟合与归档，不依赖「图片转 Excel」页。',
              style: TextStyle(fontSize: 12, color: kNeutralGrey),
            ),
            const SizedBox(height: 10),
            ImageSourceActions(
              onCaptured: (List<CameraCaptureResult> results) =>
                  unawaited(_onCaptured(results)),
              onPaths: (List<String> p) => unawaited(_onPaths(p)),
              busy: calc.isLoading,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: calc.isLoading
                      ? null
                      : () => unawaited(
                          context.read<CalculationProvider>().importExcel(),
                        ),
                  icon: const Icon(Icons.file_open_outlined, size: 18),
                  label: const Text('导入 Excel'),
                ),
                OutlinedButton.icon(
                  onPressed: calc.isLoading
                      ? null
                      : () => unawaited(_manualEntry()),
                  icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
                  label: const Text('手动录入'),
                ),
              ],
            ),
            if (calc.imagePaths.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final String path in calc.imagePaths)
                    Stack(
                      children: <Widget>[
                        // 缩略图单独包一层点击：点击预览，不影响右上角的删除按钮。
                        GestureDetector(
                          onTap: () => unawaited(_previewImage(path)),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              File(path),
                              width: 64,
                              height: 64,
                              fit: BoxFit.cover,
                              // 缩略图只解码到约 3 倍显示尺寸，避免一次选多张
                              // 大图时全尺寸解码进内存造成进入页面卡顿。
                              cacheWidth: 240,
                              filterQuality: FilterQuality.low,
                              gaplessPlayback: true,
                              errorBuilder: (_, __, ___) => Container(
                                width: 64,
                                height: 64,
                                color: appSoftSurface(context),
                                child: const Icon(
                                  Icons.image,
                                  color: kPrimaryColor,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: GestureDetector(
                            onTap: () => context
                                .read<CalculationProvider>()
                                .removeImage(path),
                            child: Container(
                              decoration: const BoxDecoration(
                                color: kErrorColor,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close,
                                size: 15,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: calc.isLoading
                    ? null
                    : () => unawaited(
                        context.read<CalculationProvider>().recognizeImages(),
                      ),
                icon: const Icon(Icons.document_scanner_outlined),
                label: Text(calc.isLoading ? '识别中…' : '识别图片中的表格数据'),
              ),
            ],
            if (calc.lastMessage != null && calc.error == null) ...<Widget>[
              const SizedBox(height: 8),
              _Banner(
                color: kSuccessColor,
                icon: Icons.check_circle_outline,
                text: calc.lastMessage!,
              ),
            ],
            for (final String warning in calc.warnings) ...<Widget>[
              const SizedBox(height: 8),
              _Banner(
                color: kWarningColor,
                icon: Icons.warning_amber_rounded,
                text: warning,
              ),
            ],
            if (calc.error != null) ...<Widget>[
              const SizedBox(height: 8),
              _Banner(
                color: kErrorColor,
                icon: Icons.error_outline,
                text: calc.error!,
                onClose: () => context.read<CalculationProvider>().clearError(),
              ),
            ],

            // ------------------------------------------------ 计算
            const SizedBox(height: 20),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '2. 选择数据行与参数',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (calc.rows.isNotEmpty)
                  TextButton.icon(
                    onPressed: () =>
                        context.read<CalculationProvider>().clearRows(),
                    icon: const Icon(Icons.clear_all, size: 16),
                    label: const Text('清空数据', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (calc.rows.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.info_outline, color: kPrimaryColor),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text('还没有数据：请先拍照 / 选择图片识别、导入 Excel，或手动录入。'),
                      ),
                    ],
                  ),
                ),
              )
            else ...<Widget>[
              _buildRowSelection(context, calc, calc.rows),
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _concentrationController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(labelText: '标液浓度'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1,
                    child: TextField(
                      controller: _unitController,
                      decoration: const InputDecoration(labelText: '单位'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: calc.isLoading
                    ? null
                    : () => unawaited(_calculate(calc)),
                icon: const Icon(Icons.calculate_outlined),
                label: Text(calc.isLoading ? '计算中…' : '计算并拟合'),
              ),
            ],

            // ------------------------------------------------ 结果与归档
            if (calc.fitResult != null) ...<Widget>[
              const SizedBox(height: 24),
              _buildResultCard(calc),
              const SizedBox(height: 16),
              FitChart(fit: calc.fitResult!),
              const SizedBox(height: 16),
              Text(
                '3. 归档到工作空间',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              const Text(
                '一次保存 3 个文件：JSON（原始拟合数据）、PNG（拟合曲线图）、Excel（结果表），均可自定义文件名。',
                style: TextStyle(fontSize: 11, color: kNeutralGrey),
              ),
              const SizedBox(height: 10),
              SaveToWorkspaceButton(
                buildFiles: () =>
                    context.read<CalculationProvider>().buildArchiveFiles(),
                enabled: !calc.isLoading,
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildRowSelection(
    BuildContext context,
    CalculationProvider calc,
    List<WaterQualityRow> rows,
  ) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const <DataColumn>[
          DataColumn(label: Text('空白行')),
          DataColumn(label: Text('含菌行')),
          DataColumn(label: Text('标签')),
          DataColumn(label: Text('日期')),
          DataColumn(label: Text('时间')),
          DataColumn(label: Text('通道')),
          DataColumn(label: Text('空白')),
          DataColumn(label: Text('检测')),
          DataColumn(label: Text('操作')),
        ],
        rows: <DataRow>[
          for (final WaterQualityRow row in rows)
            DataRow(
              cells: <DataCell>[
                DataCell(
                  Radio<String>(
                    value: row.id,
                    groupValue: calc.blankRowId,
                    onChanged: (String? v) =>
                        context.read<CalculationProvider>().setBlankRow(v),
                  ),
                ),
                DataCell(
                  Radio<String>(
                    value: row.id,
                    groupValue: calc.sampleRowId,
                    onChanged: (String? v) =>
                        context.read<CalculationProvider>().setSampleRow(v),
                  ),
                ),
                DataCell(Text(row.result ?? '')),
                DataCell(Text(row.sampleDate ?? '')),
                DataCell(Text(row.sampleTime ?? '')),
                DataCell(Text(row.channelLabel)),
                DataCell(Text(row.blankRaw ?? '')),
                DataCell(Text(row.detectionRaw ?? '')),
                DataCell(
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: '删除该行',
                    onPressed: () =>
                        context.read<CalculationProvider>().removeRow(row.id),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildResultCard(CalculationProvider calc) {
    final fit = calc.fitResult!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '拟合结果（y = B·X + A）',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            _ResultRow(
              label: 'A（截距）',
              value: NumberUtils.format(fit.intercept),
            ),
            const SizedBox(height: 8),
            _ResultRow(label: 'B（斜率）', value: NumberUtils.format(fit.slope)),
            const SizedBox(height: 8),
            _ResultRow(label: 'R²', value: NumberUtils.format(fit.rSquared)),
            const SizedBox(height: 8),
            _ResultRow(
              label: '标液浓度',
              value:
                  '${NumberUtils.format(calc.concentration, fractionDigits: 0)} ${calc.unit}',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _calculate(CalculationProvider calc) async {
    final double? concentration = NumberUtils.parseNumber(
      _concentrationController.text,
    );
    if (concentration == null || concentration <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('标液浓度需为大于 0 的数字')));
      return;
    }
    calc
      ..setConcentration(concentration)
      ..setUnit(
        _unitController.text.trim().isEmpty
            ? kDefaultUnit
            : _unitController.text.trim(),
      );
    await calc.calculate();
    // 归档入口保留在页面底部的「保存到工作空间」按钮，计算完成后
    // 不再自动弹出归档提示。
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 120,
          child: Text(label, style: const TextStyle(color: kNeutralGrey)),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.icon,
    required this.text,
    this.onClose,
  });

  final Color color;
  final IconData icon;
  final String text;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: color, fontSize: 13)),
          ),
          if (onClose != null)
            GestureDetector(
              onTap: onClose,
              child: Icon(Icons.close, color: color, size: 18),
            ),
        ],
      ),
    );
  }
}
