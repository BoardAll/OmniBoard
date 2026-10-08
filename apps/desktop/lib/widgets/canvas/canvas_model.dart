/// 画布元素内存模型：演示模式数据源（字段形状对齐 core 元素 JSON）。
///
/// - [WbCanvasElement]：不可变元素（id/type/位置/尺寸 + 类型专属字段）；
/// - [WbCanvasDocument]：按页面 id 组织的元素集合（内存权威数据）；
/// - [WbCanvasTextCache]：`TextPainter` 布局缓存（按 key 复用，上限后整体清空）；
/// - [WbCanvasPalette]：工具调色板与默认尺寸常量。
///
/// 引擎模式由 `canvas_store.dart` 的 FFI 适配器做尽力往返，本文件不直接
/// 依赖 FFI；`fromCore` 负责把 `WbElement`（含 raw JSON）映射回内存模型。
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'package:flutter/painting.dart';
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

/// 画布元素类型常量（对应 [WbElement.type]）。
abstract final class WbElementKind {
  static const String note = 'note';
  static const String text = 'text';
  static const String shape = 'shape';
  static const String image = 'image';

  /// 自由笔迹（画笔 / 荧光笔）。
  ///
  /// 偏差记录：core 契约暂未定义 `drawing` 类型，引擎模式下该类型
  /// 可能被核心引擎拒绝；演示模式完整支持。
  static const String drawing = 'drawing';

  /// 连线（圆盘「形状 / 连线」组：箭头 / 连线工具拖拽创建）。
  ///
  /// 起止点存于 [WbCanvasElement.points]（世界坐标，固定两点），
  /// 外接矩形同步维护以便渲染裁剪与命中。
  static const String connector = 'connector';

  /// 流程图（专业元素，模型存于 [WbCanvasElement.payload]）。
  static const String flowchart = 'flowchart';

  /// 表格（专业元素）。
  static const String table = 'table';

  /// 思维导图（专业元素）。
  static const String mindmap = 'mindmap';

  /// 函数图像（专业元素，id 与 `WbQuickCreateKind.functionCurve` 对齐）。
  static const String function = 'function';

  /// 3D 对象（专业元素）。
  static const String render3d = 'render3d';

  /// 2D 图元（专业元素）。
  static const String render2d = 'render2d';

  /// 是否为专业元素（payload 承载结构模型，由
  /// `professional_painter.dart` 渲染）。
  static bool isProfessional(String type) =>
      type == flowchart ||
      type == table ||
      type == mindmap ||
      type == function ||
      type == render3d ||
      type == render2d;
}

/// 形状子类型 id（存于 [WbCanvasElement.shapeKind]）。
abstract final class WbShapeKindId {
  static const String rect = 'rect';
  static const String ellipse = 'ellipse';
  static const String diamond = 'diamond';

  /// 平行四边形（圆盘「形状 / 连线」组）。
  static const String parallelogram = 'parallelogram';
}

/// 文本水平对齐 id（存于 [WbCanvasElement.textAlign]）。
abstract final class WbTextAlignId {
  static const String left = 'left';
  static const String center = 'center';
  static const String right = 'right';

  /// 映射到 Flutter [TextAlign]（未知值回退左对齐）。
  static TextAlign toTextAlign(String id) => switch (id) {
        center => TextAlign.center,
        right => TextAlign.right,
        _ => TextAlign.left,
      };
}

/// 画布调色板与排版常量。
abstract final class WbCanvasPalette {
  /// 便签底色（4 色）。
  static const List<int> noteColors = <int>[
    0xFFFFF2B2,
    0xFFCCF0D0,
    0xFFCFE4FF,
    0xFFFFD9E2,
  ];

  /// 形状主色（4 色）。
  static const List<int> shapeColors = <int>[
    0xFF3370FF,
    0xFF12A150,
    0xFFE5484D,
    0xFFF5A623,
  ];

  /// 画笔颜色（4 色）。
  static const List<int> penColors = <int>[
    0xFF1F2933,
    0xFF3370FF,
    0xFFE5484D,
    0xFF12A150,
  ];

  /// 画笔线宽档位。
  static const List<double> penWidths = <double>[2, 4, 8];

  /// 文本元素默认文字色。
  static const int textColor = 0xFF1F2933;

  /// 图片占位底色。
  static const int imageFill = 0xFFE9EDF2;

  /// 荧光笔颜色（半透明黄，含 alpha）。
  static const int highlightColor = 0x59F5C518;

  /// 便签正文字号（世界坐标）。
  static const double noteFontSize = 15;

  /// 文本正文字号（世界坐标）。
  static const double textFontSize = 20;

  /// 便签内边距（世界坐标）。
  static const double notePadding = 12;

  /// 文本次要色（图片占位说明等）。
  static const int mutedTextColor = 0xFF667085;
}

/// 元素创建定义（批量插入 / AI 工具调用落地共用）。
///
/// [position] 为元素左上角世界坐标；为 null 时由
/// `WbCanvasController.insertElements` 决定落点（视口中心阶梯错位）。
/// [size] 为 null 时按 [type] 取默认尺寸；drawing / connector 的几何
/// 以 [points] 世界坐标包围盒为准（与手势创建一致，忽略 position）。
@immutable
class WbElementSpec {
  const WbElementSpec({
    required this.type,
    this.text = '',
    this.position,
    this.size,
    this.color,
    this.fontSize = 0,
    this.textAlign = WbTextAlignId.left,
    this.shapeKind = WbShapeKindId.rect,
    this.strokeWidth = 2,
    this.points = const <Offset>[],
    this.payload,
  });

  /// 元素类型，见 [WbElementKind]。
  final String type;

  /// 文本内容（note / text）。
  final String text;

  /// 左上角世界坐标（null = 自动落点）。
  final Offset? position;

  /// 尺寸（null = 按类型默认）。
  final Size? size;

  /// 主色（null = 按类型默认）。
  final int? color;

  /// 字号覆盖（> 0 生效；0 = 类型默认）。
  final double fontSize;

  /// 文本水平对齐 id，见 [WbTextAlignId]。
  final String textAlign;

  /// 形状子类型 id，见 [WbShapeKindId]。
  final String shapeKind;

  /// 线宽（形状 / 笔迹 / 连线）。
  final double strokeWidth;

  /// 笔迹 / 连线采样点（世界坐标）。
  final List<Offset> points;

  /// 专业元素结构模型（可选）。
  final Object? payload;
}

/// 画布元素（不可变；修改经 [copyWith] 产生新实例，便于撤销快照）。
@immutable
class WbCanvasElement {
  const WbCanvasElement({
    required this.id,
    required this.type,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.zIndex = 0,
    this.text = '',
    this.color = 0xFF3370FF,
    this.strokeWidth = 2,
    this.shapeKind = WbShapeKindId.rect,
    this.penStyle = 'pen',
    this.points = const <Offset>[],
    this.fontSize = 0,
    this.textAlign = WbTextAlignId.left,
    this.payload,
    this.name = '',
    this.visible = true,
    this.locked = false,
  });

  /// 元素 id（页面内唯一）。
  final String id;

  /// 元素类型，见 [WbElementKind]。
  final String type;

  /// 左上角 x（世界坐标）。
  final double x;

  /// 左上角 y（世界坐标）。
  final double y;

  /// 宽（世界坐标）。
  final double width;

  /// 高（世界坐标）。
  final double height;

  /// Z 序（越大越靠上；列表顺序与之一致）。
  final int zIndex;

  /// 文本内容（便签 / 文本）。
  final String text;

  /// 主色（ARGB）：便签底色 / 文本色 / 形状色 / 笔色 / 图片底色。
  final int color;

  /// 线宽（形状 / 笔迹）。
  final double strokeWidth;

  /// 形状子类型 id，见 [WbShapeKindId]。
  final String shapeKind;

  /// 笔触 id，见 [WbPenStyle]（仅 [WbElementKind.drawing]）。
  final String penStyle;

  /// 笔迹采样点（世界坐标，仅 [WbElementKind.drawing]）。
  final List<Offset> points;

  /// 字号覆盖（> 0 生效；0 = 使用类型默认字号）。
  final double fontSize;

  /// 文本水平对齐 id，见 [WbTextAlignId]。
  final String textAlign;

  /// 专业元素结构模型（不可变；见 [WbElementKind.isProfessional]）。
  ///
  /// 仅内存态持有：不参与 [toJson] / [fromCore] 序列化契约，
  /// 引擎模式往返后为 null（此时画占位框）。图片元素同样以
  /// `{'path','naturalWidth','naturalHeight'}` 形态存放于 payload。
  final Object? payload;

  /// 图层显示名（空串 = 未命名，图层面板按类型自动编号）。
  final String name;

  /// 是否可见（false 时画布不绘制、不参与命中）。
  final bool visible;

  /// 是否锁定（true 时画布不参与命中与移动，图层不可拖拽排序）。
  final bool locked;

  /// 图片元素的源文件路径（payload['path']；非图片或缺失返回空串）。
  String get imagePath {
    final Object? data = payload;
    if (data is Map) {
      final Object? path = data['path'];
      if (path is String) {
        return path;
      }
    }
    return '';
  }

  /// 实际渲染字号（未覆盖时回退类型默认）。
  double get effectiveFontSize => fontSize > 0
      ? fontSize
      : (type == WbElementKind.note
          ? WbCanvasPalette.noteFontSize
          : WbCanvasPalette.textFontSize);

  /// 外接矩形（世界坐标）。
  Rect get bounds => Rect.fromLTWH(x, y, width, height);

  /// 是否文本类元素（可双击进入编辑）。
  bool get isTextual =>
      type == WbElementKind.note || type == WbElementKind.text;

  /// 中心点（世界坐标）。
  Offset get center => Offset(x + width / 2, y + height / 2);

  /// 复制并覆盖若干字段（未提供字段保持不变）。
  WbCanvasElement copyWith({
    String? id,
    String? type,
    double? x,
    double? y,
    double? width,
    double? height,
    int? zIndex,
    String? text,
    int? color,
    double? strokeWidth,
    String? shapeKind,
    String? penStyle,
    List<Offset>? points,
    double? fontSize,
    String? textAlign,
    Object? payload,
    String? name,
    bool? visible,
    bool? locked,
  }) {
    return WbCanvasElement(
      id: id ?? this.id,
      type: type ?? this.type,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      zIndex: zIndex ?? this.zIndex,
      text: text ?? this.text,
      color: color ?? this.color,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      shapeKind: shapeKind ?? this.shapeKind,
      penStyle: penStyle ?? this.penStyle,
      points: points ?? this.points,
      fontSize: fontSize ?? this.fontSize,
      textAlign: textAlign ?? this.textAlign,
      payload: payload ?? this.payload,
      name: name ?? this.name,
      visible: visible ?? this.visible,
      locked: locked ?? this.locked,
    );
  }

  /// 契约形状 JSON（对齐 `WbElement` 的 element JSON 子集）。
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'type': type,
      'position': <String, double>{'x': x, 'y': y},
      'size': <String, double>{'width': width, 'height': height},
      'zIndex': zIndex,
      'text': text,
      'color': WbColorUtils.toHex(Color(color), withAlpha: true),
      'strokeWidth': strokeWidth,
      'shapeKind': shapeKind,
      'penStyle': penStyle,
      'fontSize': fontSize,
      'textAlign': textAlign,
      'name': name,
      'visible': visible,
      'locked': locked,
      'points': <Map<String, double>>[
        for (final Offset p in points) <String, double>{'x': p.dx, 'y': p.dy},
      ],
    };
  }

  /// 从引擎 [WbElement]（含 raw JSON）映射；缺失字段取默认值。
  static WbCanvasElement fromCore(WbElement element) {
    final Map<String, dynamic> raw = element.raw;

    double readNumber(Object? value) => value is num ? value.toDouble() : 0;

    Color readColor(Object? value) {
      if (value is int) {
        return Color(value);
      }
      if (value is String && value.isNotEmpty) {
        return WbColorUtils.fromHex(value, fallback: const Color(0xFF3370FF));
      }
      return const Color(0xFF3370FF);
    }

    final List<Offset> points = <Offset>[];
    final Object? rawPoints = raw['points'];
    if (rawPoints is List) {
      for (final Object? item in rawPoints) {
        if (item is Map<dynamic, dynamic>) {
          points.add(Offset(
            readNumber(item['x']),
            readNumber(item['y']),
          ));
        }
      }
    }

    final double rawStrokeWidth = readNumber(raw['strokeWidth']);
    final double rawFontSize = readNumber(raw['fontSize']);

    return WbCanvasElement(
      id: element.id,
      type: element.type,
      x: element.x,
      y: element.y,
      width: element.width,
      height: element.height,
      zIndex: element.zIndex,
      text: raw['text'] is String ? raw['text'] as String : '',
      color: readColor(raw['color']).toARGB32(),
      strokeWidth: rawStrokeWidth == 0 ? 2 : rawStrokeWidth,
      shapeKind: raw['shapeKind'] is String
          ? raw['shapeKind'] as String
          : WbShapeKindId.rect,
      penStyle: raw['penStyle'] is String ? raw['penStyle'] as String : 'pen',
      points: points,
      fontSize: rawFontSize,
      textAlign: raw['textAlign'] is String
          ? raw['textAlign'] as String
          : WbTextAlignId.left,
      name: raw['name'] is String ? raw['name'] as String : '',
      visible: raw['visible'] is bool ? raw['visible'] as bool : true,
      locked: raw['locked'] is bool ? raw['locked'] as bool : false,
    );
  }

  @override
  String toString() =>
      'WbCanvasElement($id, $type, ${bounds.width}x${bounds.height})';
}

/// 画布文档：按页面 id 维护元素列表（内存权威数据，撤销快照的最小单位）。
class WbCanvasDocument {
  final Map<String, List<WbCanvasElement>> _pages =
      <String, List<WbCanvasElement>>{};

  /// 页面元素视图（不可变；页面无元素返回空列表）。
  List<WbCanvasElement> elementsOf(String pageId) {
    final List<WbCanvasElement>? list = _pages[pageId];
    if (list == null || list.isEmpty) {
      return const <WbCanvasElement>[];
    }
    return UnmodifiableListView<WbCanvasElement>(list);
  }

  /// 页面元素浅拷贝快照（元素不可变，浅拷贝即安全）。
  List<WbCanvasElement> snapshot(String pageId) =>
      List<WbCanvasElement>.of(_pages[pageId] ?? const <WbCanvasElement>[]);

  /// 整体替换页面元素（undo / redo / 引擎加载）。
  void replace(String pageId, List<WbCanvasElement> elements) {
    _pages[pageId] = List<WbCanvasElement>.of(elements);
  }

  /// 按 id 添加或替换单个元素。
  void upsert(String pageId, WbCanvasElement element) {
    final List<WbCanvasElement> list =
        _pages.putIfAbsent(pageId, () => <WbCanvasElement>[]);
    for (int i = 0; i < list.length; i++) {
      if (list[i].id == element.id) {
        list[i] = element;
        return;
      }
    }
    list.add(element);
  }

  /// 删除单个元素（不存在返回 false）。
  bool remove(String pageId, String elementId) {
    final List<WbCanvasElement>? list = _pages[pageId];
    if (list == null) {
      return false;
    }
    final int index = list.indexWhere((WbCanvasElement e) => e.id == elementId);
    if (index < 0) {
      return false;
    }
    list.removeAt(index);
    return true;
  }

  /// 批量删除（返回删除数量）。
  int removeMany(String pageId, Iterable<String> elementIds) {
    final List<WbCanvasElement>? list = _pages[pageId];
    if (list == null) {
      return 0;
    }
    final Set<String> ids = elementIds.toSet();
    if (ids.isEmpty) {
      return 0;
    }
    final int before = list.length;
    list.removeWhere((WbCanvasElement e) => ids.contains(e.id));
    return before - list.length;
  }

  /// 按 id 查找（不存在返回 null）。
  WbCanvasElement? byId(String pageId, String elementId) {
    final List<WbCanvasElement>? list = _pages[pageId];
    if (list == null) {
      return null;
    }
    for (final WbCanvasElement e in list) {
      if (e.id == elementId) {
        return e;
      }
    }
    return null;
  }
}

/// `TextPainter` 布局缓存。
///
/// key 由调用方组装（建议包含元素 id 与全部影响布局的字段）；缓存超过
/// [maxEntries] 时整体清空（简单可靠的兜底，避免 LRU 实现开销）。
class WbCanvasTextCache {
  final Map<String, TextPainter> _entries = <String, TextPainter>{};

  /// 缓存上限（超过后整体清空）。
  static const int maxEntries = 512;

  /// 取（或布局）指定 key 的 [TextPainter]。
  TextPainter layout({
    required String key,
    required String text,
    required TextStyle style,
    required double maxWidth,
    TextAlign align = TextAlign.left,
    int? maxLines,
  }) {
    final TextPainter? cached = _entries[key];
    if (cached != null) {
      return cached;
    }
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: WbTypography.apply(style)),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: maxLines,
      ellipsis: maxLines == null ? null : '…',
    )..layout(maxWidth: maxWidth < 1 ? 1 : maxWidth);
    if (_entries.length >= maxEntries) {
      _entries.clear();
    }
    _entries[key] = painter;
    return painter;
  }

  /// 失效某元素相关的全部缓存条目。
  void invalidate(String elementId) {
    _entries.removeWhere(
        (String key, TextPainter _) => key.startsWith('$elementId|'));
  }

  /// 清空缓存。
  void clear() => _entries.clear();
}
