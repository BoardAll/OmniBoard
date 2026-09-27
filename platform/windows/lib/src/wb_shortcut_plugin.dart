/// 全局快捷键插件接口与 Windows 方法通道实现。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'wb_window_plugin.dart';

/// 全局快捷键注册（《Flutter + C++ 工程结构设计》§6.5）。
abstract class WbShortcutPlugin {
  /// 注册全局快捷键。
  ///
  /// [accelerator] 形如 `Ctrl+Shift+J`；修饰键支持 `Ctrl` / `Alt` /
  /// `Shift` / `⌘`（Cmd）/ `Win`（Super），主键为单个字符或功能键名
  /// （`F1`…`F12`、`Space`、`Tab` 等）。
  Future<void> register(String accelerator, String id);

  /// 注销单个快捷键。
  Future<void> unregister(String id);

  /// 注销全部快捷键。
  Future<void> unregisterAll();

  /// 快捷键触发事件流（值为注册时的 [id]）。
  Stream<String> get onTriggered;
}

/// Windows 实现：与窗口插件共用通道 `whiteboard/windows`。
///
/// 原生侧使用 `RegisterHotKey` + 插件私有消息窗口转发 `WM_HOTKEY`。
/// 同一时刻只应存在一个实例（后创建者接管触发事件分发）。
class WindowsShortcutPlugin implements WbShortcutPlugin {
  WindowsShortcutPlugin({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(WindowsWindowPlugin.channelName) {
    _channel.setMethodCallHandler(_handleCall);
  }

  final MethodChannel _channel;
  final StreamController<String> _triggered =
      StreamController<String>.broadcast();

  @override
  Stream<String> get onTriggered => _triggered.stream;

  @override
  Future<void> register(String accelerator, String id) =>
      _invoke('shortcut.register', <String, Object?>{
        'accelerator': accelerator,
        'id': id,
      });

  @override
  Future<void> unregister(String id) =>
      _invoke('shortcut.unregister', <String, Object?>{'id': id});

  @override
  Future<void> unregisterAll() => _invoke('shortcut.unregisterAll');

  /// 释放资源（清空原生事件回调并关闭触发流）。
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _triggered.close();
  }

  /// 原生未注册时静默降级为 no-op（触发流保持为空）。
  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // 降级：忽略。
    }
  }

  Future<Object?> _handleCall(MethodCall call) async {
    if (call.method != 'shortcut.triggered') {
      return null;
    }
    final Object? arguments = call.arguments;
    if (arguments is Map) {
      final Object? id = arguments['id'];
      if (id is String && id.isNotEmpty && !_triggered.isClosed) {
        _triggered.add(id);
      }
    }
    return null;
  }
}
