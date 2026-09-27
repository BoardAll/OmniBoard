/// 画布元素存储适配器：内存（演示模式）与 FFI（引擎模式）两种实现。
///
/// [WbCanvasController] 始终以 [WbCanvasDocument]（内存）为权威数据源；
/// 存储适配器负责在**事务提交点**把增量同步到后端：
/// - 演示模式（无 DLL）：不注入存储，纯内存；
/// - 引擎模式：注入 [WbFfiCanvasStore]，经 `wbElement*` 接口尽力同步
///   （失败静默，本地状态仍完整）。
///
/// 偏差记录：契约未定义元素样式字段（text/color/points 等）的引擎侧
/// schema，FFI 往返为 best-effort；`replaceAll`（撤销整体替换）在引擎
/// 模式暂为 no-op，待核心引擎命令栈接入后改为 `wb_execute_command` 撤销。
library;

import 'package:whiteboard_core/wb_core.dart';

import '../../services/ffi_service.dart';
import 'canvas_model.dart';

/// 画布元素存储抽象（按页组织）。
abstract interface class WbCanvasStore {
  /// 加载页面元素（失败返回空列表）。
  List<WbCanvasElement> load(String pageId);

  /// 新增或更新元素。
  void upsert(String pageId, WbCanvasElement element);

  /// 删除元素。
  void remove(String pageId, String elementId);

  /// 整体替换页面元素（撤销 / 重做恢复用）。
  void replaceAll(String pageId, List<WbCanvasElement> elements);
}

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
