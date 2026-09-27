/// 画布深度交互测试（Wave 3.4）：
/// 视口变换 / 指针手势 / 工具创建 / 选择与框选 / 编辑命令与撤销 /
/// 文本编辑 / 迷你地图 / 缩放控件 / 快捷键（控制器单元 + Widget 两级）。
///
/// 说明：不含 golden 截图断言（跨平台字体差异）；全部通过
/// finder / gesture / 键盘事件驱动。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_desktop/state/selection_state.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';
import 'package:whiteboard_desktop/widgets/canvas/minimap.dart';
import 'package:whiteboard_desktop/widgets/canvas_view.dart';

// ---- 测试基建 -------------------------------------------------------------

const Size _window = Size(1600, 1000);
const Offset _viewportCenter = Offset(800, 500);
const Size _noteDefault = Size(180, 120);

/// 预置两个便签元素（a：0,0,100x100；b：200,0,100x100）。
void _seedTwoNotes(WbCanvasController c) {
  c.document.upsert(
    '',
    const WbCanvasElement(
      id: 'a',
      type: WbElementKind.note,
      x: 0,
      y: 0,
      width: 100,
      height: 100,
      zIndex: 1,
    ),
  );
  c.document.upsert(
    '',
    const WbCanvasElement(
      id: 'b',
      type: WbElementKind.note,
      x: 200,
      y: 0,
      width: 100,
      height: 100,
      zIndex: 2,
    ),
  );
}

/// 在 1600x1000 窗口中挂载 `CanvasView`（可注入控制器 / 选区）。
Future<void> _pumpCanvas(
  WidgetTester tester, {
  WbCanvasController? controller,
  WbSelectionState? selection,
}) async {
  tester.view.physicalSize = _window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CanvasView(controller: controller, selection: selection),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  // -------------------------------------------------------------------------
  // 控制器：视口 / 手势
  // -------------------------------------------------------------------------

  group('WbCanvasController 视口', () {
    test('世界 ↔ 屏幕换算往返一致，zoomAt 保持焦点世界坐标', () {
      final WbCanvasController c = WbCanvasController();
      c.setViewportSize(const Size(800, 600));
      c.zoomAt(Offset.zero, 2);
      c.panBy(const Offset(30, -10));

      const Offset world = Offset(123.5, -42.25);
      final Offset screen = c.worldToScreen(world);
      final Offset back = c.screenToWorld(screen);
      expect(back.dx, closeTo(world.dx, 1e-9));
      expect(back.dy, closeTo(world.dy, 1e-9));

      const Offset focal = Offset(400, 300);
      final Offset before = c.screenToWorld(focal);
      c.zoomAt(focal, 2.4);
      final Offset after = c.screenToWorld(focal);
      expect(c.scale, 2.4);
      expect(after.dx, closeTo(before.dx, 1e-9));
      expect(after.dy, closeTo(before.dy, 1e-9));
    });

    test('缩放范围钳制在 0.1 ~ 8，resetView 归位', () {
      final WbCanvasController c = WbCanvasController();
      c.zoomAt(Offset.zero, 100);
      expect(c.scale, WbCanvasController.maxScale);
      c.zoomAt(Offset.zero, 0.0001);
      expect(c.scale, WbCanvasController.minScale);
      c.panBy(const Offset(50, 60));
      c.resetView();
      expect(c.scale, 1);
      expect(c.offset, Offset.zero);
    });

    test('滚轮：普通平移 / Shift 水平 / Ctrl 聚焦缩放', () {
      final WbCanvasController c = WbCanvasController();
      c.setViewportSize(const Size(800, 600));

      c.handleScroll(const Offset(100, 100), const Offset(10, 20), ctrl: false);
      expect(c.offset, const Offset(-10, -20));

      c.handleScroll(
        const Offset(100, 100),
        const Offset(0, 15),
        ctrl: false,
        shift: true,
      );
      // Shift 将垂直滚动转为水平平移（dx -= 15）。
      expect(c.offset, const Offset(-25, -20));

      const Offset focal = Offset(200, 150);
      final Offset before = c.screenToWorld(focal);
      c.handleScroll(focal, const Offset(0, 320), ctrl: true);
      expect(c.scale, closeTo(1 / math.e, 1e-6));
      expect(c.screenToWorld(focal).dx, closeTo(before.dx, 1e-6));
    });

    test('fitToContent 使内容完整可见', () {
      final WbCanvasController c = WbCanvasController();
      c.setViewportSize(const Size(800, 600));
      c.document.upsert(
        '',
        const WbCanvasElement(
          id: 'big',
          type: WbElementKind.shape,
          x: 0,
          y: 0,
          width: 1000,
          height: 800,
        ),
      );
      c.fitToContent();
      expect(c.scale, lessThan(1));
      final Rect visible = c.visibleWorldRect;
      expect(visible.contains(const Offset(500, 400)), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // 控制器：工具创建 / 笔迹
  // -------------------------------------------------------------------------

  group('WbCanvasController 工具', () {
    test('便签工具：点击创建默认尺寸并自动进入编辑', () {
      final WbCanvasController c = WbCanvasController();
      c.setViewportSize(const Size(800, 600));
      c.setTool(WbCanvasTool.note);
      c.handlePointerDown(1, _viewportCenter, shift: false);
      c.handlePointerUp(1, _viewportCenter);

      expect(c.elements.length, 1);
      final WbCanvasElement e = c.elements.single;
      expect(e.type, WbElementKind.note);
      expect(e.width, _noteDefault.width);
      expect(e.height, _noteDefault.height);
      expect(e.x, _viewportCenter.dx - _noteDefault.width / 2);
      expect(e.y, _viewportCenter.dy - _noteDefault.height / 2);
      expect(c.editingElementId, e.id);
    });

    test('便签工具：拖拽创建使用拖拽矩形', () {
      final WbCanvasController c = WbCanvasController();
      c.setTool(WbCanvasTool.note);
      c.handlePointerDown(1, const Offset(100, 100), shift: false);
      c.handlePointerMove(1, const Offset(320, 260));
      expect(c.createPreview, isNotNull);
      c.handlePointerUp(1, const Offset(320, 260));

      final WbCanvasElement e = c.elements.single;
      expect(e.bounds, const Rect.fromLTWH(100, 100, 220, 160));
      expect(c.createPreview, isNull);
    });

    test('形状工具：创建形状元素（无文本编辑）', () {
      final WbCanvasController c = WbCanvasController();
      c.setTool(WbCanvasTool.shape);
      c.setShapeKind(WbShapeKind.ellipse);
      c.handlePointerDown(1, const Offset(10, 10), shift: false);
      c.handlePointerMove(1, const Offset(210, 130));
      c.handlePointerUp(1, const Offset(210, 130));

      final WbCanvasElement e = c.elements.single;
      expect(e.type, WbElementKind.shape);
      expect(e.shapeKind, WbShapeKindId.ellipse);
      expect(c.editingElementId, isNull);
    });

    test('画笔工具：拖拽生成自由笔迹并可撤销', () {
      final WbCanvasController c = WbCanvasController();
      c.setTool(WbCanvasTool.pen);
      c.handlePointerDown(1, const Offset(50, 50), shift: false);
      c.handlePointerMove(1, const Offset(80, 90));
      c.handlePointerMove(1, const Offset(120, 60));
      expect(c.pendingStroke, isNotNull);
      c.handlePointerUp(1, const Offset(160, 100));

      final WbCanvasElement e = c.elements.single;
      expect(e.type, WbElementKind.drawing);
      expect(e.points.length, greaterThanOrEqualTo(3));
      expect(c.pendingStroke, isNull);
      expect(c.canUndo, isTrue);

      c.undo();
      expect(c.elements, isEmpty);
    });

    test('橡皮擦：拖过元素即删除并可撤销', () {
      final WbCanvasController c = WbCanvasController();
      _seedTwoNotes(c);
      c.setTool(WbCanvasTool.eraser);
      c.handlePointerDown(1, const Offset(50, 50), shift: false);
      c.handlePointerUp(1, const Offset(50, 50));
      expect(c.elements.length, 1);
      expect(c.document.byId('', 'a'), isNull);

      c.undo();
      expect(c.elements.length, 2);
      expect(c.document.byId('', 'a'), isNotNull);
    });

    test('连线工具：拖拽创建连线元素（起止点 + 预览 + 撤销）', () {
      final WbCanvasController c = WbCanvasController();
      c.setTool(WbCanvasTool.connector);
      c.handlePointerDown(1, const Offset(100, 100), shift: false);
      expect(c.connectorPreviewStart, const Offset(100, 100));
      c.handlePointerMove(1, const Offset(300, 200));
      expect(c.connectorPreviewEnd, const Offset(300, 200));
      c.handlePointerUp(1, const Offset(300, 200));

      final WbCanvasElement e = c.elements.single;
      expect(e.type, WbElementKind.connector);
      expect(e.points.first, const Offset(100, 100));
      expect(e.points.last, const Offset(300, 200));
      expect(e.bounds, const Rect.fromLTWH(100, 100, 200, 100));
      expect(c.connectorPreviewStart, isNull);
      expect(c.canUndo, isTrue);

      c.undo();
      expect(c.elements, isEmpty);
    });

    test('连线工具：点击创建默认水平连线', () {
      final WbCanvasController c = WbCanvasController();
      c.setTool(WbCanvasTool.connector);
      c.handlePointerDown(1, const Offset(50, 50), shift: false);
      c.handlePointerUp(1, const Offset(51, 50));

      final WbCanvasElement e = c.elements.single;
      expect(e.type, WbElementKind.connector);
      expect(e.points.first, const Offset(50, 50));
      expect(e.points.last, const Offset(250, 50));
    });

    test('连线：移动时起止点随外接矩形同步平移并可撤销', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      c.document.upsert(
        '',
        const WbCanvasElement(
          id: 'l1',
          type: WbElementKind.connector,
          x: 100,
          y: 100,
          width: 200,
          height: 100,
          zIndex: 1,
          points: <Offset>[Offset(100, 100), Offset(300, 200)],
        ),
      );
      c.selectAll();
      c.handlePointerDown(2, const Offset(200, 150), shift: false);
      c.handlePointerMove(2, const Offset(220, 160));
      final WbCanvasElement moved = c.elements.single;
      expect(moved.points.first, const Offset(120, 110));
      expect(moved.points.last, const Offset(320, 210));
      c.handlePointerUp(2, const Offset(220, 160));

      c.undo();
      expect(c.elements.single.points.first, const Offset(100, 100));
    });

    test('连线命中：仅线附近可命中（bounds 内远离线不命中）', () {
      final WbCanvasController c = WbCanvasController();
      c.document.upsert(
        '',
        const WbCanvasElement(
          id: 'l1',
          type: WbElementKind.connector,
          x: 100,
          y: 100,
          width: 200,
          height: 100,
          zIndex: 1,
          points: <Offset>[Offset(100, 100), Offset(300, 200)],
        ),
      );
      expect(c.hitTestElement(const Offset(200, 150))?.id, 'l1');
      expect(c.hitTestElement(const Offset(200, 190)), isNull);
      expect(c.hitTestElement(const Offset(400, 300)), isNull);
    });

    test('平行四边形：形状工具创建 parallelogram 子类型', () {
      final WbCanvasController c = WbCanvasController();
      c.setTool(WbCanvasTool.shape);
      c.setShapeKind(WbShapeKind.parallelogram);
      c.handlePointerDown(1, const Offset(20, 20), shift: false);
      c.handlePointerMove(1, const Offset(180, 140));
      c.handlePointerUp(1, const Offset(180, 140));

      final WbCanvasElement e = c.elements.single;
      expect(e.type, WbElementKind.shape);
      expect(e.shapeKind, WbShapeKindId.parallelogram);
    });
  });

  // -------------------------------------------------------------------------
  // 控制器：选择 / 移动 / 缩放
  // -------------------------------------------------------------------------

  group('WbCanvasController 选择与变换', () {
    test('点选 / Shift 加选 / 空白清除 / 框选', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      c.setViewportSize(const Size(800, 600));
      _seedTwoNotes(c);

      c.handlePointerDown(1, const Offset(50, 50), shift: false);
      c.handlePointerUp(1, const Offset(50, 50));
      expect(sel.ids, <String>{'a'});

      c.handlePointerDown(2, const Offset(250, 50), shift: true);
      c.handlePointerUp(2, const Offset(250, 50));
      expect(sel.ids, <String>{'a', 'b'});

      c.handlePointerDown(3, const Offset(600, 400), shift: false);
      c.handlePointerUp(3, const Offset(600, 400));
      expect(sel.isEmpty, isTrue);

      c.handlePointerDown(4, const Offset(-50, -50), shift: false);
      c.handlePointerMove(4, const Offset(350, 150));
      expect(c.marqueeRect, isNotNull);
      c.handlePointerUp(4, const Offset(350, 150));
      expect(sel.ids, <String>{'a', 'b'});
      expect(c.marqueeRect, isNull);
    });

    test('拖拽移动选中元素并撤销 / 重做', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      _seedTwoNotes(c);
      sel.select(<String>['a']);

      c.handlePointerDown(1, const Offset(50, 50), shift: false);
      c.handlePointerMove(1, const Offset(150, 130));
      c.handlePointerUp(1, const Offset(150, 130));

      final WbCanvasElement moved = c.document.byId('', 'a')!;
      expect(moved.x, closeTo(100, 1e-9));
      expect(moved.y, closeTo(80, 1e-9));
      expect(c.canUndo, isTrue);

      c.undo();
      expect(c.document.byId('', 'a')!.x, 0);
      c.redo();
      expect(c.document.byId('', 'a')!.x, closeTo(100, 1e-9));
    });

    test('拖拽右下缩放柄改变元素尺寸（锚定左上角）', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      _seedTwoNotes(c);
      sel.select(<String>['a']);

      final Rect rect = c.worldRectToScreen(const Rect.fromLTWH(0, 0, 100, 100));
      final Offset handle =
          WbCanvasController.handlePosition(WbSelectionHandle.bottomRight, rect);
      expect(handle, const Offset(100, 100));

      c.handlePointerDown(1, handle, shift: false);
      c.handlePointerMove(1, const Offset(160, 140));
      c.handlePointerUp(1, const Offset(160, 140));

      final WbCanvasElement scaled = c.document.byId('', 'a')!;
      expect(scaled.x, 0);
      expect(scaled.y, 0);
      expect(scaled.width, closeTo(160, 1e-9));
      expect(scaled.height, closeTo(140, 1e-9));
    });

    test('笔迹元素：移动 / 缩放同步更新 points（第三轮问题 3）', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      c.setTool(WbCanvasTool.pen);
      c.handlePointerDown(1, const Offset(40, 40), shift: false);
      c.handlePointerMove(1, const Offset(140, 80));
      c.handlePointerUp(1, const Offset(140, 80));

      final WbCanvasElement stroke = c.elements.single;
      expect(stroke.type, WbElementKind.drawing);
      final String id = stroke.id;
      c.setTool(WbCanvasTool.select);
      sel.select(<String>[id]);

      // 沿笔迹路径点住拖动（避开选择柄）：x/y 与 points 同步平移。
      c.handlePointerDown(2, const Offset(90, 60), shift: false);
      c.handlePointerMove(2, const Offset(160, 120));
      c.handlePointerUp(2, const Offset(160, 120));

      final WbCanvasElement moved = c.document.byId('', id)!;
      expect(moved.x, closeTo(110, 1e-9));
      expect(moved.y, closeTo(100, 1e-9));
      expect(moved.points.first, const Offset(110, 100));
      expect(moved.points.last, const Offset(210, 140));

      // 拖拽右下缩放柄 ×2：points 随外接矩形同一线性映射。
      final Rect rect = c.worldRectToScreen(moved.bounds);
      final Offset handle = WbCanvasController.handlePosition(
        WbSelectionHandle.bottomRight,
        rect,
      );
      c.handlePointerDown(3, handle, shift: false);
      c.handlePointerMove(3, handle + Offset(moved.width, moved.height));
      c.handlePointerUp(3, handle + Offset(moved.width, moved.height));

      final WbCanvasElement scaled = c.document.byId('', id)!;
      expect(scaled.width, closeTo(moved.width * 2, 1e-9));
      expect(scaled.height, closeTo(moved.height * 2, 1e-9));
      expect(scaled.points.first, const Offset(110, 100));
      expect(scaled.points.last, const Offset(310, 180));
    });

    test('选择框内部空白按下：整体拖动而非框选（第三轮问题 3）', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      c.setViewportSize(const Size(800, 600));
      _seedTwoNotes(c);
      sel.select(<String>['a', 'b']);

      // 单击框内空白：不改变选择、不进入框选。
      c.handlePointerDown(1, const Offset(150, 50), shift: false);
      expect(c.marqueeRect, isNull);
      c.handlePointerUp(1, const Offset(150, 50));
      expect(sel.ids, <String>{'a', 'b'});

      // 框内空白拖拽：整体平移两个元素。
      c.handlePointerDown(2, const Offset(150, 50), shift: false);
      c.handlePointerMove(2, const Offset(190, 70));
      c.handlePointerUp(2, const Offset(190, 70));
      expect(sel.ids, <String>{'a', 'b'});
      expect(c.document.byId('', 'a')!.x, closeTo(40, 1e-9));
      expect(c.document.byId('', 'a')!.y, closeTo(20, 1e-9));
      expect(c.document.byId('', 'b')!.x, closeTo(240, 1e-9));

      // 框外按下仍进入框选。
      c.handlePointerDown(3, const Offset(600, 400), shift: false);
      c.handlePointerMove(3, const Offset(700, 500));
      expect(c.marqueeRect, isNotNull);
      c.handlePointerUp(3, const Offset(700, 500));
    });

    test('编辑命令：全选 / 复制粘贴 / 删除 / 方向键微调', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      _seedTwoNotes(c);

      c.handleShortcut(LogicalKeyboardKey.keyA, ctrl: true);
      expect(sel.count, 2);

      c.copySelection();
      c.pasteClipboard();
      expect(c.elements.length, 4);
      expect(sel.count, 2);
      expect(c.canUndo, isTrue);

      c.deleteSelected();
      expect(c.elements.length, 2);
      expect(sel.isEmpty, isTrue);

      sel.select(<String>['a']);
      c.handleShortcut(LogicalKeyboardKey.arrowRight, shift: true);
      expect(c.document.byId('', 'a')!.x, 10);
      c.handleShortcut(LogicalKeyboardKey.arrowDown, shift: false);
      expect(c.document.byId('', 'a')!.y, 1);
    });

    test('快捷键：Ctrl+0 复位、Ctrl+1 适应内容、加减缩放', () {
      final WbCanvasController c = WbCanvasController();
      c.setViewportSize(const Size(800, 600));
      c.zoomAt(Offset.zero, 3);
      c.handleShortcut(LogicalKeyboardKey.digit0, ctrl: true);
      expect(c.scale, 1);
      expect(c.offset, Offset.zero);

      c.document.upsert(
        '',
        const WbCanvasElement(
          id: 'big',
          type: WbElementKind.shape,
          x: 0,
          y: 0,
          width: 1000,
          height: 800,
        ),
      );
      c.handleShortcut(LogicalKeyboardKey.digit1, ctrl: true);
      expect(c.scale, lessThan(1));

      final double before = c.scale;
      c.handleShortcut(LogicalKeyboardKey.equal, ctrl: true);
      expect(c.scale, greaterThan(before));
      c.handleShortcut(LogicalKeyboardKey.minus, ctrl: true);
      expect(c.scale, closeTo(before, 1e-9));
    });
  });

  // -------------------------------------------------------------------------
  // 控制器：文本编辑
  // -------------------------------------------------------------------------

  group('WbCanvasController 文本编辑', () {
    test('双击进入编辑 / 提交文本 / 空文本清理元素', () {
      final WbCanvasController c = WbCanvasController();
      _seedTwoNotes(c);

      c.handleDoubleClick(const Offset(50, 50));
      expect(c.editingElementId, 'a');
      c.updateEditingText('会议纪要');
      expect(c.document.byId('', 'a')!.text, '会议纪要');

      c.commitTextEditing('会议纪要');
      expect(c.editingElementId, isNull);
      expect(c.document.byId('', 'a')!.text, '会议纪要');

      // 空文本提交：元素被清理。
      c.handleDoubleClick(const Offset(50, 50));
      c.commitTextEditing('');
      expect(c.document.byId('', 'a'), isNull);
      expect(c.editingElementId, isNull);
    });

    test('双击空白处复位视图（scale=1 / offset=0）', () {
      final WbCanvasController c = WbCanvasController();
      c.setViewportSize(const Size(800, 600));
      c.zoomAt(Offset.zero, 2.5);
      c.panBy(const Offset(40, 40));
      c.handleDoubleClick(const Offset(400, 300));
      expect(c.scale, 1);
      expect(c.offset, Offset.zero);
    });
  });

  // -------------------------------------------------------------------------
  // 控制器：专业元素双击激活（问题 6）
  // -------------------------------------------------------------------------

  group('WbCanvasController 专业元素双击', () {
    test('双击专业元素触发 onElementActivate（非专业元素不触发）', () async {
      final List<WbCanvasElement> activated = <WbCanvasElement>[];
      final WbCanvasController c = WbCanvasController(
        onElementActivate: (WbCanvasElement element) async {
          activated.add(element);
        },
      );
      addTearDown(c.dispose);
      c.document.upsert(
        '',
        const WbCanvasElement(
          id: 'f1',
          type: WbElementKind.flowchart,
          x: 0,
          y: 0,
          width: 100,
          height: 80,
        ),
      );

      c.handleDoubleClick(const Offset(50, 50));
      await Future<void>.delayed(Duration.zero);
      expect(activated.map((WbCanvasElement e) => e.id), <String>['f1']);

      // 非专业元素（形状）双击不触发激活回调。
      c.document.upsert(
        '',
        const WbCanvasElement(
          id: 's1',
          type: WbElementKind.shape,
          x: 200,
          y: 0,
          width: 100,
          height: 80,
        ),
      );
      c.handleDoubleClick(const Offset(250, 40));
      await Future<void>.delayed(Duration.zero);
      expect(activated.length, 1);
    });
  });

  // -------------------------------------------------------------------------
  // 迷你地图换算（与 WbMinimap 共用纯函数）
  // -------------------------------------------------------------------------

  group('迷你地图', () {
    test('世界 ↔ 局部坐标往返一致', () {
      final WbCanvasController c = WbCanvasController();
      c.setViewportSize(const Size(800, 600));
      _seedTwoNotes(c);

      final Rect content = wbMinimapContentBounds(c);
      const Size mapSize = Size(168, 108);
      final Offset local =
          wbMinimapWorldToLocal(const Offset(120, 60), mapSize, content);
      final Offset world = wbMinimapLocalToWorld(local, mapSize, content);
      expect(world.dx, closeTo(120, 1e-9));
      expect(world.dy, closeTo(60, 1e-9));
    });

    test('centerWorldAt 目标点置于视口中心', () {
      final WbCanvasController c = WbCanvasController();
      c.setViewportSize(const Size(800, 600));
      _seedTwoNotes(c);

      final Rect content = wbMinimapContentBounds(c);
      const Size mapSize = Size(168, 108);
      final Offset local =
          wbMinimapWorldToLocal(const Offset(250, 50), mapSize, content);
      c.centerWorldAt(wbMinimapLocalToWorld(local, mapSize, content));

      final Offset centerWorld = c.screenToWorld(c.viewportCenter);
      expect(centerWorld.dx, closeTo(250, 1e-6));
      expect(centerWorld.dy, closeTo(50, 1e-6));
    });
  });

  // -------------------------------------------------------------------------
  // Widget：静态渲染与控件
  // -------------------------------------------------------------------------

  group('CanvasView 渲染', () {
    testWidgets('画布就绪 / 调色板 / 迷你地图 / 缩放控件布局', (WidgetTester tester) async {
      final WbCanvasController c = WbCanvasController();
      await _pumpCanvas(tester, controller: c);

      expect(find.text('画布就绪'), findsOneWidget);
      for (final String id in <String>[
        'select',
        'hand',
        'pen',
        'highlighter',
        'eraser',
        'sticky',
        'text',
        'shape',
        'image',
      ]) {
        expect(
          find.byKey(ValueKey<String>('wb-canvas-tool-$id')),
          findsOneWidget,
          reason: '工具按钮 $id 应存在',
        );
      }
      expect(find.byKey(const Key('wb-canvas-undo')), findsOneWidget);
      expect(find.byKey(const Key('wb-canvas-minimap')), findsOneWidget);
      expect(find.byKey(const Key('wb-zoom-out')), findsOneWidget);
      expect(find.byKey(const Key('wb-zoom-reset')), findsOneWidget);
      expect(find.byKey(const Key('wb-zoom-in')), findsOneWidget);
      expect(find.byKey(const Key('wb-zoom-fit')), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('调色板切换工具并联动参数（便签色板）', (WidgetTester tester) async {
      final WbCanvasController c = WbCanvasController();
      await _pumpCanvas(tester, controller: c);

      await tester.tap(
        find.byKey(const ValueKey<String>('wb-canvas-tool-sticky')),
      );
      await tester.pump();
      expect(c.tool, WbCanvasTool.note);

      final Finder swatch =
          find.byKey(const ValueKey<String>('wb-canvas-note-color-1'));
      expect(swatch, findsOneWidget);
      await tester.tap(swatch);
      await tester.pump();
      expect(c.noteColor, WbCanvasPalette.noteColors[1]);

      await tester.tap(
        find.byKey(const ValueKey<String>('wb-canvas-tool-shape')),
      );
      await tester.pump();
      expect(c.tool, WbCanvasTool.shape);
      expect(
        find.byKey(const ValueKey<String>('wb-canvas-shape-kind-ellipse')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('wb-canvas-shape-kind-ellipse')),
      );
      await tester.pump();
      expect(c.shapeKind, WbShapeKind.ellipse);
    });

    testWidgets('点击创建便签 → 输入文本 → Esc 提交', (WidgetTester tester) async {
      final WbCanvasController c = WbCanvasController();
      await _pumpCanvas(tester, controller: c);

      await tester.tap(
        find.byKey(const ValueKey<String>('wb-canvas-tool-sticky')),
      );
      await tester.pump();
      await tester.tapAt(_viewportCenter);
      await tester.pump();
      await tester.pump();

      expect(c.elements.length, 1);
      expect(c.editingElementId, isNotNull);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('画布就绪'), findsNothing);

      await tester.enterText(find.byType(TextField), '会议纪要');
      await tester.pump();
      expect(c.elements.single.text, '会议纪要');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(c.editingElementId, isNull);
      expect(find.byType(TextField), findsNothing);
      expect(c.elements.single.text, '会议纪要');
      expect(c.canUndo, isTrue);
    });

    testWidgets('拖拽创建形状元素（无编辑浮层）', (WidgetTester tester) async {
      final WbCanvasController c = WbCanvasController();
      await _pumpCanvas(tester, controller: c);

      await tester.tap(
        find.byKey(const ValueKey<String>('wb-canvas-tool-shape')),
      );
      await tester.pump();

      final TestGesture gesture =
          await tester.startGesture(const Offset(600, 400));
      await gesture.moveTo(const Offset(900, 600));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(c.elements.length, 1);
      final WbCanvasElement e = c.elements.single;
      expect(e.type, WbElementKind.shape);
      expect(e.bounds, const Rect.fromLTWH(600, 400, 300, 200));
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('Zoom 控件：+ / 重置 / 适应内容', (WidgetTester tester) async {
      final WbCanvasController c = WbCanvasController();
      await _pumpCanvas(tester, controller: c);

      await tester.tap(find.byKey(const Key('wb-zoom-in')));
      await tester.pump();
      expect(c.scale, greaterThan(1));
      expect(find.text('${(c.scale * 100).round()}%'), findsOneWidget);

      await tester.tap(find.byKey(const Key('wb-zoom-reset')));
      await tester.pump();
      expect(c.scale, 1);
      expect(c.offset, Offset.zero);
      expect(find.text('100%'), findsOneWidget);

      c.document.upsert(
        '',
        const WbCanvasElement(
          id: 'big',
          type: WbElementKind.shape,
          x: 0,
          y: 0,
          width: 1000,
          height: 800,
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('wb-zoom-fit')));
      await tester.pump();
      // 适配后整个元素完整落入视口（视口较大时允许放大显示）。
      final Rect visible = c.visibleWorldRect;
      expect(visible.contains(const Offset(1, 1)), isTrue);
      expect(visible.contains(const Offset(999, 799)), isTrue);
    });

    testWidgets('迷你地图点击使目标世界点居中', (WidgetTester tester) async {
      final WbCanvasController c = WbCanvasController();
      await _pumpCanvas(tester, controller: c);
      _seedTwoNotes(c);
      await tester.pump();

      final Offset before = c.screenToWorld(c.viewportCenter);
      final Rect contentBefore = wbMinimapContentBounds(c);
      final Rect minimapRect =
          tester.getRect(find.byKey(const Key('wb-canvas-minimap')));
      await tester.tapAt(minimapRect.center);
      await tester.pump();

      final Offset expected = wbMinimapLocalToWorld(
        const Offset(84, 54),
        WbMinimap.size,
        contentBefore,
      );
      final Offset centerWorld = c.screenToWorld(c.viewportCenter);
      // 点击后面板中心对应的世界点应置于视口中心（视图确实移动）。
      expect((centerWorld - before).distance, greaterThan(1));
      expect(centerWorld.dx, closeTo(expected.dx, 25));
      expect(centerWorld.dy, closeTo(expected.dy, 25));
    });

    testWidgets('滚轮平移与 Ctrl+滚轮缩放（指针信号）', (WidgetTester tester) async {
      final WbCanvasController c = WbCanvasController();
      await _pumpCanvas(tester, controller: c);

      final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(_viewportCenter));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
      await tester.pump();
      expect(c.offset.dy, closeTo(-100, 1e-9));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -320)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(c.scale, closeTo(math.e, 1e-3));
    });

    testWidgets('双指捏合缩放（触摸指针）', (WidgetTester tester) async {
      final WbCanvasController c = WbCanvasController();
      await _pumpCanvas(tester, controller: c);

      final TestGesture g1 = await tester.startGesture(
        const Offset(600, 500),
        pointer: 11,
      );
      final TestGesture g2 = await tester.startGesture(
        const Offset(1000, 500),
        pointer: 12,
      );
      await tester.pump();
      await g1.moveTo(const Offset(500, 500));
      await g2.moveTo(const Offset(1100, 500));
      await tester.pump();
      expect(c.scale, closeTo(1.5, 1e-6));

      await g1.up();
      await g2.up();
      await tester.pump();
    });

    testWidgets('空格 + 拖拽平移视图', (WidgetTester tester) async {
      final WbCanvasController c = WbCanvasController();
      await _pumpCanvas(tester, controller: c);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(c.spacePressed, isTrue);

      final TestGesture gesture =
          await tester.startGesture(const Offset(800, 500));
      await gesture.moveTo(const Offset(850, 560));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(c.offset, const Offset(50, 60));

      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(c.spacePressed, isFalse);
    });

    testWidgets('Delete 键删除选中元素', (WidgetTester tester) async {
      final WbCanvasController c = WbCanvasController();
      final WbSelectionState sel = WbSelectionState();
      await _pumpCanvas(tester, controller: c, selection: sel);

      _seedTwoNotes(c);
      sel.select(<String>['a']);
      await tester.pump();
      expect(c.selectionBounds, isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(c.elements.length, 1);
      expect(c.document.byId('', 'a'), isNull);
    });

    testWidgets('双击便签进入文本编辑', (WidgetTester tester) async {
      final WbCanvasController c = WbCanvasController();
      await _pumpCanvas(tester, controller: c);
      c.document.upsert(
        '',
        const WbCanvasElement(
          id: 'n1',
          type: WbElementKind.note,
          x: 700,
          y: 400,
          width: 200,
          height: 150,
          text: '旧文本',
        ),
      );
      await tester.pump();

      const Offset center = Offset(800, 475);
      await tester.tapAt(center);
      await tester.pump();
      await tester.tapAt(center);
      await tester.pump();

      expect(c.editingElementId, 'n1');
      expect(find.byType(TextField), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Widget：Provider 选区同步（无参 CanvasView 端到端）
  // -------------------------------------------------------------------------

  testWidgets('无参 CanvasView + Provider：创建 → 点选 → 选区同步',
      (WidgetTester tester) async {
    final WbSelectionState sel = WbSelectionState();
    tester.view.physicalSize = _window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<WbSelectionState>.value(
        value: sel,
        child: const MaterialApp(home: Scaffold(body: CanvasView())),
      ),
    );
    // 等 autofocus 与 postFrame（attachSelection）生效。
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-canvas-tool-sticky')),
    );
    await tester.pump();
    await tester.tapAt(_viewportCenter);
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextField), '区块一');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-canvas-tool-select')),
    );
    await tester.pump();
    await tester.tapAt(_viewportCenter);
    await tester.pump();

    expect(sel.count, 1);
  });
}
