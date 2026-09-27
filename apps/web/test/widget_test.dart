/// apps/web 冒烟测试（VM 安全：WASM 走不可用降级路径）。
///
/// 覆盖：
/// - 列表页渲染演示数据与引擎状态；
/// - 列表 → 编辑页导航（含降级画布提示）；
/// - 编辑页响应式（宽屏左侧栏 / 窄屏单栏 + 底部工具条）；
/// - 新建白板流程。
///
/// 真实 WASM 加载（script 注入 / Promise 实例化）仅在浏览器发生，
/// 由 Wave 4 的产物 + 浏览器集成测试覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
    testWidgets('渲染标题、演示数据与引擎状态', (WidgetTester tester) async {
      await pumpApp(tester);

      expect(find.text('我的白板'), findsOneWidget);
      expect(find.text('产品路线图'), findsOneWidget);
      expect(find.text('系统架构草图'), findsOneWidget);
      expect(find.text('需求脑图'), findsOneWidget);
      expect(find.text('新建白板'), findsOneWidget);
      expect(find.text('引擎待命'), findsOneWidget);
    });

    testWidgets('点击卡片进入编辑页并显示降级画布', (WidgetTester tester) async {
      await pumpApp(tester);

      await tester.tap(find.text('产品路线图'));
      await tester.pumpAndSettle();

      // 编辑页：AppBar 标题 + 演示画布
      expect(find.text('产品路线图'), findsOneWidget);
      expect(find.byKey(const Key('wb-demo-canvas')), findsOneWidget);
      // WASM 核心不可用：状态 chip 与降级提示条
      expect(find.text('演示画布'), findsOneWidget);
      expect(find.textContaining('内置演示画布'), findsOneWidget);
    });

    testWidgets('新建白板后进入编辑页', (WidgetTester tester) async {
      await pumpApp(tester);

      await tester.tap(find.text('新建白板'));
      await tester.pumpAndSettle();

      expect(find.text('未命名白板 4'), findsOneWidget);
      expect(find.byKey(const Key('wb-demo-canvas')), findsOneWidget);
    });
  });

  group('白板编辑页（响应式）', () {
    testWidgets('宽屏：左侧工具面板 + 画布区', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpApp(
        tester,
        initialLocation:
            WbWebRoutes.boardPath('demo-roadmap', name: '产品路线图'),
      );

      expect(find.text('工具'), findsOneWidget);
      expect(find.text('画笔'), findsOneWidget);
      expect(find.byKey(const Key('wb-demo-canvas')), findsOneWidget);
    });

    testWidgets('窄屏：单栏 + 底部工具条（无左侧面板）', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpApp(
        tester,
        initialLocation: WbWebRoutes.boardPath('demo-roadmap'),
      );

      expect(find.text('工具'), findsNothing);
      expect(find.byIcon(LinearIcons.pen), findsOneWidget);
      expect(find.byKey(const Key('wb-demo-canvas')), findsOneWidget);
    });
  });
}
