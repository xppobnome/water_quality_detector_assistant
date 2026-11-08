import 'dart:math';

import '../models/fit_result.dart';

/// 吸光度计算 + 一次函数线性拟合。
class FitService {
  /// 吸光度 = ln(空白/检测) * 10000；空白 < 检测时反向 ln(检测/空白)。
  ///
  /// 任一为空 / 非数值 / <= 0 时返回 null（由上层跳过并提示）。
  double? calcAbsorbance(double? blank, double? detection) {
    if (blank == null || detection == null) return null;
    if (blank <= 0 || detection <= 0) return null;
    if (!blank.isFinite || !detection.isFinite) return null;

    final double ratio = blank >= detection
        ? blank / detection
        : detection / blank;
    if (ratio <= 0 || !ratio.isFinite) return null;
    return log(ratio) * 10000;
  }

  /// 以最小二乘法拟合 y = aX + b，返回 slope=a（展示 B）、intercept=b（展示 A）、rSquared=R²。
  ///
  /// 处理退化场景：无点、单点、全部 x 相同、全部 y 相同。
  FitResult linearFit(List<FitPoint> points) {
    final int n = points.length;
    if (n == 0) {
      return FitResult(slope: 0, intercept: 0, rSquared: 0, points: []);
    }

    double sumX = 0;
    double sumY = 0;
    for (final FitPoint p in points) {
      sumX += p.x;
      sumY += p.y;
    }

    final double meanX = sumX / n;
    final double meanY = sumY / n;

    double sxx = 0;
    double sxy = 0;
    double syy = 0;
    for (final FitPoint p in points) {
      final double dx = p.x - meanX;
      final double dy = p.y - meanY;
      sxx += dx * dx;
      sxy += dx * dy;
      syy += dy * dy;
    }

    double slope;
    double intercept;

    if (sxx == 0) {
      // 所有 x 相同，无法估计斜率，取水平线。
      slope = 0;
      intercept = meanY;
    } else {
      slope = sxy / sxx;
      intercept = meanY - slope * meanX;
    }

    // 拟合优度 R² = 1 - SS_res / SS_tot。
    double rSquared;
    if (syy == 0) {
      rSquared = 1;
    } else {
      double ssRes = 0;
      for (final FitPoint p in points) {
        final double predicted = slope * p.x + intercept;
        final double e = p.y - predicted;
        ssRes += e * e;
      }
      rSquared = 1 - ssRes / syy;
      // 数值上可能略超出 [0,1]，收敛回区间。
      rSquared = rSquared.clamp(0.0, 1.0);
    }

    return FitResult(
      slope: slope,
      intercept: intercept,
      rSquared: rSquared,
      points: List<FitPoint>.from(points),
    );
  }
}
