import 'package:flutter/material.dart';

import '../foundation/radius.dart';

/// 线性进度条（value 为 null 时是不确定态）。
class WbProgressBar extends StatelessWidget {
  const WbProgressBar({
    super.key,
    this.value,
    this.color,
    this.height = 4,
    this.radius,
  });

  /// 进度 0~1；null 为不确定态。
  final double? value;
  final Color? color;

  /// 进度条高度。
  final double height;

  /// 圆角半径；null 表示自动取高度的一半。
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final Color foreground = color ?? Theme.of(context).colorScheme.primary;
    return ClipRRect(
      borderRadius: WbRadius.circular(radius ?? height / 2),
      child: LinearProgressIndicator(
        value: value,
        minHeight: height,
        color: foreground,
        backgroundColor: foreground.withValues(alpha: 0.12),
      ),
    );
  }
}

/// 环形进度指示器（value 为 null 时是不确定态）。
class WbProgressRing extends StatelessWidget {
  const WbProgressRing({
    super.key,
    this.value,
    this.color,
    this.size = 20,
    this.strokeWidth = 2.5,
  });

  /// 进度 0~1；null 为不确定态。
  final double? value;
  final Color? color;
  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        value: value,
        color: color ?? Theme.of(context).colorScheme.primary,
        strokeWidth: strokeWidth,
        backgroundColor: Colors.transparent,
      ),
    );
  }
}
