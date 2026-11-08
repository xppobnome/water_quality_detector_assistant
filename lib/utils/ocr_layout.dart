import 'dart:math' as math;

/// 一行 OCR 文本及其几何位置（像素坐标，来自 ML Kit boundingBox 或
/// PaddleOCR 文本框）。[top] / [height] 用于判断哪些文本属于同一视觉行，
/// [left] 用于行内按从左到右排序。
class OcrLine {
  const OcrLine({
    required this.left,
    required this.top,
    required this.height,
    required this.text,
  });

  final double left;
  final double top;
  final double height;
  final String text;

  double get centerY => top + height / 2;
}

/// 把 OCR 引擎返回的散落文本行重排为「表格友好」的纯文本。
///
/// OCR 引擎（ML Kit / PaddleOCR）默认按「块」输出，表格截图常被拆成
/// 按列组织的块，直接拼接会导致一行数据的各单元格分散到不同行，
/// 使 [parseOcrText] 无法定位日期 / 时间锚点。
///
/// 本函数按几何位置把文本行聚类为视觉行，行内按 x 从左到右排列，
/// 单元格以空格分隔、每行一条，正好匹配 `ocr_parser.dart` 的
/// 「逐行 + token 定位」解析方式。
///
/// [rowToleranceFactor] 为「允许归入同一视觉行的纵向偏移 / 行高」比例，
/// 默认 0.6（能容忍同一行内中文与数字基线差异，又不会把相邻两行合并）。
String layoutOcrLines(List<OcrLine> lines, {double rowToleranceFactor = 0.6}) {
  if (lines.isEmpty) return '';

  final List<OcrLine> sorted = List<OcrLine>.from(lines)
    ..sort((OcrLine a, OcrLine b) {
      final int byTop = a.top.compareTo(b.top);
      return byTop != 0 ? byTop : a.left.compareTo(b.left);
    });

  final List<List<OcrLine>> rows = <List<OcrLine>>[];
  for (final OcrLine line in sorted) {
    if (rows.isEmpty) {
      rows.add(<OcrLine>[line]);
      continue;
    }
    final List<OcrLine> current = rows.last;
    double anchorY = 0;
    double maxHeight = 0;
    for (final OcrLine e in current) {
      anchorY += e.centerY;
      if (e.height > maxHeight) maxHeight = e.height;
    }
    anchorY /= current.length;
    final double tolerance = math.max(
      6.0,
      math.max(maxHeight, line.height) * rowToleranceFactor,
    );
    if ((line.centerY - anchorY).abs() <= tolerance) {
      current.add(line);
    } else {
      rows.add(<OcrLine>[line]);
    }
  }

  final StringBuffer buffer = StringBuffer();
  for (final List<OcrLine> row in rows) {
    row.sort((OcrLine a, OcrLine b) => a.left.compareTo(b.left));
    final String joined = row
        .map((OcrLine e) => e.text.trim())
        .where((String s) => s.isNotEmpty)
        .join(' ');
    if (joined.isEmpty) continue;
    if (buffer.isNotEmpty) buffer.writeln();
    buffer.write(joined);
  }
  return buffer.toString();
}
