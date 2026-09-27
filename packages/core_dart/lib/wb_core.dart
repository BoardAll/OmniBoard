/// whiteboard_core — public entry point.
///
/// CONTRACT FILE (Wave 0). Task package 2.3 fills src/** and may add exports
/// here, but must not change names of existing exports.
///
/// Web 专用入口 `wb_core_wasm.dart` 有意不在此导出（避免桌面/VM 构建
/// 拉入 `dart:js_interop`），Flutter Web 应用请显式 import。
library;

export 'wb_core_bindings.dart';
export 'wb_core_ffi.dart';

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
export 'services/element_service.dart';
export 'services/page_service.dart';
export 'services/render_service.dart';
export 'services/theme_service.dart';
export 'services/tool_service.dart';

// utils
export 'utils/binary_codec.dart';
export 'utils/handle_manager.dart';
export 'utils/json_codec.dart';
