import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../models/gb_verify.dart';
import '../../models/instrument_type.dart';
import '../../models/standard.dart';
import '../../models/water_quality_row.dart';
import '../../models/workspace.dart';
import '../../providers/image_to_excel_provider.dart';
import '../../providers/workspace_provider.dart';
import '../../services/excel_service.dart';
import '../../services/standard_definitions.dart';
import '../../utils/number_utils.dart';
import '../../utils/workspace_utils.dart';
import '../../widgets/status_badge.dart';
import '../image_to_excel_page.dart';
import 'calc_result_page.dart';
import 'calc_setup_page.dart';

/// 工作空间详情页（国标验证总入口）。
///
/// 结构：信息卡 → 数据集（表格预览 / 导入 / 改名 / 删除）→ 数据导入入口
/// （其他工作空间 / Excel / 图片 OCR）→ 开始计算 → 历史计算 → 归档附件。
///
/// 未保存拦截：草稿空间（`isUnsaved`）或页面内有改动（`_dirty`）时，
/// 返回键弹「保存 / 不保存 / 取消」三按钮对话框。
class WorkspaceDetailPage extends StatefulWidget {
  const WorkspaceDetailPage({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  State<WorkspaceDetailPage> createState() => _WorkspaceDetailPageState();
}

class _WorkspaceDetailPageState extends State<WorkspaceDetailPage> {
  Workspace? _ws;
  bool _loading = true;
  String? _error;

  /// 页面内是否有「尚未标记为已保存」的改动。
  bool _dirty = false;

  /// 保存进行中（防重入：连点保存不会触发两次归档 → 不会产生两个草稿）。
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  // ---------------------------------------------------------------- 数据装载

  Future<void> _reload() async {
    try {
      final Workspace? ws = await context.read<WorkspaceProvider>().get(
        widget.workspaceId,
      );
      if (!mounted) return;
      setState(() {
        _ws = ws;
        _loading = false;
        _error = ws == null ? '工作空间不存在或已删除' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  /// 落盘最新状态，并标记「有改动」。
  Future<void> _apply(Workspace next) async {
    if (!mounted) return;
    setState(() {
      _ws = next;
      _dirty = true;
    });
    final bool ok = await context.read<WorkspaceProvider>().update(next);
    if (!ok && mounted) {
      _toast('保存失败，请重试');
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // ---------------------------------------------------------------- 返回拦截

  Future<void> _handleBack() async {
    // 保存进行中不重复弹窗（避免连点堆叠多个对话框）。
    if (_saving) return;
    final Workspace? ws = _ws;
    if (ws == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (!ws.isUnsaved && !_dirty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    final String? choice = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('当前工作空间还没保存'),
        content: Text(
          ws.isDraft
              ? '草稿内容已自动暂存在「草稿空间」中。是否现在标记为已保存并归档到工作空间列表？'
              : '当前工作空间有改动尚未标记为已保存，是否现在保存？',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: const Text('不保存'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null || choice == 'cancel') return;

    if (choice == 'save') {
      await _saveFromDialog();
      return;
    }

    Navigator.of(context).pop();
  }

  /// 返回拦截对话框的「保存」分支：与 AppBar 保存共用 [_saving] 锁，
  /// await 期间重复触发直接忽略（防重复归档）。
  Future<void> _saveFromDialog() async {
    if (_saving) return;
    final Workspace? latest = _ws;
    if (latest == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    try {
      final WorkspaceProvider provider = context.read<WorkspaceProvider>();
      final bool ok = await provider.markSaved(latest);
      if (!mounted) return;
      if (!ok) {
        _toast('保存失败，请重试');
        return;
      }
      final String? warning = provider.lastWarning;
      if (warning != null) {
        provider.clearWarning();
        _toast(warning);
      }
      _dirty = false;
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// AppBar 主动保存。
  ///
  /// 草稿且有内容时，`markSaved` 会把它**归档为正常工作空间并清空草稿位**，
  /// 因此保存成功后直接返回列表查看结果（列表会多出一条已保存空间、草稿卡
  /// 回到空态）；空草稿与非草稿只打保存标记，留在本页继续编辑。
  ///
  /// 防重入：进入即置 [_saving]，期间 AppBar 按钮禁用、再点也直接返回；
  /// provider 侧还有按 id 复查的幂等短路，双保险。
  Future<void> _saveNow() async {
    if (_saving) return;
    final Workspace? ws = _ws;
    if (ws == null) return;
    setState(() => _saving = true);
    try {
      final WorkspaceProvider provider = context.read<WorkspaceProvider>();
      final bool archiving = ws.isDraft && provider.hasContent(ws);
      final bool ok = await provider.markSaved(ws);
      if (!mounted) return;
      if (!ok) {
        _toast('保存失败，请重试');
        return;
      }
      // 「已成功但有需要提醒的问题」（归档成功、草稿位重置失败）优先提示。
      final String? warning = provider.lastWarning;
      if (warning != null) provider.clearWarning();

      if (archiving) {
        _toast(warning ?? '草稿已归档到工作空间列表');
        Navigator.of(context).pop();
        return;
      }
      await _reload();
      if (!mounted) return;
      setState(() => _dirty = false);
      _toast(warning ?? '已保存到工作空间');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------------------------------------------------------- 检测项目

  /// 切换检测项目：**只更新 `parameter`**。
  ///
  /// 不改 `item` / `name`，因此拼接名（`Workspace.displayName`）与物理文件夹名
  /// 都保持不变——工作空间是「已归档的记录」，磁盘目录名是它的外部标识，
  /// 不能因为切换检测项目而改名。界面上的项目名一律按当前 `parameter` 实时
  /// 渲染（见 [_title] 与信息卡的项目 Chip）。
  ///
  /// 已保存的计算记录（`sessions`）不受影响；切到非「总磷」时计算入口自动
  /// 置灰（见 build 中的 `canCalc`），切回即恢复。
  Future<void> _setParameter(String id) async {
    final Workspace? ws = _ws;
    if (ws == null || ws.parameter == id) return;
    await _apply(ws.copyWith(parameter: id));
    if (!mounted) return;
    _toast('检测项目已切换为「${gbItemLabelOfId(id)}」');
  }

  // ---------------------------------------------------------------- 数据集

  Future<void> _newDataset() async {
    final Workspace? ws = _ws;
    if (ws == null) return;
    final int n = ws.datasets.length + 1;
    final Dataset ds = Dataset(name: '数据集 $n', parameter: ws.parameter);
    await _apply(ws.copyWith(datasets: <Dataset>[...ws.datasets, ds]));
  }

  Future<void> _renameDataset(Dataset ds) async {
    final TextEditingController controller = TextEditingController(
      text: ds.name,
    );
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('重命名数据集'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '数据集名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.isEmpty || name == ds.name) return;
    final Workspace? ws = _ws;
    if (ws == null) return;
    await _apply(
      ws.copyWith(
        datasets: ws.datasets
            .map((Dataset d) => d.id == ds.id ? d.copyWith(name: name) : d)
            .toList(),
      ),
    );
  }

  Future<void> _removeDataset(Dataset ds) async {
    final Workspace? ws = _ws;
    if (ws == null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除数据集'),
        content: Text(
          '「${ds.name}」及其 ${ds.measurements.length} 行数据将被删除，'
          '已保存的计算记录不受影响。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kErrorColor),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    await _apply(
      ws.copyWith(
        datasets: ws.datasets.where((Dataset d) => d.id != ds.id).toList(),
      ),
    );
  }

  /// 选定导入目标数据集：无数据集时自动建一个，多个时弹窗选择。
  Future<Dataset?> _ensureTargetDataset() async {
    final Workspace? ws = _ws;
    if (ws == null) return null;
    if (ws.datasets.isEmpty) {
      final Dataset ds = Dataset(name: '数据集 1', parameter: ws.parameter);
      await _apply(ws.copyWith(datasets: <Dataset>[ds]));
      return ds;
    }
    if (ws.datasets.length == 1) return ws.datasets.first;
    return _pickDataset('选择目标数据集');
  }

  Future<Dataset?> _pickDataset(String title) async {
    final Workspace? ws = _ws;
    if (ws == null || ws.datasets.isEmpty) return null;
    return showDialog<Dataset>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: Text(title),
        children: <Widget>[
          for (final Dataset ds in ws.datasets)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(ds),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: <Widget>[
                    const Icon(
                      Icons.dataset_outlined,
                      size: 18,
                      color: kPrimaryColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ds.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${ds.measurements.length} 行',
                      style: const TextStyle(fontSize: 11, color: kNeutralGrey),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 把测量行追加到目标数据集（列头固定为总铜数据查询表列）。
  Future<void> _appendMeasurements(
    Dataset target,
    List<Measurement> rows,
  ) async {
    if (rows.isEmpty) return;
    final Workspace? ws = _ws;
    if (ws == null) return;
    final Dataset updated = target.copyWith(
      measurements: <Measurement>[...target.measurements, ...rows],
      columns: InstrumentType.totalCopper.headers,
    );
    final List<Dataset> list = ws.datasets
        .map((Dataset d) => d.id == target.id ? updated : d)
        .toList();
    await _apply(ws.copyWith(datasets: list));
    _toast('已导入 ${rows.length} 行数据');
  }

  // ---------------------------------------------------------------- 三种导入

  /// 导入菜单（数据集卡片上的「导入数据」）。
  Future<void> _showImportMenu(Dataset target) async {
    final String? source = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(
                Icons.folder_copy_outlined,
                color: kPrimaryColor,
              ),
              title: const Text('从其他工作空间导入'),
              subtitle: const Text(
                '复制其它工作空间数据集中的行',
                style: TextStyle(fontSize: 11),
              ),
              onTap: () => Navigator.of(ctx).pop('workspace'),
            ),
            ListTile(
              leading: const Icon(
                Icons.table_chart_outlined,
                color: kPrimaryColor,
              ),
              title: const Text('导入 Excel 文件'),
              subtitle: const Text(
                '支持 .xlsx / .xls',
                style: TextStyle(fontSize: 11),
              ),
              onTap: () => Navigator.of(ctx).pop('excel'),
            ),
            ListTile(
              leading: const Icon(
                Icons.document_scanner_outlined,
                color: kPrimaryColor,
              ),
              title: const Text('选择图片并 OCR'),
              subtitle: const Text(
                '拍照/选图识别表格后带入数据',
                style: TextStyle(fontSize: 11),
              ),
              onTap: () => Navigator.of(ctx).pop('ocr'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || source == null) return;
    switch (source) {
      case 'workspace':
        await _importFromOtherWorkspace(target);
        break;
      case 'excel':
        await _importFromExcel(target);
        break;
      case 'ocr':
        await _importFromOcr(target);
        break;
    }
  }

  Future<void> _importFromOtherWorkspace(Dataset target) async {
    final Workspace? ws = _ws;
    if (ws == null) return;
    final List<Workspace> candidates = context
        .read<WorkspaceProvider>()
        .items
        .where((Workspace w) => w.id != ws.id)
        .toList();
    if (candidates.isEmpty) {
      _toast('暂无其他工作空间可导入');
      return;
    }

    final Workspace? source = await showDialog<Workspace>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: const Text('选择来源工作空间'),
        children: <Widget>[
          for (final Workspace w in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(w),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  w.isDraft
                      ? '草稿空间'
                      : (w.displayName.isNotEmpty ? w.displayName : w.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
    if (!mounted || source == null) return;

    if (source.datasets.isEmpty) {
      _toast('该工作空间还没有数据集');
      return;
    }

    final Dataset? sourceDataset = await showDialog<Dataset>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: const Text('选择来源数据集'),
        children: <Widget>[
          for (final Dataset d in source.datasets)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(d),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        d.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${d.measurements.length} 行',
                      style: const TextStyle(fontSize: 11, color: kNeutralGrey),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (!mounted || sourceDataset == null) return;
    if (sourceDataset.measurements.isEmpty) {
      _toast('该数据集还没有数据行');
      return;
    }

    final List<Measurement>? picked = await showDialog<List<Measurement>>(
      context: context,
      builder: (_) => _RowPickerDialog(dataset: sourceDataset),
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    await _appendMeasurements(target, picked.map(_copyMeasurement).toList());
  }

  Future<void> _importFromExcel(Dataset target) async {
    try {
      final List<PlatformFile> picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['xlsx', 'xls'],
      );
      if (picked.isEmpty) return;
      final String? path = picked.single.path;
      if (path == null) {
        _toast('无法读取所选文件路径');
        return;
      }
      final List<WaterQualityRow> rows = await ExcelService().importExcel(
        path,
        InstrumentType.totalCopper,
      );
      if (!mounted) return;
      if (rows.isEmpty) {
        _toast('Excel 中没有识别到数据行');
        return;
      }
      await _appendMeasurements(target, _toMeasurements(rows));
    } catch (e) {
      _toast('导入 Excel 失败：$e');
    }
  }

  /// 复用「图片转 Excel」页做 OCR 导入。
  ///
  /// 该页依赖全局单例 [ImageToExcelProvider]（`lib/app.dart` 注册），图片是**累加**的。
  /// 若不清空，上一次在「图片转 Excel」标签页里识别过的图片会一起被 `selectedRows()`
  /// 回传，导致导入与本数据集无关的数据。因此进入前必须先清空，并在用户确有
  /// 未清空图片时明确告知（不静默丢弃）。
  Future<void> _importFromOcr(Dataset target) async {
    final ImageToExcelProvider ocr = context.read<ImageToExcelProvider>();
    if (ocr.imagePaths.isNotEmpty) {
      final bool? proceed = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('先清空已有图片'),
          content: Text(
            '「图片转 Excel」中还保留着 ${ocr.imagePaths.length} 张图片。'
            '为避免把这些图片的数据一并导入本数据集，需要先清空。是否继续？',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('清空并继续'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }
    ocr.clearImages();

    final List<WaterQualityRow>? rows = await Navigator.of(context)
        .push<List<WaterQualityRow>>(
          MaterialPageRoute<List<WaterQualityRow>>(
            builder: (_) => const ImageToExcelPage(
              selectionMode: true,
              appBarTitle: '选择图片并 OCR',
            ),
          ),
        );
    if (!mounted || rows == null || rows.isEmpty) return;
    await _appendMeasurements(target, _toMeasurements(rows));
  }

  /// 数据行 → 测量（`value` 取「数据结果」列）。
  List<Measurement> _toMeasurements(List<WaterQualityRow> rows) {
    final List<Measurement> out = <Measurement>[];
    for (final WaterQualityRow row in rows) {
      final String timeText = _rowTimeText(row);
      final double? value = NumberUtils.parseNumber(row.result);
      final Map<String, double> values = <String, double>{
        if (value != null) 'value': value,
        if (row.absorbance != null) 'absorbance': row.absorbance!,
        if (row.detection != null) 'current': row.detection!,
        if (row.blank != null) 'blank': row.blank!,
      };
      out.add(
        Measurement(
          label: timeText.isEmpty ? null : timeText,
          timestamp: _parseTime(timeText),
          values: values,
          rawText:
              '${timeText.isEmpty ? '' : '$timeText '}'
                      '${row.result ?? ''}'
                  .trim(),
          cells: Map<String, String>.from(row.cells),
        ),
      );
    }
    return out;
  }

  /// 跨工作空间复制测量：换新 id，避免与来源数据集 id 冲突。
  Measurement _copyMeasurement(Measurement m) => Measurement(
    label: m.label,
    timestamp: m.timestamp,
    values: Map<String, double>.from(m.values),
    rawText: m.rawText,
    cells: Map<String, String>.from(m.cells),
  );

  /// 行时间文本：日期列 + 时间列（时间列已含日期时直接使用）。
  String _rowTimeText(WaterQualityRow row) {
    final String time = (row.sampleTime ?? '').trim();
    final String date = (row.sampleDate ?? '').trim();
    if (date.isEmpty) return time;
    if (time.isEmpty) return date;
    if (time.contains('-') || time.contains('/')) return time;
    return '$date $time';
  }

  /// 解析 `2026-11-05 22:00:00` / `2026-11-05 22:00` / `2026/11/05 22:00`。
  DateTime? _parseTime(String raw) {
    final String s = raw.trim();
    if (s.isEmpty) return null;
    final DateTime? direct = DateTime.tryParse(s);
    if (direct != null) return direct;
    final RegExp re = RegExp(
      r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?$',
    );
    final Match? m = re.firstMatch(s);
    if (m == null) return null;
    final int year = int.parse(m.group(1)!);
    final int month = int.parse(m.group(2)!);
    final int day = int.parse(m.group(3)!);
    final int hour = int.parse(m.group(4)!);
    final int minute = int.parse(m.group(5)!);
    final int second = m.group(6) == null ? 0 : int.parse(m.group(6)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    if (hour > 23 || minute > 59 || second > 59) return null;
    return DateTime(year, month, day, hour, minute, second);
  }

  // ---------------------------------------------------------------- 计算

  Future<void> _startCalc() async {
    final Workspace? ws = _ws;
    if (ws == null) return;
    if (ws.parameter != 'tp') {
      _toast('当前检测项目标准条款尚未内置，暂不可计算');
      return;
    }
    if (ws.datasets.isEmpty) {
      _toast('请先新建数据集并导入数据');
      return;
    }
    if (ws.datasets.every((Dataset d) => d.measurements.isEmpty)) {
      _toast('数据集还没有数据，请先导入测量数据');
      return;
    }
    final Dataset? ds = ws.datasets.length == 1
        ? ws.datasets.first
        : await _pickDataset('选择计算使用的数据集');
    if (!mounted || ds == null) return;

    // 计算设置页在算完后通过 `onSessionSaved` 幂等落盘（按 session.id 去重），
    // 返回后这里重新读盘刷新「历史计算」；若未来改为回传会话，下面的
    // `returned != null` 分支同样能接住。
    final CalcSession? returned = await Navigator.of(context).push<CalcSession>(
      MaterialPageRoute<CalcSession>(
        builder: (_) => CalcSetupPage(
          workspace: ws,
          dataset: ds,
          onSessionSaved: _onSessionSaved,
        ),
      ),
    );
    if (!mounted) return;
    if (returned != null) {
      await _onSessionSaved(returned);
      return;
    }
    await _reload();
    _dirty = false;
  }

  Future<void> _openSession(CalcSession session) async {
    final Workspace? ws = _ws;
    if (ws == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CalcResultPage(
          workspace: ws,
          session: session,
          onSave: _onSessionSaved,
        ),
      ),
    );
    if (!mounted) return;
    await _reload();
    _dirty = false;
  }

  /// 结果页保存会话后的回调：幂等地把会话写入工作空间并落盘。
  ///
  /// [CalcResultPage] 自身不访问存储，保存动作完全由本回调承担；
  /// 同一会话可能被保存两次（结果页点「保存」→ 返回时又随
  /// `Navigator.pop(session)` 回传），因此按 [CalcSession.id] 去重：
  /// 已存在时用新对象替换并置于首位，不存在时插入首位。
  Future<void> _onSessionSaved(CalcSession session) async {
    final Workspace? ws = _ws;
    if (ws == null) return;
    final List<CalcSession> rest = ws.sessions
        .where((CalcSession s) => s.id != session.id)
        .toList();
    final Workspace next = ws.copyWith(
      sessions: <CalcSession>[session, ...rest],
    );
    // _apply 内部即 provider.update() 落盘。
    await _apply(next);
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    setState(() => _dirty = false);
  }

  // ---------------------------------------------------------------- 附件

  Future<void> _pickAttachment() async {
    final Workspace? ws = _ws;
    if (ws == null) return;
    try {
      final List<PlatformFile> picked = await FilePicker.pickFiles(
        type: FileType.any,
      );
      if (picked.isEmpty) return;
      final PlatformFile file = picked.single;
      final String? source = file.path;
      if (source == null) return;
      if (!mounted) return;
      final TextEditingController controller = TextEditingController(
        text: file.name,
      );
      final String? customName = await showDialog<String>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('保存到工作空间'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: '自定义文件名',
              border: OutlineInputBorder(),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      controller.dispose();
      if (!mounted || customName == null || customName.isEmpty) return;
      await context.read<WorkspaceProvider>().store.addFile(
        ws.id,
        source,
        customName: customName,
      );
      if (!mounted) return;
      await _reload();
      _toast('文件已保存到工作空间');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  Future<void> _removeFile(String fileId) async {
    final Workspace? ws = _ws;
    if (ws == null) return;
    await context.read<WorkspaceProvider>().store.removeFile(ws.id, fileId);
    if (!mounted) return;
    await _reload();
    _toast('附件已删除');
  }

  // ---------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('工作空间')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final Workspace? ws = _ws;
    if (ws == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('工作空间')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error ?? '工作空间不存在或已删除',
              textAlign: TextAlign.center,
              style: const TextStyle(color: kNeutralGrey),
            ),
          ),
        ),
      );
    }

    final Standard? standard = standardById(ws.parameter);
    final bool implemented = standard?.implemented ?? false;
    // 目前仅总磷（HJ 103—2026）内置完整判定；其余项目禁用计算入口。
    final bool canCalc = ws.parameter == 'tp';

    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_title(ws)),
          actions: <Widget>[
            if (ws.isUnsaved || _dirty)
              IconButton(
                tooltip: _saving ? '保存中…' : '保存',
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                onPressed: _saving ? null : _saveNow,
              ),
            const SizedBox(width: 4),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            _infoCard(ws, implemented),
            const SizedBox(height: 16),
            _sectionHeader(
              icon: Icons.dataset_outlined,
              title: '数据集（${ws.datasets.length}）',
            ),
            const SizedBox(height: 8),
            if (ws.datasets.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(14),
                  child: Center(
                    child: Text(
                      '暂无数据集，点击下方「新建数据集」后导入测量数据',
                      style: TextStyle(fontSize: 12, color: kNeutralGrey),
                    ),
                  ),
                ),
              )
            else
              for (final Dataset ds in ws.datasets)
                _DatasetCard(
                  dataset: ds,
                  onRename: () => unawaited(_renameDataset(ds)),
                  onImport: () => unawaited(_showImportMenu(ds)),
                  onRemove: () => unawaited(_removeDataset(ds)),
                  onViewAll: () => _showFullTable(ds),
                ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => unawaited(_newDataset()),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建数据集'),
              ),
            ),
            const SizedBox(height: 20),
            _sectionHeader(icon: Icons.cloud_download_outlined, title: '导入数据'),
            const SizedBox(height: 8),
            _importCard(),
            const SizedBox(height: 20),
            _sectionHeader(icon: Icons.calculate_outlined, title: '计算'),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      implemented
                          ? '按 ${standard?.code ?? ''} 条款逐项计算并给出合格判定'
                          : '当前检测项目的标准条款尚未内置，暂不出具合格判定',
                      style: const TextStyle(fontSize: 12, color: kNeutralGrey),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: Tooltip(
                        message: canCalc
                            ? '按 HJ 103—2026 条款逐项计算'
                            : '当前检测项目标准条款尚未内置，暂不可计算',
                        child: FilledButton.icon(
                          onPressed: canCalc
                              ? () => unawaited(_startCalc())
                              : null,
                          icon: const Icon(Icons.play_arrow_outlined),
                          label: const Text('开始计算'),
                        ),
                      ),
                    ),
                    if (!canCalc) ...<Widget>[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Icon(
                            Icons.info_outline,
                            size: 14,
                            color: kNeutralGrey,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '当前检测项目标准条款尚未内置，暂不可计算。'
                              '如需出具判定，请在检测项目中选择「总磷」。',
                              style: const TextStyle(
                                fontSize: 11,
                                color: kNeutralGrey,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            _sectionHeader(
              icon: Icons.history,
              title: '历史计算（${ws.sessions.length}）',
            ),
            const SizedBox(height: 8),
            if (ws.sessions.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(14),
                  child: Center(
                    child: Text(
                      '还没有计算记录，点击「开始计算」生成',
                      style: TextStyle(fontSize: 12, color: kNeutralGrey),
                    ),
                  ),
                ),
              )
            else
              Card(
                child: Column(
                  children: <Widget>[
                    for (final CalcSession s in ws.sessions)
                      ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.assignment_turned_in_outlined,
                          color: kPrimaryColor,
                          size: 20,
                        ),
                        title: Text(
                          '${s.datasetName} · ${s.reports.length} 项',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          '合格 ${s.passCount} / 不合格 ${s.failCount}'
                          '${s.naCount > 0 ? ' / 无法判定 ${s.naCount}' : ''}'
                          // 与徽章口径对齐：徽章看 overall（含覆盖度），
                          // 若不算全导致「无法判定」，这里必须说明原因。
                          '${s.missingItemCount > 0 ? ' / 未计算 ${s.missingItemCount}' : ''}'
                          ' · ${formatDateTime(s.createdAt)}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            StatusBadge(
                              label: conclusionLabel(s.overall),
                              color: s.overall == GbConclusion.fail
                                  ? kErrorColor
                                  : s.overall == GbConclusion.pass
                                  ? kSuccessColor
                                  : kNeutralGrey,
                            ),
                            const Icon(Icons.chevron_right, size: 18),
                          ],
                        ),
                        onTap: () => unawaited(_openSession(s)),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            _attachmentsSection(ws),
          ],
        ),
      ),
    );
  }

  /// 展示标题（草稿恒为「草稿空间」）。
  ///
  /// 拼接名里的检测项目段一律按当前 `parameter` 实时渲染：切换检测项目后
  /// `ws.item` 仍是旧标签（不改名、不改文件夹），但标题要显示当前项目。
  String _title(Workspace ws) {
    if (ws.isDraft) return '草稿空间';
    final String itemLabel = gbItemLabelOfId(ws.parameter);
    final bool staleItem =
        ws.item.trim().isNotEmpty && gbItemIdOfLabel(ws.item) != ws.parameter;
    final String name = staleItem
        ? Workspace.buildName(
            ws.projectName,
            ws.contractNo,
            ws.owner,
            itemLabel,
            ws.remark,
          )
        : ws.displayName;
    if (name.isNotEmpty) return name;
    return ws.name.isEmpty ? '未命名工作空间' : ws.name;
  }

  Widget _sectionHeader({required IconData icon, required String title}) => Row(
    children: <Widget>[
      Icon(icon, size: 18, color: kPrimaryColor),
      const SizedBox(width: 6),
      Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  );

  /// 信息卡：拼接名 + 检测项目 + 合同编号/负责人/备注（空显示「—」）。
  Widget _infoCard(Workspace ws, bool implemented) {
    final String itemLabel = gbItemLabelOfId(ws.parameter);
    final Standard? standard = standardById(ws.parameter);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _title(ws),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: kPrimaryColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _parameterPicker(ws, itemLabel),
              ],
            ),
            const SizedBox(height: 8),
            _infoRow('合同编号', ws.contractNo),
            _infoRow('项目负责人', ws.owner),
            _infoRow('其他补充', ws.remark),
            _infoRow('创建时间', formatDateTime(ws.createdAt)),
            if (ws.isDraft) _infoRow('保存状态', ws.isUnsaved ? '未保存' : '已保存'),
            if (!implemented) ...<Widget>[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: kWarningColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: kWarningColor.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: kWarningColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        standard?.note.isNotEmpty == true
                            ? standard!.note
                            : '该检测项目标准条款尚未内置，仅支持数据采集与导出。',
                        style: const TextStyle(
                          fontSize: 12,
                          color: kWarningColor,
                        ),
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

  /// 检测项目 Chip：点击弹出「总磷 / 氨氮 / 总氮 / COD」菜单。
  ///
  /// 只有总磷（HJ 103—2026）内置完整判定，其余项在菜单里标注「标准未内置」。
  Widget _parameterPicker(Workspace ws, String itemLabel) =>
      PopupMenuButton<String>(
        tooltip: '切换检测项目',
        initialValue: ws.parameter,
        padding: EdgeInsets.zero,
        onSelected: (String id) => unawaited(_setParameter(id)),
        itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
          for (final GbItemOption option in gbItemOptions)
            PopupMenuItem<String>(
              value: option.id,
              child: Row(
                children: <Widget>[
                  Icon(
                    option.id == ws.parameter
                        ? Icons.check_circle_outline
                        : Icons.circle_outlined,
                    size: 16,
                    color: option.id == ws.parameter
                        ? kPrimaryColor
                        : kNeutralGrey,
                  ),
                  const SizedBox(width: 8),
                  Text(option.label),
                  if (standardById(option.id)?.implemented != true) ...<Widget>[
                    const SizedBox(width: 6),
                    const Text(
                      '（标准未内置）',
                      style: TextStyle(fontSize: 11, color: kNeutralGrey),
                    ),
                  ],
                ],
              ),
            ),
        ],
        child: Chip(
          visualDensity: VisualDensity.compact,
          backgroundColor: kPrimaryLight,
          avatar: const Icon(
            Icons.science_outlined,
            size: 14,
            color: kPrimaryColor,
          ),
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                itemLabel,
                style: const TextStyle(fontSize: 11, color: kPrimaryColor),
              ),
              const Icon(Icons.arrow_drop_down, size: 16, color: kPrimaryColor),
            ],
          ),
        ),
      );

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: kNeutralGrey),
          ),
        ),
        Expanded(
          child: Text(
            value.trim().isEmpty ? '—' : value,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    ),
  );

  /// 三种导入来源的统一入口卡片。
  Widget _importCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '导入的数据会追加到所选数据集的末尾，列头统一为'
            '「时间/数据结果/吸光度/数据标识/当前值/空白值」。',
            style: TextStyle(fontSize: 12, color: kNeutralGrey),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: () => unawaited(_importFromOtherWorkspaceFlow()),
                icon: const Icon(Icons.folder_copy_outlined, size: 18),
                label: const Text('从其他工作空间导入'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => unawaited(_importFromExcelFlow()),
                icon: const Icon(Icons.table_chart_outlined, size: 18),
                label: const Text('导入 Excel 文件'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => unawaited(_importFromOcrFlow()),
                icon: const Icon(Icons.document_scanner_outlined, size: 18),
                label: const Text('选择图片并 OCR'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Future<void> _importFromOtherWorkspaceFlow() async {
    final Dataset? target = await _ensureTargetDataset();
    if (!mounted || target == null) return;
    await _importFromOtherWorkspace(target);
  }

  Future<void> _importFromExcelFlow() async {
    final Dataset? target = await _ensureTargetDataset();
    if (!mounted || target == null) return;
    await _importFromExcel(target);
  }

  Future<void> _importFromOcrFlow() async {
    final Dataset? target = await _ensureTargetDataset();
    if (!mounted || target == null) return;
    await _importFromOcr(target);
  }

  /// 查看数据集全部行。
  void _showFullTable(Dataset ds) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(ds.name),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: _FullTable(dataset: ds),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 附件区：展示归档文件，可导入外部文件并自定义名称。
  Widget _attachmentsSection(Workspace ws) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            _sectionHeader(
              icon: Icons.attach_file,
              title: '工作空间文件（${ws.files.length}）',
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => unawaited(_pickAttachment()),
              icon: const Icon(Icons.upload_file_outlined, size: 17),
              label: const Text('导入文件'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (ws.files.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Center(
                child: Text(
                  '暂无归档文件，可在各工具完成后保存到本工作空间',
                  style: TextStyle(fontSize: 12, color: kNeutralGrey),
                ),
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: <Widget>[
                for (final WorkspaceFile f in ws.files)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      _fileIcon(f.kind),
                      color: kPrimaryColor,
                      size: 20,
                    ),
                    title: Text(
                      f.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${formatFileSize(f.size)} · ${formatDateTime(f.createdAt)}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: IconButton(
                      tooltip: '移除文件',
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: kErrorColor,
                      ),
                      onPressed: () => unawaited(_removeFile(f.id)),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  IconData _fileIcon(String kind) {
    switch (kind) {
      case 'excel':
        return Icons.table_chart_outlined;
      case 'image':
        return Icons.image_outlined;
      case 'json':
        return Icons.data_object_outlined;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}

/// 数据集卡片：标题（可重命名）+ 行数徽标 + 表格预览 + 操作。
class _DatasetCard extends StatelessWidget {
  const _DatasetCard({
    required this.dataset,
    required this.onRename,
    required this.onImport,
    required this.onRemove,
    required this.onViewAll,
  });

  final Dataset dataset;
  final VoidCallback onRename;
  final VoidCallback onImport;
  final VoidCallback onRemove;
  final VoidCallback onViewAll;

  /// 卡片内预览的最大行数。
  static const int previewRows = 8;

  @override
  Widget build(BuildContext context) {
    final int count = dataset.measurements.length;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: InkWell(
                    onTap: onRename,
                    child: Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            dataset.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.edit_outlined,
                          size: 14,
                          color: kNeutralGrey,
                        ),
                      ],
                    ),
                  ),
                ),
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text('$count 行', style: const TextStyle(fontSize: 11)),
                  backgroundColor: kPrimaryLight,
                  labelStyle: const TextStyle(color: kPrimaryColor),
                ),
                IconButton(
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline, color: kErrorColor),
                  tooltip: '删除数据集',
                ),
              ],
            ),
            if (count == 0)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  '暂无数据，点击「导入数据」带入测量行',
                  style: TextStyle(fontSize: 12, color: kNeutralGrey),
                ),
              )
            else ...<Widget>[
              const SizedBox(height: 6),
              _DatasetTable(dataset: dataset, maxRows: previewRows),
              if (count > previewRows)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: onViewAll,
                    child: Text(
                      '查看全部（$count 行）',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: onImport,
                icon: const Icon(Icons.upload_outlined, size: 17),
                label: const Text('导入数据'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 数据集表格预览（横向可滚动，最多 [maxRows] 行）。
class _DatasetTable extends StatelessWidget {
  const _DatasetTable({required this.dataset, required this.maxRows});

  final Dataset dataset;
  final int maxRows;

  @override
  Widget build(BuildContext context) {
    final List<String> columns = dataset.effectiveColumns;
    final List<Measurement> rows = dataset.measurements
        .take(maxRows)
        .toList(growable: false);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 18,
        headingRowHeight: 38,
        dataRowMinHeight: 34,
        dataRowMaxHeight: 44,
        horizontalMargin: 8,
        columns: <DataColumn>[
          for (final String c in columns)
            DataColumn(
              label: Text(
                c,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
        rows: <DataRow>[
          for (final Measurement m in rows)
            DataRow(
              cells: <DataCell>[
                for (final String c in columns) DataCell(_cell(m, c)),
              ],
            ),
        ],
      ),
    );
  }

  /// 单元格文本：优先原始 cells，其次退回 values 中的数值。
  Widget _cell(Measurement m, String column) {
    String text = m.cells[column] ?? '';
    if (text.trim().isEmpty) {
      switch (column) {
        case '时间':
          text = m.label ?? '';
          break;
        case '数据结果':
          text = _num(m.values['value']);
          break;
        case '吸光度':
          text = _num(m.values['absorbance']);
          break;
        case '当前值':
          text = _num(m.values['current']);
          break;
        case '空白值':
          text = _num(m.values['blank']);
          break;
        default:
          text = '';
      }
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Text(
        text.trim().isEmpty ? '—' : text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  String _num(double? v) => v == null ? '' : NumberUtils.format(v);
}

/// 全量表格（对话框内，横竖均可滚动）。
class _FullTable extends StatelessWidget {
  const _FullTable({required this.dataset});

  final Dataset dataset;

  @override
  Widget build(BuildContext context) {
    final List<String> columns = dataset.effectiveColumns;
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 18,
          headingRowHeight: 38,
          dataRowMinHeight: 34,
          dataRowMaxHeight: 44,
          columns: <DataColumn>[
            for (final String c in columns)
              DataColumn(
                label: Text(
                  c,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
          rows: <DataRow>[
            for (final Measurement m in dataset.measurements)
              DataRow(
                cells: <DataCell>[
                  for (final String c in columns)
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(
                          (m.cells[c] ?? '').trim().isEmpty ? '—' : m.cells[c]!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// 行选择对话框：从来源数据集中勾选若干行复制到目标数据集。
class _RowPickerDialog extends StatefulWidget {
  const _RowPickerDialog({required this.dataset});

  final Dataset dataset;

  @override
  State<_RowPickerDialog> createState() => _RowPickerDialogState();
}

class _RowPickerDialogState extends State<_RowPickerDialog> {
  late final List<bool> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List<bool>.filled(widget.dataset.measurements.length, true);
  }

  bool get _allSelected => _selected.every((bool v) => v);

  int get _selectedCount => _selected.where((bool v) => v).length;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('选择数据行（${widget.dataset.name}）'),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: Column(
          children: <Widget>[
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _allSelected,
              title: Text(
                '全选（已选 $_selectedCount / ${_selected.length}）',
                style: const TextStyle(fontSize: 13),
              ),
              onChanged: (bool? on) => setState(() {
                for (int i = 0; i < _selected.length; i++) {
                  _selected[i] = on ?? false;
                }
              }),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: widget.dataset.measurements.length,
                itemBuilder: (BuildContext ctx, int index) {
                  final Measurement m = widget.dataset.measurements[index];
                  return CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _selected[index],
                    title: Text(
                      _rowTitle(m, index),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    onChanged: (bool? on) =>
                        setState(() => _selected[index] = on ?? false),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final List<Measurement> picked = <Measurement>[];
            for (int i = 0; i < _selected.length; i++) {
              if (_selected[i]) picked.add(widget.dataset.measurements[i]);
            }
            Navigator.of(context).pop(picked);
          },
          child: Text('导入 $_selectedCount 行'),
        ),
      ],
    );
  }

  String _rowTitle(Measurement m, int index) {
    final String time = m.label?.trim().isNotEmpty == true
        ? m.label!.trim()
        : (m.cells['时间']?.trim() ?? '');
    final String value =
        m.values['value']?.toString() ?? m.cells['数据结果']?.trim() ?? '';
    final StringBuffer buffer = StringBuffer('第 ${index + 1} 行');
    if (time.isNotEmpty) buffer.write(' · $time');
    if (value.isNotEmpty) buffer.write(' · $value');
    return buffer.toString();
  }
}
