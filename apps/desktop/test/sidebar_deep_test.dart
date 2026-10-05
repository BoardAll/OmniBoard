/// 侧栏 / 页面管理 / 图层区深度交互测试（Wave 3.2）。
///
/// 覆盖《左侧栏与页面管理设计》M2.6.1–4：
/// - 侧栏展开 / 折叠（按钮与 `Ctrl+\`）、分区折叠、AI / 设置入口；
/// - 页面列表：新建、切换、缩略图刷新、拖拽排序、右键菜单、多选、快捷键；
/// - 图层区：列表顺序、可见性 / 锁定、拖拽排序、右键菜单、双击重命名、选区联动。
///
/// 全程演示模式（无 DLL），禁 golden。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_core/wb_core.dart';

import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/state/board_state.dart';
import 'package:whiteboard_desktop/state/page_state.dart';
import 'package:whiteboard_desktop/state/selection_state.dart';
import 'package:whiteboard_desktop/widgets/layers_panel.dart';
import 'package:whiteboard_desktop/widgets/page_manager.dart';
import 'package:whiteboard_desktop/widgets/sidebar.dart';

// ---------------------------------------------------------------------------
// 夹具与挂载
// ---------------------------------------------------------------------------

/// 演示模式夹具：白板 `b1`（默认 1 页 `b1-page-1`）。
class _BoardFixture {
  _BoardFixture({String name = '测试白板'}) {
    ffi = WbFfiService(candidatePaths: const <String>['__wb_missing__.dll'])
      ..initialize();
    board = WbBoardState(ffi: ffi)..open('b1', name: name);
    pages = WbPageState(ops: WbFfiPageOps(ffi))..attach(board.board!);
    selection = WbSelectionState();
  }

  late final WbFfiService ffi;
  late final WbBoardState board;
  late final WbPageState pages;
  late final WbSelectionState selection;

  void dispose() {
    board.dispose();
    pages.dispose();
    selection.dispose();
  }
}

Widget _withProviders(_BoardFixture fx, Widget child) {
  return MultiProvider(
    providers: [
      Provider<WbFfiService>.value(value: fx.ffi),
      ChangeNotifierProvider<WbBoardState>.value(value: fx.board),
      ChangeNotifierProvider<WbPageState>.value(value: fx.pages),
      ChangeNotifierProvider<WbSelectionState>.value(value: fx.selection),
    ],
    child: child,
  );
}

/// 模拟 `board_edit_page` 的挂载方式：`SizedBox(width: 240, child: Sidebar())`。
Widget _sidebarApp(
  _BoardFixture fx, {
  VoidCallback? onOpenAiPanel,
  bool initiallyCollapsed = false,
  bool canEdit = true,
  VoidCallback? onBlockedEdit,
}) {
  return _withProviders(
    fx,
    MaterialApp(
      home: Scaffold(
        body: Row(
          children: <Widget>[
            SizedBox(
              width: 240,
              child: Sidebar(
                initiallyCollapsed: initiallyCollapsed,
                onOpenAiPanel: onOpenAiPanel,
                canEdit: canEdit,
                onBlockedEdit: onBlockedEdit,
              ),
            ),
            const VerticalDivider(width: 1),
            const Expanded(child: SizedBox.expand()),
          ],
        ),
      ),
    ),
  );
}

/// 带 GoRouter 的挂载（验证设置 / 返回行为）。
Widget _routerApp(_BoardFixture fx, GoRouter router) {
  return _withProviders(fx, MaterialApp.router(routerConfig: router));
}

/// 固定窗口尺寸并挂载 + 等待稳定（侧栏在 1300 高度下可完整容纳列表）。
Future<void> _pumpSidebar(
  WidgetTester tester,
  Widget app, {
  Size size = const Size(1280, 1300),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

/// 在页面卡片上打开右键菜单。
Future<void> _openPageMenu(WidgetTester tester, String pageId) async {
  await tester.tap(
    find.byKey(ValueKey<String>('page-card-$pageId')),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(resetDemoLayers);

  // -------------------------------------------------------------------------
  // 侧栏基础（§2 / §3 / §6 / §7 / §10）
  // -------------------------------------------------------------------------

  group('侧栏基础', () {
    testWidgets('展开形态渲染标题 / 分区 / AI / 设置 / 图层种子', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      // 标题区与分区。
      expect(find.text('测试白板'), findsOneWidget);
      expect(find.text('页面'), findsOneWidget);
      expect(find.text('图层'), findsOneWidget);
      expect(find.text('AI'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);

      // 页面分区内容与缩略图静态预览。
      expect(find.text('添加页面'), findsOneWidget);
      expect(find.text('0 元素'), findsOneWidget);

      // 图层区演示种子（顶层在前：连线 3 在最上）。
      expect(find.text('演示模式：样例元素'), findsOneWidget);
      expect(find.text('便签 1'), findsOneWidget);
      expect(find.text('形状 2'), findsOneWidget);
      expect(find.text('连线 3'), findsOneWidget);
      final double top = tester
          .getTopLeft(find.byKey(const ValueKey<String>('layer-row-b1-page-1-el-3')))
          .dy;
      final double bottom = tester
          .getTopLeft(find.byKey(const ValueKey<String>('layer-row-b1-page-1-el-1')))
          .dy;
      expect(top, lessThan(bottom));
    });

    testWidgets('折叠按钮切换 56px 图标轨并可展开恢复', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      final Finder panel = find.byKey(const ValueKey<String>('sidebar-panel'));
      expect(
        tester.getSize(panel).width,
        closeTo(Sidebar.expandedWidth, 0.01),
      );

      await tester.tap(find.byKey(const ValueKey<String>('sidebar-collapse')));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(panel).width,
        closeTo(Sidebar.collapsedWidth, 0.01),
      );
      // 图标轨元素。
      expect(
        find.byKey(const ValueKey<String>('rail-expand')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('rail-page-b1-page-1')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey<String>('rail-expand')));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(panel).width,
        closeTo(Sidebar.expandedWidth, 0.01),
      );
    });

    testWidgets('Ctrl + 反斜杠快捷键折叠与展开', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      final Finder panel = find.byKey(const ValueKey<String>('sidebar-panel'));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.backslash);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(panel).width,
        closeTo(Sidebar.collapsedWidth, 0.01),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.backslash);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(panel).width,
        closeTo(Sidebar.expandedWidth, 0.01),
      );
    });

    testWidgets('AI 行点击触发 onOpenAiPanel 回调', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      int calls = 0;
      await _pumpSidebar(
        tester,
        _sidebarApp(fx, onOpenAiPanel: () => calls++),
      );

      await tester.tap(find.byKey(const ValueKey<String>('sidebar-ai')));
      await tester.pump();
      expect(calls, 1);
    });

    testWidgets('未接入 AI 面板时给出提示而非崩溃', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      await tester.tap(find.byKey(const ValueKey<String>('sidebar-ai')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('AI 面板由编辑页右上角按钮展开'), findsOneWidget);

      // 快进 SnackBar 生命周期，避免残留计时器。
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });

    testWidgets('设置行经 GoRouter 跳转设置页', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      final GoRouter router = GoRouter(
        initialLocation: '/',
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (BuildContext context, GoRouterState state) => const Scaffold(
              body: Row(
                children: <Widget>[
                  SizedBox(width: 240, child: Sidebar()),
                  VerticalDivider(width: 1),
                  Expanded(child: SizedBox.expand()),
                ],
              ),
            ),
          ),
          GoRoute(
            path: '/settings',
            builder: (BuildContext context, GoRouterState state) =>
                const Scaffold(body: Center(child: Text('设置页桩'))),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pumpSidebar(tester, _routerApp(fx, router));

      await tester.tap(find.byKey(const ValueKey<String>('sidebar-settings')));
      await tester.pumpAndSettle();
      expect(find.text('设置页桩'), findsOneWidget);
    });

    testWidgets('页面 / 图层分区可独立折叠', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      // 折叠页面分区：页面管理器移出树，图层区不受影响。
      await tester.tap(
        find.byKey(const ValueKey<String>('section-toggle-pages')),
      );
      await tester.pumpAndSettle();
      expect(find.text('添加页面'), findsNothing);
      expect(find.text('便签 1'), findsOneWidget);

      // 恢复页面分区。
      await tester.tap(
        find.byKey(const ValueKey<String>('section-toggle-pages')),
      );
      await tester.pumpAndSettle();
      expect(find.text('添加页面'), findsOneWidget);

      // 折叠图层分区。
      await tester.tap(
        find.byKey(const ValueKey<String>('section-toggle-layers')),
      );
      await tester.pumpAndSettle();
      expect(find.text('便签 1'), findsNothing);
      expect(find.text('添加页面'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // 页面管理（§4）
  // -------------------------------------------------------------------------

  group('页面管理', () {
    testWidgets('新建页面并点击卡片切换当前页', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));
      expect(fx.pages.pages.length, 1);

      await tester.tap(find.byKey(const ValueKey<String>('pages-add')));
      await tester.pumpAndSettle();
      expect(fx.pages.pages.length, 2);
      expect(fx.pages.currentPageId, 'b1-page-2');
      expect(find.text('页面 2'), findsWidgets);

      await tester.tap(
        find.byKey(const ValueKey<String>('page-card-b1-page-1')),
      );
      await tester.pumpAndSettle();
      expect(fx.pages.currentPageId, 'b1-page-1');
    });

    testWidgets('缩略图静态预览与手动刷新令牌递增', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      expect(find.text('0 元素'), findsOneWidget);
      final Finder thumb =
          find.byKey(const ValueKey<String>('page-thumb-b1-page-1'));
      final int before = tester.widget<PageThumbnail>(thumb).epoch;

      await tester.tap(find.byKey(const ValueKey<String>('pages-refresh')));
      await tester.pumpAndSettle();
      final int after = tester.widget<PageThumbnail>(thumb).epoch;
      expect(after, before + 1);
    });

    testWidgets('页面拖拽排序（第三页拖到第一页之前）', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      fx.pages.addPage();
      fx.pages.addPage();
      await _pumpSidebar(tester, _sidebarApp(fx));
      expect(fx.pages.pages.length, 3);

      final Finder handle =
          find.byKey(const ValueKey<String>('page-drag-b1-page-3'));
      final Offset from = tester.getCenter(handle);
      final Offset to = tester.getCenter(
        find.byKey(const ValueKey<String>('page-card-b1-page-1')),
      );
      await tester.drag(handle, to - from);
      await tester.pumpAndSettle();

      expect(
        fx.pages.pages.map((WbPage page) => page.id).toList(),
        <String>['b1-page-3', 'b1-page-1', 'b1-page-2'],
      );
    });

    testWidgets('右键菜单锁定 / 解锁 / 隐藏页面', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      await _openPageMenu(tester, 'b1-page-1');
      expect(find.text('锁定'), findsOneWidget);
      await tester.tap(find.text('锁定'));
      await tester.pumpAndSettle();
      expect(fx.pages.pages.first.locked, isTrue);

      await _openPageMenu(tester, 'b1-page-1');
      expect(find.text('解锁'), findsOneWidget);
      await tester.tap(find.text('解锁'));
      await tester.pumpAndSettle();
      expect(fx.pages.pages.first.locked, isFalse);

      await _openPageMenu(tester, 'b1-page-1');
      await tester.tap(find.text('隐藏'));
      await tester.pumpAndSettle();
      expect(fx.pages.pages.first.hidden, isTrue);
    });

    testWidgets('锁定页面禁止拖拽排序', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      fx.pages.addPage();
      await _pumpSidebar(tester, _sidebarApp(fx));

      await _openPageMenu(tester, 'b1-page-1');
      await tester.tap(find.text('锁定'));
      await tester.pumpAndSettle();
      expect(fx.pages.pages.first.locked, isTrue);

      final Finder handle =
          find.byKey(const ValueKey<String>('page-drag-b1-page-1'));
      final Offset from = tester.getCenter(handle);
      final Offset to = tester.getCenter(
        find.byKey(const ValueKey<String>('page-card-b1-page-2')),
      );
      await tester.drag(handle, to - from);
      await tester.pumpAndSettle();

      expect(
        fx.pages.pages.map((WbPage page) => page.id).toList(),
        <String>['b1-page-1', 'b1-page-2'],
      );
    });

    testWidgets('右键菜单重命名页面', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      await _openPageMenu(tester, 'b1-page-1');
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      expect(find.text('重命名页面'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '封面页');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(fx.pages.pages.first.name, '封面页');
      expect(find.text('封面页'), findsWidgets);
    });

    testWidgets('右键菜单复制页面', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      await _openPageMenu(tester, 'b1-page-1');
      await tester.tap(find.text('复制页面'));
      await tester.pumpAndSettle();

      expect(fx.pages.pages.length, 2);
      expect(fx.pages.pages[1].name, '页面 1 副本');
      expect(fx.pages.currentPageId, 'b1-page-1-copy-2');
    });

    testWidgets('右键菜单删除页面且最后一页不可删', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      fx.pages.addPage();
      await _pumpSidebar(tester, _sidebarApp(fx));

      await _openPageMenu(tester, 'b1-page-1');
      await tester.tap(find.text('删除页面'));
      await tester.pumpAndSettle();
      expect(fx.pages.pages.length, 1);
      expect(fx.pages.pages.single.id, 'b1-page-2');

      // 仅剩一页时删除项禁用。
      await _openPageMenu(tester, 'b1-page-2');
      final PopupMenuItem<String> item =
          tester.widget<PopupMenuItem<String>>(
        find.ancestor(
          of: find.text('删除页面'),
          matching: find.byType(PopupMenuItem<String>),
        ),
      );
      expect(item.enabled, isFalse);
    });

    testWidgets('Ctrl 多选并批量删除页面', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      fx.pages.addPage();
      fx.pages.addPage();
      await _pumpSidebar(tester, _sidebarApp(fx));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(
        find.byKey(const ValueKey<String>('page-card-b1-page-2')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('page-card-b1-page-3')),
      );
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('page-multi-b1-page-2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('page-multi-b1-page-3')),
        findsOneWidget,
      );

      await _openPageMenu(tester, 'b1-page-2');
      expect(find.text('删除 2 页'), findsOneWidget);
      await tester.tap(find.text('删除 2 页'));
      await tester.pumpAndSettle();

      expect(fx.pages.pages.length, 1);
      expect(fx.pages.pages.single.id, 'b1-page-1');
    });

    testWidgets('PageUp / PageDown 循环切换页面', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      fx.pages.addPage();
      fx.pages.addPage();
      await _pumpSidebar(tester, _sidebarApp(fx));
      expect(fx.pages.currentPageId, 'b1-page-3');

      // 点击卡片让页面列表获得焦点。
      await tester.tap(
        find.byKey(const ValueKey<String>('page-card-b1-page-3')),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(fx.pages.currentPageId, 'b1-page-2');

      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(fx.pages.currentPageId, 'b1-page-1');

      // 从第一页继续向上 -> 循环到最后一页。
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(fx.pages.currentPageId, 'b1-page-3');

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(fx.pages.currentPageId, 'b1-page-1');
    });

    testWidgets('F2 重命名当前页、Delete 删除选中页', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      fx.pages.addPage();
      await _pumpSidebar(tester, _sidebarApp(fx));

      await tester.tap(
        find.byKey(const ValueKey<String>('page-card-b1-page-2')),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.text('重命名页面'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(fx.pages.pages.length, 1);
      expect(fx.pages.pages.single.id, 'b1-page-1');
    });
  });

  // -------------------------------------------------------------------------
  // 图层区（§5）
  // -------------------------------------------------------------------------

  group('图层区', () {
    testWidgets('可见性与锁定按钮切换元素状态', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      final Finder visibleButton = find.byKey(
        const ValueKey<String>('layer-visible-b1-page-1-el-1'),
      );
      WbVisibilityIcon iconOf(Finder of) => tester.widget<WbVisibilityIcon>(
            find.descendant(of: of, matching: find.byType(WbVisibilityIcon)),
          );

      expect(iconOf(visibleButton).visible, isTrue);
      await tester.tap(visibleButton);
      await tester.pumpAndSettle();
      expect(iconOf(visibleButton).visible, isFalse);

      await tester.tap(
        find.byKey(const ValueKey<String>('layer-lock-b1-page-1-el-1')),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('解锁'), findsOneWidget);
    });

    testWidgets('图层拖拽排序（底层元素拖到最上）', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      final Finder handle =
          find.byKey(const ValueKey<String>('layer-drag-b1-page-1-el-1'));
      final Offset from = tester.getCenter(handle);
      final Offset to = tester.getCenter(
        find.byKey(const ValueKey<String>('layer-row-b1-page-1-el-3')),
      );
      await tester.drag(handle, to - from);
      await tester.pumpAndSettle();

      final double moved = tester
          .getTopLeft(
            find.byKey(const ValueKey<String>('layer-row-b1-page-1-el-1')),
          )
          .dy;
      final double other = tester
          .getTopLeft(
            find.byKey(const ValueKey<String>('layer-row-b1-page-1-el-3')),
          )
          .dy;
      expect(moved, lessThan(other));
    });

    testWidgets('图层右键菜单置于顶层', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      const Key el1Row = ValueKey<String>('layer-row-b1-page-1-el-1');
      const Key el3Row = ValueKey<String>('layer-row-b1-page-1-el-3');
      expect(
        tester.getTopLeft(find.byKey(el1Row)).dy,
        greaterThan(tester.getTopLeft(find.byKey(el3Row)).dy),
      );

      await tester.tap(
        find.byKey(el1Row),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('置于顶层'), findsOneWidget);
      await tester.tap(find.text('置于顶层'));
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byKey(el1Row)).dy,
        lessThan(tester.getTopLeft(find.byKey(el3Row)).dy),
      );
    });

    testWidgets('图层行双击进入重命名', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      final Finder row =
          find.byKey(const ValueKey<String>('layer-name-b1-page-1-el-2'));
      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(row);
      await tester.pump();

      final Finder field = find.byKey(
        const ValueKey<String>('layer-rename-b1-page-1-el-2'),
      );
      expect(field, findsOneWidget);

      await tester.enterText(field, '核心形状');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('核心形状'), findsOneWidget);

      // 冲掉双击识别计时器。
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('点击图层行联动选区状态', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      await tester.tap(
        find.byKey(const ValueKey<String>('layer-name-b1-page-1-el-2')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(fx.selection.ids, <String>{'b1-page-1-el-2'});

      final Container bar = tester.widget<Container>(
        find.byKey(const ValueKey<String>('layer-selected-b1-page-1-el-2')),
      );
      expect(bar.color, isNot(Colors.transparent));

      await tester.tap(
        find.byKey(const ValueKey<String>('layer-name-b1-page-1-el-3')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(fx.selection.ids, <String>{'b1-page-1-el-3'});
    });

    testWidgets('逐条删除元素后显示空态', (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      await _pumpSidebar(tester, _sidebarApp(fx));

      for (final String id in <String>[
        'b1-page-1-el-1',
        'b1-page-1-el-2',
        'b1-page-1-el-3',
      ]) {
        await tester.tap(find.byKey(ValueKey<String>('layer-menu-$id')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除'));
        await tester.pumpAndSettle();
      }

      expect(
        find.byKey(const ValueKey<String>('layers-empty')),
        findsOneWidget,
      );
      expect(find.text('暂无元素'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // M3 只读收窄（canEdit=false：页面 / 图层编辑入口统一拦截）
  // -------------------------------------------------------------------------

  group('M3 只读收窄 canEdit=false', () {
    testWidgets('页面编辑入口全部被拦（新建 / 菜单 / 快捷键 / 拖拽）',
        (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      fx.pages.addPage();
      int blocked = 0;
      await _pumpSidebar(
        tester,
        _sidebarApp(fx, canEdit: false, onBlockedEdit: () => blocked++),
      );
      expect(fx.pages.pages.length, 2);

      // 分区头「新建页面」。
      await tester.tap(find.byKey(const ValueKey<String>('pages-add')));
      await tester.pumpAndSettle();
      expect(fx.pages.pages.length, 2);

      // 底部「添加页面」。
      await tester.tap(find.text('添加页面'));
      await tester.pumpAndSettle();
      expect(fx.pages.pages.length, 2);

      // 右键菜单「复制页面」（编辑动作统一守卫）。
      await _openPageMenu(tester, 'b1-page-1');
      await tester.tap(find.text('复制页面'));
      await tester.pumpAndSettle();
      expect(fx.pages.pages.length, 2);

      // 键盘 F2 / Delete（选中页后触发）。
      await tester.tap(
        find.byKey(const ValueKey<String>('page-card-b1-page-2')),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.text('重命名页面'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(fx.pages.pages.length, 2);

      // 拖拽排序（maxSimultaneousDrags=0：顺序不变）。
      final Finder handle =
          find.byKey(const ValueKey<String>('page-drag-b1-page-2'));
      await tester.drag(handle, const Offset(0, -80));
      await tester.pumpAndSettle();
      expect(
        fx.pages.pages.map((WbPage page) => page.id).toList(),
        <String>['b1-page-1', 'b1-page-2'],
      );

      expect(blocked, 5);
    });

    testWidgets('图层面板行操作被拦（锁定 / 可见 / 重命名 / 菜单删除）',
        (WidgetTester tester) async {
      final _BoardFixture fx = _BoardFixture();
      addTearDown(fx.dispose);
      int blocked = 0;
      await _pumpSidebar(
        tester,
        _sidebarApp(fx, canEdit: false, onBlockedEdit: () => blocked++),
      );

      // 锁定按钮：点击后仍保持未锁定（tooltip 不变）。
      final Finder lockButton =
          find.byKey(const ValueKey<String>('layer-lock-b1-page-1-el-1'));
      expect(tester.widget<IconButton>(lockButton).tooltip, '锁定');
      await tester.tap(lockButton);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(lockButton).tooltip, '锁定');

      // 可见按钮：图标保持可见。
      final Finder visibleButton =
          find.byKey(const ValueKey<String>('layer-visible-b1-page-1-el-1'));
      WbVisibilityIcon iconOf(Finder of) => tester.widget<WbVisibilityIcon>(
            find.descendant(of: of, matching: find.byType(WbVisibilityIcon)),
          );
      expect(iconOf(visibleButton).visible, isTrue);
      await tester.tap(visibleButton);
      await tester.pumpAndSettle();
      expect(iconOf(visibleButton).visible, isTrue);

      // 双击进入重命名：被拦（未出现输入框）。
      final Finder name =
          find.byKey(const ValueKey<String>('layer-name-b1-page-1-el-2'));
      await tester.tap(name);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(name);
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('layer-rename-b1-page-1-el-2')),
        findsNothing,
      );

      // 行菜单「删除」：被拦（行保留）。
      await tester.tap(
        find.byKey(const ValueKey<String>('layer-menu-b1-page-1-el-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('layer-row-b1-page-1-el-1')),
        findsOneWidget,
      );

      expect(blocked, 4);
    });
  });
}
