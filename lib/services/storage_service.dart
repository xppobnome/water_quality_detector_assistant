import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';

/// shared_preferences 封装：标液浓度 / 单位等少量设置。
class StorageService {
  static const String _kConcentration = 'standard_concentration';
  static const String _kUnit = 'standard_unit';
  static const String _kOcrApiBaseUrl = 'ocr_api_base_url';
  static const String _kOcrApiKey = 'ocr_api_key';
  static const String _kOcrEngine = 'ocr_engine';
  static const String _kOcrEnginePath = 'ocr_engine_path';
  static const String _kThemeMode = 'app_theme_mode';

  SharedPreferences? _prefs;
  bool _loaded = false;
  double _concentration = kDefaultConcentration;
  String _unit = kDefaultUnit;
  String? _ocrApiBaseUrl;
  String? _ocrApiKey;
  String _ocrEngine = 'local';
  String? _ocrEnginePath;

  /// 外观模式：'system' / 'light' / 'dark'，默认跟随系统。
  String _themeMode = 'system';

  /// 读取本地偏好（幂等，重复调用安全）。
  Future<void> init() async {
    if (_loaded) return;
    try {
      _prefs = await SharedPreferences.getInstance();
      _concentration =
          _prefs?.getDouble(_kConcentration) ?? kDefaultConcentration;
      _unit = _prefs?.getString(_kUnit) ?? kDefaultUnit;
      _ocrApiBaseUrl = _prefs?.getString(_kOcrApiBaseUrl);
      _ocrApiKey = _prefs?.getString(_kOcrApiKey);
      _ocrEngine = _prefs?.getString(_kOcrEngine) ?? 'local';
      _ocrEnginePath = _prefs?.getString(_kOcrEnginePath);
      _themeMode = _prefs?.getString(_kThemeMode) ?? 'system';
    } catch (_) {
      // 读取失败时保留默认值，不阻断启动。
    }
    _loaded = true;
  }

  /// 标液浓度，默认 9000。
  double get standardConcentration => _concentration;

  /// 标液单位，默认 MPN/L。
  String get standardUnit => _unit;

  /// OCR 服务地址（桌面端识别图片用）。
  String? get ocrApiBaseUrl => _ocrApiBaseUrl;

  /// OCR 服务密钥（可选）。
  String? get ocrApiKey => _ocrApiKey;

  /// OCR 引擎：'local'（本地 Python 引擎，默认）/ 'cloud'（云端服务）。
  String get ocrEngine => _ocrEngine;

  /// 本地 OCR 引擎可执行文件显式路径（可选，留空则用应用目录默认名）。
  String? get ocrEnginePath => _ocrEnginePath;

  /// 外观模式原始值：'system' / 'light' / 'dark'。
  String get themeMode => _themeMode;

  Future<void> setStandardConcentration(double v) async {
    _concentration = v;
    await _prefs?.setDouble(_kConcentration, v);
  }

  Future<void> setStandardUnit(String u) async {
    _unit = u;
    await _prefs?.setString(_kUnit, u);
  }

  Future<void> setOcrApiBaseUrl(String? url) async {
    _ocrApiBaseUrl = url;
    await _prefs?.setString(_kOcrApiBaseUrl, url ?? '');
  }

  Future<void> setOcrApiKey(String? key) async {
    _ocrApiKey = key;
    await _prefs?.setString(_kOcrApiKey, key ?? '');
  }

  Future<void> setOcrEngine(String v) async {
    _ocrEngine = v;
    await _prefs?.setString(_kOcrEngine, v);
  }

  Future<void> setOcrEnginePath(String? path) async {
    _ocrEnginePath = path;
    await _prefs?.setString(_kOcrEnginePath, path ?? '');
  }

  Future<void> setThemeMode(String mode) async {
    _themeMode = mode;
    await _prefs?.setString(_kThemeMode, mode);
  }
}
