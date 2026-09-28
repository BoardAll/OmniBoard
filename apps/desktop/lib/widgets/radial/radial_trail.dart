/// 拖拽轨迹线绘制（文档 5.2 / 8.3）。
///
/// 从中心到当前指针的连线（主色 60% 透明）、指针端圆点、以及指向项
/// 名称气泡；跟随实时绘制（无缓动）。公开字段便于测试断言。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

/// 轨迹线 painter。
class RadialTrailPainter extends CustomPainter {
  const RadialTrailPainter({
    required this.from,
    required this.to,
    required this.label,
    required this.color,
    required this.labelColor,
    required this.labelBackground,
    required this.labelStyle,
  });

  /// 起点（圆盘中心，组件本地坐标）。
  final Offset from;

  /// 终点（当前指针，组件本地坐标）。
  final Offset to;

  /// 指向项名称（取消区显示"取消"）。
  final String label;

  /// 线色（调用方传入 60% 主色）。
  final Color color;

  /// 标签文字色。
  final Color labelColor;

  /// 标签背景色。
  final Color labelBackground;

  /// 标签文字样式。
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(from, to, line);
    canvas.drawCircle(to, 4, Paint()..color = color);

    if (label.isEmpty) {
      return;
    }
    final TextPainter textPainter = TextPainter(
      text: TextSpan(text: label, style: WbTypography.apply(labelStyle)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 110);
    // 标签置于指针上方居中；顶部越界时翻转到指针下方。
    double x = to.dx - textPainter.width / 2;
    double y = to.dy - textPainter.height - 12;
    if (y < 4) {
      y = to.dy + 12;
    }
    x = x.clamp(4, size.width - textPainter.width - 4);
    final Rect rect = Rect.fromLTWH(
      x - 6,
      y - 4,
      textPainter.width + 12,
      textPainter.height + 8,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(6)),
      Paint()..color = labelBackground,
    );
    textPainter.paint(canvas, Offset(x, y));
  }

  @override
  bool shouldRepaint(RadialTrailPainter oldDelegate) =>
      oldDelegate.from != from ||
      oldDelegate.to != to ||
      oldDelegate.label != label ||
      oldDelegate.color != color ||
      oldDelegate.labelBackground != labelBackground;
}
