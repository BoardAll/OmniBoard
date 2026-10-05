/// 页面状态（桌面转发层）。
///
/// [WbPageState] 及引擎桥抽象 [WbPageOps] 的实现已下沉共享包
/// `whiteboard_canvas`（`state/page_state.dart`，与 Web 端同一实现）；
/// 本文件仅为兼容既有导入路径的转发面，并定义桌面端 FFI 适配器
/// [WbFfiPageOps]。
library;

import 'package:whiteboard_canvas/state/page_state.dart';
import 'package:whiteboard_core/wb_core.dart';

import '../services/ffi_service.dart';

export 'package:whiteboard_canvas/state/page_state.dart';

/// 桌面 FFI 适配器：`WbFfiService.page`（core_dart `WbPageService` 代理）
/// → [WbPageOps]。
///
/// 引擎未加载（[isAvailable] false）时 [WbPageState] 不走引擎路径，
/// 本类方法不会被调用；误调时 `ffi.page` getter 抛 [StateError]。
class WbFfiPageOps implements WbPageOps {
  WbFfiPageOps(this.ffi);

  /// FFI 聚合服务。
  final WbFfiService ffi;

  @override
  bool get isAvailable => ffi.isAvailable;

  @override
  WbPage create(String boardId, [Map<String, dynamic> options = const {}]) =>
      ffi.page.create(boardId, options);

  @override
  WbPage rename(String pageId, String name) => ffi.page.rename(pageId, name);

  @override
  void delete(String pageId) {
    ffi.page.delete(pageId);
  }

  @override
  WbPage duplicate(String pageId) => ffi.page.duplicate(pageId);

  @override
  void move(String pageId, int newIndex) {
    ffi.page.move(pageId, newIndex);
  }

  @override
  void lock(String pageId, bool locked) {
    ffi.page.lock(pageId, locked);
  }

  @override
  void hide(String pageId, bool hidden) {
    ffi.page.hide(pageId, hidden);
  }

  @override
  void setBackground(String pageId, Map<String, dynamic> background) {
    ffi.page.setBackground(pageId, background);
  }
}
