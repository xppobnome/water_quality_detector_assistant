import 'dart:math' as math;

import '../models/workspace.dart';

/// 自动匹配规则：识别参数与建议验证项。
class RuleMatcher {
  RuleMatcher._();

  /// 从 OCR/粘贴文本识别参数 id；识别不出返回 null。
  ///
  /// 关键词：总磷/TP、氨氮/NH3-N、总氮/TN。大小写不敏感。
  static String? detectParameter(String ocrText) {
    final String t = ocrText.toLowerCase();
    if (t.contains('总磷') ||
        t.contains('总p') ||
        t.contains('tp') ||
        t.contains('总 p'))
      return 'tp';
    if (t.contains('氨氮') ||
        t.contains('nh3-n') ||
        t.contains('nh3n') ||
        t.contains('nh3'))
      return 'nh3n';
    if (t.contains('总氮') || t.contains('tn')) return 'tn';
    return null;
  }

  /// 根据测量数据与已选量程建议验证项 id；无法可靠判断返回 null。
  ///
  /// 判定优先级：
  /// 1. 约 24 组且时间跨度约 24h → 24h 漂移（按浓度落 basic/extended 选 low/high）；
  /// 2. 同水平重复 n≥3 → 重复性；
  /// 3. 含标准值 + 示值序列 → 示值误差；
  /// 4. 含高→低序列 → 记忆效应；
  /// 5. 否则 null，由用户手选。
  ///
  /// 重要：组数明显不等于 24（超过或不足）时不强行判定漂移，返回 null。
  static String? suggestItem(
    String parameter,
    List<Measurement> measurements,
    String rangeKey,
  ) {
    final int count = measurements.length;

    // 1) 24h 漂移：约 24 组 + 时间跨度约 24h + 单一浓度水平。
    if (_isAbout24(count) &&
        _spanAbout24h(measurements) &&
        _singleLevel(measurements)) {
      final double mean = _meanValue(measurements);
      // 按量程/浓度选择 low 或 high 漂移。basic 上限按总磷约定为 4 mg/L。
      final bool low = rangeKey != 'extended' && mean <= 4.0;
      return low ? 'drift_low24h' : 'drift_high24h';
    }

    // 2) 示值误差：含标准值 + 示值序列（优先于重复性，避免带标液数据被误判为重复）。
    if (_hasRefMeasured(measurements)) {
      return 'indication_error';
    }

    // 3) 重复性：同水平重复 n≥3（仅当无标准值/示值特征时）。
    if (count >= 3 && _singleLevel(measurements)) {
      return 'repeatability';
    }

    // 4) 记忆效应：高→低序列。
    if (_hasHighThenLow(measurements)) {
      return 'memory_effect';
    }

    return null;
  }

  /// 组数是否接近 24（允许 OCR 噪声的小幅偏差，但不强行判定明显不符者）。
  static bool _isAbout24(int count) => count >= 22 && count <= 26;

  static bool _spanAbout24h(List<Measurement> ms) {
    final List<Measurement> withTs = ms
        .where((Measurement m) => m.timestamp != null)
        .toList();
    if (withTs.length < 2) return false;
    final Duration span = withTs.last.timestamp!.difference(
      withTs.first.timestamp!,
    );
    return span.inHours >= 18 && span.inHours <= 30;
  }

  static double _meanValue(List<Measurement> ms) {
    final List<double> vs = ms
        .map((Measurement m) => m.values['value'])
        .whereType<double>()
        .toList();
    if (vs.isEmpty) return 0;
    return vs.reduce((double a, double b) => a + b) / vs.length;
  }

  static bool _singleLevel(List<Measurement> ms) {
    final List<double> vs = ms
        .map((Measurement m) => m.values['value'])
        .whereType<double>()
        .toList();
    if (vs.length < 3) return false;
    final double mean = vs.reduce((double a, double b) => a + b) / vs.length;
    if (mean == 0) return false;
    final double std = _std(vs, mean);
    // 相对标准差 < 5% 视为单一水平。
    return (std / mean.abs()) < 0.05;
  }

  static bool _hasRefMeasured(List<Measurement> ms) {
    for (final Measurement m in ms) {
      if (m.values.containsKey('reference') ||
          m.values.containsKey('measured')) {
        return true;
      }
      final String lbl = (m.label ?? '').toLowerCase();
      if (lbl.contains('标') ||
          lbl.contains('reference') ||
          lbl.contains('示') ||
          lbl.contains('measured')) {
        return true;
      }
    }
    return false;
  }

  static bool _hasHighThenLow(List<Measurement> ms) {
    bool sawHigh = false;
    for (final Measurement m in ms) {
      final String lbl = m.label ?? '';
      if (lbl.contains('高')) sawHigh = true;
      if (sawHigh && lbl.contains('低')) return true;
    }
    return false;
  }

  static double _std(List<double> xs, double mean) {
    if (xs.length < 2) return 0;
    double s = 0;
    for (final double x in xs) {
      s += (x - mean) * (x - mean);
    }
    return math.sqrt(s / (xs.length - 1));
  }
}
