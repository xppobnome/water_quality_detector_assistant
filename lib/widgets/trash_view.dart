import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../models/trash_entry.dart';
import '../providers/workspace_provider.dart';
import '../utils/workspace_utils.dart';

/// 回收站 bottom sheet：列出已删除工作空间，可恢复 / 彻底删除。
///
/// 超过 [kTrashRetentionDays] 天的条目在每次加载列表时自动清理。
class TrashView extends StatelessWidget {
  const TrashView({super.key});

  static Future<void> show(BuildContext context) async {
    await context.read<WorkspaceProvider>().refresh();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const TrashView(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final WorkspaceProvider provider = context.watch<WorkspaceProvider>();
    final List<TrashEntry> entries = provider.trash;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.delete_outline, color: kPrimaryColor),
                  const SizedBox(width: 8),
                  const Text(
                    '回收站',
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
              Text(
                '删除的工作空间会进入回收站，超过 $kTrashRetentionDays 天自动清理。',
                style: const TextStyle(fontSize: 12, color: kNeutralGrey),
              ),
              const SizedBox(height: 12),
              if (entries.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text('回收站为空', style: TextStyle(color: kNeutralGrey)),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (BuildContext context, int index) {
                      final TrashEntry e = entries[index];
                      final int daysLeft =
                          kTrashRetentionDays -
                          DateTime.now().difference(e.trashedAt).inDays;
                      return ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.folder_off_outlined,
                          color: kNeutralGrey,
                        ),
                        title: Text(
                          e.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '删除于 ${formatDateTime(e.trashedAt)}'
                          '${daysLeft > 0 ? ' · 剩余 $daysLeft 天' : ' · 即将清理'}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            IconButton(
                              tooltip: '恢复',
                              icon: const Icon(
                                Icons.restore_from_trash_outlined,
                                color: kSuccessColor,
                                size: 20,
                              ),
                              onPressed: () => context
                                  .read<WorkspaceProvider>()
                                  .restore(e.id),
                            ),
                            IconButton(
                              tooltip: '彻底删除',
                              icon: const Icon(
                                Icons.delete_forever_outlined,
                                color: kErrorColor,
                                size: 20,
                              ),
                              onPressed: () => _confirmPurge(context, e),
                            ),
                          ],
                        ),
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

  Future<void> _confirmPurge(BuildContext context, TrashEntry e) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('彻底删除'),
        content: Text('「${e.name}」将被永久删除，无法恢复。确定继续？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kErrorColor),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<WorkspaceProvider>().purge(e.id);
    }
  }
}
