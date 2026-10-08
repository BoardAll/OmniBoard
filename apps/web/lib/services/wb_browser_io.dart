/// 浏览器 IO（条件导出：Web 实现 / 桩）。
///
/// Web 编译时解析为 `wb_browser_io_web.dart`（localStorage 持久化 +
/// Blob 下载 + 文件选择）；非 Web 编译（VM 测试 / 桌面宿主）解析为
/// `wb_browser_io_stub.dart`（内存 Map + no-op），保证同一套上层代码
/// 跨平台编译与运行（与 `wb_core_engine.dart` 同模式）。
library;

export 'wb_browser_io_stub.dart'
    if (dart.library.js_interop) 'wb_browser_io_web.dart';
export 'wb_canvas_storage.dart';
