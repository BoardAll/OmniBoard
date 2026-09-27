/// 屏幕捕获插件接口与 macOS 方法通道实现。
library;

import 'package:flutter/services.dart';

import 'wb_window_plugin.dart';

/// 屏幕捕获帧（BGRA 原始像素，行距 [stride] 字节）。
///
/// 编码（PNG / JPEG）与入库由上层完成；捕获前必须获得用户授权
/// （《安全与合规设计》：屏幕内容涉及隐私，macOS 需“屏幕录制”权限）。
class WbCaptureFrame {
  const WbCaptureFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.stride,
  });

  /// BGRA 像素数据（长度 >= stride * height）。
  final Uint8List bytes;

  /// 像素宽。
  final int width;

  /// 像素高。
  final int height;

  /// 每行字节数。
  final int stride;

  /// 从平台通道结果构造（字段缺失时返回空帧）。
  factory WbCaptureFrame.fromMap(Map<Object?, Object?> map) {
    final Object? bytes = map['bytes'];
    final Object? width = map['width'];
    final Object? height = map['height'];
    final Object? stride = map['stride'];
    return WbCaptureFrame(
      bytes: bytes is Uint8List ? bytes : Uint8List(0),
      width: width is int ? width : 0,
      height: height is int ? height : 0,
      stride: stride is int ? stride : 0,
    );
  }
}

/// 屏幕捕获（《Flutter + C++ 工程结构设计》§6.2）。
abstract class WbScreenCapturePlugin {
  /// 捕获显示器当前画面。
  ///
  /// [displayId] 为 -1 时捕获主显示器；返回 null 表示不可用或未授权。
  Future<WbCaptureFrame?> captureDisplay({int displayId = -1});

  /// 原生捕获能力是否可用。
  Future<bool> isAvailable();
}

/// macOS 实现：与窗口插件共用通道 `whiteboard/macos`。
///
/// 原生侧使用 `CGGetActiveDisplayList` + `CGDisplayCreateImage`
/// （Quartz），输出 BGRA 缓冲；`CGDisplayCreateImage` 在 macOS 10.15+
/// 需要“屏幕录制”权限（《安全与合规设计》§7.8：不自动截屏、明确授权）。
class MacosScreenCapturePlugin implements WbScreenCapturePlugin {
  MacosScreenCapturePlugin({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(MacosWindowPlugin.channelName);

  final MethodChannel _channel;

  @override
  Future<WbCaptureFrame?> captureDisplay({int displayId = -1}) async {
    try {
      final Object? result = await _channel.invokeMethod<Object>(
        'capture.captureDisplay',
        <String, Object?>{'displayId': displayId},
      );
      if (result is Map) {
        return WbCaptureFrame.fromMap(result);
      }
      return null;
    } on MissingPluginException {
      // 降级：原生未注册时返回 null。
      return null;
    }
  }

  @override
  Future<bool> isAvailable() async {
    try {
      final Object? result =
          await _channel.invokeMethod<Object>('capture.isAvailable');
      return result == true;
    } on MissingPluginException {
      return false;
    }
  }
}
