import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/gb_verify.dart';
import '../models/standard.dart';
import '../models/workspace.dart';
import 'gb_calculator.dart';
import 'standard_definitions.dart';

/// 国标验证（HJ 103—2026 总磷）Excel 报告导出。
///
/// 一次导出生成 **4 个工作表**：
/// 1. `数据集`：参与计算的样品原始行（时间 / 数据结果 / 吸光度 / 数据标识 …）；
/// 2. `计算过程`：逐验证项的逐步计算过程（公式 → 代入 → 结果 → 说明）与明细表；
/// 3. `结果汇总`：验证项 / 条款 / 量程 / 指标值 / 限值 / 判定 + 合计行；
/// 4. `标准依据`：标准条款原文摘要（试验方法、公式、限值）。
///
/// 设计约束：
/// - **纯静态方法、无 UI 依赖**，便于单元测试与命令行调用；
/// - 数值一律使用 [ItemReport.metricDisplay] / [ItemReport.limitDisplay]，
///   **不在导出层重算任何国标限值**；
/// - 列宽按内容估算（中文按 2 个字符宽），最小 10、最大 60。
class GbExcelExporter {
  GbExcelExporter._();

  /// 数据集工作表名。
  static const String sheetDataset = '数据集';

  /// 计算过程工作表名。
  static const String sheetProcess = '计算过程';

  /// 结果汇总工作表名。
  static const String sheetSummary = '结果汇总';

  /// 标准依据工作表名。
  static const String sheetStandard = '标准依据';

  /// 数据集工作表的固定前置列。
  static const List<String> _datasetLeadColumns = <String>['序号', '时间'];

  /// 「数据结果」列在工作表中的展示表头。
  static const String _resultColumnHeader = '数据结果(mg/L)';

  // ---------------------------------------------------------------- 对外入口

  /// 生成并保存 Excel 报告，返回落盘路径。
  ///
  /// - [dir] 非空时直接写入该目录（不存在会自动创建）；
  /// - [dir] 为空时弹系统「另存为」对话框，失败回退到应用文档目录。
  static Future<String> export({
    required Workspace workspace,
    required CalcSession session,
    String? dir,
  }) async {
    final Uint8List bytes = buildBytes(workspace: workspace, session: session);
    final String fileName = buildFileName(session);

    // 指定目录：直接落盘。
    if (dir != null && dir.isNotEmpty) {
      final Directory directory = Directory(dir);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final String path = p.join(dir, fileName);
      await File(path).writeAsBytes(bytes);
      return path;
    }

    // 未指定目录：弹系统保存对话框（file_picker 13.x 内部负责写字节）。
    try {
      final Uri? uri = await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        dialogTitle: '保存国标验证报告',
      );
      if (uri != null && uri.scheme == 'file') {
        return uri.toFilePath();
      }
    } catch (_) {
      // 保存对话框失败（沙箱/权限/平台不支持）时回退到文档目录。
    }

    final Directory docDir = await getApplicationDocumentsDirectory();
    final String fallbackPath = p.join(docDir.path, fileName);
    await File(fallbackPath).writeAsBytes(bytes);
    return fallbackPath;
  }

  /// 只生成字节（不落盘），供测试或第三方上传使用。
  static Uint8List buildBytes({
    required Workspace workspace,
    required CalcSession session,
  }) {
    final Excel excel = Excel.createExcel();
    final List<String> builtInSheets = excel.tables.keys.toList();

    _buildDatasetSheet(excel, workspace, session);
    _buildProcessSheet(excel, workspace, session);
    _buildSummarySheet(excel, workspace, session);
    _buildStandardSheet(excel, session);

    // 删除模板自带的空工作表，避免出现「Sheet1」。
    const Set<String> kept = <String>{
      sheetDataset,
      sheetProcess,
      sheetSummary,
      sheetStandard,
    };
    for (final String name in builtInSheets) {
      if (!kept.contains(name)) {
        excel.delete(name);
      }
    }

    final List<int>? encoded = excel.encode();
    if (encoded == null) {
      throw Exception('Excel 编码失败');
    }
    return Uint8List.fromList(encoded);
  }

  /// 报告文件名：`国标验证_总磷_{数据集名}_{yyyyMMdd_HHmmss}.xlsx`。
  static String buildFileName(CalcSession session, {DateTime? now}) {
    final String raw = sanitizeFileName(session.datasetName);
    final String dataset = raw.isEmpty ? '数据集' : raw;
    return '国标验证_总磷_${dataset}_${_timestamp(now ?? DateTime.now())}.xlsx';
  }

  // ---------------------------------------------------------------- 工作表 1：数据集

  static void _buildDatasetSheet(
    Excel excel,
    Workspace workspace,
    CalcSession session,
  ) {
    final List<String> columns = _datasetColumns(session.samples);
    final _SheetBuilder builder = _SheetBuilder(
      excel[sheetDataset],
      columns.length,
    );
    final Sheet sheet = builder.sheet;

    builder.addMergedRow(
      '数据集：${session.datasetName}　工作空间：${workspace.displayName.isEmpty ? workspace.name : workspace.displayName}',
      style: _titleStyle(),
    );
    builder.addMergedRow(
      '量程：${GbCalculator.rangeLabel(session.rangeKey)}　'
      '数据行数：${session.samples.length}　'
      '计算时间：${_dateTimeText(session.createdAt)}',
      style: _subtleStyle(),
    );

    // 表头。
    builder.addRow(<String>[
      for (final String c in columns) c == '数据结果' ? _resultColumnHeader : c,
    ], header: true);

    // 数据行。
    for (final GbSample sample in session.samples) {
      builder.addRow(<String>[
        for (final String c in columns) _datasetCell(sample, c),
      ]);
    }

    builder.applyColumnWidths();

    // 时间列宽一点更易读；首列序号窄一点。
    sheet.setColumnWidth(0, 8);
    if (columns.length > 1) {
      sheet.setColumnWidth(1, 22);
    }
  }

  /// 数据集列顺序：序号 → 时间 → 各样品 `cells` 实际出现的键（缺「数据结果」则插到最前）。
  static List<String> _datasetColumns(List<GbSample> samples) {
    final List<String> dynamic = <String>[];
    for (final GbSample sample in samples) {
      for (final String key in sample.cells.keys) {
        final String k = key.trim();
        if (k.isEmpty) continue;
        if (_datasetLeadColumns.contains(k)) continue;
        if (!dynamic.contains(k)) dynamic.add(k);
      }
    }
    if (!dynamic.contains('数据结果')) {
      dynamic.insert(0, '数据结果');
    }
    return <String>[..._datasetLeadColumns, ...dynamic];
  }

  /// 单个数据集的单元格文本。
  static String _datasetCell(GbSample sample, String column) {
    switch (column) {
      case '序号':
        return sample.index > 0 ? '${sample.index}' : '';
      case '时间':
        return sample.timeText;
      case '数据结果':
        return _fixed(sample.value, 4);
      default:
        return sample.cells[column] ?? '';
    }
  }

  // ---------------------------------------------------------------- 工作表 2：计算过程

  static void _buildProcessSheet(
    Excel excel,
    Workspace workspace,
    CalcSession session,
  ) {
    final _SheetBuilder builder = _SheetBuilder(excel[sheetProcess], 6);

    builder.addMergedRow(
      '计算过程：${session.datasetName}　'
      '工作空间：${workspace.displayName.isEmpty ? workspace.name : workspace.displayName}　'
      '量程：${GbCalculator.rangeLabel(session.rangeKey)}　'
      '计算时间：${_dateTimeText(session.createdAt)}',
      style: _titleStyle(),
    );
    builder.blank();

    if (session.reports.isEmpty) {
      builder.addMergedRow('本次计算没有任何验证项结果。', style: _subtleStyle());
      builder.applyColumnWidths();
      return;
    }

    for (int i = 0; i < session.reports.length; i++) {
      final ItemReport report = session.reports[i];
      final StringBuffer head = StringBuffer(
        '${i + 1}. ${report.itemName}（${report.clause}）　'
        '结论：${conclusionLabel(report.conclusion)}',
      );
      if (report.subLabel.isNotEmpty) {
        head.write('　[${report.subLabel}]');
      }
      builder.addMergedRow(head.toString(), style: _sectionStyle());

      if (report.dataNote.isNotEmpty) {
        builder.addMergedRow(
          '数据量校验：${report.dataNote}',
          style: _warningStyle(),
        );
      }

      if (report.steps.isEmpty) {
        builder.addMergedRow('该验证项没有可展示的计算步骤。', style: _subtleStyle());
      } else {
        builder.addRow(const <String>[
          '步骤',
          '标题',
          '公式',
          '代入过程',
          '结果',
          '说明',
        ], header: true);
        for (final CalcStep step in report.steps) {
          builder.addRow(<String>[
            '${step.no}',
            step.title,
            step.formula,
            step.substitution,
            step.resultText,
            step.note,
          ]);
        }
      }

      if (report.detailRows.isNotEmpty) {
        builder.blank();
        builder.addMergedRow('明细数据', style: _subtleBoldStyle());
        for (int r = 0; r < report.detailRows.length; r++) {
          final List<String> row = report.detailRows[r];
          builder.addRow(row, header: r == 0);
        }
      }
      builder.blank();
    }

    builder.applyColumnWidths();
  }

  // ---------------------------------------------------------------- 工作表 3：结果汇总

  static void _buildSummarySheet(
    Excel excel,
    Workspace workspace,
    CalcSession session,
  ) {
    final _SheetBuilder builder = _SheetBuilder(excel[sheetSummary], 9);

    builder.addMergedRow(
      '结果汇总：${session.datasetName}　'
      '工作空间：${workspace.displayName.isEmpty ? workspace.name : workspace.displayName}　'
      '量程：${GbCalculator.rangeLabel(session.rangeKey)}　'
      '计算时间：${_dateTimeText(session.createdAt)}',
      style: _titleStyle(),
    );
    builder.blank();

    builder.addRow(const <String>[
      '验证项',
      '标准条款',
      '量程',
      '指标值（展示）',
      '判定用原始值（未舍入）',
      '限值',
      '判定',
      '不合格档位',
      '备注',
    ], header: true);

    for (final ItemReport report in session.reports) {
      builder.addRow(<String>[
        report.itemName,
        report.clause,
        GbCalculator.rangeLabel(report.rangeKey),
        _metricCell(report),
        _rawMetric(report),
        report.limitDisplay.isEmpty ? '—' : report.limitDisplay,
        conclusionLabel(report.conclusion),
        _failedTiersCell(report),
        _summaryRemark(report),
      ]);
    }

    builder.blank();
    builder.addMergedRow(
      '合计：共 ${session.reports.length} 项　'
      '合格 ${session.passCount} 项 / '
      '不合格 ${session.failCount} 项 / '
      '无法判定 ${session.naCount} 项　'
      '总体结论：${conclusionLabel(session.overall)}',
      style: _totalStyle(),
    );
    builder.blank();
    builder.addMergedRow('结论说明：${session.overallHint}', style: _subtleStyle());

    if (session.note.isNotEmpty) {
      builder.addMergedRow('备注：${session.note}', style: _subtleStyle());
    }

    builder.applyColumnWidths();
  }

  /// 展示用指标值：与界面完全一致，不追加任何前缀。
  static String _metricCell(ItemReport report) =>
      report.metricDisplay.isEmpty ? '—' : report.metricDisplay;

  /// 不合格档位（多档位项目用来说明具体是哪一档超标），无则「—」。
  ///
  /// 一致性偏差（conformity）是 3 台仪器**联合判定**：引擎把联合结论同时写入
  /// 3 条 tier 的 `passed`，直接拼接会得到「第 1 台仪器、第 2 台仪器、第 3 台仪器」
  /// 的误导文案，故不合格时统一写「三台联合判定」。
  static String _failedTiersCell(ItemReport report) {
    if (report.itemId == 'conformity') {
      return report.conclusion == GbConclusion.fail ? '三台联合判定' : '—';
    }
    return report.failedTierLabels.isEmpty
        ? '—'
        : report.failedTierLabels.join('、');
  }

  /// 判定用的**未舍入**指标值。
  ///
  /// 规范要求判定使用原始值、展示才舍入，导出必须同时给出两者，
  /// 否则会出现「Excel 显示 5.00% 却判不合格」的无法复核情形。
  static String _rawMetric(ItemReport report) {
    final double? v = report.metricValue;
    if (v == null || !v.isFinite) return '—';
    // toString() 给出最短可精确回读的表示，不引入额外舍入。
    return v.toString();
  }

  /// 汇总行的「备注」列：优先数据量校验问题，其次子项标签。
  static String _summaryRemark(ItemReport report) {
    if (report.dataNote.isNotEmpty) return report.dataNote;
    if (report.subLabel.isNotEmpty) return report.subLabel;
    return '—';
  }

  // ---------------------------------------------------------------- 工作表 4：标准依据

  static void _buildStandardSheet(Excel excel, CalcSession session) {
    final _SheetBuilder builder = _SheetBuilder(excel[sheetStandard], 5);
    // 按会话记录的检测项目取标准；旧数据没有该字段时回落到总磷。
    final Standard std =
        standardById(session.parameterId) ?? totalPhosphorusStandard;

    builder.addMergedRow(
      '标准依据：${std.code}'
      '《水质${std.name}自动监测仪技术要求及检测方法》',
      style: _titleStyle(),
    );
    builder.addMergedRow(
      '检测项目：${std.name}　'
      '本次计算量程：${GbCalculator.rangeLabel(session.rangeKey)}　'
      '标准说明：${std.note}',
      style: _subtleStyle(),
    );
    builder.blank();

    builder.addRow(const <String>[
      '验证项目',
      '条款号',
      '试验方法',
      '公式',
      '限值',
    ], header: true);

    for (final VerificationItem item in std.items) {
      builder.addRow(<String>[
        item.name,
        item.clause,
        item.methodNote,
        item.formulaDesc,
        _limitText(item),
      ]);
    }

    builder.applyColumnWidths();
  }

  /// 一个验证项在所有量程下的限值文案。
  static String _limitText(VerificationItem item) {
    final List<String> parts = <String>[];
    for (final String rangeKey in <String>['basic', 'extended']) {
      final StandardItemLimit? limit = item.limitFor(rangeKey);
      if (limit == null) continue;
      parts.add(
        '${totalPhosphorusStandard.rangeLabel(rangeKey)}：${_limitOf(limit)}',
      );
    }
    return parts.isEmpty ? '—' : parts.join('；');
  }

  /// 单个判定限的文案，如 `≤0.02`、`±5%`、`≥168`。
  static String _limitOf(StandardItemLimit limit) {
    final List<String> segments = <String>[];
    final double? absolute = limit.absolute;
    final double? percent = limit.percent;
    if (absolute != null) {
      segments.add('${limit.higherIsFail ? '≤' : '≥'}${_num(absolute)}');
    }
    if (percent != null) {
      segments.add(
        limit.higherIsFail ? '±${_num(percent)}%' : '≥${_num(percent)}%',
      );
    }
    return segments.isEmpty ? '—' : segments.join(' / ');
  }

  // ---------------------------------------------------------------- 样式

  static CellStyle _titleStyle() => CellStyle(
    bold: true,
    fontSize: 13,
    fontColorHex: ExcelColor.fromHexString('FF0D47A1'),
    verticalAlign: VerticalAlign.Center,
  );

  static CellStyle _sectionStyle() => CellStyle(
    bold: true,
    fontSize: 12,
    fontColorHex: ExcelColor.fromHexString('FF0D47A1'),
    backgroundColorHex: ExcelColor.fromHexString('FFE3F2FD'),
  );

  static CellStyle _headerStyle() => CellStyle(
    bold: true,
    fontSize: 11,
    fontColorHex: ExcelColor.white,
    backgroundColorHex: ExcelColor.fromHexString('FF1976D2'),
    horizontalAlign: HorizontalAlign.Center,
    verticalAlign: VerticalAlign.Center,
  );

  static CellStyle _subtleStyle() => CellStyle(
    fontSize: 10,
    fontColorHex: ExcelColor.fromHexString('FF757575'),
  );

  static CellStyle _subtleBoldStyle() => CellStyle(
    bold: true,
    fontSize: 10,
    fontColorHex: ExcelColor.fromHexString('FF424242'),
  );

  static CellStyle _warningStyle() => CellStyle(
    fontSize: 10,
    fontColorHex: ExcelColor.fromHexString('FFE65100'),
  );

  static CellStyle _totalStyle() => CellStyle(
    bold: true,
    fontSize: 11,
    backgroundColorHex: ExcelColor.fromHexString('FFF1F8E9'),
  );

  // ---------------------------------------------------------------- 工具

  /// 固定小数位；非有限值输出 `—`。
  static String _fixed(double v, int digits) =>
      v.isFinite ? v.toStringAsFixed(digits) : '—';

  /// 数值文本：整数不带小数点，其余用最短表示。
  static String _num(double v) {
    if (!v.isFinite) return '—';
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }

  static String _timestamp(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}${two(dt.month)}${two(dt.day)}'
        '_${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
  }

  static String _dateTimeText(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  /// 文本显示宽度：中日韩等宽字符按 2 计，其余按 1 计。
  static double _displayWidth(String text) {
    double width = 0;
    for (final int rune in text.runes) {
      width += rune > 0x2E7F ? 2 : 1;
    }
    return width;
  }
}

/// 工作表写入助手：统一处理追加行、合并标题行、表头加粗与列宽估算。
class _SheetBuilder {
  _SheetBuilder(this.sheet, this.columnCount);

  /// 目标工作表（由 `excel[名称]` 获取，写入即生效）。
  final Sheet sheet;

  /// 该工作表的逻辑列数（用于合并标题行与列宽估算）。
  final int columnCount;

  /// 参与列宽估算的行（不含合并的标题行）。
  final List<List<String>> _measureRows = <List<String>>[];

  /// 追加一个空白分隔行。
  void blank() {
    sheet.appendRow(<CellValue?>[TextCellValue('')]);
  }

  /// 追加一个普通数据行（不足的列补空字符串），返回行号。
  int addRow(List<String> cells, {bool header = false}) {
    final int rowIndex = sheet.maxRows;
    sheet.appendRow(<CellValue?>[
      for (int c = 0; c < columnCount; c++)
        TextCellValue(c < cells.length ? cells[c] : ''),
    ]);
    if (header) {
      final CellStyle style = GbExcelExporter._headerStyle();
      for (int c = 0; c < columnCount; c++) {
        sheet
                .cell(
                  CellIndex.indexByColumnRow(
                    columnIndex: c,
                    rowIndex: rowIndex,
                  ),
                )
                .cellStyle =
            style;
      }
    }
    _measureRows.add(<String>[
      for (int c = 0; c < columnCount; c++) c < cells.length ? cells[c] : '',
    ]);
    return rowIndex;
  }

  /// 追加一个横向合并到整行宽度的说明行，返回行号。
  int addMergedRow(String text, {CellStyle? style}) {
    final int rowIndex = sheet.maxRows;
    sheet.appendRow(<CellValue?>[TextCellValue(text)]);
    if (columnCount > 1) {
      sheet.merge(
        CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: rowIndex),
        CellIndex.indexByColumnRow(
          columnIndex: columnCount - 1,
          rowIndex: rowIndex,
        ),
        customValue: TextCellValue(text),
      );
    }
    if (style != null) {
      sheet
              .cell(
                CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: rowIndex),
              )
              .cellStyle =
          style;
    }
    return rowIndex;
  }

  /// 按内容估算列宽（中文按 2 字符宽，最小 10、最大 60）。
  void applyColumnWidths() {
    for (int c = 0; c < columnCount; c++) {
      double widest = 0;
      for (final List<String> row in _measureRows) {
        if (c >= row.length) continue;
        final double width = GbExcelExporter._displayWidth(row[c]);
        if (width > widest) widest = width;
      }
      final double target = widest < 10 ? 10 : (widest > 60 ? 60 : widest + 2);
      sheet.setColumnWidth(c, target);
    }
  }
}
