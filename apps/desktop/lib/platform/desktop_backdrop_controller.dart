/// 桌面截图兜底背景控制器（《透明批注模式技术方案》§3 降级路径）。
///
/// 原生真透明（`SetWindowCompositionAttribute`）不可用（旧系统 / 调用
/// 失败）时，「显示桌面」退化为截图背景方案：把整虚拟屏截图渲染为批注
/// 页垫底图层，使批注内容仍能对齐真实桌面（防黑屏兜底）。
///
/// 生命周期由页面在批注控制器变化时经 [sync] 驱动：
/// - 批注激活且原生透明未生效：激活 + 立即抓取一帧；
/// - 穿透态（鼠标模式）：每 [refreshInterval] 定时刷新，近似跟踪桌面变化；
/// - 批注态：暂停刷新（避免画面闪现干扰绘制），保留最近一帧；
/// - 退出批注 / 透明已生效 / 页面销毁：[deactivate] 释放截图资源。
///
/// 平台不可用（未打包 / 测试环境）时全部静默降级，不抛出。
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:whiteboard_windows/whiteboard_windows.dart';

/// 截图帧 → 显示用图片解码器（默认 BGRA 解码；测试可注入假图）。
typedef WbBackdropDecoder = Future<ui.Image> Function(WbCaptureFrame frame);

/// 兜底背景状态与截图刷新编排（[ChangeNotifier]）。
class WbDesktopBackdropController extends ChangeNotifier {
  WbDesktopBackdropController({
    WbScreenCapturePlugin? capture,
    WbBackdropDecoder? decoder,
    this.refreshInterval = const Duration(milliseconds: 800),
  })  : _capture = capture ?? WindowsScreenCapturePlugin(),
        _decoder = decoder ?? _decodeBgraFrame;

  /// 穿透态下的截图刷新间隔（问题 5：鼠标模式每 800ms 刷新）。
  final Duration refreshInterval;

  final WbScreenCapturePlugin _capture;
  final WbBackdropDecoder _decoder;

  ui.Image? _image;
  Timer? _timer;
  bool _active = false;
  bool _capturing = false;
  bool _disposed = false;

  /// 是否处于兜底背景模式（批注激活且原生透明未生效）。
  bool get isActive => _active;

  /// 最近一帧桌面截图（尚未抓到 / 已释放时为 null）。
  ui.Image? get image => _image;

  /// 是否正在抓取 / 解码（并发保护标志，测试可读）。
  bool get isCapturing => _capturing;

  /// 与批注状态同步（由页面在批注控制器变化时调用；幂等）。
  ///
  /// [annotationActive] 批注模式是否激活；[transparentApplied] 原生真
  /// 透明是否已生效（true 时无需兜底）；[penetrating] 是否鼠标穿透态
  /// （穿透态下持续刷新截图）。
  void sync({
    required bool annotationActive,
    required bool transparentApplied,
    required bool penetrating,
  }) {
    if (_disposed) {
      return;
    }
    if (!annotationActive || transparentApplied) {
      deactivate();
      return;
    }
    if (!_active) {
      _active = true;
      notifyListeners();
      unawaited(refresh());
    }
    if (penetrating) {
      _timer ??= Timer.periodic(refreshInterval, (Timer _) {
        unawaited(refresh());
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// 抓取一帧虚拟屏截图并替换背景（并发安全的静默降级实现）。
  ///
  /// 原生返回 null（不可用）/ 解码失败时保留上一帧，不抛出。
  Future<void> refresh() async {
    if (_disposed || !_active || _capturing) {
      return;
    }
    _capturing = true;
    try {
      final WbCaptureFrame? frame = await _capture.captureVirtualScreen();
      if (frame == null || frame.width <= 0 || frame.height <= 0) {
        return;
      }
      final ui.Image decoded = await _decoder(frame);
      if (_disposed || !_active) {
        // 抓取期间已退出兜底模式：丢弃迟到帧。
        decoded.dispose();
        return;
      }
      final ui.Image? previous = _image;
      _image = decoded;
      previous?.dispose();
      notifyListeners();
    } catch (_) {
      // 静默降级：截图 / 解码失败保留上一帧。
    } finally {
      _capturing = false;
    }
  }

  /// 退出兜底模式：取消定时刷新并释放截图资源（幂等）。
  void deactivate() {
    _timer?.cancel();
    _timer = null;
    final ui.Image? image = _image;
    _image = null;
    image?.dispose();
    if (_active) {
      _active = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}

/// 默认解码：BGRA 原始像素 → [ui.Image]。
///
/// `decodeImageFromPixels` 要求紧凑像素；行距 [WbCaptureFrame.stride]
/// 与 `width * 4` 不一致时先去填充逐行拷贝。
Future<ui.Image> _decodeBgraFrame(WbCaptureFrame frame) {
  final int rowBytes = frame.width * 4;
  Uint8List pixels = frame.bytes;
  if (frame.stride != rowBytes && frame.stride >= rowBytes) {
    final Uint8List packed = Uint8List(rowBytes * frame.height);
    for (int y = 0; y < frame.height; y++) {
      packed.setRange(
        y * rowBytes,
        (y + 1) * rowBytes,
        frame.bytes,
        y * frame.stride,
      );
    }
    pixels = packed;
  }
  final Completer<ui.Image> completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    frame.width,
    frame.height,
    ui.PixelFormat.bgra8888,
    completer.complete,
  );
  return completer.future;
}
