import 'package:flutter/material.dart';

import '../foundation/typography.dart';
import 'text.dart';

/// 徽标组件。
///
/// 三种形态：
/// - 裸标签：`WbBadge(label: '新')`
/// - 圆点：`WbBadge.dot()`
/// - 计数：`WbBadge.count(5)`
/// - 叠加：`WbBadge(label: '3', child: icon)`（child 右上角）
class WbBadge extends StatelessWidget {
  const WbBadge({
    super.key,
    this.child,
    this.label,
    this.color,
    this.isDot = false,
    this.maxCount,
  });

  /// 圆点徽标。
  const WbBadge.dot({
    super.key,
    this.child,
    this.color,
  })  : label = null,
        isDot = true,
        maxCount = null;

  /// 计数徽标（超过 [maxCount] 显示 `99+`）。
  const WbBadge.count(
    int count, {
    super.key,
    this.child,
    this.color,
    this.maxCount = 99,
  })  : label = '$count',
        isDot = false;

  /// 被叠加的内容（可为空，作为独立徽标渲染）。
  final Widget? child;

  /// 文本标签。
  final String? label;

  /// 背景色。
  final Color? color;

  /// 是否渲染为圆点。
  final bool isDot;

  /// 计数的上限（配合字符串数字解析）。
  final int? maxCount;

  Color _background(BuildContext context) =>
      color ?? Theme.of(context).colorScheme.error;

  String? _resolvedLabel() {
    final String? text = label;
    final int? max = maxCount;
    if (text == null || max == null) {
      return text;
    }
    final int? value = int.tryParse(text);
    if (value == null || value <= max) {
      return text;
    }
    return '$max+';
  }

  Widget _badge(BuildContext context) {
    if (isDot) {
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: _background(context),
          shape: BoxShape.circle,
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: _background(context),
        borderRadius: BorderRadius.circular(9),
      ),
      constraints: const BoxConstraints(minWidth: 16),
      alignment: Alignment.center,
      child: Text(
        _resolvedLabel() ?? '',
        style: WbTypography.caption.copyWith(
          color: Colors.white,
          fontWeight: WbTypography.weightMedium,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget badge = _badge(context);
    final Widget? target = child;
    if (target == null) {
      return badge;
    }
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        target,
        Positioned(
          top: -4,
          right: -8,
          child: badge,
        ),
      ],
    );
  }
}

/// 带文字的次级标签（胶囊型）。
class WbTag extends StatelessWidget {
  const WbTag(
    this.label, {
    super.key,
    this.color,
    this.icon,
  });

  final String label;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final Color background = color ?? Theme.of(context).colorScheme.secondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12),
            const SizedBox(width: 4),
          ],
          WbText(label, variant: WbTextVariant.label),
        ],
      ),
    );
  }
}
