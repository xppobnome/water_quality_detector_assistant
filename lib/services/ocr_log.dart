import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Windows 端 OCR 诊断日志（纯 dart:io，不依赖任何插件）。
///
/// 写系统临时目录下的 `wqa_ocr_flutter.log`，与 Python 引擎的
/// `ocr_engine.log` 配对使用。设置页「引擎诊断」可直接查看并复制，
/// 便于把失败现场完整反馈。
class OcrLog {
  const OcrLog._();

  static File get file =>
      File(p.join(Directory.systemTemp.path, 'wqa_ocr_flutter.log'));

  static String get path => file.path;

  static void write(String message) {
    try {
      final String stamp = DateTime.now().toIso8601String();
      file.writeAsStringSync(
        '[$stamp] $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 日志失败绝不影响识别流程。
    }
  }

  /// 读取日志尾部（默认最后 24KB）。
  static String tail({int maxBytes = 24000}) {
    try {
      final File f = file;
      if (!f.existsSync()) return '（暂无 Flutter 日志）';
      final List<int> bytes = f.readAsBytesSync();
      if (bytes.length <= maxBytes) {
        return utf8.decode(bytes, allowMalformed: true);
      }
      return '…（已省略前面 ${bytes.length - maxBytes} 字节）\n'
          '${utf8.decode(bytes.sublist(bytes.length - maxBytes), allowMalformed: true)}';
    } catch (e) {
      return '读取日志失败：$e';
    }
  }

  static void clear() {
    try {
      if (file.existsSync()) file.writeAsStringSync('');
    } catch (_) {
      // 忽略。
    }
  }

  /// Python 引擎日志的真实路径。
  ///
  /// PyInstaller onedir 打包后 `sys._MEIPASS` 指向 `<exe目录>/_internal`，
  /// 引擎会把日志写在那里；同时兼容旧的 exe 同级目录写法。
  static String pythonLogPath(String exePath) {
    final String dir = File(exePath).parent.path;
    final String internal = p.join(dir, '_internal', 'ocr_engine.log');
    if (File(internal).existsSync()) return internal;
    return p.join(dir, 'ocr_engine.log');
  }
}
