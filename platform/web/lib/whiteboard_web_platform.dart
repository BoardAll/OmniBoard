/// Whiteboard Web 平台插件。
///
/// 提供两类能力（《Flutter + C++ 工程结构设计》§6.4、
/// 《Web 端方案设计（Flutter Web + WASM）v1.0》）：
///
/// 1. **WASM 核心加载与 JS 互操作**（`wb_core_loader.dart` /
///    `wb_core_bindings.dart`）：注入 `wb_core.js`、实例化 `wb_core.wasm`、
///    代理 `ccall` / `cwrap` 调用；
/// 2. **Web 窗口能力**（`web_window.dart`）：全屏映射 Fullscreen API，
///    透明 / 置顶 / 穿透等浏览器不支持能力为 no-op + 能力查询。
///
/// 非 Web 环境（Windows VM / `flutter test` / 桌面宿主）下所有实现自动
/// 切换为桩：加载返回 `unavailable`、窗口调用 no-op，均不抛异常，
/// 保证同一套上层代码跨平台编译与运行。
///
/// `Registrar` 通过条件导入解析：Web 编译时复用 `flutter_web_plugins`
/// 的真实类型（该包依赖 `dart:ui_web`，非 Web 编译不可用），非 Web 编译
/// 使用同形占位类型（`src/registrar_stub.dart`）。
library;

import 'src/registrar_stub.dart'
    if (dart.library.js_interop) 'src/registrar_web.dart';

export 'wb_core_bindings.dart';
export 'wb_core_loader.dart';
export 'web_window.dart';

/// Web 插件入口类（与 pubspec `pluginClass` 一致）。
///
/// Flutter 工具生成的 `web_plugin_registrant.dart` 会调用
/// `WhiteboardWebPlatform.registerWith(registrar)`。
class WhiteboardWebPlatform {
  /// 插件注册（空实现）。
  ///
  /// Web 平台没有 MethodChannel 原生侧：WASM 核心在
  /// `WbCoreLoader.load()` 被调用时按需加载（《Web 端方案设计》§6.1），
  /// 窗口能力由 `WebWindowPlugin` 直接基于浏览器 API 提供，
  /// 因此注册阶段无需做任何事。
  static void registerWith(Registrar registrar) {}
}
