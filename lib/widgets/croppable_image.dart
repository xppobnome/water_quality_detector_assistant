import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/crop_quad.dart';

/// 纯数值计算：BoxFit.contain 下图片在容器内居中显示的实际矩形。
///
/// 返回 `[left, top, width, height]`。只依赖 double 运算、不依赖 dart:ui，
/// 便于用纯 Dart 脚本独立验证宽图 / 高图 / 方图的宽高比与居中偏移。
/// 裁剪四点始终是相对**原图**的归一化坐标（0..1），渲染时映射到该矩形，
/// 因此 ImageCropService.cropQuad 无需改动，透视裁剪输出不会偏移。
List<double> containRectValues(
  double containerW,
  double containerH,
  double imageW,
  double imageH,
) {
  if (containerW <= 0 || containerH <= 0 || imageW <= 0 || imageH <= 0) {
    return <double>[0.0, 0.0, 0.0, 0.0];
  }
  final double scale = math.min(containerW / imageW, containerH / imageH);
  final double w = imageW * scale;
  final double h = imageH * scale;
  return <double>[(containerW - w) / 2.0, (containerH - h) / 2.0, w, h];
}

/// 把 [containRectValues] 的结果转成 [Rect]，供 widget / painter 使用。
Rect containRect(Size container, Size image) {
  final List<double> v = containRectValues(
    container.width,
    container.height,
    image.width,
    image.height,
  );
  return Rect.fromLTWH(v[0], v[1], v[2], v[3]);
}

/// 预览解码宽度上限。只影响预览与宽高比读取；透视裁剪仍读原图全分辨率。
const int _kPreviewDecodeWidth = 1200;

/// 四角完全独立的可拖裁剪框（纯 Flutter 手写，跨 Android / Windows）。
///
/// 四个角是四个独立的点：拖动 tl 时 tr / br / bl 三点坐标绝对不变，
/// 裁剪区可变成任意四边形；输出时由 ImageCropService.cropQuad 透视拉正。
///
/// 预览用 [BoxFit.contain] 按原图宽高比居中显示，四点归一化坐标仍相对
/// **原图** 0..1；所有交互与绘制都映射到 [containRect] 算出的图片矩形，
/// 容器留白部分不参与裁剪。
class CroppableImage extends StatefulWidget {
  const CroppableImage({
    super.key,
    required this.imagePath,
    required this.onChanged,
    this.initial = const CropQuad(
      tl: Offset(0.08, 0.08),
      tr: Offset(0.92, 0.08),
      br: Offset(0.92, 0.92),
      bl: Offset(0.08, 0.92),
    ),
    this.hint = '拖动四角，使四边形完整框住数据表格（每个角可单独调整）',
    this.previewHeight,
  });

  final String imagePath;
  final CropQuad initial;
  final ValueChanged<CropQuad> onChanged;
  final String hint;

  /// 预览区最大高度；为空时按宽度 * 0.62 自适应。
  /// 图片按比例 contain 居中，留白不参与裁剪。
  final double? previewHeight;

  @override
  State<CroppableImage> createState() => _CroppableImageState();
}

class _CroppableImageState extends State<CroppableImage> {
  late CropQuad _quad;
  late Future<ui.Size> _metaFuture;
  final GlobalKey _imageKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _quad = widget.initial.clamp();
    _metaFuture = _readImageMeta(widget.imagePath);
  }

  @override
  void didUpdateWidget(CroppableImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      _quad = widget.initial.clamp();
      _metaFuture = _readImageMeta(widget.imagePath);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.onChanged(_quad),
      );
    }
  }

  /// 只解码一张缩略图取宽高比；codec 与 image 都必须释放。
  /// [ui.instantiateImageCodec] 的 targetWidth 限制了解码分辨率，
  /// 避免预览页把 2000+px 大图全尺寸解码进内存。
  static Future<ui.Size> _readImageMeta(String path) async {
    final Uint8List bytes = await File(path).readAsBytes();
    final ui.Codec codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: _kPreviewDecodeWidth,
    );
    ui.Image? image;
    try {
      final ui.FrameInfo frame = await codec.getNextFrame();
      image = frame.image;
      return ui.Size(image.width.toDouble(), image.height.toDouble());
    } finally {
      image?.dispose();
      codec.dispose();
    }
  }

  /// 拖拽路径只回传当前四点，绝不调用任何会改动其它点的逻辑。
  void _emit() => widget.onChanged(_quad);

  /// 防止除零：图片矩形宽高在极端布局下可能为 0。
  static double _span(double v) => v > 0 ? v : 1.0;

  /// 角序号：0=tl 1=tr 2=br 3=bl。
  ///
  /// 关键：增量除以**图片实际矩形**的宽高（不是整个容器），这样宽高比与
  /// 容器差异很大时手柄仍然跟手；其余三点直接把旧 [CropQuad] 的 [Offset]
  /// 原样带入，不做钳制、不交换、不按外接矩形重算。
  void _onCornerDrag(int corner, DragUpdateDetails d, Rect imageRect) {
    final double dx = d.delta.dx / _span(imageRect.width);
    final double dy = d.delta.dy / _span(imageRect.height);
    final CropQuad q = _quad;
    final Offset target;
    switch (corner) {
      case 0:
        target = q.tl;
        break;
      case 1:
        target = q.tr;
        break;
      case 2:
        target = q.br;
        break;
      default:
        target = q.bl;
    }
    final Offset moved = Offset(
      (target.dx + dx).clamp(0.0, 1.0).toDouble(),
      (target.dy + dy).clamp(0.0, 1.0).toDouble(),
    );

    // 另外三个 Offset 取自 q，逐字保持不变。
    final CropQuad next;
    switch (corner) {
      case 0:
        next = CropQuad(tl: moved, tr: q.tr, br: q.br, bl: q.bl);
        break;
      case 1:
        next = CropQuad(tl: q.tl, tr: moved, br: q.br, bl: q.bl);
        break;
      case 2:
        next = CropQuad(tl: q.tl, tr: q.tr, br: moved, bl: q.bl);
        break;
      default:
        next = CropQuad(tl: q.tl, tr: q.tr, br: q.br, bl: moved);
    }
    // 退化成一条线 / 一个点时忽略本次拖拽，而不是去推动其它点。
    if (!next.isValid) return;
    setState(() => _quad = next);
    _emit();
  }

  /// 框内平移：四点加**同一个**偏移，形状与四点相对关系完全不变；
  /// 偏移量先按外接范围约束，保证四点都留在 [0,1] 内。
  void _onPan(DragUpdateDetails d, Rect imageRect) {
    final double dx = d.delta.dx / _span(imageRect.width);
    final double dy = d.delta.dy / _span(imageRect.height);
    final CropQuad q = _quad;
    double minX = q.tl.dx;
    double maxX = q.tl.dx;
    double minY = q.tl.dy;
    double maxY = q.tl.dy;
    for (final Offset o in q.points) {
      if (o.dx < minX) minX = o.dx;
      if (o.dx > maxX) maxX = o.dx;
      if (o.dy < minY) minY = o.dy;
      if (o.dy > maxY) maxY = o.dy;
    }
    double shiftX = dx;
    double shiftY = dy;
    if (minX + shiftX < 0.0) shiftX = -minX;
    if (maxX + shiftX > 1.0) shiftX = 1.0 - maxX;
    if (minY + shiftY < 0.0) shiftY = -minY;
    if (maxY + shiftY > 1.0) shiftY = 1.0 - maxY;
    final Offset delta = Offset(shiftX, shiftY);
    final CropQuad next = CropQuad(
      tl: _clampPoint(q.tl + delta),
      tr: _clampPoint(q.tr + delta),
      br: _clampPoint(q.br + delta),
      bl: _clampPoint(q.bl + delta),
    );
    if (!next.isValid) return;
    setState(() => _quad = next);
    _emit();
  }

  static Offset _clampPoint(Offset o) =>
      Offset(o.dx.clamp(0.0, 1.0).toDouble(), o.dy.clamp(0.0, 1.0).toDouble());

  /// 初始化 / 重置路径可用 full.clamp()（非拖拽路径）。
  void _reset() {
    setState(() => _quad = CropQuad.full.clamp());
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: <Widget>[
              const Icon(Icons.crop, size: 18, color: Color(0xFF1976D2)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.hint,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF1976D2),
                  ),
                ),
              ),
              TextButton(
                onPressed: _reset,
                child: const Text('全图', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double width = constraints.maxWidth;
            final double height = widget.previewHeight ?? width * 0.62;
            final Size size = Size(width, height);
            return SizedBox(
              key: _imageKey,
              width: width,
              height: height,
              child: FutureBuilder<ui.Size>(
                future: _metaFuture,
                builder: (BuildContext context, AsyncSnapshot<ui.Size> snap) {
                  // 尺寸未就绪时按常见 16:10 比例渲染，几十毫秒后自动修正。
                  final ui.Size imageSize =
                      snap.data ?? const ui.Size(1600, 1000);
                  return _buildStack(size, containRect(size, imageSize));
                },
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildStack(Size size, Rect imageRect) {
    final CropQuad q = _quad;
    final bounds = q.toBoundingRect();
    final double iw = imageRect.width;
    final double ih = imageRect.height;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: ClipRect(
            child: Image.file(
              File(widget.imagePath),
              fit: BoxFit.contain,
              cacheWidth: _kPreviewDecodeWidth,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const Center(
                child: Icon(Icons.broken_image, color: Colors.grey),
              ),
            ),
          ),
        ),
        // 遮罩外侧仍是整个容器，图片外的留白也会被压暗，视觉更清楚。
        Positioned.fill(
          child: CustomPaint(painter: _CropPainter(q, imageRect)),
        ),
        // 框内平移命中区（限定在图片矩形内），角手柄在更上层优先响应。
        Positioned(
          left: imageRect.left + bounds.left * iw + 8,
          top: imageRect.top + bounds.top * ih + 8,
          width: ((bounds.right - bounds.left) * iw - 16)
              .clamp(0.0, iw)
              .toDouble(),
          height: ((bounds.bottom - bounds.top) * ih - 16)
              .clamp(0.0, ih)
              .toDouble(),
          child: GestureDetector(
            onPanUpdate: (DragUpdateDetails d) => _onPan(d, imageRect),
            behavior: HitTestBehavior.translucent,
          ),
        ),
        // 四角手柄：只做透明命中区，视觉圆点由 _CropPainter 绘制。
        for (int i = 0; i < 4; i++) _cornerHandle(i, q, imageRect),
      ],
    );
  }

  Widget _cornerHandle(int i, CropQuad q, Rect imageRect) {
    final Offset point = q.points[i];
    const double handle = 40;
    return Positioned(
      left: imageRect.left + point.dx * imageRect.width - handle / 2,
      top: imageRect.top + point.dy * imageRect.height - handle / 2,
      child: GestureDetector(
        onPanUpdate: (DragUpdateDetails d) => _onCornerDrag(i, d, imageRect),
        behavior: HitTestBehavior.opaque,
        child: const SizedBox(width: handle, height: handle),
      ),
    );
  }
}

/// 遮罩（全容器矩形 − 四边形）+ 四条边 + 两条对角参考线 + 四个角圆点手柄。
///
/// 四点的屏幕坐标 = [imageRect] 的偏移 + 归一化坐标 × 图片实际显示尺寸，
/// 因此宽图 / 高图 / 方图下遮罩框始终与图片内容对齐。
class _CropPainter extends CustomPainter {
  const _CropPainter(this.quad, this.imageRect);

  final CropQuad quad;
  final Rect imageRect;

  @override
  void paint(Canvas canvas, Size size) {
    final List<Offset> p = quad.points
        .map(
          (Offset o) => Offset(
            imageRect.left + o.dx * imageRect.width,
            imageRect.top + o.dy * imageRect.height,
          ),
        )
        .toList();
    final Path quadPath = Path()
      ..moveTo(p[0].dx, p[0].dy)
      ..lineTo(p[1].dx, p[1].dy)
      ..lineTo(p[2].dx, p[2].dy)
      ..lineTo(p[3].dx, p[3].dy)
      ..close();
    final Path fullPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final Paint dim = Paint()
      ..color = Colors.black.withValues(alpha: 0.45)
      ..style = PaintingStyle.fill;
    canvas.drawPath(
      Path.combine(PathOperation.difference, fullPath, quadPath),
      dim,
    );

    final Paint border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawPath(quadPath, border);

    final Paint guide = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    canvas.drawLine(p[0], p[2], guide); // tl → br
    canvas.drawLine(p[1], p[3], guide); // tr → bl

    final Paint dotFill = Paint()..color = Colors.white;
    final Paint dotBorder = Paint()
      ..color = const Color(0xFF1976D2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    for (final Offset o in p) {
      canvas.drawCircle(o, 9, dotFill);
      canvas.drawCircle(o, 9, dotBorder);
    }
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) {
    final CropQuad a = oldDelegate.quad;
    final CropQuad b = quad;
    return a.tl != b.tl ||
        a.tr != b.tr ||
        a.br != b.br ||
        a.bl != b.bl ||
        oldDelegate.imageRect != imageRect;
  }
}
