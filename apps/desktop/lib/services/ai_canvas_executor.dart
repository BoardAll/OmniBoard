/// AI 工具调用执行器：把模型返回的工具调用落地到画布。
///
/// - [WbAiToolExecutor]：状态层（`WbAiState`）依赖的抽象，避免状态层
///   直接依赖画布；
/// - [WbAiCanvasExecutor]：内置实现，把 `WbBoardTools` 清单中的工具
///   映射为 `WbCanvasController` 的真实编辑（入撤销栈）；
/// - 每次执行前记录页面快照，供执行卡片「撤销」整体恢复；
/// - M3 只读收窄：注入 [WbAiCanvasExecutor.canEdit] 探针后，无编辑权限
///   （演示中 / 未授权只读）时执行与撤销均不落地，错误经卡片展示。
library;

import 'package:flutter/painting.dart';
import 'package:whiteboard_ai/ai_client.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../widgets/canvas/canvas_controller.dart';
import '../widgets/canvas/canvas_model.dart';
import 'ai_tools.dart';

/// AI 工具执行器抽象。
abstract class WbAiToolExecutor {
  /// 执行一次工具调用，返回结果 JSON
  /// （`ok` / `affected` / `summary` / `ids` / `error`）。
  Future<Map<String, dynamic>> execute(AiToolCall call);

  /// 撤销一次已执行调用对白板的实际改动（执行卡片「撤销」）。
  void undo(AiToolCall call);
}

/// 画布执行器：`element_create` / `element_update` / `element_move` /
/// `element_delete`（名称对齐 [WbBoardTools]）。
class WbAiCanvasExecutor implements WbAiToolExecutor {
  WbAiCanvasExecutor({required this.canvas, this.canEdit});

  /// 目标画布控制器。
  final WbCanvasController canvas;

  /// 编辑权限探针（M3 只读收窄；null = 不检查）。
  ///
  /// 宿主注入 `() => collab.canEdit` 后，无权限时 [execute] 返回错误、
  /// [undo] 不落地（与服务端 `effectiveCanWrite` 口径对齐）。
  final bool Function()? canEdit;

  /// 当前是否具备编辑权限（未注入探针时视为有权限）。
  bool get _editable => canEdit?.call() ?? true;

  /// 每次执行前的页面快照（撤销时整体恢复；元素不可变，浅拷贝即安全）。
  final Map<String, List<WbCanvasElement>> _beforeStates =
      <String, List<WbCanvasElement>>{};

  @override
  Future<Map<String, dynamic>> execute(AiToolCall call) async {
    // M3 只读收窄（2026-10 默认无权限）：无编辑权限时拒绝落地（AI 面板卡片展示错误）。
    if (!_editable) {
      return _error('当前无编辑权限（可由主持人授权）');
    }
    // 先留档再执行，任何分支都可用 undo 整体恢复。
    _beforeStates[call.id] = canvas.pageSnapshot();
    switch (call.name) {
      case WbBoardTools.elementCreate:
        return _create(call);
      case WbBoardTools.elementUpdate:
        return _update(call);
      case WbBoardTools.elementMove:
        return _move(call);
      case WbBoardTools.elementDelete:
        return _delete(call);
      default:
        _beforeStates.remove(call.id);
        return _error('不支持的工具：${call.name}');
    }
  }

  @override
  void undo(AiToolCall call) {
    // M3 只读收窄：无编辑权限时撤销同样不落地（恢复元素同属画布编辑）。
    if (!_editable) {
      return;
    }
    final List<WbCanvasElement>? before = _beforeStates.remove(call.id);
    if (before == null) {
      return;
    }
    canvas.restoreElements(before);
  }

  // ---- 工具实现 ----

  Map<String, dynamic> _create(AiToolCall call) {
    final List<WbElementSpec> specs = _parseCreateSpecs(call.arguments);
    if (specs.isEmpty) {
      _beforeStates.remove(call.id);
      return _error('缺少 elements 参数');
    }
    final List<WbCanvasElement> created = canvas.insertElements(specs);
    return _success(
      call.name,
      created.length,
      ids: <String>[for (final WbCanvasElement e in created) e.id],
    );
  }

  Map<String, dynamic> _update(AiToolCall call) {
    final String id = _readString(call.arguments, 'elementId');
    final Object? patch = call.arguments['patch'];
    if (id.isEmpty || patch is! Map) {
      _beforeStates.remove(call.id);
      return _error('缺少 elementId 或 patch 参数');
    }
    final Map<dynamic, dynamic> patchMap = Map<dynamic, dynamic>.from(patch);
    final WbCanvasElement? updated = canvas.updateElement(
      id,
      (WbCanvasElement element) => _applyPatch(element, patchMap),
    );
    if (updated == null) {
      _beforeStates.remove(call.id);
      return _error('元素不存在：$id');
    }
    return _success(call.name, 1, ids: <String>[id]);
  }

  Map<String, dynamic> _move(AiToolCall call) {
    final String id = _readString(call.arguments, 'elementId');
    final Offset? position = _readOffset(call.arguments['position']);
    final double? dx = _readNumber(call.arguments['dx']);
    final double? dy = _readNumber(call.arguments['dy']);
    if (id.isEmpty) {
      _beforeStates.remove(call.id);
      return _error('缺少 elementId 参数');
    }
    if (position == null && dx == null && dy == null) {
      _beforeStates.remove(call.id);
      return _error('缺少 position 或 dx/dy 参数');
    }
    final WbCanvasElement? updated = canvas.updateElement(
      id,
      (WbCanvasElement element) => _applyMove(element, position, dx, dy),
    );
    if (updated == null) {
      _beforeStates.remove(call.id);
      return _error('元素不存在：$id');
    }
    return _success(call.name, 1, ids: <String>[id]);
  }

  Map<String, dynamic> _delete(AiToolCall call) {
    final List<String> ids = _readIdList(call.arguments);
    if (ids.isEmpty) {
      _beforeStates.remove(call.id);
      return _error('缺少 ids 参数');
    }
    final int removed = canvas.removeElements(ids);
    return _success(call.name, removed, ids: ids);
  }

  // ---- 参数解析 ----

  /// 解析 `element_create` 的 `elements`（容错：单元素顶层形态）。
  List<WbElementSpec> _parseCreateSpecs(Map<String, dynamic> arguments) {
    final List<WbElementSpec> specs = <WbElementSpec>[];
    final Object? elements = arguments['elements'];
    if (elements is List) {
      for (final Object? item in elements) {
        if (item is! Map) {
          continue;
        }
        final WbElementSpec? spec =
            _specFrom(Map<dynamic, dynamic>.from(item));
        if (spec != null) {
          specs.add(spec);
        }
      }
    } else if (arguments['type'] is String) {
      final WbElementSpec? spec = _specFrom(arguments);
      if (spec != null) {
        specs.add(spec);
      }
    }
    return specs;
  }

  static WbElementSpec? _specFrom(Map<dynamic, dynamic> map) {
    String type = _readFirstString(map, const <String>['type', 'kind']);
    String shapeKind = _readString(map, 'shapeKind');
    // 形状子类型可能直接写在 type 上（rect / ellipse 等）。
    final String normalizedKind = _normalizeShapeKind(type);
    if (normalizedKind.isNotEmpty) {
      shapeKind = normalizedKind;
    }
    type = _normalizeType(type);
    if (type.isEmpty) {
      return null;
    }
    // 图片无法由模型提供源文件，降级为便签承载说明文本。
    if (type == WbElementKind.image) {
      type = WbElementKind.note;
    }
    final String text =
        _readFirstString(map, const <String>['text', 'label', 'content', 'title']);
    final String textAlign = _normalizeTextAlign(_readString(map, 'textAlign'));
    return WbElementSpec(
      type: type,
      text: text,
      position: _readOffset(map['position']),
      size: _readSize(map['size']),
      color: _readColor(map['color']),
      fontSize: _readNumber(map['fontSize']) ?? 0,
      textAlign: textAlign.isEmpty ? WbTextAlignId.left : textAlign,
      shapeKind: shapeKind.isEmpty ? WbShapeKindId.rect : shapeKind,
      strokeWidth: _readNumber(map['strokeWidth']) ?? 2,
      points: _readPoints(map['points']),
    );
  }

  /// 类型归一（大小写 / 中英文别名 → `WbElementKind`）。
  static String _normalizeType(String raw) {
    final String value = raw.trim().toLowerCase();
    switch (value) {
      case 'note':
      case 'sticky':
      case 'postit':
      case 'post-it':
      case '便签':
        return WbElementKind.note;
      case 'text':
      case 'label':
      case '文本':
        return WbElementKind.text;
      case 'shape':
      case WbShapeKindId.rect:
      case WbShapeKindId.ellipse:
      case WbShapeKindId.diamond:
      case WbShapeKindId.parallelogram:
      case '形状':
        return WbElementKind.shape;
      case 'drawing':
      case 'stroke':
      case 'pen':
      case '笔迹':
      case '涂鸦':
        return WbElementKind.drawing;
      case 'connector':
      case 'arrow':
      case 'line':
      case '连线':
      case '箭头':
        return WbElementKind.connector;
      case 'image':
      case '图片':
        return WbElementKind.image;
      case '':
        return WbElementKind.note;
      default:
        return WbElementKind.note;
    }
  }

  /// 形状子类型白名单（非法值返回空串）。
  static String _normalizeShapeKind(String raw) {
    switch (raw.trim().toLowerCase()) {
      case WbShapeKindId.rect:
        return WbShapeKindId.rect;
      case WbShapeKindId.ellipse:
        return WbShapeKindId.ellipse;
      case WbShapeKindId.diamond:
        return WbShapeKindId.diamond;
      case WbShapeKindId.parallelogram:
        return WbShapeKindId.parallelogram;
      default:
        return '';
    }
  }

  /// 文本对齐白名单（非法值返回空串 = 保持默认）。
  static String _normalizeTextAlign(String raw) {
    switch (raw.trim().toLowerCase()) {
      case WbTextAlignId.left:
        return WbTextAlignId.left;
      case WbTextAlignId.center:
        return WbTextAlignId.center;
      case WbTextAlignId.right:
        return WbTextAlignId.right;
      default:
        return '';
    }
  }

  // ---- 属性补丁 ----

  /// 应用 `element_update` 的 patch（未提供的字段保持不变）。
  static WbCanvasElement _applyPatch(
    WbCanvasElement element,
    Map<dynamic, dynamic> patch,
  ) {
    final Object? rawText = patch['text'];
    final int? color = _readColor(patch['color']);
    final Offset? position = _readOffset(patch['position']);
    final Size? size = _readSize(patch['size']);
    final double? fontSize = _readNumber(patch['fontSize']);
    final String textAlign = _normalizeTextAlign(_readString(patch, 'textAlign'));
    final String shapeKind = _normalizeShapeKind(_readString(patch, 'shapeKind'));
    final double x = position?.dx ?? element.x;
    final double y = position?.dy ?? element.y;
    final double width = size?.width ?? element.width;
    final double height = size?.height ?? element.height;
    final List<Offset>? points =
        _transformStrokePoints(element, x, y, width, height);
    return element.copyWith(
      x: x,
      y: y,
      width: width,
      height: height,
      text: rawText is String ? rawText : null,
      color: color,
      fontSize: fontSize,
      textAlign: textAlign.isEmpty ? null : textAlign,
      shapeKind: shapeKind.isEmpty ? null : shapeKind,
      points: points,
    );
  }

  /// 应用 `element_move`（position 优先；否则按 dx/dy 增量）。
  static WbCanvasElement _applyMove(
    WbCanvasElement element,
    Offset? position,
    double? dx,
    double? dy,
  ) {
    final double x = position?.dx ?? element.x + (dx ?? 0);
    final double y = position?.dy ?? element.y + (dy ?? 0);
    final List<Offset>? points = _transformStrokePoints(
      element,
      x,
      y,
      element.width,
      element.height,
    );
    if (points == null) {
      return element.copyWith(x: x, y: y);
    }
    return element.copyWith(x: x, y: y, points: points);
  }

  /// 点式元素（笔迹 / 连线）的 points 随外接矩形做同一线性映射；
  /// 非点式元素返回 null（不修改 points）。
  static List<Offset>? _transformStrokePoints(
    WbCanvasElement element,
    double x,
    double y,
    double width,
    double height,
  ) {
    final bool stroke = element.type == WbElementKind.drawing ||
        element.type == WbElementKind.connector;
    final List<Offset> points = element.points;
    if (!stroke || points.isEmpty) {
      return null;
    }
    final Rect from = element.bounds;
    final double sx = from.width <= 0 ? 1 : width / from.width;
    final double sy = from.height <= 0 ? 1 : height / from.height;
    return <Offset>[
      for (final Offset p in points)
        Offset(x + (p.dx - from.left) * sx, y + (p.dy - from.top) * sy),
    ];
  }

  // ---- 结果构造 ----

  static Map<String, dynamic> _success(
    String tool,
    int affected, {
    List<String> ids = const <String>[],
  }) {
    return <String, dynamic>{
      'ok': true,
      'affected': affected,
      'ids': ids,
      'summary': '已执行 $tool（影响 $affected 个元素）',
    };
  }

  static Map<String, dynamic> _error(String message) {
    return <String, dynamic>{'ok': false, 'error': message};
  }

  // ---- 基础读取 ----

  static String _readString(Map<dynamic, dynamic> map, String key) =>
      map[key] is String ? map[key] as String : '';

  static String _readFirstString(Map<dynamic, dynamic> map, List<String> keys) {
    for (final String key in keys) {
      final String value = _readString(map, key);
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  static double? _readNumber(Object? value) =>
      value is num ? value.toDouble() : null;

  static Offset? _readOffset(Object? value) {
    if (value is! Map) {
      return null;
    }
    final double? x = _readNumber(value['x']);
    final double? y = _readNumber(value['y']);
    if (x == null || y == null) {
      return null;
    }
    return Offset(x, y);
  }

  static Size? _readSize(Object? value) {
    if (value is! Map) {
      return null;
    }
    final double? width = _readNumber(value['width']);
    final double? height = _readNumber(value['height']);
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return Size(width, height);
  }

  static List<Offset> _readPoints(Object? value) {
    if (value is! List) {
      return const <Offset>[];
    }
    final List<Offset> points = <Offset>[];
    for (final Object? item in value) {
      final Offset? point = _readOffset(item);
      if (point != null) {
        points.add(point);
      }
    }
    return points;
  }

  static int? _readColor(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      final String trimmed = value.trim();
      final bool looksHex = RegExp(
        r'^#?(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$',
      ).hasMatch(trimmed);
      if (looksHex) {
        return WbColorUtils.fromHex(trimmed).toARGB32();
      }
    }
    return null;
  }

  static List<String> _readIdList(Map<String, dynamic> arguments) {
    final List<String> ids = <String>[];
    void add(Object? value) {
      if (value is String && value.isNotEmpty && !ids.contains(value)) {
        ids.add(value);
      }
    }

    void addAll(Object? value) {
      if (value is List) {
        for (final Object? item in value) {
          add(item);
        }
      }
    }

    addAll(arguments['ids']);
    addAll(arguments['elementIds']);
    add(arguments['elementId']);
    return ids;
  }
}
