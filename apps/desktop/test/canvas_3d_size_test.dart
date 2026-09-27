/// 3D / 2D 尺寸调整与尺寸角标测试（纯 test；无 Widget）。
///
/// 覆盖：滚轮缩放（倍率 / clamp / 撤销合并 / locked 跳过 / 平移回归）、
/// [WbCanvasController.resizeElementById]（保中心 / 撤销 / locked 与
/// 无变化跳过）、尺寸角标（显示条件 / 命中回调 / 角标外正常行为）。
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/state/selection_state.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';
import 'package:whiteboard_desktop/widgets/context_editors/render3d_editor.dart';

// ---- 测试基建 -------------------------------------------------------------

/// 预置一个 300x300 的 3D 元素（id：d1，世界原点左上角）。
void _seed3d(WbCanvasController c, {bool locked = false}) {
  c.document.upsert(
    '',
    WbCanvasElement(
      id: 'd1',
      type: WbElementKind.render3d,
      x: 0,
      y: 0,
      width: 300,
      height: 300,
      locked: locked,
      payload: const Wb3dScene(),
    ),
  );
}

/// 预置一个 200x150 的 2D 图元（id：r2）。
void _seed2d(WbCanvasController c) {
  c.document.upsert(
    '',
    const WbCanvasElement(
      id: 'r2',
      type: WbElementKind.render2d,
      x: 0,
      y: 0,
      width: 200,
      height: 150,
    ),
  );
}

void main() {
  // -------------------------------------------------------------------------
  // 滚轮缩放
  // -------------------------------------------------------------------------

  group('滚轮缩放 3D 尺寸', () {
    test('单选 3D：滚轮按 exp(-dy/320) 等比缩放且中心不变', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      addTearDown(() {
        c.dispose();
        sel.dispose();
      });
      c.setViewportSize(const Size(800, 600));
      _seed3d(c);
      sel.select(<String>['d1']);

      c.handleScroll(
        const Offset(150, 150),
        const Offset(0, -320),
        ctrl: false,
      );

      final WbCanvasElement e = c.elements.single;
      expect(e.width, closeTo(300 * math.e, 1e-6));
      expect(e.height, closeTo(300 * math.e, 1e-6));
      expect(e.center.dx, closeTo(150, 1e-6), reason: '中心保持不变');
      expect(e.center.dy, closeTo(150, 1e-6));
    });

    test('缩放上下界 clamp：40 / 4000', () {
      // 下限：50 → 50/e ≈ 18.4 → clamp 40。
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      addTearDown(() {
        c.dispose();
        sel.dispose();
      });
      c.setViewportSize(const Size(800, 600));
      c.document.upsert(
        '',
        const WbCanvasElement(
          id: 'small',
          type: WbElementKind.render3d,
          x: 0,
          y: 0,
          width: 50,
          height: 50,
          payload: Wb3dScene(),
        ),
      );
      sel.select(<String>['small']);
      c.handleScroll(
        const Offset(25, 25),
        const Offset(0, 320),
        ctrl: false,
      );
      expect(c.elements.single.width, closeTo(40, 1e-9));
      expect(c.elements.single.height, closeTo(40, 1e-9));

      // 上限：3000 → 3000*e ≈ 8154.8 → clamp 4000。
      final WbSelectionState sel2 = WbSelectionState();
      final WbCanvasController c2 = WbCanvasController(selection: sel2);
      addTearDown(() {
        c2.dispose();
        sel2.dispose();
      });
      c2.setViewportSize(const Size(800, 600));
      c2.document.upsert(
        '',
        const WbCanvasElement(
          id: 'big',
          type: WbElementKind.render3d,
          x: 0,
          y: 0,
          width: 3000,
          height: 3000,
          payload: Wb3dScene(),
        ),
      );
      sel2.select(<String>['big']);
      c2.handleScroll(
        const Offset(25, 25),
        const Offset(0, -320),
        ctrl: false,
      );
      expect(c2.elements.single.width, closeTo(4000, 1e-9));
      expect(c2.elements.single.height, closeTo(4000, 1e-9));
    });

    test('撤销合并：两次快速滚轮 + 空闲 400ms 只产生 1 条撤销记录', () async {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      addTearDown(() {
        c.dispose();
        sel.dispose();
      });
      c.setViewportSize(const Size(800, 600));
      _seed3d(c);
      sel.select(<String>['d1']);

      c.handleScroll(
        const Offset(150, 150),
        const Offset(0, -320),
        ctrl: false,
      );
      c.handleScroll(
        const Offset(150, 150),
        const Offset(0, -320),
        ctrl: false,
      );
      expect(c.elements.single.width, closeTo(300 * math.e * math.e, 1e-3));

      // 空闲 400ms：会话自动提交；undo 一次即回到初始尺寸。
      await Future<void>.delayed(const Duration(milliseconds: 500));
      c.undo();
      expect(c.elements.single.width, 300);
      expect(c.elements.single.height, 300);
      expect(c.canUndo, isFalse, reason: '多次滚轮合并为 1 条撤销记录');
    });

    test('locked 元素滚轮不缩放（回退为普通平移）', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      addTearDown(() {
        c.dispose();
        sel.dispose();
      });
      c.setViewportSize(const Size(800, 600));
      _seed3d(c, locked: true);
      sel.select(<String>['d1']);

      c.handleScroll(
        const Offset(150, 150),
        const Offset(0, -320),
        ctrl: false,
      );
      expect(c.elements.single.width, 300, reason: 'locked 不缩放');
      expect(c.offset, const Offset(0, 320), reason: '回退为普通平移');
    });

    test('无选中滚轮平移 / Ctrl 缩放视图（回归）', () {
      final WbCanvasController c = WbCanvasController();
      addTearDown(c.dispose);
      c.setViewportSize(const Size(800, 600));

      // 普通滚轮：平移（offset 反向）。
      c.handleScroll(
        const Offset(100, 100),
        const Offset(10, 20),
        ctrl: false,
      );
      expect(c.offset, const Offset(-10, -20));

      // Shift + 滚轮：水平平移。
      c.handleScroll(
        const Offset(100, 100),
        const Offset(0, 30),
        ctrl: false,
        shift: true,
      );
      expect(c.offset, const Offset(-40, -20));

      // Ctrl + 滚轮：视图缩放（优先级不受新分支影响）。
      c.handleScroll(
        const Offset(0, 0),
        const Offset(0, -320),
        ctrl: true,
      );
      expect(c.scale, closeTo(math.e, 1e-6));
    });
  });

  // -------------------------------------------------------------------------
  // resizeElementById
  // -------------------------------------------------------------------------

  group('resizeElementById', () {
    test('改尺寸保中心，undo 一次恢复', () {
      final WbCanvasController c = WbCanvasController();
      addTearDown(c.dispose);
      c.setViewportSize(const Size(800, 600));
      _seed3d(c);

      c.resizeElementById('d1', 400, 200);

      final WbCanvasElement e = c.elements.single;
      expect(e.width, 400);
      expect(e.height, 200);
      expect(e.center.dx, closeTo(150, 1e-9), reason: '中心保持不变');
      expect(e.center.dy, closeTo(150, 1e-9));
      expect(e.x, closeTo(-50, 1e-9));
      expect(e.y, closeTo(50, 1e-9));
      expect(c.canUndo, isTrue);

      c.undo();
      final WbCanvasElement back = c.elements.single;
      expect(back.width, 300);
      expect(back.height, 300);
      expect(back.x, 0);
      expect(back.y, 0);
    });

    test('locked / 数值无变化 / 不存在：不修改且不产生撤销记录', () {
      final WbCanvasController c = WbCanvasController();
      addTearDown(c.dispose);
      _seed3d(c, locked: true);
      c.resizeElementById('d1', 500, 500);
      expect(c.elements.single.width, 300, reason: 'locked 不修改');
      expect(c.canUndo, isFalse);

      final WbCanvasController c2 = WbCanvasController();
      addTearDown(c2.dispose);
      _seed3d(c2);
      c2.resizeElementById('d1', 300, 300);
      expect(c2.canUndo, isFalse, reason: '数值无变化不产生撤销记录');
      c2.resizeElementById('missing', 100, 100);
      expect(c2.canUndo, isFalse, reason: '元素不存在不产生撤销记录');
    });

    test('尺寸 clamp 8~20000', () {
      final WbCanvasController c = WbCanvasController();
      addTearDown(c.dispose);
      _seed3d(c);

      c.resizeElementById('d1', 1, 100000);

      final WbCanvasElement e = c.elements.single;
      expect(e.width, 8);
      expect(e.height, 20000);
    });
  });

  // -------------------------------------------------------------------------
  // 尺寸角标
  // -------------------------------------------------------------------------

  group('尺寸角标', () {
    test('单选 render3d / render2d 显示 label 与屏幕矩形；其余为空', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      addTearDown(() {
        c.dispose();
        sel.dispose();
      });
      c.setViewportSize(const Size(800, 600));
      _seed3d(c);
      _seed2d(c);

      expect(c.sizeBadgeScreenRect, isNull, reason: '无选中无角标');
      expect(c.sizeBadgeLabel, '');

      sel.select(<String>['d1']);
      expect(c.sizeBadgeLabel, '300 × 300');
      final Rect badge = c.sizeBadgeScreenRect!;
      expect(badge.height, 20);
      expect(badge.width, closeTo('300 × 300'.length * 6.5 + 14, 1e-9));
      expect(badge.top, closeTo(306, 1e-9), reason: '选择框下缘 + 6px');
      expect(badge.center.dx, closeTo(150, 1e-9), reason: '下缘居中');

      sel.select(<String>['r2']);
      expect(c.sizeBadgeLabel, '200 × 150');
      expect(c.sizeBadgeScreenRect, isNotNull);

      // locked：不显示角标。
      final WbCanvasElement r2 =
          c.elements.firstWhere((WbCanvasElement e) => e.id == 'r2');
      c.document.upsert('', r2.copyWith(locked: true));
      expect(c.sizeBadgeScreenRect, isNull);
    });

    test('点击角标：回调收到元素且不进入手势；角标外正常行为', () {
      final WbSelectionState sel = WbSelectionState();
      WbCanvasElement? tapped;
      final WbCanvasController c = WbCanvasController(
        selection: sel,
        onSizeBadgeTap: (WbCanvasElement element) => tapped = element,
      );
      addTearDown(() {
        c.dispose();
        sel.dispose();
      });
      c.setViewportSize(const Size(800, 600));
      _seed3d(c);
      sel.select(<String>['d1']);

      // 点角标中心 (150, 316)：消费按下、回调元素、手势保持 idle。
      c.handlePointerDown(1, const Offset(150, 316), shift: false);
      expect(tapped?.id, 'd1');
      expect(c.gesture, WbCanvasGesture.idle, reason: '不进入任何手势');

      // 点角标外（元素内部）：按回归行为——单选 3D 拖动进入旋转手势。
      c.handlePointerDown(2, const Offset(150, 150), shift: false);
      expect(c.gesture, WbCanvasGesture.rotateRender3d);
      c.cancelGesture();

      // 空白处按下：清空选择并进入框选（既有行为不受影响）。
      c.handlePointerDown(3, const Offset(700, 500), shift: false);
      expect(c.gesture, WbCanvasGesture.boxSelect);
      expect(sel.ids, isEmpty);
    });

    test('无回调注入时点角标仍消费按下（不误启动其他手势）', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      addTearDown(() {
        c.dispose();
        sel.dispose();
      });
      c.setViewportSize(const Size(800, 600));
      _seed3d(c);
      sel.select(<String>['d1']);

      c.handlePointerDown(1, const Offset(150, 316), shift: false);
      expect(c.gesture, WbCanvasGesture.idle);
      expect(c.selectedIds, contains('d1'), reason: '不改变选择');
    });
  });
}
