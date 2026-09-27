/// 透明批注状态：模式 / 笔迹层 / 当前笔刷（《透明批注模式技术方案》§4 / §6）。
///
/// 纯数据状态（[ChangeNotifier]），供 UI 层消费；流程编排（进入退出 /
/// 全局快捷键 / 保存回白板）见 `widgets/annotation/annotation_controller.dart`。
library;

import 'package:flutter/material.dart';

/// 透明批注模式（文档 §4：穿透态 / 批注态）。
enum WbAnnotationMode {
  /// 未进入透明批注模式。
  off('未进入'),

  /// 批注态：捕获鼠标事件绘制批注。
  annotating('批注'),

  /// 穿透态：鼠标事件传给系统，可正常操作电脑。
  penetrating('穿透');

  const WbAnnotationMode(this.label);

  /// 中文显示名。
  final String label;
}

/// 批注工具（文档 §6.1：画笔 / 荧光笔 / 橡皮 / 激光笔）。
enum WbAnnotationTool {
  /// 画笔：自由手绘。
  pen('画笔'),

  /// 荧光笔：半透明高亮。
  highlighter('荧光笔'),

  /// 橡皮：擦除笔迹。
  eraser('橡皮'),

  /// 激光笔：临时高亮，自动消失、不保存。
  laser('激光笔');

  const WbAnnotationTool(this.label);

  /// 中文显示名。
  final String label;

  /// 是否产生笔迹（橡皮为擦除操作，不产生笔迹）。
  bool get drawsStroke => this != WbAnnotationTool.eraser;
}

/// 批注高对比色板与线宽档位（桌面批注内容色，不随主题变化）。
abstract final class WbAnnotationPalette {
  /// 可选颜色（高对比，兼顾深浅桌面背景）。
  static const List<Color> colors = <Color>[
    Color(0xFFE5484D), // 红
    Color(0xFFF76B15), // 橙
    Color(0xFFF5D90A), // 黄
    Color(0xFF30A46C), // 绿
    Color(0xFF3370FF), // 蓝
    Color(0xFF8E4EC6), // 紫
    Color(0xFFFFFFFF), // 白
    Color(0xFF1F2937), // 墨黑
  ];

  /// 线宽档位（逻辑像素）。
  static const List<double> widths = <double>[2, 4, 8];

  /// 激光笔专用色。
  static const Color laser = Color(0xFFFF3B30);
}

/// 单条批注笔迹（坐标相对覆盖层逻辑像素；本地覆盖层渲染，不写白板数据）。
class WbAnnotationStroke {
  WbAnnotationStroke({
    required this.id,
    required this.tool,
    required this.color,
    required this.width,
    required this.opacity,
    required this.createdAt,
    List<Offset>? points,
  }) : points = points ?? <Offset>[];

  /// 笔迹 id（本地唯一即可，用于覆盖层渲染与测试断言）。
  final String id;

  /// 工具类型。
  final WbAnnotationTool tool;

  /// 颜色。
  final Color color;

  /// 线宽（逻辑像素；荧光笔 / 激光笔已按工具换算）。
  final double width;

  /// 基础透明度（荧光笔 < 1，其余为 1）。
  final double opacity;

  /// 创建时刻（激光笔渐隐 / 过期计算基准）。
  final DateTime createdAt;

  /// 采样点列表（按时间顺序；由状态层追加）。
  final List<Offset> points;

  /// 激光笔生命周期（文档 §6.1：临时高亮）。
  static const Duration laserLifespan = Duration(milliseconds: 1600);

  /// 激光笔末尾渐隐时长。
  static const Duration laserFadeDuration = Duration(milliseconds: 500);

  /// 是否激光笔笔迹。
  bool get isLaser => tool == WbAnnotationTool.laser;

  /// 追加一个采样点。
  void addPoint(Offset point) => points.add(point);

  /// 在 [now] 时刻是否已过期（仅激光笔会过期）。
  bool isExpiredAt(DateTime now) =>
      isLaser && now.difference(createdAt) >= laserLifespan;

  /// 在 [now] 时刻的渲染透明度（激光笔随剩余寿命渐隐）。
  double opacityAt(DateTime now) {
    if (!isLaser) {
      return opacity;
    }
    final Duration elapsed = now.difference(createdAt);
    if (elapsed >= laserLifespan) {
      return 0;
    }
    final Duration remaining = laserLifespan - elapsed;
    if (remaining >= laserFadeDuration) {
      return opacity;
    }
    final double fade =
        (remaining.inMicroseconds / laserFadeDuration.inMicroseconds)
            .clamp(0.0, 1.0)
            .toDouble();
    return opacity * fade;
  }

  @override
  String toString() =>
      'WbAnnotationStroke($id, ${tool.name}, ${points.length} pts)';
}

/// 透明批注状态（模式 / 笔迹列表 / 当前笔刷）。
class WbAnnotationState extends ChangeNotifier {
  WbAnnotationMode _mode = WbAnnotationMode.off;
  WbAnnotationTool _tool = WbAnnotationTool.pen;
  Color _color = WbAnnotationPalette.colors.first;
  double _width = WbAnnotationPalette.widths[1];
  final List<WbAnnotationStroke> _strokes = <WbAnnotationStroke>[];
  final List<WbAnnotationStroke> _redoStack = <WbAnnotationStroke>[];
  List<WbAnnotationStroke> _saved = <WbAnnotationStroke>[];
  String? _activeStrokeId;
  int _seq = 0;

  /// 橡皮擦命中半径（逻辑像素）。
  static const double eraseRadius = 14;

  /// 荧光笔宽度倍率（相对所选线宽）。
  static const double highlighterWidthRatio = 3;

  /// 荧光笔基础透明度（半透明高亮，§6.1）。
  static const double highlighterOpacity = 0.35;

  /// 激光笔线宽（逻辑像素）。
  static const double laserWidth = 4;

  // ---- 模式（§4 两种状态） ----

  /// 当前模式。
  WbAnnotationMode get mode => _mode;

  /// 是否处于透明批注模式（批注态或穿透态）。
  bool get isActive => _mode != WbAnnotationMode.off;

  /// 是否穿透态。
  bool get isPenetrating => _mode == WbAnnotationMode.penetrating;

  /// 进入透明批注模式（默认批注态，文档 §5.2 步骤 5；幂等）。
  void enter([WbAnnotationMode mode = WbAnnotationMode.annotating]) {
    if (mode == WbAnnotationMode.off || _mode == mode) {
      return;
    }
    _mode = mode;
    notifyListeners();
  }

  /// 切换到批注 / 穿透态（未进入时忽略；off 不作为目标态）。
  void setMode(WbAnnotationMode mode) {
    if (mode == WbAnnotationMode.off || !isActive || _mode == mode) {
      return;
    }
    _mode = mode;
    notifyListeners();
  }

  /// 退出透明批注模式（不清空笔迹；清理见 [discardStrokes] / [markSaved]）。
  void exit() {
    if (_mode == WbAnnotationMode.off) {
      return;
    }
    _mode = WbAnnotationMode.off;
    _activeStrokeId = null;
    notifyListeners();
  }

  // ---- 当前笔刷（§6.2 批注属性） ----

  /// 当前工具。
  WbAnnotationTool get tool => _tool;

  /// 当前颜色。
  Color get color => _color;

  /// 当前线宽（原始档位值）。
  double get width => _width;

  /// 选择工具。
  void selectTool(WbAnnotationTool tool) {
    if (_tool == tool) {
      return;
    }
    _tool = tool;
    notifyListeners();
  }

  /// 设置颜色。
  void setColor(Color color) {
    if (_color == color) {
      return;
    }
    _color = color;
    notifyListeners();
  }

  /// 设置线宽。
  void setWidth(double width) {
    if (_width == width) {
      return;
    }
    _width = width;
    notifyListeners();
  }

  // ---- 笔迹层（§6.3 批注层管理） ----

  /// 笔迹列表（不可变视图）。
  List<WbAnnotationStroke> get strokes =>
      List<WbAnnotationStroke>.unmodifiable(_strokes);

  /// 笔迹数量。
  int get strokeCount => _strokes.length;

  /// 是否存在笔迹。
  bool get hasStrokes => _strokes.isNotEmpty;

  /// 是否存在激光笔轨迹（覆盖层据此启停帧动画）。
  bool get hasLaser => _strokes.any((WbAnnotationStroke s) => s.isLaser);

  /// 是否可撤销。
  bool get canUndo => _strokes.isNotEmpty;

  /// 是否可重做。
  bool get canRedo => _redoStack.isNotEmpty;

  /// 最近一次「保存到白板」的快照（不含激光笔；供白板合并取用）。
  List<WbAnnotationStroke> get savedSnapshot =>
      List<WbAnnotationStroke>.unmodifiable(_saved);

  /// 快照笔迹数量。
  int get savedCount => _saved.length;

  /// 开始一条笔迹（返回笔迹 id）。
  ///
  /// 画笔 / 荧光笔使用当前颜色与线宽；激光笔使用专用色与固定线宽。
  String beginStroke(Offset point, {DateTime? now}) {
    final WbAnnotationStroke stroke = _createStroke(point, now: now);
    _strokes.add(stroke);
    _redoStack.clear();
    _activeStrokeId = stroke.id;
    notifyListeners();
    return stroke.id;
  }

  /// 追加采样点到当前笔迹（无活动笔迹时忽略）。
  void extendStroke(Offset point) {
    final WbAnnotationStroke? stroke = _activeStroke;
    if (stroke == null) {
      return;
    }
    stroke.addPoint(point);
    notifyListeners();
  }

  /// 结束当前笔迹。
  void endStroke() {
    if (_activeStrokeId == null) {
      return;
    }
    _activeStrokeId = null;
    notifyListeners();
  }

  /// 橡皮擦：擦除命中 [point]（半径 [radius] + 半笔宽，含线段命中），
  /// 返回被删除的笔迹数量。
  int eraseAt(Offset point, {double radius = eraseRadius}) {
    final int before = _strokes.length;
    _strokes.removeWhere(
      (WbAnnotationStroke stroke) => _hits(stroke, point, radius),
    );
    final int removed = before - _strokes.length;
    if (removed > 0) {
      notifyListeners();
    }
    return removed;
  }

  /// 撤销（弹出最后一条笔迹到重做栈）。
  bool undo() {
    if (_strokes.isEmpty) {
      return false;
    }
    final WbAnnotationStroke stroke = _strokes.removeLast();
    _redoStack.add(stroke);
    if (stroke.id == _activeStrokeId) {
      _activeStrokeId = null;
    }
    notifyListeners();
    return true;
  }

  /// 重做。
  bool redo() {
    if (_redoStack.isEmpty) {
      return false;
    }
    _strokes.add(_redoStack.removeLast());
    notifyListeners();
    return true;
  }

  /// 清空笔迹与重做栈（文档 §6.3「支持清空」）。
  void clear() {
    if (_strokes.isEmpty && _redoStack.isEmpty) {
      return;
    }
    _strokes.clear();
    _redoStack.clear();
    _activeStrokeId = null;
    notifyListeners();
  }

  /// 丢弃批注（退出弹窗「丢弃」选项，§5.4）。
  void discardStrokes() => clear();

  /// 标记「保存到白板」成功：可保存笔迹快照化并清空本地批注层。
  void markSaved() {
    _saved = <WbAnnotationStroke>[
      for (final WbAnnotationStroke stroke in _strokes)
        if (!stroke.isLaser) stroke,
    ];
    _strokes.clear();
    _redoStack.clear();
    _activeStrokeId = null;
    notifyListeners();
  }

  /// 移除 [now] 时刻已过期的激光笔轨迹（含重做栈）；返回是否发生变更。
  bool purgeExpiredLaser(DateTime now) {
    final int strokesBefore = _strokes.length;
    final int redoBefore = _redoStack.length;
    _strokes.removeWhere((WbAnnotationStroke s) => s.isExpiredAt(now));
    _redoStack.removeWhere((WbAnnotationStroke s) => s.isExpiredAt(now));
    final bool changed =
        _strokes.length != strokesBefore || _redoStack.length != redoBefore;
    if (changed) {
      if (_activeStrokeId != null && !_strokes.any((s) => s.id == _activeStrokeId)) {
        _activeStrokeId = null;
      }
      notifyListeners();
    }
    return changed;
  }

  /// [now] 时刻的可见笔迹（激光笔过期项被过滤），供覆盖层绘制。
  List<WbAnnotationStroke> visibleStrokes(DateTime now) =>
      <WbAnnotationStroke>[
        for (final WbAnnotationStroke stroke in _strokes)
          if (!stroke.isExpiredAt(now)) stroke,
      ];

  // ---- 内部 ----

  WbAnnotationStroke? get _activeStroke {
    final String? id = _activeStrokeId;
    if (id == null) {
      return null;
    }
    for (final WbAnnotationStroke stroke in _strokes) {
      if (stroke.id == id) {
        return stroke;
      }
    }
    return null;
  }

  WbAnnotationStroke _createStroke(Offset point, {DateTime? now}) {
    final DateTime createdAt = now ?? DateTime.now();
    final String id = 'annotation-stroke-${_seq++}';
    switch (_tool) {
      case WbAnnotationTool.laser:
        return WbAnnotationStroke(
          id: id,
          tool: WbAnnotationTool.laser,
          color: WbAnnotationPalette.laser,
          width: laserWidth,
          opacity: 1,
          createdAt: createdAt,
          points: <Offset>[point],
        );
      case WbAnnotationTool.highlighter:
        return WbAnnotationStroke(
          id: id,
          tool: WbAnnotationTool.highlighter,
          color: _color,
          width: _width * highlighterWidthRatio,
          opacity: highlighterOpacity,
          createdAt: createdAt,
          points: <Offset>[point],
        );
      case WbAnnotationTool.pen:
      case WbAnnotationTool.eraser:
        return WbAnnotationStroke(
          id: id,
          tool: WbAnnotationTool.pen,
          color: _color,
          width: _width,
          opacity: 1,
          createdAt: createdAt,
          points: <Offset>[point],
        );
    }
  }

  static bool _hits(WbAnnotationStroke stroke, Offset point, double radius) {
    final double threshold = radius + stroke.width / 2;
    final List<Offset> points = stroke.points;
    if (points.isEmpty) {
      return false;
    }
    if (points.length == 1) {
      return (points.first - point).distance <= threshold;
    }
    for (int i = 1; i < points.length; i++) {
      if (_distanceToSegment(point, points[i - 1], points[i]) <= threshold) {
        return true;
      }
    }
    return false;
  }

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final Offset ab = b - a;
    final double lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lengthSquared == 0) {
      return (p - a).distance;
    }
    final double t =
        (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lengthSquared)
            .clamp(0.0, 1.0)
            .toDouble();
    final Offset projection = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - projection).distance;
  }
}
