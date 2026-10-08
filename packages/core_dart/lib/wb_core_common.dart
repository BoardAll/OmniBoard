/// wb_core_common.dart — 平台中立的公共入口（桌面 FFI / Web WASM 共用）。
///
/// 与 `wb_core.dart` 的区别：本入口不导出任何平台相关实现
/// （`dart:ffi` 的 `WbCoreFfi` / `dart:js_interop` 的 `WbCoreWasm`），
/// 因此可同时被桌面与 Web 目标编译；共享画布包（whiteboard_canvas）
/// 及其他跨端代码一律经本入口依赖 core 模型与服务。
///
/// 引擎实例（[WbEngineCaller] 实现）由宿主应用注入并构造域服务：
/// - 桌面：`WbCoreFfi.load()`；
/// - Web：`WbCoreWasm.load()`。
library;

export 'engine.dart';

// models
export 'models/background.dart';
export 'models/board.dart';
export 'models/connector.dart';
export 'models/element.dart';
export 'models/layer.dart';
export 'models/page.dart';
export 'models/theme.dart';
export 'models/tool.dart';

// services
export 'services/ai_service.dart';
export 'services/background_service.dart';
export 'services/board_service.dart';
export 'services/crdt_service.dart';
export 'services/element_service.dart';
export 'services/page_service.dart';
export 'services/render_service.dart';
export 'services/sync_service.dart';
export 'services/theme_service.dart';
export 'services/tool_service.dart';

// utils
export 'utils/binary_codec.dart';
export 'utils/handle_manager.dart';
export 'utils/json_codec.dart';
