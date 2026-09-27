/// 演示画布：WASM 核心不可用时（或就绪前的）内置降级视图。
///
/// 纯 Flutter 绘制（网格背景 + 示例元素），不依赖 C++ 核心，
/// 保证 Web 端在 Wave 4 WASM 产物就位前也可完整演示列表 → 编辑流程
/// （《Web 端方案设计（Flutter Web + WASM）》§9.4 降级策略）。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_theme/theme.dart';

/// 演示画布（网格背景 + 样例元素）。
///
/// 根节点带 [key] `wb-demo-canvas`，供冒烟测试定位。
class WbDemoCanvas extends StatelessWidget {
  /// 创建演示画布。
  const WbDemoCanvas({super.key});

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      key: const Key('wb-demo-canvas'),
      color: colors.canvas,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            CustomPaint(
              painter: _WbGridPainter(
                lineColor: colors.border.withValues(alpha: 0.4),
              ),
            ),
            Positioned(
              left: 56,
              top: 48,
              child: _DemoCard(
                width: 220,
                color: colors.elevated,
                borderColor: colors.cardBorder,
                title: '示例卡片',
                subtitle: '拖拽 / 缩放等交互在 WASM 核心就绪后可用',
              ),
            ),
            Positioned(
              left: 320,
              top: 148,
              child: _DemoCard(
                width: 200,
                color: colors.primary.withValues(alpha: 0.12),
                borderColor: colors.primary.withValues(alpha: 0.4),
                title: '便签',
                subtitle: '双击编辑（演示占位）',
              ),
            ),
            Positioned(
              right: 64,
              bottom: 72,
              child: _DemoCard(
                width: 180,
                color: colors.elevated,
                borderColor: colors.cardBorder,
                title: '流程图',
                subtitle: '自动布局（演示占位）',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 网格背景绘制器（20px 细网格）。
class _WbGridPainter extends CustomPainter {
  const _WbGridPainter({required this.lineColor});

  /// 网格线颜色。
  final Color lineColor;

  /// 网格间距（逻辑像素）。
  static const double cellSize = 20;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;
    for (double x = 0; x <= size.width; x += cellSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += cellSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_WbGridPainter oldDelegate) =>
      oldDelegate.lineColor != lineColor;
}

/// 演示卡片（画布上的样例元素）。
class _DemoCard extends StatelessWidget {
  const _DemoCard({
    required this.width,
    required this.color,
    required this.borderColor,
    required this.title,
    required this.subtitle,
  });

  final double width;
  final Color color;
  final Color borderColor;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      width: width,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(12),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colors.icon),
          ),
        ],
      ),
    );
  }
}
