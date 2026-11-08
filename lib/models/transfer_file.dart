/// 传输文件元信息。
class TransferFile {
  TransferFile({required this.name, required this.size, required this.path});

  /// 文件名。
  final String name;

  /// 字节大小。
  final int size;

  /// 本地落盘路径。
  final String path;

  /// 可读大小。
  String get sizeLabel {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// 传输进度。
class TransferProgress {
  TransferProgress({
    required this.fileName,
    required this.sent,
    required this.total,
  });

  final String fileName;
  final int sent;
  final int total;

  double get ratio => total == 0 ? 0 : (sent / total).clamp(0.0, 1.0);
}
