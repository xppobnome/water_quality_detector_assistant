import '../models/water_quality_row.dart';

/// 去重服务。
///
/// 判定键 = [WaterQualityRow.dedupKey]（采样日期|采样时间|通道/仪器简称）。
class DedupService {
  /// 返回去重后行列表，保留首次出现的行。
  List<WaterQualityRow> dedup(List<WaterQualityRow> rows) {
    final Set<String> seen = <String>{};
    final List<WaterQualityRow> result = <WaterQualityRow>[];
    for (final WaterQualityRow row in rows) {
      final String key = dedupKeyOf(row);
      if (key.trim().isEmpty || seen.contains(key)) continue;
      seen.add(key);
      result.add(row);
    }
    return result;
  }

  /// 计算单行去重键。
  String dedupKeyOf(WaterQualityRow row) => row.dedupKey;
}
