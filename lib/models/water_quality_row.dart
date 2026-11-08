import 'package:uuid/uuid.dart';

import '../utils/number_utils.dart';
import 'instrument_type.dart';

/// 水质数据行：通用列 + 去重键。
class WaterQualityRow {
  WaterQualityRow({
    required this.id,
    required this.instrument,
    this.sampleDate,
    this.sampleTime,
    this.channel,
    this.result,
    this.unit,
    this.blankRaw,
    this.detectionRaw,
    this.blank,
    this.detection,
    this.absorbance,
    Map<String, String>? cells,
  }) : cells = cells ?? {};

  /// 由「列名 → 原始文本」构造行，并自动填充通用字段与解析后的数值。
  ///
  /// 供 OCR 解析器与 Excel 导入复用，保证列映射一致。
  factory WaterQualityRow.fromCells({
    required InstrumentType instrument,
    required Map<String, String> cells,
    String? id,
  }) {
    String? get(String? key) {
      if (key == null) return null;
      final v = cells[key];
      return (v == null || v.trim().isEmpty) ? null : v.trim();
    }

    final String? dateKey = instrument.dateColumn;
    final String blankRaw = get(instrument.blankColumn) ?? '';
    final String detectionRaw = get(instrument.detectionColumn) ?? '';

    return WaterQualityRow(
      id: id ?? const Uuid().v4(),
      instrument: instrument,
      sampleDate: get(dateKey),
      sampleTime: get(instrument.timeColumn),
      channel: get(instrument.channelColumn),
      result: get(instrument.resultColumn),
      unit: get(instrument.unitColumn),
      blankRaw: blankRaw.isEmpty ? null : blankRaw,
      detectionRaw: detectionRaw.isEmpty ? null : detectionRaw,
      blank: NumberUtils.parseNumber(blankRaw),
      detection: NumberUtils.parseNumber(detectionRaw),
      absorbance: NumberUtils.parseNumber(get(instrument.absorbanceColumn)),
      cells: cells,
    );
  }

  /// uuid，编辑/勾选锚点。
  final String id;

  /// 来源仪器。
  final InstrumentType instrument;

  String? sampleDate;
  String? sampleTime;
  String? channel;
  String? result;
  String? unit;
  String? blankRaw;
  String? detectionRaw;
  double? blank;
  double? detection;
  double? absorbance;

  /// 全部列原始值，供可编辑表格展示与导出。
  final Map<String, String> cells;

  /// 去重键：采样日期 + 采样时间 + 通道（无通道仪器用仪器简称）。
  String get dedupKey =>
      '${sampleDate ?? ''}|${sampleTime ?? ''}|${channel ?? instrument.shortLabel}';

  /// 用于界面展示的通道/仪器类别短名。
  String get channelLabel => channel ?? instrument.shortLabel;
}
