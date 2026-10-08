/// Web 端引擎桥适配器：把 WASM 域服务接入共享画布的两条引擎接口。
///
/// 与桌面 `WbFfiPageOps` / `WbFfiCanvasEngine`（包装 `WbFfiService`）同构，
/// 供 [WbPageState]（页面增删改排序 / 背景 / 锁定隐藏）与共享组件
/// （PageThumbnail / LayersPanel）消费：
/// - [WbWasmPageOps]：包装 `WbPageService`，实现 `WbPageOps`；
/// - [WbWasmCanvasEngine]：包装 `WbElementService` + `WbRenderService`，
///   实现 `WbCanvasEngine`。
///
/// 引擎聚合（`WbWebEngine`）在首帧后异步就绪，宿主先创建适配器实例
/// 并注入 Provider 树，就绪后调用 [WbWasmPageOps.attach] /
/// [WbWasmCanvasEngine.attach] 绑定域服务——[isAvailable] 随之为 true；
/// 未绑定（WASM 加载失败 / 演示模式）时上层降级（内存页面 / 静态缩略图）。
library;

import 'dart:typed_data';

import 'package:whiteboard_canvas/services/canvas_engine.dart';
import 'package:whiteboard_canvas/state/page_state.dart';
import 'package:whiteboard_core/wb_core_common.dart';

/// 页面桥 Web 实现（延迟注入）。
class WbWasmPageOps implements WbPageOps {
  WbPageService? _page;

  /// 绑定引擎页服务（引擎聚合就绪后调用；幂等）。
  void attach(WbPageService page) => _page = page;

  /// 解绑（引擎销毁 / 页面离场；此后 [isAvailable] 为 false）。
  void detach() => _page = null;

  /// 引擎页服务（未注入或已解绑时抛 [StateError]）。
  WbPageService get _engine =>
      _page ?? (throw StateError('引擎页服务未就绪（WASM 未加载）'));

  @override
  bool get isAvailable => _page != null;

  @override
  WbPage create(String boardId, [Map<String, dynamic> options = const {}]) =>
      _engine.create(boardId, options);

  @override
  WbPage rename(String pageId, String name) => _engine.rename(pageId, name);

  @override
  void delete(String pageId) {
    _engine.delete(pageId);
  }

  @override
  WbPage duplicate(String pageId) => _engine.duplicate(pageId);

  @override
  void move(String pageId, int newIndex) {
    _engine.move(pageId, newIndex);
  }

  @override
  void lock(String pageId, bool locked) {
    _engine.lock(pageId, locked);
  }

  @override
  void hide(String pageId, bool hidden) {
    _engine.hide(pageId, hidden);
  }

  @override
  void setBackground(String pageId, Map<String, dynamic> background) {
    _engine.setBackground(pageId, background);
  }
}

/// 画布引擎桥 Web 实现（延迟注入；元素列表 / 行操作 / 缩略图）。
class WbWasmCanvasEngine implements WbCanvasEngine {
  WbElementService? _element;
  WbRenderService? _render;

  /// 绑定引擎域服务（引擎聚合就绪后调用；幂等）。
  void attach({
    required WbElementService element,
    required WbRenderService render,
  }) {
    _element = element;
    _render = render;
  }

  /// 解绑（引擎销毁 / 页面离场；此后 [isAvailable] 为 false）。
  void detach() {
    _element = null;
    _render = null;
  }

  /// 引擎元素服务（未注入或已解绑时抛 [StateError]）。
  WbElementService get _elementService =>
      _element ?? (throw StateError('引擎元素服务未就绪（WASM 未加载）'));

  /// 引擎渲染服务（未注入或已解绑时抛 [StateError]）。
  WbRenderService get _renderService =>
      _render ?? (throw StateError('引擎渲染服务未就绪（WASM 未加载）'));

  @override
  bool get isAvailable => _element != null;

  @override
  List<WbElement> listElements(String pageId) => _elementService.list(pageId);

  @override
  void updateElement(String elementId, Map<String, dynamic> patch) {
    _elementService.update(elementId, patch);
  }

  @override
  void deleteElement(String elementId) {
    _elementService.delete(elementId);
  }

  @override
  Uint8List? thumbnail(String pageId, int width, int height) =>
      wbDecodeThumbnail(_renderService.thumbnail(pageId, width, height));
}
