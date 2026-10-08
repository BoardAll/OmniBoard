/// 画布元素存储适配器（抽象接口）。
///
/// [WbCanvasController] 始终以 [WbCanvasDocument]（内存）为权威数据源；
/// 存储适配器负责在**事务提交点**把增量同步到后端：
/// - 演示模式 / 纯 Web 内存：不注入存储，纯内存；
/// - 引擎模式：宿主注入具体实现（桌面端为 `WbFfiCanvasStore`，经
///   `wbElement*` 接口尽力同步；失败静默，本地状态仍完整）。
///
/// 偏差记录：契约未定义元素样式字段（text/color/points 等）的引擎侧
/// schema，FFI 往返为 best-effort；`replaceAll`（撤销整体替换）在引擎
/// 模式暂为 no-op，待核心引擎命令栈接入后改为 `wb_execute_command` 撤销。
library;

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
