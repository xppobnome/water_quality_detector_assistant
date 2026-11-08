import 'dart:async';

import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../models/crop_quad.dart';
import '../services/image_crop_service.dart';
import 'croppable_image.dart';

/// 全屏四点裁剪页（拍照 / 选图后直接进入，不再弹窗询问）。
///
/// 页面本身通过 Navigator 返回 [CropQuad]（用户选「使用原图」时返回 null）；
/// 静态方法 [crop] 拿到四点后调用 `ImageCropService.cropQuad` 做透视拉正，
/// 返回最终图片路径，供上层 [runCropFlow] 逐张串联。
class CropPage extends StatefulWidget {
  const CropPage({
    super.key,
    required this.imagePath,
    this.initial,
    this.index = 1,
    this.total = 1,
  });

  final String imagePath;
  final CropQuad? initial;

  /// 当前是第几张（从 1 起），用于「第 i/N 张」标题。
  final int index;

  /// 本次共几张待裁剪图片。
  final int total;

  /// 返回裁剪后的图片路径；用户选「使用原图」或裁剪失败时返回原路径。
  static Future<String> crop(
    BuildContext context, {
    required String imagePath,
    CropQuad? initial,
    int index = 1,
    int total = 1,
  }) async {
    final NavigatorState nav = Navigator.of(context);
    final CropQuad? quad = await nav.push<CropQuad>(
      MaterialPageRoute<CropQuad>(
        builder: (_) => CropPage(
          imagePath: imagePath,
          initial: initial,
          index: index,
          total: total,
        ),
        fullscreenDialog: true,
      ),
    );
    if (quad == null) return imagePath;

    // 让上一页的退出转场先渲染一帧，避免转场动画期间叠加任何主线程工作。
    if (context.mounted) {
      await WidgetsBinding.instance.endOfFrame;
    }

    // 逐像素重采样已移到后台 isolate，UI 不会卡；这里只给一个不可关闭的
    // 轻量 loading，避免「点了确认没反应像卡死」。
    bool loading = false;
    if (context.mounted) {
      loading = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const PopScope(
            canPop: false,
            child: Center(
              child: SizedBox(
                width: 96,
                height: 96,
                child: Card(child: Center(child: CircularProgressIndicator())),
              ),
            ),
          ),
        ).then<void>((_) {}),
      );
    }
    try {
      return await ImageCropService().cropQuad(imagePath, quad);
    } catch (_) {
      return imagePath;
    } finally {
      if (loading && nav.mounted) nav.pop();
    }
  }

  @override
  State<CropPage> createState() => _CropPageState();
}

class _CropPageState extends State<CropPage> {
  static const CropQuad _fallback = CropQuad(
    tl: Offset(0.05, 0.12),
    tr: Offset(0.95, 0.12),
    br: Offset(0.95, 0.82),
    bl: Offset(0.05, 0.82),
  );

  late CropQuad _quad;

  @override
  void initState() {
    super.initState();
    _quad = (widget.initial ?? _fallback).clamp();
  }

  @override
  Widget build(BuildContext context) {
    final String title = widget.total > 1
        ? '框选数据表格（第 ${widget.index}/${widget.total} 张）'
        : '框选数据表格';
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('使用原图', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double available = constraints.maxHeight;
            // 提示条约 58px + 底部留白，裁剪图区尽量占满剩余高度（≈90% 屏幕）。
            final double previewHeight = (available * 0.86).clamp(
              160.0,
              1400.0,
            );
            return SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: CroppableImage(
                  imagePath: widget.imagePath,
                  initial: _quad,
                  previewHeight: previewHeight,
                  onChanged: (CropQuad q) => _quad = q,
                  hint:
                      '拖动四个角，使四边形完整框住仪器屏幕中的数据表格'
                      '（每个角可单独调整，避开标题栏、菜单和底部按钮）',
                ),
              ),
            );
          },
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(_quad),
            icon: const Icon(Icons.check, size: 20),
            label: const Text('确认裁剪并继续'),
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
