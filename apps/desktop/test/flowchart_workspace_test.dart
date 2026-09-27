/// 流程图编辑器全窗三区工作区 + 画布缩放测试（第三轮缺陷修复 · 波次 B2）。
///
/// 覆盖：
/// - **全窗三区布局（B2.1）**：左图形库（`wb-ctx-flow-left-panel`，176 宽）/
///   中间最大化画布（`wb-ctx-flow-preview-transform`）/ 右属性
///   （`wb-ctx-flow-right-panel`，240 宽）；不再渲染旧的 420 宽面板卡片
///   （[WbContextEditorShell] 与内嵌标题文案均不存在）；
/// - **画布缩放（B2.2）**：工具条 +（1.2x 步进）/ − / 重置 100%，滚轮
///   factor = exp(-dy / 320)、clamp 0.25~3.0（`Transform.scale` 围绕中心）；
/// - **缩放后的核心交互**：左库点击 / 拖拽添加（落点 = 指针位置）、节点
///   拖拽跟随指针（世界位移 = 屏幕位移 / scale，命中测试自动逆变换）、
///   端口拖拽连线、Delete 删除选中节点。
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

/// 拖拽手势：第一次移动越过触摸 slop（`DragStartBehavior.start` 不派发该段
/// 增量），第二次移动 [delta] 实际传递给 onPanUpdate。
Future<void> _dragBy(WidgetTester tester, Finder target, Offset delta) async {
  final TestGesture gesture =
      await tester.startGesture(tester.getCenter(target));
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.moveBy(const Offset(36, 36));
  await tester.pump();
  await gesture.moveBy(delta);
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

/// 向中间画布中心发送一次鼠标滚轮信号（dy < 0 放大）。
Future<void> _scrollPreview(WidgetTester tester, double dy) async {
  final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
  final Offset center =
      tester.getCenter(find.byKey(_key('wb-ctx-flow-preview-transform')));
  await tester.sendEventToBinding(pointer.hover(center));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

/// 当前预览区缩放值（读取 `Transform.scale` 矩阵的 X 轴缩放）。
///
/// 注：不能用 `getMaxScaleOnAxis`——Z 轴固定为 1.0，缩小时它只会返回 1.0。
double _scaleOf(WidgetTester tester) {
  final Transform transform = tester.widget<Transform>(
    find.byKey(_key('wb-ctx-flow-preview-transform')),
  );
  return transform.transform.entry(0, 0);
}

/// 点击工具条缩放按钮 [times] 次（内部逐次 pump）。
Future<void> _tapZoom(WidgetTester tester, String key, {int times = 1}) async {
  for (int i = 0; i < times; i++) {
    await tester.tap(find.byKey(_key(key)));
    await tester.pump();
  }
}

void main() {
  // -------------------------------------------------------------------------
  // B2.1 全窗三区布局
  // -------------------------------------------------------------------------

  group('流程图全窗三区工作区（B2.1）', () {
    testWidgets('三区渲染：左图形库 / 中画布 / 右属性 + 缩放控件', (
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
      expect(
        tester
            .getSize(find.byKey(_key('wb-ctx-flow-preview-transform')))
            .width,
        greaterThan(900),
      );

      // 左面板纵向图形库：9 种图形项全部渲染；示例模型节点渲染在画布上。
      for (final WbFlowNodeType type in WbFlowNodeType.values) {
        expect(
          find.byKey(_key('wb-ctx-flow-shape-${type.id}')),
          findsOneWidget,
          reason: type.id,
        );
      }
      expect(find.byKey(_key('wb-ctx-flow-node-n1')), findsOneWidget);

      // 缩放控件：- / 百分比 / + / 重置。
      expect(find.byKey(_key('wb-ctx-flow-zoom-out')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-zoom-in')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-zoom-reset')), findsOneWidget);
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

    testWidgets('滚轮：factor = exp(-dy/320)，clamp 0.25~3.0', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(tester, const WbFlowchartEditor());
      await tester.pump();

      // 上滚 160：exp(0.5) ≈ 1.6487 → 165%。
      await _scrollPreview(tester, -160);
      expect(find.text('165%'), findsOneWidget);
      expect(_scaleOf(tester), closeTo(math.exp(0.5), 1e-6));

      // 大幅下滚：clamp 到下限 25%。
      await _scrollPreview(tester, 2000);
      expect(find.text('25%'), findsOneWidget);
      expect(_scaleOf(tester), closeTo(0.25, 1e-6));

      // 大幅上滚：clamp 到上限 300%。
      await _scrollPreview(tester, -4000);
      expect(find.text('300%'), findsOneWidget);
      expect(_scaleOf(tester), closeTo(3.0, 1e-6));

      // 反向对称：下滚 160 → 300% × exp(-0.5) ≈ 181.96% → 182%。
      await _scrollPreview(tester, 160);
      expect(find.text('182%'), findsOneWidget);
      expect(_scaleOf(tester), closeTo(3 * math.exp(-0.5), 1e-6));
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

      final Finder canvas = find.byKey(_key('wb-ctx-flow-preview-transform'));
      final RenderBox box = tester.renderObject<RenderBox>(canvas);
      final Offset boxTopLeft = box.localToGlobal(Offset.zero);
      final Offset boxCenter = box.size.center(Offset.zero);
      // 目标点：画布中心偏左上（避开示例节点），保持在可视区内。
      final Offset target = boxTopLeft + boxCenter + const Offset(-200, -150);

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

      // 期望世界坐标落点：围绕中心逆缩放（命中测试自动完成同一换算）。
      final Offset expectedWorld =
          boxCenter + (target - boxTopLeft - boxCenter) / scale;
      expect(added.x + added.width / 2, closeTo(expectedWorld.dx, 1.5));
      expect(added.y + added.height / 2, closeTo(expectedWorld.dy, 1.5));
    });

    testWidgets('缩放后节点拖拽：跟随指针（世界位移 = 屏幕位移 / scale）', (
      WidgetTester tester,
    ) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();

      await _tapZoom(tester, 'wb-ctx-flow-zoom-in', times: 2);
      final Finder node = find.byKey(_key('wb-ctx-flow-node-n2'));
      final Offset beforeVisual = tester.getTopLeft(node);
      final double worldX0 = models.last.nodeById('n2')!.x;
      final double worldY0 = models.last.nodeById('n2')!.y;

      await _dragBy(tester, node, const Offset(24, 12));

      final Offset afterVisual = tester.getTopLeft(node);
      // 视觉位移 ≈ 指针位移（若错误地再除一次 scale，会放大到 34.56 / 17.28）。
      expect(afterVisual.dx - beforeVisual.dx, closeTo(24, 2));
      expect(afterVisual.dy - beforeVisual.dy, closeTo(12, 2));
      // 世界坐标位移 = 屏幕位移 / 1.44（DragUpdateDetails.delta 已是局部坐标）。
      expect(models.last.nodeById('n2')!.x - worldX0, closeTo(24 / 1.44, 1.5));
      expect(models.last.nodeById('n2')!.y - worldY0, closeTo(12 / 1.44, 1.5));
    });

    testWidgets('缩放后端口拖拽连线：a → b（globalPosition 逆变换命中）', (
      WidgetTester tester,
    ) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      // 注入紧凑模型：a / b 水平相距 500，144% 缩放后端口与目标均留在视口内
      // （默认示例模型会自动布局铺满画布高度，缩放后首尾节点出视口，不便驱动）。
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

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_key('wb-ctx-flow-port-a'))),
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
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();

      await _tapZoom(tester, 'wb-ctx-flow-zoom-in', times: 2);
      expect(find.text('144%'), findsOneWidget);
      final int nodesBefore = models.last.nodes.length;
      final int connectorsBefore = models.last.connectors.length;

      // 缩放后点选预览中的节点（命中测试沿变换链自动逆变换）。
      await tester.tap(find.byKey(_key('wb-ctx-flow-node-n2')));
      await tester.pump();
      expect(
        find.byKey(_key('wb-ctx-flow-node-remove')),
        findsOneWidget,
        reason: '选中后右面板出现删除按钮',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(models.last.nodes.length, nodesBefore - 1);
      expect(models.last.nodes.any((WbFlowNode n) => n.id == 'n2'), isFalse);
      // n2 是中间节点：删除会级联清理两条关联连线（n1→n2、n2→n3）。
      expect(
        models.last.connectors.length,
        lessThan(connectorsBefore),
        reason: '删除节点应级联清理关联连线',
      );
      expect(
        models.last.connectors.any(
          (WbFlowConnector c) => c.fromId == 'n2' || c.toId == 'n2',
        ),
        isFalse,
        reason: '不应残留指向已删除节点的连线',
      );
    });
  });
}
