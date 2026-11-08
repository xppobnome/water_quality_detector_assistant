import 'instrument_type.dart';
import 'water_quality_row.dart';

/// OCR 解析结果 + 告警。
class OcrParseResult {
  OcrParseResult({
    required this.instrument,
    required this.rows,
    this.warnings = const [],
    this.rawText,
  });

  final InstrumentType instrument;
  final List<WaterQualityRow> rows;

  /// 跳过/异常提示（面向用户）。
  final List<String> warnings;

  /// 原始 OCR 文本（可选，供「查看 OCR 原文」人工核对；向后兼容旧构造）。
  final String? rawText;
}
