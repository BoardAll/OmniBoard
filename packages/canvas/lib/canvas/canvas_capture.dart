/// 画布像素捕获：把画布绘制层（`RepaintBoundary`）栅格化为快照，
/// 供全屏取色在无法做屏幕级采样（非 Windows / 系统调用不可用 / 测试）
/// 时降级为"仅画布内取色"。
///
/// 接线：
/// 1. `canvas_view.dart` 把 [WbCanvasCapture.boundaryKey] 挂到画布的
///    `RepaintBoundary` 上；
/// 2. 取色层调用 [WbCanvasCapture.capture] 取得 [WbCanvasSnapshot]；
/// 3. 经 [WbCanvasSnapshot.colorAt] / [WbCanvasSnapshot.patch] 按全局
///    坐标（与 `PointerEvent.position` 同坐标系）读取像素。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 画布捕获入口。
class WbCanvasCapture {
  WbCanvasCapture._();

  /// 画布绘制层的全局键（由 `CanvasView` 挂到 `RepaintBoundary` 上）。
  static final GlobalKey boundaryKey =
      GlobalKey(debugLabel: 'wb-canvas-capture');

  /// 捕获当前画布像素快照。
  ///
  /// 边界未挂载 / 未布局 / 光栅化失败（后台无光栅器等）时返回 null，
  /// 调用方按"无快照"降级。
  static Future<WbCanvasSnapshot?> capture() async {
    final BuildContext? boundaryContext = boundaryKey.currentContext;
    if (boundaryContext == null) {
      return null;
    }
    final RenderObject? object = boundaryContext.findRenderObject();
    if (object is! RenderRepaintBoundary ||
        !object.attached ||
        !object.hasSize ||
        object.size.isEmpty) {
      return null;
    }
    final double pixelRatio = View.of(boundaryContext).devicePixelRatio;
    try {
      final ui.Image image = await object.toImage(pixelRatio: pixelRatio);
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final int width = image.width;
      final int height = image.height;
      final Offset origin = object.localToGlobal(Offset.zero);
      image.dispose();
      if (data == null) {
        return null;
      }
      return WbCanvasSnapshot._(
        rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        width: width,
        height: height,
        origin: origin,
        pixelRatio: pixelRatio,
      );
    } catch (_) {
      // 光栅化异常（图层未合成 / 测试环境限制）：降级为无快照。
      return null;
    }
  }
}

/// 画布像素快照（不透明 RGBA8888，行主序）。
class WbCanvasSnapshot {
  WbCanvasSnapshot._({
    required Uint8List rgba,
    required this.width,
    required this.height,
    required Offset origin,
    required double pixelRatio,
  })  : _rgba = rgba,
        _capturedOrigin = origin,
        _pixelRatio = pixelRatio;

  final Uint8List _rgba;

  /// 快照像素宽。
  final int width;

  /// 快照像素高。
  final int height;

  /// 捕获时画布左上角的全局位置（逻辑像素）。
  final Offset _capturedOrigin;

  /// 捕获使用的像素比（逻辑像素 → 快照像素）。
  final double _pixelRatio;

  /// 画布左上角当前全局位置；布局未变时与捕获时一致。
  ///
  /// 优先实时读取边界位置（窗口移动等场景更准确），边界已卸载时
  /// 回退为捕获时的位置。
  Offset get origin {
    final RenderObject? object =
        WbCanvasCapture.boundaryKey.currentContext?.findRenderObject();
    if (object is RenderBox && object.attached) {
      return object.localToGlobal(Offset.zero);
    }
    return _capturedOrigin;
  }

  /// 读取全局坐标 [global] 处的像素色；越界返回 null。
  Color? colorAt(Offset global) {
    final Offset local = (global - origin) * _pixelRatio;
    final int x = local.dx.floor();
    final int y = local.dy.floor();
    if (x < 0 || y < 0 || x >= width || y >= height) {
      return null;
    }
    return _colorAt(x, y);
  }

  /// 以全局坐标 [global] 为中心取 (2*[radius]+1)² 像素块。
  ///
  /// 行主序：中心像素索引为 `radius * (2*radius+1) + radius`；块内
  /// 越界像素夹取到最近有效像素；中心本身越界时返回 null。
  List<Color>? patch(Offset global, {required int radius}) {
    if (radius < 0) {
      return null;
    }
    final Offset local = (global - origin) * _pixelRatio;
    final int centerX = local.dx.floor();
    final int centerY = local.dy.floor();
    if (centerX < 0 || centerY < 0 || centerX >= width || centerY >= height) {
      return null;
    }
    final int side = radius * 2 + 1;
    final List<Color> cells = List<Color>.generate(
      side * side,
      (int index) {
        final int row = index ~/ side;
        final int col = index % side;
        final int x = (centerX + col - radius).clamp(0, width - 1);
        final int y = (centerY + row - radius).clamp(0, height - 1);
        return _colorAt(x, y);
      },
      growable: false,
    );
    return cells;
  }

  Color _colorAt(int x, int y) {
    final int offset = (y * width + x) * 4;
    return Color.fromARGB(
      _rgba[offset + 3],
      _rgba[offset],
      _rgba[offset + 1],
      _rgba[offset + 2],
    );
  }
}
