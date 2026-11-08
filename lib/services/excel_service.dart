import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/instrument_type.dart';
import '../models/water_quality_row.dart';
import '../utils/table_structure_detector.dart';

/// Excel 生成 / 导入。
class ExcelService {
  /// 从 Excel 头部若干行推断表格类型（去掉手动选择仪器类型后使用）。
  ///
  /// 读取前 3 行拼成文本交给 [detectInstrumentType]；无法判断时降级为 MCGS。
  Future<InstrumentType> detectType(String path) async {
    final File file = File(path);
    if (!await file.exists()) return InstrumentType.mcgs;
    try {
      final List<int> bytes = await file.readAsBytes();
      final Excel excel = Excel.decodeBytes(bytes);
      if (excel.tables.isEmpty) return InstrumentType.mcgs;
      final Sheet sheet = excel.tables.values.first;
      final StringBuffer buffer = StringBuffer();
      for (int r = 0; r < sheet.rows.length && r < 3; r++) {
        for (final Data? cell in sheet.rows[r]) {
          buffer.write(_cellToText(cell));
          buffer.write(' ');
        }
      }
      return detectInstrumentType(buffer.toString()) ?? InstrumentType.mcgs;
    } catch (_) {
      return InstrumentType.mcgs;
    }
  }

  /// 导入既有 Excel → 结构化行（桌面端入口，仪器类型由用户指定）。
  ///
  /// 读取第一个工作表，尝试定位表头行并映射到仪器已知列；
  /// 无法定位表头时将首行当作表头。
  Future<List<WaterQualityRow>> importExcel(
    String path,
    InstrumentType type,
  ) async {
    final File file = File(path);
    if (!await file.exists()) {
      throw Exception('文件不存在：$path');
    }

    final List<int> bytes = await file.readAsBytes();
    final Excel excel = Excel.decodeBytes(bytes);
    if (excel.tables.isEmpty) return <WaterQualityRow>[];

    final Sheet sheet = excel.tables.values.first;
    final List<List<Data?>> rowsData = sheet.rows;
    if (rowsData.isEmpty) return <WaterQualityRow>[];

    // 定位表头行：能匹配到至少 2 个已知列名。
    int headerIndex = -1;
    List<String> headerTexts = <String>[];
    for (int r = 0; r < rowsData.length; r++) {
      final List<String> texts = rowsData[r].map(_cellToText).toList();
      final int matched = type.headers
          .where((h) => texts.any((t) => _matchHeader(t, h)))
          .length;
      if (matched >= 2) {
        headerIndex = r;
        headerTexts = texts;
        break;
      }
    }

    if (headerIndex < 0) {
      headerIndex = 0;
      headerTexts = rowsData[0].map(_cellToText).toList();
    }

    // 建立列索引 → 已知列名映射。
    final Map<int, String> columnMap = <int, String>{};
    for (int c = 0; c < headerTexts.length; c++) {
      final String? known = _matchKnownHeader(headerTexts[c], type.headers);
      if (known != null) columnMap[c] = known;
    }

    final List<WaterQualityRow> result = <WaterQualityRow>[];
    for (int r = headerIndex + 1; r < rowsData.length; r++) {
      final List<String> texts = rowsData[r].map(_cellToText).toList();
      if (texts.every((t) => t.trim().isEmpty)) continue;

      final Map<String, String> cells = <String, String>{};
      for (final MapEntry<int, String> entry in columnMap.entries) {
        final String value = entry.key < texts.length
            ? texts[entry.key].trim()
            : '';
        cells[entry.value] = value;
      }
      // 全空行跳过。
      if (cells.values.every((v) => v.isEmpty)) continue;
      result.add(WaterQualityRow.fromCells(instrument: type, cells: cells));
    }
    return result;
  }

  /// 导出（去重后）行到 Excel，返回保存路径；[dir] 为空则弹保存对话框。
  ///
  /// 使用行所属仪器类型的列头顺序输出，单元格统一以文本写出，
  /// 「未检出」等原文得以保留。
  Future<String> exportExcel(List<WaterQualityRow> rows, {String? dir}) async {
    if (rows.isEmpty) {
      throw Exception('没有可导出的数据行');
    }

    final Excel excel = Excel.createExcel();
    final Sheet sheet = excel.tables.values.first;

    final InstrumentType instrument = rows.first.instrument;
    final List<String> headers = instrument.headers;

    sheet.appendRow(<CellValue?>[
      for (final String h in headers) TextCellValue(h),
    ]);

    for (final WaterQualityRow row in rows) {
      final List<String> rowHeaders = row.instrument.headers;
      sheet.appendRow(<CellValue?>[
        for (final String h in rowHeaders) TextCellValue(row.cells[h] ?? ''),
      ]);
    }

    final List<int>? encoded = excel.encode();
    if (encoded == null) {
      throw Exception('Excel 编码失败');
    }

    final String fileName = '水质数据_${_timestamp()}.xlsx';
    final Uint8List fileBytes = Uint8List.fromList(encoded);

    // 指定目录：直接落盘。
    if (dir != null && dir.isNotEmpty) {
      final Directory directory = Directory(dir);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final String path = p.join(dir, fileName);
      await File(path).writeAsBytes(fileBytes);
      return path;
    }

    // 未指定目录：弹系统保存对话框（file_picker 13.x 内部负责写字节）。
    try {
      final Uri? uri = await FilePicker.saveFile(
        fileName: fileName,
        bytes: fileBytes,
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        dialogTitle: '保存 Excel',
      );
      if (uri != null && uri.scheme == 'file') {
        return uri.toFilePath();
      }
    } catch (_) {
      // 保存对话框失败时回退到文档目录。
    }

    final Directory docDir = await getApplicationDocumentsDirectory();
    final String fallbackPath = p.join(docDir.path, fileName);
    await File(fallbackPath).writeAsBytes(fileBytes);
    return fallbackPath;
  }

  /// 单元格 → 原始字符串（各 CellValue 子类 toString 均返回原始值）。
  String _cellToText(Data? cell) {
    if (cell == null) return '';
    final CellValue? value = cell.value;
    return value?.toString() ?? '';
  }

  /// 将表头单元格文本匹配到已知列名；命中返回已知列名，否则 null。
  String? _matchKnownHeader(String text, List<String> headers) {
    final String t = text.trim();
    if (t.isEmpty) return null;
    for (final String h in headers) {
      if (_matchHeader(t, h)) return h;
    }
    return null;
  }

  bool _matchHeader(String text, String known) {
    final String t = text.trim();
    if (t.isEmpty) return false;
    return t == known || t.contains(known) || known.contains(t);
  }

  String _timestamp() {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}
