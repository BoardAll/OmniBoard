/// 快捷键服务：应用级快捷键注册表与展示格式化。
library;

import 'dart:io' show Platform;

// services 提供 LogicalKeyboardKey；widgets 提供快捷键类
// （ShortcutActivator / SingleActivator）。
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 快捷键作用域。
enum WbShortcutScope {
  /// 全局（任何页面可用）。
  global,

  /// 白板编辑页。
  board,
}

/// 一条快捷键定义。
class WbShortcut {
  const WbShortcut({
    required this.id,
    required this.label,
    required this.activator,
    this.scope = WbShortcutScope.board,
  });

  /// 动作 id（与命令总线 / 工具 id 风格一致，如 `edit.undo`）。
  final String id;

  /// 中文显示名。
  final String label;

  /// 键位组合。
  final ShortcutActivator activator;

  /// 作用域。
  final WbShortcutScope scope;
}

/// 快捷键服务：默认键位表 + 平台感知格式化。
///
/// 骨架：仅提供注册表与展示；窗口级 `Shortcuts`/`Actions` 接线在
/// 编辑页（Wave 3），全局热键（hotkey_manager）在平台插件（Wave 2.6）。
class WbShortcutService {
  /// 默认快捷键表（macOS 自动使用 ⌘，其他平台 Ctrl）。
  static final List<WbShortcut> defaults = <WbShortcut>[
    WbShortcut(
      id: 'edit.undo',
      label: '撤销',
      activator: _primary(LogicalKeyboardKey.keyZ),
    ),
    WbShortcut(
      id: 'edit.redo',
      label: '重做',
      activator: _primary(LogicalKeyboardKey.keyZ, shift: true),
    ),
    WbShortcut(
      id: 'edit.copy',
      label: '复制',
      activator: _primary(LogicalKeyboardKey.keyC),
    ),
    WbShortcut(
      id: 'edit.cut',
      label: '剪切',
      activator: _primary(LogicalKeyboardKey.keyX),
    ),
    WbShortcut(
      id: 'edit.paste',
      label: '粘贴',
      activator: _primary(LogicalKeyboardKey.keyV),
    ),
    WbShortcut(
      id: 'edit.duplicate',
      label: '创建副本',
      activator: _primary(LogicalKeyboardKey.keyD),
    ),
    WbShortcut(
      id: 'edit.selectAll',
      label: '全选',
      activator: _primary(LogicalKeyboardKey.keyA),
    ),
    const WbShortcut(
      id: 'edit.delete',
      label: '删除所选',
      activator: SingleActivator(LogicalKeyboardKey.delete),
    ),
    WbShortcut(
      id: 'file.save',
      label: '保存',
      activator: _primary(LogicalKeyboardKey.keyS),
      scope: WbShortcutScope.global,
    ),
    WbShortcut(
      id: 'file.export',
      label: '导出',
      activator: _primary(LogicalKeyboardKey.keyE),
    ),
    WbShortcut(
      id: 'view.resetZoom',
      label: '重置缩放',
      activator: _primary(LogicalKeyboardKey.digit0),
    ),
    WbShortcut(
      id: 'view.fitScreen',
      label: '适应画布',
      activator: _primary(LogicalKeyboardKey.digit1),
    ),
  ];

  /// 按动作 id 查询（未找到返回 null）。
  static WbShortcut? byId(String id) {
    for (final WbShortcut shortcut in defaults) {
      if (shortcut.id == id) {
        return shortcut;
      }
    }
    return null;
  }

  /// 格式化键位组合为显示文本（如 `Ctrl+Z` / `⌘+Z`）。
  static String describe(ShortcutActivator activator) {
    if (activator is! SingleActivator) {
      return activator.toString();
    }
    final List<String> parts = <String>[];
    if (activator.control) {
      parts.add('Ctrl');
    }
    if (activator.meta) {
      parts.add('⌘');
    }
    if (activator.alt) {
      parts.add('Alt');
    }
    if (activator.shift) {
      parts.add('Shift');
    }
    parts.add(activator.trigger.keyLabel);
    return parts.join('+');
  }

  /// 查找某动作 id 的显示键位（找不到返回空串）。
  static String describeById(String id) {
    final WbShortcut? shortcut = byId(id);
    return shortcut == null ? '' : describe(shortcut.activator);
  }

  static SingleActivator _primary(
    LogicalKeyboardKey trigger, {
    bool shift = false,
  }) {
    final bool mac = Platform.isMacOS;
    return SingleActivator(
      trigger,
      control: !mac,
      meta: mac,
      shift: shift,
    );
  }
}
