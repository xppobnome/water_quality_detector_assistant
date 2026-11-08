import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/constants.dart';

/// 二维码展示卡片（桌面端供手机扫码连接）。
class QrCodeCard extends StatelessWidget {
  const QrCodeCard({super.key, required this.content, this.size = 220});

  final String content;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: QrImageView(
                data: content,
                version: QrVersions.auto,
                size: size,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            const Text('请用手机扫码连接', style: TextStyle(color: kNeutralGrey)),
          ],
        ),
      ),
    );
  }
}
