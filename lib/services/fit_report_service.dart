import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:excel/excel.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/fit_result.dart';
import '../models/report_file.dart';
import '../models/workspace.dart' show sanitizeFileName;
import '../utils/workspace_utils.dart';

/// 大肠杆菌拟合成果三件套：JSON（可复现数据）+ PNG（拟合图）+ Excel（结果表）。
///
/// PNG 使用 dart:ui 的 Canvas 直接绘制，不依赖 widget 是否已渲染，
/// 因此在 Android / Windows 上都能稳定产出同一张拟合图。
class FitReportService {
  /// 生成 3 个文件到临时目录，返回待归档描述（文件名可由用户再自定义）。
  Future<List<ReportFile>> build({
    required FitResult fit,
    required double concentration,
    required String unit,
    String? baseName,
  }) async {
    final Directory dir = await getTemporaryDirectory();
    final String raw = (baseName ?? '').trim().isEmpty
        ? '大肠杆菌拟合_${timestampStamp(DateTime.now())}'
        : baseName!.trim();
    final String base = sanitizeFileName(p.basenameWithoutExtension(raw));
    final String safe = base.isEmpty
        ? 'ecoli_fit_${DateTime.now().millisecondsSinceEpoch}'
        : base;

    final List<ReportFile> out = <ReportFile>[];

    // 1) JSON：完整拟合数据 + 实验参数，可复现。
    final Map<String, dynamic> payload = <String, dynamic>{
      ...fit.toJson(),
      'A': fit.intercept,
      'B': fit.slope,
      'formula': 'y = B*X + A',
      'concentration': concentration,
      'unit': unit,
      'createdAt': DateTime.now().toIso8601String(),
    };
    final File jsonFile = File(p.join(dir.path, '${safe}_$stamp.json'));
    await jsonFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    out.add(ReportFile(path: jsonFile.path, name: '$safe.json', kind: 'json'));

    // 2) Excel：拟合参数区 + 数据点区。
    final Excel excel = Excel.createExcel();
    final Sheet sheet = excel.tables.values.first;
    sheet.appendRow(<CellValue?>[TextCellValue('大肠杆菌吸光度拟合报告')]);
    sheet.appendRow(<CellValue?>[
      TextCellValue('生成时间'),
      TextCellValue(formatDateTime(DateTime.now())),
    ]);
    sheet.appendRow(<CellValue?>[TextCellValue('项目'), TextCellValue('数值')]);
    sheet.appendRow(<CellValue?>[
      TextCellValue('A（截距）'),
      TextCellValue(fit.intercept.toStringAsFixed(6)),
    ]);
    sheet.appendRow(<CellValue?>[
      TextCellValue('B（斜率）'),
      TextCellValue(fit.slope.toStringAsFixed(8)),
    ]);
    sheet.appendRow(<CellValue?>[
      TextCellValue('R²'),
      TextCellValue(fit.rSquared.toStringAsFixed(6)),
    ]);
    sheet.appendRow(<CellValue?>[
      TextCellValue('标液浓度'),
      TextCellValue(concentration.toStringAsFixed(2)),
    ]);
    sheet.appendRow(<CellValue?>[TextCellValue('单位'), TextCellValue(unit)]);
    sheet.appendRow(<CellValue?>[
      TextCellValue('拟合公式'),
      TextCellValue('y = B*X + A'),
    ]);
    sheet.appendRow(<CellValue?>[]);
    sheet.appendRow(<CellValue?>[
      TextCellValue('X（浓度）'),
      TextCellValue('Y（吸光度）'),
    ]);
    for (final FitPoint pt in fit.points) {
      sheet.appendRow(<CellValue?>[
        TextCellValue(pt.x.toStringAsFixed(4)),
        TextCellValue(pt.y.toStringAsFixed(6)),
      ]);
    }
    final List<int>? bytes = excel.encode();
    if (bytes == null) throw Exception('Excel 编码失败');
    final File xlsx = File(p.join(dir.path, '${safe}_$stamp.xlsx'));
    await xlsx.writeAsBytes(bytes);
    out.add(ReportFile(path: xlsx.path, name: '$safe.xlsx', kind: 'excel'));

    // 3) PNG：拟合曲线图。
    final Uint8List png = await _chartPng(fit);
    final File pngFile = File(p.join(dir.path, '${safe}_$stamp.png'));
    await pngFile.writeAsBytes(png);
    out.add(ReportFile(path: pngFile.path, name: '$safe.png', kind: 'image'));

    return out;
  }

  String get stamp => timestampStamp(DateTime.now());

  /// 用 dart:ui Canvas 绘制拟合图（散点 + 拟合直线 + 网格 + ASCII 标签）。
  Future<Uint8List> _chartPng(FitResult fit) async {
    const int width = 760;
    const int height = 440;
    const double left = 72;
    const double top = 56;
    const double right = width - 32.0;
    const double bottom = height - 58.0;

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);

    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 760.0, 440.0),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    final List<FitPoint> points = fit.points;
    double minX = points.isEmpty
        ? 0
        : points.map((FitPoint p) => p.x).reduce(math.min);
    double maxX = points.isEmpty
        ? 1
        : points.map((FitPoint p) => p.x).reduce(math.max);
    double minY = points.isEmpty
        ? 0
        : points.map((FitPoint p) => p.y).reduce(math.min);
    double maxY = points.isEmpty
        ? 1
        : points.map((FitPoint p) => p.y).reduce(math.max);
    minY = math.min(minY, fit.slope * minX + fit.intercept);
    maxY = math.max(maxY, fit.slope * maxX + fit.intercept);
    if ((maxX - minX).abs() < 1e-9) maxX = minX + 1;
    if ((maxY - minY).abs() < 1e-9) maxY = minY + 1;
    final double xPad = (maxX - minX) * 0.15;
    final double yPad = (maxY - minY) * 0.15;
    final double loX = minX - xPad;
    final double hiX = maxX + xPad;
    final double loY = minY - yPad;
    final double hiY = maxY + yPad;

    double px(double x) => left + (x - loX) / (hiX - loX) * (right - left);
    double py(double y) => bottom - (y - loY) / (hiY - loY) * (bottom - top);

    // 网格
    final ui.Paint grid = ui.Paint()
      ..color = const ui.Color(0xFFE3F2FD)
      ..strokeWidth = 1;
    for (int i = 0; i <= 5; i++) {
      final double x = left + (right - left) * i / 5;
      canvas.drawLine(ui.Offset(x, top), ui.Offset(x, bottom), grid);
      final double y = top + (bottom - top) * i / 5;
      canvas.drawLine(ui.Offset(left, y), ui.Offset(right, y), grid);
    }

    // 坐标轴
    final ui.Paint axis = ui.Paint()
      ..color = const ui.Color(0xFF90A4AE)
      ..strokeWidth = 1.5;
    canvas.drawLine(ui.Offset(left, top), ui.Offset(left, bottom), axis);
    canvas.drawLine(ui.Offset(left, bottom), ui.Offset(right, bottom), axis);

    // 拟合直线
    final ui.Paint line = ui.Paint()
      ..color = const ui.Color(0xFF1976D2)
      ..strokeWidth = 2.5
      ..style = ui.PaintingStyle.stroke;
    canvas.drawLine(
      ui.Offset(px(loX), py(fit.slope * loX + fit.intercept)),
      ui.Offset(px(hiX), py(fit.slope * hiX + fit.intercept)),
      line,
    );

    // 散点
    final ui.Paint dotFill = ui.Paint()
      ..color = const ui.Color(0xFF1976D2)
      ..style = ui.PaintingStyle.fill;
    final ui.Paint dotStroke = ui.Paint()
      ..color = const ui.Color(0xFFFFFFFF)
      ..strokeWidth = 1.5
      ..style = ui.PaintingStyle.stroke;
    for (final FitPoint pt in points) {
      final ui.Offset center = ui.Offset(px(pt.x), py(pt.y));
      canvas.drawCircle(center, 6, dotFill);
      canvas.drawCircle(center, 6, dotStroke);
    }

    // 文本标签（仅 ASCII，避免内置字体缺少中文字形）。
    _text(
      canvas,
      'E.coli Absorbance Fit  (y = B*X + A)',
      left,
      18,
      size: 16,
      color: const ui.Color(0xFF1976D2),
    );
    _text(
      canvas,
      'A = ${fit.intercept.toStringAsFixed(4)}',
      left,
      40,
      size: 11,
    );
    _text(
      canvas,
      'B = ${fit.slope.toStringAsFixed(6)}',
      left + 180,
      40,
      size: 11,
    );
    _text(
      canvas,
      'R2 = ${fit.rSquared.toStringAsFixed(4)}',
      left + 400,
      40,
      size: 11,
    );
    _text(
      canvas,
      'Concentration',
      (left + right) / 2 - 50,
      bottom + 20,
      size: 11,
    );
    _text(canvas, 'Absorbance', 6, top - 22, size: 11);
    _text(canvas, hiX.toStringAsFixed(0), right - 28, bottom + 6, size: 10);
    _text(canvas, hiY.toStringAsFixed(2), 18, top - 4, size: 10);

    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(width, height);
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (data == null) throw Exception('拟合图 PNG 编码失败');
    return data.buffer.asUint8List();
  }

  void _text(
    ui.Canvas canvas,
    String value,
    double x,
    double y, {
    double size = 12,
    ui.Color color = const ui.Color(0xFF546E7A),
  }) {
    final ui.ParagraphBuilder builder = ui.ParagraphBuilder(ui.ParagraphStyle())
      ..pushStyle(ui.TextStyle(color: color, fontSize: size))
      ..addText(value);
    final ui.Paragraph paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: 600));
    canvas.drawParagraph(paragraph, ui.Offset(x, y));
  }
}
