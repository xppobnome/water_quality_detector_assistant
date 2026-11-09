import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../models/standard.dart';
import '../models/workspace.dart';
import '../providers/workspace_provider.dart';
import '../services/standard_definitions.dart';
import '../services/workspace_store.dart';
import '../utils/workspace_utils.dart';
import '../widgets/trash_view.dart';
import '../widgets/workspace_create_sheet.dart';
import 'verification/workspace_detail_page.dart';

/// 展示标题：拼接名里的检测项目段按当前 `parameter` 实时渲染。
///
/// 切换检测项目只改 `parameter`、不改 `item`（避免重命名物理文件夹），
/// 因此 `Workspace.displayName` 里可能残留旧标签，列表卡片一律走本函数。
/// 存量自由文本检测项目（如「总磷(TP)」且 parameter 一致）保持原文不变。
String _workspaceTitle(Workspace ws) {
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

/// 工作空间页（左侧 tab）：增删改查 / 排序 / 模糊搜索 / 检测项目筛选 / 回收站。
///
/// 页面顶部恒有一张「草稿空间」卡片（存在草稿时），其余工作空间按拼接名
/// 「项目名称-合同编号-项目负责人-检测项目-其他补充」落到磁盘文件夹。
class WorkspacesPage extends StatefulWidget {
  const WorkspacesPage({super.key});

  @override
  State<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<WorkspacesPage> {
  final TextEditingController _search = TextEditingController();

  /// 检测项目筛选：null 表示「全部」。
  String? _parameterFilter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<WorkspaceProvider>().load();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// 新建工作空间：检测项目下拉直接给参数 id，无需再按文本推断。
  Future<void> _create() async {
    final WorkspaceFields? fields = await WorkspaceCreateSheet.show(context);
    if (fields == null || !mounted) return;
    final Workspace? ws = await context.read<WorkspaceProvider>().create(
      contractNo: fields.contractNo,
      projectName: fields.projectName,
      owner: fields.owner,
      item: fields.item,
      remark: fields.remark,
      parameter: fields.parameterId,
    );
    if (ws != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已创建「${ws.displayName}」')));
    }
  }

  /// 新建（或复用）草稿空间并直接进入详情页。
  Future<void> _createDraft() async {
    final Workspace? ws = await context.read<WorkspaceProvider>().createDraft();
    if (ws == null || !mounted) return;
    await _open(ws);
  }

  Future<void> _edit(Workspace ws) async {
    final WorkspaceFields? fields = await WorkspaceCreateSheet.show(
      context,
      workspace: ws,
    );
    if (fields == null || !mounted) return;
    final bool ok = await context.read<WorkspaceProvider>().update(
      ws.copyWith(
        contractNo: fields.contractNo,
        projectName: fields.projectName,
        owner: fields.owner,
        item: fields.item,
        remark: fields.remark,
        parameter: fields.parameterId,
        name: Workspace.buildName(
          fields.projectName,
          fields.contractNo,
          fields.owner,
          fields.item,
          fields.remark,
        ),
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '已保存并同步重命名文件夹' : '保存失败，请检查文件夹是否被占用')),
    );
  }

  Future<void> _delete(Workspace ws) async {
    final bool isDraft = ws.isDraft;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(isDraft ? '删除草稿空间' : '删除工作空间'),
        content: Text(
          isDraft
              ? '草稿空间内容将被移入回收站，$kTrashRetentionDays 天后自动清理。'
              : '「${ws.displayName.isNotEmpty ? ws.displayName : ws.name}」'
                    '将被移入回收站，$kTrashRetentionDays 天后自动清理，期间可恢复。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kErrorColor),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('移入回收站'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<WorkspaceProvider>().delete(ws.id);
    }
  }

  Future<void> _open(Workspace ws) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => WorkspaceDetailPage(workspaceId: ws.id),
      ),
    );
    if (mounted) await context.read<WorkspaceProvider>().refresh();
  }

  /// 客户端按检测项目过滤（不改 Store 查询）。
  bool _matchesFilter(Workspace ws) {
    final String? filter = _parameterFilter;
    if (filter == null) return true;
    return ws.parameter == filter;
  }

  @override
  Widget build(BuildContext context) {
    final WorkspaceProvider provider = context.watch<WorkspaceProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('工作空间'),
        actions: <Widget>[
          IconButton(
            tooltip: provider.newestFirst ? '当前：创建时间倒序' : '当前：创建时间正序',
            icon: Icon(
              provider.newestFirst ? Icons.arrow_downward : Icons.arrow_upward,
            ),
            onPressed: () => context.read<WorkspaceProvider>().toggleSort(),
          ),
          IconButton(
            tooltip: '回收站',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => TrashView.show(context),
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('新建工作空间'),
      ),
      body: Column(
        children: <Widget>[
          _buildSearchBar(provider),
          if (provider.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: kErrorColor.withValues(alpha: 0.08),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.error_outline, color: kErrorColor, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      provider.error!,
                      style: const TextStyle(color: kErrorColor, fontSize: 12),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => context.read<WorkspaceProvider>().clearError(),
                    child: const Icon(
                      Icons.close,
                      color: kErrorColor,
                      size: 16,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(child: _buildList(provider)),
        ],
      ),
    );
  }

  Widget _buildSearchBar(WorkspaceProvider provider) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: _search,
            decoration: InputDecoration(
              hintText: '搜索项目 / 合同 / 负责人 / 检测项目 / 备注',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _search.clear();
                        context.read<WorkspaceProvider>().setQuery('');
                      },
                    ),
            ),
            onChanged: (String v) =>
                context.read<WorkspaceProvider>().setQuery(v),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<SearchField>(
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStateProperty.all(
                  const TextStyle(fontSize: 12),
                ),
              ),
              segments: const <ButtonSegment<SearchField>>[
                ButtonSegment<SearchField>(
                  value: SearchField.all,
                  label: Text('全部信息'),
                ),
                ButtonSegment<SearchField>(
                  value: SearchField.contractNo,
                  label: Text('合同编号'),
                ),
                ButtonSegment<SearchField>(
                  value: SearchField.projectName,
                  label: Text('项目名称'),
                ),
              ],
              selected: <SearchField>{provider.field},
              onSelectionChanged: (Set<SearchField> s) =>
                  context.read<WorkspaceProvider>().setField(s.first),
            ),
          ),
          const SizedBox(height: 6),
          _buildParameterFilter(),
        ],
      ),
    );
  }

  /// 检测项目筛选行：全部 / 总磷 / 氨氮 / 总氮 / COD。
  Widget _buildParameterFilter() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          FilterChip(
            label: const Text('全部', style: TextStyle(fontSize: 12)),
            selected: _parameterFilter == null,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => setState(() => _parameterFilter = null),
          ),
          for (final GbItemOption option in gbItemOptions) ...<Widget>[
            const SizedBox(width: 6),
            FilterChip(
              label: Text(option.label, style: const TextStyle(fontSize: 12)),
              selected: _parameterFilter == option.id,
              visualDensity: VisualDensity.compact,
              onSelected: (bool on) =>
                  setState(() => _parameterFilter = on ? option.id : null),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildList(WorkspaceProvider provider) {
    if (provider.loading && provider.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.items.isEmpty) {
      return _emptyState(provider);
    }

    Workspace? draft;
    final List<Workspace> others = <Workspace>[];
    for (final Workspace ws in provider.items) {
      if (ws.isDraft) {
        draft ??= ws;
      } else {
        others.add(ws);
      }
    }
    final List<Workspace> visible = others
        .where((Workspace w) => _matchesFilter(w))
        .toList();

    return RefreshIndicator(
      onRefresh: () => context.read<WorkspaceProvider>().refresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
        children: <Widget>[
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _createDraft,
              icon: const Icon(Icons.edit_note_outlined, size: 16),
              label: Text(
                draft == null ? '新建草稿' : '继续编辑草稿',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          if (draft != null)
            _DraftCard(
              workspace: draft,
              onOpen: () => _open(draft!),
              onDelete: () => _delete(draft!),
            ),
          if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  '当前筛选条件下暂无工作空间',
                  style: TextStyle(color: kNeutralGrey, fontSize: 12),
                ),
              ),
            )
          else
            for (final Workspace ws in visible)
              _WorkspaceCard(
                workspace: ws,
                onOpen: () => _open(ws),
                onEdit: () => _edit(ws),
                onDelete: () => _delete(ws),
              ),
        ],
      ),
    );
  }

  Widget _emptyState(WorkspaceProvider provider) {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.folder_open_outlined,
              size: 64,
              color: kNeutralGrey,
            ),
            const SizedBox(height: 16),
            Text(
              provider.query.isEmpty ? '暂无工作空间' : '没有匹配的工作空间',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              '工作空间用于归档各工具产生的文件，按合同 / 项目分文件夹管理',
              style: TextStyle(color: kNeutralGrey, fontSize: 12),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('新建工作空间'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _createDraft,
              icon: const Icon(Icons.edit_note_outlined),
              label: const Text('新建草稿'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 草稿空间卡片（恒置顶）。
class _DraftCard extends StatelessWidget {
  const _DraftCard({
    required this.workspace,
    required this.onOpen,
    required this.onDelete,
  });

  final Workspace workspace;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final bool unsaved = workspace.isUnsaved;
    final int measurementCount = workspace.datasets.fold<int>(
      0,
      (int sum, Dataset d) => sum + d.measurements.length,
    );
    final bool empty =
        workspace.datasets.isEmpty &&
        workspace.sessions.isEmpty &&
        workspace.files.isEmpty;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: unsaved ? kWarningColor.withValues(alpha: 0.5) : kSuccessColor,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: kPrimaryLight,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.edit_note_outlined,
                    color: kPrimaryColor,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '草稿空间',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: kPrimaryColor,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '临时工作空间 · 内容随时保存',
                        style: TextStyle(fontSize: 11, color: kNeutralGrey),
                      ),
                    ],
                  ),
                ),
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    unsaved ? '未保存' : '已保存',
                    style: const TextStyle(fontSize: 11),
                  ),
                  backgroundColor: unsaved
                      ? kErrorColor.withValues(alpha: 0.1)
                      : kSuccessColor.withValues(alpha: 0.1),
                  labelStyle: TextStyle(
                    color: unsaved ? kErrorColor : kSuccessColor,
                  ),
                  side: BorderSide(
                    color: unsaved
                        ? kErrorColor.withValues(alpha: 0.4)
                        : kSuccessColor.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '数据集 ${workspace.datasets.length}　测量 $measurementCount　'
              '计算 ${workspace.sessions.length}　附件 ${workspace.files.length}',
              style: const TextStyle(fontSize: 11, color: kNeutralGrey),
            ),
            if (empty)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '草稿空间还没有内容，进入后导入测量数据即可',
                  style: TextStyle(fontSize: 12, color: kWarningColor),
                ),
              ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 17),
                  label: const Text('删除'),
                  style: TextButton.styleFrom(foregroundColor: kErrorColor),
                ),
                const SizedBox(width: 4),
                FilledButton.icon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.play_arrow_outlined, size: 17),
                  label: const Text('继续编辑'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({
    required this.workspace,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final Workspace workspace;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final String title = _workspaceTitle(workspace);
    final int measurementCount = workspace.datasets.fold<int>(
      0,
      (int sum, Dataset d) => sum + d.measurements.length,
    );
    final Standard? standard = standardById(workspace.parameter);
    final bool implemented = standard?.implemented ?? false;
    final String itemLabel = gbItemLabelOfId(workspace.parameter);

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
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: kPrimaryLight,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.folder_outlined,
                    color: kPrimaryColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: kPrimaryColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                if (workspace.contractNo.isNotEmpty)
                  _chip(Icons.numbers_outlined, '合同：${workspace.contractNo}'),
                if (workspace.projectName.isNotEmpty)
                  _chip(Icons.business_outlined, '项目：${workspace.projectName}'),
                if (workspace.owner.isNotEmpty)
                  _chip(Icons.person_outline, '负责人：${workspace.owner}'),
                _chip(Icons.science_outlined, '检测：$itemLabel'),
                if (workspace.remark.isNotEmpty)
                  _chip(Icons.notes_outlined, '备注：${workspace.remark}'),
                if (!implemented) _notImplementedChip(),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '标准参数：$itemLabel　'
              '数据集 ${workspace.datasets.length}　测量 $measurementCount　'
              '附件 ${workspace.files.length}',
              style: const TextStyle(fontSize: 11, color: kNeutralGrey),
            ),
            Text(
              '创建：${formatDateTime(workspace.createdAt)}　'
              '文件夹：${workspace.folderName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: kNeutralGrey),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 17),
                  label: const Text('删除'),
                  style: TextButton.styleFrom(foregroundColor: kErrorColor),
                ),
                TextButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  label: const Text('编辑'),
                ),
                const SizedBox(width: 4),
                FilledButton.icon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.open_in_new, size: 17),
                  label: const Text('打开'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 「标准未内置」灰色小标记。
  Widget _notImplementedChip() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xFFF5F5F5),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: const Color(0xFFE0E0E0)),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.info_outline, size: 13, color: kNeutralGrey),
        SizedBox(width: 4),
        Text('标准未内置', style: TextStyle(fontSize: 11, color: Color(0xFF757575))),
      ],
    ),
  );

  Widget _chip(IconData icon, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: kPrimaryLight.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 13, color: kPrimaryColor),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 11, color: kPrimaryColor)),
      ],
    ),
  );
}
