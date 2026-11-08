import '../models/instrument_type.dart';

/// 依据 OCR 文本中的表头特征自动判断仪器类型。
///
/// 优先级（避免误判）：吸光度类（吸光度/数据标识）> E.co（通道）> MCGS（空白对照/测试对照）。
/// 无法判断返回 null，由调用方降级为 mcgs 并提示用户人工确认。
///
/// 注意：判定只看表头列，不看仪器标题。「总磷在线分析仪 <<数据查询>>」与
/// 「总铜在线分析仪」共用同一套列（时间/数据结果/吸光度/数据标识/当前值/空白值），
/// 因此都会归入 [InstrumentType.totalCopper] 这一列结构，解析结果一致。
InstrumentType? detectInstrumentType(String text) {
  final String t = text.replaceAll(RegExp(r'\s+'), '');

  // 1) 总铜在线分析仪：独有「吸光度」「数据标识」「当前值」「空白值」。
  final int copperHits = <String>[
    '吸光度',
    '数据标识',
    '当前值',
    '空白值',
  ].where((String k) => t.contains(k)).length;
  if (copperHits >= 2) return InstrumentType.totalCopper;

  // 2) 在线水质分析仪（E.co）：「通道」+ 三通道名/分析结果。
  final bool hasChannelWord = t.contains('通道');
  final bool hasChannelName =
      t.contains('大肠埃希氏菌') || t.contains('总大肠菌群') || t.contains('菌落总数');
  if (hasChannelWord || hasChannelName) return InstrumentType.eco;

  // 3) 总大肠菌群检测仪（MCGS）：「空白对照」「测试对照」「总大肠杆菌」。
  final int mcgsHits = <String>[
    '空白对照',
    '测试对照',
    '总大肠杆菌',
  ].where((String k) => t.contains(k)).length;
  if (mcgsHits >= 1) return InstrumentType.mcgs;

  return null;
}
