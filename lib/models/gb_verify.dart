/// 国标验证（HJ 103—2026 总磷）领域模型。
///
/// 与旧版 [CalcResult] 的区别：旧版只保存一个指标数值，无法展示"逐步计算过程"；
/// 本模型把每一步的公式、代入值、结果、文字说明都记录成 [CalcStep]，
/// 并整体挂在一个 [CalcSession]（一次计算会话）下，便于持久化与 Excel 导出。
///
/// 全部为纯数据类，手写 toJson/fromJson，不依赖 Flutter，便于单元测试。
library;

/// 单个验证项的判定结论。
enum GbConclusion {
  /// 合格。
  pass,

  /// 不合格。
  fail,

  /// 无法判定（数据不足、分母为 0、缺少必填参数等）。
  notApplicable,
}

/// 结论的中文标签。
String conclusionLabel(GbConclusion c) {
  switch (c) {
    case GbConclusion.pass:
      return '合格';
    case GbConclusion.fail:
      return '不合格';
    case GbConclusion.notApplicable:
      return '无法判定';
  }
}

/// 一条参与计算的样品数据（来自 OCR / Excel 导入的数据集行）。
///
/// [value] 对应 OCR 表的「数据结果」列，是唯一参与国标计算的量；
/// [cells] 保留整行原始文本（时间/吸光度/数据标识/当前值/空白值…），
/// 用于结果页展示与 Excel 导出。
class GbSample {
  const GbSample({
    required this.id,
    required this.value,
    this.time,
    this.flag = '',
    this.index = 0,
    this.cells = const <String, String>{},
  });

  /// 数据集内唯一 id（对应 Measurement.id）。
  final String id;

  /// 测定值（mg/L），来自「数据结果」列。
  final double value;

  /// 采样时间（来自「时间」列），用于排序与 24 h 连续性校验。
  final DateTime? time;

  /// 数据标识（来自「数据标识」列）。空串或 `N` 视为有效数据。
  final String flag;

  /// 在数据集中的序号，从 1 开始（用于步骤描述"第 3 次测定"）。
  final int index;

  /// 整行原始文本（列名 → 值）。
  final Map<String, String> cells;

  /// 是否为有效数据（标准要求无效数据不参与计算）。
  bool get isValid {
    final String f = flag.trim().toUpperCase();
    return f.isEmpty || f == 'N';
  }

  /// 时间的展示文本（yyyy-MM-dd HH:mm:ss），无时间返回空串。
  String get timeText {
    final DateTime? t = time;
    if (t == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  GbSample copyWith({
    double? value,
    String? flag,
    int? index,
    Map<String, String>? cells,
  }) => GbSample(
    id: id,
    value: value ?? this.value,
    time: time,
    flag: flag ?? this.flag,
    index: index ?? this.index,
    cells: cells ?? this.cells,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'value': value,
    'time': time?.toIso8601String(),
    'flag': flag,
    'index': index,
    'cells': cells,
  };

  factory GbSample.fromJson(Map<String, dynamic> j) => GbSample(
    id: j['id'] as String? ?? '',
    value: (j['value'] as num?)?.toDouble() ?? 0,
    time: j['time'] == null ? null : DateTime.tryParse(j['time'] as String),
    flag: j['flag'] as String? ?? '',
    index: (j['index'] as num?)?.toInt() ?? 0,
    cells: (j['cells'] as Map? ?? <String, dynamic>{}).map(
      (dynamic k, dynamic v) => MapEntry<String, String>(k as String, '$v'),
    ),
  );
}

/// 计算过程中的一个步骤。
///
/// 一步 = 一个可独立阅读的计算动作，UI 按 [no] 顺序展示：
/// 标题 → 公式 → 代入 → 结果 → 说明。
class CalcStep {
  const CalcStep({
    required this.no,
    required this.title,
    this.formula = '',
    this.substitution = '',
    this.result = '',
    this.unit = '',
    this.note = '',
  });

  /// 步骤序号，从 1 开始。
  final int no;

  /// 步骤标题，如「计算 20% 浓度档 6 次测定值平均值」。
  final String title;

  /// 公式原文（字母形式），如 `r̄ = (r₁+r₂+…+r₆) / 6`。
  final String formula;

  /// 数字代入过程，如 `(0.8006+0.7997+0.8057+0.8000+0.8182+0.8090) / 6`。
  final String substitution;

  /// 计算结果（已按展示精度格式化），如 `0.8055`。
  final String result;

  /// 结果单位（`%`、`mg/L`、`h`，无单位为空串）。
  final String unit;

  /// 一句话文字说明（面向用户，解释这步在做什么、依据哪条要求）。
  final String note;

  /// 结果 + 单位 的合并展示。
  String get resultText => unit.isEmpty ? result : '$result $unit';

  bool get hasBody =>
      formula.isNotEmpty ||
      substitution.isNotEmpty ||
      result.isNotEmpty ||
      note.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'no': no,
    'title': title,
    'formula': formula,
    'substitution': substitution,
    'result': result,
    'unit': unit,
    'note': note,
  };

  factory CalcStep.fromJson(Map<String, dynamic> j) => CalcStep(
    no: (j['no'] as num?)?.toInt() ?? 0,
    title: j['title'] as String? ?? '',
    formula: j['formula'] as String? ?? '',
    substitution: j['substitution'] as String? ?? '',
    result: j['result'] as String? ?? '',
    unit: j['unit'] as String? ?? '',
    note: j['note'] as String? ?? '',
  );
}

/// 单个浓度档 / 条件段的判定结果。
///
/// 一个验证项可能由多个档位组成（示值误差在基本量程是「上限值 10%/20%/50%/80%」
/// 四个浓度档，重复性是 20%/80% 两档，温度是 5 个温度段，电压/浊度各 3 段，
/// 一致性偏差是 3 台仪器）。旧实现只给出一项总判定，用户看不到「哪一档不合格」；
/// 本模型把逐档的指标值、限值与判定结果都记录下来，供结果页与 Excel 导出逐档展示。
///
/// 逐档结论的聚合规则是「按已测档位出结论」：任一档不合格 → 该项不合格；
/// 全部已测档位合格 → 该项合格；没有任何可算档位 → 无法判定。
class GbTierResult {
  const GbTierResult({
    required this.label,
    required this.valueText,
    this.unit = '',
    required this.limitText,
    required this.passed,
  });

  /// 档位名称，如 `上限值 10%（0.4 mg/L）`、`242 V 连续 3 次`、`第 2 台仪器，168 组`。
  final String label;

  /// 该档的指标值（已按展示精度格式化），如 `5.12`、`0.8055`。
  final String valueText;

  /// 指标单位：`%` / `mg/L` / `h`，无单位时为空串。
  final String unit;

  /// 该档对应的限值展示文本，如 `±5%`、`≤10%`；基准档（不单独判定）为 `基准`。
  final String limitText;

  /// 该档是否合格。
  final bool passed;

  /// 指标值 + 单位的合并展示。
  String get valueWithUnit => unit.isEmpty ? valueText : '$valueText $unit';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'label': label,
    'valueText': valueText,
    'unit': unit,
    'limitText': limitText,
    'passed': passed,
  };

  factory GbTierResult.fromJson(Map<String, dynamic> j) => GbTierResult(
    label: j['label'] as String? ?? '',
    valueText: j['valueText'] as String? ?? '',
    unit: j['unit'] as String? ?? '',
    limitText: j['limitText'] as String? ?? '',
    passed: j['passed'] as bool? ?? false,
  );
}

/// 单个验证项的完整计算结果（含逐步过程）。
class ItemReport {
  const ItemReport({
    required this.itemId,
    required this.itemName,
    required this.clause,
    required this.rangeKey,
    required this.conclusion,
    this.metricValue,
    this.metricDisplay = '',
    this.limitDisplay = '',
    this.ratio,
    this.steps = const <CalcStep>[],
    this.sampleIds = const <String>[],
    this.dataNote = '',
    this.subLabel = '',
    this.detailRows = const <List<String>>[],
    this.tiers = const <GbTierResult>[],
  });

  /// 验证项 id，如 `indication_error`。
  final String itemId;

  /// 中文名，如「示值误差」。
  final String itemName;

  /// 标准条款号，如 `5.5.1.1`。
  final String clause;

  /// 量程键：`basic` / `extended`。
  final String rangeKey;

  final GbConclusion conclusion;

  /// 判定用指标值（**未舍入**，判定不得使用展示值）。
  final double? metricValue;

  /// 指标值展示文本，如 `5.12`（配合 [unitOf] 或已含单位）。
  final String metricDisplay;

  /// 限值展示文本，如 `±5%`、`≤0.01 mg/L`。
  final String limitDisplay;

  /// 指标值 / 限值 的比值，用于 UI 预警着色；限值为 0 时为 null。
  final double? ratio;

  /// 逐步计算过程。
  final List<CalcStep> steps;

  /// 参与本次计算的样品 id（用于结果页标红与追溯）。
  final List<String> sampleIds;

  /// 数据量校验说明（正常时为空串）。
  final String dataNote;

  /// 子项标签，如记忆效应的 `80%→20%`。
  final String subLabel;

  /// 附加明细表（如示值误差的各浓度档结果）：首行为表头。
  final List<List<String>> detailRows;

  /// 逐档判定结果（每个浓度档 / 条件段 / 每台仪器一条）。
  ///
  /// 单档项目（定量下限、24 h 漂移、记忆效应、实际样品比对、维护周期、
  /// 数据有效率）只有 1 条；没有可细分档位时为空表。
  /// 该项总结论即「按已测档位聚合」：任一档不合格 → 不合格。
  final List<GbTierResult> tiers;

  bool get hasMetric => metricValue != null;

  /// 未通过判定的档位名称（供结果页/导出标红与文案汇总）。
  List<String> get failedTierLabels => <String>[
    for (final GbTierResult t in tiers)
      if (!t.passed) t.label,
  ];

  /// 仅用于「数据量不足时把结论降级为无法判定」，其余字段原样保留。
  ItemReport copyWith({GbConclusion? conclusion, String? dataNote}) =>
      ItemReport(
        itemId: itemId,
        itemName: itemName,
        clause: clause,
        rangeKey: rangeKey,
        conclusion: conclusion ?? this.conclusion,
        metricValue: metricValue,
        metricDisplay: metricDisplay,
        limitDisplay: limitDisplay,
        ratio: ratio,
        steps: steps,
        sampleIds: sampleIds,
        dataNote: dataNote ?? this.dataNote,
        subLabel: subLabel,
        detailRows: detailRows,
        tiers: tiers,
      );

  /// 指标值的展示单位。
  String get unit => _unitOf(this);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'itemId': itemId,
    'itemName': itemName,
    'clause': clause,
    'rangeKey': rangeKey,
    'conclusion': conclusion.name,
    'metricValue': metricValue,
    'metricDisplay': metricDisplay,
    'limitDisplay': limitDisplay,
    'ratio': ratio,
    'steps': steps.map((CalcStep s) => s.toJson()).toList(),
    'sampleIds': sampleIds,
    'dataNote': dataNote,
    'subLabel': subLabel,
    'detailRows': detailRows,
    'tiers': tiers.map((GbTierResult t) => t.toJson()).toList(),
  };

  factory ItemReport.fromJson(Map<String, dynamic> j) => ItemReport(
    itemId: j['itemId'] as String? ?? '',
    itemName: j['itemName'] as String? ?? '',
    clause: j['clause'] as String? ?? '',
    rangeKey: j['rangeKey'] as String? ?? '',
    conclusion: GbConclusion.values.firstWhere(
      (GbConclusion c) => c.name == j['conclusion'],
      orElse: () => GbConclusion.notApplicable,
    ),
    metricValue: (j['metricValue'] as num?)?.toDouble(),
    metricDisplay: j['metricDisplay'] as String? ?? '',
    limitDisplay: j['limitDisplay'] as String? ?? '',
    ratio: (j['ratio'] as num?)?.toDouble(),
    steps: (j['steps'] as List? ?? <dynamic>[])
        .map((dynamic e) => CalcStep.fromJson(e as Map<String, dynamic>))
        .toList(),
    sampleIds: List<String>.from(j['sampleIds'] as List? ?? <dynamic>[]),
    dataNote: j['dataNote'] as String? ?? '',
    subLabel: j['subLabel'] as String? ?? '',
    detailRows: (j['detailRows'] as List? ?? <dynamic>[])
        .map(
          (dynamic e) =>
              List<String>.from((e as List).map((dynamic v) => '$v')),
        )
        .toList(),
    tiers: (j['tiers'] as List? ?? <dynamic>[])
        .map((dynamic e) => GbTierResult.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  /// 指标单位：以 % 判定的项返回 `%`，否则按项返回 `mg/L` 或 `h`。
  static String _unitOf(ItemReport r) {
    if (r.limitDisplay.contains('%')) return '%';
    if (r.itemId == 'maintenance') return 'h';
    return 'mg/L';
  }
}

/// 一次计算会话：用户选定数据集 + 若干行 + 若干验证项，产出一组 [ItemReport]。
///
/// 会话自带 [samples] 快照，因此即使原数据集被修改，历史结果与 Excel 导出仍可复现。
class CalcSession {
  CalcSession({
    required this.id,
    required this.datasetId,
    required this.datasetName,
    required this.rangeKey,
    required this.createdAt,
    required this.samples,
    required this.reports,
    this.parameterId = 'tp',
    this.applicableItemCount = 0,
    this.note = '',
  });

  final String id;
  final String datasetId;
  final String datasetName;

  /// 量程：`basic` / `extended`。
  final String rangeKey;
  final DateTime createdAt;

  /// 参与计算的样品快照（按用户选择顺序）。
  final List<GbSample> samples;

  /// 各验证项结果。
  final List<ItemReport> reports;

  /// 本次量程下**标准要求应计算的验证项总数**（用于判断是否覆盖完整）。
  ///
  /// 0 表示未知（旧会话数据），此时不做覆盖度校验，行为与本字段引入前一致。
  final int applicableItemCount;

  /// 检测项目 id（`tp` / `nh3n` / `tn` / `cod`）。
  ///
  /// 目前只有总磷内置了标准条款，但会话必须记录用户当时选的是哪个项目，
  /// 否则历史记录与导出无法说明「这份报告验的是哪个参数」。
  final String parameterId;

  /// 尚未计算的验证项数量（[applicableItemCount] 为 0 时恒为 0）。
  int get missingItemCount => applicableItemCount > reports.length
      ? applicableItemCount - reports.length
      : 0;

  /// 备注（如实验室均值录入情况）。
  final String note;

  int get passCount =>
      reports.where((ItemReport r) => r.conclusion == GbConclusion.pass).length;

  int get failCount =>
      reports.where((ItemReport r) => r.conclusion == GbConclusion.fail).length;

  int get naCount => reports
      .where((ItemReport r) => r.conclusion == GbConclusion.notApplicable)
      .length;

  /// 总体结论。
  ///
  /// 合规要求：**任一验证项未判定（数据不足 / 缺参数）时不得出具「合格」**——
  /// 部分项目通过不足以证明仪器满足 HJ 103—2026 的全部要求。
  /// 同时**验证项没算全时也不得判合格**：13 项里只算 1 项并通过，
  /// 不构成「仪器合格」的结论。
  /// 因此顺序为：有不合格 → 不合格；有未判定 / 有未计算的项 → 无法判定；
  /// 全部通过 → 合格。
  GbConclusion get overall {
    if (failCount > 0) return GbConclusion.fail;
    if (naCount > 0 || missingItemCount > 0) {
      return GbConclusion.notApplicable;
    }
    return passCount > 0 ? GbConclusion.pass : GbConclusion.notApplicable;
  }

  /// 总体结论的补充说明（供结果页在结论旁展示原因）。
  String get overallHint {
    if (failCount > 0) {
      return '存在 $failCount 项不合格，仪器不满足标准要求。';
    }
    // 「无法判定」与「未计算」可能同时存在，合并成一句，避免读者只看到一半原因。
    final List<String> reasons = <String>[
      if (naCount > 0) '有 $naCount 项无法判定（数据不足或缺少必要参数）',
      if (missingItemCount > 0)
        '标准要求的 $applicableItemCount 项中尚有 $missingItemCount 项未计算'
            '（本次仅计算 ${reports.length} 项）',
    ];
    if (reasons.isNotEmpty) {
      return '${reasons.join('；')}，不能出具合格结论。';
    }
    if (passCount > 0) return '全部 ${reports.length} 项均满足标准要求。';
    return '尚未计算任何验证项。';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'datasetId': datasetId,
    'datasetName': datasetName,
    'rangeKey': rangeKey,
    'createdAt': createdAt.toIso8601String(),
    'samples': samples.map((GbSample s) => s.toJson()).toList(),
    'reports': reports.map((ItemReport r) => r.toJson()).toList(),
    'parameterId': parameterId,
    'applicableItemCount': applicableItemCount,
    'note': note,
  };

  factory CalcSession.fromJson(Map<String, dynamic> j) => CalcSession(
    id: j['id'] as String? ?? '',
    datasetId: j['datasetId'] as String? ?? '',
    datasetName: j['datasetName'] as String? ?? '',
    rangeKey: j['rangeKey'] as String? ?? 'basic',
    createdAt: j['createdAt'] == null
        ? DateTime.now()
        : (DateTime.tryParse(j['createdAt'] as String) ?? DateTime.now()),
    samples: (j['samples'] as List? ?? <dynamic>[])
        .map((dynamic e) => GbSample.fromJson(e as Map<String, dynamic>))
        .toList(),
    reports: (j['reports'] as List? ?? <dynamic>[])
        .map((dynamic e) => ItemReport.fromJson(e as Map<String, dynamic>))
        .toList(),
    parameterId: j['parameterId'] as String? ?? 'tp',
    applicableItemCount: (j['applicableItemCount'] as num?)?.toInt() ?? 0,
    note: j['note'] as String? ?? '',
  );
}
