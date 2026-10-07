/// Web 端 Markdown 宿主接线 Widget 测试（方案 §16/§17）。
///
/// 覆盖：
/// - 宽屏「更多」菜单 → Markdown 直建：默认内容落视口中心 420×320、
///   自动选中、回切选择工具、**不自动进编辑器**；
/// - 双击 Markdown 元素 → 全窗编辑工作区（预填 payload）→ 源码改写
///   debounce 300ms 经 `onLiveChanged` 实时回写画布 payload；
/// - 上下文浮层 `_resolveType` 映射：选中 markdown 显示类型标签
///   「Markdown」与「编辑 / 全屏」条目（对齐 `WbContextCatalog`），
///   `markdown.edit` / `markdown.fullscreen` 命令链路贯通；
/// - Reader「编辑」入口回跳编辑工作区（取最新元素快照）；
/// - 窄屏底部「更多」→ Markdown 直建（`wb-bottom-more-markdown`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_canvas/canvas/canvas_controller.dart';
import 'package:whiteboard_canvas/canvas/canvas_model.dart';
import 'package:whiteboard_canvas/markdown/markdown_editor.dart';
import 'package:whiteboard_canvas/markdown/markdown_model.dart';
import 'package:whiteboard_canvas/markdown/markdown_reader.dart';
import 'package:whiteboard_web/app.dart';
import 'package:whiteboard_web/routes.dart';
import 'package:whiteboard_web/services/realtime_service.dart';
import 'package:whiteboard_web/services/wb_browser_io.dart';
import 'package:whiteboard_web/services/wb_core_service.dart';
import 'package:whiteboard_web/services/wb_persistent_canvas_store.dart';
import 'package:whiteboard_web/widgets/context_toolbar_host.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

import 'support/fake_socketio_bridge.dart';

/// 浮层工具栏根 key（`showWbContextToolbar` 固定值）。
const ValueKey<String> _popupKey =
    ValueKey<String>('wb-context-toolbar-popup');

void main() {
  setUp(() {
    // 画布存档为进程内共享内存（VM 桩）：逐例清空，元素数断言从零起。
    createWbCanvasStorage().write(
      '${WbPersistentCanvasStore.keyPrefix}test-board',
      '',
    );
  });

  testWidgets('宽屏「更多」→ Markdown 直建（无对话框、自动选中、420×320）',
      (WidgetTester tester) async {
    await _pumpEditPage(tester);
    final WbCanvasController canvas = _canvasOf(tester);
    expect(canvas.elements, isEmpty);

    await _createMarkdownViaMoreMenu(tester);

    // 直建：不经编辑器对话框，默认内容直接落画布。
    expect(find.byType(WbMarkdownEditor), findsNothing);
    expect(canvas.elements.length, 1);
    final WbCanvasElement created = canvas.elements.single;
    expect(created.type, WbElementKind.markdown);
    expect(created.width, 420);
    expect(created.height, 320);
    final WbMarkdownModel model = created.payload! as WbMarkdownModel;
    expect(model.source, WbMarkdownModel.defaultSource);

    // 自动选中 + 回切选择工具 + 轻提示（双击才进编辑器）。
    expect(canvas.selectedIds, contains(created.id));
    expect(canvas.tool, WbCanvasTool.select);
    expect(find.textContaining('双击进入编辑'), findsOneWidget);

    await _flushSnacks(tester);
    await _unmount(tester);
  });

  testWidgets('双击 Markdown → 编辑工作区预填 → debounce 实时回写 payload',
      (WidgetTester tester) async {
    await _pumpEditPage(tester);
    final WbCanvasController canvas = _canvasOf(tester);
    await _createMarkdownViaMoreMenu(tester);
    final WbCanvasElement created = canvas.elements.single;

    // 双击元素（控制器口径：屏幕坐标命中）→ 全窗编辑工作区（编辑态标题）。
    canvas.handleDoubleClick(canvas.worldRectToScreen(created.bounds).center);
    await tester.pumpAndSettle();
    expect(find.text('编辑Markdown'), findsOneWidget);
    final WbMarkdownEditor editor =
        tester.widget<WbMarkdownEditor>(find.byType(WbMarkdownEditor));
    expect(editor.initialModel?.source, WbMarkdownModel.defaultSource);

    // 源码改写 → debounce 300ms → onLiveChanged 即时回写（宽高保持）。
    await tester.enterText(
      find.byKey(const ValueKey<String>('wb-md-editor-source')),
      '# 实时回写\n\n新内容',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));

    final WbCanvasElement updated = canvas.elements.single;
    expect(updated.id, created.id);
    expect(updated.width, 420);
    expect(updated.height, 320);
    expect(
      (updated.payload! as WbMarkdownModel).source,
      '# 实时回写\n\n新内容',
    );

    // 取消关闭：对话框退出，元素与已实时回写的 payload 保留。
    await tester.tap(
      find.byKey(const ValueKey<String>('wb-element-editor-cancel')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WbMarkdownEditor), findsNothing);
    expect(canvas.elements.length, 1);

    await _flushSnacks(tester);
    await _unmount(tester);
  });

  testWidgets('上下文浮层：Markdown 类型标签与「编辑」命令 → 编辑工作区',
      (WidgetTester tester) async {
    await _pumpEditPage(tester);
    final WbCanvasController canvas = _canvasOf(tester);
    await _createMarkdownViaMoreMenu(tester);
    final WbCanvasElement created = canvas.elements.single;

    // 直建后自动选中：清空重选以覆盖 `_resolveType` 映射路径。
    canvas.selection!.clear();
    await _settle(tester);
    expect(find.byKey(_popupKey), findsNothing);

    canvas.selection!.select(<String>[created.id]);
    await _settle(tester);
    expect(find.byKey(_popupKey), findsOneWidget);
    // 类型标签 = `WbContextTargetType.markdown.label`（画布渲染为
    // CustomPaint，不产生 Text，标签文本唯一）。
    expect(find.text('Markdown'), findsOneWidget);

    // 「编辑」条目 → markdown.edit → 编辑工作区（预填既有 payload）。
    await tester.tap(find.byKey(const ValueKey<String>('wb-context-edit')));
    await tester.pumpAndSettle();
    expect(find.text('编辑Markdown'), findsOneWidget);
    expect(find.byType(WbMarkdownEditor), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-element-editor-cancel')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WbMarkdownEditor), findsNothing);

    await _flushSnacks(tester);
    await _unmount(tester);
  });

  testWidgets('浮层「全屏」→ Reader → 「编辑」回跳编辑工作区',
      (WidgetTester tester) async {
    await _pumpEditPage(tester);
    final WbCanvasController canvas = _canvasOf(tester);
    await _createMarkdownViaMoreMenu(tester);
    final WbCanvasElement created = canvas.elements.single;

    canvas.selection!.clear();
    await _settle(tester);
    canvas.selection!.select(<String>[created.id]);
    await _settle(tester);
    expect(find.byKey(_popupKey), findsOneWidget);

    // 「全屏」条目 → markdown.fullscreen → 全屏阅读器。
    await tester.tap(
      find.byKey(const ValueKey<String>('wb-context-fullscreen')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WbMarkdownReader), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('wb-md-reader')), findsOneWidget);
    // 元素未命名 → 默认标题。
    expect(find.text('Markdown 阅读'), findsOneWidget);

    // Reader「编辑」→ 关闭 Reader 并回跳编辑工作区（取最新元素快照）。
    await tester.tap(find.byKey(const ValueKey<String>('wb-md-reader-edit')));
    await tester.pumpAndSettle();
    expect(find.byType(WbMarkdownReader), findsNothing);
    expect(find.text('编辑Markdown'), findsOneWidget);
    expect(find.byType(WbMarkdownEditor), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-element-editor-cancel')),
    );
    await tester.pumpAndSettle();

    await _flushSnacks(tester);
    await _unmount(tester);
  });

  testWidgets('窄屏底部「更多」→ Markdown 直建', (WidgetTester tester) async {
    await _pumpEditPage(tester, size: const Size(600, 800));
    // 窄屏：宽屏浮动面板不挂载，入口由底部工具条承担。
    expect(find.byKey(const Key('wb-canvas-more')), findsNothing);
    final WbCanvasController canvas = _canvasOf(tester);

    await tester.tap(find.byKey(const Key('wb-bottom-more')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('wb-bottom-more-markdown')),
    );
    await tester.pumpAndSettle();

    expect(canvas.elements.length, 1);
    final WbCanvasElement created = canvas.elements.single;
    expect(created.type, WbElementKind.markdown);
    expect(created.width, 420);
    expect(created.payload, isA<WbMarkdownModel>());

    await _flushSnacks(tester);
    await _unmount(tester);
  });
}

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

/// 启动注入就绪假核心与协作服务的编辑页（默认宽屏：顶部浮动工具面板可见）。
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

/// 经宽屏「更多」菜单 pro 分组直建 Markdown（无对话框，即点即建）。
Future<void> _createMarkdownViaMoreMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('wb-canvas-more')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Markdown'));
  await tester.pumpAndSettle();
}

/// 帧末同步（postFrame 驱动宿主 `_sync`）+ overlay 重建两帧。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
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
