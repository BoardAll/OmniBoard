import 'package:flutter/material.dart';

import '../foundation/typography.dart';

/// 文本样式变体。
enum WbTextVariant {
  /// 辅助说明（最小号）。
  caption,

  /// 次级标签。
  label,

  /// 正文。
  body,

  /// 正文（中等字重）。
  bodyMedium,

  /// 面板标题。
  title,

  /// 区块标题。
  heading,

  /// 页面大标题。
  display,
}

/// 基础文本组件：把 [WbTextVariant] 映射到 [WbTypography] 预置样式。
class WbText extends StatelessWidget {
  const WbText(
    this.data, {
    super.key,
    this.variant = WbTextVariant.body,
    this.color,
    this.maxLines,
    this.overflow = TextOverflow.ellipsis,
    this.textAlign,
    this.softWrap = true,
    this.fontWeight,
  });

  final String data;
  final WbTextVariant variant;
  final Color? color;
  final int? maxLines;
  final TextOverflow overflow;
  final TextAlign? textAlign;
  final bool softWrap;
  final FontWeight? fontWeight;

  /// 变体到预置样式的映射。
  static TextStyle styleOf(WbTextVariant variant) => switch (variant) {
        WbTextVariant.caption => WbTypography.caption,
        WbTextVariant.label => WbTypography.label,
        WbTextVariant.body => WbTypography.body,
        WbTextVariant.bodyMedium => WbTypography.bodyMedium,
        WbTextVariant.title => WbTypography.title,
        WbTextVariant.heading => WbTypography.heading,
        WbTextVariant.display => WbTypography.display,
      };

  @override
  Widget build(BuildContext context) {
    TextStyle style = styleOf(variant);
    if (color != null) {
      style = style.copyWith(color: color);
    }
    if (fontWeight != null) {
      style = style.copyWith(fontWeight: fontWeight);
    }
    if (color == null) {
      // 未显式指定颜色时继承主题默认文本色，并为 caption/label 降级为次级色。
      final ColorScheme scheme = Theme.of(context).colorScheme;
      if (variant == WbTextVariant.caption || variant == WbTextVariant.label) {
        style = style.copyWith(
          color: scheme.onSurface.withValues(alpha: 0.6),
        );
      } else {
        style = style.copyWith(color: scheme.onSurface);
      }
    }
    return Text(
      data,
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
      softWrap: softWrap,
    );
  }
}
