/// 画布引擎桥桌面实现：包装 [WbFfiService]（FFI）。
library;

import 'dart:typed_data';

import 'package:whiteboard_canvas/services/canvas_engine.dart';
import 'package:whiteboard_core/wb_core.dart';

import 'ffi_service.dart';

/// 画布引擎桥桌面实现（元素列表 / 行操作 / 缩略图）。
///
/// 引擎未加载（[isAvailable] false）时上层不走引擎路径；本类方法
/// 误调时 `ffi.element` / `ffi.render` getter 抛 [StateError]。
class WbFfiCanvasEngine implements WbCanvasEngine {
  const WbFfiCanvasEngine(this.ffi);

  /// FFI 聚合服务。
  final WbFfiService ffi;

  @override
  bool get isAvailable => ffi.isAvailable;

  @override
  List<WbElement> listElements(String pageId) => ffi.element.list(pageId);

  @override
  void updateElement(String elementId, Map<String, dynamic> patch) {
    ffi.element.update(elementId, patch);
  }

  @override
  void deleteElement(String elementId) {
    ffi.element.delete(elementId);
  }

  @override
  Uint8List? thumbnail(String pageId, int width, int height) =>
      wbDecodeThumbnail(ffi.render.thumbnail(pageId, width, height));
}
