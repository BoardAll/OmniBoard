import 'package:flutter/material.dart';

import '../foundation/colors.dart';
import '../foundation/radius.dart';
import '../foundation/spacing.dart';

/// 骨架形状。
enum WbSkeletonShape {
  /// 矩形。
  rect,

  /// 圆形。
  circle,
}

/// 骨架屏占位块（带 shimmer 微光动画）。
class WbSkeleton extends StatefulWidget {
  const WbSkeleton({
    super.key,
    this.width,
    this.height = 12,
    this.radius,
    this.shape = WbSkeletonShape.rect,
  });

  final double? width;
  final double height;

  /// 圆角半径；circle 形状忽略此值。
  final double? radius;
  final WbSkeletonShape shape;

  @override
  State<WbSkeleton> createState() => _WbSkeletonState();
}

class _WbSkeletonState extends State<WbSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final BorderRadius borderRadius = widget.shape == WbSkeletonShape.circle
        ? WbRadius.allFull
        : WbRadius.circular(widget.radius ?? WbRadius.s);
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        // slide: -1 → 1，驱动高光横扫。
        final double slide = _controller.value * 2 - 1;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: LinearGradient(
              begin: Alignment(slide - 1, 0),
              end: Alignment(slide + 1, 0),
              colors: const <Color>[
                WbColors.gray100,
                WbColors.gray50,
                WbColors.gray100,
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 多行文本骨架（首行到末行宽度递减，模拟段落）。
class WbSkeletonText extends StatelessWidget {
  const WbSkeletonText({
    super.key,
    this.lines = 3,
    this.lineHeight = 10,
    this.spacing = WbSpacing.sm,
    this.width,
  });

  /// 行数。
  final int lines;
  final double lineHeight;
  final double spacing;

  /// 整体宽度（null 撑满父级）。
  final double? width;

  /// 末行宽度比例（模拟自然段落结束）。
  static const double lastLineRatio = 0.6;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: List<Widget>.generate(lines, (int index) {
          final bool isLast = index == lines - 1;
          return Padding(
            padding: EdgeInsets.only(bottom: isLast ? 0 : spacing),
            child: isLast && lines > 1
                ? FractionallySizedBox(
                    widthFactor: lastLineRatio,
                    child: WbSkeleton(height: lineHeight),
                  )
                : WbSkeleton(height: lineHeight),
          );
        }),
      ),
    );
  }
}

/// 圆形骨架（头像位）。
class WbSkeletonCircle extends StatelessWidget {
  const WbSkeletonCircle({super.key, this.diameter = 32});

  final double diameter;

  @override
  Widget build(BuildContext context) {
    return WbSkeleton(
      width: diameter,
      height: diameter,
      shape: WbSkeletonShape.circle,
    );
  }
}
