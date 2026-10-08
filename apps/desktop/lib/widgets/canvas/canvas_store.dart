/// 共享画布转发 + 桌面引擎存储实现。
///
/// [WbCanvasStore] 抽象接口与其实现契约位于 `whiteboard_canvas` 包
/// （桌面 / Web 共用）；本文件额外保留桌面专属的 [WbFfiCanvasStore]
/// （依赖 [WbFfiService]，无法进入平台中立共享包）。
library;

import 'package:whiteboard_canvas/canvas/canvas_model.dart';
import 'package:whiteboard_canvas/canvas/canvas_store.dart';
import 'package:whiteboard_core/wb_core.dart';

import '../../services/ffi_service.dart';

export 'package:whiteboard_canvas/canvas/canvas_store.dart';

/// 引擎模式存储：经 [WbFfiService] 的 element 域往返（尽力而为）。
class WbFfiCanvasStore implements WbCanvasStore {
  const WbFfiCanvasStore(this.ffi);

  /// FFI 聚合服务。
  final WbFfiService ffi;

  bool get _usable => ffi.isAvailable;

  @override
  List<WbCanvasElement> load(String pageId) {
    if (!_usable || pageId.isEmpty) {
      return const <WbCanvasElement>[];
    }
    try {
      return ffi.element
          .list(pageId)
          .map(WbCanvasElement.fromCore)
          .toList(growable: false);
    } catch (_) {
      // 引擎错误 / 演示模式：返回空（内存内容保持）。
      return const <WbCanvasElement>[];
    }
  }

  @override
  void upsert(String pageId, WbCanvasElement element) {
    if (!_usable || pageId.isEmpty) {
      return;
    }
    try {
      // 引擎侧无 upsert：先按 id 探测存在性（update 失败则 create）。
      try {
        ffi.element.update(element.id, element.toJson());
      } on WbCoreException {
        ffi.element.create(pageId, element.toJson());
      }
    } catch (_) {
      // 尽力而为：本地状态仍完整。
    }
  }

  @override
  void remove(String pageId, String elementId) {
    if (!_usable || pageId.isEmpty || elementId.isEmpty) {
      return;
    }
    try {
      ffi.element.delete(elementId);
    } catch (_) {
      // 尽力而为。
    }
  }

  @override
  void replaceAll(String pageId, List<WbCanvasElement> elements) {
    // 引擎模式下整体替换不逐元素重放（避免破坏引擎 id 与命令栈）；
    // 待核心引擎提供事务性批量替换 / 撤销命令后接入。
  }
}
