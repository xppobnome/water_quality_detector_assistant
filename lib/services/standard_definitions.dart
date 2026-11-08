import '../models/standard.dart';

/// 国标验证标准定义库（依据 **HJ 103—2026《水质总磷自动监测仪技术要求及检测方法》**）。
///
/// 每个验证项均记录：条款号 [VerificationItem.clause]、试验方法
/// [VerificationItem.methodNote]、分组 [VerificationItem.group]，
/// 限值按表 1（基本检测范围 0.02～4 mg/L）与表 2（扩展检测范围 4～50 mg/L）落地。
///
/// 计算实现见 `lib/services/gb_calculator.dart`，规范原文见
/// `docs/GB_HJ103_TP_SPEC.md`。
///
/// 量程键统一为 `basic` / `extended`。

/// 计算设置页的分组顺序与中文名。
const Map<String, String> gbGroupLabels = <String, String>{
  'accuracy': '准确度',
  'precision': '精密度',
  'drift': '零点/量程漂移',
  'memory': '记忆效应',
  'influence': '影响量',
  'other': '其他要求',
};

/// 检测项目下拉项（对应工作空间的 `item` / `parameter`）。
class GbItemOption {
  const GbItemOption(this.id, this.label);

  /// 标准参数 id（'tp' / 'nh3n' / 'tn' / 'cod'）。
  final String id;

  /// 中文标签（'总磷' / '氨氮' / '总氮' / 'COD'）。
  final String label;
}

/// 新建工作空间时「检测项目」下拉选项（顺序即展示顺序）。
const List<GbItemOption> gbItemOptions = <GbItemOption>[
  GbItemOption('tp', '总磷'),
  GbItemOption('nh3n', '氨氮'),
  GbItemOption('tn', '总氮'),
  GbItemOption('cod', 'COD'),
];

/// 中文标签 → 参数 id；未匹配返回 'tp'。
String gbItemIdOfLabel(String label) {
  final String t = label.trim();
  for (final GbItemOption o in gbItemOptions) {
    if (o.label == t) return o.id;
  }
  final String lower = t.toLowerCase();
  if (lower.contains('氨氮') || lower.contains('nh3')) return 'nh3n';
  if (lower.contains('总氮')) return 'tn';
  if (lower.contains('cod') || t.contains('化学需氧量')) return 'cod';
  return 'tp';
}

/// 参数 id → 中文标签；未匹配返回 [fallback]。
String gbItemLabelOfId(String id, {String fallback = '总磷'}) {
  for (final GbItemOption o in gbItemOptions) {
    if (o.id == id) return o.label;
  }
  return fallback;
}

// ---------------------------------------------------------------- 总磷（HJ 103—2026）

/// 总磷验证项（13 项判定 / 14 条记录，记忆效应按两个方向拆分）。
const List<VerificationItem> _tpItems = <VerificationItem>[
  VerificationItem(
    id: 'indication_error',
    name: '示值误差',
    clause: '5.5.1.1',
    group: 'accuracy',
    formulaDesc: 'RE = (r̄ − ρ) / ρ × 100%',
    methodNote:
        '基本范围测上限值 10%、20%、50%、80%（0.4/0.8/2.0/3.2 mg/L）'
        '四种标准溶液，每种连续测定 6 次；扩展范围测上限值 50%（25 mg/L）'
        '连续 6 次。取各浓度相对误差的最大值作为判定值。',
    requiredSeries: <String>['reference', 'measured'],
    limitsByRange: <String, StandardItemLimit>{
      'basic': StandardItemLimit(percent: 5, higherIsFail: true),
      'extended': StandardItemLimit(percent: 5, higherIsFail: true),
    },
    impactHint: '比较各浓度档平均值与标准值的相对误差，偏差最大的浓度档影响最大。',
  ),
  VerificationItem(
    id: 'loq',
    name: '定量下限',
    clause: '5.5.1.2',
    group: 'accuracy',
    formulaDesc: 'S = √[Σ(rᵢ−r̄)²/(n−1)]，LOQ = 10 × S',
    methodNote:
        '测定基本检测范围下限值 0.02 mg/L 的标准溶液，连续 7 次；'
        '计算 7 次测定值的标准偏差 S，LOQ = 10S。'
        '同时该浓度示值误差应在 ±30% 以内。',
    requiredSeries: <String>['repeats'],
    limitsByRange: <String, StandardItemLimit>{
      'basic': StandardItemLimit(absolute: 0.02, higherIsFail: true),
    },
    impactHint: '低浓度重复测定的离散程度决定定量下限，偏离均值最大的点影响最大。',
  ),
  VerificationItem(
    id: 'repeatability',
    name: '重复性',
    clause: '5.5.1.3',
    group: 'precision',
    formulaDesc: 'RSD = √[Σ(rᵢ−r̄)²/(n−1)] / r̄ × 100%',
    methodNote:
        '基本范围测上限值 20% 与 80%（0.8/3.2 mg/L）两种溶液，各连续测定 6 次，'
        '取较大的 RSD 作为判定值；扩展范围测 25 mg/L 连续 6 次。',
    requiredSeries: <String>['repeats'],
    limitsByRange: <String, StandardItemLimit>{
      'basic': StandardItemLimit(percent: 2, higherIsFail: true),
      'extended': StandardItemLimit(percent: 5, higherIsFail: true),
    },
    impactHint: '同一浓度重复测量的相对标准偏差，离均差最大的点影响最大。',
  ),
  VerificationItem(
    id: 'drift_low24h',
    name: '24 h 低浓度漂移',
    clause: '5.5.1.4',
    group: 'drift',
    formulaDesc: 'r̄_E = Σ|rᵢ − r̄₀| / n',
    methodNote:
        '测定约 0.1 mg/L 的标准溶液，1 h 测试 1 次，连续 24 h；'
        '以最初 3 次测定值的平均值作为初期值 r̄₀，'
        '计算测定值与 r̄₀ 偏差绝对值的平均值。',
    requiredSeries: <String>['series24'],
    limitsByRange: <String, StandardItemLimit>{
      'basic': StandardItemLimit(absolute: 0.01, higherIsFail: true),
    },
    impactHint: '与最初 3 次均值偏离最大的测定点影响最大。',
  ),
  VerificationItem(
    id: 'drift_high24h',
    name: '24 h 高浓度漂移',
    clause: '5.5.1.5',
    group: 'drift',
    formulaDesc: 'RD = [Σ|rᵢ − r̄₀| / n] / r_UL × 100%',
    methodNote:
        '基本范围测定上限值 80%（3.2 mg/L）的标准溶液，1 h 测试 1 次，连续 24 h；'
        '扩展范围测定 40 mg/L。以最初 3 次均值 r̄₀ 为初期值，'
        '结果相对于检测范围上限值 r_UL 的百分率。',
    requiredSeries: <String>['series24'],
    limitsByRange: <String, StandardItemLimit>{
      'basic': StandardItemLimit(percent: 1, higherIsFail: true),
      'extended': StandardItemLimit(percent: 5, higherIsFail: true),
    },
    impactHint: '与最初 3 次均值偏离最大的测定点影响最大。',
  ),
  VerificationItem(
    id: 'memory_80to20',
    name: '记忆效应（80%→20%）',
    clause: '5.5.1.6',
    group: 'memory',
    formulaDesc: 'r̄ = Σ(r₂…rₙ)/(n−1)，RE₁ = (r₁ − r̄) / r̄ × 100%',
    methodNote:
        '先连续测量 3 次 80%（3.2 mg/L）标准溶液（结果不考核），'
        '再依次测量 20%（0.8 mg/L）7 次、80%（3.2 mg/L）7 次；'
        '本项为 80% 切换至 20% 后，20% 溶液首次测定值与后 6 次平均值的误差。',
    requiredSeries: <String>['low_after_high'],
    limitsByRange: <String, StandardItemLimit>{
      'basic': StandardItemLimit(percent: 10, higherIsFail: true),
    },
    impactHint: '高浓度后首次测低浓度的残留影响。',
  ),
  VerificationItem(
    id: 'memory_20to80',
    name: '记忆效应（20%→80%）',
    clause: '5.5.1.6',
    group: 'memory',
    formulaDesc: 'r̄ = Σ(r₂…rₙ)/(n−1)，RE₁ = (r₁ − r̄) / r̄ × 100%',
    methodNote: '同上试验，本项为 20% 切换至 80% 后，80% 溶液首次测定值与后 6 次平均值的误差。',
    requiredSeries: <String>['high_after_low'],
    limitsByRange: <String, StandardItemLimit>{
      'basic': StandardItemLimit(percent: 5, higherIsFail: true),
    },
    impactHint: '低浓度后首次测高浓度的残留影响。',
  ),
  VerificationItem(
    id: 'voltage',
    name: '电压影响',
    clause: '5.5.1.7',
    group: 'influence',
    formulaDesc: 'RE₂ = (r₂ − r₃) / r₃ × 100%',
    methodNote:
        '采用上限值 80%（3.2 mg/L）的标准溶液：220 V 测 3 次，'
        '242 V 测 3 次，198 V 测 3 次；分别计算 242 V、198 V 相对 220 V '
        '三次均值的相对误差，取绝对值较大者。',
    requiredSeries: <String>['v220', 'v242', 'v198'],
    limitsByRange: <String, StandardItemLimit>{
      'basic': StandardItemLimit(percent: 5, higherIsFail: true),
    },
    impactHint: '电压偏离 220 V 时示值变化最大的条件影响最大。',
  ),
  VerificationItem(
    id: 'turbidity',
    name: '浊度影响',
    clause: '5.5.1.8',
    group: 'influence',
    formulaDesc: 'RE₃ = (r₄ − r₅) / r₅ × 100%',
    methodNote:
        '采用上限值 10%（0.4 mg/L）的标准溶液：无浊度测 3 次，'
        '调节浊度至 100 NTU 测 3 次，300 NTU 测 3 次；'
        '分别计算相对不含浊度溶液均值的误差，取绝对值较大者。',
    requiredSeries: <String>['t0', 't100', 't300'],
    limitsByRange: <String, StandardItemLimit>{
      'basic': StandardItemLimit(percent: 15, higherIsFail: true),
    },
    impactHint: '浊度升高时示值变化最大的条件影响最大。',
  ),
  VerificationItem(
    id: 'temperature',
    name: '环境温度影响',
    clause: '5.5.1.9',
    group: 'influence',
    formulaDesc: 'RE₄ = (r₆ − r₇) / r₇ × 100%',
    methodNote:
        '采用上限值 80%（3.2 mg/L）的标准溶液，按 20℃→5℃→20℃→40℃→20℃ '
        '顺序调整环境温度，每次变温后试剂稳定 3 h 再连续测 3 次；'
        '5℃、40℃ 各 3 次均值与 20℃ 共 9 次均值比较，取绝对值较大者。',
    requiredSeries: <String>['t20a', 't5', 't20b', 't40', 't20c'],
    limitsByRange: <String, StandardItemLimit>{
      'basic': StandardItemLimit(percent: 5, higherIsFail: true),
    },
    impactHint: '温度偏离 20℃ 时示值变化最大的条件影响最大。',
  ),
  VerificationItem(
    id: 'sample_compare',
    name: '实际样品比对',
    clause: '5.5.1.10',
    group: 'accuracy',
    formulaDesc:
        'r̄_E = Σ|rᵢ − r_R| / n（r_R < 0.4 mg/L）\n'
        'RE = [Σ|rᵢ − r_R| / n] / r_R × 100%（r_R ≥ 0.4 mg/L）',
    methodNote:
        '选择 5 种不同类型样品，仪器连续测量不少于 10 次；'
        '实验室按 GB/T 11893 重复测量不少于 3 次取平均值 r_R。'
        '实验室均值 < 0.4 mg/L 按绝对误差判定（≤0.04 mg/L），'
        '≥ 0.4 mg/L 按相对误差判定（≤10%）。',
    requiredSeries: <String>['repeats'],
    limitsByRange: <String, StandardItemLimit>{
      // 双限值：按浓度分类二选一（见 StandardItemLimit.isDual）。
      'basic': StandardItemLimit(
        absolute: 0.04,
        percent: 10,
        higherIsFail: true,
      ),
    },
    impactHint: '与实验室均值偏离最大的测定点影响最大。',
  ),
  VerificationItem(
    id: 'maintenance',
    name: '最小维护周期',
    clause: '5.5.1.11',
    group: 'other',
    formulaDesc: '任意两次维护的时间间隔（h），取最小值',
    methodNote: '整个检测周期中，任何 2 次维护（倾倒废液、添加试剂、更换量程及维修等）间隔应 ≥168 h。',
    requiredSeries: <String>['interval_hours'],
    limitsByRange: <String, StandardItemLimit>{
      'basic': StandardItemLimit(absolute: 168, higherIsFail: false),
      'extended': StandardItemLimit(absolute: 168, higherIsFail: false),
    },
    impactHint: '间隔最短的两次维护决定该项结论（值越大越好）。',
  ),
  VerificationItem(
    id: 'data_availability',
    name: '数据有效率',
    clause: '5.5.1.12',
    group: 'other',
    formulaDesc: 'D = D_e / D_t × 100%',
    methodNote: '整个检测周期内实际有效数据个数与应获得总数据个数之比，应 ≥90%。',
    requiredSeries: <String>['total', 'available'],
    limitsByRange: <String, StandardItemLimit>{
      'basic': StandardItemLimit(percent: 90, higherIsFail: false),
      'extended': StandardItemLimit(percent: 90, higherIsFail: false),
    },
    impactHint: '有效数据占比（值越大越好）。',
  ),
  VerificationItem(
    id: 'conformity',
    name: '一致性偏差',
    clause: '5.5.1.13',
    group: 'precision',
    formulaDesc:
        'RSDⱼ = √[Σ(ρᵢⱼ−ρ̄ⱼ)²/(t−1)] / ρ̄ⱼ × 100%，t=3\n'
        'CD = √[Σ RSDⱼ² / m]，m=168',
    methodNote:
        '3 台仪器同时测试相同浓度溶液，1 h 测试 1 次，共 168 组数据；'
        '先算每个时段 3 台仪器的相对标准偏差 RSDⱼ，再算其平方平均数 CD。'
        '当某时段 RSDⱼ > 10% 时视为 CD > 10%。',
    requiredSeries: <String>['instruments'],
    limitsByRange: <String, StandardItemLimit>{
      'basic': StandardItemLimit(percent: 10, higherIsFail: true),
    },
    impactHint: '时段内 3 台仪器离散度最大的时段影响最大。',
  ),
];

/// 总磷标准（HJ 103—2026，已按原文完整内置）。
const Standard totalPhosphorusStandard = Standard(
  id: 'tp',
  name: '总磷',
  code: 'HJ 103—2026',
  items: _tpItems,
  ranges: <String>['basic', 'extended'],
  note:
      '依据 HJ 103—2026《水质总磷自动监测仪技术要求及检测方法》，'
      '基本检测范围 0.02～4 mg/L，扩展检测范围 4～50 mg/L。',
);

/// 氨氮标准（**限值尚未按标准原文核对**，仅作数据管理用）。
///
/// 刻意不挂 [VerificationItem]：避免把总磷的限值挂在氨氮名下造成误判，
/// 待补齐氨氮标准原文后再填充 items。
const Standard ammoniaNitrogenStandard = Standard(
  id: 'nh3n',
  name: '氨氮',
  code: '',
  implemented: false,
  note: '氨氮标准原文尚未核对，本模块仅提供数据管理与记录，暂不出具合格判定。',
  ranges: <String>['basic', 'extended'],
  items: <VerificationItem>[],
);

/// 总氮（占位，未内置标准）。
const Standard totalNitrogenStandard = Standard(
  id: 'tn',
  name: '总氮',
  code: '',
  implemented: false,
  note: '总氮标准尚未内置，本模块仅提供数据管理与记录。',
  ranges: <String>['basic'],
  items: <VerificationItem>[],
);

/// COD（占位，未内置标准）。
const Standard codStandard = Standard(
  id: 'cod',
  name: 'COD',
  code: '',
  implemented: false,
  note: 'COD 标准尚未内置，本模块仅提供数据管理与记录。',
  ranges: <String>['basic'],
  items: <VerificationItem>[],
);

/// 全部内置标准（顺序即导航/下拉展示顺序）。
const List<Standard> allStandards = <Standard>[
  totalPhosphorusStandard,
  ammoniaNitrogenStandard,
  totalNitrogenStandard,
  codStandard,
];

/// 按参数 id 取标准，未找到返回 null。
Standard? standardById(String id) {
  for (final Standard s in allStandards) {
    if (s.id == id) return s;
  }
  return null;
}

/// 参数 id → 中文名（含未内置标准的占位）。
String parameterLabel(String id) {
  final Standard? s = standardById(id);
  if (s != null) return s.name;
  switch (id) {
    case 'custom':
      return '自定义';
    default:
      return id.isEmpty ? '未指定' : id;
  }
}

/// 兼容旧接口：工作区「标准参数」可选 id 列表。
const List<String> selectableParameters = <String>['tp', 'nh3n', 'tn', 'cod'];
