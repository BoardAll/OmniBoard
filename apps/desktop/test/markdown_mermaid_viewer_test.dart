/// Mermaid 查看器 widget 测试：
/// 挂载 / 缩放百分比 / 上限 / 重置 / 关闭回调 / 拖拽平移与双击重置；
/// WbMarkdownView 点击图块弹出查看器并可关闭。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_layout.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_painter.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_theme.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_view.dart';
import 'package:whiteboard_desktop/widgets/markdown/mermaid_viewer.dart';

const String _flowchart = 'flowchart TD\n'
    '    A[开始] --> B{判断}\n'
    '    B -->|是| C[结束]';

/// 读取当前缩放百分比文本。
String _scale(WidgetTester tester) {
  final Text text = tester.widget<Text>(find.descendant(
    of: find.byKey(const ValueKey<String>('wb-md-mermaid-scale')),
    matching: find.byType(Text),
  ));
  return text.data ?? '';
}

Future<void> _pumpViewer(
  WidgetTester tester, {
  String code = _flowchart,
  double? layoutWidth,
  VoidCallback? onClose,
}) async {
  tester.view.physicalSize = const Size(900, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 800,
            height: 560,
            child: WbMermaidViewer(
              code: code,
              theme: WbMarkdownTheme.light,
              layoutWidth: layoutWidth,
              onClose: onClose,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('WbMermaidViewer', () {
    testWidgets('挂载：根容器 / 工具条按钮 / 百分比 / 无关闭按钮', (WidgetTester tester) async {
      await _pumpViewer(tester);
      expect(
        find.byKey(const ValueKey<String>('wb-md-mermaid-viewer')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('wb-md-mermaid-zoom-in')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('wb-md-mermaid-zoom-out')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('wb-md-mermaid-reset')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('wb-md-mermaid-close')),
        findsNothing,
      );
      expect(_scale(tester), endsWith('%'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('缩放按钮 / 上限封顶 / 重置 / 关闭回调', (WidgetTester tester) async {
      int closed = 0;
      await _pumpViewer(tester, onClose: () => closed++);
      final String initial = _scale(tester);
      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-mermaid-zoom-in')));
      await tester.pump();
      expect(_scale(tester), isNot(initial));
      for (int i = 0; i < 12; i++) {
        await tester
            .tap(find.byKey(const ValueKey<String>('wb-md-mermaid-zoom-in')));
        await tester.pump();
      }
      expect(_scale(tester), '500%');
      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-mermaid-reset')));
      await tester.pump();
      expect(_scale(tester), initial);
      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-mermaid-close')));
      await tester.pump();
      expect(closed, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('拖拽平移与双击重置不抛', (WidgetTester tester) async {
      await _pumpViewer(tester);
      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-mermaid-zoom-in')));
      await tester.pump();
      final String zoomed = _scale(tester);
      final Offset center = tester.getCenter(
        find.byKey(const ValueKey<String>('wb-md-mermaid-viewer')),
      );
      await tester.dragFrom(
        center + const Offset(0, 40),
        const Offset(60, 30),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      // 双击重置为适应窗口（fit）比例。
      await tester.tapAt(center + const Offset(0, 60));
      await tester.pump(const Duration(milliseconds: 120));
      await tester.tapAt(center + const Offset(0, 60));
      // 等待双击识别器的倒计时定时器结束（避免 pending timer）。
      await tester.pump(const Duration(milliseconds: 500));
      expect(_scale(tester), isNot(zoomed));
      expect(tester.takeException(), isNull);
    });

    testWidgets('类图按有限布局宽换行（初始缩放 100%）', (WidgetTester tester) async {
      const String classCode = 'classDiagram\n'
          '    class A\n'
          '    class B\n'
          '    class C\n'
          '    class D\n'
          '    class E\n'
          '    class F';
      await _pumpViewer(tester, code: classCode, layoutWidth: 360);
      // 换行后的图盒（约 248×245）完全放得下视口 → 初始缩放 100%；
      // 若回退为无限宽布局（单行 800×59）会被缩小到约 96%。
      expect(_scale(tester), '100%');
      expect(tester.takeException(), isNull);
    });
  });

  group('WbMarkdownView 点击放大', () {
    testWidgets('点击图块弹出查看器并可关闭', (WidgetTester tester) async {
      const String source = '```mermaid\n'
          'flowchart TD\n'
          '    A[开始] --> B[结束]\n'
          '```';
      tester.view.physicalSize = const Size(900, 640);
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
        width: 900,
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
      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-mermaid-close')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('wb-md-mermaid-viewer')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('关闭交互后点击非图区域不弹窗', (WidgetTester tester) async {
      const String source = '# 标题\n\n正文段落。\n\n'
          '```mermaid\nflowchart LR\n    A --> B\n```';
      tester.view.physicalSize = const Size(900, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WbMarkdownView(source: source, mermaidInteractive: false),
          ),
        ),
      ));
      await tester.pump();
      await tester.tapAt(const Offset(60, 30));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey<String>('wb-md-mermaid-viewer')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
