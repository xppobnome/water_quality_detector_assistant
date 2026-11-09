import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../models/standard.dart';
import '../models/workspace.dart';
import '../services/standard_definitions.dart';

/// 新建 / 编辑工作空间 bottom sheet。
///
/// 必填：项目名称；选填：合同编号、项目负责人、其他补充。
/// 检测项目改为下拉选择（[gbItemOptions]），返回值同时携带中文标签 [item]
/// 与参数 id [WorkspaceFields.parameterId]，保证文件夹名保持中文、
/// 国标验证取标准时使用稳定的 id。
///
/// 实时预览按「项目名称-合同编号-项目负责人-检测项目-其他补充」拼接（空段省略）。
/// 取消返回 null。
class WorkspaceCreateSheet extends StatefulWidget {
  const WorkspaceCreateSheet({super.key, this.workspace});

  /// 非空时为编辑态。
  final Workspace? workspace;

  /// 弹出并返回字段结果。
  static Future<WorkspaceFields?> show(
    BuildContext context, {
    Workspace? workspace,
  }) => showModalBottomSheet<WorkspaceFields>(
    context: context,
    isScrollControlled: true,
    builder: (_) => WorkspaceCreateSheet(workspace: workspace),
  );

  @override
  State<WorkspaceCreateSheet> createState() => _WorkspaceCreateSheetState();
}

/// bottom sheet 返回的字段集合。
class WorkspaceFields {
  const WorkspaceFields({
    required this.contractNo,
    required this.projectName,
    required this.owner,
    required this.item,
    required this.remark,
    this.parameterId = 'tp',
  });

  /// 合同编号（选填）。
  final String contractNo;

  /// 项目名称（必填）。
  final String projectName;

  /// 项目负责人（选填）。
  final String owner;

  /// 检测项目中文标签（如「总磷」），用于文件夹名与展示。
  final String item;

  /// 其他补充（选填）。
  final String remark;

  /// 检测项目参数 id（'tp' / 'nh3n' / 'tn' / 'cod'），用于取标准。
  final String parameterId;
}

class _WorkspaceCreateSheetState extends State<WorkspaceCreateSheet> {
  late final TextEditingController _contract;
  late final TextEditingController _project;
  late final TextEditingController _owner;
  late final TextEditingController _remark;

  /// 当前选中的检测项目参数 id。
  late String _parameterId;

  String? _error;

  bool get _editing => widget.workspace != null;

  @override
  void initState() {
    super.initState();
    final Workspace? w = widget.workspace;
    _contract = TextEditingController(text: w?.contractNo ?? '');
    _project = TextEditingController(text: w?.projectName ?? '');
    _owner = TextEditingController(text: w?.owner ?? '');
    _remark = TextEditingController(text: w?.remark ?? '');
    _parameterId = _resolveParameterId(w);
    for (final TextEditingController c in <TextEditingController>[
      _contract,
      _project,
      _owner,
      _remark,
    ]) {
      c.addListener(_rebuild);
    }
  }

  /// 编辑态下推断初始检测项目：优先使用已保存的 parameter id，
  /// 兼容旧数据时退回按 item 文本匹配。
  String _resolveParameterId(Workspace? w) {
    if (w == null) return 'tp';
    final String id = w.parameter.trim();
    if (id.isNotEmpty && standardById(id) != null) return id;
    return gbItemIdOfLabel(w.item);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _contract,
      _project,
      _owner,
      _remark,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 检测项目在拼接名中始终使用中文标签。
  String get _itemLabel => gbItemLabelOfId(_parameterId);

  String get _preview => Workspace.buildName(
    _project.text,
    _contract.text,
    _owner.text,
    _itemLabel,
    _remark.text,
  );

  void _submit() {
    final String project = _project.text.trim();
    if (project.isEmpty) {
      setState(() => _error = '项目名称不能为空');
      return;
    }
    Navigator.of(context).pop(
      WorkspaceFields(
        contractNo: _contract.text.trim(),
        projectName: project,
        owner: _owner.text.trim(),
        item: _itemLabel,
        remark: _remark.text.trim(),
        parameterId: _parameterId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Standard? standard = standardById(_parameterId);
    final bool implemented = standard?.implemented ?? false;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(
                  Icons.create_new_folder_outlined,
                  color: kPrimaryColor,
                ),
                const SizedBox(width: 8),
                Text(
                  _editing ? '编辑工作空间' : '新建工作空间',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _field(_project, '项目名称 *', Icons.business_outlined),
            const SizedBox(height: 12),
            _field(_contract, '合同编号（选填）', Icons.numbers_outlined),
            const SizedBox(height: 12),
            _field(_owner, '项目负责人', Icons.person_outline),
            const SizedBox(height: 12),
            _itemDropdown(),
            const SizedBox(height: 12),
            _field(_remark, '其他补充', Icons.notes_outlined, maxLines: 2),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: appSoftSurface(context),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '文件夹名称预览',
                    style: TextStyle(fontSize: 12, color: kNeutralGrey),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _preview.isEmpty ? '（请填写项目名称）' : _preview,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: kPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '选填字段为空时自动省略该段；编辑后会同步重命名文件夹。',
                    style: TextStyle(fontSize: 11, color: kNeutralGrey),
                  ),
                ],
              ),
            ),
            if (!implemented) ...<Widget>[
              const SizedBox(height: 12),
              _notImplementedTip(),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: kErrorColor, fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.check),
                label: Text(_editing ? '保存修改' : '创建'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 检测项目下拉：value 为参数 id，展示中文标签。
  Widget _itemDropdown() => DropdownButtonFormField<String>(
    initialValue: _parameterId,
    isExpanded: true,
    decoration: const InputDecoration(
      labelText: '检测项目',
      prefixIcon: Icon(Icons.science_outlined, size: 20),
      isDense: true,
      border: OutlineInputBorder(),
    ),
    items: <DropdownMenuItem<String>>[
      for (final GbItemOption option in gbItemOptions)
        DropdownMenuItem<String>(value: option.id, child: Text(option.label)),
    ],
    onChanged: (String? value) {
      if (value == null || value == _parameterId) return;
      setState(() {
        _parameterId = value;
        _error = null;
      });
    },
  );

  /// 未内置标准时的灰色提示条。
  Widget _notImplementedTip() => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: appNeutralSurface(context),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: appHairline(context)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(Icons.info_outline, size: 18, color: kNeutralGrey),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '当前仅内置总磷（HJ 103—2026）标准条款，'
            '$_itemLabel 可先做数据采集与归档，暂不出具合格判定。',
            style: const TextStyle(fontSize: 12, color: kNeutralGrey),
          ),
        ),
      ],
    ),
  );

  Widget _field(
    TextEditingController c,
    String label,
    IconData icon, {
    int maxLines = 1,
  }) => TextField(
    controller: c,
    maxLines: maxLines,
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, size: 20),
      isDense: true,
      border: const OutlineInputBorder(),
    ),
  );
}
