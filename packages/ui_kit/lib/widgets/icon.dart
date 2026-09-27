import 'package:flutter/material.dart';

/// 基础图标组件。
///
/// 统一默认尺寸（紧凑 UI 18）并透传 [IconTheme]，供全应用图标渲染复用。
class WbIcon extends StatelessWidget {
  const WbIcon(
    this.icon, {
    super.key,
    this.size = defaultSize,
    this.color,
    this.semanticLabel,
  });

  /// 默认图标尺寸。
  static const double defaultSize = 18;

  /// 小尺寸（列表项内）。
  static const double smallSize = 14;

  /// 大尺寸（空状态）。
  static const double largeSize = 32;

  final IconData icon;
  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Icon(
      icon,
      size: size,
      color: color,
      semanticLabel: semanticLabel,
    );
  }
}
