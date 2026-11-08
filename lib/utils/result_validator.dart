import '../models/water_quality_row.dart';
import 'number_utils.dart';

/// 空白/检测列校验与跳过提示。
///
/// 吸光度计算只使用「空白」「检测」两列；空 / 非数值按异常值处理（跳过并提示）。
class ResultValidator {
  ResultValidator._();

  /// 校验空白列，返回告警文案；合法返回 null。
  static String? blankIssue(WaterQualityRow row) {
    return _valueIssue(row.blankRaw, '空白');
  }

  /// 校验检测列，返回告警文案；合法返回 null。
  static String? detectionIssue(WaterQualityRow row) {
    return _valueIssue(row.detectionRaw, '检测');
  }

  /// 该行是否可参与吸光度/拟合计算（空白与检测均为合法正数）。
  static bool isValidForFit(WaterQualityRow row) {
    if (!row.instrument.supportsFit) return false;
    final double? blank = row.blank;
    final double? detection = row.detection;
    return blank != null && detection != null && blank > 0 && detection > 0;
  }

  static String? _valueIssue(String? raw, String label) {
    if (raw == null || raw.trim().isEmpty) {
      return '$label列为空，已跳过该行';
    }
    if (NumberUtils.isNotDetected(raw)) {
      return '$label列为「未检出」文本，不参与数值拟合，已跳过该行';
    }
    final double? value = NumberUtils.parseNumber(raw);
    if (value == null) {
      return '$label列「$raw」不是有效数值，已跳过该行';
    }
    if (value <= 0) {
      return '$label列「$raw」需大于 0，已跳过该行';
    }
    return null;
  }
}
