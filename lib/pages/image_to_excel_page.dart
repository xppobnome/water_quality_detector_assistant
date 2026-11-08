import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../models/crop_quad.dart';
import '../models/water_quality_row.dart';
import '../providers/image_to_excel_provider.dart';
import '../services/dedup_service.dart';
import '../widgets/camera_capture_page.dart';
import '../widgets/crop_flow.dart';
import '../widgets/editable_result_table.dart';
import '../widgets/floating_image_window.dart';
import '../widgets/image_preview.dart';
import '../widgets/image_source_actions.dart';
import '../widgets/save_to_workspace_button.dart';

/// 图片转 Excel 页：不选择仪器类型，自动识别表格。
///
/// 流程：自定义拍照（长方形取景框对齐数据表格）/ 相册 → 四角裁剪 →
/// 原始 OCR → 自动判断表头类型 → 结构化行 → 勾选行列/单元格 →
/// 去重导出 / 归档到工作空间。
///
/// 移动端图片来源只有「拍照」「相册」；桌面端保留必要的「选择图片」。
///
/// 复用模式（[selectionMode]）：由「工作空间详情页 → 选择图片并 OCR」进入，
/// 底部出现「使用所选数据」按钮，点击后把去重后的勾选行回传调用方。
class ImageToExcelPage extends StatefulWidget {
  const ImageToExcelPage({
    super.key,
    this.selectionMode = false,
    this.appBarTitle,
  });

  /// 是否为「选择数据」模式：仅回传数据，不做导出/归档。
  final bool selectionMode;

  /// 自定义标题（选择模式下生效，默认「选择图片并 OCR」）。
  final String? appBarTitle;

  @override
  State<ImageToExcelPage> createState() => _ImageToExcelPageState();
}

class _ImageToExcelPageState extends State<ImageToExcelPage> {
  /// 原图对照小窗是否显示，由 AppBar 右上角按钮手动开关。
  bool _showFloating = false;

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
    context.read<ImageToExcelProvider>().addImagePaths(finalPaths);
  }

  /// 相册 / 桌面选图：直接进入四点裁剪，不再弹窗询问。
  Future<void> _onPaths(List<String> paths) async {
    final List<String> finalPaths = await runCropFlow(context, paths);
    if (!mounted || finalPaths.isEmpty) return;
    context.read<ImageToExcelProvider>().addImagePaths(finalPaths);
  }

  /// 预览图片；若用户在预览页完成裁剪，用新图片替换原图片。
  Future<void> _previewImage(String path) async {
    final String? cropped = await ImagePreview.show(context, imagePath: path);
    if (cropped == null || !mounted) return;
    context.read<ImageToExcelProvider>().replaceImage(path, cropped);
  }

  /// 识别完成后只更新状态；归档入口保留在页面底部的
  /// [SaveToWorkspaceButton]，不再主动弹出归档提示。
  Future<void> _recognize() async {
    await context.read<ImageToExcelProvider>().recognize();
  }

  /// 弹窗展示原始 OCR 文本，[SelectableText] 支持长按复制 / 全选。
  void _showRawOcr(BuildContext context, String raw) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('OCR 原文'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(raw)),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 选择模式：把「已勾选 + 去重」的行回传给调用方（工作空间详情页）。
  void _useSelected() {
    final ImageToExcelProvider provider = context.read<ImageToExcelProvider>();
    final List<WaterQualityRow> chosen = DedupService().dedup(
      provider.selectedRows(),
    );
    if (chosen.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先识别出数据并勾选')));
      return;
    }
    Navigator.of(context).pop<List<WaterQualityRow>>(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final ImageToExcelProvider provider = context.watch<ImageToExcelProvider>();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.selectionMode
              ? (widget.appBarTitle ?? '选择图片并 OCR')
              : '图片转 Excel',
        ),
        actions: <Widget>[
          IconButton(
            icon: Icon(
              _showFloating
                  ? Icons.picture_in_picture_alt
                  : Icons.picture_in_picture_alt_outlined,
            ),
            tooltip: '原图对照小窗',
            onPressed: provider.imagePaths.isEmpty
                ? null
                : () => setState(() => _showFloating = !_showFloating),
          ),
        ],
      ),
      bottomNavigationBar: widget.selectionMode ? _bottomBar(provider) : null,
      body: FloatingImageHost(
        imagePaths: provider.imagePaths,
        visible: _showFloating,
        onClose: () => setState(() => _showFloating = false),
        childBuilder: (ScrollController controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            // 自动识别说明
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kPrimaryLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.auto_awesome_outlined,
                    color: kPrimaryColor,
                    size: 20,
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '无需选择仪器类型：识别到表格后按表头自动判断结构'
                      '（总大肠菌群 / E.co / 吸光度类表格，含总磷·总铜），'
                      '识别不出来会提示人工核对。',
                      style: TextStyle(fontSize: 12, color: kPrimaryColor),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const CaptureGuideCard(),
            const SizedBox(height: 12),
            Text('1. 添加图片', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ImageSourceActions(
              onCaptured: (List<CameraCaptureResult> results) =>
                  unawaited(_onCaptured(results)),
              onPaths: (List<String> paths) => unawaited(_onPaths(paths)),
              busy: provider.isLoading,
            ),
            const SizedBox(height: 12),
            if (provider.imagePaths.isNotEmpty) ...<Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final String path in provider.imagePaths)
                    Stack(
                      children: <Widget>[
                        // 缩略图单独包一层点击：点击预览，不影响右上角的删除按钮。
                        GestureDetector(
                          onTap: () => unawaited(_previewImage(path)),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              File(path),
                              width: 72,
                              height: 72,
                              fit: BoxFit.cover,
                              // 缩略图只解码到约 3 倍显示尺寸，避免一次选多张
                              // 大图时全尺寸解码进内存造成进入页面卡顿。
                              cacheWidth: 240,
                              filterQuality: FilterQuality.low,
                              gaplessPlayback: true,
                              errorBuilder: (_, __, ___) => Container(
                                width: 72,
                                height: 72,
                                color: kPrimaryLight,
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
                                .read<ImageToExcelProvider>()
                                .removeImage(path),
                            child: Container(
                              decoration: const BoxDecoration(
                                color: kErrorColor,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: provider.isLoading
                    ? null
                    : () => unawaited(_recognize()),
                icon: const Icon(Icons.document_scanner_outlined),
                label: Text(provider.isLoading ? '识别中…' : '开始识别'),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () =>
                    context.read<ImageToExcelProvider>().clearImages(),
                child: const Text('清空图片'),
              ),
            ],
            if (provider.error != null) ...<Widget>[
              const SizedBox(height: 12),
              _Banner(
                color: kErrorColor,
                icon: Icons.error_outline,
                text: provider.error!,
                onClose: () =>
                    context.read<ImageToExcelProvider>().clearError(),
              ),
            ],
            for (final String warning in provider.warnings) ...<Widget>[
              const SizedBox(height: 8),
              _Banner(
                color: kWarningColor,
                icon: Icons.warning_amber_rounded,
                text: warning,
              ),
            ],
            if (provider.lastMessage != null &&
                provider.error == null) ...<Widget>[
              const SizedBox(height: 8),
              _Banner(
                color: kSuccessColor,
                icon: Icons.check_circle_outline,
                text: provider.lastMessage!,
              ),
            ],
            if (provider.rows.isNotEmpty) ...<Widget>[
              const SizedBox(height: 20),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '2. 框选 / 校正数据',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (provider.rawOcrText != null &&
                      provider.rawOcrText!.trim().isNotEmpty)
                    TextButton.icon(
                      onPressed: () =>
                          _showRawOcr(context, provider.rawOcrText!),
                      icon: const Icon(Icons.article_outlined, size: 16),
                      label: const Text(
                        '查看 OCR 原文',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  Chip(
                    avatar: Icon(
                      provider.autoDetected
                          ? Icons.check_circle_outline
                          : Icons.help_outline,
                      size: 16,
                      color: provider.autoDetected
                          ? kSuccessColor
                          : kWarningColor,
                    ),
                    label: Text(
                      provider.instrument.shortLabel,
                      style: const TextStyle(fontSize: 11),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                '首列勾选整行、表头勾选整列、单元格右侧小方框可单独排除；'
                '表格可左右滑动查看完整内容，长文本悬停/长按可看全文。'
                '导出与归档只保留勾选内容。',
                style: TextStyle(fontSize: 11, color: kNeutralGrey),
              ),
              const SizedBox(height: 8),
              EditableResultTable(
                rows: provider.rows,
                instrument: provider.instrument,
                selection: provider.selection,
                allSelected: provider.isAllSelected,
                onSelectAll: (bool selectAll) => context
                    .read<ImageToExcelProvider>()
                    .setAllSelected(selectAll),
                onRowToggle: (String id, bool on) => context
                    .read<ImageToExcelProvider>()
                    .toggleRowSelection(id, on),
                onColumnToggle: (String col, bool on) => context
                    .read<ImageToExcelProvider>()
                    .toggleColumnSelection(col, on),
                onCellToggle: (String id, String col, bool on) => context
                    .read<ImageToExcelProvider>()
                    .toggleCellSelection(id, col, on),
                onCellChanged: (String id, String col, String v) =>
                    context.read<ImageToExcelProvider>().updateCell(id, col, v),
                onRemoveRow: (String id) =>
                    context.read<ImageToExcelProvider>().removeRow(id),
              ),
              const SizedBox(height: 16),
              if (!widget.selectionMode) ...<Widget>[
                FilledButton.icon(
                  onPressed: provider.isLoading
                      ? null
                      : () => unawaited(
                          context.read<ImageToExcelProvider>().export(),
                        ),
                  icon: const Icon(Icons.table_view_outlined),
                  label: Text(provider.isLoading ? '导出中…' : '合并去重并导出 Excel'),
                ),
                if (provider.exportedPath != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    '已导出：${provider.exportedPath}',
                    style: const TextStyle(fontSize: 11, color: kNeutralGrey),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  '3. 归档到工作空间',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SaveToWorkspaceButton(
                  buildFiles: () =>
                      context.read<ImageToExcelProvider>().buildArchiveFiles(),
                  enabled: !provider.isLoading,
                ),
              ] else ...<Widget>[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: kPrimaryLight,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        Icons.touch_app_outlined,
                        size: 18,
                        color: kPrimaryColor,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '勾选需要的数据行后，点击底部「使用所选数据」'
                          '把数据带入工作空间数据集。',
                          style: TextStyle(fontSize: 12, color: kPrimaryColor),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  /// 选择模式底部固定条：「使用所选数据」。
  Widget _bottomBar(ImageToExcelProvider provider) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: provider.isLoading ? null : _useSelected,
            icon: const Icon(Icons.check),
            label: const Text('使用所选数据'),
          ),
        ),
      ),
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
