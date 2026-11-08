import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../models/fit_result.dart';
import '../models/instrument_type.dart';
import '../models/report_file.dart';
import '../models/water_quality_row.dart';
import '../services/excel_service.dart';
import '../services/fit_report_service.dart';
import '../services/fit_service.dart';
import '../services/ocr_service.dart';
import '../services/storage_service.dart';
import '../services/table_recognition_service.dart';
import '../utils/result_validator.dart';

/// 大肠杆菌吸光度计算 + 一次函数拟合状态（增量版：独立采集数据）。
///
/// 不再依赖「图片转 Excel」页的识别结果：本工具自己拍照 / 选图 / 裁剪 /
/// OCR 识别 / 导入 Excel / 手动录入，然后完成计算与三件套归档。
class CalculationProvider extends ChangeNotifier {
  CalculationProvider({
    FitService? fit,
    StorageService? storage,
    OcrService? ocr,
  }) : _fit = fit ?? FitService(),
       _storage = storage ?? StorageService(),
       _injectedOcr = ocr,
       _excel = ExcelService() {
    unawaited(_resolveOcr().initEngine());
  }

  final FitService _fit;
  final StorageService _storage;
  final ExcelService _excel;
  final OcrService? _injectedOcr;
  OcrService? _ocr;
  String? _ocrEngineUsed;

  OcrService _resolveOcr() {
    if (_injectedOcr != null) {
      _ocr = _injectedOcr;
      _ocrEngineUsed = 'injected';
      return _ocr!;
    }
    final String desired = _storage.ocrEngine;
    if (_ocr != null && _ocrEngineUsed == desired) return _ocr!;
    _ocr?.disposeEngine();
    _ocr = createOcrService(storage: _storage);
    _ocrEngineUsed = desired;
    return _ocr!;
  }

  String? blankRowId;
  String? sampleRowId;
  double concentration = kDefaultConcentration;
  String unit = kDefaultUnit;
  FitResult? fitResult;
  bool isLoading = false;
  String? error;
  String? lastMessage;
  List<String> warnings = <String>[];

  /// 本工具自己维护的数据行。
  List<WaterQualityRow> rows = <WaterQualityRow>[];

  /// 已添加（裁剪后）的图片路径。
  List<String> imagePaths = <String>[];

  /// 自动识别出的表格类型（展示用）。
  InstrumentType instrument = InstrumentType.mcgs;

  Future<void> init() async {
    await _storage.init();
    concentration = _storage.standardConcentration;
    unit = _storage.standardUnit;
    notifyListeners();
  }

  // ---------------------------------------------------------------- 数据采集

  void addImagePaths(List<String> paths) {
    if (paths.isEmpty) return;
    imagePaths = <String>[...imagePaths, ...paths];
    error = null;
    lastMessage = '已添加 ${paths.length} 张图片，可开始识别';
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

  /// 对本工具自己的图片做 OCR（自动判断表格类型）。
  Future<void> recognizeImages() async {
    if (imagePaths.isEmpty) {
      error = '请先拍照或选择图片';
      notifyListeners();
      return;
    }
    isLoading = true;
    error = null;
    warnings = <String>[];
    notifyListeners();
    try {
      final result = await TableRecognitionService(ocr: _resolveOcr())
          .recognizeTable(imagePaths);
      instrument = result.instrument;
      rows = result.rows;
      warnings = List<String>.from(result.warnings);
      _resetSelection();
      lastMessage = '识别完成：共 ${rows.length} 行（${instrument.shortLabel}）';
    } catch (e) {
      error = '识别失败：$e';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// 导入既有 Excel（自动判断表格类型）。
  Future<void> importExcel() async {
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
        instrument = type;
        rows = await _excel.importExcel(path, type);
        warnings = <String>[];
        _resetSelection();
        lastMessage = '导入完成：共 ${rows.length} 行';
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

  /// OCR 不可用时手动录入一组「空白 / 检测」读数。
  void addManualRow({
    required String blank,
    required String detection,
    String label = '',
  }) {
    rows = <WaterQualityRow>[
      ...rows,
      WaterQualityRow.fromCells(
        instrument: InstrumentType.mcgs,
        cells: <String, String>{
          '采样日期': '',
          '采样时间': '',
          '总大肠杆菌': label,
          '单位': unit,
          '空白对照': blank,
          '测试对照': detection,
        },
      ),
    ];
    error = null;
    lastMessage = '已添加 1 行手动数据';
    notifyListeners();
  }

  void removeRow(String id) {
    rows = rows.where((WaterQualityRow r) => r.id != id).toList();
    if (blankRowId == id) blankRowId = null;
    if (sampleRowId == id) sampleRowId = null;
    notifyListeners();
  }

  void clearRows() {
    rows = <WaterQualityRow>[];
    _resetSelection();
    fitResult = null;
    notifyListeners();
  }

  void _resetSelection() {
    blankRowId = null;
    sampleRowId = null;
    fitResult = null;
  }

  // ---------------------------------------------------------------- 计算

  void setBlankRow(String? id) {
    blankRowId = id;
    notifyListeners();
  }

  void setSampleRow(String? id) {
    sampleRowId = id;
    notifyListeners();
  }

  void setConcentration(double value) {
    concentration = value;
    notifyListeners();
  }

  void setUnit(String value) {
    unit = value;
    notifyListeners();
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  Future<void> calculate() async {
    error = null;
    warnings = <String>[];

    if (rows.isEmpty) {
      error = '请先拍照 / 导入 / 手动录入数据';
      notifyListeners();
      return;
    }
    if (blankRowId == null || sampleRowId == null) {
      error = '请先选择空白行与含菌行';
      notifyListeners();
      return;
    }
    if (blankRowId == sampleRowId) {
      error = '空白行与含菌行不能为同一行';
      notifyListeners();
      return;
    }
    if (concentration <= 0) {
      error = '标液浓度需大于 0';
      notifyListeners();
      return;
    }

    final WaterQualityRow? blankRow = _find(blankRowId);
    final WaterQualityRow? sampleRow = _find(sampleRowId);
    if (blankRow == null || sampleRow == null) {
      error = '未找到所选数据行';
      notifyListeners();
      return;
    }
    if (!blankRow.instrument.supportsFit || !sampleRow.instrument.supportsFit) {
      error = '总铜在线分析仪不参与大肠杆菌拟合';
      notifyListeners();
      return;
    }

    final double? blankAbs = _fit.calcAbsorbance(
      blankRow.blank,
      blankRow.detection,
    );
    final double? sampleAbs = _fit.calcAbsorbance(
      sampleRow.blank,
      sampleRow.detection,
    );

    if (blankAbs == null) {
      warnings.add('空白行：${_rowIssue(blankRow) ?? '空白/检测为空或非数值，无法计算吸光度'}');
    }
    if (sampleAbs == null) {
      warnings.add('含菌行：${_rowIssue(sampleRow) ?? '空白/检测为空或非数值，无法计算吸光度'}');
    }
    if (blankAbs == null || sampleAbs == null) {
      fitResult = null;
      notifyListeners();
      return;
    }

    isLoading = true;
    notifyListeners();
    try {
      final List<FitPoint> points = <FitPoint>[
        FitPoint(0, blankAbs),
        FitPoint(concentration, sampleAbs),
      ];
      fitResult = _fit.linearFit(points);
      await _storage.setStandardConcentration(concentration);
      await _storage.setStandardUnit(unit);
      lastMessage = '拟合完成，可保存 JSON + PNG + Excel 到工作空间';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// 归档三件套：JSON + PNG + Excel。
  Future<List<ReportFile>> buildArchiveFiles() async {
    final FitResult? fit = fitResult;
    if (fit == null) return <ReportFile>[];
    return FitReportService().build(
      fit: fit,
      concentration: concentration,
      unit: unit,
    );
  }

  String? _rowIssue(WaterQualityRow row) =>
      ResultValidator.blankIssue(row) ?? ResultValidator.detectionIssue(row);

  WaterQualityRow? _find(String? id) {
    if (id == null) return null;
    for (final WaterQualityRow row in rows) {
      if (row.id == id) return row;
    }
    return null;
  }

  @override
  void dispose() {
    _ocr?.disposeEngine();
    super.dispose();
  }
}
