/// 仪器类型枚举 + 列映射元数据。
///
/// 三种检测仪表格结构：
/// 1. 总大肠菌群检测仪（MCGS 屏）：采样日期、采样时间、总大肠杆菌、单位(MPN/L)、
///    空白对照、测试对照（含小数与「未检出」文本）。
/// 2. 在线水质分析仪（E.co）：采样日期、采样时间、通道、分析结果、空白、检测；
///    通道三类 = 大肠埃希氏菌B / 总大肠菌群A / 菌落总数C。
/// 3. 总铜在线分析仪：时间、数据结果、吸光度、数据标识、当前值、空白值（不参与拟合）。
enum InstrumentType {
  mcgs('总大肠菌群检测仪', 'MCGS', hasChannel: false),
  eco('在线水质分析仪', 'E.co', hasChannel: true),
  totalCopper('总铜在线分析仪', '总铜', hasChannel: false);

  const InstrumentType(this.label, this.shortLabel, {required this.hasChannel});

  /// 仪器全称。
  final String label;

  /// 仪器简称，用于去重键与展示（无通道仪器）。
  final String shortLabel;

  /// 是否有「通道」字段（仅 E.co 有）。
  final bool hasChannel;

  /// 各仪器导出的列头（顺序固定，作为 OCR/导入/导出的列映射依据）。
  List<String> get headers {
    switch (this) {
      case InstrumentType.mcgs:
        return const ['采样日期', '采样时间', '总大肠杆菌', '单位', '空白对照', '测试对照'];
      case InstrumentType.eco:
        return const ['采样日期', '采样时间', '通道', '分析结果', '空白', '检测'];
      case InstrumentType.totalCopper:
        return const ['时间', '数据结果', '吸光度', '数据标识', '当前值', '空白值'];
    }
  }

  /// 采样日期列名；总铜无独立日期列，返回 null。
  String? get dateColumn {
    return this == InstrumentType.totalCopper ? null : '采样日期';
  }

  /// 采样时间列名；总铜用「时间」列。
  String get timeColumn {
    return this == InstrumentType.totalCopper ? '时间' : '采样时间';
  }

  /// 通道列名；无通道仪器返回 null。
  String? get channelColumn {
    return hasChannel ? '通道' : null;
  }

  /// 分析结果列名。
  String get resultColumn {
    switch (this) {
      case InstrumentType.mcgs:
        return '总大肠杆菌';
      case InstrumentType.eco:
        return '分析结果';
      case InstrumentType.totalCopper:
        return '数据结果';
    }
  }

  /// 单位列名；仅 MCGS 有。
  String? get unitColumn {
    return this == InstrumentType.mcgs ? '单位' : null;
  }

  /// 空白列名（用于吸光度计算的「空白」）。
  String get blankColumn {
    switch (this) {
      case InstrumentType.mcgs:
        return '空白对照';
      case InstrumentType.eco:
        return '空白';
      case InstrumentType.totalCopper:
        return '空白值';
    }
  }

  /// 检测列名（用于吸光度计算的「检测」）。
  String get detectionColumn {
    switch (this) {
      case InstrumentType.mcgs:
        return '测试对照';
      case InstrumentType.eco:
        return '检测';
      case InstrumentType.totalCopper:
        return '当前值';
    }
  }

  /// 吸光度列名；仅总铜自带吸光度列。
  String? get absorbanceColumn {
    return this == InstrumentType.totalCopper ? '吸光度' : null;
  }

  /// 是否参与大肠杆菌吸光度拟合。
  bool get supportsFit => this != InstrumentType.totalCopper;
}
