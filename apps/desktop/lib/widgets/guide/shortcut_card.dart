/// 快捷键卡片：按功能分组展示快捷键
/// （《用户手册与帮助文档设计》§4.3 / §10 快捷键文档）。
///
/// - [WbShortcutCard] 可直接嵌入引导完成页、帮助中心或设置页；
/// - [WbShortcutKeys] 将键位文本按 `+` 拆分为键帽徽章，供其他模块复用；
/// - 分组与条目数据来自 [WbGuideContent.shortcutGroups]，其中标注
///   `shortcutId` 的条目键位由应用快捷键注册表动态解析。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import 'guide_content.dart';
import 'guide_icons.dart';

/// 快捷键卡片（分组只读展示）。
class WbShortcutCard extends StatelessWidget {
  const WbShortcutCard({
    super.key,
    this.groups = WbGuideContent.shortcutGroups,
    this.compact = false,
    this.title = '快捷键',
  });

  /// 快捷键分组（默认 [WbGuideContent.shortcutGroups]）。
  final List<WbGuideShortcutGroup> groups;

  /// 紧凑模式（较小的间距与键帽，供引导浮层等场景使用）。
  final bool compact;

  /// 卡片标题。
  final String title;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Container(
      key: const ValueKey<String>('wb-guide-shortcut-card'),
      padding: EdgeInsets.all(compact ? 10 : 14),
      decoration: BoxDecoration(
        color: colors.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.cardBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(LinearIcons.grid, size: 16, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final WbGuideShortcutGroup group in groups)
            _ShortcutGroupBlock(group: group, compact: compact),
        ],
      ),
    );
  }
}

/// 单个快捷键分组块（标题行 + 条目行）。
class _ShortcutGroupBlock extends StatelessWidget {
  const _ShortcutGroupBlock({required this.group, required this.compact});

  final WbGuideShortcutGroup group;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Column(
      key: ValueKey<String>('wb-guide-shortcut-group-${group.id}'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(top: compact ? 8 : 12, bottom: 2),
          child: Row(
            children: <Widget>[
              Icon(
                wbGuideIcon(group.icon),
                size: 13,
                color: colors.icon,
              ),
              const SizedBox(width: 6),
              Text(
                group.name,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.icon,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  fontSize: compact ? 10 : 11,
                ),
              ),
            ],
          ),
        ),
        for (final WbGuideShortcut entry in group.entries)
          _ShortcutRow(entry: entry, compact: compact),
      ],
    );
  }
}

/// 单条快捷键行（动作名 + 键位徽章）。
class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.entry, required this.compact});

  final WbGuideShortcut entry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      key: ValueKey<String>('wb-guide-shortcut-${entry.id}'),
      padding: EdgeInsets.symmetric(vertical: compact ? 3 : 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              entry.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: compact ? 11 : 12,
              ),
            ),
          ),
          const SizedBox(width: 8),
          WbShortcutKeys(keys: entry.resolvedKeys, compact: compact),
        ],
      ),
    );
  }
}

/// 键位徽章组：将键位文本按 `+` 拆分为多个键帽（如 `Ctrl` `Shift` `Z`）。
class WbShortcutKeys extends StatelessWidget {
  const WbShortcutKeys({super.key, required this.keys, this.compact = false});

  /// 键位显示文本（含 `+` 时拆分；否则整体一个键帽）。
  final String keys;

  /// 紧凑模式。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final List<String> parts = keys.contains('+')
        ? keys
            .split('+')
            .map((String part) => part.trim())
            .where((String part) => part.isNotEmpty)
            .toList(growable: false)
        : <String>[keys];
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      alignment: WrapAlignment.end,
      children: <Widget>[
        for (final String part in parts)
          _KeyCap(label: part, compact: compact),
      ],
    );
  }
}

/// 单个键帽徽章。
class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.label, required this.compact});

  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 6,
        vertical: compact ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.cardBorder),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.icon,
              fontSize: compact ? 10 : 11,
            ),
      ),
    );
  }
}
