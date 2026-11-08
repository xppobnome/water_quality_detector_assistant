import 'dart:io';

/// 平台判断工具。
///
/// 本应用目标平台为 Android 手机端 + Windows 桌面端；
/// OCR 相关能力需用 [isAndroid] 守卫，桌面端降级处理。
bool get isAndroid => Platform.isAndroid;

bool get isWindows => Platform.isWindows;

bool get isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

bool get isMobile => Platform.isAndroid || Platform.isIOS;
