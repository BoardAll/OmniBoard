/// 设置分区组件：统一设置页的分组标题、卡片容器与条目样式。
library;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

/// 设置分区：标题（可带图标 / 尾部操作）+ 说明 + 卡片容器。
///
/// 卡片描边在高对比度模式下加粗（文档 §9：焦点环与对比度强化）。
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.icon,
    this.trailing,
    this.highContrast = false,
  });

  /// 分区标题（同时生成测试 key：`settings-section-card-<title>`）。
  final String title;

  /// 分区说明（可选，显示在标题下方）。
  final String? subtitle;

  /// 标题前置图标（可选）。
  final IconData? icon;

  /// 标题行尾部控件（可选）。
  final Widget? trailing;

  /// 卡片内容（自上而下排列）。
  final List<Widget> children;

  /// 高对比度：加粗卡片描边。
  final bool highContrast;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final double radius = context.wbTheme.radius.m;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 18, color: colors.icon),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: MiuixSmallTitle(
                  title,
                  insideMargin: const EdgeInsets.symmetric(vertical: 4),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: MiuixText(
                subtitle!,
                fontSize: 12,
                color: colors.icon,
              ),
            ),
          const SizedBox(height: 12),
          Container(
            key: ValueKey<String>('settings-section-card-$title'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: colors.cardBackground,
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: highContrast ? colors.icon : colors.cardBorder,
                width: highContrast ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置条目：前置图标（可选）+ 标题 / 说明 + 尾部控件。
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.dense = true,
  });

  /// 条目标题。
  final String title;

  /// 条目说明（可选）。
  final String? subtitle;

  /// 前置图标等（可选）。
  final Widget? leading;

  /// 尾部控件（开关、键位徽标等；可选）。
  final Widget? trailing;

  /// 点击回调（可选；提供时整行可点击）。
  final VoidCallback? onTap;

  /// 紧凑行高（默认 true）。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return MiuixBasicComponent(
      title: title,
      summary: subtitle,
      startAction: leading,
      endActions: trailing == null ? null : <Widget>[trailing!],
      onClick: onTap,
      insideMargin: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: dense ? 6 : 10,
      ),
    );
  }
}

/// 设置说明行：小号提示文本 + 前置图标（只读说明 / 偏差标注）。
class SettingsHint extends StatelessWidget {
  const SettingsHint({
    super.key,
    required this.message,
    this.icon = LinearIcons.info,
  });

  /// 提示文本。
  final String message;

  /// 前置图标。
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 14, color: colors.icon),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: MiuixText(
              message,
              fontSize: 12,
              color: colors.icon,
            ),
          ),
        ],
      ),
    );
  }
}
