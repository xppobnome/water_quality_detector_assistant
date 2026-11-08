import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../models/transfer_file.dart';

/// 传输文件列表项（含进度）。
class FileListTile extends StatelessWidget {
  const FileListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.progress,
  });

  final String title;
  final String? subtitle;
  final TransferProgress? progress;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.description_outlined, color: kPrimaryColor),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: progress == null
          ? (subtitle == null ? null : Text(subtitle!))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                LinearProgressIndicator(
                  value: progress!.ratio,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
                const SizedBox(height: 4),
                Text('${progress!.sent} / ${progress!.total} B'),
              ],
            ),
    );
  }
}
