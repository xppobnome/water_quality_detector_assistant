import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../models/gb_verify.dart';
import '../../models/standard.dart';
import '../../models/workspace.dart';
import '../../services/gb_calculator.dart';
import '../../services/standard_definitions.dart';
import 'calc_result_page.dart';

/// 国标验证「计算设置」页。
///
/// 一次设置 = 选数据行 → 定量程 → 选验证项 → 分段绑定 → 填必填参数，
/// 点击「开始计算」后逐项调用 [GbCalculator.compute] 生成 [ItemReport]，
/// 组成 [CalcSession] 推入 [CalcResultPage] 展示逐步计算过程。
///
/// 设计要点：
/// - **无 Provider / 无存储依赖**：只接收 [workspace] 与 [dataset]，便于复用与测试；
/// - 所有国标限值、公式、判定均由 [GbCalculator] 给出，本页不重算任何限值；
/// - 页首可切换检测项目（总磷 / 氨氮 / 总氮 / COD）。未内置标准条款的项目只保留
///   项目选择器 + 一张说明卡，其余设置卡片不渲染（不再整页替换，用户可随时切回）；
/// - 默认只勾选「当前量程下确有数据」的验证项，并提供全选/反选切换；
/// - 每个数据分段可单独勾选是否参与计算，只验证部分浓度档时结论会被标注
///   「无法判定（仅作记录）」；
/// - 同一批数据行可同时用于多个验证项，页面只做橙色强调，不阻断、不去重。
class CalcSetupPage extends StatefulWidget {
  const CalcSetupPage({
    super.key,
    required this.workspace,
    required this.dataset,
    this.onSessionSaved,
  });

  /// 所属工作空间（用于结果页展示与导出文件名）。
  final Workspace workspace;

  /// 待计算的数据集。
  final Dataset dataset;

  /// 计算完成后持久化会话的回调（由工作空间详情页注入，内部按 `session.id` 幂等）。
  ///
  /// 为 null 时（如独立调试进入）不落盘，结果页隐藏「保存到工作空间」。
  final Future<void> Function(CalcSession session)? onSessionSaved;

  @override
  State<CalcSetupPage> createState() => _CalcSetupPageState();
}

class _CalcSetupPageState extends State<CalcSetupPage> {
  /// 标准规定的最短维护间隔（h）。
  ///
  /// 直接取标准定义里的判定限（`limitFor('basic').absolute`），不在 UI 层
  /// 硬编码数值，保证与 [GbCalculator] 的判定口径同源。
  double get _maintenanceStandardHours {
    final VerificationItem? item = _itemOf('maintenance');
    return item?.limitFor('basic')?.absolute ?? 168;
  }

  /// 标准限值的展示文本（整数不带小数位）。
  String get _maintenanceLimitText {
    final double value = _maintenanceStandardHours;
    return value == value.roundToDouble()
        ? '${value.round()}'
        : value.toStringAsFixed(1);
  }

  /// 维护间隔录入非法（非数字/负数）时的统一红色提示文案。
  static const String _maintenanceErrorHint = '请输入 ≥ 0 的数字';

  /// 数据集可用样品（按行序，序号从 1 开始）；无法解析出数值的行已被剔除。
  late final List<GbSample> _allSamples;

  /// 被剔除的行（无法解析出数值），用于在摘要处展示警示与明细。
  late final List<_ExcludedRow> _excludedRows;

  /// 已选样品 id。
  Set<String> _selectedIds = <String>{};

  /// 当前量程键：`basic` / `extended`。
  String _rangeKey = 'basic';

  /// 已选验证项 id。
  final Set<String> _selectedItemIds = <String>{};

  /// 验证项 id → 分段绑定结果。
  final Map<String, List<GbSegment>> _segments = <String, List<GbSegment>>{};

  /// 用户手动绑定的分段：`'$itemId::$segmentKey'` → 行 id 集合。
  ///
  /// 有键即表示该段被手动绑定过（卡片上展示「已手动绑定」并提供「恢复自动」）；
  /// 值可以为空集合（用户明确把该段清空）。重建分段时会在自动结果之上覆盖。
  final Map<String, Set<String>> _manualBindings = <String, Set<String>>{};

  /// 用户显式设置的「该分段是否参与本次计算」：`'$itemId::$segmentKey'` → enabled。
  ///
  /// 默认值由数据条数自动推导（该段条数 ≥ 标准要求即参与，否则不参与），
  /// 但**用户的显式勾选/取消必须能覆盖默认值**，所以单独记忆：重建分段
  /// （换数据行、重新分组）时优先读这里，只有从未被手动操作过的段才用默认值。
  final Map<String, bool> _segmentEnabledOverride = <String, bool>{};

  /// 验证项「当前量程下有数据的分段数 / 应验证的分段数」缓存。
  ///
  /// 基于**自动分组**结果计算（不受用户当前勾选影响），因此每次重建分段时清空，
  /// 避免 build 里对每个验证项反复执行 [GbCalculator.autoBind]。
  final Map<String, List<int>> _coverageCache = <String, List<int>>{};

  /// 必填参数输入框。
  final TextEditingController _labMeanCtrl = TextEditingController();
  final TextEditingController _validCountCtrl = TextEditingController();
  final TextEditingController _totalCountCtrl = TextEditingController();

  /// 维护间隔输入框列表（每行一个间隔，至少保留 1 行）。
  ///
  /// 只有一个值时即「仅录入了一次间隔」；多个值时按 `T = min(间隔_i)` 取最短。
  final List<TextEditingController> _maintenanceCtrls =
      <TextEditingController>[TextEditingController()];

  /// 被删除的间隔控制器：延迟到本 State 销毁时统一 dispose，
  /// 避免 setState 后旧 TextField 仍在卸载过程中访问已释放的控制器。
  final List<TextEditingController> _retiredMaintenanceCtrls =
      <TextEditingController>[];

  /// 是否正在计算（防重复点击）。
  bool _computing = false;

  /// 当前检测项目 id（`tp` / `nh3n` / `tn` / `cod`），可在页面内切换。
  ///
  /// 初值取 [Workspace.parameter]；未知或缺省时回退 `tp`——总磷是目前唯一
  /// 完整内置国标条款的项目。
  String _parameterId = 'tp';

  /// 当前检测项目的标准（未内置的项目返回其占位 [Standard]）。
  Standard get _standard => standardById(_parameterId) ?? totalPhosphorusStandard;

  /// 当前项目是否已内置国标条款（未内置时只展示选择器 + 说明卡）。
  bool get _standardSupported => _standard.implemented && _items.isNotEmpty;

  /// 当前量程下的全部验证项（保持标准定义顺序）。
  List<VerificationItem> get _items => _standard.items;

  @override
  void initState() {
    super.initState();
    final _ParsedRows parsed = _parseRows(widget.dataset);
    _allSamples = parsed.samples;
    _excludedRows = parsed.excluded;
    // 检测项目：取工作空间设置，未知 id 时回退总磷。
    final String parameter = widget.workspace.parameter.trim();
    _parameterId = standardById(parameter) != null ? parameter : 'tp';
    // 默认全选：只勾选「能解析出数值 且 数据标识为空或 N」的行。
    _selectedIds = <String>{
      for (final GbSample sample in _allSamples)
        if (sample.isValid) sample.id,
    };
    _rangeKey = _suggestedRange();
    // 默认**不**全选验证项：只勾选当前量程下确有数据可算的项。
    _selectItemsWithData();
    _rebuildSegments();
    _prefillParameters();
  }

  @override
  void dispose() {
    _labMeanCtrl.dispose();
    for (final TextEditingController ctrl in _maintenanceCtrls) {
      ctrl.dispose();
    }
    for (final TextEditingController ctrl in _retiredMaintenanceCtrls) {
      ctrl.dispose();
    }
    _validCountCtrl.dispose();
    _totalCountCtrl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 数据准备

  /// 数据集行 → [GbSample]。
  ///
  /// 映射规则：
  /// - `value`：优先取结构化列 `values['value']`，取不到时回退解析原始单元格
  ///   `cells['数据结果']`；**两者都解析不出数值的行不进入候选列表**
  ///   （旧实现用 `m.values['value'] ?? 0` 兜底，会让导入失败的行以 0
  ///   参与均值与误差计算，得出虚假结论）；
  /// - `time = timestamp`；`flag = cells['数据标识'] ?? ''`；`cells` 原样保留；
  /// - `index`：保留该行在数据集中的原始序号（从 1 开始），便于与 Excel 对照。
  _ParsedRows _parseRows(Dataset dataset) {
    final List<GbSample> samples = <GbSample>[];
    final List<_ExcludedRow> excluded = <_ExcludedRow>[];
    for (int i = 0; i < dataset.measurements.length; i++) {
      final Measurement m = dataset.measurements[i];
      final int rowNo = i + 1;
      final double? value = _resolveValue(m);
      if (value == null) {
        excluded.add(
          _ExcludedRow(
            rowNo: rowNo,
            timeText: _timeTextOf(m),
            rawCell: (m.cells['数据结果'] ?? '').trim(),
          ),
        );
        continue;
      }
      samples.add(
        GbSample(
          id: m.id,
          value: value,
          time: m.timestamp,
          flag: m.cells['数据标识'] ?? '',
          index: rowNo,
          cells: m.cells,
        ),
      );
    }
    return _ParsedRows(samples: samples, excluded: excluded);
  }

  /// 解析一行的测定数值：先取结构化列，再回退解析原始文本单元格。
  ///
  /// 返回 null 表示该行无法参与任何定量计算。
  double? _resolveValue(Measurement m) {
    final double? direct = m.values['value'];
    if (direct != null && direct.isFinite) return direct;
    final String raw = (m.cells['数据结果'] ?? '').replaceAll(',', '').trim();
    if (raw.isEmpty) return null;
    final double? parsed = double.tryParse(raw);
    if (parsed == null || !parsed.isFinite) return null;
    return parsed;
  }

  /// 时间展示文本（yyyy-MM-dd HH:mm:ss）；无时间戳时退回 label。
  String _timeTextOf(Measurement m) {
    final DateTime? t = m.timestamp;
    if (t == null) return (m.label ?? '').trim();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// 按数据集顺序返回已选样品。
  List<GbSample> get _selectedSamples => <GbSample>[
    for (final GbSample sample in _allSamples)
      if (_selectedIds.contains(sample.id)) sample,
  ];

  /// 已选样品的算术均值（无数据返回 null）。
  double? get _selectedMean {
    final List<GbSample> samples = _selectedSamples;
    if (samples.isEmpty) return null;
    double sum = 0;
    for (final GbSample sample in samples) {
      sum += sample.value;
    }
    return sum / samples.length;
  }

  /// 依据已选数据均值自动建议量程。
  String _suggestedRange() {
    final double? mean = _selectedMean;
    if (mean == null) return 'basic';
    return GbCalculator.rangeOf(mean);
  }

  /// 默认勾选「当前量程下确有数据可算」的验证项。
  ///
  /// 数据不够时不再默认勾满全部验证项：没有可用数据的项算出来只会是
  /// 「无法判定」，反而干扰用户判断；这些项仍可由用户显式勾选（结论会标注
  /// 「无法判定」），因此不隐藏、只默认不选。
  void _selectItemsWithData() {
    _coverageCache.clear();
    _selectedItemIds.clear();
    for (final VerificationItem item in _items) {
      if (!item.appliesTo(_rangeKey)) continue;
      if (_itemHasUsableData(item.id)) _selectedItemIds.add(item.id);
    }
  }

  /// 当前量程下全部「适用」的验证项（含没有数据的，供全选使用）。
  List<VerificationItem> get _applicableItems => <VerificationItem>[
    for (final VerificationItem item in _items)
      if (item.appliesTo(_rangeKey)) item,
  ];

  /// 某个验证项在**自动分组**下的 [已够条数的分段数, 应验证分段数]。
  ///
  /// 只看「该段条数 ≥ 标准要求」，与用户当前把哪几段勾成「参与计算」无关，
  /// 因此不受分段操作顺序影响（这是 [_itemHasUsableData] 的数据来源）。
  List<int> _dataCoverageOf(String itemId) {
    final List<int>? cached = _coverageCache[itemId];
    if (cached != null) return cached;
    final List<GbSegmentSpec> specs = GbCalculator.segmentSpecs(
      itemId,
      _rangeKey,
    );
    int enough = 0;
    int total = 0;
    if (specs.isNotEmpty) {
      final List<GbSegment> auto = _autoSegmentsOf(itemId);
      bool procedureComplete = true;
      for (final GbSegmentSpec spec in specs) {
        final GbSegment? segment = _segmentIn(auto, spec.key);
        // discard 段是标准规定要测但不参与判定的前置段：不计入分母，
        // 但必须「有数据」——否则说明试验流程没走完（记忆效应缺了前置
        // 3 次 80%，那次 20% 的首次测定就不是「切换后」的测量了）。
        if (spec.discard) {
          if (segment == null || segment.samples.isEmpty) {
            procedureComplete = false;
          }
          continue;
        }
        total++;
        // 条数够 **且** 浓度对得上，才算该段有可用数据。
        // 只按条数判断会让「只有 0.8 mg/L 数据」的用户默认勾上定量下限
        // （target 0.02）和 24 h 低浓度漂移（target 0.1）。
        if (GbCalculator.segmentUsable(spec, segment)) enough++;
      }
      if (!procedureComplete) {
        final List<int> result = <int>[0, total];
        _coverageCache[itemId] = result;
        return result;
      }
    }
    final List<int> result = <int>[enough, total];
    _coverageCache[itemId] = result;
    return result;
  }

  /// 该验证项当前是否「有可用数据」可算（决定进入页面时是否默认勾选）。
  ///
  /// 常规项：至少有一个分段凑够了标准要求的条数。
  ///
  /// **特例 1 —— 数据有效率**：它的两个参数由 [_prefillParameters] 按
  /// 「已选行数 / 数据集总行数」预填，进入页面就能算出结果，属于「有数据」，
  /// 因此默认勾选；只有数据集一行都没有（总数为 0，引擎会直接判「无法判定」）
  /// 时才不默认勾选。最小维护周期必须用户手输维护间隔，仍保持默认不勾。
  ///
  /// **特例 2 —— 条件顺序项**（见 [_isConditionSequenceItem]）：条数够不代表
  /// 数据真的覆盖了各个条件，不自动勾选。
  bool _itemHasUsableData(String itemId) {
    if (itemId == 'data_availability') {
      // 与 _prefillParameters 的总数口径一致：按数据集原始测量行数判断。
      return widget.dataset.measurements.isNotEmpty;
    }
    if (_isConditionSequenceItem(itemId)) return false;
    return _dataCoverageOf(itemId)[0] > 0;
  }

  /// 该项是否为「按条件顺序绑定」的多段项（电压 / 浊度 / 环境温度 / 一致性偏差）。
  ///
  /// 两个特征之一命中即算：
  /// 1. 所有参与判定的分段**共用同一个目标浓度**，段与段的区别只是仪器所处条件
  ///    （220 V / 242 V / 198 V、无浊度 / 100 NTU / 300 NTU…）——6 条 0.8 mg/L 的
  ///    示值误差数据会被切成 3+3，让电压影响看上去「满足」；
  /// 2. 多段且**目标浓度全为空**（一致性偏差：3 台仪器各 168 组）——引擎只能按
  ///    行序切 168/168/168，用户只有一台仪器的 504 条数据时，会被当成「三台仪器」
  ///    算出毫无意义的 CD，比第 1 类更危险（它是 13 项判定之一，会直接进报告）。
  ///
  /// 这两类项的共同点：**段身份由行序推定，条数够不能证明数据真的覆盖了各个条件**。
  /// 因此它们不参与「有数据就默认勾选」，一律交给用户显式勾选。
  ///
  /// 真正按浓度档分组的项（示值误差 / 重复性 / 记忆效应…）各段目标浓度不同，
  /// 条数够就是真的有那么多该浓度的数据，可以默认勾选。
  bool _isConditionSequenceItem(String itemId) {
    final List<GbSegmentSpec> specs = GbCalculator.segmentSpecs(
      itemId,
      _rangeKey,
    );
    final List<GbSegmentSpec> judged = <GbSegmentSpec>[
      for (final GbSegmentSpec spec in specs)
        if (!spec.discard) spec,
    ];
    // 单段项没有「按条件分段」的概念（如定量下限、实际样品比对）。
    if (judged.length < 2) return false;
    final double? first = judged.first.target;
    // 目标浓度全为空的多段项（一致性偏差）同样是靠行序切分的，需手动选择。
    // 全标准里只有 conformity 命中这条（sample_compare 是单段，不受影响）。
    if (first == null) return true;
    for (final GbSegmentSpec spec in judged) {
      final double? target = spec.target;
      if (target == null || (target - first).abs() > 1e-9) return false;
    }
    return true;
  }

  /// 该验证项是否属于「纯人工录入参数型」（不需要绑定数据行）。
  bool _isManualEntryItem(String itemId) =>
      GbCalculator.segmentSpecs(itemId, _rangeKey).isEmpty;

  /// 全选 / 反选：当前量程下全部适用项一起选中或一起取消。
  void _setAllItemsSelected(bool selected) {
    setState(() {
      if (selected) {
        _selectedItemIds.addAll(<String>[
          for (final VerificationItem item in _applicableItems) item.id,
        ]);
      } else {
        _selectedItemIds.clear();
      }
      _rebuildSegments();
    });
  }

  /// 数据有效率默认值：有效个数 = 已选行数，总数 = 数据集总行数。
  void _prefillParameters() {
    if (_validCountCtrl.text.trim().isEmpty) {
      _validCountCtrl.text = '${_selectedIds.length}';
    }
    if (_totalCountCtrl.text.trim().isEmpty) {
      // 总数按数据集原始行数计（含无法解析数值的行，它们同样是"应获得"的数据）。
      _totalCountCtrl.text = '${widget.dataset.measurements.length}';
    }
  }

  /// 该验证项是否需要绑定数据行。
  bool _needsRows(String itemId) =>
      GbCalculator.segmentSpecs(itemId, _rangeKey).isNotEmpty;

  /// 重建所有已选验证项的分段绑定（自动分组 + 手动绑定覆盖 + 启用状态）。
  void _rebuildSegments() {
    _segments.clear();
    // 数据条数变了，「哪几段真的有数据」的缓存必须失效。
    _coverageCache.clear();
    final List<GbSample> samples = _selectedSamples;
    for (final VerificationItem item in _items) {
      if (!_selectedItemIds.contains(item.id)) continue;
      _segments[item.id] = _applyEnabled(
        item.id,
        _applyManual(item.id, _autoBind(item.id, samples)),
      );
    }
  }

  /// 自动分组：统一走 [GbCalculator.autoBind]，由引擎按项目类型选择策略
  /// （记忆效应用专用桶分类、浓度档类按就近归类、条件类顺序切分）。
  List<GbSegment> _autoBind(String itemId, List<GbSample> samples) {
    final List<GbSegmentSpec> specs = GbCalculator.segmentSpecs(
      itemId,
      _rangeKey,
    );
    if (specs.isEmpty) return const <GbSegment>[];
    return GbCalculator.autoBind(itemId, samples, specs);
  }

  /// 纯自动分组结果（不叠加手动绑定、不叠加启用记忆）。
  ///
  /// 用于回答「这批数据在自动归类下能凑出几段」，避免顺序依赖。
  List<GbSegment> _autoSegmentsOf(String itemId) =>
      _autoBind(itemId, _selectedSamples);

  /// 按「用户显式设置 → 数据条数默认值」的顺序确定每个分段是否参与计算。
  ///
  /// discard 段（标准要求测但不参与判定的前置段）恒为启用：它需要占位，
  /// 否则第 1 次与后 6 次的均值会错位。
  List<GbSegment> _applyEnabled(String itemId, List<GbSegment> segments) {
    if (segments.isEmpty) return segments;
    final List<GbSegmentSpec> specs = GbCalculator.segmentSpecs(
      itemId,
      _rangeKey,
    );
    final Map<String, GbSegmentSpec> specByKey = <String, GbSegmentSpec>{
      for (final GbSegmentSpec spec in specs) spec.key: spec,
    };
    return <GbSegment>[
      for (final GbSegment segment in segments)
        segment.copyWith(
          enabled: _enabledFor(itemId, segment, specByKey[segment.key]),
        ),
    ];
  }

  /// 单个分段的启用状态：显式设置优先，其次按条数是否达到标准要求。
  bool _enabledFor(String itemId, GbSegment segment, GbSegmentSpec? spec) {
    if (spec != null && spec.discard) return true;
    final bool? override = _segmentEnabledOverride[_bindKey(itemId, segment.key)];
    if (override != null) return override;
    if (spec == null) return true;
    return segment.samples.length >= spec.required;
  }

  /// 该验证项是否还留有「参与判定」的分段（discard 段不算）。
  bool _hasActiveVerdictSegment(String itemId) {
    final List<GbSegment> segs = _segments[itemId] ?? const <GbSegment>[];
    for (final GbSegmentSpec spec in GbCalculator.segmentSpecs(
      itemId,
      _rangeKey,
    )) {
      if (spec.discard) continue;
      final GbSegment? segment = _segmentIn(segs, spec.key);
      // 与引擎口径一致：分段缺失视为启用。
      if (segment == null || segment.enabled) return true;
    }
    return false;
  }

  /// 把用户手动绑定的行覆盖到自动结果之上。
  ///
  /// 只覆盖仍存在的分段；手动绑定的行若已被取消勾选则自动忽略，避免
  /// "已选 3 行却按 7 行计算"的错位。
  List<GbSegment> _applyManual(String itemId, List<GbSegment> auto) {
    if (_manualBindings.isEmpty) return auto;
    final Map<String, GbSample> byId = <String, GbSample>{
      for (final GbSample sample in _selectedSamples) sample.id: sample,
    };
    return <GbSegment>[
      for (final GbSegment segment in auto)
        if (_manualBindings.containsKey(_bindKey(itemId, segment.key)))
          segment.copyWith(
            samples: _sortSamples(<GbSample>[
              for (final String id
                  in _manualBindings[_bindKey(itemId, segment.key)]!)
                if (byId[id] != null) byId[id]!,
            ]),
          )
        else
          segment,
    ];
  }

  /// 手动绑定的存储键：验证项 + 分段。
  String _bindKey(String itemId, String segmentKey) => '$itemId::$segmentKey';

  /// 该段是否被用户手动绑定过。
  bool _isManual(String itemId, String segmentKey) =>
      _manualBindings.containsKey(_bindKey(itemId, segmentKey));

  /// 按时间（无时间则按原始行号）排序，保证"按时间/序号排序"的可预期性。
  List<GbSample> _sortSamples(List<GbSample> samples) {
    final List<GbSample> out = <GbSample>[...samples];
    out.sort((GbSample a, GbSample b) {
      final DateTime? ta = a.time;
      final DateTime? tb = b.time;
      if (ta != null && tb != null && ta != tb) return ta.compareTo(tb);
      return a.index.compareTo(b.index);
    });
    return out;
  }

  /// 取某验证项下某个分段键的结果（按 key 而非下标，兼容任意段数）。
  GbSegment? _segmentOf(String itemId, String segmentKey) =>
      _segmentIn(_segments[itemId] ?? const <GbSegment>[], segmentKey);

  /// 在一组分段里按 key 查某段。
  GbSegment? _segmentIn(List<GbSegment> segments, String segmentKey) {
    for (final GbSegment segment in segments) {
      if (segment.key == segmentKey) return segment;
    }
    return null;
  }

  /// 该验证项的分段数据量是否达到标准要求（discard 段不计入）。
  bool _dataSufficient(String itemId) => GbCalculator.dataSufficient(
    itemId,
    _rangeKey,
    _segments[itemId] ?? const <GbSegment>[],
  );

  /// 分段校验提示（已剔除 discard 段的条数问题）。
  ///
  /// discard 段是标准规定要测但不参与判定的前置段，条数不足只作提示，
  /// 不应进入「数据量与标准要求不一致」的阻断列表。
  String _segmentProblem(String itemId) {
    final List<GbSegment> segs = _segments[itemId] ?? const <GbSegment>[];
    final String raw = GbCalculator.checkSegments(itemId, _rangeKey, segs);
    if (raw.isEmpty) return '';
    final List<GbSegmentSpec> specs = GbCalculator.segmentSpecs(
      itemId,
      _rangeKey,
    );
    final List<String> discardLabels = <String>[
      for (final GbSegmentSpec spec in specs)
        if (spec.discard) spec.label,
    ];
    if (discardLabels.isEmpty) return raw;
    final List<String> kept = <String>[
      for (final String part in raw.split('；'))
        if (part.trim().isNotEmpty &&
            !discardLabels.any((String label) => part.startsWith(label)))
          part,
    ];
    return kept.join('；');
  }

  /// 已选验证项（按标准定义顺序）。
  List<VerificationItem> get _selectedItems => <VerificationItem>[
    for (final VerificationItem item in _items)
      if (_selectedItemIds.contains(item.id)) item,
  ];

  /// 按 id 取标准内的验证项（用于读取判定限，避免 UI 硬编码阈值）。
  VerificationItem? _itemOf(String itemId) {
    for (final VerificationItem item in _items) {
      if (item.id == itemId) return item;
    }
    return null;
  }

  // ---------------------------------------------------------------- 交互

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickRows() async {
    final Set<String>? picked = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) => _RowPickerSheet(
        samples: _allSamples,
        initial: _selectedIds,
        crossUsage: _rowUsageByOtherItems(''),
      ),
    );
    if (picked == null) return;
    setState(() {
      _selectedIds = picked;
      _rebuildSegments();
      _prefillParameters();
    });
  }

  void _onRangeChanged(Set<String> selection) {
    if (selection.isEmpty) return;
    final String next = selection.first;
    if (next == _rangeKey) return;
    setState(() {
      _rangeKey = next;
      // 量程变化后判定限、适用项与分段键都会变，分段启用记忆随之失效，
      // 重新按「有数据的项 + 够条数的分段」推导默认值。
      _segmentEnabledOverride.clear();
      _selectItemsWithData();
      _rebuildSegments();
    });
  }

  void _toggleItem(String itemId, bool selected) {
    setState(() {
      if (selected) {
        _selectedItemIds.add(itemId);
      } else {
        _selectedItemIds.remove(itemId);
      }
      _rebuildSegments();
    });
  }

  /// 勾选 / 取消某个分段是否参与本次计算（需求：数据不够的档可以先不算）。
  ///
  /// 用户的选择记入 [_segmentEnabledOverride]，后续重建分段时不会被默认值覆盖。
  /// 若因此把该项**全部**参与判定的分段都停用，则自动取消该验证项的选择，
  /// 避免出现「已勾选却什么都算不出来」的僵局（提示用户）。
  void _toggleSegmentEnabled(
    VerificationItem item,
    GbSegmentSpec spec,
    bool enabled,
  ) {
    if (spec.discard) return;
    setState(() {
      _segmentEnabledOverride[_bindKey(item.id, spec.key)] = enabled;
      final List<GbSegment> segs = _segments[item.id] ?? const <GbSegment>[];
      if (segs.isNotEmpty) {
        _segments[item.id] = <GbSegment>[
          for (final GbSegment segment in segs)
            segment.key == spec.key
                ? segment.copyWith(enabled: enabled)
                : segment,
        ];
      }
    });
    if (enabled || _hasActiveVerdictSegment(item.id)) return;
    setState(() {
      _selectedItemIds.remove(item.id);
      _segments.remove(item.id);
    });
    _snack('「${item.name}」已无参与计算的分段，已取消选择（重新勾选该项即可恢复）');
  }

  /// 行 → 被哪些**其他**验证项选中的名称集合。
  ///
  /// 只统计对方「参与计算」的分段；[excludeItemId] 用于排除当前正在看的项目
  /// （空串表示不排除，例如页面级的「选择数据行」弹窗）。
  Map<String, Set<String>> _rowUsageByOtherItems(String excludeItemId) {
    final Map<String, Set<String>> usage = <String, Set<String>>{};
    for (final VerificationItem item in _selectedItems) {
      if (item.id == excludeItemId) continue;
      for (final GbSegment segment
          in _segments[item.id] ?? const <GbSegment>[]) {
        if (!segment.enabled) continue;
        for (final GbSample sample in segment.samples) {
          usage.putIfAbsent(sample.id, () => <String>{}).add(item.name);
        }
      }
    }
    return usage;
  }

  void _rebindAll() {
    setState(() {
      // 「重新自动分组」是全局恢复出厂动作，一并清掉所有手动绑定。
      _manualBindings.clear();
      _rebuildSegments();
    });
    _snack('已按当前量程与数据行重新自动分组');
  }

  // ------------------------------------------------- 手动绑定（P1-1）

  /// 手动把数据行绑定到某个分段（复用行选择弹窗，限单选/多选到该段）。
  ///
  /// 自动分组在条件类项目（电压/浊度/温度）上只能顺序切分，行序错就会静默
  /// 错配；手动绑定是唯一的纠正手段，因此绑定后立即重算提示与按钮状态。
  Future<void> _pickSegmentRows(
    VerificationItem item,
    GbSegmentSpec spec,
  ) async {
    final List<GbSample> candidates = _selectedSamples;
    if (candidates.isEmpty) {
      _snack('请先在「数据行选择」中勾选参与计算的行');
      return;
    }
    final GbSegment? current = _segmentOf(item.id, spec.key);
    final Set<String>? picked = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) => _RowPickerSheet(
        samples: candidates,
        initial: <String>{
          for (final GbSample sample in current?.samples ?? const <GbSample>[])
            sample.id,
        },
        title: '绑定到「${spec.label}」',
        subtitle: '标准要求 ${spec.required} 条，仅可从已勾选的数据行中选择',
        // 排除本项自身：同一批行用在本项其它分段上是正常的，不必提示。
        crossUsage: _rowUsageByOtherItems(item.id),
      ),
    );
    if (picked == null) return;
    setState(() {
      _manualBindings[_bindKey(item.id, spec.key)] = <String>{...picked};
      _rebuildSegments();
    });
    _reportOverlap(item);
  }

  /// 恢复某段的自动分组：对该段重跑 [GbCalculator.autoBind] 并只覆盖该段。
  void _resetSegmentBinding(VerificationItem item, GbSegmentSpec spec) {
    setState(() {
      _manualBindings.remove(_bindKey(item.id, spec.key));
      final List<GbSegment> auto = _autoBind(item.id, _selectedSamples);
      GbSegment? restored;
      for (final GbSegment segment in auto) {
        if (segment.key == spec.key) restored = segment;
      }
      if (restored != null) {
        final List<GbSegment> current = <GbSegment>[
          ...?_segments[item.id],
        ];
        final List<GbSegment> next = <GbSegment>[
          for (final GbSegment segment in current)
            segment.key == spec.key ? restored : segment,
        ];
        _segments[item.id] = next;
      }
    });
    _snack('已恢复「${spec.label}」的自动分组');
  }

  /// 检出同一行被两个及以上分段同时使用，弹提示让用户确认（不做强制去重）。
  void _reportOverlap(VerificationItem item) {
    final List<GbSegment> segs = _segments[item.id] ?? const <GbSegment>[];
    final Map<String, List<String>> labelsById = <String, List<String>>{};
    final Map<String, GbSample> sampleById = <String, GbSample>{};
    for (final GbSegment segment in segs) {
      for (final GbSample sample in segment.samples) {
        labelsById
            .putIfAbsent(sample.id, () => <String>[])
            .add(segment.label);
        sampleById[sample.id] = sample;
      }
    }
    final List<String> conflicts = <String>[];
    labelsById.forEach((String id, List<String> labels) {
      if (labels.length < 2) return;
      final GbSample? sample = sampleById[id];
      if (sample == null) return;
      final String where = labels
          .map((String label) => '「$label」')
          .join('和');
      conflicts.add('第 ${sample.index} 行同时出现在$where，请确认');
    });
    if (conflicts.isEmpty) return;
    _showNotice(
      title: '数据行重复绑定',
      lines: conflicts,
      hint: '同一行被多个分段使用会让各段统计互相干扰；如非有意，请重新绑定其中一段。',
    );
  }

  /// 通用提示弹窗（只读，单按钮）。
  Future<void> _showNotice({
    required String title,
    required List<String> lines,
    String? hint,
  }) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final String line in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: kWarningColor,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          line,
                          style: const TextStyle(fontSize: 12.5, height: 1.45),
                        ),
                      ),
                    ],
                  ),
                ),
              if (hint != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  hint,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: kNeutralGrey,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 计算

  Future<void> _startCalculation() async {
    if (_computing) return;
    final List<VerificationItem> items = _selectedItems;
    if (items.isEmpty) {
      _snack('请至少选择一个验证项');
      return;
    }

    final List<GbSample> samples = _selectedSamples;
    final bool needsRows = items.any(
      (VerificationItem item) => _needsRows(item.id),
    );
    if (needsRows && !GbCalculator.enoughToCompute(samples)) {
      _snack('至少需要 2 条数据');
      return;
    }

    // 分段数据量校验：列出问题，允许用户强行计算（discard 段不计入）。
    final List<String> problems = <String>[];
    for (final VerificationItem item in items) {
      final String problem = _segmentProblem(item.id);
      if (problem.isNotEmpty) problems.add('${item.name}：$problem');
    }
    if (problems.isNotEmpty) {
      final bool? proceed = await _confirmProblems(problems);
      if (proceed != true) return;
    }

    // 参数校验：维护间隔填了非数字/负数时禁止计算。
    final String? maintenanceError = _maintenanceError;
    if (maintenanceError != null) {
      _snack(maintenanceError);
      return;
    }

    final double? labMean = _parseDouble(_labMeanCtrl.text);
    // 「最小维护周期」取所有录入间隔中的最小值（T = min(维护间隔_i)）。
    final double? maintenanceHours = _minMaintenanceInterval;
    final int? validCount = _parseInt(_validCountCtrl.text);
    final int? totalCount = _parseInt(_totalCountCtrl.text);

    setState(() => _computing = true);
    try {
      final List<ItemReport> reports = <ItemReport>[
        for (final VerificationItem item in items)
          GbCalculator.compute(
            item: item,
            rangeKey: _rangeKey,
            segments: _segments[item.id] ?? const <GbSegment>[],
            labMean: item.id == 'sample_compare' ? labMean : null,
            maintenanceHours: item.id == 'maintenance'
                ? maintenanceHours
                : null,
            validCount: item.id == 'data_availability' ? validCount : null,
            totalCount: item.id == 'data_availability' ? totalCount : null,
          ),
      ];

      final CalcSession session = CalcSession(
        id: const Uuid().v4(),
        datasetId: widget.dataset.id,
        datasetName: widget.dataset.name,
        rangeKey: _rangeKey,
        createdAt: DateTime.now(),
        samples: samples,
        reports: reports,
        // 记录本次验的是哪个检测项目（导出《标准依据》与历史记录都依赖它）。
        parameterId: _parameterId,
        // 记录本量程下「标准要求应算几项」，供总体结论判断是否算全了。
        applicableItemCount: _items
            .where((VerificationItem i) => i.appliesTo(_rangeKey))
            .length,
        note: _buildNote(labMean, maintenanceHours, validCount, totalCount),
      );

      if (!mounted) return;
      // 先落盘（幂等，按 session.id 去重），保证用户即使不点保存也有历史记录。
      await widget.onSessionSaved?.call(session);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CalcResultPage(
            workspace: widget.workspace,
            session: session,
            onSave: widget.onSessionSaved,
          ),
        ),
      );
    } catch (e) {
      _snack('计算失败：$e');
    } finally {
      if (mounted) setState(() => _computing = false);
    }
  }

  /// 录入参数说明（写入 [CalcSession.note]，随结果持久化与导出）。
  String _buildNote(
    double? labMean,
    double? maintenanceHours,
    int? validCount,
    int? totalCount,
  ) {
    final List<String> parts = <String>[];
    if (_selectedItemIds.contains('sample_compare') && labMean != null) {
      parts.add('实验室均值 r_R = ${labMean.toStringAsFixed(3)} mg/L');
    }
    if (_selectedItemIds.contains('maintenance') && maintenanceHours != null) {
      parts.add(
        '维护间隔 ${_maintenanceIntervals.length} 个，'
        '最短 ${maintenanceHours.toStringAsFixed(1)} h',
      );
    }
    if (_selectedItemIds.contains('data_availability') &&
        validCount != null &&
        totalCount != null) {
      parts.add('有效数据 $validCount / 应获得 $totalCount');
    }
    return parts.isEmpty ? '' : '录入参数：${parts.join('；')}';
  }

  Future<bool?> _confirmProblems(List<String> problems) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('数据量与标准要求不一致'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('以下验证项的数据条数与标准试验方法要求不匹配：'),
              const SizedBox(height: 10),
              for (final String problem in problems)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Icon(
                        Icons.error_outline,
                        size: 16,
                        color: kWarningColor,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          problem,
                          style: const TextStyle(fontSize: 12.5, height: 1.45),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 6),
              const Text(
                '继续计算时，引擎会按标准规定的条数截断使用（不足时按实际条数计算），'
                '结论仅供参考。',
                style: TextStyle(
                  fontSize: 12,
                  color: kNeutralGrey,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('返回调整'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('仍要计算'),
          ),
        ],
      ),
    );
  }

  double? _parseDouble(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return null;
    return double.tryParse(text);
  }

  int? _parseInt(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text);
  }

  // ---------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final bool supported = _standardSupported;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('计算设置'),
            Text(
              '${gbItemLabelOfId(_parameterId, fallback: _parameterId)} · '
              '数据集：${widget.dataset.name} · 已选 ${_selectedIds.length} 行',
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: <Widget>[
          // 第一步永远是「算哪个检测项目」。
          _buildParameterSelectorCard(),
          if (!supported) ...<Widget>[
            const SizedBox(height: 12),
            _buildUnsupportedItemCard(),
          ] else ...<Widget>[
            const SizedBox(height: 12),
            _buildRowPickerCard(),
            const SizedBox(height: 12),
            _buildRangeCard(),
            const SizedBox(height: 12),
            _buildItemCard(),
            const SizedBox(height: 12),
            _buildSegmentCard(),
            if (_needsParameterCard) ...<Widget>[
              const SizedBox(height: 12),
              _buildParameterCard(),
            ],
          ],
          const SizedBox(height: 4),
        ],
      ),
      bottomNavigationBar: supported ? _buildBottomBar() : null,
    );
  }

  // ---------------------------------------------------------------- 卡片：检测项目

  /// 「检测项目」选择卡：先定项目，再谈数据与验证项。
  ///
  /// 未内置标准条款的项目不会把整页替换掉——用户必须能在这里直接切回总磷，
  /// 而不是退回工作空间详情页改参数。
  Widget _buildParameterSelectorCard() {
    return _sectionCard(
      icon: Icons.science_outlined,
      title: '检测项目',
      trailing: _miniTagChip(
        _standard.implemented ? '国标条款已内置' : '国标条款未内置',
        _standard.implemented ? kSuccessColor : kNeutralGrey,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '先选择要计算的检测项目，再进入数据行与验证项设置；'
            '不同项目的标准条款、检测范围与验证项各不相同。',
            style: TextStyle(fontSize: 11.5, color: kNeutralGrey, height: 1.5),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final GbItemOption option in gbItemOptions)
                _buildParameterChip(option),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildParameterChip(GbItemOption option) {
    final bool implemented = standardById(option.id)?.implemented == true;
    final bool selected = _parameterId == option.id;
    return ChoiceChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            option.label,
            style: TextStyle(
              fontSize: 12.5,
              // 未内置的项目保留可选（用户仍可查看说明），但用灰色弱化。
              color: implemented ? null : kNeutralGrey,
              fontWeight: selected ? FontWeight.w600 : null,
            ),
          ),
          if (!implemented) ...<Widget>[
            const SizedBox(width: 4),
            _miniTagChip('未内置', kNeutralGrey),
          ],
        ],
      ),
      selected: selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: (bool _) => _switchParameter(option.id),
    );
  }

  /// 切换检测项目：重新走一遍初始化（量程 / 验证项 / 分段 / 启用记忆全部重来）。
  void _switchParameter(String parameterId) {
    if (parameterId == _parameterId) return;
    setState(() {
      _parameterId = parameterId;
      _rangeKey = _suggestedRange();
      _selectedItemIds.clear();
      _segments.clear();
      _manualBindings.clear();
      _segmentEnabledOverride.clear();
      _coverageCache.clear();
      _selectItemsWithData();
      _rebuildSegments();
    });
  }

  /// 未内置标准条款时的内嵌说明卡（保留项目选择器，可一键切回总磷）。
  Widget _buildUnsupportedItemCard() {
    final String label = gbItemLabelOfId(_parameterId, fallback: _parameterId);
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.info_outline, color: kWarningColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '当前检测项目（$label）的标准条款尚未内置',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              '国标验证计算目前仅支持「总磷（HJ 103—2026）」。'
              '本项目仍可使用数据管理与 Excel 导出功能，但暂不出具合格判定。',
              style: TextStyle(fontSize: 13, height: 1.6),
            ),
            const SizedBox(height: 8),
            const Text(
              '数据集与检测范围设置已隐藏，避免出现「能点开始计算但算不出结果」的误解。',
              style: TextStyle(
                fontSize: 11.5,
                color: kNeutralGrey,
                height: 1.5,
              ),
            ),
            if (_parameterId != 'tp') ...<Widget>[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: () => _switchParameter('tp'),
                  icon: const Icon(Icons.undo, size: 18),
                  label: const Text('切回总磷'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 卡片：数据行选择

  Widget _buildRowPickerCard() {
    final int rawTotal = widget.dataset.measurements.length;
    final int total = _allSamples.length;
    final int selected = _selectedIds.length;
    final int invalid = _allSamples.where((GbSample s) => !s.isValid).length;
    final int excluded = _excludedRows.length;
    final double? mean = _selectedMean;

    return _sectionCard(
      icon: Icons.table_rows_outlined,
      title: '数据行选择',
      trailing: Text(
        '已选 $selected / $total 行',
        style: const TextStyle(fontSize: 12, color: kNeutralGrey),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (rawTotal == 0)
            const Text(
              '该数据集暂无测量数据，请先在工作空间详情页导入或录入数据。',
              style: TextStyle(fontSize: 13, color: kErrorColor, height: 1.5),
            )
          else ...<Widget>[
            Row(
              children: <Widget>[
                _kv('总行数', '$rawTotal'),
                const SizedBox(width: 18),
                _kv('已选', '$selected'),
                const SizedBox(width: 18),
                _kv('异常标识', '$invalid'),
              ],
            ),
            if (excluded > 0) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.report_problem_outlined,
                    size: 15,
                    color: kWarningColor,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '已排除 $excluded 行无法解析出数值的行',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: kWarningColor,
                        height: 1.5,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _showExcludedRows,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      textStyle: const TextStyle(fontSize: 11.5),
                    ),
                    child: const Text('查看'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    mean == null
                        ? '尚未选择数据行'
                        : '已选数据均值 ${mean.toStringAsFixed(3)} mg/L',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _pickRows,
                  icon: const Icon(Icons.checklist_rtl, size: 18),
                  label: const Text('选择数据行'),
                ),
              ],
            ),
            if (selected == 0 && total > 0)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '当前没有默认可选行（数据标识均异常），请点击「选择数据行」手动勾选。',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: kErrorColor,
                    height: 1.5,
                  ),
                ),
              ),
            if (invalid > 0)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '数据标识为空或为 N 视为有效数据；其他标识（如 D、M、X）按标准不参与计算，默认不勾选。',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: kNeutralGrey,
                    height: 1.5,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 被排除行的明细：原始序号 + 时间 + 原始单元格文本。
  Future<void> _showExcludedRows() {
    return showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('已排除 ${_excludedRows.length} 行'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _excludedRows.length,
            itemBuilder: (BuildContext c, int i) {
              final _ExcludedRow row = _excludedRows[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '第 ${row.rowNo} 行'
                      '${row.timeText.isEmpty ? '' : ' · ${row.timeText}'}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '原始单元格：'
                      '${row.rawCell.isEmpty ? '（空）' : row.rawCell}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: kNeutralGrey,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 卡片：量程

  Widget _buildRangeCard() {
    final double? mean = _selectedMean;
    final String suggested = _suggestedRange();
    final bool suggestDiffers = mean != null && suggested != _rangeKey;

    return _sectionCard(
      icon: Icons.straighten_outlined,
      title: '检测范围',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(
                  value: 'basic',
                  label: Text('基本 0.02~4 mg/L'),
                  icon: Icon(Icons.linear_scale, size: 16),
                ),
                ButtonSegment<String>(
                  value: 'extended',
                  label: Text('扩展 4~50 mg/L'),
                  icon: Icon(Icons.stacked_line_chart, size: 16),
                ),
              ],
              selected: <String>{_rangeKey},
              showSelectedIcon: false,
              onSelectionChanged: _onRangeChanged,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            GbCalculator.rangeLabel(_rangeKey),
            style: const TextStyle(fontSize: 12, color: kNeutralGrey),
          ),
          if (suggestDiffers) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                const Icon(
                  Icons.tips_and_updates_outlined,
                  size: 16,
                  color: kWarningColor,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '已选数据均值 ${mean.toStringAsFixed(3)} mg/L，'
                    '建议使用「${GbCalculator.rangeLabel(suggested)}」。',
                    style: const TextStyle(fontSize: 12, color: kWarningColor),
                  ),
                ),
                TextButton(
                  onPressed: () => _onRangeChanged(<String>{suggested}),
                  child: const Text('采用建议'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 卡片：验证项

  Widget _buildItemCard() {
    final Map<String, List<VerificationItem>> grouped =
        <String, List<VerificationItem>>{};
    final List<VerificationItem> applicable = _applicableItems;
    for (final VerificationItem item in applicable) {
      grouped.putIfAbsent(item.group, () => <VerificationItem>[]).add(item);
    }
    final List<VerificationItem> chosen = _selectedItems;
    final int chosenApplicable = applicable
        .where((VerificationItem item) => _selectedItemIds.contains(item.id))
        .length;
    final bool allSelected =
        applicable.isNotEmpty && chosenApplicable == applicable.length;

    return _sectionCard(
      icon: Icons.fact_check_outlined,
      title: '验证项',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '已选 $chosenApplicable/${applicable.length}',
            style: const TextStyle(fontSize: 12, color: kNeutralGrey),
          ),
          TextButton.icon(
            // 数量少于可选数时提供「全选」，已全选时同一位置变成「反选」。
            onPressed: applicable.isEmpty
                ? null
                : () => _setAllItemsSelected(!allSelected),
            icon: Icon(
              allSelected ? Icons.deselect : Icons.checklist,
              size: 16,
            ),
            label: Text(allSelected ? '反选' : '全选'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.only(left: 6, right: 2),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '按 ${_standard.code} 表${_rangeKey == 'extended' ? '2' : '1'} 的'
            '${GbCalculator.rangeLabel(_rangeKey)}判定限执行，'
            '不适用于当前量程的项目已隐藏。'
            '默认只勾选有数据的项，缺数据的项可手动勾选（结论为「无法判定」）。',
            style: const TextStyle(
              fontSize: 11.5,
              color: kNeutralGrey,
              height: 1.5,
            ),
          ),
          for (final String group in gbGroupLabels.keys)
            if (grouped[group] != null &&
                grouped[group]!.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                gbGroupLabels[group] ?? group,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: <Widget>[
                  for (final VerificationItem item in grouped[group]!)
                    _buildItemChip(item),
                ],
              ),
            ],
          if (chosen.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                '尚未选择验证项，请至少选择一项后再开始计算。',
                style: TextStyle(fontSize: 12, color: kErrorColor),
              ),
            )
          else ...<Widget>[
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 10),
            for (final VerificationItem item in chosen)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${item.name} · 第 ${item.clause} 条',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.methodNote,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: kNeutralGrey,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 单个验证项 Chip：未选中且数据不足时附带灰色小字说明原因。
  ///
  /// 「有部分数据」用自动分组结果统计（`已够条数的段数 / 应验证段数`），
  /// 因此不会因为用户后来手动改绑而抖动。
  Widget _buildItemChip(VerificationItem item) {
    final bool selected = _selectedItemIds.contains(item.id);
    final bool manualEntry = _isManualEntryItem(item.id);
    final List<int> coverage = _dataCoverageOf(item.id);
    // 用 _itemHasUsableData（含数据有效率 / 条件顺序项的特例），避免误挂提示。
    final bool hasData = _itemHasUsableData(item.id);
    final bool partial = coverage[1] > 0 && coverage[0] < coverage[1];
    // 条件顺序项（电压/浊度/温度）条数可能看起来够，但顺序绑定的数据无法证明
    // 真的覆盖了各个条件，所以默认不勾选，这里明确告知用户「需手动选择」。
    final bool needsManualPick =
        !hasData && !manualEntry && _isConditionSequenceItem(item.id);

    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(item.name, style: const TextStyle(fontSize: 12)),
          if (!selected && !manualEntry && !hasData && !needsManualPick) ...<Widget>[
            const SizedBox(width: 4),
            _miniTagChip(
              partial ? '仅 ${coverage[0]}/${coverage[1]} 个分段有数据' : '无可用数据',
              kNeutralGrey,
            ),
          ] else if (!selected && needsManualPick) ...<Widget>[
            const SizedBox(width: 4),
            _miniTagChip('需手动选择', kNeutralGrey),
          ],
        ],
      ),
      selected: selected,
      onSelected: (bool v) => _toggleItem(item.id, v),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  // ---------------------------------------------------------------- 卡片：分段绑定

  Widget _buildSegmentCard() {
    final List<VerificationItem> chosen = _selectedItems;
    final List<VerificationItem> withSegments = chosen
        .where((VerificationItem item) => _needsRows(item.id))
        .toList();

    return _sectionCard(
      icon: Icons.call_split,
      title: '数据分段绑定',
      trailing: withSegments.isEmpty
          ? null
          : TextButton.icon(
              onPressed: _rebindAll,
              icon: const Icon(Icons.refresh, size: 17),
              label: const Text('重新自动分组'),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (withSegments.isEmpty)
            Text(
              // 「反选」后一项都没选时，不能笼统说「都是人工录入型」。
              chosen.isEmpty
                  ? '尚未选择验证项，暂无需要绑定分段的项目。'
                  : '所选验证项均为人工录入参数型，无需绑定数据行。',
              style: const TextStyle(fontSize: 12.5, color: kNeutralGrey),
            )
          else ...<Widget>[
            Text(
              '按「${GbCalculator.rangeLabel(_rangeKey)}」自动分组；'
              '每段左侧「参与计算」可单独勾选——只有部分浓度档数据时，'
              '只需勾选有数据的那几段。'
              '缺口为红色、超出为橙色（超出部分计算时会被截断）。'
              '行序与试验顺序不一致时，可用每段的「重新选择该段数据」手动纠正。',
              style: const TextStyle(
                fontSize: 11.5,
                color: kNeutralGrey,
                height: 1.5,
              ),
            ),
            // 顺序敏感的项目额外给出标准试验顺序，避免用户按错误顺序导入后
            // 自动分组把行分到看似合理但实为错位的段里。
            if (withSegments.any(
              (VerificationItem i) =>
                  i.id == 'memory_80to20' ||
                  i.id == 'memory_20to80' ||
                  i.id == 'conformity',
            ))
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '· 记忆效应：请按「3 次 80% → 7 次 20% → 7 次 80%」的顺序导入；'
                  '前置 3 次 80% 不参与判定。\n'
                  '· 一致性偏差：请确认 3 台仪器的数据是连续的三段、每段 168 条。',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: kWarningColor,
                    height: 1.5,
                  ),
                ),
              ),
            for (final VerificationItem item in withSegments) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                item.name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              // 跨验证项的行复用提示：只强调，不阻断。
              _buildSegmentRows(item, _rowUsageByOtherItems(item.id)),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildSegmentRows(
    VerificationItem item,
    Map<String, Set<String>> otherUsage,
  ) {
    final List<GbSegmentSpec> specs = GbCalculator.segmentSpecs(
      item.id,
      _rangeKey,
    );
    if (specs.isEmpty) {
      return const Text(
        '该验证项不需要分段绑定。',
        style: TextStyle(fontSize: 12, color: kNeutralGrey),
      );
    }
    final List<GbSegment> segs = _segments[item.id] ?? const <GbSegment>[];
    final bool sufficient = _dataSufficient(item.id);
    final String problem = _segmentProblem(item.id);
    // 已启用段数 / 应验证段数（discard 段不计），用于「仅验证 x/y 段」提示。
    final List<int> coverage = GbCalculator.coverageCounts(
      item.id,
      _rangeKey,
      segs,
    );
    final bool noneActive = coverage[0] == 0;
    final bool partial = coverage[1] > 0 && coverage[0] < coverage[1];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final GbSegmentSpec spec in specs)
          _buildSegmentRow(item, spec, otherUsage),
        if (noneActive)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.check_box_outline_blank, size: 15, color: kNeutralGrey),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '未勾选任何参与计算的分段，本项将判定为「无法判定」。'
                    '请至少勾选一段有数据的分段。',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: kNeutralGrey,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          )
        else if (!sufficient)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.report_gmailerrorred, size: 15, color: kErrorColor),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '数据量未达到标准要求，本项结论将为「无法判定」。'
                    '请补充数据、勾选其它分段或重新绑定分段。',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: kErrorColor,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (partial && !noneActive)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(Icons.rule, size: 15, color: kWarningColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '本次仅验证 ${coverage[0]}/${coverage[1]} 个分段，'
                    '该项结论将标注「无法判定（仅作记录）」。',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: kWarningColor,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (problem.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(
                  Icons.info_outline,
                  size: 15,
                  color: kWarningColor,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    problem,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: kWarningColor,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 单个分段卡片：启用开关 + 条数状态 + 手动绑定入口（+ 恢复自动）。
  Widget _buildSegmentRow(
    VerificationItem item,
    GbSegmentSpec spec,
    Map<String, Set<String>> otherUsage,
  ) {
    final GbSegment? segment = _segmentOf(item.id, spec.key);
    final List<GbSample> samples = segment?.samples ?? const <GbSample>[];
    final int current = samples.length;
    final int required = spec.required;
    final bool manual = _isManual(item.id, spec.key);
    final bool discard = spec.discard;
    // discard 段恒为启用：标准要求测但不参与判定，必须占位。
    final bool enabled = discard ? true : (segment?.enabled ?? false);
    final bool missing = current < required;
    final bool extra = current > required;

    final String status;
    final Color statusColor;
    if (discard) {
      status = missing ? '前置段缺少 ${required - current} 条' : '前置段已齐';
      statusColor = kNeutralGrey;
    } else if (!enabled) {
      // 停用段不参与计算，条数缺口不再是「错误」，改为中性说明。
      status = '未勾选，不参与计算';
      statusColor = kNeutralGrey;
    } else if (missing) {
      status = '缺少 ${required - current} 条';
      statusColor = kErrorColor;
    } else if (extra && spec.key != 'series') {
      status = '多出 ${current - required} 条，计算仅用前 $required 条';
      statusColor = kWarningColor;
    } else {
      status = '已满足';
      statusColor = kSuccessColor;
    }

    // 停用段整卡置灰，与「前置不参与判定段」同一套视觉。
    final Color background = discard || !enabled
        ? const Color(0xFFF1F3F6)
        : const Color(0xFFF7F9FC);
    final String reuseNotice = enabled
        ? _reuseNoticeOf(samples, otherUsage)
        : '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: manual
                ? kPrimaryColor.withValues(alpha: 0.45)
                : const Color(0xFFE3E8EF),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Tooltip(
              message: discard
                  ? '前置段固定占位，不参与判定'
                  : '勾选后本段参与本次计算；只有部分浓度档数据时可只勾有数据的段',
              child: SizedBox(
                width: 48,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(
                      height: 32,
                      child: Checkbox(
                        value: enabled,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: discard
                            ? null
                            : (bool? v) =>
                                  _toggleSegmentEnabled(item, spec, v == true),
                      ),
                    ),
                    Text(
                      '参与计算',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 9,
                        height: 1.2,
                        color: kNeutralGrey,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          spec.label,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: discard || !enabled ? kNeutralGrey : null,
                          ),
                        ),
                      ),
                      if (manual) ...<Widget>[
                        const SizedBox(width: 6),
                        _miniTagChip('已手动绑定', kPrimaryColor),
                      ],
                      if (!enabled && !discard) ...<Widget>[
                        const SizedBox(width: 6),
                        _miniTagChip('本段不算', kNeutralGrey),
                      ],
                      if (discard) ...<Widget>[
                        const SizedBox(width: 6),
                        _miniTagChip('不参与判定', kNeutralGrey),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '需要 $required 条 · 当前 $current 条'
                    '${spec.target == null ? '' : ' · 目标浓度 ${GbCalculator.mgL(spec.target!)}'}',
                    style: const TextStyle(fontSize: 11, color: kNeutralGrey),
                  ),
                  if (current > 0) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      '第 ${_rowNumbersOf(samples)} 行',
                      style: const TextStyle(fontSize: 11, color: kNeutralGrey),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (reuseNotice.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(
                      reuseNotice,
                      style: const TextStyle(
                        fontSize: 11,
                        color: kWarningColor,
                        height: 1.45,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          status,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: statusColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _pickSegmentRows(item, spec),
                        icon: const Icon(Icons.playlist_add_check, size: 16),
                        label: const Text('重新选择该段数据'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          textStyle: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                      if (manual)
                        TextButton(
                          onPressed: () => _resetSegmentBinding(item, spec),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            textStyle: const TextStyle(fontSize: 11.5),
                          ),
                          child: const Text('恢复自动'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 跨验证项的行复用提示文案（只强调，不阻断、不去重）。
  ///
  /// 例：`⚠ 第 4、5、6 行已被「示值误差」选定；同一批数据可同时用于多项验证，
  /// 确认无误即可继续。`
  String _reuseNoticeOf(
    List<GbSample> samples,
    Map<String, Set<String>> otherUsage,
  ) {
    if (samples.isEmpty || otherUsage.isEmpty) return '';
    final List<GbSample> reused = <GbSample>[
      for (final GbSample sample in samples)
        if (otherUsage.containsKey(sample.id)) sample,
    ];
    if (reused.isEmpty) return '';
    final Set<String> namesInRows = <String>{};
    for (final GbSample sample in reused) {
      namesInRows.addAll(otherUsage[sample.id] ?? const <String>{});
    }
    // 按已选验证项顺序拼接，避免 Set 迭代顺序导致文案抖动。
    final List<String> names = <String>[
      for (final VerificationItem item in _selectedItems)
        if (namesInRows.contains(item.name)) item.name,
    ];
    if (names.isEmpty) return '';
    const int limit = 8;
    final List<String> nums = <String>[
      for (int i = 0; i < reused.length && i < limit; i++) '${reused[i].index}',
    ];
    final String rowText = reused.length > limit
        ? '第 ${nums.join('、')} 等 ${reused.length} 行'
        : '第 ${nums.join('、')} 行';
    final String who = names.map((String name) => '「$name」').join();
    return '⚠ $rowText已被$who选定；同一批数据可同时用于多项验证，确认无误即可继续。';
  }

  /// 该段使用到的原始行号（逗号分隔，最多展示 12 个）。
  String _rowNumbersOf(List<GbSample> samples) {
    const int limit = 12;
    final List<String> nums = <String>[
      for (int i = 0; i < samples.length && i < limit; i++)
        '${samples[i].index}',
    ];
    final String text = nums.join('、');
    return samples.length > limit ? '$text …' : text;
  }

  // ---------------------------------------------------------------- 卡片：必填参数

  bool get _needsSampleCompare => _selectedItemIds.contains('sample_compare');

  bool get _needsMaintenance => _selectedItemIds.contains('maintenance');

  bool get _needsDataAvailability =>
      _selectedItemIds.contains('data_availability');

  bool get _needsParameterCard =>
      _needsSampleCompare || _needsMaintenance || _needsDataAvailability;

  /// 已录入的维护间隔（忽略空输入框）。
  ///
  /// 引擎侧公式为 `T = min(维护间隔_i)`，因此这里收集全部有效间隔，
  /// 计算时取最小值，而不是把用户录入的单个数字直接当结果。
  List<double> get _maintenanceIntervals {
    final List<double> out = <double>[];
    for (final TextEditingController ctrl in _maintenanceCtrls) {
      final double? value = _parseDouble(ctrl.text);
      if (value != null) out.add(value);
    }
    return out;
  }

  /// 最短维护间隔（h）；无有效间隔返回 null。
  double? get _minMaintenanceInterval {
    final List<double> values = _maintenanceIntervals;
    if (values.isEmpty) return null;
    double min = values.first;
    for (final double value in values) {
      if (value < min) min = value;
    }
    return min;
  }

  /// 维护间隔录错的提示文案；合法时返回 null。
  String? get _maintenanceError {
    for (final TextEditingController ctrl in _maintenanceCtrls) {
      final String text = ctrl.text.trim();
      if (text.isEmpty) continue;
      final double? value = double.tryParse(text);
      if (value == null || value < 0) return _maintenanceErrorHint;
    }
    return null;
  }

  /// 追加一次维护间隔录入行。
  void _addMaintenanceInterval() {
    setState(() => _maintenanceCtrls.add(TextEditingController()));
  }

  /// 删除某一间隔录入行（至少保留 1 行）。
  void _removeMaintenanceInterval(int index) {
    if (_maintenanceCtrls.length <= 1) {
      _snack('至少保留 1 个维护间隔');
      return;
    }
    setState(() {
      final TextEditingController removed = _maintenanceCtrls.removeAt(index);
      _retiredMaintenanceCtrls.add(removed);
    });
  }

  Widget _buildParameterCard() {
    return _sectionCard(
      icon: Icons.edit_note,
      title: '必填参数',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (_needsSampleCompare) ...<Widget>[
            TextField(
              controller: _labMeanCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: '实验室均值 r_R (mg/L)',
                helperText: '按 GB/T 11893 重复测定不少于 3 次的平均值',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 6),
            _buildCompareHint(),
            const SizedBox(height: 14),
          ],
          if (_needsMaintenance) ...<Widget>[
            _buildMaintenanceEditor(),
            const SizedBox(height: 14),
          ],
          if (_needsDataAvailability) ...<Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _validCountCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '有效数据个数',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _totalCountCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '应获得的总数据个数',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '默认取「已选行数 / 数据集总行数」，可按实际检测周期调整。',
              style: TextStyle(fontSize: 11.5, color: kNeutralGrey),
            ),
          ],
        ],
      ),
    );
  }

  /// 维护间隔列表编辑器 + 最短间隔结论预览。
  Widget _buildMaintenanceEditor() {
    final String? error = _maintenanceError;
    final List<double> intervals = _maintenanceIntervals;
    final double? shortest = _minMaintenanceInterval;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          '整个检测周期内每次维护（倾倒废液、添加试剂、更换量程及维修等）'
          '的间隔，单位 h；计算时取其中最小值 T = min(间隔_i)。',
          style: TextStyle(fontSize: 11.5, color: kNeutralGrey, height: 1.5),
        ),
        const SizedBox(height: 8),
        for (int i = 0; i < _maintenanceCtrls.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 54,
                  child: Text(
                    '第 ${i + 1} 次',
                    style: const TextStyle(fontSize: 12, color: kNeutralGrey),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _maintenanceCtrls[i],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: '间隔 ${i + 1} (h)',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      errorText: _maintenanceRowError(i),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                IconButton(
                  tooltip: '删除该间隔',
                  onPressed: () => _removeMaintenanceInterval(i),
                  icon: const Icon(Icons.delete_outline, size: 20),
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _addMaintenanceInterval,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加一次维护间隔'),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              error,
              style: const TextStyle(fontSize: 12, color: kErrorColor),
            ),
          )
        else
          _buildMaintenanceSummary(intervals.length, shortest),
      ],
    );
  }

  /// 单行间隔的校验文案（非数字或负数）。
  String? _maintenanceRowError(int index) {
    final String text = _maintenanceCtrls[index].text.trim();
    if (text.isEmpty) return null;
    final double? value = double.tryParse(text);
    if (value == null || value < 0) return _maintenanceErrorHint;
    return null;
  }

  /// 结论预览：共录入 K 个间隔，最短 M h；不足标准限值时橙字提示。
  Widget _buildMaintenanceSummary(int count, double? shortest) {
    if (shortest == null) {
      return const Text(
        '尚未录入有效间隔：本项将判定为「无法判定」。',
        style: TextStyle(fontSize: 11.5, color: kNeutralGrey),
      );
    }
    final bool below = shortest < _maintenanceStandardHours;
    return Text.rich(
      TextSpan(
        style: TextStyle(
          fontSize: 11.5,
          height: 1.5,
          color: below ? kWarningColor : kSuccessColor,
        ),
        children: <InlineSpan>[
          TextSpan(text: '共录入 $count 个间隔，最短 '),
          TextSpan(
            text: '${shortest.toStringAsFixed(1)} h',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (below)
            TextSpan(text: '，低于标准要求的 $_maintenanceLimitText h')
          else
            TextSpan(text: '，满足 ≥$_maintenanceLimitText h 要求'),
        ],
      ),
    );
  }

  Widget _buildCompareHint() {
    final double? labMean = _parseDouble(_labMeanCtrl.text);
    if (labMean == null) {
      return const Text(
        '未录入 r_R：本项将判定为「无法判定」。',
        style: TextStyle(fontSize: 11.5, color: kNeutralGrey),
      );
    }
    final bool low = labMean < GbCalculator.compareSplit;
    final String value = labMean.toStringAsFixed(3);
    return Text.rich(
      TextSpan(
        style: TextStyle(
          fontSize: 11.5,
          height: 1.5,
          color: low ? kWarningColor : kPrimaryColor,
        ),
        children: <InlineSpan>[
          TextSpan(text: '当前 r_R=$value mg/L ${low ? '<' : '≥'} 0.4 mg/L，将采用'),
          TextSpan(
            text: low ? '绝对误差' : '相对误差',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(text: low ? '判定（≤0.04 mg/L）。' : '判定（≤10%）。'),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 底部操作条

  Widget _buildBottomBar() {
    final int itemCount = _selectedItemIds.length;
    final int rowCount = _selectedIds.length;
    // 参数录错（如维护间隔填了非数字/负数）时禁止计算；
    // 分段条数不足仍允许计算（结果页会给出「数据量不一致」的说明）。
    final bool enabled =
        itemCount > 0 && !_computing && _maintenanceError == null;
    final String summary = _maintenanceError != null
        ? '参数录入有误：$_maintenanceError'
        : '已选 $itemCount 项 · 数据 $rowCount 行';
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      summary,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _maintenanceError != null ? kErrorColor : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      GbCalculator.rangeLabel(_rangeKey),
                      style: const TextStyle(fontSize: 11, color: kNeutralGrey),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: enabled ? _startCalculation : null,
                icon: _computing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.calculate_outlined),
                label: const Text('开始计算'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 通用小部件

  Widget _sectionCard({
    required IconData icon,
    required String title,
    Widget? trailing,
    required Widget child,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, size: 18, color: kPrimaryColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '$label ',
          style: const TextStyle(fontSize: 12, color: kNeutralGrey),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// 数据行选择弹窗：全选 / 仅正常标识 / 最近 24 条 / 清空 + 逐行勾选。
///
/// 同一套弹窗被两处复用：
/// 1. 页面级「选择数据行」（[title] 为默认文案）；
/// 2. 分段级「重新选择该段数据」（传入分段标题，勾选结果即绑定到该段）。
///
/// 若某行已被其它验证项选中，行尾显示橙色小标签提示复用——**不禁用**，
/// 同一批数据本来就允许同时用于多项验证。
class _RowPickerSheet extends StatefulWidget {
  const _RowPickerSheet({
    required this.samples,
    required this.initial,
    this.title = '选择参与计算的数据行',
    this.subtitle,
    this.crossUsage = const <String, Set<String>>{},
  });

  final List<GbSample> samples;
  final Set<String> initial;

  /// 弹窗标题（分段绑定时显示「绑定到「xxx」」）。
  final String title;

  /// 标题下方的补充说明（如「需要 7 条」）。
  final String? subtitle;

  /// 行 id → 已被哪些其它验证项选中（仅用于强调，不影响勾选）。
  final Map<String, Set<String>> crossUsage;

  @override
  State<_RowPickerSheet> createState() => _RowPickerSheetState();
}

class _RowPickerSheetState extends State<_RowPickerSheet> {
  /// 最近 N 条快捷选择的行数。
  static const int _recentCount = 24;

  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = <String>{...widget.initial};
  }

  void _selectAll() {
    setState(() {
      _selected = widget.samples.map((GbSample s) => s.id).toSet();
    });
  }

  void _selectValid() {
    setState(() {
      _selected = <String>{
        for (final GbSample sample in widget.samples)
          if (sample.isValid) sample.id,
      };
    });
  }

  void _selectRecent() {
    final int start = widget.samples.length > _recentCount
        ? widget.samples.length - _recentCount
        : 0;
    setState(() {
      _selected = <String>{
        for (int i = start; i < widget.samples.length; i++)
          widget.samples[i].id,
      };
    });
  }

  void _clearAll() {
    setState(_selected.clear);
  }

  double? get _mean {
    final List<GbSample> picked = <GbSample>[
      for (final GbSample sample in widget.samples)
        if (_selected.contains(sample.id)) sample,
    ];
    if (picked.isEmpty) return null;
    double sum = 0;
    for (final GbSample sample in picked) {
      sum += sample.value;
    }
    return sum / picked.length;
  }

  @override
  Widget build(BuildContext context) {
    final double height = MediaQuery.of(context).size.height * 0.86;
    final double? mean = _mean;
    return SizedBox(
      height: height,
      child: Column(
        children: <Widget>[
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFD6DCE5),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        widget.title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (widget.subtitle != null) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle!,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: kNeutralGrey,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<String>(
                segments: const <ButtonSegment<String>>[
                  ButtonSegment<String>(value: 'all', label: Text('全部')),
                  ButtonSegment<String>(
                    value: 'valid',
                    label: Text('仅正常标识(N)'),
                  ),
                  ButtonSegment<String>(
                    value: 'recent',
                    label: Text('最近 24 条'),
                  ),
                  ButtonSegment<String>(value: 'none', label: Text('清空')),
                ],
                selected: const <String>{},
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                onSelectionChanged: (Set<String> value) {
                  if (value.isEmpty) return;
                  switch (value.first) {
                    case 'all':
                      _selectAll();
                      break;
                    case 'valid':
                      _selectValid();
                      break;
                    case 'recent':
                      _selectRecent();
                      break;
                    case 'none':
                      _clearAll();
                      break;
                    default:
                      break;
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: widget.samples.isEmpty
                ? const Center(
                    child: Text(
                      '该数据集暂无数据行',
                      style: TextStyle(color: kNeutralGrey),
                    ),
                  )
                : ListView.builder(
                    itemCount: widget.samples.length,
                    itemBuilder: (BuildContext ctx, int index) {
                      final GbSample sample = widget.samples[index];
                      final bool checked = _selected.contains(sample.id);
                      final Set<String> usage =
                          widget.crossUsage[sample.id] ?? const <String>{};
                      return CheckboxListTile(
                        value: checked,
                        dense: true,
                        onChanged: (bool? v) {
                          setState(() {
                            if (v == true) {
                              _selected.add(sample.id);
                            } else {
                              _selected.remove(sample.id);
                            }
                          });
                          if (v == true && !sample.isValid) {
                            // 异常标识行允许手动勾选，但必须提示标准要求剔除。
                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '该行数据标识为「${sample.flag.trim()}」，'
                                    '标准要求剔除异常数据',
                                  ),
                                ),
                              );
                          }
                        },
                        title: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                sample.timeText.isEmpty
                                    ? '第 ${sample.index} 行'
                                    : sample.timeText,
                                style: const TextStyle(fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (!sample.isValid)
                              _miniTagChip('异常标识', kWarningColor),
                            // 已被其它验证项选中的行：橙色小标签强调，但**不禁用**。
                            if (usage.isNotEmpty) ...<Widget>[
                              const SizedBox(width: 6),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 156),
                                child: _crossUsageTag(usage),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          _subtitleOf(sample),
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: kNeutralGrey,
                          ),
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      mean == null
                          ? '已选 0 行'
                          : '已选 ${_selected.length} 行，'
                                '均值 ${mean.toStringAsFixed(3)} mg/L',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(context).pop(<String>{..._selected}),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _subtitleOf(GbSample sample) {
    final List<String> parts = <String>[
      '第 ${sample.index} 行 · 数据结果 ${sample.value.toStringAsFixed(4)} mg/L',
    ];
    final String absorbance = sample.cells['吸光度'] ?? '';
    if (absorbance.trim().isNotEmpty) {
      parts.add('吸光度 ${absorbance.trim()}');
    }
    parts.add('标识 ${sample.flag.trim().isEmpty ? 'N' : sample.flag.trim()}');
    return parts.join(' · ');
  }
}

/// 小号状态标签（「已手动绑定」「不参与判定」「异常标识」）。
Widget _miniTagChip(String label, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 10,
        color: color,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// 跨验证项复用标签（橙色，「已被「示值误差」选定」）。
///
/// 与 [_miniTagChip] 的区别：允许超长名称截断，避免行标题溢出。
Widget _crossUsageTag(Set<String> names) {
  final String label =
      '已被${names.map((String name) => '「$name」').join()}选定';
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: kWarningColor.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 10,
        color: kWarningColor,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// [Dataset] 行解析结果：可用样品 + 被排除的行。
class _ParsedRows {
  const _ParsedRows({required this.samples, required this.excluded});

  final List<GbSample> samples;
  final List<_ExcludedRow> excluded;
}

/// 被排除的数据行（无法解析出数值），仅用于提示与明细展示。
class _ExcludedRow {
  const _ExcludedRow({
    required this.rowNo,
    required this.timeText,
    required this.rawCell,
  });

  /// 数据集中的原始行号（从 1 开始）。
  final int rowNo;

  /// 时间列展示文本（无则空串）。
  final String timeText;

  /// 「数据结果」单元格原始文本。
  final String rawCell;
}
