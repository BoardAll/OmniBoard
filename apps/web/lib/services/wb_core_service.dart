/// WASM 核心服务：驱动 [WbCoreLoader] 并暴露可监听状态。
///
/// 编辑页在首帧后调用 [initialize]（幂等、不阻塞 UI）：
/// - 加载成功 → [WbCoreStatus.ready]，后续可经 [loader] 代理调用 C++ 导出；
/// - 失败 / 资源缺失（Wave 4 前 `wb_core.js` 为占位脚本）→
///   [WbCoreStatus.unavailable]，画布降级为内置演示视图
///   （《Web 端方案设计（Flutter Web + WASM）v1.0》§9.4）。
///
/// 非 Web 环境（`flutter test` / VM）下 [WbCoreLoader] 为桩实现，
/// 同样以 `unavailable` 收尾，测试与桌面宿主可安全编译运行。
library;

import 'package:flutter/foundation.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

/// WASM 核心服务（ChangeNotifier）。
class WbCoreService extends ChangeNotifier {
  /// 创建服务；[loader] 可注入（测试用），缺省自建。
  WbCoreService({WbCoreLoader? loader}) : loader = loader ?? WbCoreLoader();

  /// 底层加载器（Web 实现 / 非 Web 桩由条件导入决定）。
  final WbCoreLoader loader;

  /// 当前加载状态。
  WbCoreStatus get status => loader.status;

  /// 核心是否已就绪。
  bool get isAvailable => loader.isAvailable;

  /// 触发加载（幂等；失败不抛出，状态转为 `unavailable`）。
  Future<void> initialize() async {
    await loader.load();
    notifyListeners();
  }

  @override
  void dispose() {
    loader.dispose();
    super.dispose();
  }
}
