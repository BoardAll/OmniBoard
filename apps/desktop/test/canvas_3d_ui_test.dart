/// 3D 工具 UI 接线测试（Widget 级：工具按钮 / 参数行 / 涂色开关 / 更多菜单）。
///
/// 与 `canvas_3d_test.dart`（控制器纯测试）互补；挂载模式对齐
/// `canvas_deep_test.dart` 的 `_pumpCanvas`（MaterialApp + Scaffold 直挂，
/// 1600x1000 视口、devicePixelRatio 1.0）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/state/selection_state.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';
import 'package:whiteboard_desktop/widgets/canvas_view.dart';
import 'package:whiteboard_desktop/widgets/context_editors/render3d_editor.dart';

void main() {
  testWidgets('3D 工具：参数行 7 类型按钮可切换 + 直绘提示', (WidgetTester tester) async {
    final WbCanvasController c = WbCanvasController();
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: CanvasView(controller: c))),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-canvas-tool-render3d')),
    );
    await tester.pump();
    expect(c.tool, WbCanvasTool.render3d);
    for (final Wb3dObjectType type in Wb3dObjectType.values) {
      expect(
        find.byKey(ValueKey<String>('wb-canvas-3d-type-${type.id}')),
        findsOneWidget,
        reason: '类型按钮 ${type.id} 应存在',
      );
    }
    expect(
      find.text('单击或拖拽一次放置 3D 模型；拖动旋转、滚轮缩放、双击编辑'),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-canvas-3d-type-sphere')),
    );
    await tester.pump();
    expect(c.render3dType, Wb3dObjectType.sphere);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单选 3D 元素：涂色开关与色板接线；无选中不显示参数行', (WidgetTester tester) async {
    final WbCanvasController c = WbCanvasController();
    final WbSelectionState sel = WbSelectionState();
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CanvasView(controller: c, selection: sel)),
      ),
    );
    await tester.pump();

    // 无选中：select 工具不显示涂色参数行（保持既有 UI 行为）。
    expect(find.byKey(const Key('wb-canvas-3d-paint-toggle')), findsNothing);

    // 选中 3D 元素：涂色开关 + 色板浮出。
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
    sel.select(<String>['d1']);
    await tester.pump();

    final Finder toggle = find.byKey(const Key('wb-canvas-3d-paint-toggle'));
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    expect(c.render3dPaintMode, isTrue);

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-canvas-3d-paint-color-2')),
    );
    await tester.pump();
    expect(c.render3dPaintColor, WbCanvasPalette.shapeColors[2]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('更多菜单：3D 直绘分组选择后切到 3D 工具并预置类型', (WidgetTester tester) async {
    final WbCanvasController c = WbCanvasController();
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: CanvasView(controller: c))),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('wb-canvas-more')));
    await tester.pumpAndSettle();
    expect(find.text('圆柱（直绘）'), findsOneWidget);
    await tester.tap(find.text('圆柱（直绘）'));
    await tester.pumpAndSettle();
    expect(c.tool, WbCanvasTool.render3d);
    expect(c.render3dType, Wb3dObjectType.cylinder);
    expect(tester.takeException(), isNull);
  });
}
