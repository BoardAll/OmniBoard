/// 专业元素插入与渲染测试（问题 9 / B2）：
/// [WbProfessionalRenderer] 测量 / 插入命令 / 快速创建接口 / 渲染冒烟。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/state/selection_state.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';
import 'package:whiteboard_desktop/widgets/canvas/professional_painter.dart';
import 'package:whiteboard_desktop/widgets/canvas_view.dart';
import 'package:whiteboard_desktop/widgets/context_editors/flowchart_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/function_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/mindmap_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/quick_create.dart';
import 'package:whiteboard_desktop/widgets/context_editors/render2d_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/render3d_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/table_editor.dart';

const Size _window = Size(1600, 1000);

/// 在 1600x1000 窗口中挂载 `CanvasView`（注入控制器 / 选区）。
Future<void> _pumpCanvas(
  WidgetTester tester, {
  required WbCanvasController controller,
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
  group('WbProfessionalRenderer.measure', () {
    test('七类默认模型均可测量且不小于最小值', () {
      for (final WbQuickCreateKind kind in WbQuickCreateKind.values) {
        final Size? size =
            WbProfessionalRenderer.measure(kind.id, kind.defaultModel());
        expect(size, isNotNull, reason: kind.id);
        expect(size!.width, greaterThanOrEqualTo(140), reason: kind.id);
        expect(size.height, greaterThanOrEqualTo(90), reason: kind.id);
      }
    });

    test('payload 缺失 / 类型不符 / 未知类型返回 null', () {
      expect(
        WbProfessionalRenderer.measure(WbElementKind.flowchart, null),
        isNull,
      );
      expect(
        WbProfessionalRenderer.measure(
          WbElementKind.table,
          WbMindNode.sample(),
        ),
        isNull,
      );
      expect(
        WbProfessionalRenderer.measure('unknown', WbMindNode.sample()),
        isNull,
      );
    });

    test('流程图 / 表格尺寸 = 模型外接矩形 + 留白', () {
      final Size flow = WbProfessionalRenderer.measure(
        WbElementKind.flowchart,
        WbFlowchartModel.sample(),
      )!;
      // 示例节点并集：x 134..266，y 14..216（132 x 202）。
      expect(flow.width, 132 + WbProfessionalRenderer.inset * 2);
      expect(flow.height, 202 + WbProfessionalRenderer.inset * 2);

      final Size table = WbProfessionalRenderer.measure(
        WbElementKind.table,
        WbTableModel.sample(),
      )!;
      // 示例表格 3 列 x 3 行。
      expect(table.width, 3 * WbProfessionalRenderer.tableCellWidth +
          WbProfessionalRenderer.inset * 2);
      expect(table.height, 3 * WbProfessionalRenderer.tableCellHeight +
          WbProfessionalRenderer.inset * 2);
    });

    test('类型中文名（占位文案用）', () {
      expect(WbProfessionalRenderer.labelFor(WbElementKind.render3d), '3D 对象');
      expect(WbProfessionalRenderer.labelFor(WbElementKind.render2d), '2D 图元');
      expect(WbProfessionalRenderer.labelFor('mystery'), 'mystery');
    });
  });

  group('WbProfessionalRenderer 函数表达式图例（第三轮问题 1）', () {
    test('图例条目：过滤隐藏 / 空表达式并去除首尾空白', () {
      const WbFunctionScene scene = WbFunctionScene(
        curves: <WbCurve>[
          WbCurve(
            id: 'f1',
            expression: 'sin(x)',
            color: Color(0xFF3366FF),
          ),
          WbCurve(
            id: 'f2',
            expression: '   ',
            color: Color(0xFFE45D5D),
          ),
          WbCurve(
            id: 'f3',
            expression: 'cos(x)',
            color: Color(0xFF3AA76D),
            visible: false,
          ),
          WbCurve(
            id: 'f4',
            expression: '  x^2 ',
            color: Color(0xFFB25DD1),
          ),
        ],
      );

      final List<({Color color, String expression})> entries =
          WbProfessionalRenderer.functionLegendEntries(scene);
      expect(entries.length, 2);
      expect(entries[0].expression, 'sin(x)');
      expect(entries[0].color, const Color(0xFF3366FF));
      expect(entries[1].expression, 'x^2');
      expect(entries[1].color, const Color(0xFFB25DD1));
    });

    test('图例条目最多显示 maxFunctionLegendEntries 条', () {
      final WbFunctionScene scene = WbFunctionScene(
        curves: <WbCurve>[
          for (int i = 0; i < 10; i++)
            WbCurve(
              id: 'f$i',
              expression: 'x + $i',
              color: const Color(0xFF3366FF),
            ),
        ],
      );

      expect(
        WbProfessionalRenderer.functionLegendEntries(scene).length,
        WbProfessionalRenderer.maxFunctionLegendEntries,
      );
    });
  });

  group('WbCanvasController.insertElement', () {
    test('视口中心插入 + 选中 + payload 保留 + 可撤销', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      c.setViewportSize(const Size(800, 600));
      final WbTableModel model = WbTableModel.sample();

      final WbCanvasElement element = c.insertElement(
        type: WbElementKind.table,
        size: const Size(300, 200),
        payload: model,
      );

      expect(c.elements.length, 1);
      expect(element.bounds.center, const Offset(400, 300));
      expect(element.payload, same(model));
      expect(sel.ids, contains(element.id));
      expect(c.canUndo, isTrue);

      c.undo();
      expect(c.elements, isEmpty);
      c.redo();
      expect(c.elements.length, 1);
      expect(c.elements.single.payload, same(model));
    });

    test('过小尺寸抬升到 40 下限', () {
      final WbCanvasController c = WbCanvasController();
      c.setViewportSize(const Size(800, 600));
      final WbCanvasElement element = c.insertElement(
        type: WbElementKind.note,
        size: const Size(10, 10),
      );
      expect(element.width, 40);
      expect(element.height, 40);
    });

    test('copyWith 移动保持 payload（不可变引用透传）', () {
      final WbMindNode model = WbMindNode.sample();
      final WbCanvasElement element = WbCanvasElement(
        id: 'p1',
        type: WbElementKind.mindmap,
        x: 0,
        y: 0,
        width: 200,
        height: 160,
        payload: model,
      );
      expect(element.copyWith(x: 24).payload, same(model));
    });
  });

  group('WbQuickCreateKind 接口', () {
    test('defaultModel 类型与 id 对齐', () {
      expect(WbQuickCreateKind.flowchart.defaultModel(), isA<WbFlowchartModel>());
      expect(WbQuickCreateKind.table.defaultModel(), isA<WbTableModel>());
      expect(WbQuickCreateKind.mindmap.defaultModel(), isA<WbMindNode>());
      expect(
        WbQuickCreateKind.functionCurve.defaultModel(),
        isA<WbFunctionScene>(),
      );
      expect(WbQuickCreateKind.render3d.defaultModel(), isA<Wb3dScene>());
      expect(WbQuickCreateKind.render2d.defaultModel(), isA<WbRender2dScene>());
    });

    test('buildEditor 返回对应编辑器并透传 onChanged', () {
      expect(
        WbQuickCreateKind.flowchart.buildEditor(),
        isA<WbFlowchartEditor>(),
      );
      expect(WbQuickCreateKind.table.buildEditor(), isA<WbTableEditor>());
      expect(WbQuickCreateKind.mindmap.buildEditor(), isA<WbMindmapEditor>());
      expect(
        WbQuickCreateKind.functionCurve.buildEditor(),
        isA<WbFunctionEditor>(),
      );
      expect(
        WbQuickCreateKind.render3d.buildEditor(),
        isA<WbRender3dEditor>(),
      );
      expect(
        WbQuickCreateKind.render2d.buildEditor(),
        isA<WbRender2dEditor>(),
      );

      Object? captured;
      final WbFlowchartEditor editor = WbQuickCreateKind.flowchart.buildEditor(
        onClose: () {},
        onChanged: (Object model) => captured = model,
      ) as WbFlowchartEditor;
      expect(editor.onChanged, isNotNull);
      editor.onChanged!(WbFlowchartModel.sample());
      expect(captured, isA<WbFlowchartModel>());

      final WbRender2dEditor editor2d =
          WbQuickCreateKind.render2d.buildEditor(
        onChanged: (Object model) => captured = model,
      ) as WbRender2dEditor;
      editor2d.onChanged!(const WbRender2dScene());
      expect(captured, isA<WbRender2dScene>());
    });
  });

  group('CanvasView 渲染冒烟', () {
    testWidgets('七类专业元素 + 缺失 payload 占位均可绘制且可命中',
        (WidgetTester tester) async {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      await _pumpCanvas(tester, controller: c, selection: sel);

      // 逐类型放置（自动换行保证落在视口内，全部走 paint 分支）。
      double x = 30;
      double y = 30;
      double rowHeight = 0;
      const double gap = 30;
      for (final WbQuickCreateKind kind in WbQuickCreateKind.values) {
        final Object model = kind.defaultModel();
        final Size size =
            WbProfessionalRenderer.measure(kind.id, model) ?? const Size(200, 150);
        if (x + size.width > _window.width - 30) {
          x = 30;
          y += rowHeight + gap;
          rowHeight = 0;
        }
        c.document.upsert(
          '',
          WbCanvasElement(
            id: 'pro-${kind.id}',
            type: kind.id,
            x: x,
            y: y,
            width: size.width,
            height: size.height,
            zIndex: 10,
            payload: model,
          ),
        );
        x += size.width + gap;
        rowHeight = rowHeight > size.height ? rowHeight : size.height;
      }
      // 缺失 payload 的占位分支。
      c.document.upsert(
        '',
        const WbCanvasElement(
          id: 'pro-empty',
          type: WbElementKind.flowchart,
          x: 30,
          y: 700,
          width: 200,
          height: 140,
          zIndex: 20,
        ),
      );
      await tester.pump();
      await tester.pump();

      // 绘制不应抛异常（有异常时 tester 会在测试结束时报告失败）。
      expect(tester.takeException(), isNull);

      // 命中：表格元素中心。
      final WbCanvasElement table = c.document.byId('', 'pro-table')!;
      expect(c.hitTestElement(table.bounds.center)?.id, 'pro-table');
      // 占位元素也可选中。
      expect(
        c.hitTestElement(const Offset(130, 770))?.id,
        'pro-empty',
      );
    });
  });

  group('顶部面板「更多」菜单（B3）', () {
    testWidgets('平行四边形 / 连线直设工具；专业元素回调透传宿主',
        (WidgetTester tester) async {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = WbCanvasController(selection: sel);
      WbQuickCreateKind? created;
      tester.view.physicalSize = _window;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CanvasView(
              controller: c,
              selection: sel,
              onQuickCreate: (WbQuickCreateKind kind) => created = kind,
            ),
          ),
        ),
      );
      await tester.pump();

      // 平行四边形：设形状类型并切到形状工具。
      await tester.tap(find.byKey(const Key('wb-canvas-more')));
      await tester.pumpAndSettle();
      expect(find.text('平行四边形'), findsOneWidget);
      await tester.tap(find.text('平行四边形'));
      await tester.pumpAndSettle();
      expect(c.tool, WbCanvasTool.shape);
      expect(c.shapeKind, WbShapeKind.parallelogram);

      // 连线：切换到连线工具。
      await tester.tap(find.byKey(const Key('wb-canvas-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('连线'));
      await tester.pumpAndSettle();
      expect(c.tool, WbCanvasTool.connector);

      // 专业元素：回调透传到宿主（由宿主插入画布）。
      await tester.tap(find.byKey(const Key('wb-canvas-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('流程图'));
      await tester.pumpAndSettle();
      expect(created, WbQuickCreateKind.flowchart);
    });
  });
}
