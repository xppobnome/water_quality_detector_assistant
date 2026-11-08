import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/platform.dart';
import '../models/crop_quad.dart';

/// 一次自定义拍照的结果。
///
/// [frame] 是取景框在相机预览中的归一化四点位置，作为下一步四点裁剪的
/// 初始区域——拍照时对齐了表格，裁剪时就只需微调四角。
class CameraCaptureResult {
  const CameraCaptureResult({required this.path, required this.frame});

  final String path;
  final CropQuad frame;
}

/// 自定义拍照页：实时相机预览 + 中间一个长方形取景框，支持连续拍多张。
///
/// 每拍一张不返回，而是把路径与当时的取景框追加到结果列表；页面显示
/// 「已拍 N 张」缩略图条与「继续拍摄」「完成」按钮。点「完成」一次性返回
/// 全部结果，由调用方逐张进入全屏四点裁剪页，不再询问是否需要裁剪。
class CameraCapturePage extends StatefulWidget {
  const CameraCapturePage({super.key});

  /// 仅移动端可用；桌面端 / 取消时返回空列表。
  static Future<List<CameraCaptureResult>> capture(BuildContext context) async {
    if (!isMobile) return <CameraCaptureResult>[];
    final List<CameraCaptureResult>? results = await Navigator.of(context)
        .push<List<CameraCaptureResult>>(
          MaterialPageRoute<List<CameraCaptureResult>>(
            builder: (_) => const CameraCapturePage(),
            fullscreenDialog: true,
          ),
        );
    return results ?? <CameraCaptureResult>[];
  }

  @override
  State<CameraCapturePage> createState() => _CameraCapturePageState();
}

class _CameraCapturePageState extends State<CameraCapturePage>
    with WidgetsBindingObserver {
  /// 宽 / 高：贴近仪器数据表格区域的横向长条比例。
  static const double _frameAspect = 1.85;

  CameraController? _controller;
  String? _error;
  bool _capturing = false;
  final List<CameraCaptureResult> _captured = <CameraCaptureResult>[];

  CropQuad _suggested = const CropQuad(
    tl: Offset(0.05, 0.25),
    tr: Offset(0.95, 0.25),
    br: Offset(0.95, 0.74),
    bl: Offset(0.05, 0.74),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final List<CameraDescription> cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _error = '未检测到可用相机');
        return;
      }
      final CameraDescription back = cameras.firstWhere(
        (CameraDescription c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final CameraController controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _error = null;
      });
    } on CameraException catch (e) {
      if (mounted) {
        setState(() => _error = '相机不可用：${e.description ?? e.code}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = '相机初始化失败：$e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? controller = _controller;
    if (state == AppLifecycleState.inactive && controller != null) {
      _controller = null;
      unawaited(controller.dispose());
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      unawaited(_init());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final CameraController? controller = _controller;
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  Rect _frameOf(Size size) {
    double width = size.width * 0.9;
    double height = width / _frameAspect;
    final double maxHeight = size.height * 0.62;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * _frameAspect;
    }
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: width,
      height: height,
    );
  }

  /// 拍一张后续留在页面，把结果追加到 [_captured]，允许连续拍摄。
  Future<void> _shoot() async {
    final CameraController? controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) {
      return;
    }
    setState(() => _capturing = true);
    try {
      final file = await controller.takePicture();
      if (!mounted) return;
      setState(() {
        _captured.add(CameraCaptureResult(path: file.path, frame: _suggested));
        _capturing = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _capturing = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('拍照失败：$e')));
      }
    }
  }

  void _finish() {
    Navigator.of(context).pop(List<CameraCaptureResult>.from(_captured));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('拍照 · 对齐数据表格'),
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(<CameraCaptureResult>[]),
            child: const Text('取消', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: _error != null
          ? _message(_error!, showRetry: true)
          : _controller == null || !_controller!.value.isInitialized
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: <Widget>[
                Positioned.fill(child: _preview()),
                const Positioned(
                  top: 18,
                  left: 20,
                  right: 20,
                  child: Text(
                    '将仪器屏幕中的数据表格完整放进长方形框内，'
                    '尽量保持水平、避免反光；可连续拍多张，'
                    '完成后逐张微调四角。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                Positioned(
                  bottom: 20,
                  left: 0,
                  right: 0,
                  child: Column(
                    children: <Widget>[
                      Text(
                        '已拍 ${_captured.length} 张',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_captured.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 6),
                        SizedBox(
                          height: 58,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: _captured.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 8),
                            itemBuilder: (BuildContext ctx, int i) => ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.file(
                                File(_captured[i].path),
                                width: 58,
                                height: 58,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  width: 58,
                                  height: 58,
                                  color: Colors.white24,
                                  child: const Icon(
                                    Icons.broken_image,
                                    color: Colors.white54,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          OutlinedButton.icon(
                            onPressed: _capturing
                                ? null
                                : () => unawaited(_shoot()),
                            icon: const Icon(
                              Icons.add_a_photo_outlined,
                              size: 16,
                            ),
                            label: const Text('继续拍摄'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white70),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            onPressed: _finish,
                            icon: const Icon(Icons.check, size: 16),
                            label: const Text('完成'),
                            style: FilledButton.styleFrom(
                              backgroundColor: kPrimaryColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      GestureDetector(
                        onTap: _capturing ? null : () => unawaited(_shoot()),
                        child: Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 4),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(5),
                            child: Container(
                              decoration: BoxDecoration(
                                color: _capturing ? Colors.grey : kPrimaryLight,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _capturing ? '拍摄中…' : '点击拍照 / 继续拍摄',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _preview() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = Size(constraints.maxWidth, constraints.maxHeight);
        final Rect frame = _frameOf(size);
        // 记录归一化取景框，供下一步裁剪作为初始四点（build 内赋值不触发重绘）。
        _suggested = CropQuad(
          tl: Offset(frame.left / size.width, frame.top / size.height),
          tr: Offset(frame.right / size.width, frame.top / size.height),
          br: Offset(frame.right / size.width, frame.bottom / size.height),
          bl: Offset(frame.left / size.width, frame.bottom / size.height),
        ).clamp();
        return Stack(
          children: <Widget>[
            Positioned.fill(child: CameraPreview(_controller!)),
            Positioned.fill(child: CustomPaint(painter: _FramePainter(frame))),
          ],
        );
      },
    );
  }

  Widget _message(String text, {bool showRetry = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.no_photography_outlined,
              color: Colors.white54,
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            if (showRetry) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  setState(() => _error = null);
                  unawaited(_init());
                },
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 取景框覆盖层：四周压暗 + 白色边框 + 四角标记 + 水平参考线。
class _FramePainter extends CustomPainter {
  const _FramePainter(this.frame);

  final Rect frame;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint dim = Paint()..color = const Color(0x99000000);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, frame.top), dim);
    canvas.drawRect(
      Rect.fromLTWH(0, frame.bottom, size.width, size.height - frame.bottom),
      dim,
    );
    canvas.drawRect(Rect.fromLTWH(0, frame.top, frame.left, frame.height), dim);
    canvas.drawRect(
      Rect.fromLTWH(
        frame.right,
        frame.top,
        size.width - frame.right,
        frame.height,
      ),
      dim,
    );

    final Paint border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(frame, border);

    final Paint corner = Paint()
      ..color = kPrimaryLight
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const double len = 26;
    canvas.drawLine(
      frame.topLeft,
      frame.topLeft + const Offset(len, 0),
      corner,
    );
    canvas.drawLine(
      frame.topLeft,
      frame.topLeft + const Offset(0, len),
      corner,
    );
    canvas.drawLine(
      frame.topRight,
      frame.topRight + const Offset(-len, 0),
      corner,
    );
    canvas.drawLine(
      frame.topRight,
      frame.topRight + const Offset(0, len),
      corner,
    );
    canvas.drawLine(
      frame.bottomLeft,
      frame.bottomLeft + const Offset(len, 0),
      corner,
    );
    canvas.drawLine(
      frame.bottomLeft,
      frame.bottomLeft + const Offset(0, -len),
      corner,
    );
    canvas.drawLine(
      frame.bottomRight,
      frame.bottomRight + const Offset(-len, 0),
      corner,
    );
    canvas.drawLine(
      frame.bottomRight,
      frame.bottomRight + const Offset(0, -len),
      corner,
    );

    final Paint guide = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 1;
    for (int i = 1; i <= 2; i++) {
      final double y = frame.top + frame.height * i / 3;
      canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), guide);
    }
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) => oldDelegate.frame != frame;
}
