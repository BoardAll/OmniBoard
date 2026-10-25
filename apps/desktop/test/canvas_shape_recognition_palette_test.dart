/// 图形识别开关 chip 组件测试（共享 `WbCanvasToolPalette` 桌面装配）：
/// - 画笔工具下 chip 存在、默认开启、点击取反控制器开关；
/// - 荧光笔工具下不显示（仅画笔参数行提供，荧光笔不参与识别）。
///
/// 仿照 collab_m3_widget_test.dart 的装配方式（MaterialApp + Scaffold，
/// 不依赖 DLL 与网络）；主题回退默认内置主题（context.wbColors 自带回退）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_tool_palette.dart';

const ValueKey<String> _chipKey =
    ValueKey<String>('wb-canvas-shape-recognition');

/// 装配调色板（指定工具）并返回控制器。
Future<WbCanvasController> _pumpPalette(
  WidgetTester tester,
  WbCanvasTool tool,
) async {
  final WbCanvasController controller = WbCanvasController()..setTool(tool);
  addTearDown(controller.dispose);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: WbCanvasToolPalette(controller: controller)),
  ));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('画笔：图形识别 chip 存在、默认开启、点击取反',
      (WidgetTester tester) async {
    final WbCanvasController canvas =
        await _pumpPalette(tester, WbCanvasTool.pen);
    expect(canvas.shapeRecognitionEnabled, isTrue);
    expect(find.byKey(_chipKey), findsOneWidget);
    expect(find.text('图形识别'), findsOneWidget);

    await tester.tap(find.byKey(_chipKey));
    await tester.pump();
    expect(canvas.shapeRecognitionEnabled, isFalse);

    await tester.tap(find.byKey(_chipKey));
    await tester.pump();
    expect(canvas.shapeRecognitionEnabled, isTrue);
  });

  testWidgets('荧光笔：不显示图形识别 chip', (WidgetTester tester) async {
    final WbCanvasController canvas =
        await _pumpPalette(tester, WbCanvasTool.highlighter);
    expect(canvas.tool, WbCanvasTool.highlighter);
    expect(find.byKey(_chipKey), findsNothing);
  });
}
