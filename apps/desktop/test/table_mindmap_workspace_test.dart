/// 表格 / 思维导图全窗三区工作区 + 画布缩放测试
/// （第三轮缺陷修复 · 波次 B3 + B4）。
///
/// 覆盖：
/// - **表格（B3）**：全窗三区——左行列操作面板（`wb-ctx-table-left-panel`，
///   176 宽）/ 中最大化网格（`wb-ctx-table-grid-area`，双向滚动）/
///   右属性面板（`wb-ctx-table-right-panel`，240 宽）；左面板插入 / 删除
///   行列（作用于选中单元格所在行列，未选中时作用于末行末列并在 tooltip
///   注明）经 onChanged 上报模型验证；双击单元格进入就地编辑 + done 提交
///   回写；
/// - **思维导图（B4）**：全窗三区——左节点操作面板（`wb-ctx-mind-left-panel`，
///   176 宽）/ 中最大化预览（`wb-ctx-mind-preview-transform`）/
///   右属性面板（`wb-ctx-mind-right-panel`，240 宽）；工具条 + 滚轮缩放
///   （1.2 步进 / factor = exp(-dy/320)，clamp 0.25~3.0）；缩放后节点点选、
///   节点「+」加子节点、右键菜单、空白拖动平移与 pan 钳制稳定；
/// - 不再渲染旧的 420 宽面板卡片（[WbContextEditorShell] 与内嵌标题文案
///   均不存在，标题由宿主编辑页 AppBar 承担）。
///
/// 说明：编辑器自包含（无 Provider / 平台通道调用，测试无需 mock 通道）；
/// 手势驱动方式与 `flowchart_workspace_test.dart` / `context_editors_test.dart`
/// 保持一致。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/context_editors/context_editor_shell.dart';
import 'package:whiteboard_desktop/widgets/context_editors/mindmap_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/table_editor.dart';

// ---------------------------------------------------------------------------
// 测试基建
// ---------------------------------------------------------------------------

Key _key(String value) => ValueKey<String>(value);

/// 在 1600x1200 逻辑窗口中全窗挂载编辑器（三区布局需要足够宽度；无
/// Provider 环境）。
Future<void> _pumpEditor(WidgetTester tester, Widget editor) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: editor)));
  await tester.pump();
}

/// 从 [start] 开始的拖拽手势：第一次移动越过触摸 slop（`DragStartBehavior.start`
/// 不派发该段增量），第二次移动 [delta] 实际传递给 onPanUpdate。
Future<void> _dragFrom(
  WidgetTester tester,
  Offset start,
  Offset delta,
) async {
  final TestGesture gesture = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.moveBy(const Offset(36, 36));
  await tester.pump();
  await gesture.moveBy(delta);
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

/// 当前预览区缩放值（读取 `Transform.scale` 矩阵的 X 轴缩放）。
double _mindScaleOf(WidgetTester tester) {
  final Transform transform = tester.widget<Transform>(
    find.byKey(_key('wb-ctx-mind-preview-transform')),
  );
  return transform.transform.entry(0, 0);
}

/// 当前预览平移量（读取内容层 `Transform.translate` 矩阵的平移分量）。
Offset _mindPanOf(WidgetTester tester) {
  final Transform transform = tester.widget<Transform>(
    find.byKey(_key('wb-ctx-mind-preview-pan-layer')),
  );
  return Offset(
    transform.transform.entry(0, 3),
    transform.transform.entry(1, 3),
  );
}

/// 点击工具条缩放按钮 [times] 次（内部逐次 pump）。
Future<void> _tapZoom(WidgetTester tester, String key, {int times = 1}) async {
  for (int i = 0; i < times; i++) {
    await tester.tap(find.byKey(_key(key)));
    await tester.pump();
  }
}

/// 向中间预览区中心发送一次鼠标滚轮信号（dy < 0 放大）。
Future<void> _scrollPreview(WidgetTester tester, double dy) async {
  final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
  final Offset center =
      tester.getCenter(find.byKey(_key('wb-ctx-mind-preview-transform')));
  await tester.sendEventToBinding(pointer.hover(center));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

/// 读取图标按钮的 tooltip 文本（验证行列操作作用范围提示）。
String _tooltipOf(WidgetTester tester, String key) => tester
    .widget<WbEditorIconButton>(find.byKey(_key(key)))
    .tooltip!;

void main() {
  // -------------------------------------------------------------------------
  // B3 表格：全窗三区 + 行列操作
  // -------------------------------------------------------------------------

  group('表格全窗三区工作区（B3）', () {
    testWidgets('三区渲染：左操作 / 中网格 / 右属性，无 420 宽卡片', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(tester, const WbTableEditor());
      await tester.pump();

      // 三区容器就位（B3 固化的 ValueKey）。
      expect(find.byKey(_key('wb-ctx-table-left-panel')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-table-grid-area')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-table-grid')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-table-right-panel')), findsOneWidget);

      // 左 176 / 右 240 固定宽，中间网格吃满剩余宽度（>900，远超旧 420）。
      expect(
        tester.getSize(find.byKey(_key('wb-ctx-table-left-panel'))).width,
        176.0,
      );
      expect(
        tester.getSize(find.byKey(_key('wb-ctx-table-right-panel'))).width,
        240.0,
      );
      expect(
        tester.getSize(find.byKey(_key('wb-ctx-table-grid-area'))).width,
        greaterThan(900),
      );

      // 左面板六个行列操作按钮（固定 key）。
      const List<String> actionKeys = <String>[
        'wb-ctx-table-insert-row-above',
        'wb-ctx-table-insert-row-below',
        'wb-ctx-table-remove-row',
        'wb-ctx-table-insert-col-left',
        'wb-ctx-table-insert-col-right',
        'wb-ctx-table-remove-col',
      ];
      for (final String action in actionKeys) {
        expect(
          find.descendant(
            of: find.byKey(_key('wb-ctx-table-left-panel')),
            matching: find.byKey(_key(action)),
          ),
          findsOneWidget,
          reason: action,
        );
      }

      // 旧 420 宽面板卡片 / 内嵌第二标题栏不再渲染。
      expect(find.byType(WbContextEditorShell), findsNothing);
      expect(find.text('表格编辑器'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('左面板增删行列：未选中作用于末行 / 末列（tooltip 注明）', (
      WidgetTester tester,
    ) async {
      final List<WbTableModel> models = <WbTableModel>[];
      await _pumpEditor(tester, WbTableEditor(onChanged: models.add));
      await tester.pump();
      expect(models, isEmpty, reason: '初始不触发 onChanged');

      // 未选中时 tooltip 注明作用于末行 / 末列。
      expect(
        _tooltipOf(tester, 'wb-ctx-table-insert-row-above'),
        contains('末行'),
      );
      expect(_tooltipOf(tester, 'wb-ctx-table-remove-row'), contains('末行'));
      expect(
        _tooltipOf(tester, 'wb-ctx-table-insert-col-left'),
        contains('末列'),
      );
      expect(_tooltipOf(tester, 'wb-ctx-table-remove-col'), contains('末列'));

      // 末行上方插入行：3 → 4 行，新空行出现在末行之前。
      await tester.tap(find.byKey(_key('wb-ctx-table-insert-row-above')));
      await tester.pump();
      expect(models.last.rowCount, 4);
      expect(models.last.cellAt(2, 0), '');
      expect(models.last.cellAt(3, 0), '开发实现', reason: '原末行下移');

      // 末行下方插入行：4 → 5 行，追加到末尾。
      await tester.tap(find.byKey(_key('wb-ctx-table-insert-row-below')));
      await tester.pump();
      expect(models.last.rowCount, 5);
      expect(models.last.cellAt(3, 0), '开发实现');
      expect(models.last.cellAt(4, 0), '');

      // 删除末行（新空行）：5 → 4 行。
      await tester.tap(find.byKey(_key('wb-ctx-table-remove-row')));
      await tester.pump();
      expect(models.last.rowCount, 4);
      expect(models.last.cellAt(3, 0), '开发实现', reason: '删除新加的空行');

      // 末列左侧插入列：3 → 4 列，新空列出现在末列之前。
      await tester.tap(find.byKey(_key('wb-ctx-table-insert-col-left')));
      await tester.pump();
      expect(models.last.columnCount, 4);
      expect(models.last.cellAt(0, 2), '');
      expect(models.last.cellAt(0, 3), '状态', reason: '原末列右移');

      // 删除末列（原「状态」列）：4 → 3 列。
      await tester.tap(find.byKey(_key('wb-ctx-table-remove-col')));
      await tester.pump();
      expect(models.last.columnCount, 3);
      expect(models.last.cells[0], <String>['项目', '负责人', '']);

      // 末列右侧插入列：3 → 4 列，追加到末尾。
      await tester.tap(find.byKey(_key('wb-ctx-table-insert-col-right')));
      await tester.pump();
      expect(models.last.columnCount, 4);
      expect(models.last.cells[0], <String>['项目', '负责人', '', '']);
    });

    testWidgets('选中单元格后：行列增删作用于选中行 / 列（tooltip 更新）', (
      WidgetTester tester,
    ) async {
      final List<WbTableModel> models = <WbTableModel>[];
      await _pumpEditor(tester, WbTableEditor(onChanged: models.add));
      await tester.pump();

      // 选中 R2C1（需求评审）→ 行操作 tooltip 显示作用范围。
      await tester.tap(find.byKey(_key('wb-ctx-table-cell-1-0')));
      await tester.pump();
      expect(_tooltipOf(tester, 'wb-ctx-table-remove-row'), contains('R2'));
      expect(
        _tooltipOf(tester, 'wb-ctx-table-insert-row-below'),
        isNot(contains('末行')),
      );

      // 选中行下方插入：新空行出现在 R2 之后。
      await tester.tap(find.byKey(_key('wb-ctx-table-insert-row-below')));
      await tester.pump();
      expect(models.last.rowCount, 4);
      expect(models.last.cellAt(1, 0), '需求评审');
      expect(models.last.cellAt(2, 0), '');
      expect(models.last.cellAt(3, 0), '开发实现');

      // 删除选中行（R2）：4 → 3 行。
      await tester.tap(find.byKey(_key('wb-ctx-table-remove-row')));
      await tester.pump();
      expect(models.last.rowCount, 3);
      expect(models.last.cells[1], <String>['', '', '']);
      expect(models.last.cellAt(2, 0), '开发实现');

      // 选中 R1C2（负责人列）→ 列操作 tooltip 显示作用范围。
      await tester.tap(find.byKey(_key('wb-ctx-table-cell-0-1')));
      await tester.pump();
      expect(_tooltipOf(tester, 'wb-ctx-table-remove-col'), contains('C2'));

      // 选中列右侧插入：新空列出现在 C2 之后。
      await tester.tap(find.byKey(_key('wb-ctx-table-insert-col-right')));
      await tester.pump();
      expect(models.last.columnCount, 4);
      expect(models.last.cellAt(0, 2), '');
      expect(models.last.cellAt(0, 3), '状态');

      // 删除选中列（C2）：「负责人」列被删除。
      await tester.tap(find.byKey(_key('wb-ctx-table-remove-col')));
      await tester.pump();
      expect(models.last.columnCount, 3);
      expect(models.last.cells[0], <String>['项目', '', '状态']);
    });

    testWidgets('双击单元格进入编辑：done 提交后退出编辑态并回写', (
      WidgetTester tester,
    ) async {
      final List<WbTableModel> models = <WbTableModel>[];
      await _pumpEditor(tester, WbTableEditor(onChanged: models.add));
      await tester.pump();

      // 双击（两次连续点击）进入输入框（单击 / 双击均可，见 _beginEdit）。
      final Finder cell = find.byKey(_key('wb-ctx-table-cell-1-0'));
      await tester.tap(cell);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(cell);
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-table-cell-edit')), findsOneWidget);

      await tester.enterText(
        find.byKey(_key('wb-ctx-table-cell-edit')),
        '王五',
      );
      await tester.pump();
      expect(models.last.cellAt(1, 0), '王五');
      expect(models.last.cellAt(1, 1), '张三', reason: '其他单元格不受影响');

      // 回车（done）提交：退出编辑态，模型保留新值。
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-table-cell-edit')), findsNothing);
      expect(models.last.cellAt(1, 0), '王五');
    });
  });

  // -------------------------------------------------------------------------
  // B4 思维导图：全窗三区 + 画布缩放
  // -------------------------------------------------------------------------

  group('思维导图全窗三区工作区（B4）', () {
    testWidgets('三区渲染：左节点操作 / 中最大化预览 / 右属性 + 缩放控件', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(tester, const WbMindmapEditor());
      await tester.pump();

      // 三区容器就位（B4 固化的 ValueKey）。
      expect(find.byKey(_key('wb-ctx-mind-left-panel')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-mind-preview-transform')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-mind-right-panel')), findsOneWidget);

      // 左 176 / 右 240 固定宽，中间预览吃满剩余宽度（>900，远超旧 420）。
      expect(
        tester.getSize(find.byKey(_key('wb-ctx-mind-left-panel'))).width,
        176.0,
      );
      expect(
        tester.getSize(find.byKey(_key('wb-ctx-mind-right-panel'))).width,
        240.0,
      );
      expect(
        tester
            .getSize(find.byKey(_key('wb-ctx-mind-preview-transform')))
            .width,
        greaterThan(900),
      );

      // 左面板：节点操作 + 布局风格（既有 key 随控件搬家）。
      const List<String> leftKeys = <String>[
        'wb-ctx-mind-add',
        'wb-ctx-mind-delete',
        'wb-ctx-mind-collapse',
        'wb-ctx-mind-rename',
        'wb-ctx-mind-layout-right',
        'wb-ctx-mind-layout-tree',
        'wb-ctx-mind-layout-both',
      ];
      for (final String action in leftKeys) {
        expect(
          find.descendant(
            of: find.byKey(_key('wb-ctx-mind-left-panel')),
            matching: find.byKey(_key(action)),
          ),
          findsOneWidget,
          reason: action,
        );
      }
      expect(find.text('6 节点 · 逻辑图（向右）'), findsOneWidget);

      // 缩放控件：- / 百分比 / + / 重置。
      expect(find.byKey(_key('wb-ctx-mind-zoom-out')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-mind-zoom-in')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-mind-zoom-reset')), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);

      // 示例树渲染在最大化预览上。
      expect(find.byKey(_key('wb-ctx-mind-node-m1')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-mind-node-m6')), findsOneWidget);

      // 旧 420 宽面板卡片 / 内嵌第二标题栏不再渲染。
      expect(find.byType(WbContextEditorShell), findsNothing);
      expect(find.text('思维导图编辑器'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('工具条缩放：+ 放大 120% / − 回退 / 重置 100% / clamp 25%~300%', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(tester, const WbMindmapEditor());
      await tester.pump();
      expect(_mindScaleOf(tester), closeTo(1.0, 1e-6));

      await _tapZoom(tester, 'wb-ctx-mind-zoom-in');
      expect(find.text('120%'), findsOneWidget);
      expect(_mindScaleOf(tester), closeTo(1.2, 1e-6));

      await _tapZoom(tester, 'wb-ctx-mind-zoom-out');
      expect(find.text('100%'), findsOneWidget);
      expect(_mindScaleOf(tester), closeTo(1.0, 1e-6));

      // 连续放大：clamp 到上限 300% 后不再增长。
      await _tapZoom(tester, 'wb-ctx-mind-zoom-in', times: 12);
      expect(find.text('300%'), findsOneWidget);
      expect(_mindScaleOf(tester), closeTo(3.0, 1e-6));

      // 重置回 100%。
      await _tapZoom(tester, 'wb-ctx-mind-zoom-reset');
      expect(find.text('100%'), findsOneWidget);
      expect(_mindScaleOf(tester), closeTo(1.0, 1e-6));

      // 连续缩小：clamp 到下限 25% 后不再下降。
      await _tapZoom(tester, 'wb-ctx-mind-zoom-out', times: 12);
      expect(find.text('25%'), findsOneWidget);
      expect(_mindScaleOf(tester), closeTo(0.25, 1e-6));
    });

    testWidgets('滚轮缩放：factor = exp(-dy/320)，clamp 0.25~3.0', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(tester, const WbMindmapEditor());
      await tester.pump();

      // 上滚 160：exp(0.5) ≈ 1.6487 → 165%。
      await _scrollPreview(tester, -160);
      expect(find.text('165%'), findsOneWidget);
      expect(_mindScaleOf(tester), closeTo(math.exp(0.5), 1e-6));

      // 大幅下滚：clamp 到下限 25%。
      await _scrollPreview(tester, 2000);
      expect(find.text('25%'), findsOneWidget);
      expect(_mindScaleOf(tester), closeTo(0.25, 1e-6));

      // 大幅上滚：clamp 到上限 300%。
      await _scrollPreview(tester, -4000);
      expect(find.text('300%'), findsOneWidget);
      expect(_mindScaleOf(tester), closeTo(3.0, 1e-6));

      // 反向对称：下滚 160 → 300% × exp(-0.5) ≈ 181.96% → 182%。
      await _scrollPreview(tester, 160);
      expect(find.text('182%'), findsOneWidget);
      expect(_mindScaleOf(tester), closeTo(3 * math.exp(-0.5), 1e-6));
    });

    testWidgets('节点「+」添加子节点 +1，左面板删除 -1', (WidgetTester tester) async {
      final List<WbMindNode> roots = <WbMindNode>[];
      await _pumpEditor(tester, WbMindmapEditor(onChanged: roots.add));
      await tester.pump();
      expect(roots, isEmpty, reason: '初始不触发 onChanged');

      // 节点旁「+」：为 m6 添加子节点 → 6 → 7，新节点自动选中。
      await tester.tap(find.byKey(_key('wb-ctx-mind-node-add-m6')));
      await tester.pump();
      expect(roots.last.count, 7);
      expect(roots.last.nodeById('m6')!.children.length, 1);

      // 左面板删除：作用于新选中的子节点 → 7 → 6。
      await tester.tap(find.byKey(_key('wb-ctx-mind-delete')));
      await tester.pump();
      expect(roots.last.count, 6);
      expect(roots.last.nodeById('m6')!.children, isEmpty);
    });

    testWidgets('144% 缩放后：节点点选 / 「+」/ 右键菜单仍正常', (
      WidgetTester tester,
    ) async {
      final List<WbMindNode> roots = <WbMindNode>[];
      await _pumpEditor(tester, WbMindmapEditor(onChanged: roots.add));
      await tester.pump();

      await _tapZoom(tester, 'wb-ctx-mind-zoom-in', times: 2);
      expect(find.text('144%'), findsOneWidget);
      expect(_mindScaleOf(tester), closeTo(1.44, 1e-6));

      // 节点单击选中：m6（144% 下仍完整可见；命中测试自动逆变换）。
      await tester.tap(find.byKey(_key('wb-ctx-mind-node-m6')));
      await tester.pump();
      expect(find.text('选中：分支 C'), findsOneWidget);

      // 节点旁「+」：绘制在缩放后的位置，点击仍命中。
      await tester.tap(find.byKey(_key('wb-ctx-mind-node-add-m6')));
      await tester.pump();
      expect(roots.last.count, 7);
      expect(roots.last.nodeById('m6')!.children.length, 1);

      // 右键菜单：次键点击节点 → 菜单弹出并继续添加子节点。
      await tester.tap(
        find.byKey(_key('wb-ctx-mind-node-m6')),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_key('wb-ctx-mind-menu-add-child')), findsOneWidget);

      await tester.tap(find.byKey(_key('wb-ctx-mind-menu-add-child')));
      await tester.pumpAndSettle();
      expect(roots.last.count, 8);
      expect(roots.last.nodeById('m6')!.children.length, 2);
    });

    testWidgets('144% 缩放后空白拖动平移：内容跟随指针，钳制稳定有界', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(tester, const WbMindmapEditor());
      await tester.pump();
      expect(_mindPanOf(tester), Offset.zero);

      await _tapZoom(tester, 'wb-ctx-mind-zoom-in', times: 2);
      expect(find.text('144%'), findsOneWidget);

      // 记录 m6 的屏幕位置，用于验证内容与指针同步移动。
      final Finder nodeM6 = find.byKey(_key('wb-ctx-mind-node-m6'));
      final Offset before = tester.getTopLeft(nodeM6);

      // 从预览空白处拖动（避开节点）：空白为唯一手势成员，识别器在按下
      // 时即胜出，两段移动的 delta 均派发（无 slop 消耗）——指针总位移
      // 36 + 36 = 72，局部平移 = 72 / 1.44 = 50。
      final Finder preview = find.byKey(_key('wb-ctx-mind-preview-transform'));
      final Offset blank = tester.getCenter(preview) + const Offset(200, 200);
      await _dragFrom(tester, blank, const Offset(36, 36));

      final Offset pan = _mindPanOf(tester);
      expect(pan.dx, closeTo(72 / 1.44, 0.9));
      expect(pan.dy, closeTo(72 / 1.44, 0.9));
      // 视觉位移 ≈ 指针位移（Transform.scale 命中测试自动逆变换）。
      final Offset after = tester.getTopLeft(nodeM6);
      expect(after.dx - before.dx, closeTo(72, 1.5));
      expect(after.dy - before.dy, closeTo(72, 1.5));

      // 连续大幅拖动：pan 收敛到钳制边界（按缩放后可视尺寸折算：
      // 水平 ≈ 933.4 / 垂直 ≈ 908.8），且重复拖动保持稳定、不跳变。
      await _dragFrom(tester, blank, const Offset(2000, 2000));
      final Offset clamped = _mindPanOf(tester);
      expect(clamped.dx, closeTo(933.4, 3));
      expect(clamped.dy, closeTo(908.8, 3));
      await _dragFrom(tester, blank, const Offset(2000, 2000));
      expect(_mindPanOf(tester), clamped, reason: '钳制后重复拖动保持稳定');
    });
  });
}
