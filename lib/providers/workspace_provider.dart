import 'package:flutter/foundation.dart';

import '../models/trash_entry.dart';
import '../models/workspace.dart';
import '../services/workspace_store.dart';

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
  String _query = '';
  SearchField _field = SearchField.all;
  bool _newestFirst = true;

  List<Workspace> get items => List<Workspace>.unmodifiable(_items);
  List<TrashEntry> get trash => List<TrashEntry>.unmodifiable(_trash);
  bool get loading => _loading;
  String? get error => _error;
  String get query => _query;
  SearchField get field => _field;
  bool get newestFirst => _newestFirst;

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
      final Workspace ws = Workspace(
        name: '草稿空间',
        parameter: 'tp',
        item: '总磷',
        projectName: '',
        contractNo: '',
        isDraft: true,
      );
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

  /// 把草稿标记为「已保存」（写入 savedAt 时间戳）并落盘。
  Future<bool> markSaved(Workspace ws) async {
    try {
      await _store.update(ws.copyWith(savedAt: DateTime.now()));
      await refresh();
      return true;
    } catch (e) {
      _error = '保存失败：$e';
      notifyListeners();
      return false;
    }
  }

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
