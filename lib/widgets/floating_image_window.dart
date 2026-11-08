import 'dart:io';

import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../utils/table_column_width.dart';

/// 计算小窗允许的最大宽度。
///
/// 上限 = 屏幕宽的 2/3，同时受「窗口高度不超过屏幕高的 90%」约束：
/// `barHeight + width * imageRatio <= screenHeight * heightLimitRatio`，
/// 即 `width <= (screenHeight * heightLimitRatio - barHeight) / imageRatio`。
/// 两者取较小值，并保证结果不低于 [minWidth]（极窄 / 极矮屏不让宽度变负）。
///
/// 纯 Dart 顶层函数：只接收 double、返回 double，不依赖 BuildContext /
/// Offset / Flutter 运行时，便于在沙箱中用临时脚本复制同一公式实跑验证。
double maxFloatingWindowWidth(
  double screenWidth,
  double screenHeight, {
  double minWidth = FloatingImageWindow.minWidth,
  double barHeight = FloatingImageWindow.barHeight,
  double imageRatio = FloatingImageWindow.imageRatio,
  double heightLimitRatio = 0.9,
}) {
  final double byWidth = screenWidth * 2.0 / 3.0;
  final double maxByHeight =
      (screenHeight * heightLimitRatio - barHeight) / imageRatio;
  final double limited = byWidth < maxByHeight ? byWidth : maxByHeight;
  return limited > minWidth ? limited : minWidth;
}

/// 纯 Dart 窗口矩形（只含 double），用于对角锚定缩放计算。
///
/// 不依赖 dart:ui / Flutter，便于临时脚本原样复制 [resizeWindowRect] 实跑验证。
class WindowRect {
  const WindowRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  /// 整体平移（宽高不变），用于拖动顶部工具条移动窗口。
  WindowRect shifted(double dx, double dy) =>
      WindowRect(left: left + dx, top: top + dy, width: width, height: height);
}

/// 对角点锚定缩放：返回新矩形，锚点在整个拖拽过程中严格不动。
///
/// [fromLeft] = true（左下角手柄）：锚点 = 右上角 `(rect.right, rect.top)` 恒定，
///   `delta = -dx + dy`（向左下"向外"为正，向右上"向内"为负），
///   `newLeft = rect.right - newWidth`。
/// [fromLeft] = false（右下角手柄）：锚点 = 左上角 `(rect.left, rect.top)` 恒定，
///   `delta = dx + dy`，`newLeft = rect.left`。
/// 两个手柄 top 恒定；`newHeight = barHeight + newWidth * imageRatio`；
/// 宽度限制在 [minWidth]..[maxWidth]，两侧水平方向互为镜像。
WindowRect resizeWindowRect(
  WindowRect rect,
  double dx,
  double dy, {
  required bool fromLeft,
  required double minWidth,
  required double maxWidth,
  required double barHeight,
  required double imageRatio,
}) {
  final double delta = fromLeft ? -dx + dy : dx + dy;
  final double upper = maxWidth > minWidth ? maxWidth : minWidth;
  final double newWidth = (rect.width + delta)
      .clamp(minWidth, upper)
      .toDouble();
  final double newHeight = barHeight + newWidth * imageRatio;
  final double newLeft = fromLeft ? rect.right - newWidth : rect.left;
  return WindowRect(
    left: newLeft,
    top: rect.top,
    width: newWidth,
    height: newHeight,
  );
}

/// 图片「悬浮小窗」宿主。
///
/// 用法：把可滚动的内容用 [childBuilder] 交给它（会拿到内部创建的
/// [ScrollController]）。小窗是否显示完全由外部页面的 [visible] 决定
/// —— 即由 AppBar 右上角的按钮手动开关，不再依据滚动位置自动浮出。
/// 小窗内的关闭按钮通过 [onClose] 通知页面复位开关状态。
///
/// 小窗能力：
/// - 拖动顶部工具条自由移动，位置被约束在屏幕内；
/// - 左下角 / 右下角两个手柄拖拽缩放窗口尺寸（对角点锚定）；
/// - 双击或双指捏合缩放图片内容，放大后可平移查看局部，
///   还原到 1.0 时恢复 [PageView] 左右滑动切图；
/// - 最小化成一个小圆钮随时恢复，或直接关闭。
class FloatingImageHost extends StatefulWidget {
  const FloatingImageHost({
    super.key,
    required this.imagePaths,
    required this.visible,
    required this.onClose,
    required this.childBuilder,
  });

  final List<String> imagePaths;
  final bool visible;
  final VoidCallback onClose;
  final Widget Function(ScrollController controller) childBuilder;

  @override
  State<FloatingImageHost> createState() => _FloatingImageHostState();
}

class _FloatingImageHostState extends State<FloatingImageHost> {
  /// 仍由宿主创建并交给 [FloatingImageHost.childBuilder]，两个页面的
  /// ListView 依旧使用 `controller: controller`；只是不再监听滚动事件。
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return Stack(
          children: <Widget>[
            widget.childBuilder(_scroll),
            if (widget.visible && widget.imagePaths.isNotEmpty)
              FloatingImageWindow(
                imagePaths: widget.imagePaths,
                bounds: constraints.biggest,
                onClose: widget.onClose,
              ),
          ],
        );
      },
    );
  }
}

/// 可拖动 / 缩放 / 切图的悬浮图片小窗。
///
/// 手势分工：
/// - 顶部工具条拖动 → 移动整个窗口矩形；
/// - 左下角 / 右下角手柄拖动 → 对角点锚定缩放窗口尺寸；
/// - 双击图片 / 双指捏合 → 改变图片内容缩放 [_imageScale]；
/// - 放大状态下单指拖动 → 平移图片；未放大时单指左右滑 → 切图。
///
/// 双指缩放由 [Listener] 直接读取原始指针事件、自行计算两指距离实现，
/// 不经过 GestureArena，也不在手势中途替换子树，避免识别器收不到 pointer。
/// 窗口最大宽度为屏幕宽的 2/3（并保证高度不超屏幕 90%），见
/// [maxFloatingWindowWidth]，不再有固定像素硬上限。
class FloatingImageWindow extends StatefulWidget {
  const FloatingImageWindow({
    super.key,
    required this.imagePaths,
    required this.bounds,
    required this.onClose,
  });

  final List<String> imagePaths;
  final Size bounds;
  final VoidCallback onClose;

  /// 小窗最小宽度；最大宽度由 [maxFloatingWindowWidth] 按屏幕尺寸动态计算
  /// （屏幕宽的 2/3，且保证窗口高度不超屏幕 90%），不再有 360 硬封顶。
  /// 窗口高度按 4:3 图片比例 + 工具条计算。
  static const double minWidth = 148;
  static const double barHeight = 30;
  static const double imageRatio = 0.72;

  /// 图片内容缩放范围。
  static const double minImageScale = 1.0;
  static const double maxImageScale = 5.0;

  @override
  State<FloatingImageWindow> createState() => _FloatingImageWindowState();
}

class _FloatingImageWindowState extends State<FloatingImageWindow> {
  /// 窗口矩形（left / top / width / height）；null = 未拖动或缩放，用默认右上角。
  WindowRect? _rect;
  int _index = 0;
  bool _minimized = false;

  /// 首次出现动画开关：首帧后置 true，触发 220ms 淡入放大。
  bool _appeared = false;

  /// 当前按下的触点（key = PointerDownEvent.pointer），用于自行计算双指距离。
  /// [Listener] 只接收原始指针事件、不参与 GestureArena，且作为稳定父节点
  /// 不会在手势中途被替换，因此双指缩放一定能收到完整的 move 序列。
  final Map<int, Offset> _activePointers = <int, Offset>{};

  /// 上一帧的双指距离；null = 当前不足两指，不计算缩放。
  double? _lastPinchDistance;

  /// 图片内容缩放（与窗口尺寸完全独立）。
  double _imageScale = FloatingImageWindow.minImageScale;

  /// 放大后可查看被裁掉区域的平移量。
  Offset _imageOffset = Offset.zero;

  late final PageController _pageController = PageController(
    initialPage: _index,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _appeared = true);
    });
  }

  /// 屏幕宽的 2/3 与「高度不超屏幕 90%」约束下的最大宽度。
  double get _maxWidth =>
      maxFloatingWindowWidth(widget.bounds.width, widget.bounds.height);

  /// 默认贴在右上角（留出 12px 安全边距），默认宽 208、高按比例计算。
  WindowRect _defaultRect() {
    final double w = 208.0
        .clamp(FloatingImageWindow.minWidth, _maxWidth)
        .toDouble();
    final double h =
        FloatingImageWindow.barHeight + w * FloatingImageWindow.imageRatio;
    return WindowRect(
      left: widget.bounds.width - w - 12,
      top: 12,
      width: w,
      height: h,
    );
  }

  /// 仅当窗口超出屏幕时才平移；正常缩放时锚点严格不动。
  WindowRect _clampRect(WindowRect rect) {
    return WindowRect(
      left: clampInViewport(rect.left, widget.bounds.width - rect.width),
      top: clampInViewport(rect.top, widget.bounds.height - rect.height),
      width: rect.width,
      height: rect.height,
    );
  }

  WindowRect get _visibleRect => _clampRect(_rect ?? _defaultRect());

  double get _effectiveWidth => _visibleRect.width;

  /// 拖动顶部工具条：移动整个矩形（宽高保持不变，不丢失高度）。
  void _move(DragUpdateDetails details) {
    setState(() {
      _rect = _clampRect(
        _visibleRect.shifted(details.delta.dx, details.delta.dy),
      );
    });
  }

  /// 对角点锚定缩放（两个下角都遵循「向外拖 = 放大、向内推 = 缩小」）。
  ///
  /// 左下角 `fromLeft=true`：锚点右上角 (right, top) 恒定；
  ///   向左下 dx<0,dy>0 → `-dx+dy>0` → 放大；向右上 → 缩小。
  /// 右下角 `fromLeft=false`：锚点左上角 (left, top) 恒定；
  ///   向右下 dx>0,dy>0 → `dx+dy>0` → 放大；向左上 → 缩小。
  /// 计算委托给纯函数 [resizeWindowRect]，最后只在超屏时把矩形夹回屏幕。
  void _resize(DragUpdateDetails details, {required bool fromLeft}) {
    final WindowRect current = _visibleRect;
    final WindowRect resized = resizeWindowRect(
      current,
      details.delta.dx,
      details.delta.dy,
      fromLeft: fromLeft,
      minWidth: FloatingImageWindow.minWidth,
      maxWidth: _maxWidth,
      barHeight: FloatingImageWindow.barHeight,
      imageRatio: FloatingImageWindow.imageRatio,
    );
    setState(() {
      _rect = _clampRect(resized);
    });
  }

  /// 小窗首次出现：淡入 + 轻微放大（220ms，easeOut）。
  /// 关闭由父级直接移除 widget，不做退出动画，避免引入延迟卡顿。
  Widget _appearAnimation(Widget child) {
    return AnimatedOpacity(
      opacity: _appeared ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      child: AnimatedScale(
        scale: _appeared ? 1.0 : 0.92,
        alignment: Alignment.center,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        child: child,
      ),
    );
  }

  /// 双击：在 1.0 与 2.0 之间切换；还原时清空平移。
  void _toggleImageScale() {
    setState(() {
      _imageScale = _imageScale > FloatingImageWindow.minImageScale
          ? FloatingImageWindow.minImageScale
          : 2.0;
      if (_imageScale <= FloatingImageWindow.minImageScale) {
        _imageOffset = Offset.zero;
      }
    });
  }

  /// 记录触点；第二根手指落下时初始化基准距离。
  ///
  /// 刻意不在 down 里 setState：避免在手势中途重建子树，
  /// 打断 [PageView] 已有的 drag 或刚创建的识别器。
  void _onPointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.localPosition;
    if (_activePointers.length == 2) {
      _lastPinchDistance = _pinchDistance();
    }
  }

  /// 两指移动时用「当前距离 / 上一帧距离」连续累乘缩放图片内容。
  /// 张开（距离变大）→ 放大；捏合（距离变小）→ 缩小。只改 [_imageScale]。
  void _onPointerMove(PointerMoveEvent event) {
    if (!_activePointers.containsKey(event.pointer)) return;
    _activePointers[event.pointer] = event.localPosition;
    if (_activePointers.length < 2) return;

    final double distance = _pinchDistance();
    final double? previous = _lastPinchDistance;
    if (previous != null && previous > 0) {
      setState(() {
        _imageScale = pinchScale(
          _imageScale,
          previous,
          distance,
          min: FloatingImageWindow.minImageScale,
          max: FloatingImageWindow.maxImageScale,
        );
        if (_imageScale <= FloatingImageWindow.minImageScale) {
          _imageOffset = Offset.zero;
        } else {
          _clampImageOffset();
        }
      });
    }
    _lastPinchDistance = distance;
  }

  void _onPointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2) _lastPinchDistance = null;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2) _lastPinchDistance = null;
  }

  /// 当前按下的前两个触点之间的距离；调用方保证 length >= 2。
  double _pinchDistance() {
    final List<Offset> points = _activePointers.values.toList(growable: false);
    return (points[0] - points[1]).distance;
  }

  /// 放大后单指平移图片。
  void _panImage(DragUpdateDetails details) {
    setState(() {
      _imageOffset += details.delta;
      _clampImageOffset();
    });
  }

  /// 把平移量限制在「放大后可露出」的范围内，避免图片被拖出视口。
  void _clampImageOffset() {
    final double overflow =
        (_imageScale - FloatingImageWindow.minImageScale) / 2.0;
    final double maxX = _effectiveWidth * overflow;
    final double maxY =
        _effectiveWidth * FloatingImageWindow.imageRatio * overflow;
    _imageOffset = Offset(
      _imageOffset.dx.clamp(-maxX, maxX).toDouble(),
      _imageOffset.dy.clamp(-maxY, maxY).toDouble(),
    );
  }

  /// 切图时回到未放大状态，避免换图后仍停留在上一张的放大位置。
  void _onPageChanged(int index) {
    setState(() {
      _index = index;
      _imageScale = FloatingImageWindow.minImageScale;
      _imageOffset = Offset.zero;
      // 切图时若仍有两指按着，清掉基准避免下一帧误算比例。
      _lastPinchDistance = null;
    });
  }

  @override
  void didUpdateWidget(covariant FloatingImageWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_index >= widget.imagePaths.length) {
      _index = widget.imagePaths.length - 1;
      if (_index < 0) _index = 0;
      if (_pageController.hasClients) _pageController.jumpToPage(_index);
    }
    // 屏幕尺寸变化时把已拖动 / 缩放的矩形重新夹回可视区。
    if (oldWidget.bounds != widget.bounds && _rect != null) {
      _rect = _clampRect(_rect!);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final WindowRect rect = _visibleRect;

    // 最小化：只留一个可拖动的小圆钮，点击恢复。
    if (_minimized) {
      return Positioned(
        left: rect.left,
        top: rect.top,
        child: _appearAnimation(
          GestureDetector(
            onPanUpdate: _move,
            onTap: () => setState(() => _minimized = false),
            child: Material(
              elevation: 6,
              color: kPrimaryColor,
              borderRadius: BorderRadius.circular(24),
              child: SizedBox(
                width: 48,
                height: 48,
                child: Stack(
                  children: <Widget>[
                    const Center(
                      child: Icon(
                        Icons.photo_library_outlined,
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Text(
                        '${_index + 1}/${widget.imagePaths.length}',
                        style: const TextStyle(
                          fontSize: 9,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: _appearAnimation(
        Listener(
          // translucent：Listener 自身也能接收原始指针事件，同时其子控件
          // 仍参与命中测试，双击 / 拖动 / PageView 手势不受影响。
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          // child 恒定，不随触点数变化被替换，识别器不会在手势中途重建。
          child: _buildCard(),
        ),
      ),
    );
  }

  Widget _buildCard() {
    final bool zoomed = _imageScale > FloatingImageWindow.minImageScale;
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      color: Colors.white,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Column(
          children: <Widget>[
            // ---- 顶部工具条：拖动 + 页码 + 最小化 / 关闭 ----
            GestureDetector(
              onPanUpdate: _move,
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: FloatingImageWindow.barHeight,
                color: kPrimaryColor,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: <Widget>[
                    const Icon(
                      Icons.drag_indicator,
                      size: 16,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      child: Text(
                        widget.imagePaths.length > 1
                            ? '原图 ${_index + 1}/${widget.imagePaths.length}'
                            : '原图对照',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    _BarIcon(
                      icon: Icons.remove,
                      tooltip: '最小化',
                      onTap: () => setState(() => _minimized = true),
                    ),
                    _BarIcon(
                      icon: Icons.close,
                      tooltip: '关闭悬浮窗',
                      onTap: widget.onClose,
                    ),
                  ],
                ),
              ),
            ),
            // ---- 图片区：左右滑动切图，双击 / 双指缩放内容 ----
            Expanded(
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: Container(color: const Color(0xFF1A1A1A)),
                  ),
                  Positioned.fill(
                    child: PageView.builder(
                      controller: _pageController,
                      itemCount: widget.imagePaths.length,
                      // 放大时禁用切图，让单指拖动用于平移图片；
                      // 还原到 1.0 时恢复默认 physics，可左右切图。
                      physics: zoomed
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      onPageChanged: _onPageChanged,
                      itemBuilder: (BuildContext context, int i) {
                        final String path = widget.imagePaths[i];
                        // 单击无任何副作用：这里只注册双击与（放大后的）平移，
                        // 不注册 onTap，也不会误触发 PageView 切图。
                        return GestureDetector(
                          onDoubleTap: _toggleImageScale,
                          onPanUpdate: (_activePointers.length < 2 && zoomed)
                              ? _panImage
                              : null,
                          behavior: HitTestBehavior.opaque,
                          child: ClipRect(
                            child: Transform.translate(
                              offset: _imageOffset,
                              child: Transform.scale(
                                scale: _imageScale,
                                child: Image.file(
                                  File(path),
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) => const Center(
                                    child: Icon(
                                      Icons.broken_image_outlined,
                                      color: Colors.white54,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // 多图时显示左右切换按钮，桌面端也能用鼠标切图。
                  if (widget.imagePaths.length > 1) ...<Widget>[
                    if (_index > 0)
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        child: _SwitchButton(
                          icon: Icons.chevron_left,
                          onTap: () => _pageController.previousPage(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOut,
                          ),
                        ),
                      ),
                    if (_index < widget.imagePaths.length - 1)
                      Positioned(
                        right: 0,
                        top: 0,
                        bottom: 0,
                        child: _SwitchButton(
                          icon: Icons.chevron_right,
                          onTap: () => _pageController.nextPage(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOut,
                          ),
                        ),
                      ),
                  ],
                  // 左下角缩放手柄：锚定右上角，向左下拖放大、向右上推缩小。
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: _ResizeHandle(
                      fromLeft: true,
                      onPanUpdate: (DragUpdateDetails d) =>
                          _resize(d, fromLeft: true),
                    ),
                  ),
                  // 右下角缩放手柄：锚定左上角，向右下拖放大、向左上推缩小。
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: _ResizeHandle(
                      fromLeft: false,
                      onPanUpdate: (DragUpdateDetails d) =>
                          _resize(d, fromLeft: false),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 窗口尺寸缩放手柄：左下 / 右下各一个，圆角方向与图标朝向相反以作区分。
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({required this.fromLeft, required this.onPanUpdate});

  final bool fromLeft;
  final void Function(DragUpdateDetails details) onPanUpdate;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '拖动缩放小窗',
      child: GestureDetector(
        onPanUpdate: onPanUpdate,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: kPrimaryColor.withValues(alpha: 0.85),
            borderRadius: fromLeft
                ? const BorderRadius.only(topRight: Radius.circular(8))
                : const BorderRadius.only(topLeft: Radius.circular(8)),
          ),
          child: fromLeft
              ? const RotatedBox(
                  quarterTurns: 1,
                  child: Icon(
                    Icons.open_in_full,
                    size: 14,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.open_in_full, size: 14, color: Colors.white),
        ),
      ),
    );
  }
}

class _BarIcon extends StatelessWidget {
  const _BarIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 16,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Icon(icon, size: 15, color: Colors.white),
        ),
      ),
    );
  }
}

class _SwitchButton extends StatelessWidget {
  const _SwitchButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 26,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 18, color: Colors.white),
        ),
      ),
    );
  }
}
