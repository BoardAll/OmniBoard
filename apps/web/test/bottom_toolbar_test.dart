/// Web 窄屏底部工具条（与端上 `WbCanvasToolPalette` 工具行对齐）Widget 测试。
///
/// 覆盖：
/// - 同集断言：11 工具 + 撤销 / 重做 / 更多（key `wb-bottom-*` 与端上
///   `wb-canvas-*` 命名风格对齐）；窄屏不出现宽屏浮动面板；
/// - 贯通：点底部工具 → 控制器工具切换；无历史时撤销 / 重做置灰；
/// - 撤销 / 重做随编辑启停并生效（插入 → 撤销 → 清空 → 重做 → 恢复）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_canvas/canvas/canvas_controller.dart';
import 'package:whiteboard_canvas/canvas/canvas_tool_palette.dart';
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

  testWidgets('窄屏底部工具条：与端上同集（11 工具 + 撤销 / 重做 / 更多）',
      (WidgetTester tester) async {
    await _pumpEditPage(tester);

    for (final WbCanvasTool tool in WbCanvasTool.values) {
      expect(
        find.byKey(ValueKey<String>('wb-bottom-tool-${tool.id}')),
        findsOneWidget,
      );
    }
    expect(find.byKey(const Key('wb-bottom-undo')), findsOneWidget);
    expect(find.byKey(const Key('wb-bottom-redo')), findsOneWidget);
    expect(find.byKey(const Key('wb-bottom-more')), findsOneWidget);
    // 窄屏：宽屏浮动面板不挂载（palette 键不出现）。
    expect(find.byKey(const Key('wb-canvas-more')), findsNothing);

    // 工具切换贯通控制器；无历史时撤销 / 重做置灰。
    // 便签枚举 id 为 'sticky'（非 'note'），经枚举取值防写死偏差。
    await tester.tap(
      find.byKey(ValueKey<String>('wb-bottom-tool-${WbCanvasTool.note.id}')),
    );
    await tester.pump();
    expect(_canvasOf(tester).tool, WbCanvasTool.note);
    expect(_iconButton(tester, 'wb-bottom-undo').enabled, isFalse);
    expect(_iconButton(tester, 'wb-bottom-redo').enabled, isFalse);

    await _unmount(tester);
  });

  testWidgets('窄屏底部撤销 / 重做：随编辑启停并生效', (WidgetTester tester) async {
    await _pumpEditPage(tester);
    final WbCanvasController canvas = _canvasOf(tester);

    canvas.insertElement(type: 'note', size: const Size(200, 160));
    // 插入会自动选中元素，上下文浮层的全屏遮罩随后浮出并拦截底部条点按；
    // 清空选区（等同点击空白收起）保持本用例聚焦底部撤销 / 重做。
    canvas.selection?.clear();
    await tester.pump();
    expect(canvas.elements.length, 1);

    // 插入入撤销栈 → 撤销按钮启用 → 点按后清空。
    expect(_iconButton(tester, 'wb-bottom-undo').enabled, isTrue);
    await tester.tap(find.byKey(const Key('wb-bottom-undo')));
    await tester.pump();
    expect(canvas.elements, isEmpty);

    // 撤销后可重做 → 点按恢复。
    expect(_iconButton(tester, 'wb-bottom-redo').enabled, isTrue);
    await tester.tap(find.byKey(const Key('wb-bottom-redo')));
    await tester.pump();
    expect(canvas.elements.length, 1);

    await _unmount(tester);
  });
}

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

/// 启动注入就绪假核心的编辑页（窄屏 600×800：工具选择由底部工具条承担）。
Future<void> _pumpEditPage(
  WidgetTester tester, {
  Size size = const Size(600, 800),
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

/// 底部条共享按钮（读 enabled 断言启停）。
WbCanvasIconButton _iconButton(WidgetTester tester, String key) =>
    tester.widget<WbCanvasIconButton>(find.byKey(Key(key)));

/// 卸载应用，并冲刷其微任务 / 超时兜底定时器。
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 900));
}

/// 固定 ready 状态的假核心加载器（驱动共享画布挂载）。
class _ReadyLoader extends WbCoreLoader {
  @override
  WbCoreStatus get status => WbCoreStatus.ready;

  @override
  bool get isAvailable => WbCoreStatus.ready.isAvailable;

  @override
  Future<WbCoreStatus> load() async => WbCoreStatus.ready;
}
