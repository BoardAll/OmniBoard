/// 快捷键设置：文档快捷键总览（只读）与键位冲突检测提示
/// （《白板软件设计文档》§8 快捷键总表、《主题与背景系统设计》§8.5）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
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

/// 快捷键总览：文档键位、冲突提示，以及录制 / 恢复默认。
///
/// 自定义键位写入设置草稿，随「保存」持久化。未挂载 Provider 也可独立 pump。
class HotkeySettings extends StatelessWidget {
  const HotkeySettings({
    super.key,
    this.shortcuts = const <WbShortcut>[],
    this.documented = kWbDocumentedShortcuts,
    this.highContrast = false,
    this.overrides = const <String, List<String>>{},
    this.onChanged,
    this.onReset,
  });

  /// 实际注册表（如 `WbShortcutService.defaults`），用于冲突检测。
  final List<WbShortcut> shortcuts;

  /// 文档快捷键总表（默认 [kWbDocumentedShortcuts]）。
  final List<WbDocumentedShortcut> documented;

  /// 高对比度（键位徽标描边加强）。
  final bool highContrast;

  /// 自定义键位（动作 id → 键位片段）。缺省项用文档默认键位。
  final Map<String, List<String>> overrides;

  /// 录制到新键位后回调（由设置页写入草稿，保存后持久化）。
  final void Function(String id, List<String> keys)? onChanged;

  /// 清空全部自定义键位。
  final VoidCallback? onReset;

  /// 某条文档快捷键当前生效的键位片段。
  static List<String> effectiveKeys(
    WbDocumentedShortcut item,
    Map<String, List<String>> overrides,
  ) {
    final List<String>? custom = overrides[item.id];
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    return item.keys;
  }

  /// 文档总表上的键位冲突（同一组合被多个动作占用）。
  static List<WbShortcutConflict> bindingConflicts(
    List<WbDocumentedShortcut> documented,
    Map<String, List<String>> overrides,
  ) {
    final Map<String, List<String>> byKeys = <String, List<String>>{};
    for (final WbDocumentedShortcut item in documented) {
      final String keys = effectiveKeys(item, overrides).join('+');
      byKeys.putIfAbsent(keys, () => <String>[]).add(item.id);
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
    final List<WbShortcutConflict> conflictList = <WbShortcutConflict>[
      ...bindingConflicts(documented, overrides),
      ...conflicts(shortcuts),
    ];
    final bool canEdit = onChanged != null;
    final Color warn = Theme.of(context).colorScheme.error;

    final List<String> groups = <String>[];
    for (final WbDocumentedShortcut item in documented) {
      if (!groups.contains(item.group)) {
        groups.add(item.group);
      }
    }

    return MiuixTheme(
      data: MiuixThemeData.of(Theme.of(context).brightness),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (conflictList.isNotEmpty)
            Container(
              key: const ValueKey<String>('hotkey-conflict-banner'),
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: warn.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: warn),
              ),
              child: Row(
                children: <Widget>[
                  MiuixIcon(icon: LinearIcons.warning, size: 16, tint: warn),
                  const SizedBox(width: 8),
                  Expanded(
                    child: MiuixText(
                      '检测到 ${conflictList.length} 组键位冲突：'
                      '${conflictList.map((WbShortcutConflict c) => c.keys).join('、')}',
                      fontSize: 12,
                      color: warn,
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              key: const ValueKey<String>('hotkey-conflict-clear'),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: <Widget>[
                  MiuixIcon(
                    icon: LinearIcons.check,
                    size: 14,
                    tint: colors.primary,
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: MiuixText(
                      '未发现键位冲突',
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          for (final String group in groups) ...<Widget>[
            MiuixSmallTitle(
              group,
              insideMargin: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
            ),
            for (final WbDocumentedShortcut item in documented)
              if (item.group == group)
                SettingsTile(
                  title: item.label,
                  subtitle: item.id,
                  onTap: canEdit ? () => _edit(context, item) : null,
                  trailing: Row(
                    key: ValueKey<String>('hotkey-keys-${item.id}'),
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (final String key in effectiveKeys(item, overrides))
                        _KeyBadge(label: key, highContrast: highContrast),
                    ],
                  ),
                ),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: MiuixHorizontalDivider(),
          ),
          MiuixArrowPreference(
            key: const ValueKey<String>('hotkey-reset'),
            title: '恢复默认快捷键',
            summary: overrides.isEmpty ? '当前已是默认键位' : '清除自定义，恢复文档默认键位',
            enabled: onReset != null && overrides.isNotEmpty,
            onClick: onReset != null && overrides.isNotEmpty ? onReset : null,
          ),
          const SettingsHint(
            message: '点击条目后按下新的组合键，再点「使用此键位」。点右上角「保存」后生效。',
          ),
          const SettingsHint(
            message: '滚轮、长按、拖拽类手势改成按键组合后，将以按键为准。',
          ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, WbDocumentedShortcut item) async {
    final void Function(String id, List<String> keys)? changed = onChanged;
    if (changed == null) {
      return;
    }
    final List<String>? next = await showDialog<List<String>>(
      context: context,
      builder: (BuildContext context) => _ShortcutCaptureDialog(
        label: item.label,
        current: effectiveKeys(item, overrides),
      ),
    );
    if (next != null && next.isNotEmpty) {
      changed(item.id, next);
    }
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
    final Color textColor = MiuixTheme.of(context).colors.onSurface;
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
      child: MiuixText(
        label,
        fontSize: 11,
        color: textColor,
      ),
    );
  }
}

/// 录制一条快捷键：按下非修饰键后记下当前修饰键组合。
class _ShortcutCaptureDialog extends StatefulWidget {
  const _ShortcutCaptureDialog({
    required this.label,
    required this.current,
  });

  final String label;
  final List<String> current;

  @override
  State<_ShortcutCaptureDialog> createState() => _ShortcutCaptureDialogState();
}

class _ShortcutCaptureDialogState extends State<_ShortcutCaptureDialog> {
  final FocusNode _focusNode = FocusNode();
  List<String>? _captured;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  static bool _isModifier(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight;
  }

  static bool _pressed(LogicalKeyboardKey left, LogicalKeyboardKey right) {
    final Set<LogicalKeyboardKey> keys =
        HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(left) || keys.contains(right);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (_isModifier(key)) {
      return KeyEventResult.handled;
    }
    final List<String> parts = <String>[];
    if (_pressed(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight)) {
      parts.add('Ctrl');
    }
    if (_pressed(LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight)) {
      parts.add('Alt');
    }
    if (_pressed(LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight)) {
      parts.add('Shift');
    }
    if (_pressed(LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight)) {
      parts.add('⌘');
    }
    parts.add(key.keyLabel);
    setState(() => _captured = parts);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final List<String> shown = _captured ?? widget.current;
    return MiuixTheme(
      data: MiuixThemeData.of(Theme.of(context).brightness),
      child: AlertDialog(
        key: const ValueKey<String>('hotkey-capture-dialog'),
        title: Text('修改「${widget.label}」'),
        content: Focus(
          autofocus: true,
          focusNode: _focusNode,
          onKeyEvent: _onKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const MiuixText('请按下新的组合键。Esc 取消。', fontSize: 13),
              const SizedBox(height: 12),
              MiuixText(
                shown.join(' + '),
                key: const ValueKey<String>('hotkey-capture-preview'),
                fontSize: 16,
              ),
            ],
          ),
        ),
        actions: <Widget>[
          MiuixTextButton(
            '取消',
            onPressed: () => Navigator.of(context).pop(),
          ),
          MiuixButton(
            key: const ValueKey<String>('hotkey-capture-confirm'),
            onPressed: _captured == null
                ? null
                : () => Navigator.of(context).pop(_captured),
            enabled: _captured != null,
            colors: MiuixButtonDefaults.buttonColorsPrimary(context),
            child: const MiuixText('使用此键位'),
          ),
        ],
      ),
    );
  }
}
