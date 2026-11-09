/// 国标验证领域模型：判定限、验证项、标准。
///
/// 设计目标：可扩展。新增参数（总氮、COD 等）只需在
/// [standard_definitions.dart] 增加一个 [Standard]，UI 与计算引擎无需改动。

/// 单项判定限。
///
/// 判定限可以是绝对量（[absolute]，单位随指标而定，如 mg/L、h），
/// 也可以是相对量（[percent]，如 %）。同一量程下通常二选一；
/// **例外**：「实际样品比对」（5.5.1.10）按浓度分类同时使用两者——
/// 实验室均值 < 0.4 mg/L 时用 [absolute]（≤0.04 mg/L），
/// ≥ 0.4 mg/L 时用 [percent]（≤10%），此时两个字段同时非空，
/// 由计算引擎依据浓度分类选择（见 [isDual]）。
/// [higherIsFail] 表示「值越大越差」（误差/漂移/RSD/影响量等）；
/// 置为 false 表示「值越大越好」（如数据有效率、维护周期）。
class StandardItemLimit {
  const StandardItemLimit({
    this.absolute,
    this.percent,
    required this.higherIsFail,
  });

  /// 绝对量与相对量同时生效（按浓度分类二选一）。
  bool get isDual => absolute != null && percent != null;

  /// 绝对限值（单位随指标：mg/L、h 等）。
  final double? absolute;

  /// 相对限值（%）。
  final double? percent;

  /// true 表示值越大越差（判定为不合格的上限）；
  /// false 表示值越大越好（判定为合格的下限）。
  final bool higherIsFail;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'absolute': absolute,
    'percent': percent,
    'higherIsFail': higherIsFail,
  };

  factory StandardItemLimit.fromJson(Map<String, dynamic> j) =>
      StandardItemLimit(
        absolute: (j['absolute'] as num?)?.toDouble(),
        percent: (j['percent'] as num?)?.toDouble(),
        higherIsFail: j['higherIsFail'] as bool? ?? true,
      );
}

/// 验证项（如示值误差、重复性、24h 漂移等）。
class VerificationItem {
  const VerificationItem({
    required this.id,
    required this.name,
    required this.formulaDesc,
    required this.requiredSeries,
    required this.limitsByRange,
    required this.impactHint,
    this.clause = '',
    this.methodNote = '',
    this.group = '',
  });

  /// 唯一标识（跨参数共用同一套 id，如 'indication_error'）。
  final String id;

  /// 中文名称。
  final String name;

  /// 公式描述（展示用）。
  final String formulaDesc;

  /// 计算所需的序列键（如 ['reference', 'measured']、['repeats']）。
  final List<String> requiredSeries;

  /// 各量程（rangeKey）对应的判定限。
  final Map<String, StandardItemLimit> limitsByRange;

  /// 影响分析提示文案（面向用户）。
  final String impactHint;

  /// 标准条款号，如 `5.5.1.1`（用于结果页展示依据）。
  final String clause;

  /// 试验方法简述（浓度要求、次数、时长等），展示在计算设置页与结果页。
  final String methodNote;

  /// 分组键，用于计算设置页分组展示：accuracy/precision/drift/memory/
  /// influence/other。
  final String group;

  /// 取指定量程的判定限，无则返回 null。
  StandardItemLimit? limitFor(String rangeKey) => limitsByRange[rangeKey];

  /// 该量程下是否参与验证（无限值即该量程不适用，如扩展量程无定量下限）。
  bool appliesTo(String rangeKey) => limitsByRange.containsKey(rangeKey);

  /// 复制并替换限值表（供自定义判定限生效时使用）。
  ///
  /// 仅替换 [limitsByRange]，其余字段原样保留，保证「覆盖限值」不会
  /// 顺手改掉名称、条款、序列要求等可审计信息。
  VerificationItem copyWith({Map<String, StandardItemLimit>? limitsByRange}) =>
      VerificationItem(
        id: id,
        name: name,
        formulaDesc: formulaDesc,
        requiredSeries: requiredSeries,
        limitsByRange: limitsByRange ?? this.limitsByRange,
        impactHint: impactHint,
        clause: clause,
        methodNote: methodNote,
        group: group,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'formulaDesc': formulaDesc,
    'requiredSeries': requiredSeries,
    'limitsByRange': limitsByRange.map(
      (String k, StandardItemLimit v) =>
          MapEntry<String, dynamic>(k, v.toJson()),
    ),
    'impactHint': impactHint,
    'clause': clause,
    'methodNote': methodNote,
    'group': group,
  };

  factory VerificationItem.fromJson(Map<String, dynamic> j) => VerificationItem(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    formulaDesc: j['formulaDesc'] as String? ?? '',
    requiredSeries: List<String>.from(
      j['requiredSeries'] as List? ?? <dynamic>[],
    ),
    limitsByRange: (j['limitsByRange'] as Map? ?? <String, dynamic>{}).map(
      (dynamic k, dynamic v) => MapEntry<String, StandardItemLimit>(
        k as String,
        StandardItemLimit.fromJson(v as Map<String, dynamic>),
      ),
    ),
    impactHint: j['impactHint'] as String? ?? '',
    clause: j['clause'] as String? ?? '',
    methodNote: j['methodNote'] as String? ?? '',
    group: j['group'] as String? ?? '',
  );
}

/// 一项国标（对应一个监测参数）。
class Standard {
  const Standard({
    required this.id,
    required this.name,
    required this.items,
    required this.ranges,
    this.code = '',
    this.implemented = true,
    this.note = '',
  });

  /// 参数 id（如 'tp'、'nh3n'、'tn'）。
  final String id;

  /// 参数中文名（如 '总磷'、'氨氮'）。
  final String name;

  /// 验证项集合。
  final List<VerificationItem> items;

  /// 量程键集合（如 ['basic', 'extended']）。
  final List<String> ranges;

  /// 标准号，如 `HJ 103—2026`。
  final String code;

  /// 是否已按标准原文完整内置（false 时 UI 只做数据管理，不出具判定）。
  final bool implemented;

  /// 说明/免责文案（如"限值尚未核对标准原文"）。
  final String note;

  /// 按 id 取验证项，未找到返回 null。
  VerificationItem? itemById(String id) {
    for (final VerificationItem item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// 分组展示用的验证项列表（按 [VerificationItem.group] 归并，保持定义顺序）。
  List<VerificationItem> itemsOfGroup(String group) =>
      items.where((VerificationItem i) => i.group == group).toList();

  /// 量程中文标签。
  String rangeLabel(String rangeKey) {
    switch (rangeKey) {
      case 'basic':
        return '基本量程';
      case 'extended':
        return '扩展量程';
      default:
        return rangeKey;
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'items': items.map((VerificationItem i) => i.toJson()).toList(),
    'ranges': ranges,
    'code': code,
    'implemented': implemented,
    'note': note,
  };

  factory Standard.fromJson(Map<String, dynamic> j) => Standard(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    items: (j['items'] as List? ?? <dynamic>[])
        .map(
          (dynamic e) => VerificationItem.fromJson(e as Map<String, dynamic>),
        )
        .toList(),
    ranges: List<String>.from(j['ranges'] as List? ?? <dynamic>[]),
    code: j['code'] as String? ?? '',
    implemented: j['implemented'] as bool? ?? true,
    note: j['note'] as String? ?? '',
  );
}
