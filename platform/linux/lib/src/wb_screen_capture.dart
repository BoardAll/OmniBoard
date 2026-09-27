/// 屏幕捕获插件接口与 Linux FFI 实现。
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'wb_ffi_bindings.dart';
import 'wb_native_library.dart';

/// 屏幕捕获帧（BGRA 原始像素，行距 [stride] 字节）。
///
/// 编码（PNG / JPEG）与入库由上层完成；捕获前必须获得用户授权
/// （《安全与合规设计》§7.8：明确授权、不自动截屏、不自动上传）。
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

  /// 从字段映射构造（字段缺失时返回空帧，与平台通道结果兼容）。
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

/// 屏幕捕获（《Flutter + C++ 工程结构设计》§6.1 / §6.2）。
abstract class WbScreenCapturePlugin {
  /// 捕获显示器当前画面。
  ///
  /// [displayId] 为 -1 时捕获主显示器；返回 null 表示不可用或未授权。
  Future<WbCaptureFrame?> captureDisplay({int displayId = -1});

  /// 原生捕获能力是否可用。
  Future<bool> isAvailable();
}

/// Linux 实现：dart:ffi → `libwhiteboard_linux.so`。
///
/// X11 / XWayland 会话使用 `XGetImage` 抓取 root window（覆盖
/// Xinerama 多屏虚拟桌面，含负坐标屏幕），原生缓冲为 BGRA、行距
/// `width * 4`，经 `wb_linux_capture_free` 释放；Wayland 原生会话无
/// 屏幕抓取协议（需 xdg-desktop-portal + PipeWire），返回不支持。
///
/// 原生库缺失（未打包 / 单元测试环境）时 [captureDisplay] 返回 null、
/// [isAvailable] 返回 false，绝不抛异常。
class LinuxScreenCapturePlugin implements WbScreenCapturePlugin {
  /// [library] 供测试注入；缺省自动尝试加载（失败按缺失处理）。
  LinuxScreenCapturePlugin({WbNativeLibrary? library})
      : _bindings =
            _CaptureBindings.tryLoad(library ?? WbNativeLibrary.tryLoad());

  final _CaptureBindings? _bindings;

  @override
  Future<WbCaptureFrame?> captureDisplay({int displayId = -1}) async {
    final _CaptureBindings? bindings = _bindings;
    if (bindings == null) {
      return null;
    }
    final Pointer<Pointer<Uint8>> outBytes = calloc<Pointer<Uint8>>();
    final Pointer<Int32> outLen = calloc<Int32>();
    final Pointer<Int32> outWidth = calloc<Int32>();
    final Pointer<Int32> outHeight = calloc<Int32>();
    final Pointer<Int32> outStride = calloc<Int32>();
    try {
      final int status = bindings.captureDisplay(
        displayId,
        outBytes,
        outLen,
        outWidth,
        outHeight,
        outStride,
      );
      if (status != WbStatus.ok) {
        return null;
      }
      final Pointer<Uint8> bytesPointer = outBytes.value;
      if (bytesPointer == nullptr) {
        return null;
      }
      try {
        final int length = outLen.value;
        if (length <= 0) {
          return null;
        }
        // 必须先拷贝为 Dart 内存，再释放原生缓冲（asTypedList 是视图）。
        return WbCaptureFrame(
          bytes: Uint8List.fromList(bytesPointer.asTypedList(length)),
          width: outWidth.value,
          height: outHeight.value,
          stride: outStride.value,
        );
      } finally {
        bindings.captureFree(bytesPointer);
      }
    } catch (_) {
      // 降级：原生不可用或调用失败时返回 null。
      return null;
    } finally {
      calloc.free(outBytes);
      calloc.free(outLen);
      calloc.free(outWidth);
      calloc.free(outHeight);
      calloc.free(outStride);
    }
  }

  @override
  Future<bool> isAvailable() async {
    final _CaptureBindings? bindings = _bindings;
    if (bindings == null) {
      return false;
    }
    try {
      return bindings.isAvailable() == WbStatus.ok;
    } catch (_) {
      // 降级：忽略原生错误。
      return false;
    }
  }
}

/// 屏幕捕获 C API 的符号表；任一符号缺失则整体不可用（静默降级）。
class _CaptureBindings {
  _CaptureBindings({
    required this.captureDisplay,
    required this.captureFree,
    required this.isAvailable,
  });

  final WbCaptureDisplayDart captureDisplay;
  final WbCaptureFreeDart captureFree;
  final WbInt0Dart isAvailable;

  static _CaptureBindings? tryLoad(WbNativeLibrary? library) {
    final WbCaptureDisplayDart? captureDisplay =
        wbLookupCaptureDisplay(library, 'wb_linux_capture_display');
    final WbCaptureFreeDart? captureFree =
        wbLookupCaptureFree(library, 'wb_linux_capture_free');
    final WbInt0Dart? isAvailable =
        wbLookupInt0(library, 'wb_linux_capture_is_available');
    if (captureDisplay == null || captureFree == null || isAvailable == null) {
      return null;
    }
    return _CaptureBindings(
      captureDisplay: captureDisplay,
      captureFree: captureFree,
      isAvailable: isAvailable,
    );
  }
}
