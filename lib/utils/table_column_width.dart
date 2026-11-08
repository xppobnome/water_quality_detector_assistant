import '../models/water_quality_row.dart';

/// 结果表格列宽计算 + 悬浮窗坐标约束的纯 Dart 逻辑。
///
/// 抽成不依赖 Flutter 的独立文件，便于在无法运行 `flutter test` 的 Windows
/// 沙箱里直接用 `dart` 实跑验证。

/// 估算文本宽度：中文/全角按 2 个半角字符计，ASCII 按 1。
int textWeight(String s) =>
    s.runes.fold<int>(0, (int n, int r) => n + (r > 0x2E80 ? 2 : 1));

/// 各列的最小宽度下限。
///
/// 「时间」列是完整日期时间（如 `2026-11-03 18:00:00`），固定 132 宽时
/// 必然被截断；「采样日期」「通道」等也按语义给出更宽的下限。
double minimumColumnWidth(String header) {
  switch (header) {
    case '时间':
    case '采样日期':
      return 210;
    case '采样时间':
      return 112;
    case '通道':
      return 152;
    case '总大肠杆菌':
    case '分析结果':
    case '数据结果':
    case '总大肠菌群':
      return 128;
    default:
      return 118;
  }
}

/// 列宽 = max(语义下限, 该列最长内容估算宽度)，限制上限避免过宽。
///
/// [selectable] 为真时额外预留单元格右侧勾选框与表头复选框的空间。
double tableColumnWidth(
  String header,
  List<WaterQualityRow> rows, {
  required bool selectable,
}) {
  int maxWeight = textWeight(header);
  for (final WaterQualityRow row in rows) {
    final int weight = textWeight(row.cells[header] ?? '');
    if (weight > maxWeight) maxWeight = weight;
  }
  // 每半角字符约 8.2px（13~14 号字），再加左右 padding 与勾选框预留。
  final double byContent = maxWeight * 8.2 + (selectable ? 46 : 24);
  final double minimum = minimumColumnWidth(header) + (selectable ? 22 : 0);
  return byContent.clamp(minimum, 300).toDouble();
}

/// 把坐标夹在 [0, upper] 内；upper <= 0 时归零，避免小窗越界。
double clampInViewport(double value, double upper) =>
    value.clamp(0.0, upper > 0 ? upper : 0.0).toDouble();

/// 双指捏合缩放：按「两指距离比值」连续累乘当前缩放值。
///
/// [prevDistance] 为上一帧两指距离、[newDistance] 为当前帧距离：
/// 张开（new > prev）放大、捏合（new < prev）缩小，结果限制在
/// [min]..[max]。任一距离 <= 0 时不做任何变化（防止除零 / 脏数据）。
/// 纯 Dart 实现，不依赖 Flutter，便于沙箱中用 `dart` 直接实跑验证。
double pinchScale(
  double current,
  double prevDistance,
  double newDistance, {
  double min = 1.0,
  double max = 5.0,
}) {
  if (prevDistance <= 0 || newDistance <= 0) return current;
  return (current * (newDistance / prevDistance)).clamp(min, max).toDouble();
}
