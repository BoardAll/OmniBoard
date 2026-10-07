/// Markdown 元素接入测试：payload codec 往返（`.wbd`）、专业元素
/// measure / paint、渲染缓存命中与失效、性能用例（宽松阈值）。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/services/board_file_codec.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';
import 'package:whiteboard_desktop/widgets/canvas/professional_painter.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_layout.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_model.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_painter.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_theme.dart';

void main() {
  group('payload 模型与 codec', () {
    test('WbMarkdownModel.toJson / fromJson 往返', () {
      const WbMarkdownModel model = WbMarkdownModel(
        source: '# 标题\n\n正文 **粗**',
        autoHeight: true,
      );
      final Map<String, dynamic> json = model.toJson();
      expect(json['source'], model.source);
      expect((json['options']! as Map<String, dynamic>)['autoHeight'], true);
      final WbMarkdownModel back = WbMarkdownModel.fromJson(json);
      expect(back.source, model.source);
      expect(back.autoHeight, true);
    });

    test('fromJson 容忍坏数据（缺字段 / 类型不符）', () {
      final WbMarkdownModel model = WbMarkdownModel.fromJson(
        <String, dynamic>{'source': 42, 'options': 'bad'},
      );
      expect(model.source, '');
      expect(model.autoHeight, false);
    });

    test('fromPayload 归一：模型 / Map / 其余为 null', () {
      const WbMarkdownModel model = WbMarkdownModel(source: 'x');
      expect(WbMarkdownModel.fromPayload(model), same(model));
      final WbMarkdownModel? fromMap = WbMarkdownModel.fromPayload(
        <String, dynamic>{
          'source': 'y',
          'options': <String, dynamic>{'autoHeight': true},
        },
      );
      expect(fromMap, isNotNull);
      expect(fromMap!.source, 'y');
      expect(fromMap.autoHeight, true);
      expect(WbMarkdownModel.fromPayload(null), isNull);
      expect(WbMarkdownModel.fromPayload('raw'), isNull);
    });

    test('.wbd 编解码：markdown payload 往返', () {
      const WbBoardData data = WbBoardData(
        boardId: 'b-md',
        boardName: 'Markdown 板',
        currentPageId: 'p1',
        pages: <WbBoardPageData>[
          WbBoardPageData(
            id: 'p1',
            name: '页 1',
            elements: <WbCanvasElement>[
              WbCanvasElement(
                id: 'md-1',
                type: WbElementKind.markdown,
                x: 10,
                y: 20,
                width: 420,
                height: 320,
                payload: WbMarkdownModel(
                  source: '# 标题\n\n\$x^2\$',
                  autoHeight: true,
                ),
              ),
            ],
          ),
        ],
      );
      final String encoded = WbBoardFileCodec.encode(data);
      final WbBoardData decoded = WbBoardFileCodec.decode(encoded);
      final WbCanvasElement element = decoded.pages.single.elements.single;
      expect(element.type, WbElementKind.markdown);
      final WbMarkdownModel? model =
          WbMarkdownModel.fromPayload(element.payload);
      expect(model, isNotNull);
      expect(model!.source, '# 标题\n\n\$x^2\$');
      expect(model.autoHeight, true);
    });
  });

  group('专业元素 measure / paint', () {
    test('measure 返回非空且不小于下限', () {
      final Size? size = WbProfessionalRenderer.measure(
        WbElementKind.markdown,
        WbMarkdownModel.sample(),
      );
      expect(size, isNotNull);
      expect(size!.width, greaterThanOrEqualTo(140));
      expect(size.height, greaterThanOrEqualTo(90));
    });

    test('paint：模型 / Map payload 均返回 true，缺失返回 false', () {
      final WbCanvasTextCache textCache = WbCanvasTextCache();
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      const WbCanvasElement withModel = WbCanvasElement(
        id: 'md-1',
        type: WbElementKind.markdown,
        x: 0,
        y: 0,
        width: 420,
        height: 320,
        payload: WbMarkdownModel(source: '# 标题\n\n正文'),
      );
      expect(
        WbProfessionalRenderer.paint(canvas, withModel, textCache),
        isTrue,
      );
      const WbCanvasElement withMap = WbCanvasElement(
        id: 'md-2',
        type: WbElementKind.markdown,
        x: 460,
        y: 0,
        width: 420,
        height: 320,
        payload: <String, dynamic>{
          'source': '## 来自引擎',
          'options': <String, dynamic>{'autoHeight': false},
        },
      );
      expect(WbProfessionalRenderer.paint(canvas, withMap, textCache), isTrue);
      const WbCanvasElement withoutPayload = WbCanvasElement(
        id: 'md-3',
        type: WbElementKind.markdown,
        x: 0,
        y: 360,
        width: 420,
        height: 320,
      );
      expect(
        WbProfessionalRenderer.paint(canvas, withoutPayload, textCache),
        isFalse,
      );
      recorder.endRecording().dispose();
    });
  });

  group('渲染缓存（LRU：sourceHash + width + themeId）', () {
    const String source = '# 缓存\n\n**正文** 段落 \$x^2\$';

    setUp(() {
      WbMarkdownRenderCache.clear();
      WbMarkdownRenderCache.resetStats();
    });

    test('同 source / 宽度 / 主题命中缓存（不重复 Parse）', () {
      final WbMdLayoutResult first = WbMarkdownRenderCache.layoutFor(
        source: source,
        width: 420,
        theme: WbMarkdownTheme.light,
      );
      final WbMdLayoutResult second = WbMarkdownRenderCache.layoutFor(
        source: source,
        width: 420,
        theme: WbMarkdownTheme.light,
      );
      expect(identical(first, second), isTrue);
      expect(WbMarkdownRenderCache.parseCount, 1);
      expect(WbMarkdownRenderCache.hitCount, 1);
      expect(first.height, greaterThan(0));
    });

    test('移动 / 选择（同尺寸不同位置绘制）不重新 Parse', () {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      WbMarkdownPainter.paint(
        canvas,
        const Rect.fromLTWH(10, 10, 420, 320),
        source: source,
        theme: WbMarkdownTheme.light,
      );
      WbMarkdownPainter.paint(
        canvas,
        const Rect.fromLTWH(500, 300, 420, 320),
        source: source,
        theme: WbMarkdownTheme.light,
      );
      expect(WbMarkdownRenderCache.parseCount, 1);
      expect(WbMarkdownRenderCache.hitCount, 1);
      recorder.endRecording().dispose();
    });

    test('宽度变化（resize）重排并重新 Parse', () {
      WbMarkdownRenderCache.layoutFor(
        source: source,
        width: 420,
        theme: WbMarkdownTheme.light,
      );
      WbMarkdownRenderCache.layoutFor(
        source: source,
        width: 520,
        theme: WbMarkdownTheme.light,
      );
      expect(WbMarkdownRenderCache.parseCount, 2);
      // 回到原宽度：命中旧条目。
      WbMarkdownRenderCache.layoutFor(
        source: source,
        width: 420,
        theme: WbMarkdownTheme.light,
      );
      expect(WbMarkdownRenderCache.parseCount, 2);
      expect(WbMarkdownRenderCache.hitCount, 1);
    });

    test('主题切换重排（themeId 参与 key）', () {
      WbMarkdownRenderCache.layoutFor(
        source: source,
        width: 420,
        theme: WbMarkdownTheme.light,
      );
      WbMarkdownRenderCache.layoutFor(
        source: source,
        width: 420,
        theme: WbMarkdownTheme.dark,
      );
      expect(WbMarkdownRenderCache.parseCount, 2);
    });

    test('字体变更（clear）后重新 Parse', () {
      WbMarkdownRenderCache.layoutFor(
        source: source,
        width: 420,
        theme: WbMarkdownTheme.light,
      );
      expect(WbMarkdownRenderCache.parseCount, 1);
      WbMarkdownRenderCache.clear();
      WbMarkdownRenderCache.layoutFor(
        source: source,
        width: 420,
        theme: WbMarkdownTheme.light,
      );
      expect(WbMarkdownRenderCache.parseCount, 2);
    });

    test('measureHeight 与 paint 共用同一缓存', () {
      final double height = WbMarkdownPainter.measureHeight(source, 420);
      expect(height, greaterThan(0));
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      WbMarkdownPainter.paint(
        canvas,
        Rect.fromLTWH(0, 0, 420, height),
        source: source,
        theme: WbMarkdownTheme.light,
      );
      expect(WbMarkdownRenderCache.parseCount, 1);
      expect(WbMarkdownRenderCache.hitCount, 1);
      recorder.endRecording().dispose();
    });
  });

  group('性能用例（宽松阈值：仅断言完成与缓存命中）', () {
    test('1000 行文档', () {
      final StringBuffer source = StringBuffer();
      for (int i = 0; i < 1000; i++) {
        source.write('第 $i 行：普通文本内容 **加粗** `代码`\n');
      }
      _expectMeasurable(source.toString());
    });

    test('100 个行内公式', () {
      final StringBuffer source = StringBuffer();
      for (int i = 0; i < 100; i++) {
        source.write(r'行内公式 $x_i^2 + \frac{1}{2}$ 第 ');
        source.write('$i 行\n\n');
      }
      _expectMeasurable(source.toString());
    });

    test('20 个 Mermaid 图', () {
      final StringBuffer source = StringBuffer();
      for (int i = 0; i < 20; i++) {
        source.write('```mermaid\nflowchart TD\n');
        source.write('    A$i[开始] --> B$i{判断}\n');
        source.write('    B$i -->|是| C$i[结束]\n```\n\n');
      }
      _expectMeasurable(source.toString());
    });

    test('10 个大型 classDiagram', () {
      final StringBuffer source = StringBuffer();
      for (int k = 0; k < 10; k++) {
        source.write('```mermaid\nclassDiagram\n');
        for (int c = 0; c < 20; c++) {
          source.write('    class C$k-$c {\n');
          source.write('        +int field$c\n');
          source.write('        +String name$c\n');
          source.write('        +run$c()\n');
          source.write('    }\n');
          if (c > 0) {
            source.write('    C$k-${c - 1} <|-- C$k-$c\n');
          }
        }
        source.write('```\n\n');
      }
      _expectMeasurable(source.toString());
    });

    test('10000 字符代码块', () {
      final String code = List<String>.filled(10000, 'x').join();
      _expectMeasurable('```text\n$code\n```');
    });
  });
}

/// 断言一次测量完成（高度 > 0）且二次测量命中缓存（Parse 次数不增）。
void _expectMeasurable(String source) {
  WbMarkdownRenderCache.clear();
  WbMarkdownRenderCache.resetStats();
  final double first = WbMarkdownPainter.measureHeight(source, 720);
  expect(first, greaterThan(0));
  final double second = WbMarkdownPainter.measureHeight(source, 720);
  expect(second, first);
  expect(WbMarkdownRenderCache.parseCount, 1);
  expect(WbMarkdownRenderCache.hitCount, 1);
}
