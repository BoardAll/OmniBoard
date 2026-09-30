/// 白板文件编解码（`.wbd`：UTF-8 JSON 信封）。
///
/// 信封形状：
/// ```json
/// { "format": "whiteboard-board", "version": 1, "savedAt": "ISO8601",
///   "board": {"id": "...", "name": "..."}, "currentPageId": "...",
///   "pages": [{ "id", "name", "locked", "hidden", "background": {...},
///     "elements": [ { ...WbCanvasElement.toJson() 原样..., "payload": {...} } ] }] }
/// ```
///
/// 元素的基础字段复用 [WbCanvasElement.toJson]（契约形状）；专业元素
/// payload（6 种结构模型 + 图片 Map）由本文件实现 toJson / fromJson
/// （写在编解码层而非各编辑器，避免大文件改动）。
///
/// 容错口径：坏 JSON / 非白板文件 / 版本过新抛 [FormatException]；
/// 字段缺失取默认值；未知字段忽略（向前兼容）。
library;

import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../widgets/canvas/canvas_model.dart';
import '../widgets/context_editors/context_editor_shell.dart';
import '../widgets/context_editors/flowchart_editor.dart';
import '../widgets/context_editors/function_editor.dart';
import '../widgets/context_editors/mindmap_editor.dart';
import '../widgets/context_editors/render2d_editor.dart';
import '../widgets/context_editors/render3d_editor.dart';
import '../widgets/context_editors/table_editor.dart';

/// 白板文档数据（文件编解码的中转结构，与 UI 状态解耦）。
class WbBoardData {
  const WbBoardData({
    this.boardId = '',
    this.boardName = '',
    this.currentPageId = '',
    this.pages = const <WbBoardPageData>[],
  });

  /// 白板 id。
  final String boardId;

  /// 白板名（另存为建议文件名来源）。
  final String boardName;

  /// 当前页 id（空串 = 取第一页）。
  final String currentPageId;

  /// 页面列表（顺序即页序）。
  final List<WbBoardPageData> pages;
}

/// 白板页面数据。
class WbBoardPageData {
  const WbBoardPageData({
    required this.id,
    this.name = '',
    this.locked = false,
    this.hidden = false,
    this.background,
    this.elements = const <WbCanvasElement>[],
  });

  /// 页面 id。
  final String id;

  /// 页面名。
  final String name;

  /// 是否锁定。
  final bool locked;

  /// 是否隐藏。
  final bool hidden;

  /// 背景 JSON（对齐 background 域存储形态；null = 未设置）。
  final Map<String, dynamic>? background;

  /// 页面元素（列表顺序即 z 序）。
  final List<WbCanvasElement> elements;
}

/// `.wbd` 文件编解码。
abstract final class WbBoardFileCodec {
  /// 信封格式标识。
  static const String formatId = 'whiteboard-board';

  /// 当前文件格式版本。
  static const int fileVersion = 1;

  /// 编码为 `.wbd` 文本（缩进 JSON，可调试优先）。
  static String encode(WbBoardData data, {DateTime? savedAt}) {
    final Map<String, dynamic> json = <String, dynamic>{
      'format': formatId,
      'version': fileVersion,
      'savedAt': (savedAt ?? DateTime.now()).toIso8601String(),
      'board': <String, dynamic>{'id': data.boardId, 'name': data.boardName},
      'currentPageId': data.currentPageId,
      'pages': <Map<String, dynamic>>[
        for (final WbBoardPageData page in data.pages) _encodePage(page),
      ],
    };
    return const JsonEncoder.withIndent('  ').convert(json);
  }

  /// 从 `.wbd` 文本解码。
  ///
  /// 坏 JSON / 非白板文件 / 版本过新抛 [FormatException]。
  static WbBoardData decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const FormatException('文件不是合法 JSON（可能已损坏）');
    }
    if (decoded is! Map) {
      throw const FormatException('白板文件缺少顶层对象');
    }
    final Map<String, dynamic> json = Map<String, dynamic>.from(decoded);
    if (json['format'] != formatId) {
      throw const FormatException('不是白板文件（format 标识不匹配）');
    }
    final int version = json['version'] is num
        ? (json['version'] as num).round()
        : fileVersion;
    if (version > fileVersion) {
      throw FormatException('白板文件版本过新（v$version），请升级应用后再打开');
    }

    final Map<String, dynamic> board = json['board'] is Map
        ? Map<String, dynamic>.from(json['board'] as Map)
        : const <String, dynamic>{};

    final List<WbBoardPageData> pages = <WbBoardPageData>[];
    final Object? rawPages = json['pages'];
    if (rawPages is List) {
      for (final Object? item in rawPages) {
        if (item is Map) {
          final WbBoardPageData page =
              _decodePage(Map<String, dynamic>.from(item));
          if (page.id.isNotEmpty) {
            pages.add(page);
          }
        }
      }
    }
    if (pages.isEmpty) {
      throw const FormatException('白板文件不含任何页面');
    }

    String currentPageId =
        json['currentPageId'] is String ? json['currentPageId'] as String : '';
    if (!pages.any((WbBoardPageData page) => page.id == currentPageId)) {
      currentPageId = pages.first.id;
    }

    return WbBoardData(
      boardId: board['id'] is String ? board['id'] as String : '',
      boardName: board['name'] is String ? board['name'] as String : '',
      currentPageId: currentPageId,
      pages: pages,
    );
  }

  // ---------------------------------------------------------------------------
  // 页面 / 元素
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _encodePage(WbBoardPageData page) {
    return <String, dynamic>{
      'id': page.id,
      'name': page.name,
      'locked': page.locked,
      'hidden': page.hidden,
      'background': page.background,
      'elements': <Map<String, dynamic>>[
        for (final WbCanvasElement element in page.elements)
          encodeElement(element),
      ],
    };
  }

  static WbBoardPageData _decodePage(Map<String, dynamic> json) {
    final List<WbCanvasElement> elements = <WbCanvasElement>[];
    final Object? rawElements = json['elements'];
    if (rawElements is List) {
      for (final Object? item in rawElements) {
        if (item is Map) {
          final WbCanvasElement element =
              decodeElement(Map<String, dynamic>.from(item));
          if (element.id.isNotEmpty) {
            elements.add(element);
          }
        }
      }
    }
    return WbBoardPageData(
      id: json['id'] is String ? json['id'] as String : '',
      name: json['name'] is String ? json['name'] as String : '',
      locked: json['locked'] is bool ? json['locked'] as bool : false,
      hidden: json['hidden'] is bool ? json['hidden'] as bool : false,
      background: json['background'] is Map
          ? Map<String, dynamic>.from(json['background'] as Map)
          : null,
      elements: elements,
    );
  }

  static Map<String, dynamic> encodeElement(WbCanvasElement element) {
    final Map<String, dynamic> json = element.toJson();
    final Object? payload = element.payload;
    if (payload != null) {
      final Object? encoded = encodePayload(element.type, payload);
      if (encoded != null) {
        json['payload'] = encoded;
      }
    }
    return json;
  }

  static WbCanvasElement decodeElement(Map<String, dynamic> json) {
    double readDouble(Object? value, double fallback) =>
        value is num ? value.toDouble() : fallback;
    String readString(Object? value, String fallback) =>
        value is String ? value : fallback;

    final Map<String, dynamic> position = json['position'] is Map
        ? Map<String, dynamic>.from(json['position'] as Map)
        : const <String, dynamic>{};
    final Map<String, dynamic> size = json['size'] is Map
        ? Map<String, dynamic>.from(json['size'] as Map)
        : const <String, dynamic>{};

    final Color color = json['color'] is String &&
            (json['color'] as String).isNotEmpty
        ? WbColorUtils.fromHex(
            json['color'] as String,
            fallback: const Color(0xFF3370FF),
          )
        : const Color(0xFF3370FF);

    final List<Offset> points = <Offset>[];
    final Object? rawPoints = json['points'];
    if (rawPoints is List) {
      for (final Object? item in rawPoints) {
        if (item is Map) {
          points.add(Offset(
            readDouble(item['x'], 0),
            readDouble(item['y'], 0),
          ));
        }
      }
    }

    final String type = readString(json['type'], WbElementKind.note);
    return WbCanvasElement(
      id: readString(json['id'], ''),
      type: type,
      x: readDouble(position['x'], 0),
      y: readDouble(position['y'], 0),
      width: readDouble(size['width'], 120),
      height: readDouble(size['height'], 80),
      zIndex: json['zIndex'] is num ? (json['zIndex'] as num).round() : 0,
      text: readString(json['text'], ''),
      color: color.toARGB32(),
      strokeWidth: readDouble(json['strokeWidth'], 2),
      shapeKind: readString(json['shapeKind'], WbShapeKindId.rect),
      points: points,
      fontSize: readDouble(json['fontSize'], 0),
      textAlign: readString(json['textAlign'], WbTextAlignId.left),
      payload: decodePayload(type, json['payload']),
      name: readString(json['name'], ''),
      visible: json['visible'] is bool ? json['visible'] as bool : true,
      locked: json['locked'] is bool ? json['locked'] as bool : false,
    );
  }

  // ---------------------------------------------------------------------------
  // payload 编解码（按元素类型分发）
  // ---------------------------------------------------------------------------

  /// 编码专业元素 payload（未知类型：Map 原样 / 其它返回 null 不写入）。
  static Object? encodePayload(String type, Object payload) {
    switch (type) {
      case WbElementKind.image:
        return payload is Map ? Map<String, dynamic>.from(payload) : null;
      case WbElementKind.flowchart:
        return payload is WbFlowchartModel
            ? _flowchartToJson(payload)
            : null;
      case WbElementKind.table:
        return payload is WbTableModel ? _tableToJson(payload) : null;
      case WbElementKind.mindmap:
        return payload is WbMindNode ? _mindToJson(payload) : null;
      case WbElementKind.function:
        return payload is WbFunctionScene ? _functionToJson(payload) : null;
      case WbElementKind.render3d:
        return payload is Wb3dScene ? _render3dToJson(payload) : null;
      case WbElementKind.render2d:
        return payload is WbRender2dScene ? _render2dToJson(payload) : null;
      default:
        return payload is Map ? Map<String, dynamic>.from(payload) : null;
    }
  }

  /// 解码专业元素 payload（格式不符返回 null，渲染层按占位处理）。
  static Object? decodePayload(String type, Object? raw) {
    if (type == WbElementKind.image) {
      return raw is Map ? Map<String, dynamic>.from(raw) : null;
    }
    if (raw is! Map) {
      return null;
    }
    final Map<String, dynamic> json = Map<String, dynamic>.from(raw);
    switch (type) {
      case WbElementKind.flowchart:
        return _flowchartFromJson(json);
      case WbElementKind.table:
        return _tableFromJson(json);
      case WbElementKind.mindmap:
        return _mindFromJson(json);
      case WbElementKind.function:
        return _functionFromJson(json);
      case WbElementKind.render3d:
        return _render3dFromJson(json);
      case WbElementKind.render2d:
        return _render2dFromJson(json);
      default:
        return json;
    }
  }

  // ---------------------------------------------------------------------------
  // 通用读取helpers
  // ---------------------------------------------------------------------------

  static double _double(Object? value, double fallback) =>
      value is num ? value.toDouble() : fallback;

  static int _int(Object? value, int fallback) =>
      value is num ? value.round() : fallback;

  static String _string(Object? value, String fallback) =>
      value is String ? value : fallback;

  static bool _bool(Object? value, bool fallback) =>
      value is bool ? value : fallback;

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  /// 颜色 hex 编码（含 alpha）。
  static String _colorToHex(Color color) =>
      WbColorUtils.toHex(color, withAlpha: true);

  /// 颜色 hex 解码（坏串回退 [fallback]）。
  static Color _colorFrom(Object? value, Color fallback) =>
      value is String && value.isNotEmpty
          ? WbColorUtils.fromHex(value, fallback: fallback)
          : fallback;

  /// 按稳定 id 查找枚举（未知回退 [fallback]）。
  static T _enumById<T>(
    List<T> values,
    String Function(T value) idOf,
    Object? raw,
    T fallback,
  ) {
    if (raw is String) {
      for (final T value in values) {
        if (idOf(value) == raw) {
          return value;
        }
      }
    }
    return fallback;
  }

  // ---------------------------------------------------------------------------
  // 流程图
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _flowchartToJson(WbFlowchartModel model) {
    return <String, dynamic>{
      'direction': model.direction.id,
      'templateId': model.templateId,
      'nodes': <Map<String, dynamic>>[
        for (final WbFlowNode node in model.nodes)
          <String, dynamic>{
            'id': node.id,
            'x': node.x,
            'y': node.y,
            'type': node.type.id,
            'text': node.text,
            'width': node.width,
            'height': node.height,
            'laneId': node.laneId,
          },
      ],
      'connectors': <Map<String, dynamic>>[
        for (final WbFlowConnector c in model.connectors)
          <String, dynamic>{
            'id': c.id,
            'fromId': c.fromId,
            'toId': c.toId,
            'label': c.label,
          },
      ],
      'lanes': <Map<String, dynamic>>[
        for (final WbFlowLane lane in model.lanes)
          <String, dynamic>{
            'id': lane.id,
            'name': lane.name,
            'orientation': lane.orientation.id,
          },
      ],
    };
  }

  static WbFlowchartModel _flowchartFromJson(Map<String, dynamic> json) {
    final List<WbFlowNode> nodes = <WbFlowNode>[];
    final Object? rawNodes = json['nodes'];
    if (rawNodes is List) {
      for (final Object? item in rawNodes) {
        if (item is! Map) {
          continue;
        }
        final Map<String, dynamic> node = Map<String, dynamic>.from(item);
        final String id = _string(node['id'], '');
        if (id.isEmpty) {
          continue;
        }
        nodes.add(WbFlowNode(
          id: id,
          x: _double(node['x'], 0),
          y: _double(node['y'], 0),
          type: _enumById(
            WbFlowNodeType.values,
            (WbFlowNodeType value) => value.id,
            node['type'],
            WbFlowNodeType.process,
          ),
          text: _string(node['text'], ''),
          width: _double(node['width'], 120),
          height: _double(node['height'], 52),
          laneId: node['laneId'] is String ? node['laneId'] as String : null,
        ));
      }
    }

    final List<WbFlowConnector> connectors = <WbFlowConnector>[];
    final Object? rawConnectors = json['connectors'];
    if (rawConnectors is List) {
      for (final Object? item in rawConnectors) {
        if (item is! Map) {
          continue;
        }
        final Map<String, dynamic> c = Map<String, dynamic>.from(item);
        final String id = _string(c['id'], '');
        if (id.isEmpty) {
          continue;
        }
        connectors.add(WbFlowConnector(
          id: id,
          fromId: _string(c['fromId'], ''),
          toId: _string(c['toId'], ''),
          label: _string(c['label'], ''),
        ));
      }
    }

    final List<WbFlowLane> lanes = <WbFlowLane>[];
    final Object? rawLanes = json['lanes'];
    if (rawLanes is List) {
      for (final Object? item in rawLanes) {
        if (item is! Map) {
          continue;
        }
        final Map<String, dynamic> lane = Map<String, dynamic>.from(item);
        final String id = _string(lane['id'], '');
        if (id.isEmpty) {
          continue;
        }
        lanes.add(WbFlowLane(
          id: id,
          name: _string(lane['name'], ''),
          orientation: _enumById(
            WbSwimlaneOrientation.values,
            (WbSwimlaneOrientation value) => value.id,
            lane['orientation'],
            WbSwimlaneOrientation.vertical,
          ),
        ));
      }
    }

    return WbFlowchartModel(
      nodes: nodes,
      connectors: connectors,
      lanes: lanes,
      direction: _enumById(
        WbFlowLayoutDirection.values,
        (WbFlowLayoutDirection value) => value.id,
        json['direction'],
        WbFlowLayoutDirection.topToBottom,
      ),
      templateId:
          json['templateId'] is String ? json['templateId'] as String : null,
    );
  }

  // ---------------------------------------------------------------------------
  // 表格
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _tableToJson(WbTableModel model) {
    return <String, dynamic>{
      'cells': <List<String>>[
        for (final List<String> row in model.cells) List<String>.of(row),
      ],
      'style': <String, dynamic>{
        'headerBold': model.style.headerBold,
        'showBorders': model.style.showBorders,
        'zebraStripes': model.style.zebraStripes,
        'headerBackground': _colorToHex(model.style.headerBackground),
        'align': model.style.align.id,
      },
    };
  }

  static WbTableModel _tableFromJson(Map<String, dynamic> json) {
    final List<List<String>> cells = <List<String>>[];
    final Object? rawCells = json['cells'];
    if (rawCells is List) {
      for (final Object? row in rawCells) {
        if (row is List) {
          cells.add(<String>[
            for (final Object? cell in row)
              cell is String ? cell : (cell == null ? '' : '$cell'),
          ]);
        }
      }
    }
    final Map<String, dynamic> style = _map(json['style']);
    return WbTableModel(
      cells: cells,
      style: WbTableStyle(
        headerBold: _bool(style['headerBold'], true),
        showBorders: _bool(style['showBorders'], true),
        zebraStripes: _bool(style['zebraStripes'], false),
        headerBackground:
            _colorFrom(style['headerBackground'], const Color(0xFFEAF1FF)),
        align: _enumById(
          WbTableAlign.values,
          (WbTableAlign value) => value.id,
          style['align'],
          WbTableAlign.left,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 思维导图
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _mindToJson(WbMindNode node) {
    return <String, dynamic>{
      'id': node.id,
      'text': node.text,
      'collapsed': node.collapsed,
      'children': <Map<String, dynamic>>[
        for (final WbMindNode child in node.children) _mindToJson(child),
      ],
    };
  }

  static WbMindNode _mindFromJson(Map<String, dynamic> json) {
    final List<WbMindNode> children = <WbMindNode>[];
    final Object? rawChildren = json['children'];
    if (rawChildren is List) {
      for (final Object? item in rawChildren) {
        if (item is Map) {
          children.add(_mindFromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return WbMindNode(
      id: _string(json['id'], ''),
      text: _string(json['text'], ''),
      children: children,
      collapsed: _bool(json['collapsed'], false),
    );
  }

  // ---------------------------------------------------------------------------
  // 函数图像
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _functionToJson(WbFunctionScene scene) {
    return <String, dynamic>{
      'domainMin': scene.domainMin,
      'domainMax': scene.domainMax,
      'samples': scene.samples,
      'curves': <Map<String, dynamic>>[
        for (final WbCurve curve in scene.curves)
          <String, dynamic>{
            'id': curve.id,
            'expression': curve.expression,
            'color': _colorToHex(curve.color),
            'visible': curve.visible,
          },
      ],
    };
  }

  static WbFunctionScene _functionFromJson(Map<String, dynamic> json) {
    final List<WbCurve> curves = <WbCurve>[];
    final Object? rawCurves = json['curves'];
    if (rawCurves is List) {
      for (final Object? item in rawCurves) {
        if (item is! Map) {
          continue;
        }
        final Map<String, dynamic> curve = Map<String, dynamic>.from(item);
        curves.add(WbCurve(
          id: _string(curve['id'], ''),
          expression: _string(curve['expression'], ''),
          color: _colorFrom(
            curve['color'],
            WbContextPalette.curveSwatches[0],
          ),
          visible: _bool(curve['visible'], true),
        ));
      }
    }
    return WbFunctionScene(
      curves: curves,
      domainMin: _double(json['domainMin'], -6),
      domainMax: _double(json['domainMax'], 6),
      samples: _int(json['samples'], 240),
    );
  }

  // ---------------------------------------------------------------------------
  // 3D 对象
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _render3dToJson(Wb3dScene scene) {
    return <String, dynamic>{
      'objectType': scene.objectType.id,
      'material': scene.material.id,
      'color': _colorToHex(scene.color),
      'transform': <String, dynamic>{
        'rotationX': scene.transform.rotationX,
        'rotationY': scene.transform.rotationY,
        'rotationZ': scene.transform.rotationZ,
        'scale': scene.transform.scale,
        'lift': scene.transform.lift,
      },
      'lightType': scene.lightType.id,
      'ambient': scene.ambient,
      'lightIntensity': scene.lightIntensity,
      'wireframe': scene.wireframe,
      'faceColors': <String, dynamic>{
        for (final MapEntry<int, Color> entry in scene.faceColors.entries)
          '${entry.key}': _colorToHex(entry.value),
      },
    };
  }

  static Wb3dScene _render3dFromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> transform = _map(json['transform']);
    final Map<int, Color> faceColors = <int, Color>{};
    final Map<String, dynamic> rawFaceColors = _map(json['faceColors']);
    for (final MapEntry<String, dynamic> entry in rawFaceColors.entries) {
      final int? faceIndex = int.tryParse(entry.key);
      if (faceIndex != null && entry.value is String) {
        faceColors[faceIndex] = _colorFrom(
          entry.value,
          const Color(0xFF3370FF),
        );
      }
    }
    return Wb3dScene(
      objectType: _enumById(
        Wb3dObjectType.values,
        (Wb3dObjectType value) => value.id,
        json['objectType'],
        Wb3dObjectType.box,
      ),
      material: _enumById(
        Wb3dMaterial.values,
        (Wb3dMaterial value) => value.id,
        json['material'],
        Wb3dMaterial.standard,
      ),
      color: _colorFrom(json['color'], WbContextPalette.defaultElementColor),
      transform: Wb3dTransform(
        rotationX: _double(transform['rotationX'], 0),
        rotationY: _double(transform['rotationY'], 0),
        rotationZ: _double(transform['rotationZ'], 0),
        scale: _double(transform['scale'], 1),
        lift: _double(transform['lift'], 0),
      ),
      lightType: _enumById(
        Wb3dLightType.values,
        (Wb3dLightType value) => value.id,
        json['lightType'],
        Wb3dLightType.directional,
      ),
      ambient: _double(json['ambient'], 0.32),
      lightIntensity: _double(json['lightIntensity'], 0.9),
      wireframe: _bool(json['wireframe'], false),
      faceColors: faceColors,
    );
  }

  // ---------------------------------------------------------------------------
  // 2D 图元
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _render2dToJson(WbRender2dScene scene) {
    return <String, dynamic>{
      'primitive': scene.primitive.id,
      'count': scene.count,
      'thickness': scene.thickness,
      'filled': scene.filled,
      'color': _colorToHex(scene.color),
    };
  }

  static WbRender2dScene _render2dFromJson(Map<String, dynamic> json) {
    return WbRender2dScene(
      primitive: _enumById(
        WbRender2dPrimitive.values,
        (WbRender2dPrimitive value) => value.id,
        json['primitive'],
        WbRender2dPrimitive.polygon,
      ),
      count: _int(json['count'], 6),
      thickness: _double(json['thickness'], 2),
      filled: _bool(json['filled'], false),
      color: _colorFrom(json['color'], WbContextPalette.defaultElementColor),
    );
  }
}
