/// 共享画布引擎存储（Web 实现）：经 `wb_element_*` 域服务往返（尽力而为）。
///
/// 与桌面 `WbFfiCanvasStore`（apps/desktop）同构：控制器以内存文档为
/// 权威数据，本存储仅在事务提交点做尽力同步；引擎错误吞掉不打断交互
/// （元素 JSON 契约与 `WbCanvasElement.toJson` / `fromCore` 对齐，
/// 两端共用 whiteboard_canvas 的内存模型）。
library;

import 'package:whiteboard_canvas/canvas/canvas_model.dart';
import 'package:whiteboard_canvas/canvas/canvas_store.dart';
import 'package:whiteboard_core/wb_core_common.dart';

/// 引擎模式存储：经 [WbElementService] 的 element 域往返（尽力而为）。
class WbWasmCanvasStore implements WbCanvasStore {
  const WbWasmCanvasStore(this.element);

  /// 元素域服务（来自 [WbWebEngine.element]，WASM 引擎就绪时可用）。
  final WbElementService element;

  @override
  List<WbCanvasElement> load(String pageId) {
    if (pageId.isEmpty) {
      return const <WbCanvasElement>[];
    }
    try {
      return element
          .list(pageId)
          .map(WbCanvasElement.fromCore)
          .toList(growable: false);
    } catch (_) {
      // 引擎错误 / 演示模式：返回空（内存内容保持）。
      return const <WbCanvasElement>[];
    }
  }

  @override
  void upsert(String pageId, WbCanvasElement value) {
    if (pageId.isEmpty) {
      return;
    }
    try {
      // 引擎侧无 upsert：先按 id 探测存在性（update 失败则 create）。
      try {
        element.update(value.id, value.toJson());
      } on WbCoreException {
        element.create(pageId, value.toJson());
      }
    } catch (_) {
      // 尽力而为：本地状态仍完整。
    }
  }

  @override
  void remove(String pageId, String elementId) {
    if (pageId.isEmpty || elementId.isEmpty) {
      return;
    }
    try {
      element.delete(elementId);
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
