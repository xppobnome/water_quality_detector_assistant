import 'number_utils.dart';

/// OCR 数字 token 纠错：把常见「形似数字」字符纠正为数字。
///
/// 只在纠正结果构成合法数值时才替换，避免误伤单位、标识、通道等文本。
/// 保护规则：
/// - 含中文字符（表头 /「未检出」/「总大肠菌群A」）→ 原样返回；
/// - 含 `:`（时间 18:00:00）→ 原样返回；
/// - 含 2 个及以上 `-` / `/`（日期 2026-11-03）→ 原样返回；
/// - 单个字母（通道 A/B/C、数据标识 N 等）→ 原样返回。
String fixOcrDigits(String token) {
  if (token.isEmpty) return token;
  final String normalized = NumberUtils.normalizeFullWidth(token);

  final RegExp numeric = RegExp(r'^-?\d+(\.\d+)?$');
  final RegExp han = RegExp(r'[\u4e00-\u9fff]');
  if (han.hasMatch(normalized)) return token;
  if (normalized.contains(':')) return token;
  if (RegExp(r'[-/]').allMatches(normalized).length >= 2) return token;
  if (RegExp(r'^[A-Za-z]$').hasMatch(normalized)) return token;

  // 本身已是合法数值（含负数与小数）：直接返回半角形式。
  if (numeric.hasMatch(normalized)) return normalized;

  const Map<String, String> similar = <String, String>{
    'O': '0',
    'o': '0',
    'Q': '0',
    'D': '0',
    'l': '1',
    'I': '1',
    '|': '1',
    'i': '1',
    'Z': '2',
    'z': '2',
    'S': '5',
    's': '5',
    'B': '8',
    'g': '9',
    'q': '9',
    'A': '4',
  };
  // 仅当 token 含数字或形似数字字符时才尝试纠错。
  if (!RegExp(r'[0-9OoQDlI|iZzSsBgqA]').hasMatch(normalized)) return token;

  // 去掉数字之间的逗号 / 空格（如 1,370.550 → 1370.550）。
  String cleaned = normalized;
  while (true) {
    final String next = cleaned.replaceAllMapped(
      RegExp(r'(\d)[,\s]+(\d)'),
      (Match m) => '${m[1]}${m[2]}',
    );
    if (next == cleaned) break;
    cleaned = next;
  }

  final String corrected = cleaned
      .split('')
      .map((String ch) => similar[ch] ?? ch)
      .join();
  // 纠正后必须是合法数值才生效，否则原样返回，绝不误改结构 token。
  return numeric.hasMatch(corrected) ? corrected : token;
}
