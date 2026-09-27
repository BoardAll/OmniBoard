/// 统一窗口插件接口与 macOS 方法通道实现。
library;

import 'package:flutter/services.dart';

/// 平台窗口能力（《Flutter + C++ 工程结构设计》§6.5）。
///
/// Windows 与 macOS 提供同名接口与语义；调用方（桌面应用）按平台
/// 选择实现。
abstract class WbWindowPlugin {
  /// 窗口背景是否透明（透明批注覆盖层模式，见《透明批注模式技术方案》§3）。
  Future<void> setTransparent(bool transparent);

  /// 是否始终置顶。
  Future<void> setAlwaysOnTop(bool onTop);

  /// 是否忽略鼠标事件（点击穿透）。
  ///
  /// [forward] 为 true 时仍接收鼠标移动消息（用于悬停高亮），
  /// 点击事件继续穿透到下层窗口；macOS 无 Win32 消息转发的
  /// 对应机制，原生侧按“尽力”处理（详见 `WindowPlugin.mm` 注释）。
  Future<void> setIgnoreMouseEvents(bool ignore, {bool forward = false});

  /// 全屏切换。
  Future<void> setFullscreen(bool fullscreen);

  /// 移动窗口到屏幕坐标（逻辑像素）。
  Future<void> setPosition(int x, int y);

  /// 调整窗口尺寸（逻辑像素）。
  Future<void> setSize(int width, int height);
}

/// macOS 实现：MethodChannel `whiteboard/macos`。
class MacosWindowPlugin implements WbWindowPlugin {
  MacosWindowPlugin({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// 平台通道名（与原生 `WhiteboardMacosPlugin.mm` 一致）。
  static const String channelName = 'whiteboard/macos';

  final MethodChannel _channel;

  @override
  Future<void> setTransparent(bool transparent) =>
      _invoke('window.setTransparent', <String, Object?>{
        'transparent': transparent,
      });

  @override
  Future<void> setAlwaysOnTop(bool onTop) =>
      _invoke('window.setAlwaysOnTop', <String, Object?>{'onTop': onTop});

  @override
  Future<void> setIgnoreMouseEvents(bool ignore, {bool forward = false}) =>
      _invoke('window.setIgnoreMouseEvents', <String, Object?>{
        'ignore': ignore,
        'forward': forward,
      });

  @override
  Future<void> setFullscreen(bool fullscreen) =>
      _invoke('window.setFullscreen', <String, Object?>{
        'fullscreen': fullscreen,
      });

  @override
  Future<void> setPosition(int x, int y) =>
      _invoke('window.setPosition', <String, Object?>{'x': x, 'y': y});

  @override
  Future<void> setSize(int width, int height) =>
      _invoke('window.setSize', <String, Object?>{
        'width': width,
        'height': height,
      });

  /// 原生未注册（未打包 / 测试环境）时静默降级为 no-op（Wave 4 打包接管）。
  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // 降级：忽略。
    }
  }
}
