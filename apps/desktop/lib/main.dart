/// 桌面应用入口。
library;

import 'package:flutter/material.dart';

import 'app.dart';
import 'platform/window_service.dart';
import 'services/board_file_service.dart';
import 'services/ffi_service.dart';
import 'services/settings_store.dart';
import 'services/shortcut_service.dart';
import 'services/sync_service.dart';
import 'state/theme_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 窗口初始化（非桌面 / 平台通道缺失时静默跳过）。
  final WbWindowService windowService = WbWindowService();
  await windowService.initialize();

  // 核心引擎：加载失败进入演示模式（见 WbFfiService 文档）。
  final WbFfiService ffiService = WbFfiService();
  ffiService.initialize();

  // 设置持久化：`%APPDATA%\Whiteboard\settings.json`（IO 失败静默降级）。
  final WbSettingsStore settingsStore = WbSettingsStore();

  runApp(WhiteboardApp(
    ffiService: ffiService,
    themeState: WbThemeState(store: settingsStore),
    collabService: WbCollabService(
      engine: WbFfiCollabEngine(ffiService),
      endpoint: settingsStore.syncServerUrl,
    ),
    shortcutService: WbShortcutService(),
    settingsStore: settingsStore,
    boardFileService: WbBoardFileService(settings: settingsStore),
  ));
}
