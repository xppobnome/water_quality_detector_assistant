import 'dart:math' as math;

/// 归一化裁剪框（相对原图，0..1），与屏幕分辨率无关。
class CropRect {
  const CropRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// 相对原图宽度（0..1）。
  final double left;

  /// 相对原图高度（0..1）。
  final double top;

  /// 相对原图宽度（0..1）。
  final double right;

  /// 相对原图高度（0..1）。
  final double bottom;

  /// 是否构成有效裁剪区（右 > 左、下 > 上，且非退化）。
  bool get isValid => right > left + 0.001 && bottom > top + 0.001;

  /// 约束到 [0,1]，交换反转边，并保证最小尺寸（>= 0.05）。
  CropRect clamp() {
    double l = math.min(left, right).clamp(0.0, 1.0);
    double r = math.max(left, right).clamp(0.0, 1.0);
    double t = math.min(top, bottom).clamp(0.0, 1.0);
    double b = math.max(top, bottom).clamp(0.0, 1.0);

    const double minSide = 0.05;
    if (r - l < minSide) {
      final double mid = (l + r) / 2;
      l = (mid - minSide / 2).clamp(0.0, 1.0);
      r = (mid + minSide / 2).clamp(0.0, 1.0);
      if (r - l < minSide) {
        // 靠边时保证最小尺寸不越界。
        l = 0.0;
        r = 1.0;
      }
    }
    if (b - t < minSide) {
      final double mid = (t + b) / 2;
      t = (mid - minSide / 2).clamp(0.0, 1.0);
      b = (mid + minSide / 2).clamp(0.0, 1.0);
      if (b - t < minSide) {
        t = 0.0;
        b = 1.0;
      }
    }
    return CropRect(left: l, top: t, right: r, bottom: b);
  }

  /// 生成「整图」裁剪框。
  static const CropRect full = CropRect(left: 0, top: 0, right: 1, bottom: 1);
}
