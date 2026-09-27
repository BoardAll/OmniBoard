/// 画布图片解码缓存：文件路径 → `ui.Image`（异步解码、并发去重、失败静默）。
///
/// - 画布绘制（`WbCanvasPainter` 图片元素 / 背景图片）同步读 [imageFor]，
///   未命中时经 [request] 触发后台加载，解码完成 [notifyListeners] 触发重绘；
/// - 图片工具创建流程经 [load] 等待解码，用自然尺寸计算落画布尺寸；
/// - 解码器可注入（[WbCanvasImageCache.new] 的 `decoder`），测试用假图即可
///   完全绕开文件系统。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 图片解码缓存（`ChangeNotifier`）。
class WbCanvasImageCache extends ChangeNotifier {
  /// 创建缓存；[decoder] 为 null 时使用 `dart:io` 读取 + `instantiateImageCodec`。
  WbCanvasImageCache({Future<ui.Image> Function(String path)? decoder})
      : _decoder = decoder;

  /// 缓存上限（超出后整体清空，简单可靠）。
  static const int maxEntries = 48;

  final Future<ui.Image> Function(String path)? _decoder;
  final Map<String, ui.Image> _images = <String, ui.Image>{};
  final Map<String, Future<ui.Image?>> _inFlight = <String, Future<ui.Image?>>{};
  final Set<String> _failed = <String>{};
  bool _disposed = false;

  /// 已解码图片（未命中 / 加载中 / 失败返回 null，不触发加载）。
  ui.Image? imageFor(String path) => _images[path];

  /// 是否解码失败过（避免重复自动请求；显式 [load] 会重试）。
  bool hasFailed(String path) => _failed.contains(path);

  /// 请求后台加载（不等待；命中缓存 / 加载中 / 已失败时直接返回）。
  void request(String path) {
    if (path.isEmpty ||
        _images.containsKey(path) ||
        _inFlight.containsKey(path) ||
        _failed.contains(path)) {
      return;
    }
    unawaited(load(path));
  }

  /// 加载并缓存（等待解码完成；失败返回 null 并记录，供诊断）。
  Future<ui.Image?> load(String path) {
    if (path.isEmpty) {
      return Future<ui.Image?>.value();
    }
    final ui.Image? cached = _images[path];
    if (cached != null) {
      return Future<ui.Image?>.value(cached);
    }
    final Future<ui.Image?>? pending = _inFlight[path];
    if (pending != null) {
      return pending;
    }
    _failed.remove(path); // 显式加载允许重试。
    final Future<ui.Image?> future = _decodeAndCache(path);
    _inFlight[path] = future;
    return future;
  }

  Future<ui.Image?> _decodeAndCache(String path) async {
    try {
      final Future<ui.Image> Function(String path) decode =
          _decoder ?? _defaultDecode;
      final ui.Image image = await decode(path);
      if (_disposed) {
        image.dispose();
        return null;
      }
      if (_images.length >= maxEntries) {
        for (final ui.Image cached in _images.values) {
          cached.dispose();
        }
        _images.clear();
      }
      _images[path] = image;
      _failed.remove(path);
      notifyListeners();
      return image;
    } catch (_) {
      _failed.add(path);
      return null;
    } finally {
      unawaited(_inFlight.remove(path));
    }
  }

  /// 默认解码器：读取文件字节并以 Flutter 图像编解码器解码首帧。
  static Future<ui.Image> _defaultDecode(String path) async {
    final Uint8List bytes = await File(path).readAsBytes();
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    return frame.image;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final ui.Image image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _inFlight.clear();
    super.dispose();
  }
}
