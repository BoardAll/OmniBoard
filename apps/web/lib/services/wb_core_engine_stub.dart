/// Web 引擎聚合（非 Web 桩）。
///
/// VM（`flutter test` / 桌面宿主）没有 WASM 模块：本桩保证上层
/// （`WbCoreService` / 编辑页）跨平台可编译 —— [createFromLoader]
/// 恒返回 null，调用方按"无引擎"降级为内存画布。
///
/// 公共 API 与 Web 版（`wb_core_engine_web.dart`）保持同名同签名；
/// 实例成员在桩下不可达（恒无实例），访问即抛 [UnsupportedError]。
library;

import 'package:whiteboard_core/wb_core_common.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

/// Web 引擎聚合（桩：恒不可用，无可用实例）。
class WbWebEngine {
  /// 引擎实例（桩：不可用）。
  WbEngineCaller get core => throw UnsupportedError('WbWebEngine: 非 Web 环境不可用');

  /// 白板域服务（桩：不可用）。
  WbBoardService get board =>
      throw UnsupportedError('WbWebEngine: 非 Web 环境不可用');

  /// 元素域服务（桩：不可用）。
  WbElementService get element =>
      throw UnsupportedError('WbWebEngine: 非 Web 环境不可用');

  /// 页面域服务（桩：不可用）。
  WbPageService get page => throw UnsupportedError('WbWebEngine: 非 Web 环境不可用');

  /// 渲染域服务（桩：不可用）。
  WbRenderService get render =>
      throw UnsupportedError('WbWebEngine: 非 Web 环境不可用');

  /// 工具域服务（桩：不可用；Web 版经此访问 `crdt.*` 点分路由）。
  WbToolService get tools =>
      throw UnsupportedError('WbWebEngine: 非 Web 环境不可用');

  /// 引擎侧白板句柄（桩：恒 0）。
  int get boardHandle => 0;

  /// 默认（首页）页面 id（桩：恒空串）。
  String get pageId => '';

  /// 白板快照（桩：不可用）。
  WbBoard get snapshot => throw UnsupportedError('WbWebEngine: 非 Web 环境不可用');

  /// 从加载器聚合引擎（桩：恒返回 null）。
  static WbWebEngine? createFromLoader(
    WbCoreLoader loader, {
    String boardName = '',
  }) =>
      null;

  /// 销毁引擎侧白板（桩：no-op）。
  void destroy() {}
}
