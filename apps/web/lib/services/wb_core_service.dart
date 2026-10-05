/// WASM 核心服务：驱动 [WbCoreLoader] 并暴露可监听状态。
///
/// 编辑页在首帧后调用 [initialize]（幂等、不阻塞 UI）：
/// - 加载成功 → [WbCoreStatus.ready]，随后聚合 [WbWebEngine]
///   （创建默认白板并读取首页 id），画布切换为共享交互画布；
/// - 失败 / 资源缺失（`wb_core.js` / `wb_core.wasm` 缺失或加载失败）→
///   [WbCoreStatus.unavailable]，画布降级为内置演示视图
///   （《Web 端方案设计（Flutter Web + WASM）v1.0》§9.4）；
/// - 引擎聚合失败（模块缺失 / 初始化异常）时 [engine] 为 null，
///   画布以内存模式运行（与桌面演示模式一致）。
///
/// 非 Web 环境（`flutter test` / VM）下 [WbCoreLoader] 与 [WbWebEngine]
/// 均为桩实现，同样以 `unavailable` 收尾，测试与桌面宿主可安全编译运行。
library;

import 'package:flutter/foundation.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

import 'wb_core_engine.dart';

/// WASM 核心服务（ChangeNotifier）。
class WbCoreService extends ChangeNotifier {
  /// 创建服务；[loader] 可注入（测试用），缺省自建。
  WbCoreService({WbCoreLoader? loader}) : loader = loader ?? WbCoreLoader();

  /// 底层加载器（Web 实现 / 非 Web 桩由条件导入决定）。
  final WbCoreLoader loader;

  WbWebEngine? _engine;

  /// 当前加载状态。
  WbCoreStatus get status => loader.status;

  /// 核心是否已就绪。
  bool get isAvailable => loader.isAvailable;

  /// 聚合后的引擎（未就绪 / 聚合失败时为 null）。
  WbWebEngine? get engine => _engine;

  /// 当前白板首页 id（引擎不可用时为空串）。
  String get pageId => _engine?.pageId ?? '';

  /// 触发加载（幂等；失败不抛出，状态转为 `unavailable`）。
  ///
  /// [boardName] 为聚合引擎时创建默认白板所用名称（空串回退默认名）。
  Future<void> initialize({String boardName = ''}) async {
    await loader.load();
    if (loader.status == WbCoreStatus.ready) {
      _engine ??= WbWebEngine.createFromLoader(loader, boardName: boardName);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _engine?.destroy();
    loader.dispose();
    super.dispose();
  }
}
