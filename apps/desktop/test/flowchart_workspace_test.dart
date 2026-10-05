/// 流程图编辑器全窗三区工作区 + 无限画布交互测试（第三轮缺陷修复 · 波次 B2；
/// ProcessOn 式交互改造 · 无限画布 + UML/DFD）。
///
/// 覆盖：
/// - **全窗三区布局（B2.1）**：左图形库（`wb-ctx-flow-left-panel`，176 宽，
///   按 8 库折叠分组渲染 40 类型（静态图形 39 项））/ 中间最大化画布
///   （`wb-ctx-flow-preview-transform`）/ 右属性（`wb-ctx-flow-right-panel`，
///   240 宽）；不再渲染旧的 420 宽面板卡片；
/// - **画布缩放（B2.2）**：工具条 +（1.2x 步进）/ − / 重置 100% / 适配内容，
///   Ctrl+滚轮 factor = exp(-dy / 320)、clamp 0.25~3.0（以指针为锚）；
/// - **无限画布相机**：滚轮平移（Shift 横移）/ 空格与中键拖拽平移（grab
///   光标）/ 平移钳制（视口中心 ∈ ±5000 世界平面）/ 双击空白适配内容；
/// - **框选与多选**：空白拖拽框选（相交即选）/ Shift 点选加选 / 多选整体
///   拖动 / Ctrl+A 全选 / Delete 批量删除 / 方向键微调（1px / Shift 10px）；
/// - **对齐参考线**：拖拽吸附阈值 6 世界 px（断言吸附后的模型坐标）；
/// - **端口四向连线**：选中后四边中点圆点（key `wb-ctx-flow-port-<id>-<side>`），
///   拖到目标节点建连线、拖到空白弹出快速创建浮层；
/// - **内联改字**：双击节点进入原位 TextField（Enter 提交 / Esc 取消）；
/// - **缩放后的核心交互**：左库点击 / 拖拽添加（落点 = 指针位置）、节点
///   拖拽跟随指针（delta 自动逆变换）、端口拖拽连线、Delete 删除。
///
/// 说明：编辑器自包含（无 Provider / 平台通道调用，测试无需 mock 通道）；
/// 手势驱动方式与 `context_editors_test.dart` 保持一致。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/context_editors/context_editor_shell.dart';
import 'package:whiteboard_desktop/widgets/context_editors/flowchart_editor.dart';

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

/// 画布渲染盒（画布容器内与其同尺寸的 [DragTarget]）：指针位置与尺寸
/// 换算的锚点。
Finder _canvasFinder() => find.byType(DragTarget<WbFlowShapeSpec>);

/// 画布区域左上角（全局坐标）。
Offset _canvasTopLeft(WidgetTester tester) =>
    tester.getTopLeft(_canvasFinder());

/// 画布区域尺寸。
Size _canvasSize(WidgetTester tester) => tester.getSize(_canvasFinder());

/// 拖拽手势：第一次移动越过触摸 slop（`DragStartBehavior.start` 不派发该段
/// 增量），第二次移动 [delta] 实际传递给 onPanUpdate。
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

/// 从 [target] 中心开始拖拽。
Future<void> _dragBy(WidgetTester tester, Finder target, Offset delta) =>
    _dragFrom(tester, tester.getCenter(target), delta);

/// 向画布中心发送一次鼠标滚轮信号（默认语义 = 平移；dy < 0 向上滚动）。
Future<void> _scrollPreview(WidgetTester tester, double dy) async {
  final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
  final Offset center = tester.getCenter(_canvasFinder());
  await tester.sendEventToBinding(pointer.hover(center));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

/// Ctrl + 滚轮（以指针为锚缩放）。
Future<void> _ctrlScrollPreview(WidgetTester tester, double dy) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await _scrollPreview(tester, dy);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

/// 当前预览区缩放值（读取 `Transform` 矩阵的 X 轴缩放）。
///
/// 注：不能用 `getMaxScaleOnAxis`——Z 轴固定为 1.0，缩小时它只会返回 1.0。
double _scaleOf(WidgetTester tester) {
  final Transform transform = tester.widget<Transform>(
    find.byKey(_key('wb-ctx-flow-preview-transform')),
  );
  return transform.transform.entry(0, 0);
}

/// 当前相机平移（场景矩阵的平移分量：场景坐标 = 世界坐标 + 5000）。
Offset _panOf(WidgetTester tester) {
  final Transform transform = tester.widget<Transform>(
    find.byKey(_key('wb-ctx-flow-preview-transform')),
  );
  return Offset(
    transform.transform.entry(0, 3),
    transform.transform.entry(1, 3),
  );
}

/// 全局屏幕坐标处的世界坐标（相机逆变换：world = (local - pan) / scale - 5000）。
Offset _worldAtGlobal(WidgetTester tester, Offset global) {
  final Offset local = global - _canvasTopLeft(tester);
  return (local - _panOf(tester)) / _scaleOf(tester) -
      const Offset(5000, 5000);
}

/// 点击工具条缩放按钮 [times] 次（内部逐次 pump）。
Future<void> _tapZoom(WidgetTester tester, String key, {int times = 1}) async {
  for (int i = 0; i < times; i++) {
    await tester.tap(find.byKey(_key(key)));
    await tester.pump();
  }
}

/// grab 光标（空格 / 中键平移态的画布光标）。
Finder _grabCursorFinder() => find.byWidgetPredicate(
  (Widget widget) =>
      widget is MouseRegion && widget.cursor == SystemMouseCursors.grab,
  description: 'grab 光标区域',
);

void main() {
  // -------------------------------------------------------------------------
  // B2.1 全窗三区布局
  // -------------------------------------------------------------------------

  group('流程图全窗三区工作区（B2.1）', () {
    testWidgets('三区渲染：左图形库 8 库分组 / 中画布 / 右属性 + 缩放与适配控件', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(tester, const WbFlowchartEditor());
      await tester.pump();

      // 三区容器就位（B2 协调者固化的 ValueKey）。
      expect(find.byKey(_key('wb-ctx-flow-left-panel')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-preview-transform')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-right-panel')), findsOneWidget);

      // 左 176 / 右 240 固定宽，中间画布吃满剩余宽度（>900，远超旧 420）。
      expect(
        tester.getSize(find.byKey(_key('wb-ctx-flow-left-panel'))).width,
        176.0,
      );
      expect(
        tester.getSize(find.byKey(_key('wb-ctx-flow-right-panel'))).width,
        240.0,
      );
      expect(_canvasSize(tester).width, greaterThan(900));

      // 左面板纵向图形库：8 库折叠分组（流程图 / 类图 / 时序图 / 用例图 /
      // 状态图 / 数据流图 / 电路图 / 我的组件）+ 静态图形 39 项全部渲染
      // （组件类型不渲染静态项）；示例模型节点渲染在画布上。
      expect(find.text('流程图'), findsOneWidget);
      expect(find.text('类图'), findsOneWidget);
      expect(find.text('电路图'), findsOneWidget);
      expect(find.text('我的组件'), findsOneWidget);
      expect(WbFlowNodeType.values.length, 40);
      for (final WbFlowShapeLibrary library in WbFlowShapeLibrary.values) {
        expect(
          find.byKey(_key('wb-ctx-flow-lib-toggle-${library.id}')),
          findsOneWidget,
          reason: library.id,
        );
      }
      int shapeItems = 0;
      for (final WbFlowNodeType type in WbFlowNodeType.values) {
        if (type == WbFlowNodeType.customComponent) {
          continue;
        }
        shapeItems++;
        expect(
          find.byKey(_key('wb-ctx-flow-shape-${type.id}')),
          findsOneWidget,
          reason: type.id,
        );
      }
      expect(shapeItems, 39);
      expect(
        find.byKey(_key('wb-ctx-flow-shape-customComponent')),
        findsNothing,
      );
      // 未注入导入器：导入入口隐藏；「更多图形」入口存在。
      expect(
        find.byKey(_key('wb-ctx-flow-component-import')),
        findsNothing,
      );
      expect(find.byKey(_key('wb-ctx-flow-more-shapes')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-node-n1')), findsOneWidget);

      // 缩放控件：- / 百分比 / + / 重置 / 适配内容。
      expect(find.byKey(_key('wb-ctx-flow-zoom-out')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-zoom-in')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-zoom-reset')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-fit')), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);

      // 旧 420 宽面板卡片 / 内嵌第二标题栏不再渲染（标题由宿主 AppBar 承担）。
      expect(find.byType(WbContextEditorShell), findsNothing);
      expect(find.text('流程图编辑器'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // B2.2 画布缩放
  // -------------------------------------------------------------------------

  group('画布缩放（B2.2）', () {
    testWidgets('工具条：+ 放大 120% / − 回退 / 重置 100% / clamp 25%~300%', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(tester, const WbFlowchartEditor());
      await tester.pump();
      expect(_scaleOf(tester), closeTo(1.0, 1e-6));

      await _tapZoom(tester, 'wb-ctx-flow-zoom-in');
      expect(find.text('120%'), findsOneWidget);
      expect(_scaleOf(tester), closeTo(1.2, 1e-6));

      await _tapZoom(tester, 'wb-ctx-flow-zoom-out');
      expect(find.text('100%'), findsOneWidget);
      expect(_scaleOf(tester), closeTo(1.0, 1e-6));

      // 连续放大：clamp 到上限 300% 后不再增长。
      await _tapZoom(tester, 'wb-ctx-flow-zoom-in', times: 12);
      expect(find.text('300%'), findsOneWidget);
      expect(_scaleOf(tester), closeTo(3.0, 1e-6));

      // 重置回 100%。
      await _tapZoom(tester, 'wb-ctx-flow-zoom-reset');
      expect(find.text('100%'), findsOneWidget);
      expect(_scaleOf(tester), closeTo(1.0, 1e-6));

      // 连续缩小：clamp 到下限 25% 后不再下降。
      await _tapZoom(tester, 'wb-ctx-flow-zoom-out', times: 12);
      expect(find.text('25%'), findsOneWidget);
      expect(_scaleOf(tester), closeTo(0.25, 1e-6));
    });

    testWidgets('Ctrl+滚轮：factor = exp(-dy/320)，clamp 0.25~3.0', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(tester, const WbFlowchartEditor());
      await tester.pump();

      // 上滚 160：exp(0.5) ≈ 1.6487 → 165%。
      await _ctrlScrollPreview(tester, -160);
      expect(find.text('165%'), findsOneWidget);
      expect(_scaleOf(tester), closeTo(math.exp(0.5), 1e-6));

      // 大幅下滚：clamp 到下限 25%。
      await _ctrlScrollPreview(tester, 2000);
      expect(find.text('25%'), findsOneWidget);
      expect(_scaleOf(tester), closeTo(0.25, 1e-6));

      // 大幅上滚：clamp 到上限 300%。
      await _ctrlScrollPreview(tester, -4000);
      expect(find.text('300%'), findsOneWidget);
      expect(_scaleOf(tester), closeTo(3.0, 1e-6));

      // 反向对称：下滚 160 → 300% × exp(-0.5) ≈ 181.96% → 182%。
      await _ctrlScrollPreview(tester, 160);
      expect(find.text('182%'), findsOneWidget);
      expect(_scaleOf(tester), closeTo(3 * math.exp(-0.5), 1e-6));
    });
  });

  // -------------------------------------------------------------------------
  // 无限画布相机：平移 / 缩放锚点 / 钳制 / 适配
  // -------------------------------------------------------------------------

  group('无限画布相机', () {
    testWidgets('滚轮平移（Shift 横移）；Ctrl+滚轮以指针为锚缩放', (WidgetTester tester) async {
      await _pumpEditor(tester, const WbFlowchartEditor());
      await tester.pump();

      // 初始相机：世界原点位于视口左上角 → 场景平移 = (-5000, -5000)。
      expect(_panOf(tester), const Offset(-5000, -5000));

      // 滚轮 = 平移（与黑板一致，不再缩放）。
      await _scrollPreview(tester, 100);
      expect(_scaleOf(tester), closeTo(1.0, 1e-6));
      expect(_panOf(tester).dy, closeTo(-4900, 1e-6));

      await _scrollPreview(tester, -40);
      expect(_panOf(tester).dy, closeTo(-4940, 1e-6));

      // Shift + 滚轮 = 横移（垂直滚量转为水平平移）。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _scrollPreview(tester, 80);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(_panOf(tester).dx, closeTo(-4920, 1e-6));
      expect(_panOf(tester).dy, closeTo(-4940, 1e-6));

      // Ctrl + 滚轮：以指针（画布中心）为锚，锚点世界坐标不变。
      final Offset center = tester.getCenter(_canvasFinder());
      final Offset worldBefore = _worldAtGlobal(tester, center);
      await _ctrlScrollPreview(tester, -160);
      expect(_scaleOf(tester), closeTo(math.exp(0.5), 1e-6));
      final Offset worldAfter = _worldAtGlobal(tester, center);
      expect(worldAfter.dx, closeTo(worldBefore.dx, 1e-3));
      expect(worldAfter.dy, closeTo(worldBefore.dy, 1e-3));
    });

    testWidgets('空格 + 左键拖拽平移（grab 光标）', (WidgetTester tester) async {
      await _pumpEditor(tester, const WbFlowchartEditor());
      await tester.pump();
      expect(_grabCursorFinder(), findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(_grabCursorFinder(), findsOneWidget, reason: '空格按下后光标应变为 grab');

      final Offset before = _panOf(tester);
      await _dragFrom(
        tester,
        tester.getCenter(_canvasFinder()),
        const Offset(40, 60),
      );
      final Offset after = _panOf(tester);
      expect(after.dx - before.dx, closeTo(40, 1e-6));
      expect(after.dy - before.dy, closeTo(60, 1e-6));

      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(_grabCursorFinder(), findsNothing);
    });

    testWidgets('中键拖拽平移（grab 光标）', (WidgetTester tester) async {
      await _pumpEditor(tester, const WbFlowchartEditor());
      await tester.pump();

      final Offset before = _panOf(tester);
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(_canvasFinder()),
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await tester.pump();
      expect(_grabCursorFinder(), findsOneWidget, reason: '中键按下后光标应变为 grab');

      await gesture.moveBy(const Offset(30, -20));
      await tester.pump();
      expect(_panOf(tester).dx - before.dx, closeTo(30, 1e-6));
      expect(_panOf(tester).dy - before.dy, closeTo(-20, 1e-6));

      await gesture.up();
      await tester.pump();
      expect(_grabCursorFinder(), findsNothing);
      // 抬笔后继续移动不再平移。
      final Offset settled = _panOf(tester);
      await tester.sendEventToBinding(
        TestPointer(2, PointerDeviceKind.mouse).hover(const Offset(200, 200)),
      );
      await tester.pump();
      expect(_panOf(tester), settled);
    });

    testWidgets('平移钳制：视口中心不越出 ±5000 虚拟平面', (WidgetTester tester) async {
      await _pumpEditor(tester, const WbFlowchartEditor());
      await tester.pump();

      // 向下滚出平面 → 被钳制；继续滚动不再变化。
      await _scrollPreview(tester, 30000);
      final Offset bounded = _panOf(tester);
      await _scrollPreview(tester, 30000);
      expect(_panOf(tester).dx, closeTo(bounded.dx, 1e-6));
      expect(_panOf(tester).dy, closeTo(bounded.dy, 1e-6));

      // 上滚出平面 → 同样钳制。
      await _scrollPreview(tester, -90000);
      final Offset boundedUp = _panOf(tester);
      await _scrollPreview(tester, -30000);
      expect(_panOf(tester).dy, closeTo(boundedUp.dy, 1e-6));

      // 视口中心仍在 ±5000 内。
      final Offset center = _worldAtGlobal(
        tester,
        tester.getCenter(_canvasFinder()),
      );
      expect(center.dx.abs(), lessThanOrEqualTo(5000 + 1e-6));
      expect(center.dy.abs(), lessThanOrEqualTo(5000 + 1e-6));
    });

    testWidgets('适配内容：工具条按钮与双击空白（内容居中）', (
      WidgetTester tester,
    ) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();

      Rect? bounds;
      void assertCentered({required String reason}) {
        final double scale = _scaleOf(tester);
        final Offset pan = _panOf(tester);
        final Offset centerScreen =
            (bounds!.center + const Offset(5000, 5000)) * scale + pan;
        final Size size = _canvasSize(tester);
        expect(centerScreen.dx, closeTo(size.width / 2, 1.0), reason: reason);
        expect(centerScreen.dy, closeTo(size.height / 2, 1.0), reason: reason);
      }

      // 工具条「适配内容」：内容较小时不放大（scale 上限 1.0），仅居中。
      bounds = models.last.contentBounds();
      await tester.tap(find.byKey(_key('wb-ctx-flow-fit')));
      await tester.pump();
      expect(_scaleOf(tester), closeTo(1.0, 1e-6));
      assertCentered(reason: '适配内容后内容中心应位于视口中心');

      // 先平移相机使内容偏离中心，再双击空白 → 重新适配居中。
      await _scrollPreview(tester, 200);
      final Offset center = tester.getCenter(_canvasFinder());
      expect(
        _worldAtGlobal(tester, center).dy,
        isNot(closeTo(bounds!.center.dy, 1.0)),
        reason: '滚轮平移后相机应偏离内容中心',
      );
      final Size size = _canvasSize(tester);
      final Offset blank =
          _canvasTopLeft(tester) + Offset(size.width * 0.75, size.height * 0.75);
      await tester.tapAt(blank);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tapAt(blank);
      await tester.pump();
      assertCentered(reason: '双击空白后内容中心应回到视口中心');
    });
  });

  // -------------------------------------------------------------------------
  // 框选与多选（ProcessOn 核心）
  // -------------------------------------------------------------------------

  group('框选与多选', () {
    testWidgets('空白拖拽框选（相交即选；右面板显示已选数量）', (WidgetTester tester) async {
      await _pumpEditor(tester, const WbFlowchartEditor());
      await tester.pump();
      expect(find.text('已选 3 个节点'), findsNothing);

      // 从空白（示例模型右下侧）拖向左上，覆盖全部 3 个节点。
      final Offset tl = _canvasTopLeft(tester);
      await _dragFrom(
        tester,
        tl + const Offset(760, 520),
        const Offset(-360, -520),
      );

      expect(find.text('已选 3 个节点'), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-nodes-remove')), findsOneWidget);
      // 多选时不显示单节点文本输入框。
      expect(find.byKey(_key('wb-ctx-flow-node-text')), findsNothing);
    });

    testWidgets('Shift 点选加选 / 无 Shift 再点替换为单选', (WidgetTester tester) async {
      await _pumpEditor(tester, const WbFlowchartEditor());
      await tester.pump();

      await tester.tap(find.byKey(_key('wb-ctx-flow-node-n1')));
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-flow-node-text')), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.byKey(_key('wb-ctx-flow-node-n3')));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(find.text('已选 2 个节点'), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-nodes-remove')), findsOneWidget);

      // 无 Shift 点第三个节点：替换为单选。
      await tester.tap(find.byKey(_key('wb-ctx-flow-node-n2')));
      await tester.pump();
      expect(find.text('已选 2 个节点'), findsNothing);
      expect(find.byKey(_key('wb-ctx-flow-node-text')), findsOneWidget);
    });

    testWidgets('多选整体拖动：拖动任一所选节点整体位移', (WidgetTester tester) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();

      final Offset tl = _canvasTopLeft(tester);
      await _dragFrom(
        tester,
        tl + const Offset(760, 520),
        const Offset(-360, -520),
      );
      expect(find.text('已选 3 个节点'), findsOneWidget);

      final WbFlowNode n1 = models.last.nodeById('n1')!;
      final WbFlowNode n3 = models.last.nodeById('n3')!;
      await _dragBy(
        tester,
        find.byKey(_key('wb-ctx-flow-node-n2')),
        const Offset(30, 20),
      );

      // 全选时无其余节点参与吸附 → 位移精确等于拖拽增量。
      expect(models.last.nodeById('n1')!.x - n1.x, closeTo(30, 1e-6));
      expect(models.last.nodeById('n1')!.y - n1.y, closeTo(20, 1e-6));
      expect(models.last.nodeById('n3')!.x - n3.x, closeTo(30, 1e-6));
      expect(models.last.nodeById('n3')!.y - n3.y, closeTo(20, 1e-6));
    });

    testWidgets('Ctrl+A 全选，Delete 批量删除（级联清理连线）', (WidgetTester tester) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();

      await tester.tap(find.byKey(_key('wb-ctx-flow-node-n1')));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('已选 3 个节点'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(models.last.nodes, isEmpty);
      expect(models.last.connectors, isEmpty, reason: '删除节点应级联清理关联连线');
    });

    testWidgets('方向键微调：1px；Shift + 方向键 10px', (WidgetTester tester) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();

      await tester.tap(find.byKey(_key('wb-ctx-flow-node-n1')));
      await tester.pump();
      final double x0 = models.last.nodeById('n1')!.x;
      final double y0 = models.last.nodeById('n1')!.y;

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(models.last.nodeById('n1')!.x, closeTo(x0 + 1, 1e-6));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(models.last.nodeById('n1')!.y, closeTo(y0 + 10, 1e-6));
      // 其余节点不受影响。
      expect(models.last.nodeById('n2')!.y, closeTo(y0 + 106, 1e-6));
    });
  });

  // -------------------------------------------------------------------------
  // 对齐参考线
  // -------------------------------------------------------------------------

  group('对齐参考线', () {
    testWidgets('拖拽吸附：moving 右缘对齐目标左缘（阈值 6 内，断言模型坐标）', (
      WidgetTester tester,
    ) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      const WbFlowchartModel seed = WbFlowchartModel(
        nodes: <WbFlowNode>[
          WbFlowNode(id: 'a', x: 100, y: 100, text: 'A'),
          WbFlowNode(id: 'b', x: 400, y: 300, text: 'B'),
        ],
      );
      await _pumpEditor(
        tester,
        WbFlowchartEditor(initialModel: seed, onChanged: models.add),
      );
      await tester.pump();
      expect(models, isEmpty, reason: '注入模型不触发初始布局');

      // 拖 a（默认 132x46）到 right = 397：距 b.left = 400 差 3 < 阈值 6
      // → 吸附修正 +3；y 无候选吸附，精确 +40。
      final Offset tl = _canvasTopLeft(tester);
      await _dragFrom(tester, tl + const Offset(166, 123), const Offset(165, 40));

      final WbFlowNode a = models.last.nodeById('a')!;
      expect(a.x, closeTo(268, 1e-6));
      expect(a.y, closeTo(140, 1e-6));
      // 目标节点保持原位。
      expect(models.last.nodeById('b')!.x, 400);
      expect(models.last.nodeById('b')!.y, 300);
    });
  });

  // -------------------------------------------------------------------------
  // 端口四向连线与快速建节点
  // -------------------------------------------------------------------------

  group('端口四向连线与快速建节点', () {
    testWidgets('选中后四向端口渲染；右端口拖到目标节点建连线', (WidgetTester tester) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      const WbFlowchartModel seed = WbFlowchartModel(
        nodes: <WbFlowNode>[
          WbFlowNode(id: 'a', x: 300, y: 300, text: 'A'),
          WbFlowNode(id: 'b', x: 800, y: 300, text: 'B'),
        ],
      );
      await _pumpEditor(
        tester,
        WbFlowchartEditor(initialModel: seed, onChanged: models.add),
      );
      await tester.pump();

      // 未选中 / 未悬停：端口不渲染。
      expect(find.byKey(_key('wb-ctx-flow-port-a-right')), findsNothing);

      await tester.tap(find.byKey(_key('wb-ctx-flow-node-a')));
      await tester.pump();
      for (final WbFlowPortSide side in WbFlowPortSide.values) {
        expect(
          find.byKey(_key('wb-ctx-flow-port-a-${side.id}')),
          findsOneWidget,
          reason: side.id,
        );
      }

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_key('wb-ctx-flow-port-a-right'))),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(20, 20));
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(_key('wb-ctx-flow-node-b'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(models, isNotEmpty, reason: '连线成功应上报 onChanged');
      expect(models.last.connectors.length, 1);
      final WbFlowConnector added = models.last.connectors.single;
      expect(added.fromId, 'a');
      expect(added.toId, 'b');
    });

    testWidgets('端口拖到空白：弹出快速创建浮层，选中即建节点并连线', (
      WidgetTester tester,
    ) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      const WbFlowchartModel seed = WbFlowchartModel(
        nodes: <WbFlowNode>[
          WbFlowNode(id: 'a', x: 300, y: 300, text: 'A'),
          WbFlowNode(id: 'b', x: 800, y: 300, text: 'B'),
        ],
      );
      await _pumpEditor(
        tester,
        WbFlowchartEditor(initialModel: seed, onChanged: models.add),
      );
      await tester.pump();

      await tester.tap(find.byKey(_key('wb-ctx-flow-node-a')));
      await tester.pump();

      // 拖到空白处松手（世界坐标 (900, 700)，远离 a / b）。
      final Offset tl = _canvasTopLeft(tester);
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_key('wb-ctx-flow-port-a-right'))),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(20, 20));
      await tester.pump();
      await gesture.moveTo(tl + const Offset(900, 700));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      // 浮层出现：三个分组均渲染，chip key 可用。
      expect(find.text('快速创建并连线'), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-quick-shape-process')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-quick-shape-umlClass')), findsOneWidget);

      await tester.tap(find.byKey(_key('wb-ctx-flow-quick-shape-process')));
      await tester.pump();

      expect(find.text('快速创建并连线'), findsNothing, reason: '选中后浮层收起');
      expect(models.last.nodes.length, 3);
      final WbFlowNode created = models.last.nodes.last;
      expect(created.type, WbFlowNodeType.process);
      // 落点中心对齐松手位置。
      expect(created.x, closeTo(900 - 132 / 2, 0.5));
      expect(created.y, closeTo(700 - 46 / 2, 0.5));
      expect(models.last.connectors.single.fromId, 'a');
      expect(models.last.connectors.single.toId, created.id);
    });
  });

  // -------------------------------------------------------------------------
  // 内联改字
  // -------------------------------------------------------------------------

  group('内联改字', () {
    testWidgets('双击节点：原位 TextField；Enter 提交；Esc 取消不提交', (
      WidgetTester tester,
    ) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();

      final Finder node = find.byKey(_key('wb-ctx-flow-node-n2'));
      final Finder field =
          find.byKey(_key('wb-ctx-flow-node-editor-field'));
      expect(field, findsNothing);

      // 双击进入内联编辑。
      await tester.tap(node);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(node);
      await tester.pump();
      expect(field, findsOneWidget);

      // Enter（完成动作）提交。
      await tester.enterText(field, '改名');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(field, findsNothing);
      expect(models.last.nodeById('n2')!.text, '改名');

      // 再次双击进入，Esc 取消不提交。
      await tester.tap(node);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(node);
      await tester.pump();
      expect(field, findsOneWidget);
      await tester.enterText(field, '不保存');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(field, findsNothing);
      expect(models.last.nodeById('n2')!.text, '改名');
    });
  });

  // -------------------------------------------------------------------------
  // B2.2 缩放后的核心交互
  // -------------------------------------------------------------------------

  group('缩放后的核心交互（B2.2）', () {
    testWidgets('左图形库点击添加节点（onChanged 上报 +1）', (WidgetTester tester) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();
      expect(models, isNotEmpty, reason: '初始自动布局应触发 onChanged');
      final int before = models.last.nodes.length;

      final Finder item = find.byKey(_key('wb-ctx-flow-shape-process'));
      await tester.ensureVisible(item);
      await tester.pump();
      await tester.tap(item);
      await tester.pump();

      expect(models.last.nodes.length, before + 1);
      final WbFlowNode added = models.last.nodes.last;
      expect(added.type, WbFlowNodeType.process);
      expect(added.text, WbFlowNodeType.process.label);
      // 添加后自动选中 → 右面板显示节点属性（可删除）。
      expect(find.byKey(_key('wb-ctx-flow-node-remove')), findsOneWidget);
    });

    testWidgets('图形库拖拽放置：落点按逆变换映射为世界坐标（144%）', (
      WidgetTester tester,
    ) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();

      await _tapZoom(tester, 'wb-ctx-flow-zoom-in', times: 2);
      final double scale = _scaleOf(tester);
      expect(scale, closeTo(1.44, 1e-6));
      final int before = models.last.nodes.length;

      // 目标点：画布视口中心偏左上（避开示例节点），保持在可视区内。
      final Offset canvasCenter =
          _canvasTopLeft(tester) + _canvasSize(tester).center(Offset.zero);
      final Offset target = canvasCenter + const Offset(-200, -150);

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_key('wb-ctx-flow-shape-database'))),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(models.last.nodes.length, before + 1);
      final WbFlowNode added = models.last.nodes.last;
      expect(added.type, WbFlowNodeType.database);

      // 期望世界坐标落点：按相机逆变换（命中测试自动完成同一换算）。
      final Offset expectedWorld = _worldAtGlobal(tester, target);
      expect(added.x + added.width / 2, closeTo(expectedWorld.dx, 1.5));
      expect(added.y + added.height / 2, closeTo(expectedWorld.dy, 1.5));
    });

    testWidgets('组件拖拽放置：内嵌组件数据 + 长边 160 等比尺寸', (WidgetTester tester) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      const WbFlowComponent component = WbFlowComponent(
        id: 'cmp-drag',
        name: '宽幅组件',
        mime: WbFlowComponent.mimePng,
        data: 'AA==',
        width: 320,
        height: 160,
      );
      final WbFlowMemoryLibraryStore store = WbFlowMemoryLibraryStore(
        const WbFlowLibraryPrefs(
          enabledLibraries: <String>{'custom'},
          components: <WbFlowComponent>[component],
        ),
      );
      await _pumpEditor(
        tester,
        WbFlowchartEditor(libraryStore: store, onChanged: models.add),
      );
      await tester.pump();

      // 仅启用「我的组件」库：面板仅渲染组件分组（未注入导入器）。
      final Finder item = find.byKey(_key('wb-ctx-flow-component-cmp-drag'));
      await tester.ensureVisible(item);
      await tester.pump();
      final int before = models.last.nodes.length;

      final Offset canvasCenter =
          _canvasTopLeft(tester) + _canvasSize(tester).center(Offset.zero);
      final Offset target = canvasCenter + const Offset(240, -160);

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(item),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(models.last.nodes.length, before + 1);
      final WbFlowNode added = models.last.nodes.last;
      expect(added.type, WbFlowNodeType.customComponent);
      expect(added.component?.id, 'cmp-drag');
      expect(added.text, '宽幅组件');
      // 320x160 长边 320 > 160 → 等比缩至 160x80。
      expect(added.width, 160);
      expect(added.height, 80);

      final Offset expectedWorld = _worldAtGlobal(tester, target);
      expect(added.x + added.width / 2, closeTo(expectedWorld.dx, 1.5));
      expect(added.y + added.height / 2, closeTo(expectedWorld.dy, 1.5));
    });

    testWidgets('缩放后节点拖拽：跟随指针（世界位移 = 屏幕位移 / scale）', (
      WidgetTester tester,
    ) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      // 注入贴近视口中心的紧凑模型（缩放后 a / b 均留在视口内）。
      const WbFlowchartModel seed = WbFlowchartModel(
        nodes: <WbFlowNode>[
          WbFlowNode(id: 'a', x: 526, y: 542, text: 'A'),
          WbFlowNode(id: 'b', x: 750, y: 542, text: 'B'),
        ],
      );
      await _pumpEditor(
        tester,
        WbFlowchartEditor(initialModel: seed, onChanged: models.add),
      );
      await tester.pump();

      await _tapZoom(tester, 'wb-ctx-flow-zoom-in', times: 2);
      expect(_scaleOf(tester), closeTo(1.44, 1e-6));
      final Finder node = find.byKey(_key('wb-ctx-flow-node-a'));
      final Offset beforeVisual = tester.getTopLeft(node);
      // 注入模型不触发初始自动布局（尊重外部坐标），以注入常量作为初态。
      const double worldX0 = 526;
      const double worldY0 = 542;

      await _dragBy(tester, node, const Offset(24, 12));

      final Offset afterVisual = tester.getTopLeft(node);
      // 视觉位移 ≈ 指针位移（若错误地再除一次 scale，会放大到 34.56 / 17.28）。
      expect(afterVisual.dx - beforeVisual.dx, closeTo(24, 2));
      expect(afterVisual.dy - beforeVisual.dy, closeTo(12, 2));
      // 世界坐标位移 = 屏幕位移 / 1.44（onPanUpdate.delta 已是局部坐标）。
      expect(models.last.nodeById('a')!.x - worldX0, closeTo(24 / 1.44, 1.5));
      expect(models.last.nodeById('a')!.y - worldY0, closeTo(12 / 1.44, 1.5));
    });

    testWidgets('缩放后端口拖拽连线：a → b（globalPosition 逆变换命中）', (
      WidgetTester tester,
    ) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      // 注入紧凑模型：a / b 水平相距 500，144% 缩放后端口与目标均留在视口内。
      // 注入模型跳过自动布局、不在初始化时上报 onChanged。
      const WbFlowchartModel seed = WbFlowchartModel(
        nodes: <WbFlowNode>[
          WbFlowNode(id: 'a', x: 300, y: 300, text: 'A'),
          WbFlowNode(id: 'b', x: 800, y: 300, text: 'B'),
        ],
      );
      await _pumpEditor(
        tester,
        WbFlowchartEditor(initialModel: seed, onChanged: models.add),
      );
      await tester.pump();

      await _tapZoom(tester, 'wb-ctx-flow-zoom-in', times: 2);
      expect(_scaleOf(tester), closeTo(1.44, 1e-6));

      // 缩放后点选 a（命中测试沿变换链自动逆变换）→ 四向端口出现。
      await tester.tap(find.byKey(_key('wb-ctx-flow-node-a')));
      await tester.pump();

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_key('wb-ctx-flow-port-a-right'))),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(20, 20));
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(_key('wb-ctx-flow-node-b'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(models, isNotEmpty, reason: '连线成功应上报 onChanged');
      expect(models.last.connectors.length, 1);
      final WbFlowConnector added = models.last.connectors.single;
      expect(added.fromId, 'a');
      expect(added.toId, 'b');
    });

    testWidgets('缩放后选中节点按 Delete 删除（级联清理连线）', (
      WidgetTester tester,
    ) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      const WbFlowchartModel seed = WbFlowchartModel(
        nodes: <WbFlowNode>[
          WbFlowNode(id: 'a', x: 526, y: 542, text: 'A'),
          WbFlowNode(id: 'b', x: 750, y: 542, text: 'B'),
        ],
        connectors: <WbFlowConnector>[
          WbFlowConnector(id: 'c1', fromId: 'a', toId: 'b'),
        ],
      );
      await _pumpEditor(
        tester,
        WbFlowchartEditor(initialModel: seed, onChanged: models.add),
      );
      await tester.pump();

      await _tapZoom(tester, 'wb-ctx-flow-zoom-in', times: 2);
      expect(find.text('144%'), findsOneWidget);

      // 缩放后点选 b → 右面板出现删除按钮。
      await tester.tap(find.byKey(_key('wb-ctx-flow-node-b')));
      await tester.pump();
      expect(
        find.byKey(_key('wb-ctx-flow-node-remove')),
        findsOneWidget,
        reason: '选中后右面板出现删除按钮',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(models.last.nodes.length, 1);
      expect(models.last.nodes.single.id, 'a');
      expect(models.last.connectors, isEmpty, reason: '删除节点应级联清理关联连线');
    });
  });
}
