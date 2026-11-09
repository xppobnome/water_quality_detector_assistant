import 'package:flutter/material.dart';

import '../core/design_system.dart';
import '../services/storage_service.dart';

/// 外观模式状态：跟随系统 / 浅色 / 深色。
///
/// 选择结果写入 [StorageService]，下次启动恢复；`ThemeMode.system` 时
/// `MaterialApp` 会随系统亮度变化自动重建，无需额外监听。
class ThemeProvider extends ChangeNotifier {
  ThemeProvider({required StorageService storage}) : _storage = storage {
    _mode = AppThemeModeX.fromStorage(storage.themeMode);
  }

  final StorageService _storage;
  AppThemeMode _mode = AppThemeMode.system;

  AppThemeMode get mode => _mode;

  ThemeMode get materialThemeMode => _mode.materialThemeMode;

  /// 是否为「深色」（跟随系统时以当前平台亮度为准）。
  bool resolvedDark(Brightness platformBrightness) => switch (_mode) {
    AppThemeMode.dark => true,
    AppThemeMode.light => false,
    AppThemeMode.system => platformBrightness == Brightness.dark,
  };

  Future<void> setMode(AppThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    await _storage.setThemeMode(mode.storageValue);
  }

  /// 顶栏快捷按钮：浅色 <-> 深色 直接切换（不改变「跟随系统」偏好时也可临时使用）。
  Future<void> toggle(Brightness platformBrightness) async {
    final bool dark = resolvedDark(platformBrightness);
    await setMode(dark ? AppThemeMode.light : AppThemeMode.dark);
  }
}
