/// apps/web 冒烟测试（VM 安全：WASM 走不可用降级路径）。
///
/// 覆盖：
/// - 列表页空态渲染与引擎状态（预留演示数据已移除）；
/// - 新建白板 → 编辑页导航（含降级画布提示）→ 返回列表保留；
/// - 编辑页响应式（宽屏左侧栏仅页面 / 图层分区，工具为画布顶部浮动面板；
///   窄屏单栏 + 底部工具条）。
///
/// 真实 WASM 加载（script 注入 / Promise 实例化）仅在浏览器发生，
/// 由 Wave 4 的产物 + 浏览器集成测试覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_canvas/canvas/canvas_controller.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_web/app.dart';
import 'package:whiteboard_web/routes.dart';

/// 启动应用；[initialLocation] 非空时使用对应路由直达。
Future<void> pumpApp(WidgetTester tester, {String? initialLocation}) async {
  await tester.pumpWidget(
    WhiteboardWebApp(
      router: initialLocation == null
          ? null
          : createWebRouter(initialLocation: initialLocation),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('白板列表页', () {
    testWidgets('渲染标题、空态与引擎状态', (WidgetTester tester) async {
      await pumpApp(tester);

      expect(find.text('我的白板'), findsOneWidget);
      expect(find.text('新建白板'), findsOneWidget);
      expect(find.text('引擎待命'), findsOneWidget);
      // 空态引导（预留演示数据已移除）。
      expect(find.byKey(const Key('wb-board-list-empty')), findsOneWidget);
      expect(find.text('还没有白板'), findsOneWidget);
      expect(find.text('产品路线图'), findsNothing);
      expect(find.text('系统架构草图'), findsNothing);
      expect(find.text('需求脑图'), findsNothing);
    });

    testWidgets('新建白板进入编辑页并显示降级画布', (WidgetTester tester) async {
      await pumpApp(tester);

      await tester.tap(find.text('新建白板'));
      await tester.pumpAndSettle();

      // 编辑页：AppBar 标题（首个新建为「未命名白板 1」）+ 演示画布
      expect(find.text('未命名白板 1'), findsOneWidget);
      expect(find.byKey(const Key('wb-demo-canvas')), findsOneWidget);
      // WASM 核心不可用：状态 chip 与降级提示条
      expect(find.text('演示画布'), findsOneWidget);
      expect(find.textContaining('内置演示画布'), findsOneWidget);
    });

    testWidgets('新建白板后返回列表仍保留条目', (WidgetTester tester) async {
      await pumpApp(tester);

      await tester.tap(find.text('新建白板'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('返回列表'));
      await tester.pumpAndSettle();

      expect(find.text('我的白板'), findsOneWidget);
      expect(find.byKey(const Key('wb-board-list-empty')), findsNothing);
      expect(find.text('未命名白板 1'), findsOneWidget);
    });
  });

  group('白板编辑页（响应式）', () {
    testWidgets('宽屏：左侧页面/图层面板 + 画布区', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpApp(
        tester,
        initialLocation: WbWebRoutes.boardPath('test-board', name: '测试白板'),
      );

      // 工具栏（P3）：宽屏工具为画布顶部浮动面板（随共享画布挂载），
      // 左侧栏不再含工具分区；VM 降级（演示画布）时无工具 UI。
      expect(find.text('工具'), findsNothing);
      expect(find.text('画笔'), findsNothing);
      // 页面 / 图层面板（P2）：分区标题 + 新建按钮 + 演示占位页卡片。
      expect(find.text('页面'), findsOneWidget);
      expect(find.text('图层'), findsOneWidget);
      expect(find.byKey(const Key('web-pages-add')), findsOneWidget);
      expect(
        find.byKey(const Key('page-card-test-board-page-1')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('wb-demo-canvas')), findsOneWidget);
    });

    testWidgets('宽屏：新建页面后页面列表增加', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpApp(
        tester,
        initialLocation: WbWebRoutes.boardPath('test-board', name: '测试白板'),
      );

      await tester.tap(find.byKey(const Key('web-pages-add')));
      await tester.pumpAndSettle();

      // 内存模式新建：id 按现有页数递增（`<boardId>-page-N`）。
      expect(
        find.byKey(const Key('page-card-test-board-page-2')),
        findsOneWidget,
      );
      expect(find.text('页面 2'), findsOneWidget);
    });

    testWidgets('窄屏：单栏 + 底部工具条（无左侧面板）', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpApp(
        tester,
        initialLocation: WbWebRoutes.boardPath('test-board'),
      );

      expect(find.text('工具'), findsNothing);
      expect(find.text('页面'), findsNothing);
      expect(find.text('图层'), findsNothing);
      // 底部工具条与端上工具行同集：11 工具 + 撤销 / 重做 / 更多
      // （演示模式下控制器缺省：撤销 / 重做置灰但仍在位）。
      for (final WbCanvasTool tool in WbCanvasTool.values) {
        expect(
          find.byKey(ValueKey<String>('wb-bottom-tool-${tool.id}')),
          findsOneWidget,
        );
      }
      expect(find.byKey(const Key('wb-bottom-undo')), findsOneWidget);
      expect(find.byKey(const Key('wb-bottom-redo')), findsOneWidget);
      expect(find.byKey(const Key('wb-bottom-more')), findsOneWidget);
      expect(find.byIcon(LinearIcons.pen), findsOneWidget);
      expect(find.byKey(const Key('wb-demo-canvas')), findsOneWidget);
    });
  });
}
