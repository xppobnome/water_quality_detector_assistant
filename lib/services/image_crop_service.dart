import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/crop_quad.dart';
import '../models/crop_rect.dart';

/// 像素级图片裁剪 / 透视拉正（纯 Flutter / dart:ui，跨 Android + Windows）。
///
/// 不引入 `package:image`，因为本项目 `excel 4.0.6` 依赖 `archive ^3.6.1`，
/// 而 `image ^4` 依赖 `archive ^4`，会造成 pub 版本冲突。
///
/// - [cropImage]：普通矩形裁剪，沿用 Canvas.drawImageRect；
/// - [cropQuad]：任意四边形 → 矩形的透视拉正，纯 CPU 逐像素双线性采样，
///   不使用 `Canvas.drawVertices` 纹理映射（Impeller Vulkan 下不稳）。
/// 跨 isolate 传递的纯数据请求：只含 Uint8List / int / List<double>。
///
/// isolate 边界不能传 `ui.Image` / `ui.Codec` / `ByteData`，所以主 isolate
/// 负责解码取 rawRgba 字节与求单应系数，后台 isolate 只做纯数值重采样。
class _WarpParams {
  const _WarpParams({
    required this.src,
    required this.srcW,
    required this.srcH,
    required this.outW,
    required this.outH,
    required this.k,
  });

  /// 原图 rgba8888 像素，长度 = srcW * srcH * 4。
  final Uint8List src;
  final int srcW;
  final int srcH;
  final int outW;
  final int outH;

  /// 单应系数 [a, b, c, d, e, f, g, h]，由主 isolate 的
  /// [ImageCropService.solveHomography] 计算后传入。
  final List<double> k;
}

/// 纯 CPU 逐像素双线性重采样，可在后台 isolate 执行。
///
/// 该函数与 [ImageCropService.cropQuad] 改造前的内联循环逐行等价：
/// 目标单位矩形 (u,v) → 单应反算源归一化坐标 → 乘原图宽高 → 双线性插值；
/// 越界 / 分母奇异的像素填白。只依赖 Uint8List / int / double / List<double>，
/// 不含任何 dart:ui 类型。
Uint8List _warpPixels(_WarpParams p) {
  final Uint8List src = p.src;
  final int w = p.srcW;
  final int h = p.srcH;
  final int outW = p.outW;
  final int outH = p.outH;
  final List<double> k = p.k;
  final double a = k[0];
  final double b = k[1];
  final double c = k[2];
  final double d = k[3];
  final double e = k[4];
  final double f = k[5];
  final double g = k[6];
  final double hh = k[7];

  final Uint8List out = Uint8List(outW * outH * 4);
  final int rowStride = w * 4;
  for (int v = 0; v < outH; v++) {
    final double vv = (v + 0.5) / outH;
    final double denV = hh * vv + 1.0;
    for (int u = 0; u < outW; u++) {
      final int oi = (v * outW + u) * 4;
      final double uu = (u + 0.5) / outW;
      final double den = g * uu + denV;
      if (den.abs() < 1e-9) {
        _fillWhitePixel(out, oi);
        continue;
      }
      // 单应反算出的源坐标仍是归一化值，乘原图宽高得到像素坐标。
      final double sx = ((a * uu + b * vv + c) / den) * w;
      final double sy = ((d * uu + e * vv + f) / den) * h;
      if (sx < 0 || sy < 0 || sx >= w - 1 || sy >= h - 1) {
        _fillWhitePixel(out, oi);
        continue;
      }
      final int x0 = sx.floor();
      final int y0 = sy.floor();
      final double fx = sx - x0;
      final double fy = sy - y0;
      final int i00 = y0 * rowStride + x0 * 4;
      final int i10 = i00 + 4;
      final int i01 = i00 + rowStride;
      final int i11 = i01 + 4;
      for (int ch = 0; ch < 4; ch++) {
        final double top = src[i00 + ch] * (1 - fx) + src[i10 + ch] * fx;
        final double bottom = src[i01 + ch] * (1 - fx) + src[i11 + ch] * fx;
        out[oi + ch] = (top * (1 - fy) + bottom * fy)
            .round()
            .clamp(0, 255)
            .toInt();
      }
    }
  }
  return out;
}

void _fillWhitePixel(Uint8List out, int offset) {
  out[offset] = 255;
  out[offset + 1] = 255;
  out[offset + 2] = 255;
  out[offset + 3] = 255;
}

class ImageCropService {
  /// 矩形裁剪；[rect] 无效或覆盖整图时直接返回原路径（避免无谓重编码）。
  Future<String> cropImage(
    String sourcePath,
    CropRect rect, {
    String? outDir,
  }) async {
    final File source = File(sourcePath);
    if (!await source.exists()) {
      throw Exception('图片不存在：$sourcePath');
    }
    final CropRect r = rect.clamp();
    if (!r.isValid ||
        (r.left <= 0 && r.top <= 0 && r.right >= 1 && r.bottom >= 1)) {
      return sourcePath;
    }

    final Uint8List bytes = await source.readAsBytes();
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    ui.Image? decoded;
    ui.Image? cropped;
    try {
      final ui.FrameInfo frame = await codec.getNextFrame();
      decoded = frame.image;
      final int w = decoded.width;
      final int h = decoded.height;

      int x = (r.left * w).floor();
      int y = (r.top * h).floor();
      int cw = ((r.right - r.left) * w).ceil();
      int ch = ((r.bottom - r.top) * h).ceil();
      if (x < 0) x = 0;
      if (y < 0) y = 0;
      if (x + cw > w) cw = w - x;
      if (y + ch > h) ch = h - y;
      if (cw <= 0 || ch <= 0 || x >= w || y >= h) return sourcePath;

      final ui.Rect src = ui.Rect.fromLTWH(
        x.toDouble(),
        y.toDouble(),
        cw.toDouble(),
        ch.toDouble(),
      );
      final ui.Rect dst = ui.Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble());

      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(recorder);
      canvas.drawImageRect(decoded, src, dst, ui.Paint());
      final ui.Picture picture = recorder.endRecording();
      cropped = await picture.toImage(cw, ch);
      final ByteData? data = await cropped.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (data == null) throw Exception('裁剪结果 PNG 编码失败');
      final Uint8List png = data.buffer.asUint8List();

      return await _writePng(sourcePath, png, outDir, 'crop');
    } finally {
      cropped?.dispose();
      decoded?.dispose();
      codec.dispose();
    }
  }

  /// 四点透视裁剪：把 [quad] 围成的任意四边形拉正为矩形输出。
  ///
  /// 步骤：解码原图取 rawRgba → 目标单位矩形到源四边形的单应（8×9 增广矩阵
  /// 高斯消元）→ 逐输出像素反算源坐标并双线性插值 → rgba8888 编码成 PNG。
  ///
  /// 矩阵奇异 / 任一异常 / [quad] 非法 → 回退 [cropImage] 的外接矩形裁剪。
  Future<String> cropQuad(
    String sourcePath,
    CropQuad quad, {
    String? outDir,
  }) async {
    // 降级入口：只依赖外接矩形与原有 cropImage，逻辑保持单一实现。
    Future<String> fallback() =>
        cropImage(sourcePath, quad.toBoundingRect(), outDir: outDir);

    if (!quad.isValid) return await fallback();

    final File source = File(sourcePath);
    if (!await source.exists()) {
      throw Exception('图片不存在：$sourcePath');
    }

    ui.Codec? codec;
    ui.Image? decoded;
    ui.Image? warped;
    try {
      final Uint8List bytes = await source.readAsBytes();
      codec = await ui.instantiateImageCodec(bytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      decoded = frame.image;
      final int w = decoded.width;
      final int h = decoded.height;
      if (w <= 0 || h <= 0) return await fallback();

      final ByteData? raw = await decoded.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (raw == null) return await fallback();
      final Uint8List src = Uint8List.view(
        raw.buffer,
        raw.offsetInBytes,
        raw.lengthInBytes,
      );
      if (src.length < w * h * 4) return await fallback();

      // 源四角（归一化）换算成像素点，顺序 tl / tr / br / bl。
      final List<ui.Offset> q = quad.points;
      final List<ui.Offset> px = q
          .map((ui.Offset o) => ui.Offset(o.dx * w, o.dy * h))
          .toList();
      double len(ui.Offset a, ui.Offset b) => math.sqrt(
        (a.dx - b.dx) * (a.dx - b.dx) + (a.dy - b.dy) * (a.dy - b.dy),
      );

      // 输出矩形尺寸：宽度取上/下边平均，高度取左/右边平均，上限 3000。
      int outW = ((len(px[0], px[1]) + len(px[3], px[2])) / 2).round();
      int outH = ((len(px[0], px[3]) + len(px[1], px[2])) / 2).round();
      outW = outW.clamp(1, 3000);
      outH = outH.clamp(1, 3000);
      if (outW < 1 || outH < 1) return await fallback();

      final List<double>? k = solveHomography(q);
      if (k == null) return await fallback();
      // 逐像素双线性采样（上限 3000×3000，最多约 3600 万次迭代）搬到后台
      // isolate：主 isolate 只做解码、PNG 编码与写盘，UI 不再被这段纯计算阻塞。
      // _WarpParams 只含 Uint8List / int / List<double>，没有 ui.Image /
      // ui.Codec / ByteData 跨 isolate。
      final Uint8List out = await Isolate.run<Uint8List>(
        () => _warpPixels(
          _WarpParams(src: src, srcW: w, srcH: h, outW: outW, outH: outH, k: k),
        ),
      );

      final Completer<ui.Image> completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(out, outW, outH, ui.PixelFormat.rgba8888, (
        ui.Image img,
      ) {
        if (!completer.isCompleted) completer.complete(img);
      });
      warped = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw StateError('rgba8888 解码超时'),
      );
      final ByteData? pngData = await warped.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (pngData == null) return await fallback();
      final Uint8List png = Uint8List.view(
        pngData.buffer,
        pngData.offsetInBytes,
        pngData.lengthInBytes,
      );
      return await _writePng(sourcePath, png, outDir, 'cropq');
    } catch (_) {
      return await fallback();
    } finally {
      warped?.dispose();
      decoded?.dispose();
      codec?.dispose();
    }
  }

  /// 求「目标单位矩形 (0,0)(1,0)(1,1)(0,1) → 源四边形」的单应系数。
  ///
  /// 方程：x=(a*u+b*v+c)/(g*u+h*v+1)，y=(d*u+e*v+f)/(g*u+h*v+1)。
  /// 4 对点列出 8 个线性方程解 8 个未知数 a..h；奇异（退化四点）返回 null。
  /// 公开为 static 便于单测覆盖降级判定，且坐标均为 0..1，数值稳定。
  static List<double>? solveHomography(List<ui.Offset> srcQuad) {
    if (srcQuad.length != 4) return null;
    const List<ui.Offset> dst = <ui.Offset>[
      ui.Offset(0, 0),
      ui.Offset(1, 0),
      ui.Offset(1, 1),
      ui.Offset(0, 1),
    ];
    final List<List<double>> m = List<List<double>>.generate(
      8,
      (_) => List<double>.filled(9, 0.0),
    );
    for (int i = 0; i < 4; i++) {
      final double u = dst[i].dx;
      final double v = dst[i].dy;
      final double x = srcQuad[i].dx;
      final double y = srcQuad[i].dy;
      final int rx = i * 2;
      final int ry = rx + 1;
      // x 方程：a*u + b*v + c - g*u*x - h*v*x = x
      m[rx][0] = u;
      m[rx][1] = v;
      m[rx][2] = 1.0;
      m[rx][6] = -u * x;
      m[rx][7] = -v * x;
      m[rx][8] = x;
      // y 方程：d*u + e*v + f - g*u*y - h*v*y = y
      m[ry][3] = u;
      m[ry][4] = v;
      m[ry][5] = 1.0;
      m[ry][6] = -u * y;
      m[ry][7] = -v * y;
      m[ry][8] = y;
    }
    return _solve8x9(m);
  }

  /// 8×9 增广矩阵高斯消元（列主元选取 + 回代）；奇异返回 null。
  static List<double>? _solve8x9(List<List<double>> m) {
    const int n = 8;
    for (int col = 0; col < n; col++) {
      int pivot = col;
      for (int r = col + 1; r < n; r++) {
        if (m[r][col].abs() > m[pivot][col].abs()) pivot = r;
      }
      if (m[pivot][col].abs() < 1e-12) return null;
      if (pivot != col) {
        final List<double> tmp = m[pivot];
        m[pivot] = m[col];
        m[col] = tmp;
      }
      final double pv = m[col][col];
      for (int r = col + 1; r < n; r++) {
        final double factor = m[r][col] / pv;
        if (factor == 0.0) continue;
        m[r][col] = 0.0;
        for (int c = col + 1; c <= n; c++) {
          m[r][c] -= factor * m[col][c];
        }
      }
    }
    final List<double> x = List<double>.filled(n, 0.0);
    for (int i = n - 1; i >= 0; i--) {
      double sum = m[i][n];
      for (int j = i + 1; j < n; j++) {
        sum -= m[i][j] * x[j];
      }
      final double diag = m[i][i];
      if (diag.abs() < 1e-12) return null;
      x[i] = sum / diag;
    }
    return x;
  }

  /// 统一的 PNG 落盘逻辑（cropImage / cropQuad 复用）。
  Future<String> _writePng(
    String sourcePath,
    Uint8List png,
    String? outDir,
    String prefix,
  ) async {
    final Directory dir = outDir != null
        ? Directory(outDir)
        : await getTemporaryDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    final String name =
        '${prefix}_${DateTime.now().millisecondsSinceEpoch}_'
        '${p.basenameWithoutExtension(sourcePath)}.png';
    final File out = File(p.join(dir.path, name));
    await out.writeAsBytes(png);
    return out.path;
  }
}
