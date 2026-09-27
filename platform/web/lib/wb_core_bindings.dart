/// Emscripten Module 绑定入口（条件导入）。
///
/// - Web 目标：`src/wb_core_bindings_web.dart`（`dart:js_interop` 绑定，
///   含 `ccall` / `cwrap` / `UTF8ToString` / `malloc`(`_malloc`) /
///   `free`(`_free`) / `heapU8` / `readBytes`）；
/// - 其他目标：`src/wb_core_bindings_stub.dart`（同名占位类型）。
library;

export 'src/wb_core_bindings_stub.dart'
    if (dart.library.js_interop) 'src/wb_core_bindings_web.dart';
