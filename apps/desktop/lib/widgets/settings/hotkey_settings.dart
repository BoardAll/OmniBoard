/// 快捷键设置：文档快捷键总览（只读）与键位冲突检测提示
/// （《白板软件设计文档》§8 快捷键总表、《主题与背景系统设计》§8.5）。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../../services/shortcut_service.dart';
import 'settings_section.dart';

/// 文档快捷键条目（《白板软件设计文档》§8 快捷键总表）。
class WbDocumentedShortcut {
  const WbDocumentedShortcut({
    required this.id,
    required this.label,
    required this.keys,
    required this.group,
  });

  /// 动作 id（与文档 / 命令总线风格一致，如 `cmd.palette`）。
  final String id;

  /// 中文显示名。
  final String label;

  /// 键位显示片段（如 `['Ctrl', 'Shift', 'A']`）。
  final List<String> keys;

  /// 分组名（`全局` / `白板编辑` / `导航`）。
  final String group;
}

/// 文档 §8 快捷键总表（展示用；macOS 上 Ctrl 等价显示为 ⌘）。
const List<WbDocumentedShortcut> kWbDocumentedShortcuts =
    <WbDocumentedShortcut>[
  WbDocumentedShortcut(
    id: 'cmd.palette',
    label: '命令面板',
    keys: <String>['Ctrl', 'K'],
    group: '全局',
  ),
  WbDocumentedShortcut(
    id: 'ai.panel',
    label: 'AI 面板',
    keys: <String>['Ctrl', 'Shift', 'A'],
    group: '全局',
  ),
  WbDocumentedShortcut(
    id: 'ai.voice',
    label: '语音输入（按住）',
    keys: <String>['Alt', 'Space'],
    group: '全局',
  ),
  WbDocumentedShortcut(
    id: 'page.manager',
    label: '页面管理',
    keys: <String>['Ctrl', 'P'],
    group: '全局',
  ),
  WbDocumentedShortcut(
    id: 'mode.passthrough',
    label: '切换穿透 / 批注',
    keys: <String>['Alt', 'Shift', 'A'],
    group: '全局',
  ),
  WbDocumentedShortcut(
    id: 'page.new',
    label: '新建页面',
    keys: <String>['Ctrl', 'Shift', 'N'],
    group: '全局',
  ),
  WbDocumentedShortcut(
    id: 'edit.undo',
    label: '撤销',
    keys: <String>['Ctrl', 'Z'],
    group: '白板编辑',
  ),
  WbDocumentedShortcut(
    id: 'edit.redo',
    label: '重做',
    keys: <String>['Ctrl', 'Shift', 'Z'],
    group: '白板编辑',
  ),
  WbDocumentedShortcut(
    id: 'edit.copy',
    label: '复制',
    keys: <String>['Ctrl', 'C'],
    group: '白板编辑',
  ),
  WbDocumentedShortcut(
    id: 'edit.paste',
    label: '粘贴',
    keys: <String>['Ctrl', 'V'],
    group: '白板编辑',
  ),
  WbDocumentedShortcut(
    id: 'edit.selectAll',
    label: '全选',
    keys: <String>['Ctrl', 'A'],
    group: '白板编辑',
  ),
  WbDocumentedShortcut(
    id: 'edit.delete',
    label: '删除',
    keys: <String>['Delete'],
    group: '白板编辑',
  ),
  WbDocumentedShortcut(
    id: 'view.zoom',
    label: '缩放',
    keys: <String>['Ctrl', '滚轮'],
    group: '白板编辑',
  ),
  WbDocumentedShortcut(
    id: 'view.pan',
    label: '平移画布',
    keys: <String>['Space', '拖拽'],
    group: '白板编辑',
  ),
  WbDocumentedShortcut(
    id: 'radial.disk',
    label: '齿轮圆盘',
    keys: <String>['长按画布'],
    group: '导航',
  ),
  WbDocumentedShortcut(
    id: 'page.next',
    label: '下一页',
    keys: <String>['PageDown'],
    group: '导航',
  ),
  WbDocumentedShortcut(
    id: 'page.prev',
    label: '上一页',
    keys: <String>['PageUp'],
    group: '导航',
  ),
];

/// 键位冲突（同一组合被多个动作占用）。
class WbShortcutConflict {
  const WbShortcutConflict({required this.keys, required this.ids});

  /// 冲突键位显示文本，如 `Ctrl+K`。
  final String keys;

  /// 冲突动作 id 列表（长度 >= 2）。
  final List<String> ids;
}

/// 快捷键总览（只读展示 + 冲突检测）。
///
/// 键位自定义编辑依赖配置持久化，Wave 4 接入；当前仅展示与冲突提示，
/// 未挂载 Provider 也可独立 pump。
class HotkeySettings extends StatelessWidget {
  const HotkeySettings({
    super.key,
    this.shortcuts = const <WbShortcut>[],
    this.documented = kWbDocumentedShortcuts,
    this.highContrast = false,
  });

  /// 实际注册表（如 `WbShortcutService.defaults`），用于冲突检测。
  final List<WbShortcut> shortcuts;

  /// 文档快捷键总表（默认 [kWbDocumentedShortcuts]）。
  final List<WbDocumentedShortcut> documented;

  /// 高对比度（键位徽标描边加强）。
  final bool highContrast;

  /// 检测键位冲突：返回同一键位被多个动作占用的分组（纯函数）。
  static List<WbShortcutConflict> conflicts(List<WbShortcut> shortcuts) {
    final Map<String, List<String>> byKeys = <String, List<String>>{};
    for (final WbShortcut shortcut in shortcuts) {
      final String keys = WbShortcutService.describe(shortcut.activator);
      byKeys.putIfAbsent(keys, () => <String>[]).add(shortcut.id);
    }
    return <WbShortcutConflict>[
      for (final MapEntry<String, List<String>> entry in byKeys.entries)
        if (entry.value.length > 1)
          WbShortcutConflict(
            keys: entry.key,
            ids: List<String>.unmodifiable(entry.value),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final TextTheme text = Theme.of(context).textTheme;
    final List<WbShortcutConflict> conflictList = conflicts(shortcuts);
    final Color warn = Theme.of(context).colorScheme.error;

    final List<String> groups = <String>[];
    for (final WbDocumentedShortcut item in documented) {
      if (!groups.contains(item.group)) {
        groups.add(item.group);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (conflictList.isNotEmpty)
          Container(
            key: const ValueKey<String>('hotkey-conflict-banner'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: warn.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: warn),
            ),
            child: Row(
              children: <Widget>[
                Icon(LinearIcons.warning, size: 16, color: warn),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '检测到 ${conflictList.length} 组键位冲突：'
                    '${conflictList.map((WbShortcutConflict c) => c.keys).join('、')}',
                    style: text.bodySmall?.copyWith(color: warn),
                  ),
                ),
              ],
            ),
          )
        else
          Row(
            key: const ValueKey<String>('hotkey-conflict-clear'),
            children: <Widget>[
              Icon(LinearIcons.check, size: 14, color: colors.primary),
              const SizedBox(width: 6),
              Text(
                '未发现键位冲突（基于 WbShortcutService 注册表）',
                style: text.bodySmall?.copyWith(color: colors.icon),
              ),
            ],
          ),
        const SizedBox(height: 8),
        for (final String group in groups) ...<Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Text(
              group,
              style: text.labelMedium?.copyWith(
                color: colors.icon,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final WbDocumentedShortcut item in documented)
            if (item.group == group)
              SettingsTile(
                title: item.label,
                subtitle: item.id,
                trailing: Row(
                  key: ValueKey<String>('hotkey-keys-${item.id}'),
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final String key in item.keys)
                      _KeyBadge(label: key, highContrast: highContrast),
                  ],
                ),
              ),
        ],
        const Divider(height: 20),
        const SettingsHint(
          message: '键位编辑（自定义）依赖配置持久化，Wave 4 接入；当前为只读展示与冲突提示。',
        ),
        const SettingsHint(
          message: 'macOS 上 Ctrl 对应 ⌘（由平台适配层处理，此处按 Windows 习惯展示）。',
        ),
      ],
    );
  }
}

/// 键位徽标（单键展示）。
class _KeyBadge extends StatelessWidget {
  const _KeyBadge({required this.label, required this.highContrast});

  final String label;
  final bool highContrast;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.hover,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: highContrast ? colors.icon : colors.border,
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
      ),
    );
  }
}
