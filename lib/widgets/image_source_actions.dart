import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/constants.dart';
import '../core/platform.dart';
import 'camera_capture_page.dart';

/// 统一的图片来源入口。
///
/// 移动端保留「拍照」与「相册」：拍照走自定义相机预览页，可连续拍多张，
/// 点「完成」后把所有结果一次性交给调用方，逐张直接进入全屏四点裁剪；
/// 相册与桌面选图同样支持多选、直接进入裁剪，不再弹窗询问。
class ImageSourceActions extends StatelessWidget {
  const ImageSourceActions({
    super.key,
    required this.onCaptured,
    required this.onPaths,
    this.busy = false,
  });

  /// 自定义拍照结果（可含多张，每张自带取景框建议四点）。
  final void Function(List<CameraCaptureResult> results) onCaptured;

  /// 相册 / 桌面选图结果。
  final void Function(List<String> paths) onPaths;
  final bool busy;

  Future<void> _camera(BuildContext context) async {
    // 在 await 之前取出 messenger，避免异步间隙后继续使用 BuildContext。
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final List<CameraCaptureResult> results = await CameraCapturePage.capture(
        context,
      );
      if (results.isNotEmpty) onCaptured(results);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('拍照失败：$e')));
    }
  }

  Future<void> _gallery(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final List<XFile> images = await ImagePicker().pickMultiImage();
      if (images.isNotEmpty) {
        onPaths(images.map((XFile x) => x.path).toList());
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('选择图片失败：$e')));
    }
  }

  Future<void> _files(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final List<PlatformFile> result = await FilePicker.pickFiles(
        type: FileType.image,
      );
      final List<String> paths = result
          .map((PlatformFile f) => f.path)
          .whereType<String>()
          .toList();
      if (paths.isNotEmpty) onPaths(paths);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('选择图片失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        if (isMobile) ...<Widget>[
          FilledButton.icon(
            onPressed: busy ? null : () => _camera(context),
            icon: const Icon(Icons.photo_camera_outlined, size: 18),
            label: const Text('拍照'),
          ),
          OutlinedButton.icon(
            onPressed: busy ? null : () => _gallery(context),
            icon: const Icon(Icons.photo_library_outlined, size: 18),
            label: const Text('相册'),
          ),
        ],
        if (isDesktop)
          OutlinedButton.icon(
            onPressed: busy ? null : () => _files(context),
            icon: const Icon(Icons.folder_open_outlined, size: 18),
            label: const Text('选择图片'),
          ),
      ],
    );
  }
}

/// 拍照引导提示卡。
class CaptureGuideCard extends StatelessWidget {
  const CaptureGuideCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kPrimaryLight,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.tips_and_updates_outlined, color: kPrimaryColor, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              '拍照时对准屏幕：把仪器的数据表格完整放进中间的长方形框内，'
              '尽量保持水平、避免反光。可连续拍多张，点「完成」后逐张进入'
              '四点裁剪，拖动任意一个角精确框住表格即可（四角互不影响）。',
              style: TextStyle(fontSize: 12, color: kPrimaryColor),
            ),
          ),
        ],
      ),
    );
  }
}
