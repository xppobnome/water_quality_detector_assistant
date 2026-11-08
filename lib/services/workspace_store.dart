import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../models/trash_entry.dart';
import '../models/workspace.dart';

/// 工作空间搜索字段。
enum SearchField { all, contractNo, projectName }

/// 工作空间持久化（增量 v2）：每个工作空间 = 一个真实文件夹。
///
/// 目录结构：
/// ```
/// documents/
/// ├── workspaces/<拼接名>/meta.json + 附件
/// └── trash/trash_index.json + trash/<id>/（移入的原文件夹）
/// ```
/// 兼容旧版 `workspaces/<id>.json`（[migrateLegacyIfNeeded] 幂等迁移）。
/// 同时保留旧 API [list]/[get]/[save]/[delete] 供国标验证页复用。
class WorkspaceStore {
  WorkspaceStore();

  Directory? _workspacesDir;
  Directory? _trashDir;
  bool _migrated = false;

  Future<Directory> get _dir async {
    if (_workspacesDir != null && await _workspacesDir!.exists()) {
      return _workspacesDir!;
    }
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(p.join(base.path, 'workspaces'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _workspacesDir = dir;
    return dir;
  }

  Future<Directory> get _trash async {
    if (_trashDir != null && await _trashDir!.exists()) return _trashDir!;
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(p.join(base.path, 'trash'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _trashDir = dir;
    return dir;
  }

  Future<File> get _trashIndex async {
    final Directory dir = await _trash;
    return File(p.join(dir.path, 'trash_index.json'));
  }

  // ---------------------------------------------------------------- 迁移

  /// 旧 `<id>.json` → 文件夹 + meta.json，幂等；迁移成功后删除旧文件。
  Future<void> migrateLegacyIfNeeded() async {
    if (_migrated) return;
    final Directory dir = await _dir;
    final List<File> legacy = dir
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.json'))
        .toList();
    for (final File f in legacy) {
      try {
        final Map<String, dynamic> json =
            jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final Workspace ws = Workspace.fromJson(json);
        final Directory target = await _uniqueDir(dir, _safeFolder(ws), ws.id);
        await _writeMeta(target, ws);
        await f.delete();
      } catch (_) {
        // 损坏文件跳过，不阻断迁移。
      }
    }
    _migrated = true;
  }

  // ---------------------------------------------------------------- 查询

  /// 列出工作空间（默认按创建时间倒序）；[query] 为空返回全部。
  Future<List<Workspace>> list({
    String? query,
    SearchField field = SearchField.all,
    bool newestFirst = true,
    bool includeTrashed = false,
  }) async {
    await migrateLegacyIfNeeded();
    await purgeExpiredTrash();
    final Directory dir = await _dir;
    final List<Workspace> result = <Workspace>[];
    for (final FileSystemEntity e in dir.listSync().whereType<Directory>()) {
      final Workspace? ws = await _readMeta(e as Directory);
      if (ws != null) result.add(ws);
    }
    if (includeTrashed) {
      final Directory trash = await _trash;
      for (final FileSystemEntity e
          in trash.listSync().whereType<Directory>()) {
        final Workspace? ws = await _readMeta(e as Directory);
        if (ws != null) result.add(ws);
      }
    }
    // 排序：草稿空间恒置顶，其余按创建时间正/倒序。
    result.sort((Workspace a, Workspace b) {
      if (a.isDraft != b.isDraft) return a.isDraft ? -1 : 1;
      return newestFirst
          ? b.createdAt.compareTo(a.createdAt)
          : a.createdAt.compareTo(b.createdAt);
    });
    final String q = (query ?? '').trim().toLowerCase();
    if (q.isEmpty) return result;
    return result.where((Workspace w) => _matches(w, q, field)).toList();
  }

  bool _matches(Workspace w, String q, SearchField field) {
    switch (field) {
      case SearchField.contractNo:
        return w.contractNo.toLowerCase().contains(q);
      case SearchField.projectName:
        return w.projectName.toLowerCase().contains(q);
      case SearchField.all:
        return <String>[
          w.name,
          w.displayName,
          w.contractNo,
          w.projectName,
          w.owner,
          w.item,
          w.remark,
          w.parameter,
        ].any((String s) => s.toLowerCase().contains(q));
    }
  }

  /// 按 id 取工作空间；不存在返回 null。
  Future<Workspace?> get(String id) async {
    await migrateLegacyIfNeeded();
    final Directory dir = await _dir;
    for (final FileSystemEntity e in dir.listSync().whereType<Directory>()) {
      final Workspace? ws = await _readMeta(e as Directory);
      if (ws != null && ws.id == id) return ws;
    }
    return null;
  }

  /// 按 id 找其物理文件夹；不存在返回 null。
  Future<Directory?> _dirOf(String id) async {
    final Directory dir = await _dir;
    for (final Directory e in dir.listSync().whereType<Directory>()) {
      final Workspace? ws = await _readMeta(e);
      if (ws != null && ws.id == id) return e;
    }
    return null;
  }

  // ---------------------------------------------------------------- 写入

  /// 新建工作空间：建文件夹（sanitize + 防冲突）+ meta.json，返回落盘后的对象。
  Future<Workspace> create(Workspace ws) async {
    await migrateLegacyIfNeeded();
    final Directory dir = await _dir;
    final Directory target = await _uniqueDir(dir, _safeFolder(ws), ws.id);
    await _writeMeta(target, ws);
    return ws;
  }

  /// 更新 meta.json；若拼接名变化则同步重命名物理文件夹（冲突追加 id 前 6 位，失败回滚）。
  Future<void> update(Workspace ws) async {
    await migrateLegacyIfNeeded();
    final Directory? current = await _dirOf(ws.id);
    if (current == null) {
      await create(ws);
      return;
    }
    final Workspace? old = await _readMeta(current);
    final String desired = _safeFolder(ws);
    final String currentName = p.basename(current.path);
    if (old == null || desired == currentName) {
      await _writeMeta(current, ws);
      return;
    }

    // 目标已存在（且不是自己）→ 追加 _<id前6位>。
    String newName = desired;
    Directory candidate = Directory(p.join(current.parent.path, newName));
    if (await candidate.exists()) {
      newName =
          '${desired}_${ws.id.substring(0, ws.id.length >= 6 ? 6 : ws.id.length)}';
      candidate = Directory(p.join(current.parent.path, newName));
    }
    try {
      final Directory renamed = await current.rename(candidate.path);
      await _writeMeta(renamed, ws);
    } catch (_) {
      // 回滚：写回旧元数据，保证不残留半写状态。
      if (await current.exists()) await _writeMeta(current, old);
      rethrow;
    }
  }

  /// 兼容旧 API：存在则 [update]，不存在则 [create]。
  Future<void> save(Workspace ws) async {
    final Directory? existing = await _dirOf(ws.id);
    if (existing == null) {
      await create(ws);
    } else {
      await update(ws);
    }
  }

  /// 删除 = 移入回收站（连同附件整体移动）+ 登记索引。
  Future<void> delete(String id) async {
    await migrateLegacyIfNeeded();
    final Directory? current = await _dirOf(id);
    if (current == null) return;
    final Workspace? ws = await _readMeta(current);
    final Directory trash = await _trash;
    final Directory dest = Directory(p.join(trash.path, id));
    if (await dest.exists()) await dest.delete(recursive: true);
    await current.rename(dest.path);

    final List<TrashEntry> entries = await listTrash();
    entries.removeWhere((TrashEntry e) => e.id == id);
    entries.add(
      TrashEntry(
        id: id,
        name: (ws?.displayName.isNotEmpty ?? false)
            ? ws!.displayName
            : (ws?.name ?? id),
        folderName: p.basename(current.path),
        trashedAt: DateTime.now(),
      ),
    );
    await _writeTrashIndex(entries);
  }

  /// 兼容旧 API：同 [delete]。
  Future<void> deletePermanent(String id) async {
    final Directory trash = await _trash;
    final Directory target = Directory(p.join(trash.path, id));
    if (await target.exists()) await target.delete(recursive: true);
    final List<TrashEntry> entries = await listTrash();
    entries.removeWhere((TrashEntry e) => e.id == id);
    await _writeTrashIndex(entries);
  }

  /// 从回收站恢复工作空间文件夹。
  Future<void> restore(String id) async {
    final Directory trash = await _trash;
    final Directory source = Directory(p.join(trash.path, id));
    if (!await source.exists()) return;
    final Directory dir = await _dir;
    final List<TrashEntry> entries = await listTrash();
    TrashEntry? entry;
    for (final TrashEntry e in entries) {
      if (e.id == id) {
        entry = e;
        break;
      }
    }
    String targetName = entry?.folderName ?? id;
    if (Directory(p.join(dir.path, targetName)).existsSync()) {
      targetName =
          '${targetName}_${id.substring(0, id.length >= 6 ? 6 : id.length)}';
    }
    await source.rename(p.join(dir.path, targetName));
    entries.removeWhere((TrashEntry e) => e.id == id);
    await _writeTrashIndex(entries);
  }

  /// 回收站条目列表。
  Future<List<TrashEntry>> listTrash() async {
    final File file = await _trashIndex;
    if (!await file.exists()) return <TrashEntry>[];
    try {
      final List<dynamic> raw =
          jsonDecode(await file.readAsString()) as List<dynamic>;
      return raw
          .map((dynamic e) => TrashEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return <TrashEntry>[];
    }
  }

  /// 清理超过 [kTrashRetentionDays] 天的回收站数据。
  Future<void> purgeExpiredTrash() async {
    final List<TrashEntry> entries = await listTrash();
    final DateTime cutoff = DateTime.now().subtract(
      const Duration(days: kTrashRetentionDays),
    );
    final List<TrashEntry> kept = <TrashEntry>[];
    bool changed = false;
    final Directory trash = await _trash;
    for (final TrashEntry e in entries) {
      if (e.trashedAt.isBefore(cutoff)) {
        final Directory d = Directory(p.join(trash.path, e.id));
        if (await d.exists()) await d.delete(recursive: true);
        changed = true;
      } else {
        kept.add(e);
      }
    }
    if (changed) await _writeTrashIndex(kept);
  }

  // ---------------------------------------------------------------- 附件

  /// 把产出文件以自定义名复制进工作空间文件夹，并登记到 meta.json。
  Future<WorkspaceFile> addFile(
    String id,
    String sourcePath, {
    String? customName,
  }) async {
    final Directory? folder = await _dirOf(id);
    if (folder == null) throw Exception('工作空间不存在：$id');
    final File source = File(sourcePath);
    if (!await source.exists()) throw Exception('源文件不存在：$sourcePath');

    final String requested = (customName ?? '').trim();
    String name = sanitizeFileName(
      requested.isEmpty ? p.basename(sourcePath) : requested,
    );
    if (name.isEmpty) name = 'file_${DateTime.now().millisecondsSinceEpoch}';
    final File dest = File(p.join(folder.path, name));
    await source.copy(dest.path);
    final int size = await dest.length();
    final WorkspaceFile wf = WorkspaceFile(
      name: name,
      size: size,
      kind: _kindOf(name),
    );

    final Workspace? ws = await _readMeta(folder);
    if (ws != null) {
      final List<WorkspaceFile> files = <WorkspaceFile>[
        ...ws.files.where((WorkspaceFile f) => f.name != name),
        wf,
      ];
      await _writeMeta(folder, ws.copyWith(files: files));
    }
    return wf;
  }

  /// 删除附件（文件 + meta 登记）。
  Future<void> removeFile(String id, String fileId) async {
    final Directory? folder = await _dirOf(id);
    if (folder == null) return;
    final Workspace? ws = await _readMeta(folder);
    if (ws == null) return;
    WorkspaceFile? target;
    for (final WorkspaceFile f in ws.files) {
      if (f.id == fileId) {
        target = f;
        break;
      }
    }
    if (target == null) return;
    final File f = File(p.join(folder.path, target.name));
    if (await f.exists()) await f.delete();
    await _writeMeta(
      folder,
      ws.copyWith(
        files: ws.files.where((WorkspaceFile f) => f.id != fileId).toList(),
      ),
    );
  }

  /// 附件所在目录（供归档服务写入）。
  Future<String?> workspacePath(String id) async => (await _dirOf(id))?.path;

  // ---------------------------------------------------------------- 内部

  String _kindOf(String name) {
    final String ext = p.extension(name).toLowerCase();
    switch (ext) {
      case '.xlsx':
      case '.xls':
        return 'excel';
      case '.png':
      case '.jpg':
      case '.jpeg':
        return 'image';
      case '.json':
        return 'json';
      case '.pdf':
        return 'pdf';
      default:
        return 'other';
    }
  }

  String _safeFolder(Workspace ws) {
    final String s = ws.folderName;
    return s.isEmpty ? 'workspace_${ws.id.substring(0, 6)}' : s;
  }

  Future<Directory> _uniqueDir(
    Directory parent,
    String desired,
    String id,
  ) async {
    final String short = id.length >= 6 ? id.substring(0, 6) : id;
    String name = desired;
    Directory candidate = Directory(p.join(parent.path, name));
    if (await candidate.exists()) {
      name = '${desired}_$short';
      candidate = Directory(p.join(parent.path, name));
      // 极端情况下仍冲突，用毫秒时间戳兜底。
      if (await candidate.exists()) {
        name = '${desired}_${short}_${DateTime.now().millisecondsSinceEpoch}';
        candidate = Directory(p.join(parent.path, name));
      }
    }
    await candidate.create(recursive: true);
    return candidate;
  }

  Future<void> _writeMeta(Directory folder, Workspace ws) async {
    final File meta = File(p.join(folder.path, kWorkspaceMetaName));
    await meta.writeAsString(jsonEncode(ws.toJson()));
  }

  Future<Workspace?> _readMeta(Directory folder) async {
    final File meta = File(p.join(folder.path, kWorkspaceMetaName));
    if (!await meta.exists()) return null;
    try {
      final Map<String, dynamic> json =
          jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
      return Workspace.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeTrashIndex(List<TrashEntry> entries) async {
    final File file = await _trashIndex;
    await file.writeAsString(
      jsonEncode(entries.map((TrashEntry e) => e.toJson()).toList()),
    );
  }
}
