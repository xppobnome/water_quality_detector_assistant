import 'package:flutter/foundation.dart';

import '../models/trash_entry.dart';
import '../models/workspace.dart';
import '../services/standard_definitions.dart';
import '../services/workspace_store.dart';
import '../utils/workspace_utils.dart';

/// 工作空间状态：CRUD / 搜索 / 排序 / 回收站。
///
/// 所有页面经此 Provider 访问 [WorkspaceStore]，禁止 widget 直调 service
/// （归档服务 [WorkspaceArchiveService] 除外，它由按钮封装调用）。
class WorkspaceProvider extends ChangeNotifier {
  WorkspaceProvider({WorkspaceStore? store})
    : _store = store ?? WorkspaceStore();

  final WorkspaceStore _store;

  WorkspaceStore get store => _store;

  List<Workspace> _items = <Workspace>[];
  List<TrashEntry> _trash = <TrashEntry>[];
  bool _loading = false;
  String? _error;

  /// 「已成功但需提醒用户」的警告（如草稿已归档但草稿位重置失败）。
  ///
  /// 与 [error] 分开：结果整体成功，UI 应以警告样式提示并自行调用
  /// [clearWarning] 清空，避免下一次保存误读。
  String? _lastWarning;
  String _query = '';
  SearchField _field = SearchField.all;
  bool _newestFirst = true;

  List<Workspace> get items => List<Workspace>.unmodifiable(_items);
  List<TrashEntry> get trash => List<TrashEntry>.unmodifiable(_trash);
  bool get loading => _loading;
  String? get error => _error;
  String? get lastWarning => _lastWarning;
  String get query => _query;
  SearchField get field => _field;
  bool get newestFirst => _newestFirst;

  /// 清空一次性警告（UI 读完即调）。
  void clearWarning() {
    _lastWarning = null;
    notifyListeners();
  }

  /// 首次加载：迁移旧数据 + 清理过期回收站 + 拉列表。
  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await _store.migrateLegacyIfNeeded();
      await _store.purgeExpiredTrash();
      await refresh();
    } catch (e) {
      _error = '加载工作空间失败：$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    try {
      _items = await _store.list(
        query: _query,
        field: _field,
        newestFirst: _newestFirst,
      );
      _trash = await _store.listTrash();
    } catch (e) {
      _error = '刷新失败：$e';
    }
    notifyListeners();
  }

  void setQuery(String q) {
    _query = q;
    refresh();
  }

  void setField(SearchField f) {
    _field = f;
    refresh();
  }

  void toggleSort() {
    _newestFirst = !_newestFirst;
    refresh();
  }

  /// 新建工作空间（仅「项目名称」必填；合同编号改为选填）。
  ///
  /// [item] 传检测项目中文标签（用于文件夹名与展示），[parameter] 传参数 id
  /// （用于取国标标准），两者由调用方保持一致。
  /// [isDraft] 为 true 时创建「草稿空间」（无需填写表单即可落盘）。
  Future<Workspace?> create({
    String contractNo = '',
    required String projectName,
    String owner = '',
    String item = '',
    String remark = '',
    String parameter = 'custom',
    bool isDraft = false,
  }) async {
    final String c = contractNo.trim();
    final String p = projectName.trim();
    final String param = parameter.trim().isEmpty ? 'custom' : parameter.trim();
    if (!isDraft && p.isEmpty) {
      _error = '项目名称不能为空';
      notifyListeners();
      return null;
    }
    final String display = Workspace.buildName(p, c, owner, item, remark);
    final Workspace ws = Workspace(
      name: display.isEmpty ? (isDraft ? '草稿空间' : '未命名工作空间') : display,
      parameter: param,
      contractNo: c,
      projectName: p,
      owner: owner.trim(),
      item: item.trim(),
      remark: remark.trim(),
      isDraft: isDraft,
    );
    try {
      await _store.create(ws);
      await refresh();
      return ws;
    } catch (e) {
      _error = '创建失败：$e';
      notifyListeners();
      return null;
    }
  }

  /// 创建（或复用）唯一的「草稿空间」。
  ///
  /// 草稿空间只允许存在一个：已存在时直接返回已有草稿，不重复建目录。
  Future<Workspace?> createDraft() async {
    Workspace? existing = _findDraft();
    if (existing == null) {
      // 列表可能尚未加载（例如从工具页直接进入），先刷新一次再判断。
      await refresh();
      existing = _findDraft();
    }
    if (existing != null) return existing;
    try {
      final Workspace ws = _emptyDraft();
      await _store.create(ws);
      await refresh();
      return ws;
    } catch (e) {
      _error = '创建草稿空间失败：$e';
      notifyListeners();
      return null;
    }
  }

  /// 当前的草稿空间；不存在返回 null。
  Workspace? draftWorkspace() => _findDraft();

  /// 当前列表中是否存在草稿空间。
  bool get hasDraft => _findDraft() != null;

  Workspace? _findDraft() {
    for (final Workspace w in _items) {
      if (w.isDraft) return w;
    }
    return null;
  }

  /// 把工作空间标记为「已保存」。
  ///
  /// - **非草稿**：仅写入 [Workspace.savedAt] 时间戳后落盘（行为与旧版一致）。
  /// - **草稿（有内容）**：先把当前内容**归档成一份正常工作空间**——沿用同一
  ///   id，因此 `WorkspaceStore.update` 会把物理文件夹按新拼接名重命名，附件
  ///   随目录整体搬迁，数据集 / 计算记录 / 限值覆盖全部保留；**归档写盘成功后**
  ///   再重建一个空草稿，让草稿位回到空态等待下次使用。任意一步失败都保留
  ///   原草稿不动（不回滚数据、不丢数据）。
  /// - **草稿（无内容）**：没有归档价值，只打保存标记。
  ///
  /// **幂等**：始终以磁盘上的当前对象为准（保存可能被重复触发，第二次拿到的
  /// `ws` 已是陈旧快照）。若该 id 已不存在或已不是草稿，说明归档已由前一次
  /// 调用完成——直接短路返回，不会再 `update` / 再 `create`，避免产生第二个
  /// 空草稿。
  Future<bool> markSaved(Workspace ws) async {
    final DateTime now = DateTime.now();
    if (!ws.isDraft) {
      return _stampSaved(ws, now);
    }

    Workspace? current;
    try {
      current = await _store.get(ws.id);
    } catch (e) {
      _error = '读取工作空间失败：$e';
      notifyListeners();
      return false;
    }
    // 已被另一次保存归档（或已删除）：幂等短路，不重复归档/建草稿。
    if (current == null || !current.isDraft) {
      await refresh();
      return true;
    }
    if (!hasContent(current)) {
      return _stampSaved(current, now);
    }

    // 1) 归档：去掉草稿标记 + 生成可读名称（草稿原本没有项目名称）。
    //    检测项目取**当前 parameter 的实时标签**：草稿切过项目时 `item`
    //    可能还是旧标签，归档这一刻按 parameter 落名才不会与界面不一致
    //    （草稿目录本来就要重命名，不存在外部引用问题）。
    final String itemLabel = gbItemLabelOfId(
      current.parameter,
      fallback: current.item.trim().isEmpty ? '总磷' : current.item.trim(),
    );
    final String archivedProject = '草稿归档 ${formatDateTime(now)}';
    final Workspace archived = current.copyWith(
      isDraft: false,
      savedAt: now,
      projectName: archivedProject,
      item: itemLabel,
      name: Workspace.buildName(
        archivedProject,
        current.contractNo,
        current.owner,
        itemLabel,
        current.remark,
      ),
    );
    try {
      await _store.update(archived);
    } catch (e) {
      _error = '归档失败，草稿内容未改动：$e';
      notifyListeners();
      return false;
    }

    // 2) 清空草稿位：仅在归档成功后重建空草稿。
    try {
      await _store.create(_emptyDraft());
    } catch (e) {
      // 归档已经落盘（数据安全），只是草稿位没重建成功，如实提示。
      final String warning = '草稿已归档为「$archivedProject」，但草稿位重置失败：$e';
      _error = warning;
      _lastWarning = warning;
      await refresh();
      notifyListeners();
      return true;
    }
    await refresh();
    return true;
  }

  /// 是否有实质内容（数据集里有数据行、有计算记录或有附件）。
  ///
  /// 详情页据此判断草稿保存时是「归档 + 清空」还是「仅打保存标记」。
  bool hasContent(Workspace ws) =>
      ws.sessions.isNotEmpty ||
      ws.files.isNotEmpty ||
      ws.datasets.any((Dataset d) => d.measurements.isNotEmpty);

  /// 仅写入 savedAt 并落盘。
  Future<bool> _stampSaved(Workspace ws, DateTime now) async {
    try {
      await _store.update(ws.copyWith(savedAt: now));
      await refresh();
      return true;
    } catch (e) {
      _error = '保存失败：$e';
      notifyListeners();
      return false;
    }
  }

  /// 空白草稿（固定名称与默认检测项目，草稿文件夹名恒为「草稿空间」）。
  Workspace _emptyDraft() => Workspace(
    name: '草稿空间',
    parameter: 'tp',
    item: '总磷',
    projectName: '',
    contractNo: '',
    isDraft: true,
  );

  /// 编辑（字段变化会触发物理文件夹重命名）。
  Future<bool> update(Workspace ws) async {
    try {
      await _store.update(ws);
      await refresh();
      return true;
    } catch (e) {
      _error = '保存失败（可能是文件夹重命名冲突）：$e';
      notifyListeners();
      return false;
    }
  }

  Future<void> delete(String id) async {
    try {
      await _store.delete(id);
      await refresh();
    } catch (e) {
      _error = '删除失败：$e';
      notifyListeners();
    }
  }

  Future<void> restore(String id) async {
    try {
      await _store.restore(id);
      await refresh();
    } catch (e) {
      _error = '恢复失败：$e';
      notifyListeners();
    }
  }

  Future<void> purge(String id) async {
    try {
      await _store.deletePermanent(id);
      await refresh();
    } catch (e) {
      _error = '清理失败：$e';
      notifyListeners();
    }
  }

  Future<Workspace?> get(String id) => _store.get(id);

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
