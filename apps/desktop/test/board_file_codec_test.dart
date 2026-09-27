/// 白板文件编解码（`.wbd`）：全元素类型 round-trip（12 种元素 + 6 类专业
/// 元素 payload + 图片 / 笔迹 / 透明色）与容错口径（坏 JSON / 缺字段 /
/// 未知枚举 / 类型不符 payload）。
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/services/board_file_codec.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';
import 'package:whiteboard_desktop/widgets/context_editors/flowchart_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/function_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/mindmap_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/render2d_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/render3d_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/table_editor.dart';

/// 全元素类型样品（两页：第一页含 11 个元素，第二页 1 个文本）。
WbBoardData _sampleBoard() {
  return const WbBoardData(
    boardId: 'board-1',
    boardName: '测试白板',
    currentPageId: 'page-2',
    pages: <WbBoardPageData>[
      WbBoardPageData(
        id: 'page-1',
        name: '页面 1',
        locked: true,
        background: <String, dynamic>{'id': 'light-gray', 'opacity': 0.5},
        elements: <WbCanvasElement>[
          WbCanvasElement(
            id: 'el-note',
            type: WbElementKind.note,
            x: 10.5,
            y: -20,
            width: 120,
            height: 80,
            zIndex: 3,
            text: '便签内容',
            color: 0x80112233,
            fontSize: 14,
            textAlign: WbTextAlignId.center,
            name: '备注',
            visible: false,
          ),
          WbCanvasElement(
            id: 'el-shape',
            type: WbElementKind.shape,
            x: 0,
            y: 0,
            width: 90,
            height: 60,
            strokeWidth: 4,
            shapeKind: WbShapeKindId.diamond,
            locked: true,
          ),
          WbCanvasElement(
            id: 'el-draw',
            type: WbElementKind.drawing,
            x: 5,
            y: 6,
            width: 50,
            height: 40,
            points: <Offset>[Offset(1, 2), Offset(3.5, 4.25)],
          ),
          WbCanvasElement(
            id: 'el-conn',
            type: WbElementKind.connector,
            x: 1,
            y: 2,
            width: 100,
            height: 80,
            points: <Offset>[Offset(1, 2), Offset(101, 82)],
          ),
          WbCanvasElement(
            id: 'el-image',
            type: WbElementKind.image,
            x: 8,
            y: 9,
            width: 200,
            height: 150,
            payload: <String, dynamic>{
              'src': r'C:\img\photo.png',
              'fit': 'contain',
            },
          ),
          WbCanvasElement(
            id: 'el-flow',
            type: WbElementKind.flowchart,
            x: 0,
            y: 0,
            width: 300,
            height: 200,
            payload: WbFlowchartModel(
              nodes: <WbFlowNode>[
                WbFlowNode(
                  id: 'n1',
                  x: 0,
                  y: 0,
                  type: WbFlowNodeType.start,
                  text: '开始',
                ),
                WbFlowNode(
                  id: 'n2',
                  x: 0,
                  y: 80,
                  type: WbFlowNodeType.decision,
                  text: '条件',
                  laneId: 'lane-1',
                ),
              ],
              connectors: <WbFlowConnector>[
                WbFlowConnector(id: 'c1', fromId: 'n1', toId: 'n2', label: '是'),
              ],
              lanes: <WbFlowLane>[
                WbFlowLane(
                  id: 'lane-1',
                  name: '泳道',
                  orientation: WbSwimlaneOrientation.horizontal,
                ),
              ],
              direction: WbFlowLayoutDirection.leftToRight,
              templateId: 'sample-template',
            ),
          ),
          WbCanvasElement(
            id: 'el-table',
            type: WbElementKind.table,
            x: 0,
            y: 0,
            width: 260,
            height: 160,
            payload: WbTableModel(
              cells: <List<String>>[
                <String>['项目', '状态'],
                <String>['评审', '进行中'],
              ],
              style: WbTableStyle(
                zebraStripes: true,
                headerBackground: Color(0xFF2233AA),
                align: WbTableAlign.center,
              ),
            ),
          ),
          WbCanvasElement(
            id: 'el-mind',
            type: WbElementKind.mindmap,
            x: 0,
            y: 0,
            width: 320,
            height: 180,
            payload: WbMindNode(
              id: 'root',
              text: '中心',
              children: <WbMindNode>[
                WbMindNode(id: 'm1', text: '分支 1', collapsed: true),
                WbMindNode(
                  id: 'm2',
                  text: '分支 2',
                  children: <WbMindNode>[
                    WbMindNode(id: 'm2a', text: '子节点'),
                  ],
                ),
              ],
            ),
          ),
          WbCanvasElement(
            id: 'el-func',
            type: WbElementKind.function,
            x: 0,
            y: 0,
            width: 300,
            height: 200,
            payload: WbFunctionScene(
              curves: <WbCurve>[
                WbCurve(
                  id: 'cv1',
                  expression: 'sin(x) + 0.5 * x',
                  color: Color(0xFFEE5511),
                  visible: false,
                ),
              ],
              domainMin: -3,
              domainMax: 3,
              samples: 120,
            ),
          ),
          WbCanvasElement(
            id: 'el-3d',
            type: WbElementKind.render3d,
            x: 0,
            y: 0,
            width: 220,
            height: 220,
            payload: Wb3dScene(
              objectType: Wb3dObjectType.sphere,
              material: Wb3dMaterial.metal,
              color: Color(0xFF88AACC),
              transform: Wb3dTransform(
                rotationX: 15,
                rotationY: 30,
                rotationZ: 45,
                scale: 1.5,
                lift: 20,
              ),
              lightType: Wb3dLightType.spot,
              ambient: 0.5,
              lightIntensity: 1.2,
              wireframe: true,
              faceColors: <int, Color>{3: Color(0xFF112233)},
            ),
          ),
          WbCanvasElement(
            id: 'el-2d',
            type: WbElementKind.render2d,
            x: 0,
            y: 0,
            width: 160,
            height: 160,
            payload: WbRender2dScene(
              primitive: WbRender2dPrimitive.star,
              count: 7,
              thickness: 3.5,
              filled: true,
              color: Color(0xFF00AA88),
            ),
          ),
        ],
      ),
      WbBoardPageData(
        id: 'page-2',
        name: '页面 2',
        hidden: true,
        elements: <WbCanvasElement>[
          WbCanvasElement(
            id: 'el-text',
            type: WbElementKind.text,
            x: 1,
            y: 1,
            width: 120,
            height: 40,
            text: '标题',
            fontSize: 24,
          ),
        ],
      ),
    ],
  );
}

WbCanvasElement _elementOf(WbBoardPageData page, String id) =>
    page.elements.firstWhere((WbCanvasElement e) => e.id == id);

void main() {
  final DateTime savedAt = DateTime.utc(2026, 1, 2, 3, 4, 5);

  test('全元素类型 round-trip：decode 后重编码文本一致', () {
    final WbBoardData data = _sampleBoard();
    final String text = WbBoardFileCodec.encode(data, savedAt: savedAt);
    final WbBoardData decoded = WbBoardFileCodec.decode(text);
    expect(WbBoardFileCodec.encode(decoded, savedAt: savedAt), text);
  });

  test('字段级断言：基础字段 / 透明色 / 笔迹点 / 专业 payload', () {
    final WbBoardData decoded = WbBoardFileCodec.decode(
      WbBoardFileCodec.encode(_sampleBoard(), savedAt: savedAt),
    );
    expect(decoded.boardId, 'board-1');
    expect(decoded.boardName, '测试白板');
    expect(decoded.currentPageId, 'page-2');
    expect(decoded.pages.length, 2);

    final WbBoardPageData page1 = decoded.pages[0];
    expect(page1.name, '页面 1');
    expect(page1.locked, isTrue);
    expect(page1.hidden, isFalse);
    expect(page1.background, <String, dynamic>{
      'id': 'light-gray',
      'opacity': 0.5,
    });
    expect(page1.elements.length, 11);

    final WbCanvasElement note = _elementOf(page1, 'el-note');
    expect(note.x, 10.5);
    expect(note.y, -20);
    expect(note.width, 120);
    expect(note.height, 80);
    expect(note.zIndex, 3);
    expect(note.text, '便签内容');
    expect(note.color, 0x80112233); // 透明色 alpha 保留
    expect(note.fontSize, 14);
    expect(note.textAlign, WbTextAlignId.center);
    expect(note.name, '备注');
    expect(note.visible, isFalse);

    final WbCanvasElement shape = _elementOf(page1, 'el-shape');
    expect(shape.shapeKind, WbShapeKindId.diamond);
    expect(shape.strokeWidth, 4);
    expect(shape.locked, isTrue);

    final WbCanvasElement draw = _elementOf(page1, 'el-draw');
    expect(
      draw.points,
      const <Offset>[Offset(1, 2), Offset(3.5, 4.25)],
    );
    final WbCanvasElement conn = _elementOf(page1, 'el-conn');
    expect(conn.points.length, 2);

    final WbCanvasElement image = _elementOf(page1, 'el-image');
    expect(image.payload, <String, dynamic>{
      'src': r'C:\img\photo.png',
      'fit': 'contain',
    });

    final WbFlowchartModel flow =
        _elementOf(page1, 'el-flow').payload! as WbFlowchartModel;
    expect(flow.nodes.length, 2);
    expect(flow.nodes[0].type, WbFlowNodeType.start);
    expect(flow.nodes[1].type, WbFlowNodeType.decision);
    expect(flow.nodes[1].laneId, 'lane-1');
    expect(flow.connectors.single.label, '是');
    expect(flow.lanes.single.orientation, WbSwimlaneOrientation.horizontal);
    expect(flow.direction, WbFlowLayoutDirection.leftToRight);
    expect(flow.templateId, 'sample-template');

    final WbTableModel table =
        _elementOf(page1, 'el-table').payload! as WbTableModel;
    expect(table.cells[0], <String>['项目', '状态']);
    expect(table.style.zebraStripes, isTrue);
    expect(table.style.headerBackground, const Color(0xFF2233AA));
    expect(table.style.align, WbTableAlign.center);

    final WbMindNode mind =
        _elementOf(page1, 'el-mind').payload! as WbMindNode;
    expect(mind.children[0].collapsed, isTrue);
    expect(mind.children[1].children.single.text, '子节点');

    final WbFunctionScene function =
        _elementOf(page1, 'el-func').payload! as WbFunctionScene;
    expect(function.curves.single.expression, 'sin(x) + 0.5 * x');
    expect(function.curves.single.color, const Color(0xFFEE5511));
    expect(function.curves.single.visible, isFalse);
    expect(function.domainMin, -3);
    expect(function.samples, 120);

    final Wb3dScene scene3d =
        _elementOf(page1, 'el-3d').payload! as Wb3dScene;
    expect(scene3d.objectType, Wb3dObjectType.sphere);
    expect(scene3d.material, Wb3dMaterial.metal);
    expect(scene3d.transform.rotationY, 30);
    expect(scene3d.transform.scale, 1.5);
    expect(scene3d.lightType, Wb3dLightType.spot);
    expect(scene3d.ambient, 0.5);
    expect(scene3d.wireframe, isTrue);
    expect(scene3d.faceColors[3], const Color(0xFF112233));

    final WbRender2dScene scene2d =
        _elementOf(page1, 'el-2d').payload! as WbRender2dScene;
    expect(scene2d.primitive, WbRender2dPrimitive.star);
    expect(scene2d.count, 7);
    expect(scene2d.thickness, 3.5);
    expect(scene2d.filled, isTrue);

    expect(decoded.pages[1].hidden, isTrue);
    expect(_elementOf(decoded.pages[1], 'el-text').text, '标题');
  });

  group('容错口径', () {
    test('坏 JSON / 非对象 / 非白板 / 版本过新 / 无页面 → FormatException', () {
      expect(
        () => WbBoardFileCodec.decode('not-json'),
        throwsFormatException,
      );
      expect(() => WbBoardFileCodec.decode('[1, 2]'), throwsFormatException);
      expect(
        () => WbBoardFileCodec.decode('{"format":"other","version":1}'),
        throwsFormatException,
      );
      expect(
        () => WbBoardFileCodec.decode(
          '{"format":"whiteboard-board","version":99,"pages":[{"id":"p"}]}',
        ),
        throwsFormatException,
      );
      expect(
        () => WbBoardFileCodec.decode(
          '{"format":"whiteboard-board","version":1,"pages":[]}',
        ),
        throwsFormatException,
      );
    });

    test('字段缺失 / 未知字段 / 未知枚举 / 坏 payload：取默认不抛', () {
      const String source = '''
{
  "format": "whiteboard-board",
  "version": 1,
  "futureField": true,
  "board": {"id": "b1"},
  "currentPageId": "missing-page",
  "pages": [
    {"id": "p1", "futureField2": 1, "elements": [
      {"id": "e1", "type": "note", "extra": {"a": 1}},
      {"id": "e2", "type": "shape", "shapeKind": "no-such",
       "textAlign": "no-such", "color": "###", "strokeWidth": "bad",
       "position": {"x": 5, "y": 6},
       "size": {"width": 30, "height": "bad"}},
      {"type": "note", "x": 1},
      {"id": "e4", "type": "flowchart",
       "payload": {"nodes": [{"id": "n1", "type": "no-such"}],
                   "connectors": [{"fromId": "n1"}],
                   "direction": "no-such"}},
      {"id": "e5", "type": "table", "payload": "not-a-map"},
      {"id": "e6", "type": "image", "payload": 42}
    ]}
  ]
}
''';
      final WbBoardData data = WbBoardFileCodec.decode(source);
      expect(data.boardId, 'b1');
      expect(data.boardName, '');
      expect(data.currentPageId, 'p1'); // 无效 currentPageId 回退第一页

      final WbBoardPageData page = data.pages.single;
      expect(page.elements.length, 5); // 缺 id 的元素被丢弃

      final WbCanvasElement e1 = page.elements[0];
      expect(e1.width, 120); // 尺寸缺省
      expect(e1.height, 80);
      expect(e1.color, 0xFF3370FF); // 颜色缺省
      expect(e1.visible, isTrue);
      expect(e1.payload, isNull);

      final WbCanvasElement e2 = page.elements[1];
      expect(e2.x, 5);
      expect(e2.y, 6);
      expect(e2.width, 30);
      expect(e2.height, 80); // 坏 height 回退缺省
      expect(e2.shapeKind, 'no-such'); // 元素级枚举 id 原样保留（渲染层兜底）
      expect(e2.textAlign, 'no-such');
      expect(e2.strokeWidth, 2);
      expect(e2.color, 0xFF3370FF); // 坏色值回退

      final WbFlowchartModel flow =
          page.elements[2].payload! as WbFlowchartModel;
      expect(flow.nodes.single.type, WbFlowNodeType.process); // 未知枚举回退
      expect(flow.connectors, isEmpty); // 缺 id 的连线被丢弃
      expect(flow.direction, WbFlowLayoutDirection.topToBottom);

      expect(page.elements[3].payload, isNull); // 类型不符 payload
      expect(page.elements[4].payload, isNull);
    });

    test('encodePayload / decodePayload：枚举稳定 id 往返、类型不符返回 null', () {
      final Object? encoded = WbBoardFileCodec.encodePayload(
        WbElementKind.flowchart,
        const WbFlowchartModel(
          nodes: <WbFlowNode>[
            WbFlowNode(id: 'n1', x: 1, y: 2, type: WbFlowNodeType.inputOutput),
          ],
        ),
      );
      expect(encoded, isA<Map<String, dynamic>>());
      final Object? decoded =
          WbBoardFileCodec.decodePayload(WbElementKind.flowchart, encoded);
      expect(
        (decoded! as WbFlowchartModel).nodes.single.type,
        WbFlowNodeType.inputOutput,
      );

      // 未知类型：Map 原样 / 非 Map 返回 null。
      expect(
        WbBoardFileCodec.encodePayload('custom-type', <String, dynamic>{
          'k': 1,
        }),
        <String, dynamic>{'k': 1},
      );
      expect(WbBoardFileCodec.encodePayload('custom-type', 'raw'), isNull);
      expect(WbBoardFileCodec.encodePayload(WbElementKind.table, 'raw'), isNull);
      expect(WbBoardFileCodec.decodePayload(WbElementKind.table, null), isNull);
      expect(
        WbBoardFileCodec.decodePayload('custom-type', <String, dynamic>{
          'k': 1,
        }),
        <String, dynamic>{'k': 1},
      );
    });
  });
}
