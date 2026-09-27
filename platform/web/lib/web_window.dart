/// Web 窗口能力入口（条件导入）。
///
/// - Web 目标：`src/web_window_web.dart`（Fullscreen API，其余能力 no-op）；
/// - 其他目标：`src/web_window_stub.dart`（全部能力不可用、调用 no-op）。
///
/// [WbWindowPlugin] 与 [WebWindowCapabilities] 定义在
/// `src/web_window_types.dart`，两个目标共用。
library;

export 'src/web_window_stub.dart'
    if (dart.library.js_interop) 'src/web_window_web.dart';
export 'src/web_window_types.dart';
