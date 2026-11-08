import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../models/workspace.dart';
import '../providers/workspace_provider.dart';
import '../utils/workspace_utils.dart';
import 'workspace_create_sheet.dart';

/// 工作空间选择 bottom sheet：选已有 / 直接新建一个。
///
/// 各子工具「保存到工作空间」统一由此选择目标；返回 null 表示用户取消。
class WorkspacePickerSheet extends StatelessWidget {
  const WorkspacePickerSheet({super.key});

  static Future<Workspace?> show(BuildContext context) async {
    final WorkspaceProvider provider = context.read<WorkspaceProvider>();
    await provider.refresh();
    if (!context.mounted) return null;
    return showModalBottomSheet<Workspace>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const WorkspacePickerSheet(),
    );
  }

  /// 直接新建工作空间并返回创建结果。
  ///
  /// 供「工具执行完成后」的归档提示复用，避免用户先选工作空间再创建。
  static Future<Workspace?> createNew(BuildContext context) async {
    final WorkspaceFields? fields = await WorkspaceCreateSheet.show(context);
    if (fields == null || !context.mounted) return null;
    return context.read<WorkspaceProvider>().create(
      contractNo: fields.contractNo,
      projectName: fields.projectName,
      owner: fields.owner,
      item: fields.item,
      remark: fields.remark,
      parameter: fields.parameterId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final WorkspaceProvider provider = context.watch<WorkspaceProvider>();
    final List<Workspace> items = provider.items;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.folder_copy_outlined, color: kPrimaryColor),
                  const SizedBox(width: 8),
                  const Text(
                    '选择工作空间',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                '成果文件将以自定义文件名保存到所选工作空间文件夹中。',
                style: TextStyle(fontSize: 12, color: kNeutralGrey),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                tileColor: kPrimaryLight,
                leading: const Icon(
                  Icons.create_new_folder_outlined,
                  color: kPrimaryColor,
                ),
                title: const Text(
                  '新建工作空间',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: kPrimaryColor,
                  ),
                ),
                subtitle: const Text(
                  '按合同编号 / 项目名称创建文件夹',
                  style: TextStyle(fontSize: 11),
                ),
                trailing: const Icon(Icons.chevron_right, color: kPrimaryColor),
                onTap: () => _create(context),
              ),
              const SizedBox(height: 6),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                leading: const Icon(
                  Icons.edit_note_outlined,
                  color: kWarningColor,
                ),
                title: const Text(
                  '新建草稿',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: kWarningColor,
                  ),
                ),
                subtitle: const Text(
                  '临时工作空间，无需填写表单，内容随时保存',
                  style: TextStyle(fontSize: 11),
                ),
                trailing: const Icon(Icons.chevron_right, color: kWarningColor),
                onTap: () => _createDraft(context),
              ),
              const SizedBox(height: 8),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: Text(
                      '暂无工作空间，可点击上方新建',
                      style: TextStyle(color: kNeutralGrey),
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (BuildContext context, int index) {
                      final Workspace ws = items[index];
                      return ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.folder_outlined,
                          color: kPrimaryColor,
                        ),
                        title: Text(
                          ws.displayName.isNotEmpty ? ws.displayName : ws.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${formatDateTime(ws.createdAt)} · 附件 ${ws.files.length}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        onTap: () => Navigator.of(context).pop(ws),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _create(BuildContext context) async {
    final Workspace? ws = await createNew(context);
    if (ws != null && context.mounted) Navigator.of(context).pop(ws);
  }

  /// 新建（或复用）草稿空间并直接返回，进入详情页后即可导入数据。
  Future<void> _createDraft(BuildContext context) async {
    final Workspace? ws = await context.read<WorkspaceProvider>().createDraft();
    if (ws != null && context.mounted) Navigator.of(context).pop(ws);
  }
}
