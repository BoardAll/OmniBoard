/// Web 端 Mermaid 图查看器接线测试：
/// `WbMarkdownView` 点击图块弹出放大查看器（缩放 / 重置 / 关闭）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_canvas/markdown/markdown_layout.dart';
import 'package:whiteboard_canvas/markdown/markdown_painter.dart';
import 'package:whiteboard_canvas/markdown/markdown_theme.dart';
import 'package:whiteboard_canvas/markdown/markdown_view.dart';

/// 读取当前缩放百分比文本。
String _scale(WidgetTester tester) {
  final Text text = tester.widget<Text>(find.descendant(
    of: find.byKey(const ValueKey<String>('wb-md-mermaid-scale')),
    matching: find.byType(Text),
  ));
  return text.data ?? '';
}

void main() {
  const String source = '```mermaid\n'
      'flowchart TB\n'
      '    subgraph 预览\n'
      '        A[开始] --> B[结束]\n'
      '    end\n'
      '```';

  testWidgets('点击图块弹出查看器：缩放 / 重置 / 关闭', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1024, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WbMarkdownView(source: source),
        ),
      ),
    ));
    await tester.pump();

    // 定位图块（mermaidCode 非空的绘制指令）中心并点击。
    final WbMdLayoutResult result = WbMarkdownRenderCache.layoutFor(
      source: source,
      width: 1024,
      theme: WbMarkdownTheme.light,
    );
    final WbMdDrawOp op = result.ops
        .firstWhere((WbMdDrawOp item) => item.mermaidCode.isNotEmpty);
    await tester.tapAt(op.rect.center);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('wb-md-mermaid-viewer')),
      findsOneWidget,
    );

    // 缩放：放大 → 百分比变化 → 重置回初始。
    final String initial = _scale(tester);
    await tester
        .tap(find.byKey(const ValueKey<String>('wb-md-mermaid-zoom-in')));
    await tester.pump();
    expect(_scale(tester), isNot(initial));
    await tester
        .tap(find.byKey(const ValueKey<String>('wb-md-mermaid-reset')));
    await tester.pump();
    expect(_scale(tester), initial);

    // 关闭视图。
    await tester
        .tap(find.byKey(const ValueKey<String>('wb-md-mermaid-close')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('wb-md-mermaid-viewer')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
