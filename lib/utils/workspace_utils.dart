/// 工作空间 UI 通用小工具。
library;

import '../services/standard_definitions.dart';

/// 由「检测项目」文本推断国标验证使用的参数 id。
///
/// 统一委托给 [gbItemIdOfLabel]，保证与「检测项目」下拉选项
/// （总磷 / 氨氮 / 总氮 / COD）完全一致，未命中时回退到「总磷」，
/// 使 [standardById] 总能取到已内置的标准。
String guessStandardParameter(String item) => gbItemIdOfLabel(item);

/// 日期时间展示：yyyy-MM-dd HH:mm。
String formatDateTime(DateTime dt) =>
    ''
    '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} '
    '${_pad(dt.hour)}:${_pad(dt.minute)}';

String _pad(int n) => n.toString().padLeft(2, '0');

/// 时间戳文件名片段：yyyyMMdd_HHmmss。
String timestampStamp(DateTime dt) =>
    ''
    '${dt.year}${_pad(dt.month)}${_pad(dt.day)}_'
    '${_pad(dt.hour)}${_pad(dt.minute)}${_pad(dt.second)}';

/// 人类可读文件大小。
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
