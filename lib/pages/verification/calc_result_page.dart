import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants.dart';
import '../../models/gb_verify.dart';
import '../../models/standard.dart';
import '../../models/workspace.dart';
import '../../services/gb_calculator.dart';
import '../../services/gb_excel_export.dart';
import '../../services/standard_definitions.dart';

/// 一致性偏差的项目 id。
///
/// 该项由 **3 台仪器联合判定**（引擎把联合结论同时写入 3 条 tier 的 `passed`），
/// 因此不得逐台标红，否则会被读成「每台都单独不合格」。
const String _jointVerdictItemId = 'conformity';

/// 指标值展示文本：直接使用引擎给出的展示值，空值占位为「—」。
///
/// 不在展示层追加任何前缀（如旧版的「（参考）」）——「无法判定」的语境
/// 由结论 Chip、数据量校验提示与标准条款共同承担，前缀反而让表格难以对齐阅读。
String gbMetricText(ItemReport report) =>
    report.metricDisplay.isEmpty ? '—' : report.metricDisplay;

/// 国标验证「计算结果」页：总体结论 + 结果总览 + 逐项逐步计算过程。
///
/// 设计约束：
/// - **不直接访问 Provider / Store**：保存动作一律通过 [onSave] 回调交给调用方；
/// - 数值展示只使用 [ItemReport.metricDisplay] / [ItemReport.limitDisplay]，
///   页面内不重算任何国标限值；
/// - Excel 导出由 [GbExcelExporter] 完成，本页只负责触发与提示落盘路径。
class CalcResultPage extends StatefulWidget {
  const CalcResultPage({
    super.key,
    required this.workspace,
    required this.session,
    this.onSave,
  });

  /// 所属工作空间（用于导出文件名与「保存到工作空间」）。
  final Workspace workspace;

  /// 本次计算会话（含样品快照与全部验证项结果）。
  final CalcSession session;

  /// 保存回调；为 null 时隐藏「保存到工作空间」菜单项。
  final Future<void> Function(CalcSession session)? onSave;

  @override
  State<CalcResultPage> createState() => _CalcResultPageState();
}

class _CalcResultPageState extends State<CalcResultPage> {
  /// 等宽字体族回退链（跨 Windows / Android 都能命中）。
  static const List<String> _monoFallback = <String>[
    'Consolas',
    'Courier New',
    'Roboto Mono',
    'monospace',
  ];

  bool _exporting = false;

  CalcSession get _session => widget.session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('计算结果'),
        actions: <Widget>[
          IconButton(
            tooltip: '导出 Excel',
            onPressed: _exporting ? null : _exportExcel,
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.file_download_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: _onMenuSelected,
            itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
              if (widget.onSave != null)
                const PopupMenuItem<String>(
                  value: 'save',
                  child: _MenuRow(icon: Icons.save_outlined, label: '保存到工作空间'),
                ),
              const PopupMenuItem<String>(
                value: 'copy',
                child: _MenuRow(icon: Icons.copy_all_outlined, label: '复制文字报告'),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: <Widget>[
          _buildOverallCard(),
          const SizedBox(height: 12),
          _buildSummaryCard(),
          const SizedBox(height: 12),
          _buildItemReports(),
          const SizedBox(height: 4),
        ],
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  // ---------------------------------------------------------------- 总体结论

  Widget _buildOverallCard() {
    final GbConclusion overall = _session.overall;
    final Color color = _conclusionColor(overall);
    final String rangeText = GbCalculator.rangeLabel(_session.rangeKey);

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
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: color.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(_conclusionIcon(overall), size: 17, color: color),
                      const SizedBox(width: 6),
                      Text(
                        conclusionLabel(overall),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  _session.datasetName,
                  style: const TextStyle(fontSize: 12, color: kNeutralGrey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '共 ${_session.reports.length} 项 · '
              '合格 ${_session.passCount} · '
              '不合格 ${_session.failCount} · '
              '无法判定 ${_session.naCount}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              _session.overallHint,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: overall == GbConclusion.pass
                    ? kNeutralGrey
                    : color.withValues(alpha: 0.95),
              ),
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                _meta('数据行数', '${_session.samples.length} 行'),
                const SizedBox(width: 20),
                Flexible(child: _meta('检测范围', rangeText)),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                _meta('计算时间', _dateTimeText(_session.createdAt)),
                const SizedBox(width: 20),
                Flexible(
                  child: _meta(
                    '工作空间',
                    widget.workspace.displayName.isEmpty
                        ? widget.workspace.name
                        : widget.workspace.displayName,
                  ),
                ),
              ],
            ),
            if (_session.note.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F7FD),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _session.note,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF33506E),
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _meta(String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '$label ',
          style: const TextStyle(fontSize: 11.5, color: kNeutralGrey),
        ),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Color(0xFF3C4A5A)),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 结果总览

  Widget _buildSummaryCard() {
    if (_session.reports.isEmpty) {
      return _emptyCard('本次计算没有任何验证项结果。');
    }
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
                const Icon(
                  Icons.summarize_outlined,
                  size: 18,
                  color: kPrimaryColor,
                ),
                const SizedBox(width: 8),
                const Text(
                  '结果总览',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '共 ${_session.reports.length} 项',
                  style: const TextStyle(fontSize: 12, color: kNeutralGrey),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 38,
                dataRowMinHeight: 36,
                dataRowMaxHeight: 48,
                columnSpacing: 22,
                horizontalMargin: 8,
                headingRowColor: WidgetStateProperty.all(
                  const Color(0xFFF1F5FA),
                ),
                columns: const <DataColumn>[
                  DataColumn(label: Text('验证项', style: _headStyle)),
                  DataColumn(label: Text('条款', style: _headStyle)),
                  DataColumn(label: Text('指标值', style: _headStyle)),
                  DataColumn(label: Text('限值', style: _headStyle)),
                  DataColumn(label: Text('判定', style: _headStyle)),
                ],
                rows: <DataRow>[
                  for (final ItemReport report in _session.reports)
                    DataRow(
                      cells: <DataCell>[
                        DataCell(
                          SizedBox(
                            width: 132,
                            child: Text(
                              report.itemName,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                        ),
                        DataCell(
                          Text(
                            report.clause.isEmpty ? '—' : report.clause,
                            style: const TextStyle(
                              fontSize: 12,
                              color: kNeutralGrey,
                            ),
                          ),
                        ),
                        DataCell(_metricCellWidget(report)),
                        DataCell(
                          Text(
                            report.limitDisplay.isEmpty
                                ? '—'
                                : report.limitDisplay,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        DataCell(_conclusionChip(report.conclusion)),
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

  /// 总览表的「指标值」单元格：数值 + 可选的档位警示图标。
  Widget _metricCellWidget(ItemReport report) {
    final Widget? badge = _tierBadge(report);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          gbMetricText(report),
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
        ),
        if (badge != null) ...<Widget>[const SizedBox(width: 4), badge],
      ],
    );
  }

  /// 总览表的档位警示图标（红色），无警示返回 null。
  ///
  /// 一致性偏差保留图标（表示该项不合格），但 tooltip 只说明「联合判定」，
  /// 不列出三台仪器，避免读成「每台都单独不合格」。
  Widget? _tierBadge(ItemReport report) {
    if (report.itemId == _jointVerdictItemId) {
      if (report.conclusion != GbConclusion.fail) return null;
      return const Tooltip(
        message: '三台仪器联合判定不合格',
        child: Icon(Icons.error_outline, size: 14, color: kErrorColor),
      );
    }
    if (report.failedTierLabels.isEmpty) return null;
    return Tooltip(
      message: '不符合要求的档位：${report.failedTierLabels.join('、')}',
      child: const Icon(Icons.error_outline, size: 14, color: kErrorColor),
    );
  }

  // ---------------------------------------------------------------- 逐项计算过程

  Widget _buildItemReports() {
    if (_session.reports.isEmpty) {
      return _emptyCard('没有可展示的计算过程。');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            '计算过程',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        for (int i = 0; i < _session.reports.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _buildReportCard(i + 1, _session.reports[i]),
          ),
      ],
    );
  }

  Widget _buildReportCard(int no, ItemReport report) {
    final VerificationItem? definition = totalPhosphorusStandard.itemById(
      report.itemId,
    );
    final Color color = _conclusionColor(report.conclusion);
    final Widget? tierNotice = _buildTierNotice(report);

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 头部：序号 + 项目名 + 条款 + 结论 + 子标签
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: kPrimaryLight,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '$no',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: kPrimaryColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        report.itemName,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (report.clause.isNotEmpty)
                        Text(
                          '标准条款 ${report.clause}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: kNeutralGrey,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _conclusionChip(report.conclusion),
              ],
            ),
            if (report.subLabel.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2F5F9),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    report.subLabel,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF51616F),
                    ),
                  ),
                ),
              ),
            ],
            // 指标值与限值
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color.withValues(alpha: 0.25)),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(child: _kvBlock('指标值', gbMetricText(report))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _kvBlock(
                      '限值',
                      report.limitDisplay.isEmpty ? '—' : report.limitDisplay,
                    ),
                  ),
                ],
              ),
            ),
            // 不合格档位提示（一致性偏差为联合判定，单独处理）
            if (tierNotice != null) tierNotice,
            // 数据量校验提示
            if (report.dataNote.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF4E5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFFFD8A8)),
                ),
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
                        report.dataNote,
                        style: const TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          color: Color(0xFF8A4B00),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // 步骤列表
            if (report.steps.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  '该验证项没有可展示的计算步骤（数据不足或缺少必填参数）。',
                  style: TextStyle(
                    fontSize: 12,
                    color: kNeutralGrey,
                    height: 1.5,
                  ),
                ),
              )
            else ...<Widget>[
              const SizedBox(height: 14),
              for (int i = 0; i < report.steps.length; i++)
                _buildStep(
                  report.steps[i],
                  isLast: i == report.steps.length - 1,
                ),
            ],
            // 明细表
            if (report.detailRows.isNotEmpty) ...<Widget>[
              const SizedBox(height: 14),
              const Text(
                '明细数据',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              _buildDetailTable(report.detailRows),
            ],
            // 标准条款原文
            if (definition != null) ...<Widget>[
              const SizedBox(height: 6),
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: const Text(
                    '标准条款原文',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  children: <Widget>[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '${definition.clause}　${definition.name}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: kPrimaryColor,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            definition.methodNote,
                            style: const TextStyle(
                              fontSize: 11.5,
                              height: 1.6,
                              color: Color(0xFF4A5768),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '公式：${definition.formulaDesc}',
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.6,
                              fontFamily: 'monospace',
                              fontFamilyFallback: _monoFallback,
                              color: const Color(0xFF4A5768),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 逐项卡片的「不合格档位」提示行，无提示返回 null。
  ///
  /// - 一致性偏差（[_jointVerdictItemId]）是 3 台仪器**联合判定**：不合格时
  ///   只给一条不列台号的中性警示，绝不逐台点名（那会把联合结论误读成单台结论）；
  ///   合格 / 无法判定时不提示。
  /// - 其余项目照常列出具体不合格档位，合格时不提示。
  Widget? _buildTierNotice(ItemReport report) {
    if (report.itemId == _jointVerdictItemId) {
      if (report.conclusion != GbConclusion.fail) return null;
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.info_outline, size: 15, color: kWarningColor),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                '三台仪器联合判定不合格（不区分单台）',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  fontWeight: FontWeight.w600,
                  color: kWarningColor,
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (report.failedTierLabels.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.error_outline, size: 15, color: kErrorColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '不符合要求的档位：${report.failedTierLabels.join('、')}',
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                fontWeight: FontWeight.w600,
                color: kErrorColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kvBlock(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: const TextStyle(fontSize: 11, color: kNeutralGrey)),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }

  /// 单个计算步骤：左侧竖线 + 圆形序号。
  Widget _buildStep(CalcStep step, {required bool isLast}) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 24,
            child: Column(
              children: <Widget>[
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: kPrimaryColor,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${step.no}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      color: const Color(0xFFDDE4ED),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    step.title,
                    style: const TextStyle(
                      fontSize: 12.8,
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                  if (step.formula.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 5),
                    _codeBlock(step.formula),
                  ],
                  if (step.substitution.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    _scrollCodeBlock(step.substitution),
                  ],
                  if (step.result.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 5),
                    Text(
                      step.resultText,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0D47A1),
                      ),
                    ),
                  ],
                  if (step.note.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      step.note,
                      style: const TextStyle(
                        fontSize: 11,
                        color: kNeutralGrey,
                        height: 1.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _codeBlock(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FA),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          height: 1.5,
          fontFamily: 'monospace',
          fontFamilyFallback: _monoFallback,
          color: const Color(0xFF34495E),
        ),
      ),
    );
  }

  Widget _scrollCodeBlock(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FA),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.5,
            fontFamily: 'monospace',
            fontFamilyFallback: _monoFallback,
            color: const Color(0xFF34495E),
          ),
        ),
      ),
    );
  }

  /// 明细表：首行为表头，可横向滚动。
  Widget _buildDetailTable(List<List<String>> rows) {
    final List<String> header = rows.first;
    final int columns = rows
        .map((List<String> r) => r.length)
        .reduce((int a, int b) => a > b ? a : b);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 36,
        dataRowMinHeight: 32,
        dataRowMaxHeight: 44,
        columnSpacing: 18,
        horizontalMargin: 8,
        headingRowColor: WidgetStateProperty.all(const Color(0xFFF1F5FA)),
        columns: <DataColumn>[
          for (int c = 0; c < columns; c++)
            DataColumn(
              label: Text(
                c < header.length ? header[c] : '',
                style: _headStyle,
              ),
            ),
        ],
        rows: <DataRow>[
          for (int r = 1; r < rows.length; r++)
            DataRow(
              cells: <DataCell>[
                for (int c = 0; c < columns; c++)
                  DataCell(
                    Text(
                      c < rows[r].length ? rows[r][c] : '',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 底部条

  Widget _buildBottomBar() {
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _exporting ? null : _exportExcel,
              icon: const Icon(Icons.file_download_outlined),
              label: Text(_exporting ? '正在导出…' : '导出 Excel（4 个工作表）'),
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyCard(String message) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            message,
            style: const TextStyle(color: kNeutralGrey, fontSize: 13),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 动作

  Future<void> _onMenuSelected(String value) async {
    switch (value) {
      case 'save':
        await _saveToWorkspace();
        break;
      case 'copy':
        await _copyTextReport();
        break;
      default:
        break;
    }
  }

  Future<void> _exportExcel() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final String path = await GbExcelExporter.export(
        workspace: widget.workspace,
        session: _session,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 8),
            showCloseIcon: true,
            closeIconColor: Colors.white70,
            content: Text('已导出：$path'),
            action: SnackBarAction(
              label: '复制路径',
              onPressed: () => Clipboard.setData(ClipboardData(text: path)),
            ),
          ),
        );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('导出失败：$e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _saveToWorkspace() async {
    final Future<void> Function(CalcSession session)? save = widget.onSave;
    if (save == null) return;
    try {
      await save(_session);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已保存到工作空间')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  Future<void> _copyTextReport() async {
    await Clipboard.setData(ClipboardData(text: _buildTextReport()));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('文字报告已复制到剪贴板')));
  }

  /// 把 [CalcSession] 拼成可粘贴到 Word / 微信的纯文本报告。
  String _buildTextReport() {
    final StringBuffer buffer = StringBuffer();
    buffer.writeln('国标验证计算报告（${totalPhosphorusStandard.code} 总磷）');
    buffer.writeln('数据集：${_session.datasetName}');
    final String workspaceName = widget.workspace.displayName.isEmpty
        ? widget.workspace.name
        : widget.workspace.displayName;
    if (workspaceName.isNotEmpty) {
      buffer.writeln('工作空间：$workspaceName');
    }
    buffer.writeln('检测范围：${GbCalculator.rangeLabel(_session.rangeKey)}');
    buffer.writeln('计算时间：${_dateTimeText(_session.createdAt)}');
    buffer.writeln('数据行数：${_session.samples.length}');
    buffer.writeln(
      '总体结论：${conclusionLabel(_session.overall)}'
      '（共 ${_session.reports.length} 项，合格 ${_session.passCount}，'
      '不合格 ${_session.failCount}，无法判定 ${_session.naCount}）',
    );
    if (_session.note.isNotEmpty) {
      buffer.writeln(_session.note);
    }
    buffer.writeln();

    for (int i = 0; i < _session.reports.length; i++) {
      final ItemReport report = _session.reports[i];
      buffer.writeln(
        '${i + 1}. ${report.itemName}（${report.clause}）'
        '　结论：${conclusionLabel(report.conclusion)}',
      );
      if (report.subLabel.isNotEmpty) {
        buffer.writeln('   ${report.subLabel}');
      }
      buffer.writeln(
        '   指标值：${gbMetricText(report)}'
        '　限值：${report.limitDisplay.isEmpty ? '—' : report.limitDisplay}',
      );
      if (report.itemId == _jointVerdictItemId) {
        // 联合判定：不逐台点名，避免读成「每台都单独不合格」。
        if (report.conclusion == GbConclusion.fail) {
          buffer.writeln('   三台仪器联合判定不合格（不区分单台）');
        }
      } else if (report.failedTierLabels.isNotEmpty) {
        buffer.writeln('   不符合要求的档位：${report.failedTierLabels.join('、')}');
      }
      if (report.dataNote.isNotEmpty) {
        buffer.writeln('   数据量校验：${report.dataNote}');
      }
      if (report.steps.isEmpty) {
        buffer.writeln('   （无计算步骤）');
      } else {
        buffer.writeln('   计算步骤：');
        for (final CalcStep step in report.steps) {
          buffer.writeln('   ${step.no}) ${step.title}');
          if (step.formula.isNotEmpty) {
            buffer.writeln('      公式：${step.formula}');
          }
          if (step.substitution.isNotEmpty) {
            buffer.writeln('      代入：${step.substitution}');
          }
          if (step.result.isNotEmpty) {
            buffer.writeln('      结果：${step.resultText}');
          }
          if (step.note.isNotEmpty) {
            buffer.writeln('      说明：${step.note}');
          }
        }
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  // ---------------------------------------------------------------- 结论样式

  static const TextStyle _headStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: Color(0xFF31465C),
  );

  Color _conclusionColor(GbConclusion conclusion) {
    switch (conclusion) {
      case GbConclusion.pass:
        return kSuccessColor;
      case GbConclusion.fail:
        return kErrorColor;
      case GbConclusion.notApplicable:
        return kNeutralGrey;
    }
  }

  IconData _conclusionIcon(GbConclusion conclusion) {
    switch (conclusion) {
      case GbConclusion.pass:
        return Icons.check_circle_outline;
      case GbConclusion.fail:
        return Icons.cancel_outlined;
      case GbConclusion.notApplicable:
        return Icons.help_outline;
    }
  }

  Widget _conclusionChip(GbConclusion conclusion) {
    final Color color = _conclusionColor(conclusion);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        conclusionLabel(conclusion),
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  String _dateTimeText(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }
}

/// 弹出菜单中的一行（图标 + 文字）。
///
/// 不直接用 [ListTile]：ListTile 的默认最小高度会撑破 [PopupMenuItem] 的高度约束。
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 18, color: kNeutralGrey),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(fontSize: 13.5)),
      ],
    );
  }
}
