/// 工具产出的待归档文件描述。
///
/// [path] 是磁盘上的临时/源文件路径，[name] 是建议的自定义文件名（含扩展名），
/// [kind] 为 'excel' | 'image' | 'json' | 'pdf' | 'other'，仅用于 UI 图标提示。
class ReportFile {
  const ReportFile({
    required this.path,
    required this.name,
    this.kind = 'other',
  });

  final String path;
  final String name;
  final String kind;
}
