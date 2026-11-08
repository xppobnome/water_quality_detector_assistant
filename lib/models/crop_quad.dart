import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'crop_rect.dart';

/// 归一化四点裁剪区（相对原图，0..1）。
///
/// 与 [CropRect] 的本质区别：四个角是**四个完全独立的点**。拖动任一角只改变
/// 该角对应的 [Offset]，其余三点坐标绝对不变，因此裁剪区可以是任意四边形；
/// 输出时由 `ImageCropService.cropQuad` 做透视变换拉正为矩形。
///
/// 四点顺序固定为 tl → tr → br → bl（顺时针），与单应方程的角点顺序一致。
class CropQuad {
  const CropQuad({
    required this.tl,
    required this.tr,
    required this.br,
    required this.bl,
  });

  /// 左上角。
  final Offset tl;

  /// 右上角。
  final Offset tr;

  /// 右下角。
  final Offset br;

  /// 左下角。
  final Offset bl;

  /// 按 tl → tr → br → bl 顺序返回四点。
  List<Offset> get points => <Offset>[tl, tr, br, bl];

  /// 鞋带公式计算的四边形面积（归一化坐标下整图为 1.0）。
  double get area {
    double sum = 0.0;
    final List<Offset> pts = points;
    for (int i = 0; i < pts.length; i++) {
      final Offset p = pts[i];
      final Offset n = pts[(i + 1) % pts.length];
      sum += p.dx * n.dy - n.dx * p.dy;
    }
    return (sum * 0.5).abs();
  }

  /// 四点非退化：面积大于 0.0004（约等于 0.02×0.02 的最小可用区域）。
  bool get isValid => area > 0.0004;

  /// 只把每个点各自钳到 [0,1]；绝不交换点、绝不推动其它点。
  CropQuad clamp() => CropQuad(
    tl: _clampPoint(tl),
    tr: _clampPoint(tr),
    br: _clampPoint(br),
    bl: _clampPoint(bl),
  );

  static Offset _clampPoint(Offset o) =>
      Offset(o.dx.clamp(0.0, 1.0).toDouble(), o.dy.clamp(0.0, 1.0).toDouble());

  /// 外接矩形：透视变换失败时回退到普通矩形裁剪。
  CropRect toBoundingRect() {
    final List<Offset> pts = points;
    double l = pts.first.dx;
    double r = pts.first.dx;
    double t = pts.first.dy;
    double b = pts.first.dy;
    for (final Offset o in pts) {
      l = math.min(l, o.dx);
      r = math.max(r, o.dx);
      t = math.min(t, o.dy);
      b = math.max(b, o.dy);
    }
    return CropRect(left: l, top: t, right: r, bottom: b);
  }

  /// 由矩形生成四点（顺序 tl → tr → br → bl）。
  static CropQuad fromRect(CropRect r) => CropQuad(
    tl: Offset(r.left, r.top),
    tr: Offset(r.right, r.top),
    br: Offset(r.right, r.bottom),
    bl: Offset(r.left, r.bottom),
  );

  /// 整图。
  static const CropQuad full = CropQuad(
    tl: Offset(0, 0),
    tr: Offset(1, 0),
    br: Offset(1, 1),
    bl: Offset(0, 1),
  );

  @override
  String toString() => 'CropQuad(tl=$tl, tr=$tr, br=$br, bl=$bl)';
}
