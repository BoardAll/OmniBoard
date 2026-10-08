/// Web 引擎聚合入口（条件导入）。
///
/// - Web 目标（`dart.library.js_interop`）：`wb_core_engine_web.dart`，
///   把 [WbCoreLoader] 已实例化的模块聚合为引擎 + 白板句柄 + 域服务；
/// - 其他目标（VM / 桌面 / `flutter test`）：`wb_core_engine_stub.dart`，
///   `createFromLoader` 恒返回 null，保证跨平台可编译。
library;

export 'wb_core_engine_stub.dart'
    if (dart.library.js_interop) 'wb_core_engine_web.dart';
