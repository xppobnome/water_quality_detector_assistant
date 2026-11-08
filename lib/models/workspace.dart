import 'package:uuid/uuid.dart';

import 'gb_verify.dart';
import 'standard.dart';

/// 国标验证工作区领域模型（手写 toJson/fromJson，避免代码生成依赖）。
///
/// 数据层级：Workspace（工作空间） > Dataset（原始数据集） > Measurement（单次测量）。
///
/// 增量改造：Workspace 升级为全应用通用的「项目管理容器」，新增字段化命名
/// （contractNo/projectName/owner/item/remark）与归档附件（files）；存储层迁移为
/// `workspaces/<拼接名>/meta.json + 附件` 的真实文件夹结构（见 workspace_store.dart）。

/// 文件夹名 / 文件名的非法字符清洗：去掉 Windows/跨平台不允许的字符，
/// 折叠连续空白，并去掉首尾空白与点。返回可能为空串，调用方自行兜底。
String sanitizeFolderName(String raw) {
  String s = raw.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
  return s;
}

/// 归档文件名的非法字符清洗（复用 [sanitizeFolderName] 规则）。
String sanitizeFileName(String raw) => sanitizeFolderName(raw);

/// 单次测量。
///
/// [values] 为「序列键 → 数值」映射，最常见为 {'value': 1.23}；
/// 当参与分项计算时也可承载 {'reference': ..., 'measured': ...}。
/// [rawText] 保留原始 OCR/粘贴行，便于回溯。
class Measurement {
  Measurement({
    String? id,
    this.label,
    this.timestamp,
    Map<String, double>? values,
    this.rawText = '',
    Map<String, String>? cells,
  }) : id = id ?? const Uuid().v4(),
       values = values ?? <String, double>{},
       cells = cells ?? <String, String>{};

  /// 唯一 id（标红锚点）。
  final String id;

  /// 可选标签（如 '水平1'、'第3组'、时间文本）。
  final String? label;

  /// 可选时间戳（用于 24h 漂移等时间相关判定）。
  final DateTime? timestamp;

  /// 数值映射，如 {'value': 1.23}。
  final Map<String, double> values;

  /// 原始文本行。
  final String rawText;

  /// 整行原始文本（列名 → 值），用于国标验证表格展示与 Excel 导出。
  ///
  /// 典型键：`时间`/`数据结果`/`吸光度`/`数据标识`/`当前值`/`空白值`。
  final Map<String, String> cells;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'label': label,
    'timestamp': timestamp?.toIso8601String(),
    'values': values,
    'rawText': rawText,
    'cells': cells,
  };

  factory Measurement.fromJson(Map<String, dynamic> j) => Measurement(
    id: j['id'] as String? ?? const Uuid().v4(),
    label: j['label'] as String?,
    timestamp: j['timestamp'] == null
        ? null
        : DateTime.tryParse(j['timestamp'] as String),
    values: (j['values'] as Map? ?? <String, dynamic>{}).map(
      (dynamic k, dynamic v) =>
          MapEntry<String, double>(k as String, (v as num).toDouble()),
    ),
    rawText: j['rawText'] as String? ?? '',
    cells: (j['cells'] as Map? ?? <String, dynamic>{}).map(
      (dynamic k, dynamic v) => MapEntry<String, String>(k as String, '$v'),
    ),
  );
}

/// 原始数据集（单独展示，可编辑/增删）。
class Dataset {
  Dataset({
    String? id,
    required this.name,
    required this.parameter,
    DateTime? createdAt,
    List<Measurement>? measurements,
    List<String>? columns,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       measurements = measurements ?? <Measurement>[],
       columns = columns ?? <String>[];

  final String id;
  final String name;

  /// 所属参数（与 Standard.id 对齐，或 'custom'）。
  final String parameter;

  final DateTime createdAt;
  final List<Measurement> measurements;

  /// 列名顺序（国标验证数据集：时间/数据结果/吸光度/数据标识/当前值/空白值）。
  /// 为空时按 [defaultColumns] 展示。
  final List<String> columns;

  /// 默认列（水质在线分析仪「数据查询」表）。
  static const List<String> defaultColumns = <String>[
    '时间',
    '数据结果',
    '吸光度',
    '数据标识',
    '当前值',
    '空白值',
  ];

  /// 实际展示列：优先自定义，否则默认列。
  List<String> get effectiveColumns =>
      columns.isEmpty ? defaultColumns : columns;

  Dataset copyWith({
    String? name,
    String? parameter,
    List<Measurement>? measurements,
    List<String>? columns,
  }) => Dataset(
    id: id,
    name: name ?? this.name,
    parameter: parameter ?? this.parameter,
    createdAt: createdAt,
    measurements: measurements ?? this.measurements,
    columns: columns ?? this.columns,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'parameter': parameter,
    'createdAt': createdAt.toIso8601String(),
    'measurements': measurements.map((Measurement m) => m.toJson()).toList(),
    'columns': columns,
  };

  factory Dataset.fromJson(Map<String, dynamic> j) => Dataset(
    id: j['id'] as String?,
    name: j['name'] as String? ?? '',
    parameter: j['parameter'] as String? ?? '',
    createdAt: j['createdAt'] == null
        ? null
        : DateTime.tryParse(j['createdAt'] as String),
    measurements: (j['measurements'] as List? ?? <dynamic>[])
        .map((dynamic e) => Measurement.fromJson(e as Map<String, dynamic>))
        .toList(),
    columns: List<String>.from(j['columns'] as List? ?? <dynamic>[]),
  );
}

/// 计算结果。
class CalcResult {
  CalcResult({
    String? id,
    required this.itemId,
    required this.rangeKey,
    required this.metricValue,
    required this.pass,
    required this.limitValue,
    this.impactedMeasurementIds = const <String>[],
    this.formulaUsed = '',
    this.intermediate = const <String, double>{},
    this.seriesSnapshot = const <String, List<double>>{},
    this.idsSnapshot = const <String, List<String>>{},
  }) : id = id ?? const Uuid().v4();

  final String id;

  /// 验证项 id。
  final String itemId;

  /// 量程键。
  final String rangeKey;

  /// 计算得到的指标值（与 [limitValue] 同单位）。
  final double metricValue;

  /// 是否合格。
  final bool pass;

  /// 实际使用的判定限值。
  final double limitValue;

  /// 影响最大的测量点 id（仅接近/超出限值时非空，用于标红）。
  final List<String> impactedMeasurementIds;

  /// 使用的公式描述。
  final String formulaUsed;

  /// 中间量（mean/std/delta 等），用于结果展示与审计。
  final Map<String, double> intermediate;

  /// 参与计算的序列快照（结果展示用，便于精确复现与标红）。
  final Map<String, List<double>> seriesSnapshot;

  /// 与 [seriesSnapshot] 对齐的测量点 id（手动输入时为合成 id）。
  final Map<String, List<String>> idsSnapshot;

  /// 指标值接近限值(≥80%)的比例，便于 UI 预警着色。
  double ratioToLimit() {
    if (!limitValue.isFinite || limitValue == 0)
      return metricValue == 0 ? 0 : 1;
    return (metricValue / limitValue).abs();
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'itemId': itemId,
    'rangeKey': rangeKey,
    'metricValue': metricValue,
    'pass': pass,
    'limitValue': limitValue,
    'impactedMeasurementIds': impactedMeasurementIds,
    'formulaUsed': formulaUsed,
    'intermediate': intermediate,
    'seriesSnapshot': seriesSnapshot.map(
      (String k, List<double> v) => MapEntry<String, dynamic>(k, v),
    ),
    'idsSnapshot': idsSnapshot.map(
      (String k, List<String> v) => MapEntry<String, dynamic>(k, v),
    ),
  };

  factory CalcResult.fromJson(Map<String, dynamic> j) => CalcResult(
    id: j['id'] as String?,
    itemId: j['itemId'] as String? ?? '',
    rangeKey: j['rangeKey'] as String? ?? '',
    metricValue: (j['metricValue'] as num?)?.toDouble() ?? double.nan,
    pass: j['pass'] as bool? ?? false,
    limitValue: (j['limitValue'] as num?)?.toDouble() ?? double.nan,
    impactedMeasurementIds: List<String>.from(
      j['impactedMeasurementIds'] as List? ?? <dynamic>[],
    ),
    formulaUsed: j['formulaUsed'] as String? ?? '',
    intermediate: (j['intermediate'] as Map? ?? <String, dynamic>{}).map(
      (dynamic k, dynamic v) =>
          MapEntry<String, double>(k as String, (v as num).toDouble()),
    ),
    seriesSnapshot: (j['seriesSnapshot'] as Map? ?? <String, dynamic>{}).map(
      (dynamic k, dynamic v) => MapEntry<String, List<double>>(
        k as String,
        List<double>.from(
          (v as List).map((dynamic e) => (e as num).toDouble()),
        ),
      ),
    ),
    idsSnapshot: (j['idsSnapshot'] as Map? ?? <String, dynamic>{}).map(
      (dynamic k, dynamic v) => MapEntry<String, List<String>>(
        k as String,
        List<String>.from((v as List).map((dynamic e) => e as String)),
      ),
    ),
  );
}

/// 归档附件：保存在工作空间文件夹内，`meta.json` 中以列表形式登记。
class WorkspaceFile {
  WorkspaceFile({
    String? id,
    required this.name,
    required this.size,
    required this.kind,
    DateTime? createdAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now();

  final String id;

  /// 自定义文件名（含扩展名）。
  final String name;

  /// 字节大小。
  final int size;

  /// 类型：'excel' | 'image' | 'json' | 'pdf' | 'other'。
  final String kind;

  final DateTime createdAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'size': size,
    'kind': kind,
    'createdAt': createdAt.toIso8601String(),
  };

  factory WorkspaceFile.fromJson(Map<String, dynamic> j) => WorkspaceFile(
    id: j['id'] as String?,
    name: j['name'] as String? ?? '',
    size: (j['size'] as num?)?.toInt() ?? 0,
    kind: j['kind'] as String? ?? 'other',
    createdAt: j['createdAt'] == null
        ? null
        : DateTime.tryParse(j['createdAt'] as String),
  );
}

/// 工作空间：一次完整验证任务的容器（增量升级为通用项目管理容器）。
class Workspace {
  Workspace({
    String? id,
    required this.name,
    required this.parameter,
    DateTime? createdAt,
    List<Dataset>? datasets,
    List<CalcResult>? results,
    Map<String, Map<String, StandardItemLimit>>? overrideLimits,
    this.contractNo = '',
    this.projectName = '',
    this.owner = '',
    this.item = '',
    this.remark = '',
    List<WorkspaceFile>? files,
    List<CalcSession>? sessions,
    this.isDraft = false,
    this.savedAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       datasets = datasets ?? <Dataset>[],
       results = results ?? <CalcResult>[],
       overrideLimits =
           overrideLimits ?? <String, Map<String, StandardItemLimit>>{},
       files = files ?? <WorkspaceFile>[],
       sessions = sessions ?? <CalcSession>[];

  /// 唯一 id。
  final String id;

  /// 工作区名称（兼容旧数据；新增工作空间默认取 [displayName]）。
  final String name;

  /// 参数 id（'tp'/'nh3n'/'tn'/'custom'）。
  final String parameter;

  final DateTime createdAt;

  /// 原始数据集列表。
  final List<Dataset> datasets;

  /// 已保存的计算结果。
  final List<CalcResult> results;

  /// 用户编辑后的判定限（itemId → rangeKey → 限）。覆盖标准默认值。
  final Map<String, Map<String, StandardItemLimit>> overrideLimits;

  /// 合同编号（必填字段）。
  final String contractNo;

  /// 项目名称（必填字段）。
  final String projectName;

  /// 项目负责人（选填）。
  final String owner;

  /// 检测项目（选填）。
  final String item;

  /// 其他补充（选填）。
  final String remark;

  /// 归档附件列表。
  final List<WorkspaceFile> files;

  /// 国标验证计算会话（含逐步计算过程，按时间倒序保存）。
  final List<CalcSession> sessions;

  /// 是否为「草稿空间」：无需填写表单即可创建，内容随时保存。
  final bool isDraft;

  /// 最近一次显式保存时间（null 表示从未保存，即"未保存状态"）。
  final DateTime? savedAt;

  /// 是否有未保存内容（草稿且从未保存，或调用方显式置脏）。
  bool get isUnsaved => isDraft && savedAt == null;

  /// 拼接名（未 sanitize 的展示名）：项目名称-合同编号-项目负责人-检测项目-其他补充。
  /// 选填空字段省略该段（不占位）。
  String get displayName =>
      Workspace.buildName(projectName, contractNo, owner, item, remark);

  /// 落盘文件夹名 = sanitize(displayName)；全部为空时回退到 name。
  /// 草稿空间固定使用 `草稿空间`，避免空名导致文件夹名漂移。
  String get folderName => isDraft
      ? (name.trim().isEmpty ? '草稿空间' : sanitizeFolderName(name))
      : sanitizeFolderName(displayName.isNotEmpty ? displayName : name);

  /// 拼接展示名：各字段 trim 后过滤空段，用 '-' 连接。
  static String buildName(
    String projectName,
    String contractNo,
    String owner,
    String item,
    String remark,
  ) {
    return <String>[
      projectName,
      contractNo,
      owner,
      item,
      remark,
    ].map((String s) => s.trim()).where((String s) => s.isNotEmpty).join('-');
  }

  /// 取生效判定限：优先用户覆盖，否则取标准默认。
  StandardItemLimit? effectiveLimit(VerificationItem item, String rangeKey) {
    final StandardItemLimit? overridden =
        overrideLimits[item.id]?[rangeKey] ?? overrideLimits[item.id]?['*'];
    if (overridden != null) return overridden;
    return item.limitFor(rangeKey);
  }

  Workspace copyWith({
    String? name,
    String? parameter,
    List<Dataset>? datasets,
    List<CalcResult>? results,
    Map<String, Map<String, StandardItemLimit>>? overrideLimits,
    String? contractNo,
    String? projectName,
    String? owner,
    String? item,
    String? remark,
    List<WorkspaceFile>? files,
    List<CalcSession>? sessions,
    bool? isDraft,
    DateTime? savedAt,
  }) => Workspace(
    id: id,
    name: name ?? this.name,
    parameter: parameter ?? this.parameter,
    createdAt: createdAt,
    datasets: datasets ?? this.datasets,
    results: results ?? this.results,
    overrideLimits: overrideLimits ?? this.overrideLimits,
    contractNo: contractNo ?? this.contractNo,
    projectName: projectName ?? this.projectName,
    owner: owner ?? this.owner,
    item: item ?? this.item,
    remark: remark ?? this.remark,
    files: files ?? this.files,
    sessions: sessions ?? this.sessions,
    isDraft: isDraft ?? this.isDraft,
    savedAt: savedAt ?? this.savedAt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'parameter': parameter,
    'createdAt': createdAt.toIso8601String(),
    'datasets': datasets.map((Dataset d) => d.toJson()).toList(),
    'results': results.map((CalcResult r) => r.toJson()).toList(),
    'overrideLimits': overrideLimits.map(
      (String k, Map<String, StandardItemLimit> v) => MapEntry<String, dynamic>(
        k,
        v.map(
          (String k2, StandardItemLimit v2) =>
              MapEntry<String, dynamic>(k2, v2.toJson()),
        ),
      ),
    ),
    'contractNo': contractNo,
    'projectName': projectName,
    'owner': owner,
    'item': item,
    'remark': remark,
    'files': files.map((WorkspaceFile f) => f.toJson()).toList(),
    'sessions': sessions.map((CalcSession s) => s.toJson()).toList(),
    'isDraft': isDraft,
    'savedAt': savedAt?.toIso8601String(),
  };

  factory Workspace.fromJson(Map<String, dynamic> j) => Workspace(
    id: j['id'] as String?,
    name: j['name'] as String? ?? '',
    parameter: j['parameter'] as String? ?? '',
    createdAt: j['createdAt'] == null
        ? null
        : DateTime.tryParse(j['createdAt'] as String),
    datasets: (j['datasets'] as List? ?? <dynamic>[])
        .map((dynamic e) => Dataset.fromJson(e as Map<String, dynamic>))
        .toList(),
    results: (j['results'] as List? ?? <dynamic>[])
        .map((dynamic e) => CalcResult.fromJson(e as Map<String, dynamic>))
        .toList(),
    overrideLimits: _parseOverride(j['overrideLimits']),
    contractNo: j['contractNo'] as String? ?? '',
    projectName: j['projectName'] as String? ?? '',
    owner: j['owner'] as String? ?? '',
    item: j['item'] as String? ?? '',
    remark: j['remark'] as String? ?? '',
    files: (j['files'] as List? ?? <dynamic>[])
        .map((dynamic e) => WorkspaceFile.fromJson(e as Map<String, dynamic>))
        .toList(),
    sessions: (j['sessions'] as List? ?? <dynamic>[])
        .map((dynamic e) => CalcSession.fromJson(e as Map<String, dynamic>))
        .toList(),
    isDraft: j['isDraft'] as bool? ?? false,
    savedAt: j['savedAt'] == null
        ? null
        : DateTime.tryParse(j['savedAt'] as String),
  );

  static Map<String, Map<String, StandardItemLimit>> _parseOverride(
    dynamic raw,
  ) {
    final Map<String, Map<String, StandardItemLimit>> out =
        <String, Map<String, StandardItemLimit>>{};
    if (raw is Map) {
      raw.forEach((dynamic k, dynamic v) {
        if (v is Map) {
          final Map<String, StandardItemLimit> inner =
              <String, StandardItemLimit>{};
          v.forEach((dynamic k2, dynamic v2) {
            if (v2 is Map) {
              inner[k2 as String] = StandardItemLimit.fromJson(
                v2 as Map<String, dynamic>,
              );
            }
          });
          out[k as String] = inner;
        }
      });
    }
    return out;
  }
}
