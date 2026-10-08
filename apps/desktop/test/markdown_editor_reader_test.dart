/// Markdown 编辑器 / 阅读器 widget 测试：
/// 编辑器分栏挂载 / debounce 上报 / 模式切换 / 插入动作 / 关闭补发；
/// Reader 滚动 / 搜索 / 目录 / 缩放 / 编辑与退出回调 / 错误卡片渲染。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_editor.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_model.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_reader.dart';

/// 在 1280x800 逻辑窗口中挂载组件。
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1280, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: child)),
  );
  await tester.pump();
}

String _sourceText(WidgetTester tester) {
  final TextField field = tester.widget<TextField>(
    find.byKey(const ValueKey<String>('wb-md-editor-source')),
  );
  return field.controller!.text;
}

void main() {
  group('WbMarkdownEditor', () {
    testWidgets('编辑工作区挂载：源码 + 预览分栏默认展示', (WidgetTester tester) async {
      await _pump(tester, const WbMarkdownEditor());
      expect(find.byKey(const ValueKey<String>('wb-md-editor')), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('wb-md-editor-source-pane')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('wb-md-editor-preview')),
        findsOneWidget,
      );
      expect(_sourceText(tester), WbMarkdownModel.defaultSource);
      expect(tester.takeException(), isNull);
    });

    testWidgets('输入 debounce 300ms 后上报 onChanged', (WidgetTester tester) async {
      final List<WbMarkdownModel> emitted = <WbMarkdownModel>[];
      await _pump(tester, WbMarkdownEditor(onChanged: emitted.add));
      await tester.enterText(
        find.byKey(const ValueKey<String>('wb-md-editor-source')),
        '# 新内容',
      );
      await tester.pump();
      expect(emitted, isEmpty, reason: 'debounce 未到期不上报');
      await tester.pump(const Duration(milliseconds: 320));
      expect(emitted.single.source, '# 新内容');
      expect(tester.takeException(), isNull);
    });

    testWidgets('模式切换：源码 / 预览 / 双栏', (WidgetTester tester) async {
      await _pump(tester, const WbMarkdownEditor());
      final Finder sourcePane =
          find.byKey(const ValueKey<String>('wb-md-editor-source-pane'));
      final Finder preview =
          find.byKey(const ValueKey<String>('wb-md-editor-preview'));

      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-editor-mode-preview')));
      await tester.pump();
      expect(sourcePane, findsNothing);
      expect(preview, findsOneWidget);

      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-editor-mode-source')));
      await tester.pump();
      expect(sourcePane, findsOneWidget);
      expect(preview, findsNothing);

      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-editor-mode-split')));
      await tester.pump();
      expect(sourcePane, findsOneWidget);
      expect(preview, findsOneWidget);
    });

    testWidgets('插入动作：即时应用并上报（不走 debounce）', (WidgetTester tester) async {
      final List<WbMarkdownModel> emitted = <WbMarkdownModel>[];
      await _pump(
        tester,
        WbMarkdownEditor(
          initialModel: const WbMarkdownModel(source: 'abc'),
          onChanged: emitted.add,
        ),
      );
      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-editor-insert-bold')));
      await tester.pump();
      expect(_sourceText(tester), 'abc**粗体**');
      expect(emitted.single.source, 'abc**粗体**');

      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-editor-insert-table')));
      await tester.pump();
      expect(_sourceText(tester), contains('| 列 A | 列 B |'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('关闭：补齐未上报编辑并回调 onClose', (WidgetTester tester) async {
      final List<WbMarkdownModel> emitted = <WbMarkdownModel>[];
      bool closed = false;
      await _pump(
        tester,
        WbMarkdownEditor(
          initialModel: const WbMarkdownModel(source: 'abc'),
          onChanged: emitted.add,
          onClose: () => closed = true,
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('wb-md-editor-source')),
        'abc 末尾',
      );
      await tester.pump();
      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-editor-close')));
      await tester.pump();
      expect(closed, isTrue);
      expect(emitted.single.source, 'abc 末尾');
    });

    testWidgets('销毁时补发未来得及 debounce 的编辑', (WidgetTester tester) async {
      final List<WbMarkdownModel> emitted = <WbMarkdownModel>[];
      await _pump(
        tester,
        WbMarkdownEditor(
          initialModel: const WbMarkdownModel(source: 'abc'),
          onChanged: emitted.add,
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('wb-md-editor-source')),
        'abcdef',
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(emitted.single.source, 'abcdef');
    });

    testWidgets('错误语法（非法 Mermaid / 公式）渲染不抛出', (WidgetTester tester) async {
      await _pump(
        tester,
        const WbMarkdownEditor(
          initialModel: WbMarkdownModel(
            source: '```mermaid\nbogus\n```\n\n\$\$\n\\\\frac{\$\$\n',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 320));
      expect(find.byKey(const ValueKey<String>('wb-md-editor-preview')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('WbMarkdownReader', () {
    const String source = '# 概述\n\n正文第一段\n\n## 小节\n\n更多内容';

    testWidgets('挂载：目录侧栏与标题锚点', (WidgetTester tester) async {
      await _pump(tester, const WbMarkdownReader(source: source));
      expect(find.byKey(const ValueKey<String>('wb-md-reader')), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('wb-md-reader-toc')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('wb-md-reader-toc-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('wb-md-reader-toc-1')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('目录点击定位与折叠切换', (WidgetTester tester) async {
      await _pump(tester, const WbMarkdownReader(source: source));
      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-reader-toc-1')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-reader-toc-toggle')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('wb-md-reader-toc')),
        findsNothing,
      );
    });

    testWidgets('搜索：命中计数显示', (WidgetTester tester) async {
      await _pump(tester, const WbMarkdownReader(source: source));
      await tester.enterText(
        find.byKey(const ValueKey<String>('wb-md-reader-search')),
        '正文',
      );
      await tester.pump();
      expect(find.text('1 处'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey<String>('wb-md-reader-search')),
        '不存在的词',
      );
      await tester.pump();
      expect(find.text('0 处'), findsOneWidget);
    });

    testWidgets('缩放：显示比例随按钮更新且不越界', (WidgetTester tester) async {
      await _pump(tester, const WbMarkdownReader(source: source));
      expect(find.text('100%'), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-reader-zoom-in')));
      await tester.pump();
      expect(find.text('110%'), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-reader-zoom-out')));
      await tester.pump();
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('编辑 / 退出回调', (WidgetTester tester) async {
      bool edited = false;
      bool closed = false;
      await _pump(
        tester,
        WbMarkdownReader(
          source: source,
          onEdit: () => edited = true,
          onClose: () => closed = true,
        ),
      );
      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-reader-edit')));
      await tester.pump();
      expect(edited, isTrue);
      await tester
          .tap(find.byKey(const ValueKey<String>('wb-md-reader-close')));
      await tester.pump();
      expect(closed, isTrue);
    });

    testWidgets('错误语法渲染不抛出（错误卡片）', (WidgetTester tester) async {
      await _pump(
        tester,
        const WbMarkdownReader(
          source: '```mermaid\nflowchart TD\n    ???\n```',
        ),
      );
      expect(find.byKey(const ValueKey<String>('wb-md-reader')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
