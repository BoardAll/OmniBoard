/// WASM 核心加载器入口（条件导入）。
///
/// - Web 目标（`dart.library.js_interop`）：`src/wb_core_loader_web.dart`，
///   基于 `dart:js_interop` + `package:web` 注入 `wb_core.js` 并实例化 WASM；
/// - 其他目标（VM / 桌面 / 测试）：`src/wb_core_loader_stub.dart`，
///   `load()` 恒返回 [WbCoreStatus.unavailable]，保证跨平台可编译。
///
/// 使用示例：
/// ```dart
/// final WbCoreLoader loader = WbCoreLoader();
/// final WbCoreStatus status = await loader.load();
/// if (status.isAvailable) {
///   final Object? version = await loader.call('wb_version');
/// }
/// ```
library;

export 'src/wb_core_loader_stub.dart'
    if (dart.library.js_interop) 'src/wb_core_loader_web.dart';
export 'src/wb_core_types.dart';
