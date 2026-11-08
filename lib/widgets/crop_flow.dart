import 'package:flutter/material.dart';

import '../models/crop_quad.dart';
import 'crop_page.dart';

/// 统一的「拍照 / 选图 → 四点裁剪 → 输出最终图片」流程。
///
/// 所有来源（自定义拍照、相册、桌面选图）都**直接**逐张进入全屏
/// [CropPage]，不再弹「是否需要裁剪」询问框。多张时标题显示「第 i/N 张」。
///
/// 用户选「使用原图」或裁剪失败时回退为原路径，不阻断流程。
Future<List<String>> runCropFlow(
  BuildContext context,
  List<String> paths, {
  CropQuad? initial,
}) async {
  if (paths.isEmpty) return <String>[];

  final List<String> result = <String>[];
  for (int i = 0; i < paths.length; i++) {
    if (!context.mounted) {
      result.add(paths[i]);
      continue;
    }
    result.add(
      await CropPage.crop(
        context,
        imagePath: paths[i],
        initial: initial,
        index: i + 1,
        total: paths.length,
      ),
    );
    // 保持串行（避免并发弹多个裁剪页），但让上一张的退出转场先完成一帧，
    // 多张时观感更顺；绝不在这里一次性解码所有图片。
    if (i + 1 < paths.length && context.mounted) {
      await WidgetsBinding.instance.endOfFrame;
    }
  }
  return result;
}
