/// Markdown Mermaid 子集测试：5 类图解析与布局
/// （flowchart / classDiagram / sequenceDiagram / stateDiagram-v2 /
/// erDiagram）+ 空图 / 单节点 / 非法语法容错。
library;

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_painter.dart';
import 'package:whiteboard_desktop/widgets/markdown/markdown_theme.dart';
import 'package:whiteboard_desktop/widgets/markdown/mermaid_parser.dart';
import 'package:whiteboard_desktop/widgets/markdown/mermaid_renderer.dart';

void main() {
  group('flowchart', () {
    test('方向 / 节点形状 / 带标签连线', () {
      final WbMermaidFlowchart chart = WbMermaidParser.parse(
        'flowchart TD\n'
        '    A[开始] --> B{判断}\n'
        '    B -->|是| C[结束]',
      ) as WbMermaidFlowchart;
      expect(chart.direction, 'TD');
      expect(chart.nodes.length, 3);
      expect(chart.nodes[0].label, '开始');
      expect(chart.nodes[0].shape, WbMermaidNodeShape.rect);
      expect(chart.nodes[1].shape, WbMermaidNodeShape.diamond);
      expect(chart.edges.length, 2);
      expect(chart.edges[1].label, '是');
      expect(chart.edges[1].hasArrow, isTrue);
    });

    test('链式连线与虚线 / 加粗样式', () {
      final WbMermaidFlowchart chart = WbMermaidParser.parse(
        'graph LR\n'
        '    A --> B -.-> C ==> D',
      ) as WbMermaidFlowchart;
      expect(chart.direction, 'LR');
      expect(chart.nodes.length, 4);
      expect(chart.edges.length, 3);
      expect(chart.edges[1].style, WbMermaidEdgeStyle.dotted);
      expect(chart.edges[2].style, WbMermaidEdgeStyle.thick);
    });

    test('单节点图与空图', () {
      final WbMermaidFlowchart single = WbMermaidParser.parse(
        'flowchart LR\n    A',
      ) as WbMermaidFlowchart;
      expect(single.nodes.length, 1);
      expect(single.edges, isEmpty);

      final WbMermaidFlowchart empty = WbMermaidParser.parse(
        'flowchart TD',
      ) as WbMermaidFlowchart;
      expect(empty.nodes, isEmpty);
    });

    test('subgraph 分组：成员归属 / 两种标题语法', () {
      final WbMermaidFlowchart chart = WbMermaidParser.parse(
        'flowchart TB\n'
        '    subgraph 预览[预览路径]\n'
        '        A[开始] --> B[处理]\n'
        '    end\n'
        '    subgraph 共享层\n'
        '        C[公共]\n'
        '    end\n'
        '    B --> C',
      ) as WbMermaidFlowchart;
      expect(chart.subgraphs.length, 2);
      expect(chart.subgraphs[0].id, '预览');
      expect(chart.subgraphs[0].title, '预览路径');
      expect(chart.subgraphs[0].nodeIds, <String>['A', 'B']);
      expect(chart.subgraphs[1].id, '共享层');
      expect(chart.subgraphs[1].title, '共享层');
      expect(chart.subgraphs[1].nodeIds, <String>['C']);
      expect(chart.nodes.length, 3);
      expect(chart.edges.length, 2);
    });

    test('subgraph 嵌套归属与未闭合 / 匿名容错', () {
      final WbMermaidFlowchart nested = WbMermaidParser.parse(
        'flowchart TD\n'
        '    subgraph 外层\n'
        '        subgraph 内层\n'
        '            A --> B\n'
        '        end\n'
        '        B --> C\n'
        '    end',
      ) as WbMermaidFlowchart;
      expect(nested.subgraphs.length, 2);
      expect(nested.subgraphs[0].nodeIds, <String>['C']);
      expect(nested.subgraphs[1].nodeIds, <String>['A', 'B']);

      final WbMermaidFlowchart unclosed = WbMermaidParser.parse(
        'flowchart TD\n'
        '    subgraph 未闭合\n'
        '        A --> B\n'
        '    subgraph 又一层\n'
        '        C',
      ) as WbMermaidFlowchart;
      expect(unclosed.subgraphs.length, 2);
      expect(unclosed.subgraphs[0].nodeIds, <String>['A', 'B']);
      expect(unclosed.subgraphs[1].nodeIds, <String>['C']);

      final WbMermaidFlowchart anonymous = WbMermaidParser.parse(
        'flowchart TD\n'
        '    subgraph\n'
        '        A --> B\n'
        '    end\n'
        '    B --> C',
      ) as WbMermaidFlowchart;
      expect(anonymous.subgraphs, isEmpty);
      expect(anonymous.nodes.length, 3);
    });
  });

  group('classDiagram', () {
    test('类块成员与继承关系', () {
      final WbMermaidClassDiagram chart = WbMermaidParser.parse(
        'classDiagram\n'
        '    class Animal {\n'
        '        +String name\n'
        '        +makeSound()\n'
        '    }\n'
        '    class Dog\n'
        '    Animal <|-- Dog',
      ) as WbMermaidClassDiagram;
      expect(chart.classes.length, 2);
      final WbMermaidClass animal = chart.classes
          .firstWhere((WbMermaidClass c) => c.name == 'Animal');
      expect(animal.members.length, 2);
      expect(chart.relations.length, 1);
      expect(chart.relations.single.type, WbMermaidRelationType.inheritance);
      expect(chart.relations.single.to, 'Dog');
    });

    test('关系标签与依赖 / 组合类型', () {
      final WbMermaidClassDiagram chart = WbMermaidParser.parse(
        'classDiagram\n'
        '    A --> B : uses\n'
        '    C *-- D\n'
        '    E ..> F',
      ) as WbMermaidClassDiagram;
      expect(chart.classes.length, 6);
      expect(chart.relations.length, 3);
      expect(chart.relations[0].label, 'uses');
      expect(chart.relations[1].type, WbMermaidRelationType.composition);
      expect(chart.relations[2].type, WbMermaidRelationType.dependency);
    });

    test('曲线与端点错位渲染不抛（同一类多条出边）', () {
      final WbMermaidClassDiagram chart = WbMermaidParser.parse(
        'classDiagram\n'
        '    class A\n'
        '    class B\n'
        '    class C\n'
        '    A <|-- B\n'
        '    A *-- C\n'
        '    B ..> C : uses',
      ) as WbMermaidClassDiagram;
      final WbMermaidBox box = WbMermaidRenderer.layout(
        chart,
        theme: WbMarkdownTheme.light,
        maxWidth: 600,
      );
      expect(box.size.width, greaterThan(0));
      expect(box.size.height, greaterThan(0));
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      expect(() => box.draw(canvas), returnsNormally);
      recorder.endRecording().dispose();
    });

    test('网格按有限 maxWidth 换行（窄容器多行 / 宽容器单行）', () {
      final WbMermaidClassDiagram chart = WbMermaidParser.parse(
        'classDiagram\n'
        '    class A\n'
        '    class B\n'
        '    class C\n'
        '    class D\n'
        '    class E\n'
        '    class F',
      ) as WbMermaidClassDiagram;
      final WbMermaidBox narrow = WbMermaidRenderer.layout(
        chart,
        theme: WbMarkdownTheme.light,
        maxWidth: 360,
      );
      final WbMermaidBox wide = WbMermaidRenderer.layout(
        chart,
        theme: WbMarkdownTheme.light,
        maxWidth: 2000,
      );
      // 窄容器换行成多行（更高、不超宽）；宽容器单行、整体更宽。
      expect(narrow.size.height, greaterThan(wide.size.height));
      expect(narrow.size.width, lessThanOrEqualTo(360));
      expect(wide.size.width, greaterThan(narrow.size.width));
    });
  });

  group('sequenceDiagram', () {
    test('参与者声明 / actor / 消息与 Note', () {
      final WbMermaidSequenceDiagram chart = WbMermaidParser.parse(
        'sequenceDiagram\n'
        '    participant A as Alice\n'
        '    actor B\n'
        '    A->>B: 你好\n'
        '    B-->>A: 收到\n'
        '    Note over A: 备注',
      ) as WbMermaidSequenceDiagram;
      expect(chart.participants.length, 2);
      expect(chart.participants[0].label, 'Alice');
      expect(chart.participants[1].isActor, isTrue);
      expect(chart.messages.length, 3);
      expect(chart.messages[0].text, '你好');
      expect(chart.messages[0].arrow, WbMermaidMessageArrow.filled);
      expect(chart.messages[1].dashed, isTrue);
      expect(chart.messages[2].note, WbMermaidNotePosition.over);
    });

    test('相邻泳道消息文字过长时自动撑大间距（箭头长于文字）', () {
      WbMermaidBox layoutOf(String message) {
        return WbMermaidRenderer.layout(
          WbMermaidParser.parse(
            'sequenceDiagram\n'
            '    participant A\n'
            '    participant B\n'
            '    A->>B: $message',
          ),
          theme: WbMarkdownTheme.light,
          maxWidth: 2000,
        );
      }

      final WbMermaidBox shortBox = layoutOf('ok');
      final WbMermaidBox longBox =
          layoutOf('这是一条很长的消息文本，明显超过两侧泳道的默认间距要求');
      // 文字过长时泳道间距被撑大 → 整体变宽（箭头长于文字）。
      expect(longBox.size.width, greaterThan(shortBox.size.width));
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      expect(() => longBox.draw(canvas), returnsNormally);
      recorder.endRecording().dispose();
    });
  });

  group('stateDiagram-v2', () {
    test('起止伪状态与带标签转换', () {
      final WbMermaidStateDiagram chart = WbMermaidParser.parse(
        'stateDiagram-v2\n'
        '    [*] --> Idle\n'
        '    Idle --> Running: start\n'
        '    Running --> [*]',
      ) as WbMermaidStateDiagram;
      expect(chart.states.length, 3);
      // `[*]` 起止共用同一伪状态（按 id 去重）。
      expect(
        chart.states.where((WbMermaidState s) => s.isPseudo).length,
        1,
      );
      expect(chart.transitions.length, 3);
      expect(chart.transitions[1].label, 'start');
    });

    test('命名状态与描述标签', () {
      final WbMermaidStateDiagram chart = WbMermaidParser.parse(
        'stateDiagram-v2\n'
        '    state "空闲状态" as Idle\n'
        '    Idle : 等待输入\n'
        '    Idle --> Busy : 点击',
      ) as WbMermaidStateDiagram;
      final WbMermaidState idle =
          chart.states.firstWhere((WbMermaidState s) => s.id == 'Idle');
      expect(idle.label, '空闲状态');
      expect(chart.transitions.single.label, '点击');
    });
  });

  group('erDiagram', () {
    test('实体属性与基数关系', () {
      final WbMermaidErDiagram chart = WbMermaidParser.parse(
        'erDiagram\n'
        '    CUSTOMER {\n'
        '        string name PK\n'
        '        string email\n'
        '    }\n'
        '    ORDER {\n'
        '        int id PK\n'
        '    }\n'
        '    CUSTOMER ||--o{ ORDER : places',
      ) as WbMermaidErDiagram;
      expect(chart.entities.length, 2);
      expect(chart.entities[0].attributes.length, 2);
      expect(chart.relations.length, 1);
      final WbMermaidErRelation relation = chart.relations.single;
      expect(relation.leftCard, '||');
      expect(relation.rightCard, 'o{');
      expect(relation.label, 'places');
      expect(relation.dashed, isFalse);
    });
  });

  group('容错语义（不抛出）', () {
    test('空图 / 未知类型 / 非法语句返回错误模型', () {
      final WbMermaidDiagram empty = WbMermaidParser.parse('');
      expect(empty, isA<WbMermaidError>());
      expect((empty as WbMermaidError).detail, contains('Empty'));

      final WbMermaidDiagram unknown = WbMermaidParser.parse('pie title X');
      expect(unknown, isA<WbMermaidError>());
      expect((unknown as WbMermaidError).detail, contains('Unsupported'));

      final WbMermaidDiagram syntax = WbMermaidParser.parse(
        'flowchart TD\n    ???',
      );
      expect(syntax, isA<WbMermaidError>());
      expect((syntax as WbMermaidError).line, 2);
    });

    test('各类图源码的非法变体均不抛出', () {
      const List<String> inputs = <String>[
        '%% 仅注释',
        'flowchart TD\n    A -->',
        'classDiagram\n    class',
        'sequenceDiagram\n    A ->> : 空目标',
        'stateDiagram-v2\n    ???',
        'erDiagram\n    ??? -- ??? : bad',
        'graph XYZ\n    A --> B',
      ];
      for (final String input in inputs) {
        expect(() => WbMermaidParser.parse(input), returnsNormally,
            reason: input);
        expect(WbMermaidParser.parse(input), isA<WbMermaidDiagram>(),
            reason: input);
      }
    });
  });

  group('布局与渲染烟雾', () {
    const String allDiagrams = '```mermaid\n'
        'flowchart TD\n'
        '    A[开始] --> B{判断}\n'
        '    B -->|是| C[结束]\n'
        '```\n\n'
        '```mermaid\n'
        'classDiagram\n'
        '    class Animal {\n'
        '        +String name\n'
        '    }\n'
        '    Animal <|-- Dog\n'
        '```\n\n'
        '```mermaid\n'
        'sequenceDiagram\n'
        '    participant A as Alice\n'
        '    A->>A: 自处理\n'
        '```\n\n'
        '```mermaid\n'
        'stateDiagram-v2\n'
        '    [*] --> Idle\n'
        '    Idle --> [*]\n'
        '```\n\n'
        '```mermaid\n'
        'erDiagram\n'
        '    CUSTOMER ||--o{ ORDER : places\n'
        '```';

    test('5 类图均可测量（高度 > 0）', () {
      final double height = WbMarkdownPainter.measureHeight(allDiagrams, 560);
      expect(height, greaterThan(0));
    });

    test('5 类图与错误卡片渲染不抛出', () {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      expect(
        () => WbMarkdownPainter.paint(
          canvas,
          const Rect.fromLTWH(0, 0, 560, 800),
          source: allDiagrams,
          theme: WbMarkdownTheme.light,
        ),
        returnsNormally,
      );
      expect(
        () => WbMarkdownPainter.paint(
          canvas,
          const Rect.fromLTWH(0, 0, 560, 320),
          source: '```mermaid\nbogus\n```',
          theme: WbMarkdownTheme.light,
        ),
        returnsNormally,
      );
      recorder.endRecording().dispose();
    });

    test('subgraph 复杂例（用户场景）可解析并渲染不抛', () {
      const String body = 'flowchart TB\n'
          '    subgraph 预览路径_新增\n'
          '        SP[StartCameraPreview] --> SC2[StartCameraCapture +1]\n'
          '        SC2 --> WCC[WebrtcCameraCapture]\n'
          '        WCC -->|AddOrUpdateSink| RVR2[RTCVideoRender PREVIEW]\n'
          '        RVR2 --> VFB[VideoFrameBuffer key=_1]\n'
          '    end\n'
          '    subgraph 发布路径_现有\n'
          '        PV[ProduceVideo] --> SC1[StartCameraCapture +1]\n'
          '        SC1 --> Track[CreateCameraTrack]\n'
          '        Track --> PR[Producer]\n'
          '        Track -->|AddOrUpdateSink| RVR1[RTCVideoRender VIDEO]\n'
          '        RVR1 --> VFB2[VideoFrameBuffer key=_0]\n'
          '    end\n'
          '    subgraph 共享层\n'
          '        MC[MediaCapture 单例]\n'
          '        MC --> RC[cameraRefCount]\n'
          '        MC --> WCC\n'
          '    end\n'
          '    SC1 --> MC\n'
          '    SC2 --> MC';
      final WbMermaidFlowchart chart =
          WbMermaidParser.parse(body) as WbMermaidFlowchart;
      expect(chart.nodes.length, 13);
      expect(chart.edges.length, 13);
      expect(chart.subgraphs.length, 3);
      expect(chart.subgraphs[0].nodeIds,
          <String>['SP', 'SC2', 'WCC', 'RVR2', 'VFB']);
      expect(chart.subgraphs[1].nodeIds,
          <String>['PV', 'SC1', 'Track', 'PR', 'RVR1', 'VFB2']);
      expect(chart.subgraphs[2].nodeIds, <String>['MC', 'RC']);

      const String source = '```mermaid\n$body\n```';
      final double height = WbMarkdownPainter.measureHeight(source, 560);
      expect(height, greaterThan(0));
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      expect(
        () => WbMarkdownPainter.paint(
          canvas,
          const Rect.fromLTWH(0, 0, 560, 1200),
          source: source,
          theme: WbMarkdownTheme.light,
        ),
        returnsNormally,
      );
      recorder.endRecording().dispose();
    });

    test('宽度变化触发图表重排', () {
      WbMarkdownRenderCache.clear();
      final double narrow = WbMarkdownPainter.measureHeight(allDiagrams, 320);
      final double wide = WbMarkdownPainter.measureHeight(allDiagrams, 720);
      expect(narrow, greaterThan(0));
      expect(wide, greaterThan(0));
    });
  });
}
