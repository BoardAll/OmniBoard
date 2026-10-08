// §8.3 集成测试共用脚手架：启动完整应用（FFI 缺失 → 应用内演示模式降级
// 路径）并按需进入编辑页。
//
// 交互坐标与按键约定与既有深度 widget 测试保持一致：1600x1000 视口，
// 侧栏 240 + 画布 + AI 面板 320（默认展开）。
//
// 说明：显式注入单一 [GoRouter]（`WhiteboardApp.router` 测试接缝）。若不注入，
// 根组件在 `WbThemeState` 每次通知时都会 `createRouter()` 重建路由，导致
// 导航栈重置（设置页切主题后跳回首页）——既影响真实装配（main.dart 未传
// router），也会干扰端到端断言；作为测试脚手架在此规避并单独上报该缺陷。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:whiteboard_desktop/app.dart';
import 'package:whiteboard_desktop/routes.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/services/shortcut_service.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';
import 'package:whiteboard_desktop/state/theme_state.dart';

/// 画布区域中心点（不被侧栏 / AI 面板覆盖）。
const Offset kCanvasCenter = Offset(760, 500);

/// 演示模式 FFI 服务（候选路径必然失败 → 走应用内降级路径，保证确定性）。
WbFfiService demoFfi() {
  return WbFfiService(candidatePaths: const <String>['__wb_missing__.dll'])
    ..initialize();
}

/// 启动完整应用（1600x1000 视口），停留在「我的白板」首页。
///
/// 返回 [WbThemeState]，供用例在需要时调整外观偏好（如工具栏风格切换）。
Future<WbThemeState> pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final WbThemeState theme = WbThemeState();
  final WbCollabService sync = WbCollabService();
  final GoRouter router = createRouter();
  addTearDown(() {
    theme.dispose();
    sync.dispose();
    router.dispose();
  });

  await tester.pumpWidget(WhiteboardApp(
    ffiService: demoFfi(),
    themeState: theme,
    collabService: sync,
    shortcutService: WbShortcutService(),
    router: router,
  ));
  await tester.pumpAndSettle();
  return theme;
}

/// 启动应用并通过「新建白板」进入编辑页。
///
/// 返回 [WbThemeState]（透传 [pumpApp]）。
Future<WbThemeState> pumpEditor(WidgetTester tester) async {
  final WbThemeState theme = await pumpApp(tester);
  await tester.tap(find.text('新建白板'));
  await tester.pumpAndSettle();
  return theme;
}

/// 展开快速创建入口并选择某类编辑器。
///
/// [kindId] 取值：flowchart / table / mindmap / function / render3d。
Future<void> openQuickCreate(WidgetTester tester, String kindId) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('wb-ctx-quick-create-toggle')),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(ValueKey<String>('wb-ctx-quick-create-$kindId')),
  );
  await tester.pumpAndSettle();
}

/// 点击浮层遮罩关闭对话框（与 board_wiring_test 相同的安全坐标）。
Future<void> dismissOverlay(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 120));
  await tester.pumpAndSettle();
}
