/// Markdown 解析器（GFM 子集）测试：逐块用例 + 容错用例。
///
/// 覆盖方案 §16 必须清单：标题 / 段落 / 行内样式 / 列表 / 引用 / 表格 /
/// 代码块 / 公式 / 图表 / 分割线 / 图片 / 链接；非法语法不抛出（容错
/// 语义，方案 §20）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_ast.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_parser.dart';

void main() {
  group('块级解析', () {
    test('标题 1..6 级与收尾井号', () {
      final WbMdDocument doc = WbMarkdownParser.parse(
        '# 一级\n## 二级\n### 三级 ###\n###### 六级',
      );
      expect(doc.blocks.length, 4);
      final WbMdHeading first = doc.blocks[0] as WbMdHeading;
      expect(first.level, 1);
      expect(wbMdInlinePlainText(first.inlines), '一级');
      expect((doc.blocks[1] as WbMdHeading).level, 2);
      expect(
        wbMdInlinePlainText((doc.blocks[2] as WbMdHeading).inlines),
        '三级',
      );
      expect((doc.blocks[3] as WbMdHeading).level, 6);
    });

    test('段落：连续行合并为软换行', () {
      final WbMdDocument doc =
          WbMarkdownParser.parse('第一行\n第二行\n\n第二段');
      expect(doc.blocks.length, 2);
      final WbMdParagraph para = doc.blocks[0] as WbMdParagraph;
      expect(wbMdInlinePlainText(para.inlines), '第一行\n第二行');
    });

    test('分割线：--- / *** / ___', () {
      final WbMdDocument doc =
          WbMarkdownParser.parse('---\n\n***\n\n___');
      expect(doc.blocks.length, 3);
      expect(doc.blocks[0], isA<WbMdDivider>());
      expect(doc.blocks[1], isA<WbMdDivider>());
      expect(doc.blocks[2], isA<WbMdDivider>());
    });

    test('引用块：多行合并，内含行内样式', () {
      final WbMdDocument doc =
          WbMarkdownParser.parse('> 引用一\n> 引用二 **加粗**');
      expect(doc.blocks.length, 1);
      final WbMdQuote quote = doc.blocks[0] as WbMdQuote;
      expect(quote.blocks.length, 1);
      final WbMdParagraph inner = quote.blocks[0] as WbMdParagraph;
      expect(wbMdInlinePlainText(inner.inlines), '引用一\n引用二 加粗');
      expect(inner.inlines.whereType<WbMdText>().any((WbMdText t) => t.bold),
          isTrue);
    });

    test('无序 / 有序 / 起始序号列表', () {
      final WbMdListBlock unordered = WbMarkdownParser.parse(
        '- 甲\n- 乙',
      ).blocks.single as WbMdListBlock;
      expect(unordered.ordered, isFalse);
      expect(unordered.items.length, 2);

      final WbMdListBlock ordered = WbMarkdownParser.parse(
        '1. 一\n2. 二',
      ).blocks.single as WbMdListBlock;
      expect(ordered.ordered, isTrue);
      expect(ordered.start, 1);
      expect(ordered.items.length, 2);

      final WbMdListBlock fromThree = WbMarkdownParser.parse(
        '3. 三\n4. 四',
      ).blocks.single as WbMdListBlock;
      expect(fromThree.start, 3);
    });

    test('任务列表：勾选状态', () {
      final WbMdListBlock list = WbMarkdownParser.parse(
        '- [x] 完成\n- [ ] 未完成',
      ).blocks.single as WbMdListBlock;
      expect(list.items[0].checked, isTrue);
      expect(list.items[1].checked, isFalse);
      expect(wbMdInlinePlainText(list.items[0].inlines), '完成');
    });

    test('嵌套列表：缩进构建子列表', () {
      final WbMdListBlock list = WbMarkdownParser.parse(
        '- 父项\n  - 子项',
      ).blocks.single as WbMdListBlock;
      expect(list.items.length, 1);
      final WbMdListBlock? children = list.items[0].children;
      expect(children, isNotNull);
      expect(wbMdInlinePlainText(children!.items[0].inlines), '子项');
    });

    test('表格：表头 / 对齐 / 数据行', () {
      final WbMdTableBlock table = WbMarkdownParser.parse(
        '| A | B |\n| --- | :--: |\n| 1 | 2 |',
      ).blocks.single as WbMdTableBlock;
      expect(table.columnCount, 2);
      expect(table.aligns, <WbMdTableAlign>[
        WbMdTableAlign.left,
        WbMdTableAlign.center,
      ]);
      expect(table.rows.length, 1);
      expect(wbMdInlinePlainText(table.header[0]), 'A');
      expect(wbMdInlinePlainText(table.rows[0][1]), '2');
    });

    test('围栏代码块：语言与内容', () {
      final WbMdCodeBlock code = WbMarkdownParser.parse(
        '```dart\nvoid main() {}\n```',
      ).blocks.single as WbMdCodeBlock;
      expect(code.language, 'dart');
      expect(code.code, 'void main() {}');
    });

    test('mermaid 围栏 → 独立图表块', () {
      final WbMdBlock block = WbMarkdownParser.parse(
        '```mermaid\nflowchart TD\n    A --> B\n```',
      ).blocks.single;
      expect(block, isA<WbMdMermaidBlock>());
      expect((block as WbMdMermaidBlock).code, 'flowchart TD\n    A --> B');
    });

    test('块级公式：单行 \$\$...\$\$ 与跨行围栏', () {
      final WbMdMathBlock single = WbMarkdownParser.parse(
        r'$$E = mc^2$$',
      ).blocks.single as WbMdMathBlock;
      expect(single.latex, 'E = mc^2');

      final WbMdMathBlock multi = WbMarkdownParser.parse(
        '\$\$\n\\frac{a}{b}\n\$\$',
      ).blocks.single as WbMdMathBlock;
      expect(multi.latex, r'\frac{a}{b}');
    });
  });

  group('行内解析', () {
    test('粗体 / 斜体 / 删除线 / 行内代码', () {
      final List<WbMdInline> inlines = WbMarkdownParser.parseInline(
        '**粗** *斜* ~~删~~ `码`',
      );
      final List<WbMdText> texts = inlines.whereType<WbMdText>().toList();
      expect(texts.any((WbMdText t) => t.bold), isTrue);
      expect(texts.any((WbMdText t) => t.italic), isTrue);
      expect(texts.any((WbMdText t) => t.strike), isTrue);
      expect(texts.any((WbMdText t) => t.code), isTrue);
    });

    test('链接 / 图片 / 行内公式', () {
      final List<WbMdInline> inlines = WbMarkdownParser.parseInline(
        '[示例](https://a.b) ![图](img.png) \$x^2\$',
      );
      final WbMdText link = inlines
          .whereType<WbMdText>()
          .firstWhere((WbMdText t) => t.link.isNotEmpty);
      expect(link.text, '示例');
      expect(link.link, 'https://a.b');
      final WbMdImage image = inlines.whereType<WbMdImage>().single;
      expect(image.alt, '图');
      expect(image.url, 'img.png');
      final WbMdInlineMath math = inlines.whereType<WbMdInlineMath>().single;
      expect(math.latex, r'x^2');
    });

    test('反斜杠转义：字面量星号不构成样式', () {
      final List<WbMdInline> inlines =
          WbMarkdownParser.parseInline(r'\*不斜体\*');
      expect(wbMdInlinePlainText(inlines), '*不斜体*');
      expect(
        inlines.whereType<WbMdText>().any((WbMdText t) => t.italic),
        isFalse,
      );
    });
  });

  group('容错语义（不抛出）', () {
    test('空文档 / 全空白', () {
      expect(WbMarkdownParser.parse('').blocks, isEmpty);
      expect(WbMarkdownParser.parse('   \n\n  ').blocks, isEmpty);
    });

    test('非法 / 未闭合结构均不抛出', () {
      const List<String> inputs = <String>[
        '**未闭合粗体',
        '[未闭合链接(https://a.b)',
        '![未闭合图片](x',
        '`未闭合行内代码',
        '```\n未闭合代码块',
        '\$\$',
        '####### 七级井号',
        '| 只有表头 |\n| 没有分隔行 |',
        '1. 有序\n- 混排无序',
        '\u0000控制字符',
      ];
      for (final String input in inputs) {
        expect(
          () => WbMarkdownParser.parse(input),
          returnsNormally,
          reason: input,
        );
        expect(WbMarkdownParser.parse(input), isA<WbMdDocument>());
      }
    });

    test('未闭合围栏：内容读到结尾不抛出', () {
      final WbMdDocument doc = WbMarkdownParser.parse('```\ncode 行 1\ncode 行 2');
      final WbMdCodeBlock code = doc.blocks.single as WbMdCodeBlock;
      expect(code.code, 'code 行 1\ncode 行 2');
    });
  });
}
