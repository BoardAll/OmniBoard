/// Web 引擎聚合（Web 实现）。
///
/// [WbCoreLoader] 完成脚本注入与模块实例化后，本聚合把平台中立的
/// 域服务（[WbBoardService] / [WbElementService] / [WbPageService] /
/// [WbRenderService] / [WbToolService]）接到同一引擎实例（[WbCoreWasm]）上：
/// 初始化引擎、创建默认白板、读取首页 id 与白板快照（供页面状态
/// `attach`）。
///
/// 说明（P4 协作）：WASM 导出表从 `wb.h` 的 `WB_API` 声明派生，而 `wb.h`
/// 未声明 `wb_crdt_*` 系列——[WbCrdtService] 的直调符号在 Web 不可用；
/// crdt 域统一经 [tools]（`wb_execute_tool` → tool 域点分路由到 `crdt` 域）
/// 访问。
///
/// 任一步失败（模块缺失 / `wb_init` / `wb_create_board` / `wb_board_get`
/// 异常或空句柄）返回 null，调用方降级为内存画布（与桌面演示模式一致，
/// 不阻塞 UI）。
library;

import 'package:whiteboard_core/wb_core_common.dart';
import 'package:whiteboard_core/wb_core_wasm.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

/// Web 引擎聚合：引擎实例 + 白板句柄 + 首页 id + 域服务。
class WbWebEngine {
  WbWebEngine._(
    this.core, {
    required this.boardHandle,
    required this.pageId,
    required this.snapshot,
  })  : board = WbBoardService(core),
        element = WbElementService(core),
        page = WbPageService(core),
        render = WbRenderService(core),
        tools = WbToolService(core);

  /// 引擎实例（实现共享契约 [WbEngineCaller]，域服务两端共用）。
  final WbCoreWasm core;

  /// 白板域服务（生命周期 / 命令 / 工具）。
  final WbBoardService board;

  /// 元素域服务（画布存储 `WbWasmCanvasStore` / 引擎桥使用）。
  final WbElementService element;

  /// 页面域服务（列表 / 增删改 / 排序 / 背景 / 锁定隐藏）。
  final WbPageService page;

  /// 渲染域服务（缩略图等）。
  final WbRenderService render;

  /// 工具域服务（`wb_execute_tool` 点分路由；P4 协作经此访问 `crdt.*`）。
  final WbToolService tools;

  /// 引擎侧白板句柄（uint64）。
  final int boardHandle;

  /// 默认（首页）页面 id（空串 = 白板无页面）。
  final String pageId;

  /// 白板快照（含页面列表；供 `WbPageState.attach`）。
  final WbBoard snapshot;

  /// 从已就绪的加载器聚合引擎；失败返回 null（调用方降级）。
  ///
  /// [boardName] 为创建默认白板所用名称（空串回退引擎默认名）。
  static WbWebEngine? createFromLoader(
    WbCoreLoader loader, {
    String boardName = '',
  }) {
    // 条件导入下 `loader.module` 的静态类型随解析目标变化（Web / 桩
    // 占位类型），此处以 [Object] 接收，由 fromModule 运行时校验。
    final Object? module = loader.module;
    if (module == null) {
      return null;
    }
    try {
      // 复用加载器已实例化的模块（不重复调用全局工厂）。
      final WbCoreWasm core = WbCoreWasm.fromModule(module);
      core.init('{}');
      final WbBoardService board = WbBoardService(core);
      final int handle = board.create(
        name: boardName.isEmpty ? '未命名白板' : boardName,
      );
      if (handle == 0) {
        return null;
      }
      final WbBoard snapshot = board.get(handle);
      final String pageId =
          snapshot.pages.isEmpty ? '' : snapshot.pages.first.id;
      return WbWebEngine._(
        core,
        boardHandle: handle,
        pageId: pageId,
        snapshot: snapshot,
      );
    } catch (_) {
      // 引擎错误：不抛异常，返回 null 由调用方降级。
      return null;
    }
  }

  /// 销毁引擎侧白板（幂等；此后句柄失效）。
  void destroy() {
    try {
      board.destroy(boardHandle);
    } catch (_) {
      // 尽力而为。
    }
  }
}
