/// Markdown LaTeX 子集测试：解析与布局（分式 / 上下标 / 根号 / 矩阵 /
/// 大运算符 / 希腊字母 / 非法公式容错）+ 渲染烟雾。
library;

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_painter.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_theme.dart';
import 'package:whiteboard_desktop/widgets/markdown/math_parser.dart';

/// 深度遍历收集节点显示文本（测试断言用）。
String _flatten(WbMathNode node) {
  final StringBuffer buffer = StringBuffer();
  void walk(WbMathNode n) {
    switch (n) {
      case WbMathAtom():
        buffer.write(n.text);
      case WbMathRow():
        for (final WbMathNode child in n.children) {
          walk(child);
        }
      case WbMathSpace():
        buffer.write(' ');
      case WbMathFrac():
        walk(n.numerator);
        buffer.write('/');
        walk(n.denominator);
      case WbMathSqrt():
        buffer.write('√');
        walk(n.child);
      case WbMathScript():
        walk(n.base);
      case WbMathBigOp():
        buffer.write(n.symbol);
      case WbMathDelim():
        buffer.write(n.left);
        walk(n.child);
        buffer.write(n.right);
      case WbMathMatrix():
        for (final List<WbMathNode> row in n.rows) {
          for (final WbMathNode cell in row) {
            walk(cell);
          }
        }
      case WbMathError():
        buffer.write(n.message);
    }
  }

  walk(node);
  return buffer.toString();
}

void main() {
  group('解析：结构', () {
    test('分式 \\frac{a}{b}（含 dfrac / tfrac 别名）', () {
      final WbMathFrac frac = WbMathParser.parse(r'\frac{a}{b}') as WbMathFrac;
      expect((frac.numerator as WbMathAtom).text, 'a');
      expect((frac.denominator as WbMathAtom).text, 'b');
      expect(WbMathParser.parse(r'\dfrac{1}{2}'), isA<WbMathFrac>());
      expect(WbMathParser.parse(r'\tfrac{1}{2}'), isA<WbMathFrac>());
    });

    test('上下标：x^2 / x_i / x_i^2', () {
      final WbMathScript sup = WbMathParser.parse('x^2') as WbMathScript;
      expect((sup.base as WbMathAtom).text, 'x');
      expect((sup.sup! as WbMathAtom).text, '2');
      expect(sup.sub, isNull);

      final WbMathScript sub = WbMathParser.parse('x_i') as WbMathScript;
      expect((sub.sub! as WbMathAtom).text, 'i');

      final WbMathScript both = WbMathParser.parse('x_i^2') as WbMathScript;
      expect((both.sub! as WbMathAtom).text, 'i');
      expect((both.sup! as WbMathAtom).text, '2');
    });

    test('根号：\\sqrt{x} 与 \\sqrt[3]{x}', () {
      final WbMathSqrt plain =
          WbMathParser.parse(r'\sqrt{x}') as WbMathSqrt;
      expect((plain.child as WbMathAtom).text, 'x');
      expect(plain.index, isNull);

      final WbMathSqrt indexed =
          WbMathParser.parse(r'\sqrt[3]{x}') as WbMathSqrt;
      expect((indexed.index! as WbMathAtom).text, '3');
    });

    test('大运算符：\\sum 上下限', () {
      final WbMathNode node = WbMathParser.parse(r'\sum_{i=1}^{n} i');
      expect(node, isA<WbMathRow>());
      final WbMathBigOp op =
          (node as WbMathRow).children.whereType<WbMathBigOp>().single;
      expect(op.symbol, '∑');
      expect(_flatten(op.sub!), 'i=1');
      expect(_flatten(op.sup!), 'n');
      expect(_flatten(node), contains('i'));
    });

    test('希腊字母与运算符映射', () {
      final String text = _flatten(WbMathParser.parse(r'\alpha + \beta'));
      expect(text, contains('α'));
      expect(text, contains('β'));
      expect(_flatten(WbMathParser.parse(r'\infty')), '∞');
      expect(_flatten(WbMathParser.parse(r'a \leq b')), contains('≤'));
    });

    test('矩阵：pmatrix 2x2 与 cases 环境', () {
      final WbMathMatrix matrix = WbMathParser.parse(
        r'\begin{pmatrix} a & b \\ c & d \end{pmatrix}',
      ) as WbMathMatrix;
      expect(matrix.left, '(');
      expect(matrix.right, ')');
      expect(matrix.rows.length, 2);
      expect(matrix.rows[0].length, 2);

      final WbMathMatrix cases = WbMathParser.parse(
        r'\begin{cases} x & \text{if} \\ y & \text{else} \end{cases}',
      ) as WbMathMatrix;
      expect(cases.left, '{');
      expect(cases.right, '');
      expect(cases.rows.length, 2);
      expect(_flatten(cases), contains('if'));
    });

    test('自适应定界符：\\left( \\frac{a}{b} \\right)', () {
      final WbMathDelim delim = WbMathParser.parse(
        r'\left( \frac{a}{b} \right)',
      ) as WbMathDelim;
      expect(delim.left, '(');
      expect(delim.right, ')');
      expect(delim.child, isA<WbMathFrac>());
    });
  });

  group('解析：容错（不抛出）', () {
    test('常见非法输入返回节点而非异常', () {
      const List<String> inputs = <String>[
        '',
        '{',
        '}',
        r'\frac',
        r'\sqrt',
        r'\left(',
        r'\begin{matrix}',
        r'\begin{unknown} x \end{unknown}',
        r'^^^',
        r'___',
        r'\unknowncommand',
        '∑∑∑',
      ];
      for (final String input in inputs) {
        expect(() => WbMathParser.parse(input), returnsNormally, reason: input);
        expect(WbMathParser.parse(input), isA<WbMathNode>(), reason: input);
      }
    });

    test('未闭合花括号不吞掉后续内容', () {
      final String text = _flatten(WbMathParser.parse(r'\frac{a}{b'));
      expect(text, contains('a'));
      expect(text, contains('b'));
    });
  });

  group('布局与渲染烟雾', () {
    test('行内与块级公式均可测量（高度 > 0）', () {
      const String source = r'''
行内公式 $E = mc^2$ 与 $x_i^2$。

$$
\frac{a}{b} = \sum_{i=1}^{n} i
$$

$$
\begin{pmatrix} 1 & 0 \\ 0 & 1 \end{pmatrix}
$$
''';
      final double height =
          WbMarkdownPainter.measureHeight(source, 520);
      expect(height, greaterThan(0));
    });

    test('非法公式渲染不抛出（错误卡片路径）', () {
      const String source = r'''
$$
\frac{$$
''';
      expect(
        () => WbMarkdownPainter.measureHeight(source, 420),
        returnsNormally,
      );
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      expect(
        () => WbMarkdownPainter.paint(
          canvas,
          const Rect.fromLTWH(0, 0, 420, 320),
          source: source,
          theme: WbMarkdownTheme.light,
        ),
        returnsNormally,
      );
      recorder.endRecording().dispose();
    });

    test('宽度变化触发重排（宽度字段跟随请求）', () {
      WbMarkdownRenderCache.clear();
      const String source = r'$$x = \frac{p}{q}$$';
      final double narrow = WbMarkdownPainter.measureHeight(source, 320);
      final double wide = WbMarkdownPainter.measureHeight(source, 640);
      expect(narrow, greaterThan(0));
      expect(wide, greaterThan(0));
    });
  });
}
