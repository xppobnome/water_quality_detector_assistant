import 'package:flutter/material.dart';

import '../../models/standard.dart';
import '../../models/workspace.dart';
import '../../services/standard_definitions.dart';

/// 自定义判定限编辑页（补全 `Workspace.overrideLimits` 的写入侧）。
///
/// 计算引擎在 `GbCalculator.compute(limitOverride: ...)` 已经会读取覆盖值，
/// 但此前全仓没有任何界面能写入 `overrideLimits`，字段形同虚设。
/// 本页把「本工作空间 / 当前检测项目 / 各量程下适用的验证项」逐条列出，
/// 允许用户改写绝对限值 / 相对限值；等于标准默认值时不写覆盖（保持可审计）。
///
/// 约束：
/// - 只列出 `item.appliesTo(rangeKey)` 为 true 的组合。若放开不适用项，
///   覆盖会把限值塞进该量程，使 `appliesTo` 变 true，导致标准里本不该验的项出结论。
/// - `higherIsFail`（值越大越差 / 越大越好）沿用标准定义，不允许翻转，避免改变判定语义。
/// - 返回值为完整的 `overrideLimits` 映射；调用方负责 `copyWith` + 落盘。
class LimitOverridePage extends StatefulWidget {
  const LimitOverridePage({super.key, required this.workspace});

  final Workspace workspace;

  @override
  State<LimitOverridePage> createState() => _LimitOverridePageState();
}

/// 一个可编辑的「验证项 × 量程」组合。
class _LimitRow {
  const _LimitRow({
    required this.item,
    required this.rangeKey,
    required this.standardLimit,
    required this.initialLimit,
  });

  final VerificationItem item;
  final String rangeKey;
  final StandardItemLimit standardLimit;
  final StandardItemLimit initialLimit;
}

class _LimitOverridePageState extends State<LimitOverridePage> {
  late final Standard _standard;
  late final List<_LimitRow> _rows;
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};
  String? _formError;

  @override
  void initState() {
    super.initState();
    _standard =
        standardById(widget.workspace.parameter) ?? totalPhosphorusStandard;
    final Map<String, Map<String, StandardItemLimit>> existing =
        widget.workspace.overrideLimits;
    final List<_LimitRow> rows = <_LimitRow>[];
    for (final VerificationItem item in _standard.items) {
      for (final String rangeKey in _standard.ranges) {
        final StandardItemLimit? std = item.limitFor(rangeKey);
        if (std == null) continue; // 本量程不适用 → 不开放编辑
        final Map<String, StandardItemLimit>? byRange = existing[item.id];
        // 兼容历史 '*' 通配覆盖：读取时展开到具体量程，保存时统一写成具体量程键。
        final StandardItemLimit? override = byRange?[rangeKey] ?? byRange?['*'];
        final StandardItemLimit effective = override ?? std;
        rows.add(
          _LimitRow(
            item: item,
            rangeKey: rangeKey,
            standardLimit: std,
            initialLimit: effective,
          ),
        );
        _fillControllers(item.id, rangeKey, effective);
      }
    }
    _rows = rows;
  }

  @override
  void dispose() {
    for (final TextEditingController c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _key(String itemId, String rangeKey) => '$itemId|$rangeKey';

  void _fillControllers(
    String itemId,
    String rangeKey,
    StandardItemLimit limit,
  ) {
    final String k = _key(itemId, rangeKey);
    _controllers['$k|abs'] ??= TextEditingController();
    _controllers['$k|pct'] ??= TextEditingController();
    _controllers['$k|abs']!.text = limit.absolute == null
        ? ''
        : _num(limit.absolute!);
    _controllers['$k|pct']!.text = limit.percent == null
        ? ''
        : _num(limit.percent!);
  }

  /// 去掉 `toStringAsFixed` 的尾随零，避免 168 显示成 168.0000。
  static String _num(double v) => v
      .toStringAsFixed(6)
      .replaceAll(RegExp(r'0+$'), '')
      .replaceAll(RegExp(r'\.$'), '');

  static bool _same(double? a, double? b) {
    if (a == null || b == null) return a == null && b == null;
    return (a - b).abs() < 1e-9;
  }

  /// 单个判定限的文案，如 `≤0.02 / ±5%`、`≥168`、`≥90%`。
  static String _limitText(StandardItemLimit limit) {
    final List<String> parts = <String>[];
    final double? absolute = limit.absolute;
    final double? percent = limit.percent;
    if (absolute != null) {
      parts.add('${limit.higherIsFail ? '≤' : '≥'}${_num(absolute)}');
    }
    if (percent != null) {
      parts.add(
        limit.higherIsFail ? '±${_num(percent)}%' : '≥${_num(percent)}%',
      );
    }
    return parts.isEmpty ? '—' : parts.join(' / ');
  }

  bool _isCustom(_LimitRow row) {
    final String k = _key(row.item.id, row.rangeKey);
    final double? abs = double.tryParse(_controllers['$k|abs']!.text.trim());
    final double? pct = double.tryParse(_controllers['$k|pct']!.text.trim());
    return !_same(abs, row.standardLimit.absolute) ||
        !_same(pct, row.standardLimit.percent);
  }

  double? _read(String text, String label, {required bool required}) {
    final String t = text.trim();
    if (t.isEmpty) {
      if (required) _formError = '「$label」不能为空';
      return null;
    }
    final double? v = double.tryParse(t);
    if (v == null || !v.isFinite || v <= 0) {
      _formError = '「$label」需要填写大于 0 的数字';
      return null;
    }
    return v;
  }

  void _save() {
    _formError = null;
    final Map<String, Map<String, StandardItemLimit>> result =
        <String, Map<String, StandardItemLimit>>{};
    // 保留不属于当前标准的条目（例如从其它检测项目残留的覆盖），避免数据丢失。
    for (final MapEntry<String, Map<String, StandardItemLimit>> e
        in widget.workspace.overrideLimits.entries) {
      if (_standard.itemById(e.key) != null) continue;
      result[e.key] = Map<String, StandardItemLimit>.from(e.value);
    }
    for (final _LimitRow row in _rows) {
      final String k = _key(row.item.id, row.rangeKey);
      final String label =
          '${row.item.name} · ${_standard.rangeLabel(row.rangeKey)}';
      final bool needAbs = row.standardLimit.absolute != null;
      final bool needPct = row.standardLimit.percent != null;
      final double? abs = _read(
        _controllers['$k|abs']!.text,
        '$label 绝对限值',
        required: needAbs,
      );
      final double? pct = _read(
        _controllers['$k|pct']!.text,
        '$label 相对限值',
        required: needPct,
      );
      if (_formError != null) break;
      final bool changed =
          !_same(abs, row.standardLimit.absolute) ||
          !_same(pct, row.standardLimit.percent);
      if (!changed) continue;
      result.putIfAbsent(
        row.item.id,
        () => <String, StandardItemLimit>{},
      )[row.rangeKey] = StandardItemLimit(
        absolute: abs,
        percent: pct,
        higherIsFail: row.standardLimit.higherIsFail,
      );
    }
    if (_formError != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(_formError!)));
      return;
    }
    Navigator.of(context).pop(result);
  }

  void _resetRow(_LimitRow row) {
    setState(() {
      _fillControllers(row.item.id, row.rangeKey, row.standardLimit);
    });
  }

  void _resetAll() {
    setState(() {
      for (final _LimitRow row in _rows) {
        _fillControllers(row.item.id, row.rangeKey, row.standardLimit);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final List<VerificationItem> items = <VerificationItem>[
      for (final VerificationItem item in _standard.items)
        if (_rows.any((_LimitRow r) => r.item.id == item.id)) item,
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('自定义判定限'),
        actions: <Widget>[
          TextButton(onPressed: _resetAll, child: const Text('全部恢复默认')),
          IconButton(
            tooltip: '保存',
            icon: const Icon(Icons.save_outlined),
            onPressed: _save,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.info_outline_rounded,
                      size: 17,
                      color: cs.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_standard.name}（${_standard.code}）',
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '留空或填回标准值即不覆盖；填写后仅本工作空间的判定生效，'
                  '标准依据工作表仍展示国标原文限值。'
                  '修改需要重新点击「开始计算」才会反映到结论。'
                  '仅列出该量程下国标适用的验证项，判定方向（越大越差 / 越大越好）不可改。',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 11.5,
                    height: 1.55,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (final VerificationItem item in items)
            _itemCard(context, cs, item),
        ],
      ),
    );
  }

  Widget _itemCard(
    BuildContext context,
    ColorScheme cs,
    VerificationItem item,
  ) {
    final List<_LimitRow> rows = <_LimitRow>[
      for (final _LimitRow r in _rows)
        if (r.item.id == item.id) r,
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    item.name,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (item.clause.isNotEmpty)
                  Text(
                    item.clause,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (final _LimitRow row in rows) _rangeBlock(cs, row),
          ],
        ),
      ),
    );
  }

  Widget _rangeBlock(ColorScheme cs, _LimitRow row) {
    final String k = _key(row.item.id, row.rangeKey);
    final bool custom = _isCustom(row);
    final String op = row.standardLimit.higherIsFail ? '上限' : '下限';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                _standard.rangeLabel(row.rangeKey),
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '标准 ${_limitText(row.standardLimit)}（$op）',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
              ),
              const Spacer(),
              if (custom)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: cs.tertiaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '已自定义',
                    style: TextStyle(
                      color: cs.onTertiaryContainer,
                      fontSize: 10.5,
                    ),
                  ),
                ),
              IconButton(
                tooltip: '恢复标准默认值',
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.settings_backup_restore_rounded,
                  size: 17,
                ),
                onPressed: () => _resetRow(row),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              if (row.standardLimit.absolute != null)
                Expanded(
                  child: TextField(
                    controller: _controllers['$k|abs'],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: row.standardLimit.higherIsFail
                          ? '绝对限值 ≤'
                          : '绝对限值 ≥',
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
              if (row.standardLimit.absolute != null &&
                  row.standardLimit.percent != null)
                const SizedBox(width: 10),
              if (row.standardLimit.percent != null)
                Expanded(
                  child: TextField(
                    controller: _controllers['$k|pct'],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: row.standardLimit.higherIsFail
                          ? '相对限值 ±（%）'
                          : '相对限值 ≥（%）',
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
