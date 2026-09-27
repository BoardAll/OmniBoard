import 'package:flutter/material.dart';

import '../foundation/spacing.dart';

/// 水平分隔线。
class WbDivider extends StatelessWidget {
  const WbDivider({
    super.key,
    this.thickness = 1,
    this.indent = 0,
    this.endIndent = 0,
    this.color,
  });

  final double thickness;
  final double indent;
  final double endIndent;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: thickness,
      thickness: thickness,
      indent: indent,
      endIndent: endIndent,
      color: color ?? Theme.of(context).dividerColor,
    );
  }
}

/// 垂直分隔线（用于工具条/行内布局）。
class WbVerticalDivider extends StatelessWidget {
  const WbVerticalDivider({
    super.key,
    this.thickness = 1,
    this.height = 20,
    this.margin = const EdgeInsets.symmetric(horizontal: WbSpacing.sm),
    this.color,
  });

  final double thickness;

  /// 分隔线自身绘制高度（不改变父布局高度）。
  final double height;
  final EdgeInsetsGeometry margin;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: thickness,
      height: height,
      margin: margin,
      color: color ?? Theme.of(context).dividerColor,
    );
  }
}
