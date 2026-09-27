/// 圆盘右键配置菜单与"更多"菜单（文档 5.1 右键、5.4 更多入口、11 设置项）。
///
/// 菜单本身无状态：用户选择通过回调上交 `RadialToolbar` 消化。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';

import 'radial_models.dart';

/// 配置菜单项 id（内部路由用，测试可直接引用）。
abstract final class RadialConfigValues {
  /// 锁定 / 解锁。
  static const String lock = 'lock';

  /// 隐藏圆盘。
  static const String hide = 'hide';

  /// 尺寸：小。
  static const String sizeSmall = 'size:small';

  /// 尺寸：中。
  static const String sizeMedium = 'size:medium';

  /// 尺寸：大。
  static const String sizeLarge = 'size:large';

  /// 显示标签。
  static const String labels = 'labels';

  /// 显示最近使用。
  static const String recent = 'recent';

  /// 展开动效。
  static const String animations = 'animations';

  /// 拖拽轨迹线。
  static const String trail = 'trail';

  /// 清空最近使用。
  static const String clearRecent = 'clearRecent';
}

/// 显示右键配置菜单（文档 5.1：右键圆盘打开配置菜单）。
///
/// [globalPosition] 为右键点击位置；各回调在用户选择后调用。
Future<void> showRadialConfigMenu(
  BuildContext context, {
  required Offset globalPosition,
  required RadialSettings settings,
  required bool locked,
  required bool hasRecent,
  required ValueChanged<RadialSettings> onSettings,
  required VoidCallback onToggleLock,
  required VoidCallback onHide,
  required VoidCallback onClearRecent,
}) async {
  final String? selected = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      globalPosition.dx,
      globalPosition.dy,
    ),
    items: <PopupMenuEntry<String>>[
      PopupMenuItem<String>(
        value: RadialConfigValues.lock,
        child: _menuRow(
          locked ? LinearIcons.unlock : LinearIcons.lock,
          locked ? '解锁圆盘' : '锁定圆盘',
        ),
      ),
      PopupMenuItem<String>(
        value: RadialConfigValues.hide,
        child: _menuRow(LinearIcons.visible, '隐藏圆盘'),
      ),
      const PopupMenuDivider(),
      CheckedPopupMenuItem<String>(
        value: RadialConfigValues.sizeSmall,
        checked: settings.size == RadialSizeOption.small,
        child: const Text('大小：小'),
      ),
      CheckedPopupMenuItem<String>(
        value: RadialConfigValues.sizeMedium,
        checked: settings.size == RadialSizeOption.medium,
        child: const Text('大小：中'),
      ),
      CheckedPopupMenuItem<String>(
        value: RadialConfigValues.sizeLarge,
        checked: settings.size == RadialSizeOption.large,
        child: const Text('大小：大'),
      ),
      const PopupMenuDivider(),
      CheckedPopupMenuItem<String>(
        value: RadialConfigValues.labels,
        checked: settings.showLabels,
        child: const Text('显示标签'),
      ),
      CheckedPopupMenuItem<String>(
        value: RadialConfigValues.recent,
        checked: settings.showRecent,
        child: const Text('显示最近使用'),
      ),
      CheckedPopupMenuItem<String>(
        value: RadialConfigValues.animations,
        checked: settings.animations,
        child: const Text('展开动效'),
      ),
      CheckedPopupMenuItem<String>(
        value: RadialConfigValues.trail,
        checked: settings.showTrail,
        child: const Text('拖拽轨迹线'),
      ),
      const PopupMenuDivider(),
      PopupMenuItem<String>(
        value: RadialConfigValues.clearRecent,
        enabled: hasRecent,
        child: const Text('清空最近使用'),
      ),
    ],
  );

  switch (selected) {
    case RadialConfigValues.lock:
      onToggleLock();
    case RadialConfigValues.hide:
      onHide();
    case RadialConfigValues.sizeSmall:
      onSettings(settings.copyWith(size: RadialSizeOption.small));
    case RadialConfigValues.sizeMedium:
      onSettings(settings.copyWith(size: RadialSizeOption.medium));
    case RadialConfigValues.sizeLarge:
      onSettings(settings.copyWith(size: RadialSizeOption.large));
    case RadialConfigValues.labels:
      onSettings(settings.copyWith(showLabels: !settings.showLabels));
    case RadialConfigValues.recent:
      onSettings(settings.copyWith(showRecent: !settings.showRecent));
    case RadialConfigValues.animations:
      onSettings(settings.copyWith(animations: !settings.animations));
    case RadialConfigValues.trail:
      onSettings(settings.copyWith(showTrail: !settings.showTrail));
    case RadialConfigValues.clearRecent:
      onClearRecent();
    default:
      break;
  }
}

/// "更多"菜单项 id（内部路由用）。
abstract final class RadialMoreValues {
  /// 撤销。
  static const String undo = 'undo';

  /// 重做。
  static const String redo = 'redo';

  /// 隐藏圆盘。
  static const String hide = 'hide';
}

/// 显示"更多"菜单（内环"更多"入口，文档 4：AI 入口在更多里）。
///
/// [onAction] 透传动作 id（如 [kRadialAiAssistantId] / [kRadialSettingsId]）。
Future<void> showRadialMoreMenu(
  BuildContext context, {
  required Offset globalPosition,
  required VoidCallback onUndo,
  required VoidCallback onRedo,
  required ValueChanged<String> onAction,
  required VoidCallback onHide,
}) async {
  final String? selected = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      globalPosition.dx,
      globalPosition.dy,
    ),
    items: <PopupMenuEntry<String>>[
      PopupMenuItem<String>(
        value: RadialMoreValues.undo,
        child: _menuRow(LinearIcons.undo, '撤销'),
      ),
      PopupMenuItem<String>(
        value: RadialMoreValues.redo,
        child: _menuRow(LinearIcons.redo, '重做'),
      ),
      const PopupMenuDivider(),
      PopupMenuItem<String>(
        value: kRadialAiAssistantId,
        child: _menuRow(LinearIcons.ai, 'AI 助手'),
      ),
      PopupMenuItem<String>(
        value: kRadialSettingsId,
        child: _menuRow(LinearIcons.settings, '设置'),
      ),
      const PopupMenuDivider(),
      PopupMenuItem<String>(
        value: RadialMoreValues.hide,
        child: _menuRow(LinearIcons.visible, '隐藏圆盘'),
      ),
    ],
  );

  switch (selected) {
    case RadialMoreValues.undo:
      onUndo();
    case RadialMoreValues.redo:
      onRedo();
    case RadialMoreValues.hide:
      onHide();
    case kRadialAiAssistantId || kRadialSettingsId:
      onAction(selected!);
    default:
      break;
  }
}

Widget _menuRow(IconData icon, String label) {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Icon(icon, size: 18),
      const SizedBox(width: 8),
      Text(label),
    ],
  );
}
