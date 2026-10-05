/// Web 专业元素编辑器（P5：高级模块入口）Widget 测试。
///
/// 覆盖：
/// - 宽屏「更多」菜单 pro 组 → 表格编辑器对话框（新建）→ 保存 →
///   画布元素 +1（默认示例模型测量插入 + 回切选择工具 + 轻提示）；
/// - 双击专业元素 → 编辑对话框（预填既有模型，同实例注入）→ 保存 →
///   `updateElement` 写回（copyWith 新实例、payload 保留）；
/// - 取消无副作用：创建取消不插入；编辑取消不写回（元素同实例）；
/// - 尺寸角标（render2d）→ 尺寸对话框：预填 → 取消不修改 → 确认
///   `resizeElementById` 生效。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_canvas/canvas/canvas_controller.dart';
import 'package:whiteboard_canvas/canvas/canvas_model.dart';
import 'package:whiteboard_canvas/context_editors/table_editor.dart';
import 'package:whiteboard_web/app.dart';
import 'package:whiteboard_web/routes.dart';
import 'package:whiteboard_web/services/realtime_service.dart';
import 'package:whiteboard_web/services/wb_browser_io.dart';
import 'package:whiteboard_web/services/wb_core_service.dart';
import 'package:whiteboard_web/services/wb_persistent_canvas_store.dart';
import 'package:whiteboard_web/widgets/context_toolbar_host.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

import 'support/fake_socketio_bridge.dart';

void main() {
  setUp(() {
    // 画布存档为进程内共享内存（VM 桩）：逐例清空，元素数断言从零起。
    createWbCanvasStorage().write(
      '${WbPersistentCanvasStore.keyPrefix}test-board',
      '',
    );
  });

  testWidgets('P5：更多菜单 pro 组 → 表格编辑器 → 保存 → 元素 +1',
      (WidgetTester tester) async {
    await _pumpEditPage(tester);
    final WbCanvasController canvas = _canvasOf(tester);
    expect(canvas.elements, isEmpty);

    // 宽屏「更多」菜单 → pro 分组「表格」。
    await tester.tap(find.byKey(const Key('wb-canvas-more')));
    await tester.pumpAndSettle();
    expect(find.text('表格'), findsOneWidget);
    await tester.tap(find.text('表格'));
    await tester.pumpAndSettle();

    // 新建对话框：全屏工作区编辑器（表格）。
    expect(find.text('新建表格'), findsOneWidget);
    expect(find.byType(WbTableEditor), findsOneWidget);

    // 未修改直接保存 → 默认示例模型 → 测量插入。
    await tester.tap(find.byKey(const ValueKey<String>('wb-element-editor-save')));
    await tester.pumpAndSettle();

    expect(find.text('新建表格'), findsNothing);
    expect(canvas.elements.length, 1);
    final WbCanvasElement created = canvas.elements.single;
    expect(created.type, WbElementKind.table);
    expect(created.payload, isA<WbTableModel>());
    // 创建完成后回切选择模式 + 轻提示。
    expect(canvas.tool, WbCanvasTool.select);
    expect(find.textContaining('已插入「表格」到画布'), findsOneWidget);

    await _flushSnacks(tester);
    await _unmount(tester);
  });

  testWidgets('P5：双击专业元素 → 编辑对话框预填 → 保存回写',
      (WidgetTester tester) async {
    await _pumpEditPage(tester);
    final WbCanvasController canvas = _canvasOf(tester);
    await _createViaMoreMenu(tester, '表格');
    final WbCanvasElement created = canvas.elements.single;

    // 双击元素（控制器口径：屏幕坐标命中）→ 编辑对话框。
    canvas.handleDoubleClick(canvas.worldRectToScreen(created.bounds).center);
    await tester.pumpAndSettle();

    expect(find.text('编辑表格'), findsOneWidget);
    // 预填：既有模型（同一实例）注入编辑器。
    final WbTableEditor editor =
        tester.widget<WbTableEditor>(find.byType(WbTableEditor));
    expect(identical(editor.initialModel, created.payload), isTrue);

    // 保存 → updateElement 写回（copyWith 产生新实例、payload 保留）。
    await tester.tap(find.byKey(const ValueKey<String>('wb-element-editor-save')));
    await tester.pumpAndSettle();

    expect(find.byType(WbTableEditor), findsNothing);
    expect(canvas.elements.length, 1);
    final WbCanvasElement updated = canvas.elements.single;
    expect(updated.id, created.id);
    expect(identical(updated, created), isFalse);
    expect(identical(updated.payload, created.payload), isTrue);

    await _flushSnacks(tester);
    await _unmount(tester);
  });

  testWidgets('P5：取消无副作用（创建取消不插入 / 编辑取消不写回）',
      (WidgetTester tester) async {
    await _pumpEditPage(tester);
    final WbCanvasController canvas = _canvasOf(tester);

    // 创建取消：对话框关闭、无元素插入、无轻提示。
    await tester.tap(find.byKey(const Key('wb-canvas-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('表格'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('wb-element-editor-cancel')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WbTableEditor), findsNothing);
    expect(canvas.elements, isEmpty);

    // 正常创建（编辑取消的前置）。
    await _createViaMoreMenu(tester, '表格');
    final WbCanvasElement created = canvas.elements.single;

    // 编辑取消：对话框关闭、元素未被写回（同实例）。
    canvas.handleDoubleClick(canvas.worldRectToScreen(created.bounds).center);
    await tester.pumpAndSettle();
    expect(find.byType(WbTableEditor), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('wb-element-editor-cancel')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WbTableEditor), findsNothing);
    expect(canvas.elements.length, 1);
    expect(identical(canvas.elements.single, created), isTrue);

    await _flushSnacks(tester);
    await _unmount(tester);
  });

  testWidgets('P5：尺寸角标 → 尺寸对话框 → 取消不修改 / 确认 resize',
      (WidgetTester tester) async {
    await _pumpEditPage(tester);
    final WbCanvasController canvas = _canvasOf(tester);
    // 尺寸角标仅对有尺寸元素（render3d / render2d）显示。
    await _createViaMoreMenu(tester, '2D 图元');
    final WbCanvasElement created = canvas.elements.single;
    expect(created.type, WbElementKind.render2d);

    // 角标屏幕矩形（选择框下缘居中）→ 控制器指针按下消费并回调。
    final Rect? badge = canvas.sizeBadgeScreenRect;
    expect(badge, isNotNull);
    canvas.handlePointerDown(1, badge!.center, shift: false);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('wb-size-dialog')), findsOneWidget);
    expect(find.text('尺寸设置'), findsOneWidget);

    // 取消：尺寸不变。
    await tester.tap(find.byKey(const ValueKey<String>('wb-size-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('wb-size-dialog')), findsNothing);
    expect(canvas.elements.single.width, created.width);
    expect(canvas.elements.single.height, created.height);

    // 再次打开 → 输入新尺寸 → 确认 → resize 生效（中心不变）。
    canvas.handlePointerDown(2, badge.center, shift: false);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('wb-size-width-field')),
      '500',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('wb-size-height-field')),
      '400',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('wb-size-confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('wb-size-dialog')), findsNothing);
    final WbCanvasElement resized = canvas.elements.single;
    expect(resized.width, 500);
    expect(resized.height, 400);
    expect(resized.center, created.center);

    await _flushSnacks(tester);
    await _unmount(tester);
  });
}

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

/// 启动注入就绪假核心与协作服务的编辑页（宽屏：顶部浮动工具面板可见）。
Future<void> _pumpEditPage(
  WidgetTester tester, {
  Size size = const Size(1400, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final WbCoreService core = WbCoreService(loader: _ReadyLoader());
  addTearDown(core.dispose);
  final WbRealtimeService realtime = WbRealtimeService(
    clientLoader: (String endpoint) async {},
    bridgeFactory: FakeSocketIoBridge.new,
  );
  await tester.pumpWidget(
    WhiteboardWebApp(
      router: createWebRouter(
        initialLocation: WbWebRoutes.boardPath('test-board', name: '测试白板'),
      ),
      realtimeService: realtime,
      coreService: core,
    ),
  );
  await tester.pumpAndSettle();
}

/// 取画布控制器（经上下文工具栏宿主持有的实例）。
WbCanvasController _canvasOf(WidgetTester tester) =>
    tester
        .widget<WbWebContextToolbarHost>(
          find.byType(WbWebContextToolbarHost),
        )
        .controller;

/// 经宽屏「更多」菜单 pro 分组创建专业元素（对话框直接保存默认模型）。
Future<void> _createViaMoreMenu(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const Key('wb-canvas-more')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(const ValueKey<String>('wb-element-editor-save')),
  );
  await tester.pumpAndSettle();
}

/// 逐条冲刷轻提示队列（一次 pump 只令当前条到期；后续条在其关闭动画
/// 结束后才开始计时，需循环快进）。
Future<void> _flushSnacks(WidgetTester tester) async {
  for (int i = 0; i < 3; i++) {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }
}

/// 卸载应用，并冲刷其微任务 / 超时兜底定时器。
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 900));
}

/// 固定 ready 状态的假核心加载器（驱动共享画布与顶部工具面板挂载）。
class _ReadyLoader extends WbCoreLoader {
  @override
  WbCoreStatus get status => WbCoreStatus.ready;

  @override
  bool get isAvailable => WbCoreStatus.ready.isAvailable;

  @override
  Future<WbCoreStatus> load() async => WbCoreStatus.ready;
}
