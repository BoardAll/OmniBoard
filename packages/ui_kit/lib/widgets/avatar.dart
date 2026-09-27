import 'package:flutter/material.dart';

import '../foundation/typography.dart';
import '../utils/text_utils.dart';

/// 头像尺寸档位。
enum WbAvatarSize {
  /// 小（列表内）。
  s(24),

  /// 中（默认）。
  m(32),

  /// 大（个人资料）。
  l(40),

  /// 特大（成员管理页）。
  xl(56);

  const WbAvatarSize(this.px);

  /// 像素尺寸。
  final double px;
}

/// 基础头像组件：图片优先，缺省回退到名称首字。
class WbAvatar extends StatelessWidget {
  const WbAvatar({
    super.key,
    this.name,
    this.imageUrl,
    this.size = WbAvatarSize.m,
    this.backgroundColor,
  });

  /// 名称（用于首字回退与语义标签）。
  final String? name;

  /// 图片地址（null 时展示首字）。
  final String? imageUrl;

  final WbAvatarSize size;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = backgroundColor ?? scheme.primaryContainer;
    final String initials = name == null || name!.isEmpty ? '?' : WbTextUtils.initials(name!);
    final Widget fallback = Container(
      width: size.px,
      height: size.px,
      alignment: Alignment.center,
      color: background,
      child: Text(
        initials,
        style: WbTypography.label.copyWith(
          color: scheme.onPrimaryContainer,
          fontSize: size.px * 0.42,
          fontWeight: WbTypography.weightMedium,
        ),
      ),
    );

    Widget avatar = fallback;
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      avatar = Image.network(
        imageUrl!,
        width: size.px,
        height: size.px,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (BuildContext context, Object error, StackTrace? stackTrace) => fallback,
      );
    }
    return Semantics(
      label: name,
      image: true,
      child: ClipOval(child: SizedBox(width: size.px, height: size.px, child: avatar)),
    );
  }
}
