// tests/e2e 共用脚手架：启动 apps/desktop 完整应用入口
// （WhiteboardApp + 演示模式 FFI 降级路径），并按需进入编辑页。
//
// 与 apps/desktop/test 的深度 widget 测试同一策略（见
// apps/desktop/test/board_wiring_test.dart）：
// - 注入必然失败的 DLL 候选路径 → 应用内演示模式，保证确定性；
// - 1600x1000 视口：侧栏 240 + 画布 + AI 面板 320（默认展开）；
// - 不注入 GoRouter（不额外引入 go_router 依赖）：本套件流程不触发
//   主题通知，未触及 apps/desktop/lib/app.dart 中
//   `routerConfig: router ?? createRouter()` 的重建缺陷（已单独上报）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/app.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/services/shortcut_service.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';
import 'package:whiteboard_desktop/state/theme_state.dart';

/// 画布区域中心点（不被侧栏 / AI 面板覆盖）。
const Offset kCanvasCenter = Offset(760, 500);

/// 演示模式 FFI 服务（候选路径必然失败 → 应用内降级路径，保证确定性）。
WbFfiService demoFfi() {
  return WbFfiService(candidatePaths: const <String>['__wb_missing__.dll'])
    ..initialize();
}

/// 启动完整应用（1600x1000 视口），停留在「我的白板」首页。
Future<void> pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final WbThemeState theme = WbThemeState();
  final WbSyncService sync = WbSyncService();
  addTearDown(() {
    theme.dispose();
    sync.dispose();
  });

  await tester.pumpWidget(
    WhiteboardApp(
      ffiService: demoFfi(),
      themeState: theme,
      syncService: sync,
      shortcutService: WbShortcutService(),
    ),
  );
  await tester.pumpAndSettle();
}

/// 启动应用并通过「新建白板」进入编辑页。
Future<void> pumpEditor(WidgetTester tester) async {
  await pumpApp(tester);
  await tester.tap(find.text('新建白板'));
  await tester.pumpAndSettle();
}
