/// 回收站条目：记录被删除工作空间的元信息，用于恢复与 30 天自动清理。
class TrashEntry {
  TrashEntry({
    required this.id,
    required this.name,
    required this.folderName,
    required this.trashedAt,
  });

  /// 原工作空间 id。
  final String id;

  /// 显示名（拼接名，缺失时回退 name）。
  final String name;

  /// 原文件夹名（恢复时回置）。
  final String folderName;

  /// 进入回收站的时间。
  final DateTime trashedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'folderName': folderName,
    'trashedAt': trashedAt.toIso8601String(),
  };

  factory TrashEntry.fromJson(Map<String, dynamic> j) => TrashEntry(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    folderName: j['folderName'] as String? ?? '',
    trashedAt: j['trashedAt'] == null
        ? DateTime.now()
        : (DateTime.tryParse(j['trashedAt'] as String) ?? DateTime.now()),
  );
}
