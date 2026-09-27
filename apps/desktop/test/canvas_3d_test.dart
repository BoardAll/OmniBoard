/// 3D 直绘 / 翻转旋转 / 表面涂色控制器测试（纯 test；无 Widget）。
///
/// 覆盖：一次放置直绘（拖拽 / 单击默认尺寸 / 取消清理）、单选旋转手势
/// 与撤销回滚、Shift 拖动移动、表面涂色命中与同色取消。
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/state/selection_state.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';
import 'package:whiteboard_desktop/widgets/context_editors/render3d_editor.dart';

// ---- 测试基建 -------------------------------------------------------------

/// 预置一个 300x300 的 3D 元素（id：d1，世界原点左上角）。
void _seed3d(WbCanvasController c) {
  c.document.upsert(
    '',
    const WbCanvasElement(
      id: 'd1',
      type: WbElementKind.render3d,
      x: 0,
      y: 0,
      width: 300,
      height: 300,
      payload: Wb3dScene(),
    ),
  );
}

/// 读取唯一元素的 3D 场景 payload。
Wb3dScene _sceneOf(WbCanvasController c) =>
    c.elements.single.payload! as Wb3dScene;

void main() {
  // -------------------------------------------------------------------------
  // 直绘状态机
  // -------------------------------------------------------------------------

  group('3D 直绘状态机', () {
    test('球体一次完成：拖动确定直径并回切选择工具', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      addTearDown(() {
        c.dispose();
        sel.dispose();
      });
      c.setViewportSize(const Size(800, 600));
      c.setRender3dType(Wb3dObjectType.sphere);
      c.setTool(WbCanvasTool.render3d);

      c.handlePointerDown(1, const Offset(200, 200), shift: false);
      c.handlePointerMove(1, const Offset(300, 300));
      c.handlePointerUp(1, const Offset(300, 300));

      expect(c.elements.length, 1);
      final WbCanvasElement e = c.elements.single;
      expect(e.type, WbElementKind.render3d);
      expect(e.bounds, const Rect.fromLTWH(200, 200, 100, 100));
      final Wb3dScene scene = _sceneOf(c);
      expect(scene.objectType, Wb3dObjectType.sphere);
      expect(scene.faceColors, isEmpty);
      expect(c.tool, WbCanvasTool.select);
      expect(c.render3dPreviewScene, isNull);
      expect(c.render3dPreviewRect, isNull);
      expect(c.selectedIds, <String>{e.id}, reason: '创建完成后立即选中新元素');
      expect(c.canUndo, isTrue);

      c.undo();
      expect(c.elements, isEmpty);
    });

    test('柱体一次完成：拖拽后高度 = 底面最大边 × 0.8，可撤销', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      addTearDown(() {
        c.dispose();
        sel.dispose();
      });
      c.setViewportSize(const Size(800, 600));
      c.setTool(WbCanvasTool.render3d);

      c.handlePointerDown(1, const Offset(200, 200), shift: false);
      c.handlePointerMove(1, const Offset(300, 300));
      expect(
        c.render3dPreviewRect,
        const Rect.fromLTWH(200, 200, 100, 80),
        reason: '拖拽中预览即最终盒子（高 = 100 × 0.8 = 80）',
      );
      c.handlePointerUp(1, const Offset(300, 300));

      expect(c.elements.length, 1);
      final WbCanvasElement e = c.elements.single;
      expect(e.type, WbElementKind.render3d);
      expect(e.bounds, const Rect.fromLTWH(200, 200, 100, 80));
      expect(_sceneOf(c).objectType, Wb3dObjectType.box);
      expect(c.tool, WbCanvasTool.select);
      expect(c.render3dPreviewScene, isNull);
      expect(c.render3dPreviewRect, isNull);
      expect(c.selectedIds, <String>{e.id});
      expect(c.canUndo, isTrue);

      c.undo();
      expect(c.elements, isEmpty);
    });

    test('单击放置：球体默认 180 直径，柱体默认底面 220x160 + 高 176', () {
      // 球体：down / up 同点（无拖动）→ 180x180 以落点为中心。
      final WbCanvasController c = WbCanvasController();
      addTearDown(c.dispose);
      c.setViewportSize(const Size(800, 600));
      c.setRender3dType(Wb3dObjectType.sphere);
      c.setTool(WbCanvasTool.render3d);
      c.handlePointerDown(1, const Offset(400, 300), shift: false);
      c.handlePointerUp(1, const Offset(400, 300));

      expect(c.elements.length, 1);
      expect(
        c.elements.single.bounds,
        const Rect.fromLTWH(310, 210, 180, 180),
      );
      expect(c.tool, WbCanvasTool.select);

      // 柱体：单击 → 默认底面 220x160（中心在落点），最终 220x176。
      final WbCanvasController c2 = WbCanvasController();
      addTearDown(c2.dispose);
      c2.setViewportSize(const Size(800, 600));
      c2.setTool(WbCanvasTool.render3d);
      c2.handlePointerDown(1, const Offset(400, 300), shift: false);
      c2.handlePointerUp(1, const Offset(400, 300));

      expect(c2.elements.length, 1);
      expect(
        c2.elements.single.bounds,
        const Rect.fromLTWH(290, 220, 220, 176),
      );
      expect(c2.tool, WbCanvasTool.select);
    });

    test('拖动中取消 / 切走工具：无元素且预览清理；完成后预览为空', () {
      final WbCanvasController c = WbCanvasController();
      addTearDown(c.dispose);
      c.setViewportSize(const Size(800, 600));
      c.setTool(WbCanvasTool.render3d);

      // 拖动中取消：无元素、预览清理。
      c.handlePointerDown(1, const Offset(200, 200), shift: false);
      c.handlePointerMove(1, const Offset(300, 300));
      expect(c.render3dPreviewScene, isNotNull);
      expect(c.render3dPreviewRect, isNotNull);
      c.cancelGesture();
      expect(c.render3dPreviewScene, isNull);
      expect(c.render3dPreviewRect, isNull);
      expect(c.elements, isEmpty);

      // 拖动中切走工具：同样清理且不落元素。
      c.handlePointerDown(2, const Offset(200, 200), shift: false);
      c.handlePointerMove(2, const Offset(300, 300));
      expect(c.render3dPreviewScene, isNotNull);
      c.setTool(WbCanvasTool.select);
      expect(c.render3dPreviewScene, isNull);
      expect(c.render3dPreviewRect, isNull);
      expect(c.elements, isEmpty);
      expect(c.canUndo, isFalse);

      // 拖拽完成后：预览为空（已落地为元素）。
      c.setTool(WbCanvasTool.render3d);
      c.handlePointerDown(3, const Offset(200, 200), shift: false);
      c.handlePointerMove(3, const Offset(300, 300));
      c.handlePointerUp(3, const Offset(300, 300));
      expect(c.elements.length, 1);
      expect(c.render3dPreviewScene, isNull);
      expect(c.render3dPreviewRect, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // 翻转（旋转）
  // -------------------------------------------------------------------------

  group('3D 翻转（旋转）', () {
    test('单选 3D 元素拖动旋转：Y 随 dx、X 随 dy 实时更新并可撤销', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      addTearDown(() {
        c.dispose();
        sel.dispose();
      });
      c.setViewportSize(const Size(800, 600));
      _seed3d(c);
      sel.select(<String>['d1']);
      c.setTool(WbCanvasTool.select);

      c.handlePointerDown(1, const Offset(150, 150), shift: false);
      expect(c.gesture, WbCanvasGesture.rotateRender3d);

      c.handlePointerMove(1, const Offset(190, 170));
      final Wb3dScene mid = _sceneOf(c);
      expect(mid.transform.rotationY, closeTo(20, 1e-6));
      expect(mid.transform.rotationX, closeTo(-10, 1e-6));

      c.handlePointerUp(1, const Offset(190, 170));
      final Wb3dScene done = _sceneOf(c);
      expect(done.transform.rotationY, closeTo(20, 1e-6));
      expect(done.transform.rotationX, closeTo(-10, 1e-6));
      expect(c.canUndo, isTrue);

      c.undo();
      final Wb3dScene back = _sceneOf(c);
      expect(back.transform.rotationY, 0);
      expect(back.transform.rotationX, 0);
    });

    test('旋转中 cancelGesture 回滚到起始场景（不入撤销栈）', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      addTearDown(() {
        c.dispose();
        sel.dispose();
      });
      c.setViewportSize(const Size(800, 600));
      _seed3d(c);
      sel.select(<String>['d1']);
      c.setTool(WbCanvasTool.select);

      c.handlePointerDown(1, const Offset(150, 150), shift: false);
      c.handlePointerMove(1, const Offset(250, 150));
      expect(_sceneOf(c).transform.rotationY, closeTo(50, 1e-6));

      c.cancelGesture();
      final Wb3dScene after = _sceneOf(c);
      expect(after.transform.rotationY, 0);
      expect(after.transform.rotationX, 0);
      expect(c.canUndo, isFalse);
    });

    test('Shift+拖动 3D 元素为移动（不旋转）', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      addTearDown(() {
        c.dispose();
        sel.dispose();
      });
      c.setViewportSize(const Size(800, 600));
      _seed3d(c);
      c.setTool(WbCanvasTool.select);

      // 未预选时 Shift 按下会先加选，再进入移动手势。
      c.handlePointerDown(1, const Offset(150, 150), shift: true);
      expect(c.gesture, WbCanvasGesture.moveElements);

      c.handlePointerMove(1, const Offset(190, 150));
      c.handlePointerUp(1, const Offset(190, 150));

      final WbCanvasElement e = c.elements.single;
      expect(e.x, closeTo(40, 1e-9));
      expect(e.y, closeTo(0, 1e-9));
      final Wb3dScene scene = _sceneOf(c);
      expect(scene.transform.rotationX, 0);
      expect(scene.transform.rotationY, 0);
    });
  });

  // -------------------------------------------------------------------------
  // 表面涂色
  // -------------------------------------------------------------------------

  group('3D 表面涂色', () {
    test('点击着色 → 同色再点取消 → 关闭模式不生效', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      addTearDown(() {
        c.dispose();
        sel.dispose();
      });
      c.setViewportSize(const Size(800, 600));
      _seed3d(c);
      sel.select(<String>['d1']);
      c.setTool(WbCanvasTool.select);
      c.setRender3dPaintMode(true);

      // 第一次点击：着色并消费手势。
      c.handlePointerDown(1, const Offset(150, 150), shift: false);
      c.handlePointerUp(1, const Offset(150, 150));
      final Wb3dScene painted = _sceneOf(c);
      expect(painted.faceColors, isNotEmpty);
      expect(
        painted.faceColors.values,
        everyElement(Color(c.render3dPaintColor)),
      );
      expect(c.canUndo, isTrue);

      // 同色再点：取消该面涂色。
      c.handlePointerDown(2, const Offset(150, 150), shift: false);
      c.handlePointerUp(2, const Offset(150, 150));
      expect(_sceneOf(c).faceColors, isEmpty);

      // 关闭涂色模式：点击不再涂色。
      c.setRender3dPaintMode(false);
      c.handlePointerDown(3, const Offset(150, 150), shift: false);
      c.handlePointerUp(3, const Offset(150, 150));
      expect(_sceneOf(c).faceColors, isEmpty);
    });

    test('涂色参数：默认关闭 / 默认首色 / 切走选择工具自动关闭', () {
      final WbCanvasController c = WbCanvasController();
      addTearDown(c.dispose);
      expect(c.render3dPaintMode, isFalse);
      expect(c.render3dPaintColor, WbCanvasPalette.shapeColors.first);

      c.setRender3dPaintMode(true);
      expect(c.render3dPaintMode, isTrue);
      c.setRender3dPaintColor(WbCanvasPalette.shapeColors[2]);
      expect(c.render3dPaintColor, WbCanvasPalette.shapeColors[2]);

      c.setTool(WbCanvasTool.render3d);
      expect(c.render3dPaintMode, isFalse, reason: '切走 select 自动关闭涂色');
    });

    test('单选判断：hasSingleRender3dSelection 与 payload 无关（按类型）', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      addTearDown(() {
        c.dispose();
        sel.dispose();
      });
      _seed3d(c);
      expect(c.hasSingleRender3dSelection, isFalse);
      sel.select(<String>['d1']);
      expect(c.hasSingleRender3dSelection, isTrue);
      expect(c.singleSelectedRender3d!.id, 'd1');
      sel.clear();
      expect(c.hasSingleRender3dSelection, isFalse);
      expect(c.singleSelectedRender3d, isNull);
    });
  });
}
