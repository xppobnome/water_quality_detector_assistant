/// 拟合散点。
class FitPoint {
  FitPoint(this.x, this.y);

  /// x 轴：标液浓度 / 0。
  final double x;

  /// y 轴：吸光度。
  final double y;

  Map<String, dynamic> toJson() => <String, dynamic>{'x': x, 'y': y};

  factory FitPoint.fromJson(Map<String, dynamic> j) => FitPoint(
    (j['x'] as num?)?.toDouble() ?? 0,
    (j['y'] as num?)?.toDouble() ?? 0,
  );
}

/// 一次函数 y = aX + b 拟合结果。
class FitResult {
  FitResult({
    required this.slope,
    required this.intercept,
    required this.rSquared,
    required this.points,
  });

  /// 斜率 a，界面展示为 B。
  final double slope;

  /// 截距 b，界面展示为 A。
  final double intercept;

  /// 拟合度 R²。
  final double rSquared;

  /// 参与拟合的散点。
  final List<FitPoint> points;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'slope': slope,
    'intercept': intercept,
    'rSquared': rSquared,
    'points': points.map((FitPoint p) => p.toJson()).toList(),
  };

  factory FitResult.fromJson(Map<String, dynamic> j) => FitResult(
    slope: (j['slope'] as num?)?.toDouble() ?? 0,
    intercept: (j['intercept'] as num?)?.toDouble() ?? 0,
    rSquared: (j['rSquared'] as num?)?.toDouble() ?? 0,
    points: (j['points'] as List? ?? <dynamic>[])
        .map((dynamic e) => FitPoint.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}
