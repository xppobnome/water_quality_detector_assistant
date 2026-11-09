import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 工作空间存储位置偏好。
///
/// 只承载两件事，**刻意不做成 ChangeNotifier**，避免为两个开关重构 Provider 树：
/// 1. 落盘根目录（默认系统应用文档目录，可被用户指定为任意可写目录）；
/// 2. 新工作空间是否按 `yyyy-MM` 年月分组存放。
///
/// 变更通过 [epoch] 版本号对外广播：`WorkspaceStore` 缓存了目录句柄，读取前
/// 比对 epoch 即可在配置变化后自动失效（见 `WorkspaceStore._syncEpoch`）。
class WorkspaceStorageSettings {
  WorkspaceStorageSettings._();

  /// 根目录覆盖值；空串表示「使用系统默认目录」。
  static const String _kRootPath = 'workspace_root_path';

  /// 是否按年月创建子文件夹。
  static const String _kMonthly = 'workspace_monthly_folder';

  /// 校验目录可写时使用的探针文件名（写入后立即删除）。
  static const String _kProbeFileName = '.aqua_write_probe';

  /// null = 系统默认（应用文档目录）。
  static String? _rootPathOverride;
  static bool _monthlyFolder = false;
  static int _epoch = 0;
  static bool _loaded = false;

  /// 用户指定的根目录；null 表示使用系统默认目录。
  static String? get rootPathOverride => _rootPathOverride;

  /// 新工作空间是否按年月分组存放。
  static bool get monthlyFolder => _monthlyFolder;

  /// 配置版本号，每次配置变更 +1（供 `WorkspaceStore` 失效缓存）。
  static int get epoch => _epoch;

  /// 从本地偏好恢复配置（幂等，重复调用安全；读取失败保留默认值）。
  static Future<void> load() async {
    if (_loaded) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String raw = (prefs.getString(_kRootPath) ?? '').trim();
      _rootPathOverride = raw.isEmpty ? null : raw;
      _monthlyFolder = prefs.getBool(_kMonthly) ?? false;
    } catch (_) {
      // 读取失败时退回「系统默认目录 + 不分组」，不阻断启动。
      _rootPathOverride = null;
      _monthlyFolder = false;
    }
    _loaded = true;
    // 载入后失效一次缓存：保证任何早于 load() 拿到的目录句柄都被丢弃。
    _epoch++;
  }

  /// 年月键，格式固定 `yyyy-MM`（月份补零）。
  static String monthKey(DateTime t) {
    final String month = t.month < 10 ? '0${t.month}' : '${t.month}';
    return '${t.year}-$month';
  }

  /// 工作空间根目录相对 base 的路径分段。
  ///
  /// - [monthly] 为 false → `['workspaces']`
  /// - [monthly] 为 true → `['workspaces', '2026-05']`
  ///
  /// 纯函数（无 IO、无插件调用），便于单元探针直接验证。
  static List<String> layoutSegments({
    required bool monthly,
    required DateTime at,
  }) {
    final List<String> segments = <String>['workspaces'];
    if (monthly) segments.add(monthKey(at));
    return segments;
  }

  /// 当前生效的 base 目录：用户覆盖值优先，否则系统应用文档目录。
  static Future<Directory> baseDirectory() async {
    final String? override = _rootPathOverride;
    if (override != null && override.trim().isNotEmpty) {
      return Directory(override.trim());
    }
    return getApplicationDocumentsDirectory();
  }

  /// 面向用户的「工作空间根路径」描述（含年月层，按当前时间实时计算）。
  static Future<String> describeRootPath() async {
    final Directory base = await baseDirectory();
    return p.joinAll(<String>[
      base.path,
      ...layoutSegments(monthly: _monthlyFolder, at: DateTime.now()),
    ]);
  }

  /// 校验目录是否可用作存储根目录。
  ///
  /// 返回可展示给用户的错误文案；`null` 表示可用。
  static Future<String?> validatePath(String path) async {
    final String trimmed = path.trim();
    if (trimmed.isEmpty) return '路径不能为空';
    final Directory dir = Directory(trimmed);
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (_) {
      return '目录不存在且无法创建：$trimmed';
    }
    final File probe = File(p.join(dir.path, _kProbeFileName));
    try {
      await probe.writeAsString('aqua', flush: true);
    } catch (_) {
      return '该目录不可写：$trimmed';
    } finally {
      try {
        if (await probe.exists()) await probe.delete();
      } catch (_) {
        // 探针清理失败不影响结论（下次写入会覆盖同名文件）。
      }
    }
    return null;
  }

  /// 设置根目录覆盖值。
  ///
  /// [path] 为 `null` 或空串 → 恢复系统默认目录（无需校验）。
  /// 否则先 [validatePath]，校验失败**不修改任何状态**并返回错误文案。
  /// 成功返回 `null`。
  static Future<String?> setRootPathOverride(String? path) async {
    final String trimmed = (path ?? '').trim();
    if (trimmed.isEmpty) {
      _rootPathOverride = null;
      _epoch++;
      await _persistString(_kRootPath, '');
      return null;
    }
    final String? error = await validatePath(trimmed);
    if (error != null) return error;
    _rootPathOverride = trimmed;
    _epoch++;
    await _persistString(_kRootPath, trimmed);
    return null;
  }

  /// 设置是否按年月分组（仅影响新建工作空间，不移动已有目录）。
  static Future<void> setMonthlyFolder(bool value) async {
    if (_monthlyFolder == value) return;
    _monthlyFolder = value;
    _epoch++;
    await _persistBool(_kMonthly, value);
  }

  static Future<void> _persistString(String key, String value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (_) {
      // 持久化失败时本次会话内配置仍生效（已在内存中），不阻断交互。
    }
  }

  static Future<void> _persistBool(String key, bool value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {
      // 同上：内存态优先，失败不抛出。
    }
  }
}
