import 'package:uuid/uuid.dart';

import '../models/workspace.dart';
import '../utils/number_utils.dart';

/// 验证模块 OCR/粘贴文本解析：将文本行解析为可编辑的 [Measurement] 列表。
///
/// 策略：逐行提取数字（首个数值作为主测量值 value），尽力提取时间戳与标签，
/// 保留原始行 [Measurement.rawText]。无数字的行跳过，由调用方回退为手动输入。
List<Measurement> parseVerificationMeasurements(String text) {
  final List<Measurement> out = <Measurement>[];
  final List<String> lines = text
      .split(RegExp(r'\r?\n'))
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty)
      .toList();

  for (final String raw in lines) {
    final List<double> nums = _extractNumbers(raw);
    if (nums.isEmpty) continue; // 无数字行：跳过，回退手动输入。
    final DateTime? ts = _extractTimestamp(raw);
    final String? label = _extractLabel(raw, nums);
    out.add(
      Measurement(
        id: const Uuid().v4(),
        label: label,
        timestamp: ts,
        values: <String, double>{'value': nums.first},
        rawText: raw,
      ),
    );
  }
  return out;
}

/// 从一行文本提取全部数值（已归一全角/千分位）。
List<double> _extractNumbers(String line) {
  final String s = NumberUtils.normalizeFullWidth(line);
  final List<String> tokens = s
      .split(RegExp(r'[\s,，、;；]+'))
      .where((String t) => t.isNotEmpty)
      .toList();
  final List<double> nums = <double>[];
  for (final String t in tokens) {
    final double? d = NumberUtils.parseNumber(t);
    if (d != null) nums.add(d);
  }
  return nums;
}

/// 尽力提取时间戳：支持「日期 时间」「仅日期」「仅时间」三种形态。
DateTime? _extractTimestamp(String line) {
  final RegExp dateTime = RegExp(
    r'(\d{4}[-/]\d{1,2}[-/]\d{1,2})[ T](\d{1,2}:\d{2}(?::\d{2})?)',
  );
  final RegExp dateOnly = RegExp(r'(\d{4}[-/]\d{1,2}[-/]\d{1,2})');
  final RegExp timeOnly = RegExp(r'(\d{1,2}:\d{2}(?::\d{2})?)');

  final Match? m1 = dateTime.firstMatch(line);
  if (m1 != null) {
    return DateTime.tryParse('${m1.group(1)} ${m1.group(2)}');
  }
  final Match? m2 = dateOnly.firstMatch(line);
  if (m2 != null) {
    return DateTime.tryParse(m2.group(1)!.replaceAll('/', '-'));
  }
  final Match? m3 = timeOnly.firstMatch(line);
  if (m3 != null) {
    final List<String> parts = m3.group(1)!.split(':');
    final int h = int.tryParse(parts[0]) ?? 0;
    final int min = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    final int sec = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0;
    final DateTime now = DateTime.now();
    return DateTime(now.year, now.month, now.day, h, min, sec);
  }
  return null;
}

/// 从一行提取非数值文本作为标签（去除数字与标点）。
String? _extractLabel(String raw, List<double> nums) {
  final String s = NumberUtils.normalizeFullWidth(raw);
  final String label = s
      .replaceAll(RegExp(r'[\d.,，、;；:\-\s]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return label.isEmpty ? null : label;
}
