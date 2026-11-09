import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../core/design_system.dart';
import '../core/platform.dart';
import '../providers/workspace_provider.dart';
import '../services/ocr_log.dart';
import '../services/ocr_service.dart';
import '../services/storage_service.dart';
import '../services/workspace_storage_settings.dart';
import '../widgets/futuristic.dart';

/// ============================================================================
/// 设置（第 4 个 tab）
/// ============================================================================
/// 新增「外观与主题」：跟随系统 / 浅色 / 深色三选一，选择即持久化。
/// 其余 OCR 引擎配置、桌面端引擎诊断、日志查看逻辑完整保留，
/// 仅视觉层统一为玻璃卡片 + 设计令牌，确保深色模式下无白块与低对比文字。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.tune_rounded, size: 19, color: context.cs.primary),
            const SizedBox(width: AppSpacing.sm),
            const Text('偏好设置'),
          ],
        ),
        actions: const <Widget>[
          AquaThemeToggle(compact: true),
          SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: AquaBody(
        glowStrength: 0.7,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.section,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 940),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _PageIntro(),
                  const SizedBox(height: AppSpacing.xl),
                  const _AppearanceCard(),
                  const SizedBox(height: AppSpacing.xxl),
                  const _WorkspaceStorageCard(),
                  const SizedBox(height: AppSpacing.xxl),
                  const SectionHeader(
                    title: '平台与识别引擎',
                    subtitle: '本地离线优先，可选云端 OCR 服务',
                    icon: Icons.memory_rounded,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _platformCard(context),
                  const SizedBox(height: AppSpacing.lg),
                  if (isDesktop) ...<Widget>[
                    const _EngineDiagnosisCard(),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                  const _OcrConfigCard(),
                  const SizedBox(height: AppSpacing.lg),
                  const _AboutCard(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _platformCard(BuildContext context) {
    final String platform = isWindows
        ? 'Windows 桌面端'
        : (isMobile ? 'Android 移动端' : '桌面端');
    final String strategy = isDesktop
        ? 'Windows 使用「Python 进程启动并加载 OCR 模型」的纯本地方案：'
              'Flutter 通过 Process.start 拉起随应用分发的 ocr_engine.exe，'
              'PaddleOCR 模型常驻、离线识别，无需安装 Python 或配置路径。'
        : 'Android 使用 Google ML Kit 中文文本识别（google_mlkit_text_recognition）：'
              '模型随 APK 打包、端侧离线推理；无需后端服务、API Key 或联网，'
              '拍照后走四角裁剪再直接识别。';
    final ColorScheme cs = context.cs;
    return GlassCard(
      elevated: false,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          GlowIcon(
            icon: isDesktop
                ? Icons.desktop_windows_outlined
                : Icons.phone_android_rounded,
            size: 42,
            iconSize: 20,
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '当前平台：$platform',
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    AquaPill(label: '离线可用', icon: Icons.wifi_off_rounded),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  strategy,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 11.5,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PageIntro extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = context.cs;
    return Row(
      children: <Widget>[
        const AquaLogo(size: 38),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '让你的工作台更顺手',
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '外观、OCR 引擎与运行诊断都集中在这里',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 外观与主题
// ---------------------------------------------------------------------------

class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = context.cs;
    final AppThemeExtension ds = context.ds;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              GlowIcon(icon: Icons.palette_outlined, size: 42, iconSize: 20),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '外观与主题',
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '淡蓝未来感 / 深空蓝，两套配色均已通过对比度校验',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              AquaPill(
                label: ds.isDark ? '深色生效' : '浅色生效',
                icon: ds.isDark
                    ? Icons.nights_stay_outlined
                    : Icons.wb_sunny_outlined,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          const ThemeModeSelector(),
          const SizedBox(height: AppSpacing.lg),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: cs.primary.withValues(alpha: 0.16)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.info_outline_rounded, size: 16, color: cs.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '选择「跟随系统」后，应用会随设备外观设置自动切换，'
                    '运行过程中修改系统主题也会立即生效；也可随时用顶栏的'
                    '太阳 / 月亮按钮快速切换。',
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 11.5,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 工作空间存储位置
// ---------------------------------------------------------------------------

/// 存储位置设置卡：可选根目录 + 是否按年月分组。
///
/// 换根目录是「危险操作」——现有工作空间可能留在原地，所以必须走确认弹窗，
/// 让用户在「移动 / 仅新建」之间显式选择；移动由 `WorkspaceStore.migrateAllTo`
/// 完成（跨盘自动退化为复制 + 删除）。
class _WorkspaceStorageCard extends StatefulWidget {
  const _WorkspaceStorageCard();

  @override
  State<_WorkspaceStorageCard> createState() => _WorkspaceStorageCardState();
}

class _WorkspaceStorageCardState extends State<_WorkspaceStorageCard> {
  /// `<base>/workspaces`（**不含**年月层，年月在展示时实时拼）。
  String _rootBase = '';
  int _count = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// 当前完整落盘路径（开启分组时含 `yyyy-MM`）。
  String get _currentPath {
    final String base = _rootBase.isEmpty ? '…' : _rootBase;
    if (!WorkspaceStorageSettings.monthlyFolder) return base;
    return p.join(base, WorkspaceStorageSettings.monthKey(DateTime.now()));
  }

  /// 「新工作空间会创建在 …」的示例路径。
  String get _newFolderPreview {
    final String base = _rootBase.isEmpty ? '…' : _rootBase;
    final List<String> segments = <String>[
      base,
      if (WorkspaceStorageSettings.monthlyFolder)
        WorkspaceStorageSettings.monthKey(DateTime.now()),
      '<工作空间名>',
    ];
    return '${p.joinAll(segments)}${p.separator}';
  }

  Future<void> _load() async {
    final WorkspaceProvider provider = context.read<WorkspaceProvider>();
    String base = '';
    int count = 0;
    try {
      final Directory dir = await WorkspaceStorageSettings.baseDirectory();
      base = p.join(dir.path, 'workspaces');
      count = await provider.store.countWorkspaces();
    } catch (_) {
      // 统计失败不影响路径展示（路径仍会显示出来）。
    }
    if (!mounted) return;
    setState(() {
      _rootBase = base;
      _count = count;
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: _currentPath));
    if (!mounted) return;
    _snack('路径已复制');
  }

  Future<void> _toggleMonthly(bool value) async {
    final WorkspaceProvider provider = context.read<WorkspaceProvider>();
    setState(() => _busy = true);
    await WorkspaceStorageSettings.setMonthlyFolder(value);
    // epoch 已变，refresh 会走新的分组目录读取（老数据仍能扫到）。
    await provider.refresh();
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  /// 选择新根目录 → 校验 → 确认是否迁移 → 应用。
  Future<void> _changeLocation() async {
    if (_busy) return;
    String? picked;
    // 目录还不存在时不要把它作为初始目录交给选择器（部分平台会直接报错）。
    final String? initial =
        (_rootBase.isEmpty || !Directory(_rootBase).existsSync())
        ? null
        : _rootBase;
    try {
      // file_picker 13.x：目录选择是静态方法（没有 .platform 单例）。
      picked = await FilePicker.getDirectoryPath(
        dialogTitle: '选择工作空间存储根目录',
        initialDirectory: initial,
      );
    } catch (e) {
      if (!mounted) return;
      _snack('打开目录选择器失败：$e');
      return;
    }
    if (picked == null || picked.trim().isEmpty || !mounted) return; // 用户取消
    final String target = picked.trim();
    final String? error = await WorkspaceStorageSettings.validatePath(target);
    if (!mounted) return;
    if (error != null) {
      _snack(error);
      return;
    }
    final bool? move = await _confirmSwitch(target);
    if (move == null || !mounted) return;
    await _applyRootPath(target, move: move);
  }

  /// 恢复默认目录（不自动迁移，避免不可预期的大规模搬动）。
  Future<void> _restoreDefault() async {
    String oldPath = '';
    try {
      oldPath = await WorkspaceStorageSettings.describeRootPath();
    } catch (_) {
      // 取不到旧路径时用占位文案。
    }
    if (!mounted) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('恢复默认存储位置'),
        content: SingleChildScrollView(
          child: Text(
            '新工作空间将创建在系统应用文档目录下。\n\n'
            '原有工作空间留在${oldPath.isEmpty ? '旧位置' : '：\n$oldPath'}\n\n'
            '不会自动移回；如需一起搬回，请手动复制文件夹或先「更改位置…」到该目录。',
            style: const TextStyle(fontSize: 13, height: 1.55),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _applyRootPath(null, move: false);
  }

  /// 迁移确认弹窗：返回 true = 移动现有数据，false = 仅新建，null = 取消。
  Future<bool?> _confirmSwitch(String target) async {
    final WorkspaceProvider provider = context.read<WorkspaceProvider>();
    int count = _count;
    String oldPath = '';
    try {
      count = await provider.store.countWorkspaces();
      oldPath = await WorkspaceStorageSettings.describeRootPath();
    } catch (_) {
      // 统计失败时仍允许切换，只是数字可能不准。
    }
    if (!mounted) return null;
    return showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('切换存储位置'),
        content: SingleChildScrollView(
          child: Text(
            '现有 $count 个工作空间位于\n'
            '${oldPath.isEmpty ? '旧位置' : oldPath}\n\n'
            '「移动」会把它们（含回收站）搬到新位置：\n$target\n\n'
            '「仅新建」则留在旧位置，切换后列表只显示新位置的工作空间。',
            style: const TextStyle(fontSize: 13, height: 1.55),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('仅新建'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('移动现有数据'),
          ),
        ],
      ),
    );
  }

  /// 应用根目录；[target] 为 null 表示恢复系统默认。
  ///
  /// 顺序很关键：**先迁移（用旧 base 扫描）、再写偏好**，否则迁移会扫到新目录。
  Future<void> _applyRootPath(String? target, {required bool move}) async {
    final WorkspaceProvider provider = context.read<WorkspaceProvider>();
    setState(() => _busy = true);
    int moved = 0;
    String? failure;
    try {
      if (move && target != null) {
        moved = await provider.store.migrateAllTo(target);
      }
      final String? error = await WorkspaceStorageSettings.setRootPathOverride(
        target,
      );
      if (error != null) failure = error;
      await provider.refresh();
      await _load();
    } catch (e) {
      failure = '$e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) {
      _snack('切换存储位置失败：$failure');
      return;
    }
    _snack(move ? '已切换存储位置，迁移 $moved 个工作空间' : '已切换存储位置（仅新建，原有数据留在旧位置）');
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = context.cs;
    final bool desktop = isDesktop;
    final bool monthly = WorkspaceStorageSettings.monthlyFolder;
    final bool canRestoreDefault =
        WorkspaceStorageSettings.rootPathOverride != null;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const GlowIcon(
                icon: Icons.folder_copy_outlined,
                size: 42,
                iconSize: 20,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '工作空间存储',
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '决定工作空间保存到磁盘的哪个位置',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              AquaPill(
                label: '$_count 个工作空间',
                icon: Icons.inventory_2_outlined,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(
            '当前存储路径',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.xs,
              AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: cs.primary.withValues(alpha: 0.16)),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: SelectableText(
                    _currentPath,
                    style: TextStyle(color: cs.onSurface, fontSize: 11.5),
                  ),
                ),
                IconButton(
                  tooltip: '复制路径',
                  visualDensity: VisualDensity.compact,
                  onPressed: _busy ? null : () => unawaited(_copyPath()),
                  icon: const Icon(Icons.copy_rounded, size: 17),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.subdirectory_arrow_right_rounded,
                size: 15,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '新工作空间会创建在 $_newFolderPreview',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 11.5,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SwitchListTile(
            value: monthly,
            onChanged: _busy
                ? null
                : (bool value) => unawaited(_toggleMonthly(value)),
            dense: true,
            contentPadding: EdgeInsets.zero,
            secondary: Icon(
              Icons.calendar_month_outlined,
              size: 20,
              color: cs.primary,
            ),
            title: Text(
              '按年月创建子文件夹',
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              '开启后新工作空间按 yyyy-MM 分组存放；已存在的工作空间不会被移动',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (!desktop)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.info_outline_rounded,
                  size: 15,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Android 端固定使用应用私有目录（其他应用无法读取），'
                    '仅支持按年月分组。',
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 11.5,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          if (desktop)
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _busy ? null : () => unawaited(_changeLocation()),
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(
                          Icons.drive_folder_upload_outlined,
                          size: 18,
                        ),
                  label: const Text('更改位置…'),
                ),
                if (canRestoreDefault)
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => unawaited(_restoreDefault()),
                    icon: const Icon(
                      Icons.settings_backup_restore_rounded,
                      size: 18,
                    ),
                    label: const Text('恢复默认'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// OCR 引擎配置
// ---------------------------------------------------------------------------

class _OcrConfigCard extends StatefulWidget {
  const _OcrConfigCard();

  @override
  State<_OcrConfigCard> createState() => _OcrConfigCardState();
}

class _OcrConfigCardState extends State<_OcrConfigCard> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  String _engine = 'local';
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    final StorageService storage = context.read<StorageService>();
    _engine = storage.ocrEngine;
    _urlController.text = storage.ocrApiBaseUrl ?? '';
    _keyController.text = storage.ocrApiKey ?? '';
    _pathController.text = storage.ocrEnginePath ?? '';
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final StorageService storage = context.read<StorageService>();
    final ColorScheme cs = context.cs;
    final bool mobile = isMobile;
    return GlassCard(
      elevated: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'OCR 引擎配置',
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            mobile
                ? '端侧引擎：Google ML Kit 中文模型，随 APK 打包、离线识别，无需任何配置；'
                      '云端：可配置的 OCR 服务地址（可选）。'
                : '本地：随应用分发的 PaddleOCR 引擎（离线、纯本地）；'
                      '云端：可配置的 OCR 服务地址。',
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 11.5,
              height: 1.45,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SegmentedButton<String>(
            segments: <ButtonSegment<String>>[
              ButtonSegment<String>(
                value: 'local',
                label: Text(mobile ? '端侧引擎' : '本地引擎'),
                icon: const Icon(Icons.computer_outlined, size: 16),
              ),
              const ButtonSegment<String>(
                value: 'cloud',
                label: Text('云端服务'),
                icon: Icon(Icons.cloud_outlined, size: 16),
              ),
            ],
            selected: <String>{_engine},
            onSelectionChanged: (Set<String> s) =>
                setState(() => _engine = s.first),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (_engine == 'local') ...<Widget>[
            if (mobile)
              const _MlKitInfoCard()
            else ...<Widget>[
              TextField(
                controller: _pathController,
                decoration: const InputDecoration(
                  labelText: '本地引擎路径（可选）',
                  hintText: '留空则自动查找随应用分发的 ocr_engine 目录',
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '运行项目 python/build_engine.bat 可一键打包；'
                '产物由 CMake 自动拷到应用目录，通常无需手动指定。',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5),
              ),
            ],
          ] else ...<Widget>[
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'OCR 服务地址',
                hintText: 'https://your-ocr-service/recognize',
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _keyController,
              decoration: const InputDecoration(
                labelText: 'API Key（可选）',
                hintText: '留空则不加 Authorization 头',
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              FilledButton.icon(
                onPressed: () async {
                  await storage.setOcrEngine(_engine);
                  await storage.setOcrEnginePath(_pathController.text.trim());
                  await storage.setOcrApiBaseUrl(_urlController.text.trim());
                  await storage.setOcrApiKey(_keyController.text.trim());
                  if (!context.mounted) return;
                  setState(() => _saved = true);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('OCR 配置已保存，重新进入工具后生效')),
                  );
                },
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存'),
              ),
              if (_saved)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.check_circle_rounded,
                      color: context.ds.success,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '已保存',
                      style: TextStyle(color: context.ds.success, fontSize: 12),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 移动端端侧 OCR 说明卡：明确「零配置、离线可用」。
class _MlKitInfoCard extends StatelessWidget {
  const _MlKitInfoCard();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = context.cs;
    final AppThemeExtension ds = context.ds;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.check_circle_outline_rounded,
                color: ds.success,
                size: 17,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '端侧离线 OCR 已内置',
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'google_mlkit_text_recognition · 中文模型\n'
            '无需安装 Python、无需搭建服务、无需 API Key、无需联网。',
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 11.5,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// 桌面端「引擎诊断」：显示实际解析到的引擎路径与文件是否存在，
/// 并可生成一张测试 PNG 走一次 initEngine + recognizeRaw，把返回文本 /
/// [OcrService.lastError] 直接展示出来，避免「识别不了但看不到原因」。
class _EngineDiagnosisCard extends StatefulWidget {
  const _EngineDiagnosisCard();

  @override
  State<_EngineDiagnosisCard> createState() => _EngineDiagnosisCardState();
}

class _EngineDiagnosisCardState extends State<_EngineDiagnosisCard> {
  bool _testing = false;

  /// 用 dart:ui 画一张 300x80 白底黑字 PNG，写到临时目录后返回路径。
  Future<String> _buildTestImage() async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    final ui.Paint background = ui.Paint()..color = const ui.Color(0xFFFFFFFF);
    canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 300, 80), background);

    final ui.ParagraphBuilder builder =
        ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 26))
          ..pushStyle(
            ui.TextStyle(color: const ui.Color(0xFF000000), fontSize: 26),
          )
          ..addText('OCR 12345');
    final ui.Paragraph paragraph = builder.build();
    paragraph.layout(ui.ParagraphConstraints(width: 300));
    canvas.drawParagraph(paragraph, const ui.Offset(10, 20));

    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(300, 80);
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    final List<int> bytes = data == null
        ? <int>[]
        : data.buffer
              .asUint8List(data.offsetInBytes, data.lengthInBytes)
              .toList();
    picture.dispose();
    image.dispose();
    if (bytes.isEmpty) {
      throw StateError('无法生成测试图片 PNG');
    }

    final Directory dir = await getTemporaryDirectory();
    final File file = File(p.join(dir.path, 'ocr_engine_probe.png'));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  Future<void> _testEngine() async {
    if (_testing) return;
    setState(() => _testing = true);
    final StorageService storage = context.read<StorageService>();
    final OcrService ocr = createOcrService(storage: storage);
    String message = '';
    try {
      final String imagePath = await _buildTestImage();
      await ocr.initEngine();
      final String text = (await ocr.recognizeRaw(<String>[imagePath])).trim();
      final String diagnosis = ocr.lastError ?? '（无诊断信息）';
      message =
          '识别返回文本：\n${text.isEmpty ? '（空）' : text}\n\n'
          '──── 完整诊断 ────\n$diagnosis';
    } catch (e) {
      message = '测试失败：$e\n\n${ocr.lastError ?? '（无诊断信息）'}';
    } finally {
      ocr.disposeEngine();
    }
    if (!mounted) return;
    setState(() => _testing = false);
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('引擎诊断结果'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(message)),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 同时展示 Flutter 侧与 Python 引擎侧的文件日志，便于整体复制反馈。
  Future<void> _showLogs(BuildContext context) async {
    final String flutterLog = OcrLog.tail();
    final StorageService storage = context.read<StorageService>();
    final String exe = LocalPythonOcrService(storage: storage)
        .resolvedExecutable();
    final File pythonFile = File(OcrLog.pythonLogPath(exe));
    String pythonLog;
    try {
      pythonLog = pythonFile.existsSync()
          ? pythonFile.readAsStringSync()
          : '（未找到 Python 引擎日志，文件尚未生成）';
    } catch (e) {
      pythonLog = '读取失败：$e';
    }
    if (pythonLog.length > 24000) {
      pythonLog =
          '…（已省略前面 ${pythonLog.length - 24000} 字符）\n'
          '${pythonLog.substring(pythonLog.length - 24000)}';
    }
    final String text =
        '── Flutter 日志（${OcrLog.path}）──\n$flutterLog\n\n'
        '── Python 引擎日志（${pythonFile.path}）──\n$pythonLog';
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('OCR 运行日志（可长按复制）'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              OcrLog.clear();
              Navigator.of(ctx).pop();
            },
            child: const Text('清空 Flutter 日志'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final StorageService storage = context.read<StorageService>();
    final LocalPythonOcrService local = LocalPythonOcrService(storage: storage);
    final String path = local.resolvedExecutable();
    final bool exists = File(path).existsSync();
    final String engineLabel = storage.ocrEngine == 'cloud'
        ? '云端服务（当前配置）'
        : '本地引擎（当前配置）';
    final String diagnosis = local.lastError ?? '（无诊断信息）';
    final ColorScheme cs = context.cs;
    final AppThemeExtension ds = context.ds;

    return GlassCard(
      elevated: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '引擎诊断',
            style: TextStyle(
              color: cs.onSurface,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '当前 OCR 引擎：$engineLabel',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5),
          ),
          const SizedBox(height: 6),
          Text(
            '解析到的引擎路径：',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5),
          ),
          const SizedBox(height: 4),
          SelectableText(
            path,
            style: TextStyle(color: cs.onSurface, fontSize: 11.5),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: <Widget>[
              Icon(
                exists
                    ? Icons.check_circle_rounded
                    : Icons.error_outline_rounded,
                size: 16,
                color: exists ? ds.success : ds.error,
              ),
              const SizedBox(width: 6),
              Text(
                exists ? '文件存在' : '文件不存在，识别会失败',
                style: TextStyle(
                  fontSize: 11.5,
                  color: exists ? ds.success : ds.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '当前状态诊断（可长按复制）：',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5),
          ),
          const SizedBox(height: 4),
          SelectableText(
            diagnosis,
            style: TextStyle(color: cs.onSurface, fontSize: 11),
          ),
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: <Widget>[
              FilledButton.icon(
                onPressed: _testing ? null : () => unawaited(_testEngine()),
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded, size: 18),
                label: Text(_testing ? '测试中…' : '测试引擎'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  await storage.setOcrEngine('local');
                  if (!context.mounted) return;
                  setState(() {});
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('已切回本地引擎')));
                },
                icon: const Icon(
                  Icons.settings_backup_restore_rounded,
                  size: 18,
                ),
                label: const Text('切回本地引擎'),
              ),
              OutlinedButton.icon(
                onPressed: () => unawaited(_showLogs(context)),
                icon: const Icon(Icons.article_outlined, size: 18),
                label: const Text('查看运行日志'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = context.cs;
    return GlassCard(
      elevated: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const AquaLogo(size: 34, showGlow: false),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  '关于 AQUA Lab',
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              AquaPill(label: 'v1.0', color: cs.primary),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '水质检测仪助手 · 淡蓝 / 深空双主题 · Android + Windows',
            style: TextStyle(color: cs.onSurface, fontSize: 11.5),
          ),
          const SizedBox(height: 6),
          Text(
            '工作空间按文件夹落盘，回收站保留 $kTrashRetentionDays 天；'
            '各工具执行完成后均可创建或导入到工作空间。',
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 11.5,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
