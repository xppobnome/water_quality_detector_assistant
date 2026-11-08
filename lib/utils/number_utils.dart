/// 数值解析工具：处理「未检出」/空/小数/千分位/全角字符。
class NumberUtils {
  NumberUtils._();

  /// 将原始文本解析为 double；空串、非数值或「未检出」返回 null。
  ///
  /// 「未检出」按异常值处理（不参与数值拟合），调用方据此跳过并提示。
  static double? parseNumber(String? raw) {
    if (raw == null) return null;
    String s = normalizeFullWidth(raw.trim());
    if (s.isEmpty) return null;
    if (s.contains('未检出') || s.contains('未检') || s.contains('无')) return null;
    // 去掉千分位与普通空格。
    s = s.replaceAll(',', '').replaceAll('，', '').replaceAll(' ', '');
    return double.tryParse(s);
  }

  /// 判断原始文本是否表示「未检出」。
  static bool isNotDetected(String? raw) {
    if (raw == null) return false;
    final s = raw.trim();
    return s.contains('未检出') || s.contains('未检');
  }

  /// 全角字符转半角（含全角数字/字母/标点），并统一全角空格为普通空格。
  static String normalizeFullWidth(String input) {
    final StringBuffer buffer = StringBuffer();
    for (final int code in input.runes) {
      if (code >= 0xFF01 && code <= 0xFF5E) {
        buffer.writeCharCode(code - 0xFEE0);
      } else if (code == 0x3000) {
        buffer.write(' ');
      } else {
        buffer.writeCharCode(code);
      }
    }
    return buffer.toString();
  }

  /// 格式化 double：保留 [fractionDigits] 位小数；null 或非有限返回占位符。
  static String format(double? value, {int fractionDigits = 4}) {
    if (value == null || !value.isFinite) return '—';
    return value.toStringAsFixed(fractionDigits);
  }

  /// 判断字符串是否为一个数字 token（用于 OCR 解析中的 token 分类）。
  static bool isNumericToken(String token) {
    return parseNumber(token) != null;
  }
}
