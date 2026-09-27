/// 透明批注覆盖层画布：本地笔迹绘制 / 擦除 / 激光笔渐隐 + 键盘。
///
/// - 批注态：捕获指针（命中测试生效）绘制或擦除，笔迹仅本地渲染；
/// - 穿透态（含按住 `Alt` 的临时穿透）：[IgnorePointer] 放行鼠标事件；
/// - 键盘：`Esc` 请求退出、按住 / 松开 `Alt` 切换临时穿透
///   （《透明批注模式技术方案》§4.2 / §5.3 / §6.4）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../state/annotation_state.dart';
import 'annotation_controller.dart';

/// 覆盖层画布部件（挂载于应用 Stack 的 `Positioned.fill`）。
class AnnotationOverlay extends StatefulWidget {
  const AnnotationOverlay({super.key, required this.controller});

  /// 批注控制器。
  final WbAnnotationController controller;

  @override
  State<AnnotationOverlay> createState() => _AnnotationOverlayState();
}

class _AnnotationOverlayState extends State<AnnotationOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    widget.controller.addListener(_onControllerChanged);
    _syncTicker();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _ticker.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) {
      return;
    }
    // 激光笔出现时启动帧动画，全部消失后停止（避免常驻帧回调）。
    _syncTicker();
  }

  void _syncTicker() {
    final bool shouldTick = widget.controller.state.hasLaser;
    if (shouldTick && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldTick && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    final DateTime now = DateTime.now();
    setState(() => _now = now);
    widget.controller.state.purgeExpiredLaser(now);
  }

  void _handleDown(PointerDownEvent event) {
    final WbAnnotationState state = widget.controller.state;
    if (state.tool == WbAnnotationTool.eraser) {
      state.eraseAt(event.localPosition);
      return;
    }
    state.beginStroke(event.localPosition);
  }

  void _handleMove(PointerMoveEvent event) {
    final WbAnnotationState state = widget.controller.state;
    if (state.tool == WbAnnotationTool.eraser) {
      state.eraseAt(event.localPosition);
      return;
    }
    state.extendStroke(event.localPosition);
  }

  void _handleUp(PointerUpEvent event) {
    widget.controller.state.endStroke();
  }

  void _handleCancel(PointerCancelEvent event) {
    widget.controller.state.endStroke();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape && event is KeyDownEvent) {
      widget.controller.requestExit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight) {
      if (event is KeyDownEvent) {
        widget.controller.setTemporaryPenetrate(true);
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        widget.controller.setTemporaryPenetrate(false);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? child) {
        final WbAnnotationController controller = widget.controller;
        final List<WbAnnotationStroke> strokes =
            controller.state.visibleStrokes(_now);
        final bool interactive =
            controller.isActive && !controller.isPenetratingInEffect;
        return Focus(
          autofocus: true,
          onKeyEvent: _handleKey,
          child: IgnorePointer(
            ignoring: !interactive,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _handleDown,
              onPointerMove: _handleMove,
              onPointerUp: _handleUp,
              onPointerCancel: _handleCancel,
              child: CustomPaint(
                painter: WbAnnotationPainter(strokes: strokes, now: _now),
                size: Size.infinite,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 批注层画笔：把可见笔迹绘制到覆盖层（高 DPI / 激光笔渐隐）。
class WbAnnotationPainter extends CustomPainter {
  WbAnnotationPainter({required this.strokes, required this.now});

  /// 当前可见笔迹（已过滤过期激光笔）。
  final List<WbAnnotationStroke> strokes;

  /// 渲染时刻（激光笔渐隐计算基准）。
  final DateTime now;

  @override
  void paint(Canvas canvas, Size size) {
    for (final WbAnnotationStroke stroke in strokes) {
      final double alpha = stroke.opacityAt(now);
      if (alpha <= 0 || stroke.points.isEmpty) {
        continue;
      }
      final Paint paint = Paint()
        ..color = stroke.color
            .withValues(alpha: alpha.clamp(0.0, 1.0).toDouble())
        ..strokeWidth = stroke.width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          stroke.points.first,
          stroke.width / 2,
          paint..style = PaintingStyle.fill,
        );
        continue;
      }
      final Offset first = stroke.points.first;
      final Path path = Path()..moveTo(first.dx, first.dy);
      for (final Offset point in stroke.points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant WbAnnotationPainter oldDelegate) =>
      oldDelegate.now != now || !identical(oldDelegate.strokes, strokes);
}
