/// 专业元素上下文编辑器测试（Wave 3.6）。
///
/// 覆盖 `lib/widgets/context_editors/` 全部组件：
/// - 流程图：模型 / 泳道 / 自动布局（分层 + 环回退）/ 模板 / 拖拽微调 /
///   连线模式 / 泳道编辑 / 模板一键填充；
/// - 表格：单元格原位编辑 / 行列增减 / 样式 chip / 模型边界守卫；
/// - 思维导图：三种布局引擎 / 添加 / 重命名 / 删除 / 折叠 / 布局切换；
/// - 函数图像：表达式编译器 / 分段采样器 / 编辑器交互 / 定义域 / 颜色显隐；
/// - 3D 对象：对象 / 材质 / 光照切换 / 变换参数 / 重置 / 渲染烟雾测试；
/// - 快速创建：按钮条 / 浮出入口 / 编辑器构建映射。
///
/// 说明：不含 golden 截图断言（跨平台字体差异）；全部通过 finder /
/// 手势 / 文本输入驱动；组件自包含，测试不注入 Provider / 主题扩展。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';
import 'package:whiteboard_desktop/widgets/context_editors/context_editor_shell.dart';
import 'package:whiteboard_desktop/widgets/context_editors/flowchart_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/function_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/mindmap_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/quick_create.dart';
import 'package:whiteboard_desktop/widgets/context_editors/render3d_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/table_editor.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_editor.dart';

// ---------------------------------------------------------------------------
// 测试基建
// ---------------------------------------------------------------------------

/// 编辑器面板默认挂载尺寸（全窗三区工作区需要足够宽度：左 176 + 右 240
/// + 中间画布；高有界）。
const Size _panel = Size(1280, 900);

/// 在 1600x1200 逻辑窗口中挂载编辑器面板（无 Provider 环境）。
Future<void> _pumpEditor(
  WidgetTester tester,
  Widget editor, {
  Size size = _panel,
}) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: editor,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 在滑杆（[WbEditorSlider]）的 [fraction] 比例位置点击（先滚动到可见区）。
Future<void> _tapSliderAt(WidgetTester tester, Key key, double fraction) async {
  final Finder slider =
      find.descendant(of: find.byKey(key), matching: find.byType(Slider));
  await tester.ensureVisible(slider);
  await tester.pump();
  final Rect rect = tester.getRect(slider);
  await tester.tapAt(Offset(rect.left + rect.width * fraction, rect.center.dy));
  await tester.pump();
}

/// 拖拽手势：第一次移动越过触摸 slop（被识别器消耗），
/// 第二次移动 [delta] 实际传递给 onPanUpdate。
Future<void> _dragBy(
  WidgetTester tester,
  Finder target,
  Offset delta, {
  Offset slop = const Offset(36, 36),
}) async {
  final TestGesture gesture = await tester.startGesture(tester.getCenter(target));
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.moveBy(slop);
  await tester.pump();
  await gesture.moveBy(delta);
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

Key _key(String value) => ValueKey<String>(value);

void main() {
  // -------------------------------------------------------------------------
  // 调色板
  // -------------------------------------------------------------------------

  group('调色板与画布口径', () {
    test('WbContextPalette 前 4 色与 WbCanvasPalette 一致', () {
      for (int i = 0; i < WbCanvasPalette.shapeColors.length; i++) {
        expect(
          WbContextPalette.swatches[i].toARGB32(),
          WbCanvasPalette.shapeColors[i],
          reason: '第 $i 色应与画布形状主色一致',
        );
      }
      expect(
        WbContextPalette.flowProcess.toARGB32(),
        WbCanvasPalette.shapeColors[0],
      );
      expect(WbContextPalette.swatches.length, greaterThanOrEqualTo(4));
      expect(WbContextPalette.curveSwatches.length, greaterThanOrEqualTo(4));
      // softFill 默认浅透明（淡底彩边风格）
      final Color fill = WbContextPalette.softFill(WbContextPalette.flowStart);
      expect(fill.a, closeTo(0.14, 1e-6));
      expect(fill.toARGB32(), isNot(WbContextPalette.flowStart.toARGB32()));
    });
  });

  // -------------------------------------------------------------------------
  // 流程图：模型 / 布局 / 模板（单元）
  // -------------------------------------------------------------------------

  group('流程图模型 / 自动布局 / 模板', () {
    test('节点与连线编辑（含级联清理）', () {
      final WbFlowchartModel base = WbFlowchartModel.sample();
      expect(base.nodes.length, 3);
      expect(base.connectors.length, 2);

      final WbFlowchartModel updated = base
          .updateNode('n2', text: '改名', x: 5)
          .upsertNode(const WbFlowNode(id: 'n4', x: 0, y: 0, text: '新'));
      expect(updated.nodes.length, 4);
      expect(updated.nodeById('n2')!.text, '改名');
      expect(updated.nodeById('n2')!.x, 5);

      // 重复连线 / 自环 / 未知节点均被忽略（返回自身）
      expect(
        updated
            .addConnector(
              const WbFlowConnector(id: 'cx', fromId: 'n1', toId: 'n2'),
            )
            .connectors
            .length,
        updated.connectors.length,
      );
      expect(
        updated
            .addConnector(
              const WbFlowConnector(id: 'cy', fromId: 'n1', toId: 'n1'),
            )
            .connectors
            .length,
        updated.connectors.length,
      );
      expect(
        updated
            .addConnector(
              const WbFlowConnector(id: 'cz', fromId: 'n1', toId: 'zz'),
            )
            .connectors
            .length,
        updated.connectors.length,
      );

      // 新连线与邻接查询
      final WbFlowchartModel linked = updated.addConnector(
        const WbFlowConnector(id: 'c3', fromId: 'n1', toId: 'n4'),
      );
      expect(linked.connectorsOf('n1').length, 2);

      // 删除节点自动清理关联连线（仅保留 n1 -> n4）
      final WbFlowchartModel removed = linked.removeNode('n2');
      expect(removed.nodes.length, 3);
      expect(removed.nodeById('n2'), isNull);
      expect(removed.connectors.length, 1);
      expect(removed.connectors.single.fromId, 'n1');
      expect(removed.connectors.single.toId, 'n4');
    });

    test('泳道增删改与节点归类', () {
      final WbFlowchartModel withLane = WbFlowchartModel.sample()
          .addLane(const WbFlowLane(id: 'l1', name: '泳道 1'))
          .addLane(const WbFlowLane(id: 'l2', name: '泳道 2'))
          .updateNode('n1', laneId: 'l1')
          .updateNode('n2', laneId: 'l2');
      expect(withLane.lanes.length, 2);
      expect(withLane.nodesOfLane('l1').single.id, 'n1');
      expect(withLane.nodesOfLane('l2').single.id, 'n2');

      final WbFlowchartModel renamed = withLane.renameLane('l1', '研发');
      expect(renamed.laneById('l1')!.name, '研发');

      // 默认纵向 → 翻转后横向（对全部泳道生效）
      expect(renamed.lanes.first.orientation, WbSwimlaneOrientation.vertical);
      final WbFlowchartModel flipped = renamed.flipLaneOrientation();
      expect(
        flipped.lanes.every(
          (WbFlowLane lane) =>
              lane.orientation == WbSwimlaneOrientation.horizontal,
        ),
        isTrue,
      );

      // 删除泳道：节点保留但变为未归类
      final WbFlowchartModel stripped = renamed.removeLane('l1');
      expect(stripped.lanes.length, 1);
      expect(stripped.nodeById('n1')!.laneId, isNull);
      expect(stripped.nodeById('n2')!.laneId, 'l2');
    });

    test('自动布局 tb：Kahn 分层 + 固定间距（同层 80 / 层间 60），不再钳制画布', () {
      const WbFlowchartModel model = WbFlowchartModel(
        nodes: <WbFlowNode>[
          WbFlowNode(id: 'n1', x: 0, y: 0, type: WbFlowNodeType.start),
          WbFlowNode(id: 'n2', x: 0, y: 0),
          WbFlowNode(id: 'n3', x: 0, y: 0, type: WbFlowNodeType.decision),
          WbFlowNode(id: 'n4', x: 0, y: 0),
          WbFlowNode(id: 'n5', x: 0, y: 0),
        ],
        connectors: <WbFlowConnector>[
          WbFlowConnector(id: 'c1', fromId: 'n1', toId: 'n2'),
          WbFlowConnector(id: 'c2', fromId: 'n2', toId: 'n3'),
          WbFlowConnector(id: 'c3', fromId: 'n3', toId: 'n4'),
          WbFlowConnector(id: 'c4', fromId: 'n3', toId: 'n5'),
        ],
      );
      final WbFlowchartModel laid = WbFlowAutoLayout.apply(
        model,
        canvas: const Size(400, 400),
      );
      double x(String id) => laid.nodeById(id)!.x;
      double y(String id) => laid.nodeById(id)!.y;
      double w(String id) => laid.nodeById(id)!.width;
      double h(String id) => laid.nodeById(id)!.height;
      expect(y('n1'), lessThan(y('n2')));
      expect(y('n2'), lessThan(y('n3')));
      expect(y('n3'), lessThan(y('n4')));
      expect(y('n4'), y('n5'), reason: '同层共享 y');
      expect(x('n4'), lessThan(x('n5')), reason: '同层按插入序水平排开');
      // 固定间距：层间 60（下层 y = 上层 y + 层高 + 60）。
      expect(y('n2') - (y('n1') + h('n1')), closeTo(60, 1e-6));
      expect(y('n3') - (y('n2') + h('n2')), closeTo(60, 1e-6));
      expect(y('n4') - (y('n3') + h('n3')), closeTo(60, 1e-6));
      // 同层水平间距 80。
      expect(x('n5') - (x('n4') + w('n4')), closeTo(80, 1e-6));
      // 无限画布口径：不再钳制进画布，坐标有限；锚点取内容包围盒顶边。
      for (final WbFlowNode node in laid.nodes) {
        expect(node.x.isFinite && node.y.isFinite, isTrue);
      }
      expect(y('n1'), closeTo(0, 1e-6), reason: '锚点 = 内容包围盒顶边');
    });

    test('自动布局 lr：主方向为 x', () {
      const WbFlowchartModel model = WbFlowchartModel(
        direction: WbFlowLayoutDirection.leftToRight,
        nodes: <WbFlowNode>[
          WbFlowNode(id: 'n1', x: 0, y: 0, type: WbFlowNodeType.start),
          WbFlowNode(id: 'n2', x: 0, y: 0),
          WbFlowNode(id: 'n3', x: 0, y: 0, type: WbFlowNodeType.end),
        ],
        connectors: <WbFlowConnector>[
          WbFlowConnector(id: 'c1', fromId: 'n1', toId: 'n2'),
          WbFlowConnector(id: 'c2', fromId: 'n2', toId: 'n3'),
        ],
      );
      final WbFlowchartModel laid = WbFlowAutoLayout.apply(
        model,
        canvas: const Size(500, 300),
      );
      final double x1 = laid.nodeById('n1')!.x;
      final double x2 = laid.nodeById('n2')!.x;
      final double x3 = laid.nodeById('n3')!.x;
      expect(x1, lessThan(x2));
      expect(x2, lessThan(x3));
      // 层间（x 方向）固定间距 80；锚点 = 画布轴心。
      expect(x2 - (x1 + laid.nodeById('n1')!.width), closeTo(80, 1e-6));
      expect(x3 - (x2 + laid.nodeById('n2')!.width), closeTo(80, 1e-6));
      expect(x1, closeTo(250, 1e-6), reason: 'lr 锚点 = 画布宽度轴心');
    });

    test('自动布局环回退：不丢节点不挂死', () {
      const WbFlowchartModel cyclic = WbFlowchartModel(
        nodes: <WbFlowNode>[
          WbFlowNode(id: 'a', x: 0, y: 0),
          WbFlowNode(id: 'b', x: 0, y: 0),
        ],
        connectors: <WbFlowConnector>[
          WbFlowConnector(id: 'c1', fromId: 'a', toId: 'b'),
          WbFlowConnector(id: 'c2', fromId: 'b', toId: 'a'),
        ],
      );
      final WbFlowchartModel laid = WbFlowAutoLayout.apply(
        cyclic,
        canvas: const Size(400, 400),
      );
      expect(laid.nodes.length, 2);
      final WbFlowNode a = laid.nodeById('a')!;
      final WbFlowNode b = laid.nodeById('b')!;
      expect(a.x.isFinite && a.y.isFinite, isTrue);
      expect(b.x.isFinite && b.y.isFinite, isTrue);
      // 两节点被分到不同层或同层不同列，位置必有区分
      expect(a.x != b.x || a.y != b.y, isTrue);
    });

    test('内置模板 7 个且结构完整、均可布局', () {
      expect(wbFlowTemplates.length, 7);
      final Set<String> ids =
          wbFlowTemplates.map((WbFlowTemplate t) => t.id).toSet();
      expect(
        ids,
        containsAll(<String>[
          'basic',
          'approval',
          'login',
          'swimlane',
          'branch',
          'uml',
          'dfd',
        ]),
      );
      expect(ids.length, wbFlowTemplates.length, reason: '模板 id 唯一');

      final WbFlowchartModel approval = wbFlowTemplates
          .firstWhere((WbFlowTemplate t) => t.id == 'approval')
          .build();
      expect(approval.nodes.length, 6);
      expect(approval.connectors.length, 6);
      expect(
        approval.nodes
            .where((WbFlowNode n) => n.type == WbFlowNodeType.decision)
            .length,
        1,
      );

      final WbFlowchartModel swimlane = wbFlowTemplates
          .firstWhere((WbFlowTemplate t) => t.id == 'swimlane')
          .build();
      expect(swimlane.lanes.length, 4);
      expect(
        swimlane.nodes.every((WbFlowNode n) => n.laneId != null),
        isTrue,
      );

      // UML 类图模板：三段式类框 + 继承箭头。
      final WbFlowchartModel uml = wbFlowTemplates
          .firstWhere((WbFlowTemplate t) => t.id == 'uml')
          .build();
      expect(
        uml.nodes
            .where((WbFlowNode n) => n.type == WbFlowNodeType.umlClass)
            .length,
        3,
      );
      expect(
        uml.nodes
            .firstWhere((WbFlowNode n) => n.id == 'n1')
            .compartments
            .length,
        3,
      );
      expect(
        uml.connectors.every(
          (WbFlowConnector c) => c.arrow == WbFlowArrowStyle.inherit,
        ),
        isTrue,
      );

      // 数据流图模板：开放箭头。
      final WbFlowchartModel dfd = wbFlowTemplates
          .firstWhere((WbFlowTemplate t) => t.id == 'dfd')
          .build();
      expect(dfd.nodes.length, 4);
      expect(
        dfd.connectors.every(
          (WbFlowConnector c) => c.arrow == WbFlowArrowStyle.open,
        ),
        isTrue,
      );

      for (final WbFlowTemplate template in wbFlowTemplates) {
        final WbFlowchartModel built = template.build();
        final WbFlowchartModel laid = WbFlowAutoLayout.apply(
          built,
          canvas: const Size(480, 400),
        );
        expect(laid.nodes.length, built.nodes.length, reason: template.id);
        for (final WbFlowNode node in laid.nodes) {
          expect(
            node.x.isFinite && node.y.isFinite,
            isTrue,
            reason: '${template.id}/${node.id}',
          );
        }
      }
    });

    test('图形库 8 库 / 40 类型：分组计数、默认尺寸抽查与 id 往返', () {
      expect(WbFlowNodeType.values.length, 40);
      const Map<WbFlowShapeLibrary, int> expectedCounts =
          <WbFlowShapeLibrary, int>{
        WbFlowShapeLibrary.flowchart: 9,
        WbFlowShapeLibrary.umlClass: 7,
        WbFlowShapeLibrary.umlSequence: 3,
        WbFlowShapeLibrary.umlUseCase: 3,
        WbFlowShapeLibrary.umlState: 4,
        WbFlowShapeLibrary.dfd: 3,
        WbFlowShapeLibrary.circuit: 10,
        WbFlowShapeLibrary.custom: 1,
      };
      for (final MapEntry<WbFlowShapeLibrary, int> entry
          in expectedCounts.entries) {
        expect(
          WbFlowNodeType.values
              .where((WbFlowNodeType t) => t.library == entry.key)
              .length,
          entry.value,
          reason: entry.key.id,
        );
      }
      // 既有类型默认尺寸（新建节点时采用）。
      expect(WbFlowNodeType.umlClass.defaultWidth, 160);
      expect(WbFlowNodeType.umlClass.defaultHeight, 120);
      expect(WbFlowNodeType.umlActor.defaultWidth, 48);
      expect(WbFlowNodeType.umlActor.defaultHeight, 78);
      expect(WbFlowNodeType.umlUseCase.defaultWidth, 140);
      expect(WbFlowNodeType.umlUseCase.defaultHeight, 60);
      expect(WbFlowNodeType.umlPackage.defaultWidth, 140);
      expect(WbFlowNodeType.umlPackage.defaultHeight, 80);
      expect(WbFlowNodeType.umlNote.defaultWidth, 140);
      expect(WbFlowNodeType.umlNote.defaultHeight, 70);
      expect(WbFlowNodeType.dfdExternal.defaultWidth, 140);
      expect(WbFlowNodeType.dfdExternal.defaultHeight, 60);
      expect(WbFlowNodeType.dfdProcess.defaultWidth, 96);
      expect(WbFlowNodeType.dfdProcess.defaultHeight, 96);
      expect(WbFlowNodeType.dfdStore.defaultWidth, 150);
      expect(WbFlowNodeType.dfdStore.defaultHeight, 50);
      // 新增类型默认尺寸抽查（类图细化 / 时序图 / 用例图 / 状态图 /
      // 电路图 / 组件）。
      expect(WbFlowNodeType.umlInterface.defaultWidth, 160);
      expect(WbFlowNodeType.umlInterface.defaultHeight, 120);
      expect(WbFlowNodeType.umlSimpleClass.defaultWidth, 140);
      expect(WbFlowNodeType.umlSimpleClass.defaultHeight, 50);
      expect(WbFlowNodeType.umlSimpleInterface.defaultWidth, 140);
      expect(WbFlowNodeType.umlSimpleInterface.defaultHeight, 56);
      expect(WbFlowNodeType.umlMultiton.defaultWidth, 160);
      expect(WbFlowNodeType.umlMultiton.defaultHeight, 120);
      expect(WbFlowNodeType.umlLifeline.defaultWidth, 120);
      expect(WbFlowNodeType.umlLifeline.defaultHeight, 160);
      expect(WbFlowNodeType.umlActivation.defaultWidth, 14);
      expect(WbFlowNodeType.umlActivation.defaultHeight, 80);
      expect(WbFlowNodeType.umlObject.defaultWidth, 140);
      expect(WbFlowNodeType.umlObject.defaultHeight, 46);
      expect(WbFlowNodeType.umlSystem.defaultWidth, 300);
      expect(WbFlowNodeType.umlSystem.defaultHeight, 220);
      expect(WbFlowNodeType.umlState.defaultWidth, 140);
      expect(WbFlowNodeType.umlState.defaultHeight, 60);
      expect(WbFlowNodeType.umlInitial.defaultWidth, 24);
      expect(WbFlowNodeType.umlFinal.defaultWidth, 28);
      expect(WbFlowNodeType.umlChoice.defaultWidth, 48);
      expect(WbFlowNodeType.circuitResistor.defaultWidth, 64);
      expect(WbFlowNodeType.circuitResistor.defaultHeight, 24);
      expect(WbFlowNodeType.circuitBattery.defaultWidth, 48);
      expect(WbFlowNodeType.circuitDcSource.defaultWidth, 52);
      expect(WbFlowNodeType.circuitGround.defaultHeight, 28);
      expect(WbFlowNodeType.circuitJunction.defaultWidth, 18);
      expect(WbFlowNodeType.customComponent.defaultWidth, 120);
      expect(WbFlowNodeType.customComponent.defaultHeight, 120);
      // 默认尺寸回退到通用节点尺寸（流程图分组未显式声明的类型）。
      expect(
        WbFlowNodeType.process.defaultWidth,
        WbContextMetrics.flowNodeWidth,
      );
      expect(
        WbFlowNodeType.process.defaultHeight,
        WbContextMetrics.flowNodeHeight,
      );
      // 类型 / 箭头样式 id 往返与未知回退。
      for (final WbFlowNodeType type in WbFlowNodeType.values) {
        expect(WbFlowNodeType.fromId(type.id), type);
      }
      for (final WbFlowArrowStyle style in WbFlowArrowStyle.values) {
        expect(WbFlowArrowStyle.fromId(style.id), style);
      }
      expect(WbFlowNodeType.fromId('unknown'), WbFlowNodeType.process);
      expect(WbFlowArrowStyle.fromId('unknown'), WbFlowArrowStyle.arrow);
    });

    test('UML 类节点 compartments 三段与展示文本', () {
      const WbFlowNode node = WbFlowNode(
        id: 'c1',
        x: 0,
        y: 0,
        type: WbFlowNodeType.umlClass,
        text: 'Order',
        compartments: <String>['Order', '+ id: String', '+ pay(): void'],
      );
      expect(node.displayText, 'Order\n+ id: String\n+ pay(): void');

      // 无 compartments 回退单文本。
      const WbFlowNode plain = WbFlowNode(id: 'p', x: 0, y: 0, text: '处理');
      expect(plain.displayText, '处理');

      // 模型级更新 compartments；空段在展示时被过滤。
      final WbFlowchartModel model = const WbFlowchartModel(
        nodes: <WbFlowNode>[node],
      ).updateNode(
        'c1',
        compartments: <String>['Order', '', '+ pay(): void'],
      );
      expect(model.nodeById('c1')!.displayText, 'Order\n+ pay(): void');

      // copyWith 未指定 compartments 时保持原值。
      expect(node.copyWith(text: '改名').compartments, node.compartments);
    });

    test('类图三段式与构造型口径（WbFlowUmlClassLayout）', () {
      expect(
        WbFlowUmlClassLayout.isThreeSegment(WbFlowNodeType.umlClass),
        isTrue,
      );
      expect(
        WbFlowUmlClassLayout.isThreeSegment(WbFlowNodeType.umlInterface),
        isTrue,
      );
      expect(
        WbFlowUmlClassLayout.isThreeSegment(WbFlowNodeType.umlMultiton),
        isTrue,
      );
      expect(
        WbFlowUmlClassLayout.isThreeSegment(WbFlowNodeType.umlSimpleClass),
        isFalse,
      );
      expect(
        WbFlowUmlClassLayout.stereotypeOf(WbFlowNodeType.umlInterface),
        '«interface»',
      );
      expect(
        WbFlowUmlClassLayout.stereotypeOf(WbFlowNodeType.umlSimpleInterface),
        '«interface»',
      );
      expect(
        WbFlowUmlClassLayout.stereotypeOf(WbFlowNodeType.umlMultiton),
        '«多例»',
      );
      expect(WbFlowUmlClassLayout.stereotypeOf(WbFlowNodeType.umlClass), '');
      // 名带：无构造型 28 / 含构造型行 42；分隔线在名带底与剩余均分处。
      expect(WbFlowUmlClassLayout.nameBand(hasStereotype: false), 28);
      expect(WbFlowUmlClassLayout.nameBand(hasStereotype: true), 42);
      expect(
        WbFlowUmlClassLayout.dividers(WbFlowNodeType.umlClass, 120),
        <double>[28, 74],
      );
      expect(
        WbFlowUmlClassLayout.dividers(WbFlowNodeType.umlInterface, 120),
        <double>[42, 81],
      );
    });

    test('WbFlowShapeSpec 放置尺寸：静态取默认、组件长边 ≤160 等比', () {
      const WbFlowShapeSpec plain = WbFlowShapeSpec(
        type: WbFlowNodeType.umlClass,
      );
      expect(plain.preferredSize, const Size(160, 120));

      const WbFlowComponent wide = WbFlowComponent(
        id: 'cmp-wide',
        name: '宽图',
        mime: WbFlowComponent.mimePng,
        data: 'eA==',
        width: 320,
        height: 160,
      );
      const WbFlowShapeSpec wideSpec = WbFlowShapeSpec(
        type: WbFlowNodeType.customComponent,
        component: wide,
      );
      expect(wideSpec.preferredSize, const Size(160, 80));

      const WbFlowComponent small = WbFlowComponent(
        id: 'cmp-small',
        name: '小图',
        mime: WbFlowComponent.mimePng,
        data: 'eA==',
        width: 48,
        height: 48,
      );
      const WbFlowShapeSpec smallSpec = WbFlowShapeSpec(
        type: WbFlowNodeType.customComponent,
        component: small,
      );
      expect(smallSpec.preferredSize, const Size(48, 48));
    });

    test('批量平移 / 批量删除与连线属性更新', () {
      final WbFlowchartModel base = WbFlowchartModel.sample();

      // 平移仅作用于选中集合。
      final WbFlowchartModel moved =
          base.translateNodes(<String>{'n1', 'n3'}, const Offset(10, -5));
      expect(
        moved.nodeById('n1')!.x,
        closeTo(base.nodeById('n1')!.x + 10, 1e-6),
      );
      expect(
        moved.nodeById('n1')!.y,
        closeTo(base.nodeById('n1')!.y - 5, 1e-6),
      );
      expect(
        moved.nodeById('n3')!.x,
        closeTo(base.nodeById('n3')!.x + 10, 1e-6),
      );
      expect(
        identical(moved.nodeById('n2'), base.nodeById('n2')),
        isTrue,
        reason: '未选中节点保持原实例',
      );
      expect(
        identical(base.translateNodes(<String>{}, Offset.zero), base),
        isTrue,
        reason: '空集返回自身',
      );

      // 批量删除级联清理连线；未知 id 返回自身。
      final WbFlowchartModel removed = base.removeNodes(<String>{'n2'});
      expect(removed.nodes.length, 2);
      expect(removed.connectors, isEmpty, reason: '删除节点级联清理连线');
      expect(identical(base.removeNodes(<String>{'zz'}), base), isTrue);

      // 连线标签与箭头样式更新；未知连线返回自身。
      final WbFlowchartModel styled = base.updateConnector(
        'c1',
        label: '是',
        arrow: WbFlowArrowStyle.inherit,
      );
      expect(styled.connectors.first.label, '是');
      expect(styled.connectors.first.arrow, WbFlowArrowStyle.inherit);
      expect(identical(base.updateConnector('zz', label: 'x'), base), isTrue);
    });

    test('端口四向锚点位于节点四边中点', () {
      const Rect bounds = Rect.fromLTWH(100, 200, 132, 46);
      expect(WbFlowPortSide.top.anchorOn(bounds), const Offset(166, 200));
      expect(WbFlowPortSide.right.anchorOn(bounds), const Offset(232, 223));
      expect(WbFlowPortSide.bottom.anchorOn(bounds), const Offset(166, 246));
      expect(WbFlowPortSide.left.anchorOn(bounds), const Offset(100, 223));
      expect(WbFlowPortSide.values.length, 4);
    });
  });

  // -------------------------------------------------------------------------
  // 流程图：编辑器 Widget
  // -------------------------------------------------------------------------

  group('流程图编辑器 Widget', () {
    testWidgets('挂载示例模型后自动分层布局', (WidgetTester tester) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(
        tester,
        WbFlowchartEditor(onChanged: models.add),
      );
      await tester.pump();
      expect(models, isNotEmpty, reason: '初始布局应触发 onChanged');
      final WbFlowchartModel laid = models.last;
      expect(laid.nodes.length, 3);
      final double y1 = laid.nodeById('n1')!.y;
      final double y2 = laid.nodeById('n2')!.y;
      final double y3 = laid.nodeById('n3')!.y;
      expect(y1, lessThan(y2));
      expect(y2, lessThan(y3));
    });

    testWidgets('注入模型抑制初始布局，自动布局按钮可重排', (WidgetTester tester) async {
      const WbFlowchartModel injected = WbFlowchartModel(
        nodes: <WbFlowNode>[
          WbFlowNode(id: 'a', x: 10, y: 20, text: 'A'),
          WbFlowNode(id: 'b', x: 10, y: 120, text: 'B'),
        ],
        connectors: <WbFlowConnector>[
          WbFlowConnector(id: 'c1', fromId: 'a', toId: 'b'),
        ],
      );
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(
        tester,
        WbFlowchartEditor(initialModel: injected, onChanged: models.add),
      );
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-flow-node-a')), findsOneWidget);
      expect(models, isEmpty, reason: '外部注入模型不应被自动布局');

      await tester.tap(find.byKey(_key('wb-ctx-flow-auto-layout')));
      await tester.pump();
      expect(models, isNotEmpty);
      final WbFlowchartModel laid = models.last;
      expect(laid.nodeById('a')!.y, lessThan(laid.nodeById('b')!.y));
      expect(laid.nodeById('a')!.x, isNot(10), reason: '应被重排居中');
    });

    testWidgets('切换方向为从左到右并重新布局', (WidgetTester tester) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();

      await tester.tap(find.byKey(_key('wb-ctx-flow-direction-lr')));
      await tester.pump();
      final WbFlowchartModel lr = models.last;
      expect(lr.direction, WbFlowLayoutDirection.leftToRight);
      expect(lr.nodeById('n1')!.x, lessThan(lr.nodeById('n2')!.x));
      expect(lr.nodeById('n2')!.x, lessThan(lr.nodeById('n3')!.x));

      await tester.tap(find.byKey(_key('wb-ctx-flow-direction-tb')));
      await tester.pump();
      expect(models.last.direction, WbFlowLayoutDirection.topToBottom);
    });

    testWidgets('节点拖拽微调位置', (WidgetTester tester) async {
      await _pumpEditor(tester, const WbFlowchartEditor());
      await tester.pump();
      final Finder node = find.byKey(_key('wb-ctx-flow-node-n2'));
      expect(node, findsOneWidget);
      final Offset before = tester.getTopLeft(node);

      await _dragBy(tester, node, const Offset(16, 8));
      final Offset after = tester.getTopLeft(node);
      expect(after.dx, greaterThan(before.dx + 4));
      expect(after.dy, greaterThan(before.dy + 2));
      expect(after.dx, lessThanOrEqualTo(before.dx + 80));
      expect(after.dy, lessThanOrEqualTo(before.dy + 60));
    });

    testWidgets('添加与删除节点', (WidgetTester tester) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();

      await tester.tap(find.byKey(_key('wb-ctx-flow-add-node')));
      await tester.pump();
      expect(models.last.nodes.length, 4, reason: '新节点应被追加并选中');

      // 新节点选中后 inspector 出现删除按钮
      await tester.tap(find.byKey(_key('wb-ctx-flow-node-remove')));
      await tester.pump();
      expect(models.last.nodes.length, 3);
    });

    testWidgets('添加节点按钮复用最近创建的类型（工具条无类型芯片）', (
      WidgetTester tester,
    ) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();

      // 工具条不再渲染类型芯片（图形库承担选择）。
      expect(
        find.byKey(_key('wb-ctx-flow-type-start')),
        findsNothing,
      );

      // 图形库点击「开始」→ 创建 start 节点并记为待添加类型。
      final Finder startItem = find.byKey(_key('wb-ctx-flow-shape-start'));
      await tester.ensureVisible(startItem);
      await tester.pump();
      await tester.tap(startItem);
      await tester.pump();
      expect(models.last.nodes.last.type, WbFlowNodeType.start);

      // 「添加节点」按钮沿用最近创建的类型。
      await tester.tap(find.byKey(_key('wb-ctx-flow-add-node')));
      await tester.pump();
      expect(models.last.nodes.last.type, WbFlowNodeType.start);
    });

    testWidgets('连线模式：依次点击两个节点创建连线', (WidgetTester tester) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();
      expect(models.last.connectors.length, 2);

      await tester.tap(find.byKey(_key('wb-ctx-flow-link-mode')));
      await tester.pump();
      await tester.tap(find.byKey(_key('wb-ctx-flow-node-n1')));
      await tester.pump();
      await tester.tap(find.byKey(_key('wb-ctx-flow-node-n3')));
      await tester.pump();

      final WbFlowchartModel model = models.last;
      expect(model.connectors.length, 3);
      final WbFlowConnector last = model.connectors.last;
      expect(last.fromId, 'n1');
      expect(last.toId, 'n3');
    });

    testWidgets('泳道添加 / 重命名 / 删除', (WidgetTester tester) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();

      await tester.tap(find.byKey(_key('wb-ctx-flow-lane-add')));
      await tester.pump();
      expect(models.last.lanes.length, 1);
      expect(models.last.lanes.first.name, '泳道 1');

      // 添加后泳道自动选中 → inspector 出现名称输入框
      await tester.enterText(
        find.byKey(_key('wb-ctx-flow-lane-name')),
        '研发',
      );
      await tester.pump();
      expect(models.last.lanes.first.name, '研发');

      await tester.tap(find.byKey(_key('wb-ctx-flow-lane-remove')));
      await tester.pump();
      expect(models.last.lanes, isEmpty);
    });

    testWidgets('模板库一键填充（审批流）', (WidgetTester tester) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(tester, WbFlowchartEditor(onChanged: models.add));
      await tester.pump();

      await tester.tap(find.byKey(_key('wb-ctx-flow-template-toggle')));
      await tester.pump();
      // 40 类型图形库使模板面板成为列表第二个懒构建子项（视口外不构建）：
      // 直接把左面板滚动到底部再断言。
      final ScrollableState panelScrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(_key('wb-ctx-flow-left-panel')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      panelScrollable.position.jumpTo(
        panelScrollable.position.maxScrollExtent,
      );
      // 估算值与实际内容高度存在偏差（懒构建），等待位置修正动画完成。
      await tester.pumpAndSettle();
      final Finder approval = find.byKey(_key('wb-ctx-flow-template-approval'));
      expect(approval, findsOneWidget);

      // 面板超出一屏，先滚动到可见区再点。
      await tester.ensureVisible(approval);
      await tester.pump();
      await tester.tap(approval);
      await tester.pump();
      final WbFlowchartModel applied = models.last;
      expect(applied.templateId, 'approval');
      expect(applied.nodes.length, 6);
      expect(applied.connectors.length, 6);
      // 应用后模板面板自动收起
      expect(find.byKey(_key('wb-ctx-flow-template-approval')), findsNothing);
    });

    testWidgets('关闭按钮约定：有回调才显示并可触发（全窗工作区由宿主承担）', (
      WidgetTester tester,
    ) async {
      int closed = 0;
      // 全窗三区工作区（问题 2）：编辑器内不再渲染关闭按钮，关闭由宿主
      // 页面 AppBar 承担（见 element_editor_test.dart 的取消 / 保存用例）。
      await _pumpEditor(
        tester,
        WbFlowchartEditor(onClose: () => closed++),
      );
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-editor-close')), findsNothing);
      expect(closed, 0);

      // 居中面板类编辑器（非工作区）保留面板内关闭按钮约定。
      await _pumpEditor(
        tester,
        WbRender3dEditor(onClose: () => closed++),
        size: const Size(480, 960),
      );
      await tester.pump();
      await tester.tap(find.byKey(_key('wb-ctx-editor-close')));
      await tester.pump();
      expect(closed, 1);

      // 不提供 onClose 时不显示关闭按钮
      await _pumpEditor(
        tester,
        const WbRender3dEditor(),
        size: const Size(480, 960),
      );
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-editor-close')), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // 流程图：图形库扩展（折叠 / 更多图形 / 我的组件 / 三段编辑）
  // -------------------------------------------------------------------------

  group('流程图图形库扩展（ProcessOn 式分库）', () {
    const WbFlowComponent component = WbFlowComponent(
      id: 'cmp-1',
      name: '星形',
      mime: WbFlowComponent.mimePng,
      data: 'AA==',
      width: 120,
      height: 120,
    );

    testWidgets('分组折叠 / 展开：点击 toggle 显隐图形项并持久化', (
      WidgetTester tester,
    ) async {
      final WbFlowMemoryLibraryStore store = WbFlowMemoryLibraryStore();
      await _pumpEditor(tester, WbFlowchartEditor(libraryStore: store));
      await tester.pump();

      expect(
        find.byKey(_key('wb-ctx-flow-shape-start')),
        findsOneWidget,
        reason: '默认展开',
      );

      await tester.tap(find.byKey(_key('wb-ctx-flow-lib-toggle-flowchart')));
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-flow-shape-start')), findsNothing);
      expect(
        store.read()!.collapsedLibraries,
        contains('flowchart'),
        reason: '折叠态持久化',
      );

      await tester.tap(find.byKey(_key('wb-ctx-flow-lib-toggle-flowchart')));
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-flow-shape-start')), findsOneWidget);
      expect(store.read()!.collapsedLibraries, isNot(contains('flowchart')));
    });

    testWidgets('更多图形对话框：取消勾选隐藏分组、勾回恢复并持久化', (
      WidgetTester tester,
    ) async {
      final WbFlowMemoryLibraryStore store = WbFlowMemoryLibraryStore();
      await _pumpEditor(tester, WbFlowchartEditor(libraryStore: store));
      await tester.pump();

      final Finder more = find.byKey(_key('wb-ctx-flow-more-shapes'));
      await tester.ensureVisible(more);
      await tester.pump();
      await tester.tap(more);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.byKey(_key('wb-ctx-flow-more-shapes-dialog')),
        findsOneWidget,
      );
      expect(
        find.byKey(_key('wb-ctx-flow-lib-toggle-circuit')),
        findsOneWidget,
        reason: '默认全部勾选（电路图分组可见）',
      );

      await tester.tap(find.byKey(_key('wb-ctx-flow-lib-check-circuit')));
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-flow-lib-toggle-circuit')), findsNothing);
      expect(store.read()!.enabledLibraries, isNot(contains('circuit')));

      await tester.tap(find.byKey(_key('wb-ctx-flow-lib-check-circuit')));
      await tester.pump();
      expect(
        find.byKey(_key('wb-ctx-flow-lib-toggle-circuit')),
        findsOneWidget,
      );
      expect(store.read()!.enabledLibraries, contains('circuit'));

      await tester.tap(find.byKey(_key('wb-ctx-flow-more-shapes-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(_key('wb-ctx-flow-more-shapes-dialog')), findsNothing);
    });

    testWidgets('我的组件：点击添加生成组件节点、悬停删除并持久化', (
      WidgetTester tester,
    ) async {
      final WbFlowMemoryLibraryStore store = WbFlowMemoryLibraryStore(
        const WbFlowLibraryPrefs(
          enabledLibraries: <String>{'custom'},
          components: <WbFlowComponent>[component],
        ),
      );
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(
        tester,
        WbFlowchartEditor(libraryStore: store, onChanged: models.add),
      );
      await tester.pump();

      final Finder item = find.byKey(_key('wb-ctx-flow-component-cmp-1'));
      expect(item, findsOneWidget);
      await tester.ensureVisible(item);
      await tester.pump();
      await tester.tap(item);
      await tester.pump();

      final WbFlowNode added = models.last.nodes.last;
      expect(added.type, WbFlowNodeType.customComponent);
      expect(added.component, isNotNull);
      expect(added.component!.id, 'cmp-1');

      // 悬停显示删除按钮 → 删除条目（已放置节点不受影响）。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.pump();
      await mouse.moveTo(tester.getCenter(item));
      await tester.pump();

      final Finder remove = find.byKey(
        _key('wb-ctx-flow-component-remove-cmp-1'),
      );
      expect(remove, findsOneWidget);
      await tester.tap(remove);
      await tester.pump();

      expect(find.byKey(_key('wb-ctx-flow-component-cmp-1')), findsNothing);
      expect(store.read()!.components, isEmpty);
      expect(
        models.last.nodes.any(
          (WbFlowNode n) => n.type == WbFlowNodeType.customComponent,
        ),
        isTrue,
        reason: '已放置的组件节点保留',
      );
    });

    testWidgets('类图三段编辑：类名 / 属性 / 方法写回 compartments', (
      WidgetTester tester,
    ) async {
      final List<WbFlowchartModel> models = <WbFlowchartModel>[];
      await _pumpEditor(
        tester,
        WbFlowchartEditor(
          initialModel: const WbFlowchartModel(
            nodes: <WbFlowNode>[
              WbFlowNode(
                id: 'cls',
                x: 40,
                y: 40,
                type: WbFlowNodeType.umlClass,
                text: 'Order',
                width: 160,
                height: 120,
              ),
            ],
          ),
          onChanged: models.add,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(_key('wb-ctx-flow-node-cls')));
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-flow-node-name')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-node-attrs')), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-node-methods')), findsOneWidget);
      expect(
        find.byKey(_key('wb-ctx-flow-node-text')),
        findsNothing,
        reason: '三段式类型不再使用单行文本框',
      );

      await tester.enterText(
        find.byKey(_key('wb-ctx-flow-node-attrs')),
        '+ id: int',
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(_key('wb-ctx-flow-node-methods')),
        '+ pay(): void',
      );
      await tester.pump();

      final WbFlowNode updated = models.last.nodeById('cls')!;
      expect(updated.compartments.length, 3);
      expect(updated.compartments[0], 'Order', reason: '类名段回退 text');
      expect(updated.compartments[1], '+ id: int');
      expect(updated.compartments[2], '+ pay(): void');
    });

    testWidgets('custom 组件节点：无文本编辑，显示组件名提示', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(
        tester,
        const WbFlowchartEditor(
          initialModel: WbFlowchartModel(
            nodes: <WbFlowNode>[
              WbFlowNode(
                id: 'cmp-node',
                x: 40,
                y: 40,
                type: WbFlowNodeType.customComponent,
                width: 120,
                height: 120,
                component: component,
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(_key('wb-ctx-flow-node-cmp-node')));
      await tester.pump();

      expect(find.byKey(_key('wb-ctx-flow-node-component')), findsOneWidget);
      expect(find.text('组件：星形'), findsOneWidget);
      expect(find.byKey(_key('wb-ctx-flow-node-text')), findsNothing);
      expect(find.byKey(_key('wb-ctx-flow-node-name')), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // 表格：模型 + 编辑器 Widget
  // -------------------------------------------------------------------------

  group('表格编辑器', () {
    test('WbTableModel 边界守卫与归一化', () {
      const WbTableModel ragged = WbTableModel(
        cells: <List<String>>[
          <String>['a'],
          <String>['b', 'c'],
        ],
      );
      expect(ragged.rowCount, 2);
      expect(ragged.columnCount, 2);
      expect(ragged.cellAt(0, 1), '');
      expect(ragged.cellAt(9, 9), '');

      // setCell 自动扩展为矩形
      final WbTableModel extended = ragged.setCell(2, 1, 'x');
      expect(extended.rowCount, 3);
      expect(extended.columnCount, 2);
      expect(extended.cellAt(2, 1), 'x');
      expect(extended.cellAt(0, 0), 'a');
      expect(extended.cellAt(1, 1), 'c');
      expect(extended.setCell(-1, 0, 'bad'), extended, reason: '负索引忽略');

      // 至少保留一行 / 一列
      const WbTableModel single = WbTableModel(cells: <List<String>>[<String>['only']]);
      expect(single.removeRow(0).rowCount, 1);
      expect(single.removeColumn(0).columnCount, 1);

      // addColumn 表头命名 / normalize 补空串
      final WbTableModel added = ragged.addColumn();
      expect(added.columnCount, 3);
      expect(added.cellAt(0, 2), '列 3');
      final List<List<String>> normalized =
          WbTableModel.normalize(<List<String>>[
        <String>['x'],
        <String>['y', 'z'],
      ]);
      expect(normalized[0].length, 2);
      expect(normalized[0][1], '');
    });

    testWidgets('单元格原位编辑', (WidgetTester tester) async {
      final List<WbTableModel> models = <WbTableModel>[];
      await _pumpEditor(tester, WbTableEditor(onChanged: models.add));
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-table-grid')), findsOneWidget);

      await tester.tap(find.byKey(_key('wb-ctx-table-cell-1-0')));
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-table-cell-edit')), findsOneWidget);

      await tester.enterText(
        find.byKey(_key('wb-ctx-table-cell-edit')),
        '王五',
      );
      await tester.pump();
      expect(models.last.cellAt(1, 0), '王五');
      expect(models.last.cellAt(0, 0), '项目', reason: '其他单元格不受影响');
    });

    testWidgets('行列增减（未选中作用于末尾）', (WidgetTester tester) async {
      final List<WbTableModel> models = <WbTableModel>[];
      await _pumpEditor(tester, WbTableEditor(onChanged: models.add));
      await tester.pump();
      expect(models, isEmpty);

      await tester.tap(find.byKey(_key('wb-ctx-table-add-row')));
      await tester.pump();
      expect(models.last.rowCount, 4);

      await tester.tap(find.byKey(_key('wb-ctx-table-add-col')));
      await tester.pump();
      expect(models.last.columnCount, 4);

      await tester.tap(find.byKey(_key('wb-ctx-table-remove-row')));
      await tester.pump();
      expect(models.last.rowCount, 3);

      await tester.tap(find.byKey(_key('wb-ctx-table-remove-col')));
      await tester.pump();
      expect(models.last.columnCount, 3);
    });

    testWidgets('样式 chip 与表头底色', (WidgetTester tester) async {
      final List<WbTableModel> models = <WbTableModel>[];
      await _pumpEditor(tester, WbTableEditor(onChanged: models.add));
      await tester.pump();

      await tester.tap(find.byKey(_key('wb-ctx-table-align-center')));
      await tester.pump();
      expect(models.last.style.align, WbTableAlign.center);

      await tester.tap(find.byKey(_key('wb-ctx-table-borders')));
      await tester.pump();
      expect(models.last.style.showBorders, isFalse);

      await tester.tap(find.byKey(_key('wb-ctx-table-zebra')));
      await tester.pump();
      expect(models.last.style.zebraStripes, isTrue);

      await tester.tap(find.byKey(_key('wb-ctx-table-header-bold')));
      await tester.pump();
      expect(models.last.style.headerBold, isFalse);

      // 表头底色为选中单元格后的 inspector 功能
      await tester.tap(find.byKey(_key('wb-ctx-table-cell-0-0')));
      await tester.pump();
      await tester.tap(find.byKey(_key('wb-ctx-table-header-color-2')));
      await tester.pump();
      final Color background = models.last.style.headerBackground;
      expect(background, isNot(const Color(0xFFEAF1FF)));
      expect((background.toARGB32() >> 16) & 0xFF, greaterThan(200));
    });
  });

  // -------------------------------------------------------------------------
  // 思维导图：布局引擎 + 编辑器 Widget
  // -------------------------------------------------------------------------

  group('思维导图', () {
    test('WbMindLayoutEngine 三种布局与折叠', () {
      final WbMindNode root = WbMindNode.sample();
      const Size canvas = Size(400, 400);

      final WbMindLayoutResult right = WbMindLayoutEngine.layout(
        root: root,
        layout: WbMindLayout.right,
        canvas: canvas,
      );
      expect(right.rects.length, 6);
      expect(right.depths['m1'], 0);
      expect(right.rects['m1']!.left, lessThan(right.rects['m2']!.left));
      expect(right.rects['m2']!.left, lessThan(right.rects['m3']!.left));
      final double m2Center = right.rects['m2']!.center.dy;
      final double childSpan =
          (right.rects['m3']!.top + right.rects['m4']!.bottom) / 2;
      expect(m2Center, closeTo(childSpan, 1.0), reason: '父节点居中于子节点范围');
      expect(right.edges.length, 5);

      final WbMindLayoutResult tree = WbMindLayoutEngine.layout(
        root: root,
        layout: WbMindLayout.tree,
        canvas: canvas,
      );
      expect(tree.rects['m1']!.top, lessThan(tree.rects['m2']!.top));
      expect(tree.rects['m2']!.top, lessThan(tree.rects['m3']!.top));

      final WbMindLayoutResult both = WbMindLayoutEngine.layout(
        root: root,
        layout: WbMindLayout.both,
        canvas: canvas,
      );
      expect(both.rects['m6']!.center.dx, lessThan(both.rects['m1']!.center.dx));
      expect(both.rects['m1']!.center.dx, lessThan(both.rects['m2']!.center.dx));
      expect(both.rects['m5']!.center.dx, greaterThan(both.rects['m1']!.center.dx));

      // 折叠：子树不参与布局
      final WbMindNode collapsed = root.mapById(
        'm2',
        (WbMindNode node) => node.copyWith(collapsed: true),
      );
      final WbMindLayoutResult folded = WbMindLayoutEngine.layout(
        root: collapsed,
        layout: WbMindLayout.right,
        canvas: canvas,
      );
      expect(folded.rects.containsKey('m1'), isTrue);
      expect(folded.rects.containsKey('m2'), isTrue);
      expect(folded.rects.containsKey('m3'), isFalse);
    });

    testWidgets('添加 / 重命名 / 删除节点', (WidgetTester tester) async {
      final List<WbMindNode> roots = <WbMindNode>[];
      await _pumpEditor(tester, WbMindmapEditor(onChanged: roots.add));
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-mind-node-m1')), findsOneWidget);

      // 初始选中根节点，添加子节点 → 7 个节点
      await tester.tap(find.byKey(_key('wb-ctx-mind-add')));
      await tester.pump();
      expect(roots.last.count, 7);

      // 选中 m5 并重命名
      await tester.tap(find.byKey(_key('wb-ctx-mind-node-m5')));
      await tester.pump();
      await tester.enterText(find.byKey(_key('wb-ctx-mind-text')), '新主题');
      await tester.pump();
      expect(roots.last.nodeById('m5')!.text, '新主题');

      // 删除选中节点
      await tester.tap(find.byKey(_key('wb-ctx-mind-delete')));
      await tester.pump();
      expect(roots.last.count, 6);
      expect(roots.last.nodeById('m5'), isNull);
    });

    testWidgets('折叠子树与布局切换回调', (WidgetTester tester) async {
      final List<WbMindNode> roots = <WbMindNode>[];
      final List<WbMindLayout> layouts = <WbMindLayout>[];
      await _pumpEditor(
        tester,
        WbMindmapEditor(onChanged: roots.add, onLayoutChanged: layouts.add),
      );
      await tester.pump();

      await tester.tap(find.byKey(_key('wb-ctx-mind-collapse-badge-m2')));
      await tester.pump();
      expect(roots.last.nodeById('m2')!.collapsed, isTrue);
      expect(find.byKey(_key('wb-ctx-mind-node-m3')), findsNothing);
      expect(find.byKey(_key('wb-ctx-mind-node-m4')), findsNothing);
      expect(find.text('+2'), findsOneWidget, reason: '折叠徽章显示隐藏数量');

      await tester.tap(find.byKey(_key('wb-ctx-mind-layout-tree')));
      await tester.pump();
      expect(layouts.single, WbMindLayout.tree);

      // 再展开：子树恢复显示
      await tester.tap(find.byKey(_key('wb-ctx-mind-collapse-badge-m2')));
      await tester.pump();
      expect(roots.last.nodeById('m2')!.collapsed, isFalse);
      expect(find.byKey(_key('wb-ctx-mind-node-m3')), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // 函数图像：编译器 / 采样器 + 编辑器 Widget
  // -------------------------------------------------------------------------

  group('函数图像', () {
    test('表达式编译器：优先级 / 结合性 / 常量 / 函数 / 非法输入', () {
      final WbEvalFn? sum = WbExpressionCompiler.compile('1 + 2 * 3');
      expect(sum, isNotNull);
      expect(sum!(0), 7);
      expect(WbExpressionCompiler.compile('(1 + 2) * 3')!(0), 9);

      final WbEvalFn? power = WbExpressionCompiler.compile('2^3^2');
      expect(power!(0), 512, reason: '幂运算右结合');

      final WbEvalFn? unary = WbExpressionCompiler.compile('-x^2');
      expect(unary!(2), -4, reason: '一元负号优先级低于幂');

      expect(
        WbExpressionCompiler.compile('sin(pi / 2)')!(0),
        closeTo(1, 1e-9),
      );
      expect(
        WbExpressionCompiler.compile('sqrt(4) + ln(e) + abs(-0.5)')!(0),
        closeTo(3.5, 1e-9),
      );
      expect(WbExpressionCompiler.compile('exp(0)')!(0), closeTo(1, 1e-9));

      final WbEvalFn? identity = WbExpressionCompiler.compile('x');
      expect(identity!(3.5), 3.5);

      expect(WbExpressionCompiler.compile('sin('), isNull);
      expect(WbExpressionCompiler.compile('1 +'), isNull);
      expect(WbExpressionCompiler.compile(''), isNull);
      expect(WbExpressionCompiler.compile('foo(x)'), isNull);
      expect(WbExpressionCompiler.isValid('cos(x) * 2'), isTrue);
      expect(WbExpressionCompiler.isValid('cos(x) *'), isFalse);
    });

    test('采样器：非有限值 / 大跳变分段与自适应范围', () {
      final WbFunctionGeometry reciprocal = WbFunctionSampler.sample(
        WbFunctionScene(
          curves: <WbCurve>[
            WbCurve(
              id: 'r',
              expression: '1 / x',
              color: WbContextPalette.curveSwatches[0],
            ),
          ],
        ),
      );
      expect(reciprocal.paths.length, 1);
      expect(
        reciprocal.paths.single.segments.length,
        greaterThanOrEqualTo(2),
        reason: 'x=0 非有限值应断开',
      );
      expect(reciprocal.range.minY, lessThan(0));
      expect(reciprocal.range.maxY, greaterThan(0));

      final WbFunctionGeometry sine = WbFunctionSampler.sample(
        WbFunctionScene(
          curves: <WbCurve>[
            WbCurve(
              id: 's',
              expression: 'sin(x)',
              color: WbContextPalette.curveSwatches[0],
            ),
          ],
        ),
      );
      expect(sine.paths.single.segments.length, 1, reason: '连续函数单段');

      // 隐藏曲线不参与几何；非法表达式被跳过
      final WbFunctionGeometry hidden = WbFunctionSampler.sample(
        WbFunctionScene(
          curves: <WbCurve>[
            WbCurve(
              id: 'h',
              expression: 'x',
              color: WbContextPalette.curveSwatches[0],
              visible: false,
            ),
            WbCurve(
              id: 'bad',
              expression: 'sin(',
              color: WbContextPalette.curveSwatches[1],
            ),
          ],
        ),
      );
      expect(hidden.paths, isEmpty);
    });

    testWidgets('表达式实时校验与曲线增删', (WidgetTester tester) async {
      final List<WbFunctionScene> scenes = <WbFunctionScene>[];
      await _pumpEditor(tester, WbFunctionEditor(onChanged: scenes.add));
      await tester.pump();

      final TextField expr =
          tester.widget<TextField>(find.byKey(_key('wb-ctx-func-expr')));
      expect(expr.controller!.text, 'sin(x)');

      await tester.enterText(find.byKey(_key('wb-ctx-func-expr')), 'sin(');
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-func-error')), findsOneWidget);

      await tester.enterText(find.byKey(_key('wb-ctx-func-expr')), 'x^2');
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-func-error')), findsNothing);
      expect(scenes.last.curveById('f1')!.expression, 'x^2');

      await tester.tap(find.byKey(_key('wb-ctx-func-add-curve')));
      await tester.pump();
      expect(scenes.last.curves.length, 3);

      await tester.tap(find.byKey(_key('wb-ctx-func-remove-curve')));
      await tester.pump();
      expect(scenes.last.curves.length, 2);
    });

    testWidgets('定义域编辑与曲线颜色 / 显隐', (WidgetTester tester) async {
      final List<WbFunctionScene> scenes = <WbFunctionScene>[];
      await _pumpEditor(tester, WbFunctionEditor(onChanged: scenes.add));
      await tester.pump();

      await tester.enterText(find.byKey(_key('wb-ctx-func-domain-min')), '-3');
      await tester.pump();
      expect(scenes.last.domainMin, -3);
      expect(find.byKey(_key('wb-ctx-func-preview')), findsOneWidget);

      // 反向定义域被守卫（min >= max 忽略）
      await tester.enterText(find.byKey(_key('wb-ctx-func-domain-max')), '-8');
      await tester.pump();
      expect(scenes.last.domainMax, 6);

      await tester.tap(find.byKey(_key('wb-ctx-func-color-1')));
      await tester.pump();
      expect(
        scenes.last.curveById('f1')!.color,
        WbContextPalette.curveSwatches[1],
      );

      await tester.tap(find.byKey(_key('wb-ctx-func-visible')));
      await tester.pump();
      expect(scenes.last.curveById('f1')!.visible, isFalse);

      // 删除选中曲线（f1）后仅剩一条；删除按钮随后被禁用
      await tester.tap(find.byKey(_key('wb-ctx-func-remove-curve')));
      await tester.pump();
      expect(scenes.last.curves.length, 1);
      expect(scenes.last.curves.single.id, 'f2');
      await tester.tap(find.byKey(_key('wb-ctx-func-remove-curve')));
      await tester.pump();
      expect(scenes.last.curves.length, 1, reason: '仅剩一条时删除被守卫');
    });
  });

  // -------------------------------------------------------------------------
  // 3D 对象：参数面板 + 渲染烟雾测试
  // -------------------------------------------------------------------------

  group('3D 对象编辑器', () {
    testWidgets('对象类型 / 材质 / 光照切换', (WidgetTester tester) async {
      final List<Wb3dScene> scenes = <Wb3dScene>[];
      await _pumpEditor(tester, WbRender3dEditor(onChanged: scenes.add));
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-3d-preview')), findsOneWidget);

      await tester.tap(find.byKey(_key('wb-ctx-3d-type-sphere')));
      await tester.pump();
      expect(scenes.last.objectType, Wb3dObjectType.sphere);

      await tester.tap(find.byKey(_key('wb-ctx-3d-material-glass')));
      await tester.pump();
      expect(scenes.last.material, Wb3dMaterial.glass);

      final Finder spot = find.byKey(_key('wb-ctx-3d-light-spot'));
      await tester.ensureVisible(spot);
      await tester.pump();
      await tester.tap(spot);
      await tester.pump();
      expect(scenes.last.lightType, Wb3dLightType.spot);

      await tester.tap(find.byKey(_key('wb-ctx-3d-color-3')));
      await tester.pump();
      expect(scenes.last.color, WbContextPalette.swatches[3]);
    });

    testWidgets('环境光滑杆 / 线框开关 / 变换与重置', (WidgetTester tester) async {
      final List<Wb3dScene> scenes = <Wb3dScene>[];
      await _pumpEditor(tester, WbRender3dEditor(onChanged: scenes.add));
      await tester.pump();

      await _tapSliderAt(tester, _key('wb-ctx-3d-ambient'), 0.25);
      expect(scenes, isNotEmpty);
      expect(scenes.last.ambient, lessThan(0.32));
      expect(scenes.last.ambient, greaterThanOrEqualTo(0));

      final Finder switchFinder = find.descendant(
        of: find.byKey(_key('wb-ctx-3d-wireframe')),
        matching: find.byType(Switch),
      );
      await tester.ensureVisible(switchFinder);
      await tester.pump();
      await tester.tap(switchFinder);
      await tester.pump();
      expect(scenes.last.wireframe, isTrue);

      await _tapSliderAt(tester, _key('wb-ctx-3d-rotate-x'), 0.75);
      expect(scenes.last.transform.rotationX, isNot(0));

      await _tapSliderAt(tester, _key('wb-ctx-3d-scale'), 0.8);
      expect(scenes.last.transform.scale, greaterThan(1));

      await tester.tap(find.byKey(_key('wb-ctx-3d-reset')));
      await tester.pump();
      expect(scenes.last.objectType, Wb3dObjectType.box);
      expect(scenes.last.material, Wb3dMaterial.standard);
      expect(scenes.last.wireframe, isFalse);
      expect(scenes.last.ambient, 0.32);
      expect(scenes.last.transform.rotationX, 0);
      expect(scenes.last.transform.scale, 1);
    });

    testWidgets('渲染烟雾测试：7 类型 × 4 材质', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      for (final Wb3dObjectType type in Wb3dObjectType.values) {
        for (final Wb3dMaterial material in Wb3dMaterial.values) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 480,
                    height: 960,
                    child: WbRender3dEditor(
                      key: ValueKey<String>('${type.id}-${material.id}'),
                      initialScene: Wb3dScene(
                        objectType: type,
                        material: material,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(
            tester.takeException(),
            isNull,
            reason: '${type.id} / ${material.id} 渲染异常',
          );
        }
      }
    });
  });

  // -------------------------------------------------------------------------
  // 快速创建
  // -------------------------------------------------------------------------

  group('快速创建', () {
    testWidgets('按钮条：七类按钮与回调', (WidgetTester tester) async {
      final List<WbQuickCreateKind> created = <WbQuickCreateKind>[];
      await _pumpEditor(
        tester,
        WbQuickCreateBar(onCreate: created.add),
        size: const Size(600, 240),
      );
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-quick-create-bar')), findsOneWidget);
      expect(WbQuickCreateKind.values.length, 7);
      for (final WbQuickCreateKind kind in WbQuickCreateKind.values) {
        expect(
          find.byKey(_key('wb-ctx-quick-create-${kind.id}')),
          findsOneWidget,
          reason: kind.id,
        );
      }

      await tester.tap(find.byKey(_key('wb-ctx-quick-create-flowchart')));
      await tester.pump();
      expect(created.single, WbQuickCreateKind.flowchart);
    });

    testWidgets('浮出入口：展开 / 创建后自动收起 / 收起键', (WidgetTester tester) async {
      final List<WbQuickCreateKind> created = <WbQuickCreateKind>[];
      await _pumpEditor(
        tester,
        WbQuickCreateLauncher(onCreate: created.add),
        size: const Size(600, 600),
      );
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-quick-create-bar')), findsNothing);
      expect(find.byKey(_key('wb-ctx-quick-create-toggle')), findsOneWidget);

      await tester.tap(find.byKey(_key('wb-ctx-quick-create-toggle')));
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-quick-create-bar')), findsOneWidget);

      await tester.tap(find.byKey(_key('wb-ctx-quick-create-table')));
      await tester.pump();
      expect(created.single, WbQuickCreateKind.table);
      expect(
        find.byKey(_key('wb-ctx-quick-create-bar')),
        findsNothing,
        reason: '创建后自动收起',
      );

      await tester.tap(find.byKey(_key('wb-ctx-quick-create-toggle')));
      await tester.pump();
      await tester.tap(find.byKey(_key('wb-ctx-quick-create-dismiss')));
      await tester.pump();
      expect(find.byKey(_key('wb-ctx-quick-create-bar')), findsNothing);
    });

    testWidgets('buildEditor 七类编辑器挂载与标题', (WidgetTester tester) async {
      const Map<WbQuickCreateKind, String> titles =
          <WbQuickCreateKind, String>{
        WbQuickCreateKind.flowchart: '流程图编辑器',
        WbQuickCreateKind.table: '表格编辑器',
        WbQuickCreateKind.mindmap: '思维导图编辑器',
        WbQuickCreateKind.functionCurve: '函数图像编辑器',
        WbQuickCreateKind.render3d: '3D 对象编辑器',
        WbQuickCreateKind.render2d: '2D 图元',
        WbQuickCreateKind.markdown: 'Markdown编辑器',
      };
      // 全窗工作区（问题 2 · 波次 B2~B4）：流程图 / 表格 / 思维导图的标题
      // 由宿主编辑页 AppBar 提供，编辑器内不再渲染第二标题栏；Markdown 为
      // 全窗工作区形态（顶部工具条仅标识「Markdown」与统计，无标题栏）。
      const Map<WbQuickCreateKind, Type> workspaceTypes =
          <WbQuickCreateKind, Type>{
        WbQuickCreateKind.flowchart: WbFlowchartEditor,
        WbQuickCreateKind.table: WbTableEditor,
        WbQuickCreateKind.mindmap: WbMindmapEditor,
        WbQuickCreateKind.markdown: WbMarkdownEditor,
      };
      for (final MapEntry<WbQuickCreateKind, String> entry in titles.entries) {
        await _pumpEditor(tester, entry.key.buildEditor());
        await tester.pump();
        final Type? workspaceType = workspaceTypes[entry.key];
        if (workspaceType != null) {
          expect(find.text(entry.value), findsNothing, reason: entry.key.id);
          expect(
            find.byType(workspaceType),
            findsOneWidget,
            reason: entry.key.id,
          );
        } else {
          expect(find.text(entry.value), findsOneWidget, reason: entry.key.id);
        }
        expect(tester.takeException(), isNull, reason: entry.key.id);
      }
    });
  });
}
