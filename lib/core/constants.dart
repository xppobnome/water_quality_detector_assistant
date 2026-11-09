import 'package:flutter/material.dart';

/// 全局常量：配色、协议、默认参数、响应式断点。
///
/// 命名遵循共享知识约定：SCREAMING_SNAKE_CASE + `k` 前缀。
const Color kPrimaryColor = Color(0xFF1976D2);
const Color kPrimaryLight = Color(0xFFE3F2FD);

/// 语义状态色：成功 / 警示 / 错误。
const Color kSuccessColor = Color(0xFF2E7D32);
const Color kWarningColor = Color(0xFFEF6C00);
const Color kErrorColor = Color(0xFFC62828);
const Color kNeutralGrey = Color(0xFF9E9E9E);

/// ── 主题语义兼容层 ──────────────────────────────────────────────────────
///
/// 早期页面里存在一批大面积硬编码浅色背景。深色模式下若原样渲染会变成
/// 刺眼白块，因此这些位置统一改走下列按亮度解析的函数：
/// - [appSoftSurface]：淡蓝强调块。深色模式取亮蓝 HUD 色，保证其上
///   `kPrimaryColor` 深蓝文字仍有 >= 4.5:1 对比度（WCAG AA）。
/// - [appNeutralSurface]：中性信息块，深色模式取深蓝表面。
/// - [appHairline]：分隔线 / 描边。
///
/// 新写的代码请直接使用 `context.cs`（ColorScheme）与 `context.ds`
/// （AppThemeExtension），不要再引用这些兼容函数。
Color appSoftSurface(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFC2DFFF)
    : kPrimaryLight;

Color appNeutralSurface(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF152438)
    : const Color(0xFFF5F5F5);

Color appHairline(BuildContext context) =>
    Theme.of(context).colorScheme.outlineVariant;

/// ── 业务常量 ────────────────────────────────────────────────────────────

/// 标液浓度默认值（MPN/L）。
const double kDefaultConcentration = 9000.0;
const String kDefaultUnit = 'MPN/L';

/// 数据传输协议常量。
const String kServiceTag = 'WQA';
const String kProtocolVersion = '1.0';
const int kTokenLength = 8;

/// HTTP 服务器优先端口，占用时动态回退。
const int kHttpPortPreferred = 54000;

/// UDP 广播发现端口。
const int kUdpDiscoveryPort = 54001;

/// 响应式布局断点：宽度 >= 该值使用桌面端（NavigationRail）布局。
const double kDesktopBreakpoint = 640.0;

/// 工作空间元数据文件名。
const String kWorkspaceMetaName = 'meta.json';

/// 回收站保留天数（超过该天数自动清理）。
const int kTrashRetentionDays = 30;
