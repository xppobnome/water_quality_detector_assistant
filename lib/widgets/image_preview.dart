import 'dart:io';

import 'package:flutter/material.dart';

import '../core/constants.dart';
import 'crop_page.dart';

/// 全屏图片预览：黑底 + 双指缩放/拖动，并可直接进入四角裁剪。
///
/// [show] 返回裁剪后的新图片路径；用户只是查看（或选了「使用原图」）时返回
/// null，由调用方决定是否替换原图片。
class ImagePreview extends StatelessWidget {
  const ImagePreview({super.key, required this.imagePath});

  final String imagePath;

  /// 打开全屏预览；点「裁剪此图」会接着打开四点裁剪页。
  static Future<String?> show(
    BuildContext context, {
    required String imagePath,
  }) async {
    final bool? wantCrop = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => ImagePreview(imagePath: imagePath),
      ),
    );
    if (wantCrop != true || !context.mounted) return null;
    final String cropped = await CropPage.crop(
      context,
      imagePath: imagePath,
      index: 1,
      total: 1,
    );
    return cropped == imagePath ? null : cropped;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('图片预览'),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.crop, size: 18, color: kPrimaryLight),
            label: const Text('裁剪此图', style: TextStyle(color: kPrimaryLight)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: InteractiveViewer(
        minScale: 0.5,
        maxScale: 6,
        child: Center(
          child: Image.file(
            File(imagePath),
            // 明确按原图宽高比显示，绝不使用 fill 拉伸。
            // 不设 cacheWidth：预览页需要保留全分辨率以支撑双指放大看细节，
            // 且是单张查看，不会像多图缩略图那样批量解码。
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const _PreviewPlaceholder(),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.crop_free, size: 20),
            label: const Text('裁剪这张图片'),
            style: FilledButton.styleFrom(
              backgroundColor: kPrimaryColor,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewPlaceholder extends StatelessWidget {
  const _PreviewPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.broken_image_outlined, size: 64, color: Colors.white54),
        SizedBox(height: 12),
        Text(
          '图片加载失败，文件可能已被移动或删除',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
      ],
    );
  }
}
