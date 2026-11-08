import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/platform.dart';
import '../models/instrument_type.dart';
import '../models/ocr_parse_result.dart';
import '../models/report_file.dart';
import '../models/table_selection.dart';
import '../models/water_quality_row.dart';
import '../services/dedup_service.dart';
import '../services/excel_service.dart';
import '../services/ocr_service.dart';
import '../services/storage_service.dart';
import '../services/table_recognition_service.dart';
import '../utils/number_utils.dart';
import '../utils/workspace_utils.dart';

/// 图片转 Excel 状态（增量版）。
///
/// 去掉「手动选择仪器类型」：先四角裁剪 → 原始 OCR → 自动识别表格类型 →
/// 结构化行；用户可在结果表格中勾选行 / 列 / 单元格，导出与归档只保留勾选项。
class ImageToExcelProvider extends ChangeNotifier {
  ImageToExcelProvider({
    OcrService? ocr,
    ExcelService? excel,
    DedupService? dedup,
    required this.storage,
  }) : _injectedOcr = ocr,
       _excel = excel ?? ExcelService(),
       _dedup = dedup ?? DedupService() {
    // 预启动 OCR 引擎（Windows 本地 Python 引擎会在此加载模型）。
    unawaited(_resolveOcr().initEngine());
  }

  final OcrService? _injectedOcr;
  OcrService? _ocr;
  String? _ocrEngineUsed;
  final ExcelService _excel;
  final DedupService _dedup;
  final StorageService storage;

  OcrService _resolveOcr() {
    if (_injectedOcr != null) {
      _ocr = _injectedOcr;
      _ocrEngineUsed = 'injected';
      return _ocr!;
    }
    final String desired = storage.ocrEngine;
    if (_ocr != null && _ocrEngineUsed == desired) return _ocr!;
    _ocr?.disposeEngine();
    _ocr = createOcrService(storage: storage);
    _ocrEngineUsed = desired;
    return _ocr!;
  }

  /// 自动识别（或 Excel 导入推断）出的表格类型，仅供展示与列映射。
  InstrumentType instrument = InstrumentType.mcgs;

  /// 是否由自动识别得出（false 时 UI 提示人工核对表头）。
  bool autoDetected = false;

  List<String> imagePaths = <String>[];
  List<WaterQualityRow> rows = <WaterQualityRow>[];
  List<String> warnings = <String>[];
  TableSelection selection = TableSelection();
  bool isLoading = false;
  String? error;
  String? lastMessage;
  String? exportedPath;

  /// 最近一次识别的原始 OCR 文本（供「查看 OCR 原文」人工核对）。
  String? rawOcrText;

  int originalCount = 0;
  int dedupedCount = 0;

  /// 仍保留手动覆盖能力（自动识别不准时可在页面切换）。
  void setInstrument(InstrumentType type) {
    instrument = type;
    autoDetected = false;
    selection = TableSelection();
    notifyListeners();
  }

  // ---------------------------------------------------------------- 图片来源

  Future<void> pickImagesFromCamera() async {
    if (!isMobile) return;
    try {
      final XFile? image = await ImagePicker().pickImage(
        source: ImageSource.camera,
      );
      if (image != null) addImagePaths(<String>[image.path]);
    } catch (e) {
      error = '拍照失败：$e';
      notifyListeners();
    }
  }

  Future<void> pickImagesFromGallery() async {
    if (!isMobile) return;
    try {
      final List<XFile> images = await ImagePicker().pickMultiImage();
      if (images.isNotEmpty) {
        addImagePaths(images.map((XFile x) => x.path).toList());
      }
    } catch (e) {
      error = '选择图片失败：$e';
      notifyListeners();
    }
  }

  /// 跨平台文件选择（已由页面在 [addImagePaths] 前完成裁剪询问）。
  Future<void> pickImagesFromFilePicker() async {
    try {
      final List<PlatformFile> result = await FilePicker.pickFiles(
        type: FileType.image,
      );
      final List<String> paths = result
          .map((PlatformFile f) => f.path)
          .whereType<String>()
          .toList();
      if (paths.isNotEmpty) addImagePaths(paths);
    } catch (e) {
      error = '选择图片失败：$e';
      notifyListeners();
    }
  }

  /// 从系统剪贴板粘贴图片，返回临时文件路径（由页面再走裁剪流程）。
  Future<String?> pasteImageFromClipboard() async {
    try {
      final ClipboardData? data = await Clipboard.getData('image/png');
      final String? text = data?.text;
      if (text == null || text.isEmpty) {
        error = '剪贴板中没有图片，请先复制一张图片（Ctrl+C）';
        notifyListeners();
        return null;
      }
      final List<int> bytes = base64Decode(text);
      final Directory dir = await getTemporaryDirectory();
      final File file = File(
        p.join(dir.path, 'clip_${DateTime.now().microsecondsSinceEpoch}.png'),
      );
      await file.writeAsBytes(bytes);
      error = null;
      lastMessage = '已从剪贴板粘贴 1 张图片';
      notifyListeners();
      return file.path;
    } catch (e) {
      error = '粘贴图片失败：$e';
      notifyListeners();
      return null;
    }
  }

  /// 添加「已裁剪」的图片路径（裁剪流程由页面 [runCropFlow] 统一处理）。
  void addImagePaths(List<String> paths) {
    if (paths.isEmpty) return;
    imagePaths = <String>[...imagePaths, ...paths];
    lastMessage = '已添加 ${paths.length} 张图片';
    error = null;
    notifyListeners();
  }

  void removeImage(String path) {
    imagePaths = imagePaths.where((String e) => e != path).toList();
    notifyListeners();
  }

  /// 预览页重新裁剪后，用新图片替换原图片（保持列表位置）。
  void replaceImage(String oldPath, String newPath) {
    if (oldPath == newPath) return;
    imagePaths = imagePaths
        .map((String p) => p == oldPath ? newPath : p)
        .toList();
    notifyListeners();
  }

  void clearImages() {
    imagePaths = <String>[];
    notifyListeners();
  }

  // ---------------------------------------------------------------- 识别

  /// 原始 OCR → 自动判断表格类型 → 结构化行。
  Future<void> recognize() async {
    if (imagePaths.isEmpty) {
      error = '请先添加图片（拍照/选择/粘贴）';
      notifyListeners();
      return;
    }
    isLoading = true;
    error = null;
    warnings = <String>[];
    rawOcrText = null;
    notifyListeners();
    try {
      final OcrParseResult result = await TableRecognitionService(
        ocr: _resolveOcr(),
      ).recognizeTable(imagePaths);
      instrument = result.instrument;
      autoDetected = !result.warnings.any(
        (String w) => w.contains('未能自动判断仪器类型'),
      );
      rows = result.rows;
      rawOcrText = result.rawText;
      warnings = List<String>.from(result.warnings);
      selection = TableSelection();
      lastMessage =
          '识别完成：共 ${rows.length} 行'
          '（表格类型：${instrument.label}）';
    } on UnsupportedError catch (e) {
      error = e.message ?? '当前平台不支持 OCR，请导入 Excel';
    } catch (e) {
      error = '识别失败：$e';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// 导入既有 Excel（自动推断表格类型，无需用户选择仪器）。
  Future<void> importExistingExcel() async {
    try {
      final List<PlatformFile> result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['xlsx', 'xls'],
      );
      if (result.isEmpty) return;
      final String? path = result.single.path;
      if (path == null) {
        error = '无法读取所选文件路径';
        notifyListeners();
        return;
      }

      isLoading = true;
      error = null;
      notifyListeners();
      try {
        final InstrumentType type = await _excel.detectType(path);
        final List<WaterQualityRow> imported = await _excel.importExcel(
          path,
          type,
        );
        instrument = type;
        autoDetected = true;
        rows = imported;
        selection = TableSelection();
        rawOcrText = null;
        warnings = <String>['已按 Excel 表头自动判断表格类型：${type.label}'];
        lastMessage = '导入完成：共 ${imported.length} 行';
      } finally {
        isLoading = false;
        notifyListeners();
      }
    } catch (e) {
      isLoading = false;
      error = '导入失败：$e';
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- 勾选

  /// 是否处于「全选」态：空 selectedRowIds 或显式勾选行数 >= 全部行数，
  /// 且未标记 [TableSelection.noneSelected]。
  bool get isAllSelected =>
      !selection.noneSelected &&
      (selection.selectedRowIds.isEmpty ||
          selection.selectedRowIds.length >= rows.length);

  /// 空集合代表全选；从「全选」取消某一行时先物化全量再剔除。
  void toggleRowSelection(String rowId, bool on) {
    final TableSelection next = selection.clone();
    if (next.noneSelected && !on) return; // 已是「全不选」，取消勾选无意义
    if (on) next.noneSelected = false;
    if (!on && next.selectedRowIds.isEmpty) {
      next.selectedRowIds.addAll(rows.map((WaterQualityRow r) => r.id));
    }
    next.toggleRow(rowId, on);
    if (!next.noneSelected && next.selectedRowIds.length == rows.length) {
      next.selectedRowIds.clear();
    }
    selection = next;
    notifyListeners();
  }

  void toggleColumnSelection(String column, bool on) {
    final TableSelection next = selection.clone();
    if (!on && next.selectedColumns.isEmpty) {
      next.selectedColumns.addAll(instrument.headers);
    }
    next.toggleColumn(column, on);
    if (next.selectedColumns.length == instrument.headers.length) {
      next.selectedColumns.clear();
    }
    selection = next;
    notifyListeners();
  }

  void toggleCellSelection(String rowId, String column, bool on) {
    final TableSelection next = selection.clone();
    next.toggleCell(rowId, column, on);
    selection = next;
    notifyListeners();
  }

  /// 兼容旧调用：一键全选。
  void selectAll() => setAllSelected(true);

  /// 表头按钮：当前全选 → 「反选」（清空为 0 行）；否则 → 一键全选。
  void selectAllOrInvert() => setAllSelected(!isAllSelected);

  /// [selectAll] 为 true 时清空选中集合（= 全选）；为 false 时标记
  /// [TableSelection.noneSelected] 使 [TableSelection.apply] 返回 0 行。
  void setAllSelected(bool selectAll) {
    selection = selectAll
        ? TableSelection()
        : TableSelection(noneSelected: true);
    notifyListeners();
  }

  /// 应用勾选后的数据行。
  List<WaterQualityRow> selectedRows() =>
      selection.apply(rows, instrument.headers);

  // ---------------------------------------------------------------- 编辑 / 导出

  void updateCell(String rowId, String column, String value) {
    final int index = rows.indexWhere((WaterQualityRow r) => r.id == rowId);
    if (index < 0) return;
    final WaterQualityRow row = rows[index];
    row.cells[column] = value;

    switch (column) {
      case '采样日期':
        row.sampleDate = value;
        break;
      case '采样时间':
      case '时间':
        row.sampleTime = value;
        break;
      case '通道':
        row.channel = value;
        break;
      case '总大肠杆菌':
      case '分析结果':
      case '数据结果':
        row.result = value;
        break;
      case '单位':
        row.unit = value;
        break;
      case '空白对照':
      case '空白':
      case '空白值':
        row.blankRaw = value;
        row.blank = NumberUtils.parseNumber(value);
        break;
      case '测试对照':
      case '检测':
      case '当前值':
        row.detectionRaw = value;
        row.detection = NumberUtils.parseNumber(value);
        break;
      case '吸光度':
        row.absorbance = NumberUtils.parseNumber(value);
        break;
    }
    notifyListeners();
  }

  void removeRow(String rowId) {
    rows.removeWhere((WaterQualityRow r) => r.id == rowId);
    notifyListeners();
  }

  Future<void> export() async {
    final List<WaterQualityRow> target = _dedup.dedup(selectedRows());
    if (target.isEmpty) {
      error = '没有可导出的数据（请检查勾选状态）';
      notifyListeners();
      return;
    }
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      originalCount = rows.length;
      dedupedCount = target.length;
      exportedPath = await _excel.exportExcel(target);
      lastMessage = '导出成功：识别 $originalCount 行，勾选/去重后 $dedupedCount 行';
    } catch (e) {
      error = '导出失败：$e';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// 生成用于归档的 Excel（写临时目录，不弹保存对话框），返回待归档描述。
  Future<List<ReportFile>> buildArchiveFiles() async {
    final List<WaterQualityRow> target = _dedup.dedup(selectedRows());
    if (target.isEmpty) return <ReportFile>[];
    final Directory dir = await getTemporaryDirectory();
    final String path = await _excel.exportExcel(target, dir: dir.path);
    final String name = '水质数据_${timestampStamp(DateTime.now())}.xlsx';
    return <ReportFile>[ReportFile(path: path, name: name, kind: 'excel')];
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _ocr?.disposeEngine();
    super.dispose();
  }
}
