import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../models/report_file.dart';
import '../models/workspace.dart';
import '../providers/workspace_provider.dart';
import '../services/workspace_archive_service.dart';
import 'workspace_picker_sheet.dart';

/// 「保存到工作空间」按钮：生成成果 → 选/建工作空间 → 自定义文件名 → 归档。
///
/// 每个子工具只需提供 [buildFiles]（按需生成待归档文件），
/// 选择工作空间、命名、落盘、登记均由此组件统一处理。
/// [save] 静态方法供 AppBar 等无按钮样式的入口复用同一套流程。
class SaveToWorkspaceButton extends StatefulWidget {
  const SaveToWorkspaceButton({
    super.key,
    required this.buildFiles,
    this.enabled = true,
    this.label = '创建 / 保存到工作空间',
    this.onSaved,
  });

  final Future<List<ReportFile>> Function() buildFiles;
  final bool enabled;
  final String label;
  final void Function(Workspace ws)? onSaved;

  /// 完整归档流程，返回是否成功保存。
  static Future<bool> save(
    BuildContext context, {
    required Future<List<ReportFile>> Function() buildFiles,
    Workspace? workspace,
    void Function(Workspace ws)? onSaved,
  }) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final WorkspaceProvider provider = context.read<WorkspaceProvider>();
    try {
      // 1) 生成待归档文件（由各工具自行实现，可为多文件，如 JSON+PNG+Excel）。
      final List<ReportFile> files = await buildFiles();
      if (files.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('没有可保存的成果，请先完成计算 / 导出')),
        );
        return false;
      }
      if (!context.mounted) return false;

      // 2) 选择或新建工作空间；[workspace] 非空说明调用方已选好，跳过选择器。
      final Workspace? ws =
          workspace ?? await WorkspacePickerSheet.show(context);
      if (ws == null || !context.mounted) return false;

      // 3) 逐个自定义文件名。
      final List<String>? names = await showDialog<List<String>>(
        context: context,
        builder: (_) => _NameDialog(files: files, workspace: ws),
      );
      if (names == null || names.length != files.length) return false;

      // 4) 归档（复制进工作空间文件夹 + 登记 meta.json）。
      final WorkspaceArchiveService archive = WorkspaceArchiveService(
        store: provider.store,
      );
      final Map<String, String> byName = <String, String>{};
      for (int i = 0; i < files.length; i++) {
        byName[names[i]] = files[i].path;
      }
      await archive.archiveAll(
        workspaceId: ws.id,
        sourcePathsByCustomName: byName,
      );
      await provider.refresh();
      onSaved?.call(ws);
      messenger.showSnackBar(
        SnackBar(content: Text('已保存 ${files.length} 个文件到「${ws.displayName}」')),
      );
      return true;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('保存失败：$e')));
      return false;
    }
  }

  @override
  State<SaveToWorkspaceButton> createState() => _SaveToWorkspaceButtonState();
}

class _SaveToWorkspaceButtonState extends State<SaveToWorkspaceButton> {
  bool _busy = false;

  Future<void> _save() async {
    if (_busy || !widget.enabled) return;
    setState(() => _busy = true);
    try {
      await SaveToWorkspaceButton.save(
        context,
        buildFiles: widget.buildFiles,
        onSaved: widget.onSaved,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: (widget.enabled && !_busy) ? _save : null,
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.folder_copy_outlined),
      label: Text(_busy ? '处理中…' : widget.label),
    );
  }
}

/// 文件名自定义对话框：每个待归档文件一行，默认值为建议名。
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.files, required this.workspace});

  final List<ReportFile> files;
  final Workspace workspace;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final List<TextEditingController> _controllers;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controllers = <TextEditingController>[
      for (final ReportFile f in widget.files)
        TextEditingController(text: f.name),
    ];
  }

  @override
  void dispose() {
    for (final TextEditingController c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final List<String> names = _controllers
        .map((TextEditingController c) => c.text.trim())
        .toList();
    if (names.any((String s) => s.isEmpty)) {
      setState(() => _error = '文件名不能为空');
      return;
    }
    if (names.toSet().length != names.length) {
      setState(() => _error = '文件名不能重复');
      return;
    }
    Navigator.of(context).pop(names);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('自定义文件名'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '目标工作空间：${widget.workspace.displayName}',
                style: const TextStyle(fontSize: 12, color: kNeutralGrey),
              ),
              const SizedBox(height: 12),
              for (int i = 0; i < widget.files.length; i++) ...<Widget>[
                TextField(
                  controller: _controllers[i],
                  decoration: InputDecoration(
                    labelText: '文件 ${i + 1}（${widget.files[i].kind}）',
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (_error != null)
                Text(
                  _error!,
                  style: const TextStyle(color: kErrorColor, fontSize: 12),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
