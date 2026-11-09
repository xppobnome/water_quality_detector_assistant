import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../models/trash_entry.dart';
import '../models/workspace.dart';
import 'workspace_storage_settings.dart';

/// 工作空间搜索字段。
enum SearchField { all, contractNo, projectName }

/// 工作空间持久化（增量 v2）：每个工作空间 = 一个真实文件夹。
///
/// 目录结构（`<base>` 默认是系统应用文档目录，可由用户在设置页更改）：
/// ```
/// <base>/
/// ├── workspaces/<拼接名>/meta.json + 附件
/// ├── workspaces/<yyyy-MM>/<拼接名>/ …（开启「按年月分组」后的新工作空间）
/// └── trash/trash_index.json + trash/<id>/（移入的原文件夹）
/// ```
///
/// 说明：
/// - 回收站与工作空间共用同一个 `<base>`，保证 `rename` 同盘（秒级移动）；
/// - 若用户在跨盘位置之间切换过，移动逻辑自动退化为「复制 + 删除」
///   （见 [_moveDir]）；
/// - 读取时同时兼容「平铺」与「年月分组」两种布局，用户中途关闭开关后
///   老数据仍然可见（见 [_scanWorkspaceDirsSync]）。
///
/// 兼容旧版 `workspaces/<id>.json`（[migrateLegacyIfNeeded] 幂等迁移）。
/// 同时保留旧 API [list]/[get]/[save]/[delete] 供国标验证页复用。
class WorkspaceStore {
  WorkspaceStore();

  Directory? _workspacesDir;
  Directory? _trashDir;
  bool _migrated = false;

  /// 当前缓存对应的配置版本号（[WorkspaceStorageSettings.epoch]）。
  int _cacheEpoch = -1;

  /// 当前 `_workspacesDir` 缓存所属的年月键；跨月运行必须重建目录。
  String _dirMonthKey = '';

  /// 配置变更（换根目录 / 开关分组）后失效所有缓存句柄。
  void _syncEpoch() {
    if (_cacheEpoch == WorkspaceStorageSettings.epoch) return;
    _cacheEpoch = WorkspaceStorageSettings.epoch;
    _workspacesDir = null;
    _trashDir = null;
    _migrated = false;
    _dirMonthKey = '';
  }

  /// 当前写入目标目录：`<base>/workspaces` 或 `<base>/workspaces/<yyyy-MM>`。
  Future<Directory> get _dir async {
    _syncEpoch();
    final DateTime now = DateTime.now();
    final String monthKey = WorkspaceStorageSettings.monthKey(now);
    final Directory? cached = _workspacesDir;
    // 缓存只在「同月 + 同上一次配置版本」内有效，否则跨月会写进上个月的目录。
    if (cached != null && _dirMonthKey == monthKey && await cached.exists()) {
      return cached;
    }
    final Directory base = await WorkspaceStorageSettings.baseDirectory();
    final Directory dir = Directory(
      p.joinAll(<String>[
        base.path,
        ...WorkspaceStorageSettings.layoutSegments(
          monthly: WorkspaceStorageSettings.monthlyFolder,
          at: now,
        ),
      ]),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    _workspacesDir = dir;
    _dirMonthKey = monthKey;
    return dir;
  }

  /// 工作空间根目录（`<base>/workspaces`，**不含**年月层，不缓存、不创建）。
  ///
  /// 读取侧统一从这里递归一层扫描，因此两种布局都能被读到。
  Future<Directory> get _rootDir async {
    _syncEpoch();
    final Directory base = await WorkspaceStorageSettings.baseDirectory();
    return Directory(p.join(base.path, 'workspaces'));
  }

  Future<Directory> get _trash async {
    _syncEpoch();
    if (_trashDir != null && await _trashDir!.exists()) return _trashDir!;
    final Directory base = await WorkspaceStorageSettings.baseDirectory();
    final Directory dir = Directory(p.join(base.path, 'trash'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _trashDir = dir;
    return dir;
  }

  Future<File> get _trashIndex async {
    final Directory dir = await _trash;
    return File(p.join(dir.path, 'trash_index.json'));
  }

  /// 扫描 [root] 下所有工作空间文件夹（兼容平铺 + 年月分组两种布局）。
  ///
  /// 判定规则：目录直接含 `meta.json` → 它是工作空间；否则再看一层子目录。
  /// 这样「已存在的平铺目录」和「新建的年月目录」能被同时读到。
  List<Directory> _scanWorkspaceDirsSync(Directory root) {
    final List<Directory> out = <Directory>[];
    if (!root.existsSync()) return out;
    for (final Directory d in root.listSync().whereType<Directory>()) {
      if (File(p.join(d.path, kWorkspaceMetaName)).existsSync()) {
        out.add(d);
        continue;
      }
      for (final Directory c in d.listSync().whereType<Directory>()) {
        if (File(p.join(c.path, kWorkspaceMetaName)).existsSync()) out.add(c);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- 迁移

  /// 旧 `<id>.json` → 文件夹 + meta.json，幂等；迁移成功后删除旧文件。
  ///
  /// 旧文件始终位于 `workspaces/` **顶层**，因此扫描用 [_rootDir]（不含年月层）；
  /// 迁出的新目录仍写入 [_dir]（开启分组时自动进当月）。
  Future<void> migrateLegacyIfNeeded() async {
    if (_migrated) return;
    final Directory root = await _rootDir;
    final List<File> legacy = root.existsSync()
        ? root
              .listSync()
              .whereType<File>()
              .where((File f) => f.path.endsWith('.json'))
              .toList()
        : <File>[];
    for (final File f in legacy) {
      try {
        final Map<String, dynamic> json =
            jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final Workspace ws = Workspace.fromJson(json);
        final Directory dir = await _dir;
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
    final Directory root = await _rootDir;
    final List<Workspace> result = <Workspace>[];
    for (final Directory d in _scanWorkspaceDirsSync(root)) {
      final Workspace? ws = await _readMeta(d);
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
    final Directory root = await _rootDir;
    for (final Directory d in _scanWorkspaceDirsSync(root)) {
      final Workspace? ws = await _readMeta(d);
      if (ws != null && ws.id == id) return ws;
    }
    return null;
  }

  /// 按 id 找其物理文件夹；不存在返回 null。
  Future<Directory?> _dirOf(String id) async {
    final Directory root = await _rootDir;
    for (final Directory d in _scanWorkspaceDirsSync(root)) {
      final Workspace? ws = await _readMeta(d);
      if (ws != null && ws.id == id) return d;
    }
    return null;
  }

  /// 现有工作空间数量（不含回收站），供设置页展示。
  Future<int> countWorkspaces() async {
    final Directory root = await _rootDir;
    return _scanWorkspaceDirsSync(root).length;
  }

  // ---------------------------------------------------------------- 写入

  /// 新建工作空间：建文件夹（sanitize + 防冲突）+ meta.json，返回落盘后的对象。
  ///
  /// 父目录取 [_dir]：开启「按年月分组」时会自动落在 `<base>/workspaces/<yyyy-MM>`
  /// 下，关闭时落在 `<base>/workspaces` 下。
  Future<Workspace> create(Workspace ws) async {
    await migrateLegacyIfNeeded();
    final Directory dir = await _dir;
    final Directory target = await _uniqueDir(dir, _safeFolder(ws), ws.id);
    await _writeMeta(target, ws);
    return ws;
  }

  /// 更新 meta.json；若拼接名变化则同步重命名物理文件夹（冲突追加 id 前 6 位，失败回滚）。
  ///
  /// **重命名严格限制在 `current.parent` 内**（即同一年月分组目录里）：不跨月 /
  /// 跨组搬动目录，避免用户改个名字就把数据挪到别的分组，也避免跨盘复制风险。
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
    // 用 [_moveDir] 而非直接 rename：用户换过根目录后可能跨盘，rename 会失败。
    await _moveDir(current, dest.path);

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
  ///
  /// 恢复到 [_dir]（当天所在分组）；若同名目录已被占用则追加 id 前 6 位。
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
    await _moveDir(source, p.join(dir.path, targetName));
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

  // ---------------------------------------------------------------- 存储迁移

  /// 把**当前 base** 下所有工作空间（含回收站）搬到 [newBasePath]。
  ///
  /// 目标布局：`<newBasePath>/workspaces[/<该工作空间 createdAt 的年月>]/<原文件夹名>`，
  /// 年月层是否出现取决于调用时刻的 [WorkspaceStorageSettings.monthlyFolder]；
  /// 同名冲突复用 [_uniqueName] 的「追加 id 前 6 位」策略。
  ///
  /// **必须在 `setRootPathOverride(newBasePath)` 之前调用**：本方法内部用旧 base
  /// 扫描（`_syncEpoch` 尚未失效缓存），切换后再调会扫到空目录。返回移动条数。
  Future<int> migrateAllTo(String newBasePath) async {
    final String base = newBasePath.trim();
    if (base.isEmpty) return 0;
    final Directory oldRoot = await _rootDir;
    final List<Directory> sources = _scanWorkspaceDirsSync(oldRoot);
    int moved = 0;
    for (final Directory src in sources) {
      final String folderName = p.basename(src.path);
      final Workspace? ws = await _readMeta(src);
      final DateTime at = ws?.createdAt ?? DateTime.now();
      final List<String> segments = WorkspaceStorageSettings.layoutSegments(
        monthly: WorkspaceStorageSettings.monthlyFolder,
        at: at,
      );
      final Directory parent = Directory(
        p.joinAll(<String>[base, ...segments]),
      );
      // 用户可能选了「同一个根目录」：已在目标分组的目录原地保留，不重复搬运。
      if (p.equals(src.parent.path, parent.path)) continue;
      if (!await parent.exists()) await parent.create(recursive: true);
      final String name = await _uniqueName(
        parent,
        folderName,
        ws?.id ?? folderName,
      );
      try {
        await _moveDir(src, p.join(parent.path, name));
        moved++;
      } catch (_) {
        // 单个目录搬迁失败不影响其余工作空间（宁可部分迁移，也不留半途崩溃）。
      }
    }
    // 回收站整体搬迁：索引与目录必须同时可用，否则「删除」会立刻失败。
    final Directory oldTrash = await _trash;
    final Directory newTrash = Directory(p.join(base, 'trash'));
    if (await oldTrash.exists() &&
        !p.equals(oldTrash.path, newTrash.path) &&
        !await newTrash.exists()) {
      try {
        await _moveDir(oldTrash, newTrash.path);
      } catch (_) {
        // 回收站搬迁失败不阻断主流程：下次删除时会在新位置重建空回收站。
      }
    }
    return moved;
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

  /// 冲突安全的目录名词：`name` → `name_<id前6位>` → `name_<id前6位>_<毫秒>`。
  Future<String> _uniqueName(
    Directory parent,
    String desired,
    String id,
  ) async {
    final String short = id.length >= 6 ? id.substring(0, 6) : id;
    String name = desired;
    if (await Directory(p.join(parent.path, name)).exists()) {
      name = '${desired}_$short';
      // 极端情况下仍冲突，用毫秒时间戳兜底。
      if (await Directory(p.join(parent.path, name)).exists()) {
        name = '${desired}_${short}_${DateTime.now().millisecondsSinceEpoch}';
      }
    }
    return name;
  }

  Future<Directory> _uniqueDir(
    Directory parent,
    String desired,
    String id,
  ) async {
    final String name = await _uniqueName(parent, desired, id);
    final Directory candidate = Directory(p.join(parent.path, name));
    await candidate.create(recursive: true);
    return candidate;
  }

  /// 移动目录；跨盘（或跨卷）时 `rename` 会抛 `FileSystemException`，
  /// 此时退化为「递归复制 + 删除源目录」，保证用户切换存储位置后仍能工作。
  ///
  /// [destPath] 不应已存在（调用方负责先清空或选唯一名）。
  Future<void> _moveDir(Directory src, String destPath) async {
    if (!await src.exists()) return;
    try {
      await src.rename(destPath);
      return;
    } on FileSystemException {
      // 回退到复制方案。
    }
    final Directory dest = Directory(destPath);
    if (!await dest.exists()) await dest.create(recursive: true);
    await for (final FileSystemEntity entity in src.list(
      recursive: true,
      followLinks: false,
    )) {
      final String rel = p.relative(entity.path, from: src.path);
      final String target = p.join(dest.path, rel);
      if (entity is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entity is File) {
        await File(target).parent.create(recursive: true);
        await entity.copy(target);
      }
    }
    await src.delete(recursive: true);
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
