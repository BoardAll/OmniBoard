/// 托盘插件接口与 macOS 方法通道实现。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'wb_window_plugin.dart';

/// 托盘菜单项类型。
enum WbTrayMenuItemType {
  /// 普通可点击项。
  normal,

  /// 分隔线（[WbTrayMenuItem.id] 可为空）。
  separator,

  /// 复选项（原生侧渲染勾选标记，状态由应用维护）。
  checkbox,
}

/// 托盘菜单项。
class WbTrayMenuItem {
  const WbTrayMenuItem({
    required this.id,
    this.label = '',
    this.type = WbTrayMenuItemType.normal,
    this.enabled = true,
    this.checked = false,
  });

  /// 稳定 id（点击事件回传）。
  final String id;

  /// 显示文本。
  final String label;

  /// 类型。
  final WbTrayMenuItemType type;

  /// 是否可用。
  final bool enabled;

  /// 复选项是否勾选。
  final bool checked;

  /// 序列化为平台通道参数。
  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'label': label,
        'type': type.name,
        'enabled': enabled,
        'checked': checked,
      };
}

/// 系统托盘（《Flutter + C++ 工程结构设计》§6.5）。
abstract class WbTrayPlugin {
  /// 设置托盘图标（平台图标资源路径 / 绝对路径）。
  Future<void> setIcon(String iconPath);

  /// 设置悬停提示。
  Future<void> setTooltip(String tooltip);

  /// 设置右键菜单（整体替换）。
  Future<void> setMenu(List<WbTrayMenuItem> items);

  /// 菜单项点击事件流（值为 [WbTrayMenuItem.id]）。
  Stream<String> get onMenuItemClicked;
}

/// macOS 实现：与窗口插件共用通道 `whiteboard/macos`。
///
/// 原生侧使用 `NSStatusBar` 系统状态栏项（`NSStatusItem`）与
/// `NSMenu`；点击项通过 `representedObject` 回传稳定 id。
/// 同一时刻只应存在一个实例。
class MacosTrayPlugin implements WbTrayPlugin {
  MacosTrayPlugin({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(MacosWindowPlugin.channelName) {
    _channel.setMethodCallHandler(_handleCall);
  }

  final MethodChannel _channel;
  final StreamController<String> _clicked = StreamController<String>.broadcast();

  @override
  Stream<String> get onMenuItemClicked => _clicked.stream;

  @override
  Future<void> setIcon(String iconPath) =>
      _invoke('tray.setIcon', <String, Object?>{'iconPath': iconPath});

  @override
  Future<void> setTooltip(String tooltip) =>
      _invoke('tray.setTooltip', <String, Object?>{'tooltip': tooltip});

  @override
  Future<void> setMenu(List<WbTrayMenuItem> items) => _invoke(
        'tray.setMenu',
        <String, Object?>{
          'items': items
              .map((WbTrayMenuItem item) => item.toMap())
              .toList(growable: false),
        },
      );

  /// 释放资源（清空原生事件回调并关闭点击流）。
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _clicked.close();
  }

  /// 原生未注册时静默降级为 no-op（点击流保持为空）。
  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // 降级：忽略。
    }
  }

  Future<Object?> _handleCall(MethodCall call) async {
    if (call.method != 'tray.clicked') {
      return null;
    }
    final Object? arguments = call.arguments;
    if (arguments is Map) {
      final Object? id = arguments['id'];
      if (id is String && id.isNotEmpty && !_clicked.isClosed) {
        _clicked.add(id);
      }
    }
    return null;
  }
}
