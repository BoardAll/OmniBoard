/// 迷你地图：内容缩略图 + 视口指示 + 点击/拖动跳转。
///
/// 布局换算基于「内容世界矩形」（元素包围盒 ∪ 视口，外扩 8% 余量）等比
/// 适配到地图面板，相关纯函数（[wbMinimapContentBounds] /
/// [wbMinimapLocalToWorld] / [wbMinimapWorldToLocal]）导出以便测试复用。
///
/// [WbMinimapPainter] 通过 `super(repaint: controller)` 跟随画布重绘；
/// 点击 / 拖动经 [WbCanvasController.centerWorldAt] 把目标世界点置于
/// 视口中心。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:whiteboard_theme/theme.dart';

import 'canvas_controller.dart';
import 'canvas_model.dart';

/// 计算迷你地图内容世界矩形（元素包围盒 ∪ 视口，外扩 8% 余量）。
///
/// 空画布返回以原点为中心的默认矩形，保证换算函数恒定有定义。
Rect wbMinimapContentBounds(WbCanvasController controller) {
  final Rect viewport = controller.visibleWorldRect;
  Rect content = controller.contentBounds ?? viewport;
  content = content.expandToInclude(viewport);
  if (content.width <= 0 || content.height <= 0) {
    content = const Rect.fromLTWH(-400, -300, 800, 600);
  }
  return content.inflate(math.max(content.width, content.height) * 0.08);
}

/// 迷你地图等比适配缩放（内容 → 面板像素）。
double wbMinimapFitScale(Size mapSize, Rect content) => math.min(
      mapSize.width / math.max(1, content.width),
      mapSize.height / math.max(1, content.height),
    );

/// 内容映射到面板后的平移原点（使内容在面板中居中）。
Offset wbMinimapOrigin(Size mapSize, Rect content) {
  final double scale = wbMinimapFitScale(mapSize, content);
  return Offset(
    (mapSize.width - content.width * scale) / 2 - content.left * scale,
    (mapSize.height - content.height * scale) / 2 - content.top * scale,
  );
}

/// 迷你地图局部坐标 → 世界坐标。
Offset wbMinimapLocalToWorld(Offset local, Size mapSize, Rect content) {
  final double scale = wbMinimapFitScale(mapSize, content);
  final Offset origin = wbMinimapOrigin(mapSize, content);
  return Offset(
    (local.dx - origin.dx) / scale,
    (local.dy - origin.dy) / scale,
  );
}

/// 世界坐标 → 迷你地图局部坐标。
Offset wbMinimapWorldToLocal(Offset world, Size mapSize, Rect content) {
  final double scale = wbMinimapFitScale(mapSize, content);
  final Offset origin = wbMinimapOrigin(mapSize, content);
  return Offset(
    world.dx * scale + origin.dx,
    world.dy * scale + origin.dy,
  );
}

/// 迷你地图面板（视口指示 + 点击 / 拖动跳转）。
class WbMinimap extends StatelessWidget {
  /// 创建迷你地图。
  const WbMinimap({super.key, required this.controller});

  /// 画布控制器。
  final WbCanvasController controller;

  /// 面板尺寸。
  static const Size size = Size(168, 108);

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      key: const Key('wb-canvas-minimap'),
      width: size.width,
      height: size.height,
      decoration: BoxDecoration(
        color: colors.elevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (TapDownDetails details) => _jumpTo(details.localPosition),
        onPanUpdate: (DragUpdateDetails details) =>
            _jumpTo(details.localPosition),
        child: CustomPaint(
          painter: WbMinimapPainter(
            controller: controller,
            viewportColor: colors.primary,
          ),
          size: size,
        ),
      ),
    );
  }

  void _jumpTo(Offset local) {
    final Rect content = wbMinimapContentBounds(controller);
    final Offset clamped = Offset(
      local.dx.clamp(0, size.width),
      local.dy.clamp(0, size.height),
    );
    controller.centerWorldAt(wbMinimapLocalToWorld(clamped, size, content));
  }
}

/// 迷你地图绘制器：元素缩略块 + 视口指示框。
class WbMinimapPainter extends CustomPainter {
  /// 创建绘制器。
  WbMinimapPainter({required this.controller, required this.viewportColor})
      : super(repaint: controller);

  /// 画布控制器。
  final WbCanvasController controller;

  /// 视口指示框颜色。
  final Color viewportColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final Rect content = wbMinimapContentBounds(controller);
    final double scale = wbMinimapFitScale(size, content);
    final Offset origin = wbMinimapOrigin(size, content);

    for (final WbCanvasElement element in controller.elements) {
      final Rect bounds = element.bounds;
      final Rect local = Rect.fromLTWH(
        bounds.left * scale + origin.dx,
        bounds.top * scale + origin.dy,
        math.max(1.5, bounds.width * scale),
        math.max(1.5, bounds.height * scale),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(local, const Radius.circular(1.5)),
        Paint()..color = Color(element.color).withValues(alpha: 0.85),
      );
    }

    final Rect viewport = controller.visibleWorldRect;
    if (viewport.width > 0 && viewport.height > 0) {
      final Rect indicator = Rect.fromLTWH(
        viewport.left * scale + origin.dx,
        viewport.top * scale + origin.dy,
        viewport.width * scale,
        viewport.height * scale,
      );
      canvas.drawRect(
        indicator,
        Paint()..color = viewportColor.withValues(alpha: 0.10),
      );
      canvas.drawRect(
        indicator,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = viewportColor,
      );
    }
  }

  @override
  bool shouldRepaint(WbMinimapPainter oldDelegate) =>
      oldDelegate.controller != controller ||
      oldDelegate.viewportColor != viewportColor;
}
