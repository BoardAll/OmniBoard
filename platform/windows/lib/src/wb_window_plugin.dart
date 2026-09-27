/// 统一窗口插件接口与 Windows 方法通道实现。
library;

import 'package:flutter/services.dart';

/// 平台窗口能力（《Flutter + C++ 工程结构设计》§6.5）。
///
/// Windows 与 macOS 提供同名接口与语义；调用方（桌面应用）按平台
/// 选择实现。
abstract class WbWindowPlugin {
  /// 窗口背景是否透明（透明批注覆盖层模式，见《透明批注模式技术方案》§3）。
  ///
  /// 返回透明设置是否成功：Windows 原生经 SetWindowCompositionAttribute
  /// 强调色策略交由 DWM 合成；API 缺失（旧系统）或调用失败返回 false，
  /// 调用方可据此降级（例如改用截图作为背景）。
  Future<bool> setTransparent(bool transparent);

  /// 是否始终置顶。
  Future<void> setAlwaysOnTop(bool onTop);

  /// 是否忽略鼠标事件（点击穿透）。
  ///
  /// [forward] 为 true 时仍接收鼠标移动消息（用于悬停高亮），
  /// 点击事件继续穿透到下层窗口。
  Future<void> setIgnoreMouseEvents(bool ignore, {bool forward = false});

  /// 全屏切换。
  Future<void> setFullscreen(bool fullscreen);

  /// 移动窗口到屏幕坐标（逻辑像素）。
  Future<void> setPosition(int x, int y);

  /// 调整窗口尺寸（逻辑像素）。
  Future<void> setSize(int width, int height);

  /// 打开系统「选择图片」文件对话框。
  ///
  /// 返回选中文件的绝对路径；用户取消、平台未实现或原生未注册
  /// （测试环境）返回 null。默认实现返回 null（不破坏外部实现类），
  /// Windows 覆写为原生模态对话框（`dialog.openImage`）。
  Future<String?> openImageFile() async => null;

  /// 打开系统「打开白板」文件对话框（`.wbd`）。
  ///
  /// 返回选中文件的绝对路径；用户取消、平台未实现或原生未注册
  /// （测试环境）返回 null。默认实现返回 null，Windows 覆写为原生
  /// 模态对话框（`dialog.openBoard`）。
  Future<String?> openBoardFile() async => null;

  /// 打开系统「保存白板」文件对话框（`.wbd`）。
  ///
  /// [suggestedPath] 为建议全路径（原生预填文件名）；返回目标绝对
  /// 路径，取消 / 平台未实现 / 原生未注册返回 null。默认实现返回
  /// null，Windows 覆写为原生模态对话框（`dialog.saveBoard`）。
  Future<String?> saveBoardFile({String suggestedPath = ''}) async => null;
}

/// Windows 实现：MethodChannel `whiteboard/windows`。
class WindowsWindowPlugin implements WbWindowPlugin {
  WindowsWindowPlugin({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// 平台通道名（与原生 `whiteboard_windows_plugin.cpp` 一致）。
  static const String channelName = 'whiteboard/windows';

  final MethodChannel _channel;

  @override
  Future<bool> setTransparent(bool transparent) async {
    try {
      final Object? result = await _channel.invokeMethod<Object>(
        'window.setTransparent',
        <String, Object?>{'transparent': transparent},
      );
      // 契约：只有原生明确返回 true 才算成功（非 true 一律 false）。
      return result == true;
    } on MissingPluginException {
      // 原生未注册（未打包 / 测试环境）：降级为 false。
      return false;
    }
  }

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

  /// 打开系统「选择图片」文件对话框（原生 `GetOpenFileNameW` 模态对话框）。
  ///
  /// 返回选中文件绝对路径；用户取消（原生返回 null）或原生未注册
  /// （MissingPluginException，测试环境）返回 null。
  @override
  Future<String?> openImageFile() async {
    try {
      return await _channel.invokeMethod<String>('dialog.openImage');
    } on MissingPluginException {
      return null;
    }
  }

  /// 打开系统「打开白板」文件对话框（原生 `GetOpenFileNameW`，过滤 `.wbd`）。
  ///
  /// 返回选中文件绝对路径；用户取消（原生返回 null）或原生未注册
  /// （MissingPluginException，测试环境）返回 null。
  @override
  Future<String?> openBoardFile() async {
    try {
      return await _channel.invokeMethod<String>('dialog.openBoard');
    } on MissingPluginException {
      return null;
    }
  }

  /// 打开系统「保存白板」对话框（原生 `GetSaveFileNameW`，默认扩展名 `.wbd`）。
  ///
  /// [suggestedPath] 建议全路径（原生预填文件名）；返回目标绝对路径，
  /// 取消（原生返回 null）或原生未注册（MissingPluginException）返回 null。
  @override
  Future<String?> saveBoardFile({String suggestedPath = ''}) async {
    try {
      return await _channel.invokeMethod<String>(
        'dialog.saveBoard',
        <String, Object?>{'suggestedPath': suggestedPath},
      );
    } on MissingPluginException {
      return null;
    }
  }

  /// 原生未注册（未打包 / 测试环境）时静默降级为 no-op（Wave 4 打包接管）。
  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // 降级：忽略。
    }
  }
}
