/// 画布控制器：视口变换 / 手势状态机 / 工具行为 / 选择 / 编辑命令 / 撤销栈。
///
/// 坐标约定：**世界坐标**（元素存储、网格、笔迹）与**屏幕坐标**（画布视口
/// 内像素）通过 [worldToScreen] / [screenToWorld] 双向换算
/// （`screen = world * scale + offset`）。
///
/// 所有状态变更都会 [notifyListeners]；`WbCanvasPainter`、迷你地图与悬浮
/// 控件监听本对象做局部重绘（避免整页 rebuild）。手势由 `CanvasView` 的
/// `Listener` 转发原始指针事件（鼠标 / 触摸 / 触控板统一入口，见各
/// `handle*` 方法），键盘快捷键经 [handleShortcut]。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:whiteboard_theme/theme.dart';

import '../state/selection_state.dart';
import '../collab/preview_page_match.dart';
import '../context_editors/render3d_editor.dart';
import '../markdown/markdown_painter.dart';
import 'canvas_image_cache.dart';
import 'canvas_model.dart';
import 'stroke_style.dart';
import 'canvas_store.dart';
import 'wb3d_projection.dart';

/// 画布工具（id 与工具栏 / 命令总线命名风格一致）。
enum WbCanvasTool {
  select('select', '选择'),
  hand('hand', '抓手'),
  pen('pen', '画笔'),
  highlighter('highlighter', '荧光笔'),
  eraser('eraser', '橡皮擦'),
  note('sticky', '便签'),
  text('text', '文本'),
  shape('shape', '形状'),
  image('image', '图片'),
  connector('connector', '连线'),
  render3d('render3d', '3D');

  const WbCanvasTool(this.id, this.label);

  /// 工具 id。
  final String id;

  /// 中文显示名。
  final String label;
}

/// 形状子类型（[WbCanvasElement.shapeKind] 的枚举视图）。
enum WbShapeKind {
  rect(WbShapeKindId.rect, '矩形'),
  ellipse(WbShapeKindId.ellipse, '椭圆'),
  diamond(WbShapeKindId.diamond, '菱形'),
  parallelogram(WbShapeKindId.parallelogram, '平行四边形');

  const WbShapeKind(this.id, this.label);

  /// 子类型 id（与 [WbCanvasElement.shapeKind] 对应）。
  final String id;

  /// 中文显示名。
  final String label;

  /// 按 id 反查（未知返回 [WbShapeKind.rect]）。
  static WbShapeKind fromId(String id) {
    for (final WbShapeKind kind in values) {
      if (kind.id == id) {
        return kind;
      }
    }
    return WbShapeKind.rect;
  }
}

/// 指针手势状态机状态。
enum WbCanvasGesture {
  idle,
  panning,
  boxSelect,
  moveElements,
  scaleElements,
  draw,
  createElement,
  erase,
  createRender3d,
  rotateRender3d,
}

/// 选择框缩放柄（4 角 + 4 边）。
enum WbSelectionHandle {
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left;

  /// 该柄拖动左侧边。
  bool get movesLeft => this == topLeft || this == left || this == bottomLeft;

  /// 该柄拖动右侧边。
  bool get movesRight =>
      this == topRight || this == right || this == bottomRight;

  /// 该柄拖动上侧边。
  bool get movesTop => this == topLeft || this == top || this == topRight;

  /// 该柄拖动下侧边。
  bool get movesBottom =>
      this == bottomLeft || this == bottom || this == bottomRight;
}

/// 手势起始时的元素快照（移动 / 缩放的基准）。
class _ElementSnapshot {
  const _ElementSnapshot({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.points = const <Offset>[],
  });

  final String id;
  final double x;
  final double y;
  final double width;
  final double height;

  /// 手势起始时的笔迹 / 连线点（世界坐标；连线移动缩放时同步映射）。
  final List<Offset> points;
}

/// 本地落定提交批次（与撤销栈入栈同一批落地；协同出口的输入）。
///
/// [pageId] 为提交所属页 id（协同出口内嵌进 op 载荷，接收端按页
/// 路由）；[upserts] 为新增 / 变更后的元素（全量契约 JSON 语义）；
/// [removedIds] 为被删除的元素 id。由 `WbCanvasController._commitEdit`
/// 生成并经 `onLocalCommit` 交给协同服务（远端应用路径不经过本出口）。
class WbCanvasCommitBatch {
  const WbCanvasCommitBatch({
    this.pageId = '',
    this.upserts = const <WbCanvasElement>[],
    this.removedIds = const <String>[],
  });

  /// 提交所属页 id（空串 = 未分页 / 默认页）。
  final String pageId;

  /// 新增或变更的元素（元素不可变，引用安全）。
  final List<WbCanvasElement> upserts;

  /// 删除的元素 id。
  final List<String> removedIds;

  /// 批次是否为空（无变更）。
  bool get isEmpty => upserts.isEmpty && removedIds.isEmpty;

  /// 批次是否非空。
  bool get isNotEmpty => !isEmpty;
}

/// 画布控制器（唯一状态源）。
class WbCanvasController extends ChangeNotifier {
  WbCanvasController({
    WbCanvasDocument? document,
    WbCanvasStore? store,
    WbSelectionState? selection,
    WbCanvasTextCache? textCache,
    WbCanvasImageCache? imageCache,
    this.imagePicker,
    this.onElementActivate,
    this.onSizeBadgeTap,
    Timer Function(Duration interval, void Function() onTick)?
        previewTimerFactory,
  })  : document = document ?? WbCanvasDocument(),
        textCache = textCache ?? WbCanvasTextCache(),
        imageCache = imageCache ?? WbCanvasImageCache(),
        _ownsImageCache = imageCache == null,
        _store = store,
        _previewTimerFactory = previewTimerFactory ?? _oneShotTimer {
    attachSelection(selection);
  }

  /// 内存文档（按页元素集合，权威数据）。
  final WbCanvasDocument document;

  /// 文本布局缓存（绘制用）。
  final WbCanvasTextCache textCache;

  /// 图片解码缓存（painter 同步读、图片工具解码用；注入时由持有者释放）。
  final WbCanvasImageCache imageCache;

  final bool _ownsImageCache;

  /// 图片文件选择回调（注入；null 时图片工具回退占位元素、双击不重选）。
  Future<String?> Function()? imagePicker;

  /// 专业元素双击激活回调（注入；null 时双击专业元素无行为）。
  ///
  /// 宿主持有独立编辑页时用它接收激活事件，返回后自行按新模型
  /// 经 [updateElement] 回写（问题 6：创建 / 编辑新起页面）。
  Future<void> Function(WbCanvasElement element)? onElementActivate;

  /// 尺寸角标点击回调（注入；null 时点击角标无行为）。
  ///
  /// 宿主弹出尺寸设置对话框并把结果经 [resizeElementById] 回写
  /// （问题 6：3D / 2D 元素显示宽高并可调整）。
  void Function(WbCanvasElement element)? onSizeBadgeTap;

  /// 本地落定提交回调（注入：协同出口；null 时无行为）。
  ///
  /// 在 `_commitEdit`（撤销栈入栈同一批）后调用；`isRemoteApplying`
  /// 返回 true 时跳过（防回发）。回调内不得直接调用本控制器方法。
  void Function(WbCanvasCommitBatch batch)? onLocalCommit;

  /// 远端应用期间判定（注入：防回发第二层）。
  ///
  /// 协同服务应用远端 op 期间返回 true——`_commitEdit` 的出口将跳过
  /// 提交批次（第一层：远端应用走 `applyRemoteElement` /
  /// `applyRemoteRemove`，结构上绕过提交漏斗）。
  bool Function()? isRemoteApplying;

  /// 笔迹预览出口（注入：协同；null 时无行为）。
  ///
  /// 画笔 / 荧光笔拖动中按 [previewInterval] 节流交付增量点
  /// （`{kind:'ink', strokeId, pageId, points:[Δ点], style, highlight}`）；
  /// `strokeId` 为落定前置生成的元素 id，终态 op 仍走 [onLocalCommit]
  /// 的既有 `el:{id}:data` 链路。
  void Function(Map<String, dynamic> preview)? onInkPreview;

  /// 变换预览出口（注入：协同；null 时无行为）。
  ///
  /// 移动 / 缩放拖动中按 [previewInterval] 节流交付选中元素目标几何
  /// （`{kind:'transform', elementId, pageId, x, y, w, h}`）。
  void Function(Map<String, dynamic> preview)? onTransformPreview;

  /// 指针光标出口（注入：协同；null 时无行为）。
  ///
  /// 画布内指针移动按 [cursorInterval] 节流交付世界坐标
  /// （`{kind:'cursor', pageId, x, y}`）。
  void Function(Map<String, dynamic> preview)? onCursorMoved;

  /// 选区变化出口（注入：协同；null 时无行为）。
  ///
  /// 选中集合变化按 [selectionInterval] 节流交付
  /// （`{kind:'selection', pageId, elementIds}`）。
  void Function(Map<String, dynamic> preview)? onSelectionChanged;

  /// 编辑锁请求出口（注入：协同；null 时无行为）。
  ///
  /// 进入文本编辑 / 专业编辑 / 尺寸对话框前请求软锁
  /// （`lock:acquire`）；授予 / 拒绝经协同服务 lockAcks 回执处理。
  void Function(String elementId)? onEditLockRequest;

  /// 编辑锁释放出口（注入：协同；null 时无行为）。
  ///
  /// 退出文本编辑 / 专业编辑 / 尺寸对话框后释放软锁
  /// （`lock:release`）。
  void Function(String elementId)? onEditLockRelease;

  /// 点击「他人编辑中」元素回调（注入；null 时无行为）。
  ///
  /// 文本 / 专业元素等编辑入口命中远端持有的软锁时用它提示。
  void Function(WbCanvasElement element)? onLockedElementTap;

  /// 视口帧出口（注入：协同跟随；null 时无行为）。
  ///
  /// 用户平移 / 缩放后按 [viewportBroadcastInterval]（200ms）节流交付
  /// `{kind:'viewport', pageId, offset:{dx,dy}, zoom}`；是否实际发送由
  /// 应用层按协同状态（有跟随者 / 本端为演示者）决定。
  void Function(Map<String, dynamic> frame)? onViewportChanged;

  /// 页面帧出口（注入：协同跟随；null 时无行为）。
  ///
  /// [setPage] 切换到达新页时立即交付 `{kind:'page', pageId}`。
  void Function(Map<String, dynamic> frame)? onPagePreview;

  /// 用户视口手势回调（注入：协同跟随打断；null 时无行为）。
  ///
  /// 用户 pan / zoom 入口（含滚轮 / 触控板 / 缩放控件 / 小地图）触发；
  /// [applyRemoteViewport] 等程序化调用不触发。应用层据此自动停止跟随。
  void Function()? onUserViewportGesture;

  /// 是否已释放（异步流程完成后不再写状态）。
  bool _disposed = false;

  final WbCanvasStore? _store;

  /// 预览节流 / 鬼影时钟的一次性定时器工厂（注入用于测试手动驱动）。
  final Timer Function(Duration interval, void Function() onTick)
      _previewTimerFactory;

  // ---- 视口 -------------------------------------------------------------

  /// 最小缩放。
  static const double minScale = 0.1;

  /// 最大缩放。
  static const double maxScale = 8;

  /// 撤销栈最大深度。
  static const int maxUndoDepth = 100;

  /// 粘贴偏移（世界坐标）。
  static const double pasteOffset = 24;

  /// 笔迹 / 变换预览节流间隔（33ms ≈ 30fps）。
  static const Duration previewInterval = Duration(milliseconds: 33);

  /// 光标预览节流间隔（50ms）。
  static const Duration cursorInterval = Duration(milliseconds: 50);

  /// 选区 / 擦除批次节流间隔（100ms）。
  static const Duration selectionInterval = Duration(milliseconds: 100);

  /// 视口帧外发节流间隔（M3 跟随：200ms）。
  static const Duration viewportBroadcastInterval = Duration(milliseconds: 200);

  /// 笔迹落定前 Douglas-Peucker 抽稀公差（世界坐标亚像素）。
  static const double strokeSimplifyTolerance = 0.75;

  /// 远端鬼影空闲淘汰时间（超时后开始淡出；秒）。
  static const double remoteGhostTtlSeconds = 5;

  /// 远端鬼影淡出时长（秒）。
  static const double remoteGhostFadeSeconds = 1;

  /// 远端删除淡出时长（秒）。
  static const double remoteFadeOutSeconds = 0.15;

  /// 远端变换预览外发上限（防大批量选中刷屏）。
  static const int maxTransformPreviews = 12;

  /// 单条远端笔迹鬼影点数上限（超出丢弃最旧点）。
  static const int remoteInkGhostMaxPoints = 4000;

  /// 已终态 strokeId 记忆容量（FIFO 淘汰；丢弃迟到的预览帧）。
  static const int finalizedIdsCapacity = 128;

  /// 鬼影 / 淡出时钟步进间隔。
  static const Duration _previewTickInterval = Duration(milliseconds: 40);

  Size _viewportSize = Size.zero;
  double _scale = 1;
  Offset _offset = Offset.zero;

  /// 视口尺寸（由 `CanvasView` 的 LayoutBuilder 上报）。
  Size get viewportSize => _viewportSize;

  /// 当前缩放（1 = 100%）。
  double get scale => _scale;

  /// 当前平移（屏幕坐标偏移）。
  Offset get offset => _offset;

  /// 视口中心（屏幕坐标）。
  Offset get viewportCenter =>
      Offset(_viewportSize.width / 2, _viewportSize.height / 2);

  /// 当前可见世界矩形。
  Rect get visibleWorldRect => Rect.fromPoints(
        screenToWorld(Offset.zero),
        screenToWorld(Offset(_viewportSize.width, _viewportSize.height)),
      );

  /// 上报视口尺寸（`LayoutBuilder` 内调用；不触发通知，避免 build 期重建）。
  void setViewportSize(Size size) {
    if (size == _viewportSize) {
      return;
    }
    _viewportSize = size;
  }

  /// 世界坐标 → 屏幕坐标。
  Offset worldToScreen(Offset world) => Offset(
        world.dx * _scale + _offset.dx,
        world.dy * _scale + _offset.dy,
      );

  /// 屏幕坐标 → 世界坐标。
  Offset screenToWorld(Offset screen) => Offset(
        (screen.dx - _offset.dx) / _scale,
        (screen.dy - _offset.dy) / _scale,
      );

  /// 世界矩形 → 屏幕矩形。
  Rect worldRectToScreen(Rect rect) => Rect.fromPoints(
      worldToScreen(rect.topLeft), worldToScreen(rect.bottomRight));

  /// 按屏幕像素平移视图。
  void panBy(Offset screenDelta) {
    if (screenDelta == Offset.zero) {
      return;
    }
    _offset += screenDelta;
    _afterUserViewportChange();
    notifyListeners();
  }

  /// 围绕 [screenFocal] 缩放到 [newScale]（焦点下的世界点保持不动）。
  void zoomAt(Offset screenFocal, double newScale) {
    final double target = _clampScale(newScale);
    if (target == _scale) {
      return;
    }
    final Offset worldFocal = screenToWorld(screenFocal);
    _scale = target;
    _offset = screenFocal - worldFocal * target;
    _afterUserViewportChange();
    notifyListeners();
  }

  /// 按倍率缩放（默认围绕视口中心）。
  void zoomBy(double factor, {Offset? focal}) {
    zoomAt(focal ?? viewportCenter, _scale * factor);
  }

  /// 重置为 100% 且原点对齐屏幕左上（双击空白 / Ctrl+0 行为）。
  void resetView() {
    _scale = 1;
    _offset = Offset.zero;
    _afterUserViewportChange();
    notifyListeners();
  }

  /// 当前页所有元素的包围盒（无元素返回 null）。
  Rect? get contentBounds {
    final List<WbCanvasElement> list = elements;
    if (list.isEmpty) {
      return null;
    }
    Rect bounds = list.first.bounds;
    for (int i = 1; i < list.length; i++) {
      bounds = bounds.expandToInclude(list[i].bounds);
    }
    return bounds;
  }

  /// 缩放并平移使全部内容可见（Ctrl+1 / 适应内容按钮）。
  void fitToContent({double padding = 48}) {
    final Rect? bounds = contentBounds;
    final Size viewport = _viewportSize;
    if (bounds == null || viewport.isEmpty) {
      resetView();
      return;
    }
    final double availableW = math.max(1, viewport.width - padding * 2);
    final double availableH = math.max(1, viewport.height - padding * 2);
    final double contentW = math.max(1, bounds.width);
    final double contentH = math.max(1, bounds.height);
    final double target = _clampScale(
      math.min(availableW / contentW, availableH / contentH),
    );
    _scale = target;
    _offset = Offset(
      viewport.width / 2 - bounds.center.dx * target,
      viewport.height / 2 - bounds.center.dy * target,
    );
    _afterUserViewportChange();
    notifyListeners();
  }

  /// 使世界点 [world] 位于视口中心（迷你地图跳转）。
  void centerWorldAt(Offset world) {
    if (_viewportSize.isEmpty) {
      return;
    }
    _offset = viewportCenter - world * _scale;
    _afterUserViewportChange();
    notifyListeners();
  }

  /// 应用远端视口（M3 跟随）：程序化设置平移 / 缩放并重绘。
  ///
  /// 不触发 [onViewportChanged] / [onUserViewportGesture]（防回环、
  /// 不打断跟随）；偏移 / 缩放（含钳制后）均相同时零开销。
  void applyRemoteViewport(Offset offset, double scale) {
    final double target = _clampScale(scale);
    if (target == _scale && offset == _offset) {
      return;
    }
    _scale = target;
    _offset = offset;
    notifyListeners();
  }

  // ---- 页面 -------------------------------------------------------------

  String _pageId = '';

  /// 当前页 id（空串为默认页；由 `CanvasView` 从 `WbPageState` 同步）。
  String get pageId => _pageId;

  /// 切换页面（取消手势、提交编辑、清空撤销栈并按需加载引擎元素）。
  void setPage(String pageId) {
    if (pageId == _pageId) {
      return;
    }
    _flushRender3dSizeSession();
    cancelGesture();
    endTextEditing();
    _pageId = pageId;
    _undoStack.clear();
    _redoStack.clear();
    if (_store != null && pageId.isNotEmpty) {
      try {
        document.replace(pageId, _store.load(pageId));
      } catch (_) {
        // 引擎错误：保持内存内容。
      }
    }
    notifyListeners();
    onPagePreview?.call(<String, dynamic>{'kind': 'page', 'pageId': _pageId});
  }

  /// 当前页元素（不可变视图）。
  List<WbCanvasElement> get elements => document.elementsOf(_pageId);

  // ---- 工具 -------------------------------------------------------------

  WbCanvasTool _tool = WbCanvasTool.select;
  WbShapeKind _shapeKind = WbShapeKind.rect;
  int _noteColor = WbCanvasPalette.noteColors.first;
  int _shapeColor = WbCanvasPalette.shapeColors.first;
  int _penColor = WbCanvasPalette.penColors.first;
  int _highlightColor = WbCanvasPalette.highlightColor;
  WbPenStyle _penStyle = WbPenStyle.pen;
  double _penWidth = WbCanvasPalette.penWidths[1];
  bool _spacePressed = false;
  Wb3dObjectType _render3dType = Wb3dObjectType.box;

  /// 当前工具。
  WbCanvasTool get tool => _tool;

  /// 形状子类型（形状工具使用）。
  WbShapeKind get shapeKind => _shapeKind;

  /// 便签底色。
  int get noteColor => _noteColor;

  /// 形状主色。
  int get shapeColor => _shapeColor;

  /// 画笔颜色。
  int get penColor => _penColor;

  /// 荧光笔颜色（含透明度）。
  int get highlightColor => _highlightColor;

  /// 当前画笔笔触。荧光笔绘制时忽略，仍走实线。
  WbPenStyle get penStyle => _penStyle;

  /// 画笔线宽。
  double get penWidth => _penWidth;

  /// 空格键是否按下（临时平移）。
  bool get spacePressed => _spacePressed;

  /// 3D 直绘对象类型（[WbCanvasTool.render3d]）。
  Wb3dObjectType get render3dType => _render3dType;

  /// 切换工具（取消进行中的手势并提交编辑）。
  void setTool(WbCanvasTool tool) {
    if (_tool == tool) {
      return;
    }
    _flushRender3dSizeSession();
    cancelGesture();
    endTextEditing();
    _tool = tool;
    if (tool != WbCanvasTool.select) {
      // 涂色模式仅在「选择」工具下可用，切走时自动关闭。
      _render3dPaintMode = false;
    }
    _clearRender3dState();
    notifyListeners();
  }

  /// 设置形状子类型。
  void setShapeKind(WbShapeKind kind) {
    if (_shapeKind == kind) {
      return;
    }
    _shapeKind = kind;
    notifyListeners();
  }

  /// 设置便签底色。
  void setNoteColor(int color) {
    if (_noteColor == color) {
      return;
    }
    _noteColor = color;
    notifyListeners();
  }

  /// 设置形状主色。
  void setShapeColor(int color) {
    if (_shapeColor == color) {
      return;
    }
    _shapeColor = color;
    notifyListeners();
  }

  /// 设置画笔颜色。
  void setPenColor(int color) {
    if (_penColor == color) {
      return;
    }
    _penColor = color;
    notifyListeners();
  }

  /// 设置荧光笔颜色（保留调用方传入的透明度）。
  void setHighlightColor(int color) {
    if (_highlightColor == color) {
      return;
    }
    _highlightColor = color;
    notifyListeners();
  }

  /// 设置画笔笔触。
  void setPenStyle(WbPenStyle style) {
    if (_penStyle == style) {
      return;
    }
    _penStyle = style;
    notifyListeners();
  }

  /// 设置画笔线宽。
  void setPenWidth(double width) {
    if (_penWidth == width) {
      return;
    }
    _penWidth = width;
    notifyListeners();
  }

  /// 空格按下态（空格 + 拖拽 = 平移）。
  void setSpacePressed(bool pressed) {
    if (_spacePressed == pressed) {
      return;
    }
    _spacePressed = pressed;
    notifyListeners();
  }

  /// 设置 3D 直绘对象类型。
  void setRender3dType(Wb3dObjectType type) {
    if (_render3dType == type) {
      return;
    }
    _render3dType = type;
    notifyListeners();
  }

  // ---- 选择 -------------------------------------------------------------

  WbSelectionState? _selection;

  /// 外部选区状态（可为空，为空时选择交互退化为 no-op）。
  WbSelectionState? get selection => _selection;

  /// 绑定 / 解绑外部选区状态。
  void attachSelection(WbSelectionState? selection) {
    if (identical(_selection, selection)) {
      return;
    }
    _selection?.removeListener(_onSelectionChanged);
    _selection = selection;
    _selection?.addListener(_onSelectionChanged);
    notifyListeners();
  }

  void _onSelectionChanged() {
    // 选区外发（M2）：节流交付当前选中集合（含清空）；未注入出口时
    // 零开销（不建定时器）。
    if (onSelectionChanged != null) {
      _selectionThrottle.schedule(_emitSelectionPreview);
    }
    notifyListeners();
  }

  /// 发出选区预览（[onSelectionChanged] 出口）。
  void _emitSelectionPreview() {
    final void Function(Map<String, dynamic> preview)? callback =
        onSelectionChanged;
    if (callback == null) {
      return;
    }
    callback(<String, dynamic>{
      'kind': 'selection',
      'pageId': _pageId,
      'elementIds': selectedIds.toList(growable: false),
    });
  }

  /// 选中元素 id 集合。
  Set<String> get selectedIds => _selection?.ids ?? const <String>{};

  /// 是否有选中。
  bool get hasSelection => selectedIds.isNotEmpty;

  /// 选中元素列表（按 z 序）。
  List<WbCanvasElement> get selectedElements {
    final Set<String> ids = selectedIds;
    if (ids.isEmpty) {
      return const <WbCanvasElement>[];
    }
    return elements
        .where((WbCanvasElement e) => ids.contains(e.id))
        .toList(growable: false);
  }

  /// 选中元素包围盒（世界坐标；无选中返回 null）。
  Rect? get selectionBounds {
    final List<WbCanvasElement> selected = selectedElements;
    if (selected.isEmpty) {
      return null;
    }
    Rect bounds = selected.first.bounds;
    for (int i = 1; i < selected.length; i++) {
      bounds = bounds.expandToInclude(selected[i].bounds);
    }
    return bounds;
  }

  /// 全选当前页元素（Ctrl+A）。
  void selectAll() {
    final List<String> ids =
        elements.map((WbCanvasElement e) => e.id).toList(growable: false);
    if (ids.isEmpty) {
      return;
    }
    _selection?.select(ids);
  }

  // ---- 3D 表面涂色参数（问题 6 尾巴）-------------------------------------

  bool _render3dPaintMode = false;
  int _render3dPaintColor = WbCanvasPalette.shapeColors.first;

  /// 表面涂色模式（选择工具 + 单选 3D 元素时可用）。
  bool get render3dPaintMode => _render3dPaintMode;

  /// 涂色色板当前色（ARGB）。
  int get render3dPaintColor => _render3dPaintColor;

  /// 单选中的 3D 元素（未单选 3D 元素时返回 null）。
  WbCanvasElement? get singleSelectedRender3d {
    final Set<String> ids = selectedIds;
    if (ids.length != 1) {
      return null;
    }
    final WbCanvasElement? element = document.byId(_pageId, ids.first);
    if (element == null || element.type != WbElementKind.render3d) {
      return null;
    }
    return element;
  }

  /// 是否单选了一个 3D 元素（浮出涂色参数行的前提）。
  bool get hasSingleRender3dSelection => singleSelectedRender3d != null;

  /// 切换表面涂色模式。
  void setRender3dPaintMode(bool on) {
    if (_render3dPaintMode == on) {
      return;
    }
    _render3dPaintMode = on;
    notifyListeners();
  }

  /// 设置涂色色板当前色。
  void setRender3dPaintColor(int color) {
    if (_render3dPaintColor == color) {
      return;
    }
    _render3dPaintColor = color;
    notifyListeners();
  }

  // ---- 尺寸角标（3D / 2D 宽高显示与调整）---------------------------------

  /// 单选中的「有尺寸」元素（render3d / render2d；不可用时返回 null）。
  ///
  /// 元素锁定或正在进行文本编辑时返回 null（不显示尺寸角标）。
  WbCanvasElement? get singleSelectedSizedElement {
    final Set<String> ids = selectedIds;
    if (ids.length != 1) {
      return null;
    }
    final WbCanvasElement? element = document.byId(_pageId, ids.first);
    if (element == null ||
        (element.type != WbElementKind.render3d &&
            element.type != WbElementKind.render2d) ||
        element.locked ||
        editingElementId != null) {
      return null;
    }
    return element;
  }

  /// 尺寸角标文本（世界单位取整；无可用元素返回空串）。
  String get sizeBadgeLabel {
    final WbCanvasElement? element = singleSelectedSizedElement;
    if (element == null) {
      return '';
    }
    return '${element.width.round()} × ${element.height.round()}';
  }

  /// 尺寸角标的屏幕矩形（选择框下缘居中、下方 6px；无角标返回 null）。
  ///
  /// 每帧从 [selectionBounds] 推导：缩放柄拖动 / 滚轮缩放时角标自动
  /// 跟随刷新（painter 只绘制，不持有几何）。
  Rect? get sizeBadgeScreenRect {
    if (singleSelectedSizedElement == null) {
      return null;
    }
    final Rect? bounds = selectionBounds;
    if (bounds == null) {
      return null;
    }
    final Rect screen = worldRectToScreen(bounds);
    final double width = sizeBadgeLabel.length * 6.5 + 14;
    return Rect.fromLTWH(
      screen.center.dx - width / 2,
      screen.bottom + 6,
      width,
      20,
    );
  }

  /// 按 id 调整元素宽高（保持中心不变；入撤销栈）。
  ///
  /// 元素不存在、锁定或数值无变化时直接返回（不产生撤销记录）。
  void resizeElementById(String id, double width, double height) {
    final WbCanvasElement? element = document.byId(_pageId, id);
    if (element == null || element.locked) {
      return;
    }
    final double w = width.clamp(8.0, 20000.0).toDouble();
    final double h = height.clamp(8.0, 20000.0).toDouble();
    if (w == element.width && h == element.height) {
      return;
    }
    final Offset center = element.center;
    _beginEdit();
    document.upsert(
      _pageId,
      element.copyWith(
        x: center.dx - w / 2,
        y: center.dy - h / 2,
        width: w,
        height: h,
      ),
    );
    _commitEdit();
    notifyListeners();
  }

  // ---- 命中测试 ---------------------------------------------------------

  /// 命中测试（世界坐标；返回最上层命中的元素）。
  ///
  /// 隐藏（[WbCanvasElement.visible] = false）与锁定
  /// （[WbCanvasElement.locked] = true）元素不参与命中；远端软锁
  /// 持有（[isLockedByOther]）的元素默认跳过（可查看不可交互），
  /// [ignoreRemoteLocks] 为 true 时例外（双击提示「他人编辑中」用）。
  WbCanvasElement? hitTestElement(
    Offset world, {
    bool ignoreRemoteLocks = false,
  }) {
    final List<WbCanvasElement> list = elements;
    for (int i = list.length - 1; i >= 0; i--) {
      final WbCanvasElement element = list[i];
      if (!element.visible || element.locked) {
        continue;
      }
      if (!ignoreRemoteLocks && isLockedByOther(element.id)) {
        continue;
      }
      if (_hitElement(element, world)) {
        return element;
      }
    }
    return null;
  }

  bool _hitElement(WbCanvasElement element, Offset world) {
    if (element.type == WbElementKind.drawing ||
        element.type == WbElementKind.connector) {
      return _hitStroke(
        element,
        world,
        tolerance: 8 / _scale + element.strokeWidth / 2,
      );
    }
    return element.bounds.contains(world);
  }

  bool _hitStroke(WbCanvasElement element, Offset point,
      {required double tolerance}) {
    final List<Offset> points = element.points;
    if (points.isEmpty) {
      return element.bounds.inflate(tolerance).contains(point);
    }
    if (points.length == 1) {
      return (points.first - point).distance <= tolerance;
    }
    for (int i = 0; i < points.length - 1; i++) {
      if (_distanceToSegment(point, points[i], points[i + 1]) <= tolerance) {
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
    final double raw =
        ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lengthSquared;
    final double t = math.min(math.max(raw, 0), 1);
    return (p - (a + ab * t)).distance;
  }

  /// 命中缩放柄（屏幕坐标；返回命中的柄或 null）。
  WbSelectionHandle? hitTestHandle(Offset screen, {double tolerance = 10}) {
    final Rect? bounds = selectionBounds;
    if (bounds == null) {
      return null;
    }
    final Rect rect = worldRectToScreen(bounds);
    for (final WbSelectionHandle handle in WbSelectionHandle.values) {
      if ((handlePosition(handle, rect) - screen).distance <= tolerance) {
        return handle;
      }
    }
    return null;
  }

  /// 柄在屏幕矩形中的位置。
  static Offset handlePosition(WbSelectionHandle handle, Rect rect) {
    switch (handle) {
      case WbSelectionHandle.topLeft:
        return rect.topLeft;
      case WbSelectionHandle.top:
        return Offset(rect.center.dx, rect.top);
      case WbSelectionHandle.topRight:
        return rect.topRight;
      case WbSelectionHandle.right:
        return Offset(rect.right, rect.center.dy);
      case WbSelectionHandle.bottomRight:
        return rect.bottomRight;
      case WbSelectionHandle.bottom:
        return Offset(rect.center.dx, rect.bottom);
      case WbSelectionHandle.bottomLeft:
        return rect.bottomLeft;
      case WbSelectionHandle.left:
        return Offset(rect.left, rect.center.dy);
    }
  }

  // ---- 手势 -------------------------------------------------------------

  WbCanvasGesture _gesture = WbCanvasGesture.idle;
  final Map<int, Offset> _pointers = <int, Offset>{};
  bool _multiTouch = false;
  double _pinchStartDistance = 1;
  Offset _pinchStartFocal = Offset.zero;
  double _pinchStartScale = 1;
  Offset _pinchStartOffset = Offset.zero;
  Offset _gestureStartScreen = Offset.zero;
  Offset _gestureStartWorld = Offset.zero;
  Offset _lastScreen = Offset.zero;
  List<_ElementSnapshot> _gestureOriginals = <_ElementSnapshot>[];
  Rect? _gestureStartBounds;
  WbSelectionHandle? _activeHandle;
  Rect? _marqueeRect;
  List<Offset>? _pendingStroke;
  Rect? _createPreview;
  Set<String> _marqueeBaseSelection = <String>{};
  List<WbCanvasElement>? _editSnapshot;
  DateTime? _lastTapTime;
  Offset? _lastTapPosition;
  double _panZoomScale = 1;
  Rect? _render3dBaseRect;
  String? _rotate3dElementId;
  Wb3dScene? _rotate3dStartScene;
  Timer? _render3dSizeCommitTimer;
  bool _render3dSizeSession = false;

  /// 画布交互开关（M3 权限收窄：present 非演示者 / Viewer / 被移除 →
  /// false 时忽略指针编辑手势与编辑快捷键；保留视口浏览）。
  bool _interactionEnabled = true;

  /// 滚轮缩放 3D 尺寸会话的空闲提交延迟（多次滚轮合并为 1 条撤销）。
  static const Duration _render3dSizeIdle = Duration(milliseconds: 400);

  // ---- 协同预览（M2）：节流器与鬼影时钟 ---------------------------------

  /// 笔迹 / 变换 / 光标 / 选区 / 擦除预览节流器
  /// （首沿立即 + 窗口抑制 + 尾沿补发）。
  late final _PreviewThrottle _inkThrottle =
      _PreviewThrottle(previewInterval, _previewTimerFactory);
  late final _PreviewThrottle _transformThrottle =
      _PreviewThrottle(previewInterval, _previewTimerFactory);
  late final _PreviewThrottle _cursorThrottle =
      _PreviewThrottle(cursorInterval, _previewTimerFactory);
  late final _PreviewThrottle _selectionThrottle =
      _PreviewThrottle(selectionInterval, _previewTimerFactory);
  late final _PreviewThrottle _eraseThrottle =
      _PreviewThrottle(selectionInterval, _previewTimerFactory);
  late final _PreviewThrottle _viewportThrottle =
      _PreviewThrottle(viewportBroadcastInterval, _previewTimerFactory);

  /// 进行中笔迹的预生成元素 id（增量预览与落定终态共用）。
  String? _pendingStrokeId;

  /// 当前笔迹已外发的增量点数（下次只发 [sent, length) 区间）。
  int _inkPreviewSentCount = 0;

  /// 最近一次指针屏幕位置（光标预览转世界坐标用）。
  Offset? _pendingCursorScreen;

  /// 擦除批次的 diff 基线（手势开始时快照；中间批次逐次更新）。
  List<WbCanvasElement>? _eraseLastEmitSnapshot;

  /// 鬼影 / 淡出时钟（有叠加时自续期；见 [_ensurePreviewTicker]）。
  Timer? _previewTicker;

  /// 视「单击」的最小拖拽边长（任一有效边小于该值即按单击默认尺寸放置）。
  static const double _minDrawSide = 24;

  /// 球体单击默认直径（以按下点为中心）。
  static const double _sphereClickSide = 180;

  /// 非球体单击默认底面宽（以按下点为中心）。
  static const double _clickBaseWidth = 220;

  /// 非球体单击默认底面高（以按下点为中心）。
  static const double _clickBaseHeight = 160;

  /// 画布交互是否开启（false = 只读：忽略编辑手势 / 双击 / 编辑快捷键，
  /// 保留滚轮 / 触控板 PanZoom / space / 中键 / 手形浏览）。
  bool get interactionEnabled => _interactionEnabled;

  /// 设置画布交互开关（变化才通知；关闭时取消进行中的编辑手势）。
  void setInteractionEnabled(bool value) {
    if (value == _interactionEnabled) {
      return;
    }
    _interactionEnabled = value;
    if (!value) {
      cancelGesture();
    }
    notifyListeners();
  }

  /// 当前手势状态。
  WbCanvasGesture get gesture => _gesture;

  /// 框选矩形（屏幕坐标；未框选为 null）。
  Rect? get marqueeRect => _marqueeRect;

  /// 进行中的笔迹（世界坐标；画笔拖动中）。
  List<Offset>? get pendingStroke => _pendingStroke;

  /// 拖拽创建预览矩形（世界坐标；便签/文本/形状/图片工具拖动中）。
  Rect? get createPreview => _createPreview;

  /// 连线工具创建手势起点（世界坐标；非连线创建中返回 null）。
  Offset? get connectorPreviewStart =>
      (_gesture == WbCanvasGesture.createElement &&
              _tool == WbCanvasTool.connector)
          ? _gestureStartWorld
          : null;

  /// 连线工具创建手势当前终点（世界坐标，随指针更新）。
  Offset? get connectorPreviewEnd =>
      (_gesture == WbCanvasGesture.createElement &&
              _tool == WbCanvasTool.connector)
          ? screenToWorld(_lastScreen)
          : null;

  /// 3D 直绘预览场景（创建手势中返回当前类型场景；否则 null）。
  Wb3dScene? get render3dPreviewScene =>
      _gesture == WbCanvasGesture.createRender3d && _render3dBaseRect != null
          ? Wb3dScene(objectType: _render3dType)
          : null;

  /// 3D 直绘预览矩形（世界坐标；预览与落地结果一致）。
  ///
  /// 拖拽中为实时底面推导出的整体盒子（单击 = 默认尺寸盒子）。
  Rect? get render3dPreviewRect {
    final Rect? base = _render3dBaseRect;
    if (base == null || _gesture != WbCanvasGesture.createRender3d) {
      return null;
    }
    return _render3dDropRect(base);
  }

  /// 指针按下（由 `CanvasView` 转发）。
  void handlePointerDown(
    int pointerId,
    Offset screen, {
    required bool shift,
    bool middleButton = false,
    bool secondaryButton = false,
    bool touch = false,
  }) {
    if (secondaryButton) {
      return; // 右键保留给上下文菜单（Wave 4）。
    }
    // 交互关闭（M3 权限收窄：present 非演示者 / Viewer / 被移除）：
    // 指针编辑手势直接忽略；保留视口浏览（触屏双指 / space / 中键 /
    // 手形工具 panning）。
    if (!_interactionEnabled &&
        !(_spacePressed || middleButton || _tool == WbCanvasTool.hand)) {
      if (touch) {
        _pointers[pointerId] = screen;
        if (_pointers.length >= 2) {
          _enterMultiTouch();
        }
      }
      return;
    }
    // 新指针按下：先结束滚轮缩放会话（多次滚轮合并为 1 条撤销记录）。
    _flushRender3dSizeSession();
    _pointers[pointerId] = screen;
    if (touch && _pointers.length >= 2) {
      _enterMultiTouch();
      return;
    }
    if (_gesture != WbCanvasGesture.idle) {
      cancelGesture();
    }
    endTextEditing();

    _gestureStartScreen = screen;
    _gestureStartWorld = screenToWorld(screen);
    _lastScreen = screen;

    if (_spacePressed || middleButton || _tool == WbCanvasTool.hand) {
      _gesture = WbCanvasGesture.panning;
      notifyListeners();
      return;
    }

    switch (_tool) {
      case WbCanvasTool.pen:
      case WbCanvasTool.highlighter:
        _gesture = WbCanvasGesture.draw;
        _pendingStroke = <Offset>[_gestureStartWorld];
        // 两阶段笔迹（M2）：预生成元素 id，增量点经 [onInkPreview]
        // 节流外发；抬笔终态仍以同一 id 走 `el:{id}:data`。
        _pendingStrokeId = _nextId();
        _inkPreviewSentCount = 0;
        if (onInkPreview != null) {
          _inkThrottle.schedule(_emitInkPreview);
        }
        notifyListeners();
        return;
      case WbCanvasTool.eraser:
        _gesture = WbCanvasGesture.erase;
        _beginEdit();
        // 逐批提交基线：手势开始时的元素快照（中间批次与之 diff）。
        _eraseLastEmitSnapshot = List<WbCanvasElement>.of(elements);
        _eraseAt(_gestureStartWorld);
        return;
      case WbCanvasTool.note:
      case WbCanvasTool.text:
      case WbCanvasTool.shape:
      case WbCanvasTool.image:
      case WbCanvasTool.connector:
        _gesture = WbCanvasGesture.createElement;
        _createPreview =
            Rect.fromPoints(_gestureStartWorld, _gestureStartWorld);
        notifyListeners();
        return;
      case WbCanvasTool.render3d:
        // 单击 / 拖拽一次即可放置：PointerUp 时按轨迹或默认尺寸落地。
        _gesture = WbCanvasGesture.createRender3d;
        _render3dBaseRect =
            Rect.fromPoints(_gestureStartWorld, _gestureStartWorld);
        notifyListeners();
        return;
      case WbCanvasTool.select:
      case WbCanvasTool.hand:
        break;
    }

    // 尺寸角标点击（select 工具）：命中时消费按下并回调，不进入任何手势。
    if (_tool == WbCanvasTool.select) {
      final WbCanvasElement? sized = singleSelectedSizedElement;
      final Rect? badge = sizeBadgeScreenRect;
      if (sized != null && badge != null && badge.contains(screen)) {
        onSizeBadgeTap?.call(sized);
        return;
      }
    }

    final WbSelectionHandle? handle = hitTestHandle(screen);
    if (handle != null && hasSelection) {
      _gesture = WbCanvasGesture.scaleElements;
      _activeHandle = handle;
      _gestureStartBounds = selectionBounds;
      _captureOriginals();
      _beginEdit();
      notifyListeners();
      return;
    }

    final WbCanvasElement? hit = hitTestElement(_gestureStartWorld);

    // 3D 表面涂色（选择工具 + 涂色模式）：命中 3D 元素时消费本次按下。
    if (_tool == WbCanvasTool.select && _render3dPaintMode && hit != null) {
      if (_paintRender3dFace(hit, _gestureStartWorld)) {
        return;
      }
    }

    // 3D 翻转：单选已选中的 3D 元素时，拖动进入旋转手势。
    if (hit != null &&
        _tool == WbCanvasTool.select &&
        !shift &&
        hit.type == WbElementKind.render3d &&
        selectedIds.length == 1 &&
        selectedIds.contains(hit.id)) {
      final Object? payload = hit.payload;
      if (payload is Wb3dScene) {
        _gesture = WbCanvasGesture.rotateRender3d;
        _rotate3dElementId = hit.id;
        _rotate3dStartScene = payload;
        _beginEdit();
        notifyListeners();
        return;
      }
    }

    if (hit != null) {
      if (shift) {
        _selection?.toggle(hit.id);
      } else if (!selectedIds.contains(hit.id)) {
        _selection?.select(<String>[hit.id]);
      }
      if (selectedIds.contains(hit.id)) {
        _gesture = WbCanvasGesture.moveElements;
        _captureOriginals();
        _beginEdit();
        notifyListeners();
      } else {
        notifyListeners();
      }
      return;
    }

    // 选择框内部按下（未命中元素）：仍视为拖动整个选择集，
    // 而非清空选择开始框选（框选需从选择框外部开始）。
    if (_tool == WbCanvasTool.select && hasSelection) {
      final Rect? bounds = selectionBounds;
      if (bounds != null &&
          worldRectToScreen(bounds).inflate(6).contains(screen)) {
        _gesture = WbCanvasGesture.moveElements;
        _captureOriginals();
        _beginEdit();
        notifyListeners();
        return;
      }
    }

    _gesture = WbCanvasGesture.boxSelect;
    _marqueeRect = Rect.fromPoints(screen, screen);
    _marqueeBaseSelection = shift ? Set<String>.of(selectedIds) : <String>{};
    if (!shift) {
      _selection?.clear();
    }
    notifyListeners();
  }

  /// 指针移动（由 `CanvasView` 转发）。
  void handlePointerMove(int pointerId, Offset screen) {
    if (_pointers.containsKey(pointerId)) {
      _pointers[pointerId] = screen;
    }
    if (_multiTouch) {
      _updatePinch();
      return;
    }
    if (_gesture == WbCanvasGesture.idle) {
      _lastScreen = screen;
      return;
    }
    final Offset delta = screen - _lastScreen;
    _lastScreen = screen;
    switch (_gesture) {
      case WbCanvasGesture.panning:
        _offset += delta;
        _afterUserViewportChange();
        notifyListeners();
      case WbCanvasGesture.draw:
        _appendStrokePoint(screenToWorld(screen));
      case WbCanvasGesture.createElement:
        _createPreview =
            Rect.fromPoints(_gestureStartWorld, screenToWorld(screen));
        notifyListeners();
      case WbCanvasGesture.moveElements:
        _applyMove(screen - _gestureStartScreen);
      case WbCanvasGesture.scaleElements:
        _applyScale(screen);
      case WbCanvasGesture.boxSelect:
        _updateMarquee();
      case WbCanvasGesture.erase:
        _eraseAt(screenToWorld(screen));
      case WbCanvasGesture.createRender3d:
        _updateRender3dDraw(screen);
      case WbCanvasGesture.rotateRender3d:
        _applyRotate3d(screen);
      case WbCanvasGesture.idle:
        break;
    }
  }

  /// 指针悬停（由 `CanvasView` 的 MouseRegion 转发；无按键移动）。
  ///
  /// 仅用于在场光标（M2）：[cursorInterval] 节流经 [onCursorMoved]
  /// 外发世界坐标；未注入回调时零开销。
  void handlePointerHover(Offset screen) {
    if (_disposed || onCursorMoved == null) {
      return;
    }
    _pendingCursorScreen = screen;
    _cursorThrottle.schedule(_emitCursorPreview);
  }

  /// 发出光标预览（[onCursorMoved] 出口；屏幕坐标转世界坐标）。
  void _emitCursorPreview() {
    final void Function(Map<String, dynamic> preview)? callback = onCursorMoved;
    final Offset? screen = _pendingCursorScreen;
    if (callback == null || screen == null) {
      return;
    }
    final Offset world = screenToWorld(screen);
    callback(<String, dynamic>{
      'kind': 'cursor',
      'pageId': _pageId,
      'x': world.dx,
      'y': world.dy,
    });
  }

  /// 发出视口帧（[onViewportChanged] 出口；节流窗口尾沿读当前视口）。
  void _emitViewportFrame() {
    final void Function(Map<String, dynamic> frame)? callback =
        onViewportChanged;
    if (callback == null || _disposed) {
      return;
    }
    callback(<String, dynamic>{
      'kind': 'viewport',
      'pageId': _pageId,
      'offset': <String, double>{'dx': _offset.dx, 'dy': _offset.dy},
      'zoom': _scale,
    });
  }

  /// 用户视口变化收尾（M3 跟随）：触发打断回调 + 节流外发视口帧。
  ///
  /// 由用户 pan / zoom 入口（[panBy] / [zoomAt] / [resetView] /
  /// [fitToContent] / [centerWorldAt] / panning 拖动 / 双指缩放）调用；
  /// [applyRemoteViewport]（远端跟随帧）不经过这里（防回环）。
  void _afterUserViewportChange() {
    if (_disposed) {
      return;
    }
    onUserViewportGesture?.call();
    if (onViewportChanged != null) {
      _viewportThrottle.schedule(_emitViewportFrame);
    }
  }

  /// 指针抬起（由 `CanvasView` 转发）。
  void handlePointerUp(int pointerId, Offset screen) {
    _pointers.remove(pointerId);
    if (_multiTouch) {
      if (_pointers.isEmpty) {
        _multiTouch = false;
        notifyListeners();
      }
      return;
    }
    if (_gesture == WbCanvasGesture.idle) {
      _maybeDoubleTap(screen);
      return;
    }
    final bool isClick = (screen - _gestureStartScreen).distance < 4;
    switch (_gesture) {
      case WbCanvasGesture.panning:
      case WbCanvasGesture.boxSelect:
        _resetGestureState();
        notifyListeners();
      case WbCanvasGesture.draw:
        _finishStroke();
      case WbCanvasGesture.createElement:
        _finishCreate(isClick, screen);
      case WbCanvasGesture.moveElements:
      case WbCanvasGesture.scaleElements:
      case WbCanvasGesture.rotateRender3d:
        _commitEdit();
        _resetGestureState();
        notifyListeners();
      case WbCanvasGesture.erase:
        // 终态 flush：中间批次已外发，这里只补发残余删除；撤销栈仍
        // 以整段（`_editSnapshot` 起点）入栈一个单元（`emitLocal: false`
        // 防重复提交）。
        _emitEraseBatch();
        _commitEdit(emitLocal: false);
        _resetGestureState();
        notifyListeners();
      case WbCanvasGesture.createRender3d:
        _finishRender3dDraw();
      case WbCanvasGesture.idle:
        break;
    }
    _maybeDoubleTap(screen);
  }

  /// 指针取消（由 `CanvasView` 转发；回滚进行中的手势）。
  void handlePointerCancel(int pointerId) {
    _pointers.remove(pointerId);
    if (_multiTouch) {
      if (_pointers.isEmpty) {
        _multiTouch = false;
        notifyListeners();
      }
      return;
    }
    cancelGesture();
  }

  /// 滚轮 / 触控板双指滚动（由 `CanvasView` 转发）。
  ///
  /// - `Ctrl/Cmd + 滚轮`：围绕指针缩放；
  /// - 普通滚动：平移（`Shift` 时水平平移）。
  bool handleScroll(
    Offset screenFocal,
    Offset scrollDelta, {
    required bool ctrl,
    bool shift = false,
  }) {
    if (scrollDelta == Offset.zero) {
      return false;
    }
    if (ctrl) {
      final double factor = math.exp(-scrollDelta.dy / 320);
      zoomAt(screenFocal, _scale * factor);
      return true;
    }
    // 单选 3D 元素（选择工具）时滚轮等比缩放尺寸，中心保持不变。
    final WbCanvasElement? sized = singleSelectedRender3d;
    if (_tool == WbCanvasTool.select && sized != null && !sized.locked) {
      _zoomRender3dSize(sized, scrollDelta.dy);
      return true;
    }
    if (shift) {
      panBy(Offset(-scrollDelta.dy, 0));
    } else {
      panBy(Offset(-scrollDelta.dx, -scrollDelta.dy));
    }
    return true;
  }

  /// 触控板 PanZoom 手势开始。
  void handlePanZoomStart() {
    _panZoomScale = 1;
  }

  /// 触控板 PanZoom 手势更新（双指平移 + 捏合缩放）。
  void handlePanZoomUpdate(
      Offset localPosition, Offset panDelta, double scale) {
    if (panDelta != Offset.zero) {
      panBy(panDelta);
    }
    final double delta = scale / _panZoomScale;
    _panZoomScale = scale;
    if ((delta - 1).abs() > 0.0001) {
      zoomBy(delta, focal: localPosition);
    }
  }

  /// 触控板 PanZoom 手势结束。
  void handlePanZoomEnd() {
    _panZoomScale = 1;
  }

  /// 取消进行中的手势（回滚未提交的修改）。
  void cancelGesture() {
    final bool busy = _gesture != WbCanvasGesture.idle ||
        _marqueeRect != null ||
        _pendingStroke != null ||
        _createPreview != null ||
        _multiTouch ||
        _render3dBaseRect != null;
    if (!busy) {
      return;
    }
    _pointers.clear();
    _multiTouch = false;
    _abortGesture();
    notifyListeners();
  }

  /// 双击（元素上进入编辑 / 图片重选源文件 / 专业元素打开编辑页；空白处复位视图）。
  ///
  /// 命中远端软锁元素时经 [onLockedElementTap] 提示且不复位视图。
  void handleDoubleClick(Offset screen) {
    if (!_interactionEnabled) {
      return; // 交互关闭：双击编辑 / 空白复位一并忽略。
    }
    final Offset world = screenToWorld(screen);
    final WbCanvasElement? hit = hitTestElement(world);
    if (hit != null) {
      if (hit.isTextual) {
        beginTextEditing(hit.id);
        return;
      }
      if (hit.type == WbElementKind.image && imagePicker != null) {
        unawaited(_replaceImageElement(hit.id));
        return;
      }
      final Future<void> Function(WbCanvasElement element)? activate =
          onElementActivate;
      if (activate != null && WbElementKind.isProfessional(hit.type)) {
        unawaited(activate(hit));
      }
      return;
    }
    // 二次命中（含远端锁元素）：提示他人编辑中，不触发空白双击复位。
    final WbCanvasElement? locked =
        hitTestElement(world, ignoreRemoteLocks: true);
    if (locked != null && isLockedByOther(locked.id)) {
      onLockedElementTap?.call(locked);
      return;
    }
    resetView();
  }

  void _enterMultiTouch() {
    _abortGesture();
    _multiTouch = true;
    final List<Offset> points = _pointers.values.toList(growable: false);
    _pinchStartDistance = math.max(1, (points[0] - points[1]).distance);
    _pinchStartFocal = (points[0] + points[1]) / 2;
    _pinchStartScale = _scale;
    _pinchStartOffset = _offset;
    notifyListeners();
  }

  void _updatePinch() {
    final List<Offset> points = _pointers.values.toList(growable: false);
    if (points.length < 2) {
      return;
    }
    final Offset focal = (points[0] + points[1]) / 2;
    final double distance = math.max(1, (points[0] - points[1]).distance);
    final double targetScale =
        _clampScale(_pinchStartScale * distance / _pinchStartDistance);
    final Offset worldFocal =
        (_pinchStartFocal - _pinchStartOffset) / _pinchStartScale;
    _scale = targetScale;
    _offset = focal - worldFocal * targetScale;
    _afterUserViewportChange();
    notifyListeners();
  }

  void _abortGesture() {
    switch (_gesture) {
      case WbCanvasGesture.moveElements:
      case WbCanvasGesture.scaleElements:
      case WbCanvasGesture.erase:
      case WbCanvasGesture.rotateRender3d:
        _restoreEditSnapshot();
      case WbCanvasGesture.idle:
      case WbCanvasGesture.panning:
      case WbCanvasGesture.boxSelect:
      case WbCanvasGesture.draw:
      case WbCanvasGesture.createElement:
      case WbCanvasGesture.createRender3d:
        break;
    }
    _resetGestureState();
  }

  void _resetGestureState() {
    _gesture = WbCanvasGesture.idle;
    _gestureOriginals = <_ElementSnapshot>[];
    _gestureStartBounds = null;
    _activeHandle = null;
    _marqueeRect = null;
    _pendingStroke = null;
    _createPreview = null;
    _marqueeBaseSelection = <String>{};
    _editSnapshot = null;
    _pendingStrokeId = null;
    _inkPreviewSentCount = 0;
    _inkThrottle.cancel();
    _transformThrottle.cancel();
    _eraseThrottle.cancel();
    _eraseLastEmitSnapshot = null;
    _clearRender3dState();
  }

  // ---- 3D 直绘 / 旋转 / 涂色内部实现 ----------------------------------------

  /// 清理 3D 直绘 / 旋转中间状态（完成 / 取消 / 切工具时调用）。
  void _clearRender3dState() {
    _render3dBaseRect = null;
    _rotate3dElementId = null;
    _rotate3dStartScene = null;
  }

  void _updateRender3dDraw(Offset screen) {
    _render3dBaseRect =
        Rect.fromPoints(_gestureStartWorld, screenToWorld(screen));
    notifyListeners();
  }

  void _finishRender3dDraw() {
    final Rect? base = _render3dBaseRect;
    if (base == null) {
      _resetGestureState();
      notifyListeners();
      return;
    }
    // 单击 / 拖拽一次直接完成：拖拽取轨迹，过小（单击）取默认尺寸。
    _completeRender3d(_render3dDropRect(base));
  }

  /// 球体元素矩形（以 [base] 最大边为直径）。
  ///
  /// 拖动过小 / 单击（最大边 < [_minDrawSide]）时取默认直径
  /// [_sphereClickSide]，以按下点为中心。
  Rect _sphereElementRect(Rect base) {
    final double side = math.max(base.width, base.height);
    if (side < _minDrawSide) {
      return Rect.fromCenter(
        center: _gestureStartWorld,
        width: _sphereClickSide,
        height: _sphereClickSide,
      );
    }
    return Rect.fromCenter(center: base.center, width: side, height: side);
  }

  /// 落地矩形（预览 = 最终结果）：单击取默认尺寸、拖拽按轨迹推导。
  ///
  /// - 球体：[_sphereElementRect]（最大边为直径的正方形）；
  /// - 非球体：底面宽 × 默认高；任一边小于 [_minDrawSide] 视为单击，
  ///   取默认底面 [_clickBaseWidth] x [_clickBaseHeight]，以落点为中心。
  Rect _render3dDropRect(Rect base) {
    if (_render3dType == Wb3dObjectType.sphere) {
      return _sphereElementRect(base);
    }
    if (base.width < _minDrawSide || base.height < _minDrawSide) {
      final double height = _defaultRender3dHeight(
        const Rect.fromLTWH(0, 0, _clickBaseWidth, _clickBaseHeight),
      );
      return Rect.fromLTWH(
        base.center.dx - _clickBaseWidth / 2,
        base.center.dy - _clickBaseHeight / 2,
        _clickBaseWidth,
        height,
      );
    }
    return Rect.fromLTWH(
      base.left,
      base.top,
      base.width,
      _defaultRender3dHeight(base),
    );
  }

  /// 3D 盒子默认高度（底面最大边 * 0.8，夹取 40~2000）。
  static double _defaultRender3dHeight(Rect base) {
    final double hint = math.max(base.width, base.height) * 0.8;
    return hint.clamp(40.0, 2000.0).toDouble();
  }

  /// 完成直绘：按 [rect] 插入 3D 元素并回切选择工具（入撤销栈）。
  void _completeRender3d(Rect rect) {
    final WbCanvasElement element = WbCanvasElement(
      id: _nextId(),
      type: WbElementKind.render3d,
      x: rect.left,
      y: rect.top,
      width: math.max(1.0, rect.width),
      height: math.max(1.0, rect.height),
      zIndex: _nextZIndex(),
      color: _colorForTool(),
      payload: Wb3dScene(objectType: _render3dType),
    );
    _beginEdit();
    document.upsert(_pageId, element);
    _commitEdit();
    _resetGestureState();
    // 问题 4：创建类工具完成后回切选择模式。
    setTool(WbCanvasTool.select);
    // 问题 6 / 波次 C：创建完成后选中新元素，可立即拖动旋转 / 滚轮缩放。
    _selection?.select(<String>[element.id]);
    notifyListeners();
  }

  /// 滚轮缩放单选 3D 尺寸（中心不变；会话合并为 1 条撤销记录）。
  ///
  /// 倍率 = `exp(-dy / 320)`（与视口 Ctrl+滚轮同一口径），宽高各自
  /// clamp 40~4000 世界单位。
  void _zoomRender3dSize(WbCanvasElement element, double scrollDy) {
    final double factor = math.exp(-scrollDy / 320);
    final double width =
        (element.width * factor).clamp(40.0, 4000.0).toDouble();
    final double height =
        (element.height * factor).clamp(40.0, 4000.0).toDouble();
    if (width == element.width && height == element.height) {
      return;
    }
    _beginRender3dSizeSession();
    final Offset center = element.center;
    document.upsert(
      _pageId,
      element.copyWith(
        x: center.dx - width / 2,
        y: center.dy - height / 2,
        width: width,
        height: height,
      ),
    );
    notifyListeners();
  }

  /// 开始（或延续）滚轮缩放会话：首帧建立快照并按空闲延迟自动提交。
  void _beginRender3dSizeSession() {
    if (!_render3dSizeSession) {
      _render3dSizeSession = true;
      if (_editSnapshot == null) {
        _beginEdit();
      }
    }
    _render3dSizeCommitTimer?.cancel();
    _render3dSizeCommitTimer =
        Timer(_render3dSizeIdle, _flushRender3dSizeSession);
  }

  /// 结束滚轮缩放会话：取消空闲定时器并提交合并编辑。
  ///
  /// 无实际变化时 [_commitEdit] 不会产生撤销记录（快照比较兜底）。
  void _flushRender3dSizeSession() {
    _render3dSizeCommitTimer?.cancel();
    _render3dSizeCommitTimer = null;
    if (!_render3dSizeSession) {
      return;
    }
    _render3dSizeSession = false;
    _commitEdit();
  }

  void _applyRotate3d(Offset screen) {
    final String? id = _rotate3dElementId;
    final Wb3dScene? start = _rotate3dStartScene;
    if (id == null || start == null) {
      return;
    }
    final WbCanvasElement? element = document.byId(_pageId, id);
    if (element == null) {
      return;
    }
    final Offset delta = screen - _gestureStartScreen;
    final double rotationY =
        _normalizeDegrees(start.transform.rotationY + delta.dx * 0.5);
    final double rotationX =
        _normalizeDegrees(start.transform.rotationX - delta.dy * 0.5);
    document.upsert(
      _pageId,
      element.copyWith(
        payload: start.copyWith(
          transform: start.transform.copyWith(
            rotationX: rotationX,
            rotationY: rotationY,
          ),
        ),
      ),
    );
    notifyListeners();
  }

  /// 角度归一化到 (-180, 180]（保护 3D 编辑页滑杆范围与数值可读性）。
  static double _normalizeDegrees(double degrees) {
    final double wrapped = degrees % 360;
    if (wrapped > 180) {
      return wrapped - 360;
    }
    if (wrapped <= -180) {
      return wrapped + 360;
    }
    return wrapped;
  }

  /// 表面涂色命中处理；返回 true 表示本次按下已被消费（命中 3D 元素）。
  bool _paintRender3dFace(WbCanvasElement element, Offset world) {
    if (element.type != WbElementKind.render3d) {
      return false;
    }
    final Object? payload = element.payload;
    if (payload is! Wb3dScene) {
      return false;
    }
    // 世界 → 元素内容坐标：逆 fit 变换（口径与 `professional_painter` 一致）。
    final double fit = Wb3dProjector.contentFit(element.bounds.size);
    final Offset local = world - element.bounds.topLeft;
    final Offset contentPoint =
        (local - Offset(element.width / 2, element.height / 2)) / fit +
            const Offset(150, 150);
    final Wb3dProjection projection = Wb3dProjector.project(
      scene: payload,
      size: const Size(300, 300),
      colors: WbThemeColors.lightDefaults,
    );
    final int? faceIndex =
        Wb3dProjector.hitTest(projection.faces, contentPoint);
    if (faceIndex == null) {
      return true;
    }
    final Map<int, Color> next = Map<int, Color>.of(payload.faceColors);
    final Color painted = Color(_render3dPaintColor);
    if (next[faceIndex] == painted) {
      next.remove(faceIndex);
    } else {
      next[faceIndex] = painted;
    }
    _beginEdit();
    document.upsert(
      _pageId,
      element.copyWith(payload: payload.copyWith(faceColors: next)),
    );
    _commitEdit();
    notifyListeners();
    return true;
  }

  void _captureOriginals() {
    _gestureOriginals = <_ElementSnapshot>[
      for (final WbCanvasElement e in selectedElements)
        _ElementSnapshot(
          id: e.id,
          x: e.x,
          y: e.y,
          width: e.width,
          height: e.height,
          points: e.points,
        ),
    ];
  }

  void _appendStrokePoint(Offset world) {
    final List<Offset>? stroke = _pendingStroke;
    if (stroke == null) {
      return;
    }
    final double minDistance = 1.5 / _scale;
    if (stroke.isNotEmpty && (world - stroke.last).distance < minDistance) {
      return;
    }
    stroke.add(world);
    if (onInkPreview != null) {
      _inkThrottle.schedule(_emitInkPreview);
    }
    notifyListeners();
  }

  /// 发出笔迹增量预览（[onInkPreview] 出口；增量 = 未发送区间）。
  void _emitInkPreview() {
    final void Function(Map<String, dynamic> preview)? callback = onInkPreview;
    final String? strokeId = _pendingStrokeId;
    final List<Offset>? stroke = _pendingStroke;
    if (callback == null || strokeId == null || stroke == null) {
      return;
    }
    if (_inkPreviewSentCount >= stroke.length) {
      return;
    }
    final bool highlight = _tool == WbCanvasTool.highlighter;
    final List<Offset> delta =
        stroke.sublist(_inkPreviewSentCount, stroke.length);
    _inkPreviewSentCount = stroke.length;
    callback(<String, dynamic>{
      'kind': 'ink',
      'strokeId': strokeId,
      'pageId': _pageId,
      'points': <List<double>>[
        for (final Offset p in delta) <double>[p.dx, p.dy],
      ],
      'style': <String, dynamic>{
        'color': highlight ? _highlightColor : _penColor,
        'width': highlight ? 14 : _penWidth,
      },
      'highlight': highlight,
    });
  }

  void _applyMove(Offset screenDelta) {
    if (_gestureOriginals.isEmpty) {
      return;
    }
    final Offset worldDelta = screenDelta / _scale;
    for (final _ElementSnapshot original in _gestureOriginals) {
      final WbCanvasElement? element = document.byId(_pageId, original.id);
      if (element == null || element.locked || isLockedByOther(original.id)) {
        continue;
      }
      final WbCanvasElement moved;
      if (element.type == WbElementKind.connector ||
          element.type == WbElementKind.drawing) {
        // 连线 / 笔迹的点为世界绝对坐标，平移时同步更新。
        moved = element.copyWith(
          x: original.x + worldDelta.dx,
          y: original.y + worldDelta.dy,
          points: <Offset>[
            for (final Offset p in original.points) p + worldDelta,
          ],
        );
      } else {
        moved = element.copyWith(
          x: original.x + worldDelta.dx,
          y: original.y + worldDelta.dy,
        );
      }
      document.upsert(_pageId, moved);
    }
    if (onTransformPreview != null) {
      _transformThrottle.schedule(_emitTransformPreviews);
    }
    notifyListeners();
  }

  void _applyScale(Offset screen) {
    final Rect? startBounds = _gestureStartBounds;
    final WbSelectionHandle? handle = _activeHandle;
    if (startBounds == null || handle == null || _gestureOriginals.isEmpty) {
      return;
    }
    final Offset world = screenToWorld(screen);
    const double minSize = 8;
    double left = startBounds.left;
    double top = startBounds.top;
    double right = startBounds.right;
    double bottom = startBounds.bottom;
    if (handle.movesLeft) {
      left = math.min(world.dx, right - minSize);
    }
    if (handle.movesRight) {
      right = math.max(world.dx, left + minSize);
    }
    if (handle.movesTop) {
      top = math.min(world.dy, bottom - minSize);
    }
    if (handle.movesBottom) {
      bottom = math.max(world.dy, top + minSize);
    }
    final double sx =
        startBounds.width <= 0 ? 1 : (right - left) / startBounds.width;
    final double sy =
        startBounds.height <= 0 ? 1 : (bottom - top) / startBounds.height;
    final double anchorX =
        handle.movesLeft ? startBounds.right : startBounds.left;
    final double anchorY =
        handle.movesTop ? startBounds.bottom : startBounds.top;
    for (final _ElementSnapshot original in _gestureOriginals) {
      final WbCanvasElement? element = document.byId(_pageId, original.id);
      if (element == null || element.locked || isLockedByOther(original.id)) {
        continue;
      }
      final WbCanvasElement scaled;
      if (element.type == WbElementKind.connector ||
          element.type == WbElementKind.drawing) {
        // 连线 / 笔迹的点随外接矩形同步缩放（与元素矩形同一线性映射）。
        scaled = element.copyWith(
          x: anchorX + (original.x - anchorX) * sx,
          y: anchorY + (original.y - anchorY) * sy,
          width: math.max(1, original.width * sx),
          height: math.max(1, original.height * sy),
          points: <Offset>[
            for (final Offset p in original.points)
              Offset(
                anchorX + (p.dx - anchorX) * sx,
                anchorY + (p.dy - anchorY) * sy,
              ),
          ],
        );
      } else {
        scaled = element.copyWith(
          x: anchorX + (original.x - anchorX) * sx,
          y: anchorY + (original.y - anchorY) * sy,
          width: math.max(1, original.width * sx),
          height: math.max(1, original.height * sy),
        );
      }
      document.upsert(_pageId, scaled);
    }
    if (onTransformPreview != null) {
      _transformThrottle.schedule(_emitTransformPreviews);
    }
    notifyListeners();
  }

  /// 发出变换预览（[onTransformPreview] 出口；目标几何逐元素外发）。
  void _emitTransformPreviews() {
    final void Function(Map<String, dynamic> preview)? callback =
        onTransformPreview;
    if (callback == null) {
      return;
    }
    int sent = 0;
    for (final _ElementSnapshot original in _gestureOriginals) {
      if (sent >= maxTransformPreviews) {
        break;
      }
      final WbCanvasElement? element = document.byId(_pageId, original.id);
      if (element == null) {
        continue;
      }
      callback(<String, dynamic>{
        'kind': 'transform',
        'elementId': element.id,
        'pageId': _pageId,
        'x': element.x,
        'y': element.y,
        'w': element.width,
        'h': element.height,
      });
      sent++;
    }
  }

  void _updateMarquee() {
    final Rect marquee = Rect.fromPoints(_gestureStartScreen, _lastScreen);
    _marqueeRect = marquee;
    final Rect worldRect = Rect.fromPoints(
      screenToWorld(marquee.topLeft),
      screenToWorld(marquee.bottomRight),
    );
    final Set<String> hits = <String>{
      for (final WbCanvasElement e in elements)
        if (e.visible && !e.locked && e.bounds.overlaps(worldRect)) e.id,
    };
    _selection?.select(<String>{..._marqueeBaseSelection, ...hits});
    notifyListeners();
  }

  void _eraseAt(Offset world) {
    // 远端锁元素不参与命中（`hitTestElement` 默认过滤）——橡皮擦跳过。
    final WbCanvasElement? hit = hitTestElement(world);
    if (hit == null) {
      return;
    }
    if (document.remove(_pageId, hit.id)) {
      _selection?.remove(hit.id);
      textCache.invalidate(hit.id);
      // 逐批提交（M2）：手势中按 [selectionInterval] 节流发中间批次，
      // 抬笔终态 flush（见 `handlePointerUp` 的 erase 分支）；未注入
      // 提交出口时零开销（不建定时器）。
      if (onLocalCommit != null) {
        _eraseThrottle.schedule(_emitEraseBatch);
      }
      notifyListeners();
    }
  }

  /// 发出擦除批次（中间节流批次 / 抬笔终态 flush 共用）。
  ///
  /// 与上次外发快照（[_eraseLastEmitSnapshot]）diff 本批删除集合；
  /// 中间批次不入撤销栈（抬笔时 `_commitEdit` 以整段入栈一个单元）。
  void _emitEraseBatch() {
    final void Function(WbCanvasCommitBatch batch)? callback = onLocalCommit;
    final List<WbCanvasElement>? base = _eraseLastEmitSnapshot;
    if (callback == null || base == null) {
      return;
    }
    final List<String> removed = _diffRemovedIds(base, elements);
    _eraseLastEmitSnapshot = List<WbCanvasElement>.of(elements);
    if (removed.isEmpty) {
      return;
    }
    callback(WbCanvasCommitBatch(pageId: _pageId, removedIds: removed));
  }

  /// 快照与当前页元素 id 集之差（快照中残余者视为删除）。
  static List<String> _diffRemovedIds(
    List<WbCanvasElement> before,
    List<WbCanvasElement> now,
  ) {
    final Map<String, WbCanvasElement> beforeById = <String, WbCanvasElement>{
      for (final WbCanvasElement e in before) e.id: e,
    };
    for (final WbCanvasElement e in now) {
      beforeById.remove(e.id);
    }
    return beforeById.keys.toList(growable: false);
  }

  void _finishStroke() {
    final List<Offset>? points = _pendingStroke;
    final String? strokeId = _pendingStrokeId;
    _pendingStroke = null;
    _pendingStrokeId = null;
    if (points == null || points.length < 2) {
      _resetGestureState();
      notifyListeners();
      return;
    }
    final bool highlight = _tool == WbCanvasTool.highlighter;
    // Douglas-Peucker 抽稀（落定前；世界坐标亚像素公差）——与增量
    // 预览的原始点位无关，终态元素点集更紧凑。
    final List<Offset> simplified =
        _simplifyStroke(points, strokeSimplifyTolerance);
    final Rect bounds = _strokeBounds(simplified);
    final WbCanvasElement element = WbCanvasElement(
      id: strokeId ?? _nextId(),
      type: WbElementKind.drawing,
      x: bounds.left,
      y: bounds.top,
      width: bounds.width,
      height: bounds.height,
      zIndex: _nextZIndex(),
      color: highlight ? _highlightColor : _penColor,
      strokeWidth: highlight ? 14 : _penWidth,
      penStyle: highlight ? WbPenStyle.pen.id : _penStyle.id,
      points: List<Offset>.unmodifiable(simplified),
    );
    _beginEdit();
    document.upsert(_pageId, element);
    _commitEdit();
    _resetGestureState();
    notifyListeners();
  }

  static Rect _strokeBounds(List<Offset> points) {
    double minX = points.first.dx;
    double maxX = minX;
    double minY = points.first.dy;
    double maxY = minY;
    for (final Offset p in points) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Douglas-Peucker 抽稀（迭代实现；保留首尾点）。
  ///
  /// [tolerance] 为世界坐标下允许的最大偏离距离；输入少于 3 点或公差
  /// 非正时原样返回新列表。
  static List<Offset> _simplifyStroke(
    List<Offset> points,
    double tolerance,
  ) {
    final int count = points.length;
    if (count < 3 || tolerance <= 0) {
      return List<Offset>.of(points);
    }
    final List<bool> keep = List<bool>.filled(count, false);
    keep[0] = true;
    keep[count - 1] = true;
    final List<List<int>> stack = <List<int>>[
      <int>[0, count - 1],
    ];
    while (stack.isNotEmpty) {
      final List<int> range = stack.removeLast();
      final int start = range[0];
      final int end = range[1];
      double maxDistance = 0;
      int maxIndex = -1;
      for (int i = start + 1; i < end; i++) {
        final double distance = _distanceToSegment(
          points[i],
          points[start],
          points[end],
        );
        if (distance > maxDistance) {
          maxDistance = distance;
          maxIndex = i;
        }
      }
      if (maxIndex != -1 && maxDistance > tolerance) {
        keep[maxIndex] = true;
        stack.add(<int>[start, maxIndex]);
        stack.add(<int>[maxIndex, end]);
      }
    }
    return <Offset>[
      for (int i = 0; i < count; i++)
        if (keep[i]) points[i],
    ];
  }

  void _finishCreate(bool isClick, Offset screenEnd) {
    final Rect? preview = _createPreview;
    _createPreview = null;
    if (_tool == WbCanvasTool.connector) {
      _finishConnectorCreate(isClick, screenEnd);
      return;
    }
    final String type = _elementTypeForTool(_tool);
    final Size minSize = _minSizeFor(type);
    final Rect rect;
    if (!isClick &&
        preview != null &&
        preview.width >= minSize.width &&
        preview.height >= minSize.height) {
      rect = Rect.fromLTWH(
        preview.left,
        preview.top,
        preview.width,
        preview.height,
      );
    } else {
      final Size size = _defaultSizeFor(_tool);
      rect = Rect.fromCenter(
        center: _gestureStartWorld,
        width: size.width,
        height: size.height,
      );
    }
    _resetGestureState();
    if (type == WbElementKind.image && imagePicker != null) {
      // 图片工具：先拉起系统文件选择，成功后再按图片宽高比落画布。
      unawaited(_finishImageCreate(rect));
      return;
    }
    final WbCanvasElement element = _newElement(rect);
    _beginEdit();
    document.upsert(_pageId, element);
    _commitEdit();
    // 问题 4：创建类工具完成后回切选择模式。文本元素先切工具再进入编辑
    // （setTool 内部的 endTextEditing 否则会立即结束刚开启的编辑）。
    setTool(WbCanvasTool.select);
    if (element.isTextual) {
      beginTextEditing(element.id);
    }
  }

  /// 图片工具收尾（异步）：选择文件 → 解码取原始尺寸 → 按宽高比落画布。
  ///
  /// 用户取消或选择失败时不产生元素；两种分支均在末尾回切选择模式。
  Future<void> _finishImageCreate(Rect rect) async {
    final Future<String?> Function()? picker = imagePicker;
    if (picker == null) {
      return;
    }
    String? path;
    try {
      path = await picker();
    } catch (_) {
      path = null;
    }
    if (path == null || path.isEmpty || _disposed) {
      if (!_disposed) {
        setTool(WbCanvasTool.select);
      }
      return;
    }
    final ui.Image? image = await imageCache.load(path);
    if (_disposed) {
      return;
    }
    final Size target = _imageElementSize(rect.size, image);
    final WbCanvasElement element = WbCanvasElement(
      id: _nextId(),
      type: WbElementKind.image,
      x: rect.center.dx - target.width / 2,
      y: rect.center.dy - target.height / 2,
      width: target.width,
      height: target.height,
      zIndex: _nextZIndex(),
      color: WbCanvasPalette.imageFill,
      payload: _imagePayload(path, image),
    );
    _beginEdit();
    document.upsert(_pageId, element);
    _commitEdit();
    _selection?.select(<String>[element.id]);
    setTool(WbCanvasTool.select);
  }

  /// 图片元素落画布尺寸：最长边不超过 360（自然尺寸更小时保持），
  /// 各边不低于元素最小尺寸；解码失败回退手势矩形尺寸。
  static Size _imageElementSize(Size fallback, ui.Image? image) {
    const double maxSide = 360;
    const double minEdge = 40;
    if (image == null || image.width <= 0 || image.height <= 0) {
      return Size(
        math.max(fallback.width, minEdge),
        math.max(fallback.height, minEdge),
      );
    }
    final double naturalWidth = image.width.toDouble();
    final double naturalHeight = image.height.toDouble();
    final double longest = math.max(naturalWidth, naturalHeight);
    final double factor = longest > maxSide ? maxSide / longest : 1;
    return Size(
      math.max(naturalWidth * factor, minEdge),
      math.max(naturalHeight * factor, minEdge),
    );
  }

  static Map<String, dynamic> _imagePayload(String path, ui.Image? image) {
    return <String, dynamic>{
      'path': path,
      if (image != null) 'naturalWidth': image.width.toDouble(),
      if (image != null) 'naturalHeight': image.height.toDouble(),
    };
  }

  /// 双击图片元素：重选源文件并替换 payload（元素尺寸保持）。
  Future<void> _replaceImageElement(String id) async {
    final Future<String?> Function()? picker = imagePicker;
    if (picker == null) {
      return;
    }
    String? path;
    try {
      path = await picker();
    } catch (_) {
      path = null;
    }
    if (path == null || path.isEmpty || _disposed) {
      return;
    }
    final WbCanvasElement? element = document.byId(_pageId, id);
    if (element == null) {
      return;
    }
    final ui.Image? image = await imageCache.load(path);
    if (_disposed) {
      return;
    }
    _beginEdit();
    document.upsert(
        _pageId, element.copyWith(payload: _imagePayload(path, image)));
    _commitEdit();
    notifyListeners();
  }

  /// 连线创建收尾：拖拽距离达标时以起止点为线；点击 / 过短时回退水平默认线。
  void _finishConnectorCreate(bool isClick, Offset screenEnd) {
    final Offset start = _gestureStartWorld;
    final Offset rawEnd = screenToWorld(screenEnd);
    const double minLength = 6;
    final Offset end = (isClick || (rawEnd - start).distance < minLength)
        ? Offset(start.dx + 200, start.dy)
        : rawEnd;
    final Rect bounds = Rect.fromPoints(start, end);
    final WbCanvasElement element = WbCanvasElement(
      id: _nextId(),
      type: WbElementKind.connector,
      x: bounds.left,
      y: bounds.top,
      width: math.max(1, bounds.width),
      height: math.max(1, bounds.height),
      zIndex: _nextZIndex(),
      color: _penColor,
      strokeWidth: math.max(2, _penWidth),
      points: List<Offset>.unmodifiable(<Offset>[start, end]),
    );
    _beginEdit();
    document.upsert(_pageId, element);
    _commitEdit();
    _resetGestureState();
    // 问题 4：连线创建完成后回切选择模式。
    setTool(WbCanvasTool.select);
  }

  static String _elementTypeForTool(WbCanvasTool tool) {
    switch (tool) {
      case WbCanvasTool.note:
        return WbElementKind.note;
      case WbCanvasTool.text:
        return WbElementKind.text;
      case WbCanvasTool.shape:
        return WbElementKind.shape;
      case WbCanvasTool.image:
        return WbElementKind.image;
      case WbCanvasTool.connector:
        return WbElementKind.connector;
      case WbCanvasTool.render3d:
        return WbElementKind.render3d;
      case WbCanvasTool.select:
      case WbCanvasTool.hand:
      case WbCanvasTool.pen:
      case WbCanvasTool.highlighter:
      case WbCanvasTool.eraser:
        return WbElementKind.shape;
    }
  }

  static Size _minSizeFor(String type) {
    switch (type) {
      case WbElementKind.text:
        return const Size(40, 28);
      case WbElementKind.note:
        return const Size(60, 44);
      case WbElementKind.markdown:
        return const Size(240, 160);
      default:
        return const Size(24, 24);
    }
  }

  static Size _defaultSizeFor(WbCanvasTool tool) {
    switch (tool) {
      case WbCanvasTool.note:
        return const Size(180, 120);
      case WbCanvasTool.text:
        return const Size(220, 44);
      case WbCanvasTool.shape:
        return const Size(160, 120);
      case WbCanvasTool.image:
        return const Size(240, 160);
      case WbCanvasTool.connector:
        return const Size(200, 1);
      case WbCanvasTool.render3d:
        return const Size(180, 180);
      case WbCanvasTool.select:
      case WbCanvasTool.hand:
      case WbCanvasTool.pen:
      case WbCanvasTool.highlighter:
      case WbCanvasTool.eraser:
        return const Size(160, 120);
    }
  }

  int _colorForTool() {
    switch (_tool) {
      case WbCanvasTool.note:
        return _noteColor;
      case WbCanvasTool.text:
        return WbCanvasPalette.textColor;
      case WbCanvasTool.shape:
        return _shapeColor;
      case WbCanvasTool.image:
        return WbCanvasPalette.imageFill;
      case WbCanvasTool.connector:
        return _penColor;
      case WbCanvasTool.render3d:
        return _shapeColor;
      case WbCanvasTool.select:
      case WbCanvasTool.hand:
      case WbCanvasTool.pen:
      case WbCanvasTool.highlighter:
      case WbCanvasTool.eraser:
        return _shapeColor;
    }
  }

  WbCanvasElement _newElement(Rect rect) {
    final String type = _elementTypeForTool(_tool);
    final Size minSize = _minSizeFor(type);
    return WbCanvasElement(
      id: _nextId(),
      type: type,
      x: rect.left,
      y: rect.top,
      width: math.max(minSize.width, rect.width),
      height: math.max(minSize.height, rect.height),
      zIndex: _nextZIndex(),
      color: _colorForTool(),
      shapeKind: _shapeKind.id,
      strokeWidth: 2,
    );
  }

  // ---- 文本编辑 ---------------------------------------------------------

  String? _editingElementId;

  /// 正在编辑的元素 id（null 表示无编辑）。
  String? get editingElementId => _editingElementId;

  /// 正在编辑的元素（无编辑返回 null）。
  WbCanvasElement? get editingElement {
    final String? id = _editingElementId;
    if (id == null) {
      return null;
    }
    return document.byId(_pageId, id);
  }

  /// 进入文本编辑（记录撤销快照；空文本会在结束时清理元素）。
  ///
  /// 闸门（M2）：远端软锁持有者非本端时拒绝进入并提示
  /// [onLockedElementTap]；通过后请求编辑锁（[onEditLockRequest]）。
  void beginTextEditing(String id) {
    final WbCanvasElement? element = document.byId(_pageId, id);
    if (element == null || !element.isTextual || _editingElementId == id) {
      return;
    }
    if (isLockedByOther(id)) {
      onLockedElementTap?.call(element);
      return;
    }
    endTextEditing();
    _beginEdit();
    _editingElementId = id;
    onEditLockRequest?.call(id);
    notifyListeners();
  }

  /// 实时更新编辑中的文本（每键写入模型，painter 即时预览）。
  void updateEditingText(String text) {
    final String? id = _editingElementId;
    if (id == null) {
      return;
    }
    final WbCanvasElement? element = document.byId(_pageId, id);
    if (element == null || element.text == text) {
      return;
    }
    textCache.invalidate(id);
    document.upsert(_pageId, element.copyWith(text: text));
    notifyListeners();
  }

  /// 提交编辑文本并退出编辑态。
  void commitTextEditing(String text) {
    updateEditingText(text);
    endTextEditing();
  }

  /// 文本布局全量失效：清空文本布局缓存并通知重绘。
  ///
  /// 系统字体变化后调用（Web CanvasKit 动态下载 CJK 回退字体就绪时），
  /// 让缺字形段落按新字体重新排版。监听挂载在 `CanvasView`（Widget 层，
  /// binding 必然已初始化），避免控制器在无绑定环境构造时报错。
  void invalidateTextLayouts() {
    textCache.clear();
    // Markdown 布局缓存与字体强相关（Web CJK 回退字体就绪后需重排）。
    WbMarkdownRenderCache.clear();
    notifyListeners();
  }

  /// 结束文本编辑（提交；空文本元素删除）。
  ///
  /// 退出时释放编辑锁（[onEditLockRelease]）。
  void endTextEditing() {
    final String? id = _editingElementId;
    if (id == null) {
      return;
    }
    _editingElementId = null;
    onEditLockRelease?.call(id);
    final WbCanvasElement? element = document.byId(_pageId, id);
    if (element != null && element.text.trim().isEmpty) {
      document.remove(_pageId, id);
      _selection?.remove(id);
      textCache.invalidate(id);
    }
    _commitEdit();
    notifyListeners();
  }

  // ---- 编辑命令 ---------------------------------------------------------

  final List<List<WbCanvasElement>> _undoStack = <List<WbCanvasElement>>[];
  final List<List<WbCanvasElement>> _redoStack = <List<WbCanvasElement>>[];
  final List<WbCanvasElement> _clipboard = <WbCanvasElement>[];
  int _sequence = 0;
  int _documentRevision = 0;

  /// 元素 id 前缀（`wb-el-<ns>-N`；ns 为本实例命名空间，见 [_idNamespace]）。
  static const String _elementIdPrefix = 'wb-el-';

  /// 本实例的元素 id 命名空间（6 位随机 + 2 位序号 base36；方案 B）。
  ///
  /// 协同多端各自只生成本命名空间下的 id（远端 id 只应用不生成），从根上
  /// 杜绝两端独立编号（旧 `wb-el-N`）同号覆盖 / 误删；与旧格式 id 天然
  /// 不同号，加载旧文档无需迁移。
  final String _idNamespace = _generateIdNamespace();

  /// 命名空间实例序号（同进程内两实例的命名空间必然不同）。
  static int _namespaceSerial = 0;

  /// 生成本实例元素 id 命名空间（base36：6 位随机 + 2 位序号）。
  static String _generateIdNamespace() {
    const String alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final math.Random random = math.Random();
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 6; i++) {
      buffer.write(alphabet[random.nextInt(alphabet.length)]);
    }
    buffer.write((++_namespaceSerial % 1296).toRadixString(36).padLeft(2, '0'));
    return buffer.toString();
  }

  /// 文档修订号：元素真实变更时递增（编辑 / 撤销重做 / 整板加载）。
  ///
  /// 供未保存脏标记比较（`board_file_service.dart`）；pan / zoom / 选择等
  /// 视口与交互通知不递增，避免误标脏。
  int get documentRevision => _documentRevision;

  /// 是否可撤销。
  bool get canUndo => _undoStack.isNotEmpty;

  /// 是否可重做。
  bool get canRedo => _redoStack.isNotEmpty;

  /// 撤销栈深度（测试 / 调试）。
  int get undoDepth => _undoStack.length;

  /// 删除选中元素（Delete / Backspace）。
  void deleteSelected() {
    final Set<String> ids = selectedIds;
    if (ids.isEmpty) {
      return;
    }
    endTextEditing();
    _beginEdit();
    document.removeMany(_pageId, ids);
    for (final String id in ids) {
      textCache.invalidate(id);
    }
    _selection?.clear();
    _commitEdit();
    notifyListeners();
  }

  /// 复制选中元素到内部剪贴板（Ctrl+C）。
  void copySelection() {
    final List<WbCanvasElement> selected = selectedElements;
    if (selected.isEmpty) {
      return;
    }
    _clipboard
      ..clear()
      ..addAll(selected);
  }

  /// 剪切选中元素（Ctrl+X）。
  void cutSelection() {
    if (selectedElements.isEmpty) {
      return;
    }
    copySelection();
    deleteSelected();
  }

  /// 粘贴（Ctrl+V；偏移 [pasteOffset] 并选中新元素）。
  void pasteClipboard() {
    if (_clipboard.isEmpty) {
      return;
    }
    endTextEditing();
    _beginEdit();
    final List<String> newIds = <String>[];
    int z = _nextZIndex();
    for (final WbCanvasElement source in _clipboard) {
      final WbCanvasElement copy = source.copyWith(
        id: _nextId(),
        x: source.x + pasteOffset,
        y: source.y + pasteOffset,
        zIndex: z++,
      );
      document.upsert(_pageId, copy);
      newIds.add(copy.id);
    }
    _selection?.select(newIds);
    _commitEdit();
    notifyListeners();
  }

  /// 插入元素（视口中心；专业元素用 [payload] 携带结构模型）。
  ///
  /// [size] 为世界尺寸（小于 40 时抬升）；入撤销栈并选中新元素；
  /// 返回新元素。
  WbCanvasElement insertElement({
    required String type,
    required Size size,
    Object? payload,
  }) {
    endTextEditing();
    final Size clamped = Size(
      math.max(size.width, 40),
      math.max(size.height, 40),
    );
    final Offset center = screenToWorld(
      Offset(_viewportSize.width / 2, _viewportSize.height / 2),
    );
    _beginEdit();
    final WbCanvasElement element = WbCanvasElement(
      id: _nextId(),
      type: type,
      x: center.dx - clamped.width / 2,
      y: center.dy - clamped.height / 2,
      width: clamped.width,
      height: clamped.height,
      zIndex: _nextZIndex(),
      payload: payload,
    );
    document.upsert(_pageId, element);
    _selection?.select(<String>[element.id]);
    _commitEdit();
    notifyListeners();
    return element;
  }

  /// 批量插入元素（同一撤销单元；AI 工具调用落地 / 批量导入）。
  ///
  /// - 未提供 [WbElementSpec.position] 的非点式元素放置到视口中心，
  ///   并按序阶梯错位（避免完全重叠）；
  /// - drawing / connector 以 [WbElementSpec.points] 的世界坐标包围盒
  ///   作为几何（与手势创建一致）；
  /// - [select] 为 true 时选中全部新元素。
  List<WbCanvasElement> insertElements(
    List<WbElementSpec> specs, {
    bool select = true,
  }) {
    if (specs.isEmpty) {
      return const <WbCanvasElement>[];
    }
    endTextEditing();
    _beginEdit();
    final Offset center = screenToWorld(
      Offset(_viewportSize.width / 2, _viewportSize.height / 2),
    );
    final List<WbCanvasElement> created = <WbCanvasElement>[];
    double cascade = 0;
    for (final WbElementSpec spec in specs) {
      final WbCanvasElement element = _elementFromSpec(spec, center, cascade);
      document.upsert(_pageId, element);
      created.add(element);
      cascade += 24;
    }
    if (select) {
      _selection?.select(<String>[
        for (final WbCanvasElement e in created) e.id,
      ]);
    }
    _commitEdit();
    notifyListeners();
    return created;
  }

  /// 按创建定义构造元素（不落库；落点 / 尺寸 / 颜色缺省在此归一）。
  WbCanvasElement _elementFromSpec(
    WbElementSpec spec,
    Offset fallbackCenter,
    double cascade,
  ) {
    final Size minSize = _minSizeFor(spec.type);
    final List<Offset> rawPoints = spec.points;
    final Size size;
    final Offset topLeft;
    List<Offset> points = rawPoints;
    final bool stroke = rawPoints.length >= 2 &&
        (spec.type == WbElementKind.drawing ||
            spec.type == WbElementKind.connector);
    if (stroke) {
      // 点式元素（笔迹 / 连线）：包围盒定尺寸；未指定 position 时整体
      // 平移到视口中心（points 为世界绝对坐标，平移同步写回）。
      final Rect bounds = _strokeBounds(rawPoints);
      size = Size(
        math.max(bounds.width, minSize.width),
        math.max(bounds.height, minSize.height),
      );
      final Offset anchor = spec.position ??
          Offset(
            fallbackCenter.dx - size.width / 2 + cascade,
            fallbackCenter.dy - size.height / 2 + cascade,
          );
      final Offset delta = anchor - bounds.topLeft;
      if (delta != Offset.zero) {
        points = <Offset>[
          for (final Offset p in rawPoints) p + delta,
        ];
      }
      topLeft = anchor;
    } else {
      final Size requested = spec.size ?? _defaultSizeForType(spec.type);
      size = Size(
        math.max(requested.width, minSize.width),
        math.max(requested.height, minSize.height),
      );
      topLeft = spec.position ??
          Offset(
            fallbackCenter.dx - size.width / 2 + cascade,
            fallbackCenter.dy - size.height / 2 + cascade,
          );
    }
    return WbCanvasElement(
      id: _nextId(),
      type: spec.type,
      x: topLeft.dx,
      y: topLeft.dy,
      width: size.width,
      height: size.height,
      zIndex: _nextZIndex(),
      text: spec.text,
      color: spec.color ?? _defaultColorForType(spec.type),
      strokeWidth: spec.strokeWidth,
      shapeKind: spec.shapeKind,
      points: List<Offset>.unmodifiable(points),
      fontSize: spec.fontSize,
      textAlign: spec.textAlign,
      payload: spec.payload,
    );
  }

  /// 类型默认尺寸（与手势创建 `_defaultSizeFor` 对齐）。
  static Size _defaultSizeForType(String type) {
    switch (type) {
      case WbElementKind.note:
        return const Size(180, 120);
      case WbElementKind.text:
        return const Size(220, 44);
      case WbElementKind.markdown:
        return const Size(420, 320);
      default:
        return const Size(160, 120);
    }
  }

  /// 类型默认主色（继承控制器当前调色板选择）。
  int _defaultColorForType(String type) {
    switch (type) {
      case WbElementKind.note:
        return _noteColor;
      case WbElementKind.text:
        return WbCanvasPalette.textColor;
      case WbElementKind.drawing:
      case WbElementKind.connector:
        return _penColor;
      default:
        return _shapeColor;
    }
  }

  /// 批量删除元素（一个撤销单元；AI 工具调用落地等批量场景）。
  ///
  /// 返回实际删除的元素数；不存在的 id 忽略。
  int removeElements(Iterable<String> ids) {
    final Set<String> targets = <String>{
      for (final String id in ids)
        if (document.byId(_pageId, id) != null) id,
    };
    if (targets.isEmpty) {
      return 0;
    }
    endTextEditing();
    _beginEdit();
    document.removeMany(_pageId, targets);
    for (final String id in targets) {
      _selection?.remove(id);
      textCache.invalidate(id);
    }
    _commitEdit();
    notifyListeners();
    return targets.length;
  }

  /// 当前页面元素快照（AI 执行前留档供撤销恢复；元素不可变，浅拷贝安全）。
  List<WbCanvasElement> pageSnapshot() => document.snapshot(_pageId);

  /// 用整页元素快照替换当前页（AI 撤销 / 恢复用；入撤销栈）。
  void restoreElements(List<WbCanvasElement> elements) {
    endTextEditing();
    _beginEdit();
    document.replace(_pageId, elements);
    // 收敛选择：移除快照中已不存在的选中 id。
    final Set<String> existing = <String>{
      for (final WbCanvasElement e in elements) e.id,
    };
    final Set<String> selected = _selection?.ids ?? const <String>{};
    for (final String id in selected.toList(growable: false)) {
      if (!existing.contains(id)) {
        _selection?.remove(id);
      }
    }
    _commitEdit();
    notifyListeners();
  }

  /// 整板加载（打开本地 `.wbd` 文件后调用）。
  ///
  /// 逐页替换内存文档、清空撤销/重做栈与选择、提升 id 序列防冲突；
  /// 不触碰视口（缩放 / 平移保持现状）。引擎 store 存在时尽力同步。
  void loadBoardData(Map<String, List<WbCanvasElement>> byPage) {
    _flushRender3dSizeSession();
    cancelGesture();
    endTextEditing();
    for (final MapEntry<String, List<WbCanvasElement>> entry
        in byPage.entries) {
      document.replace(entry.key, entry.value);
      // 历史数据 zIndex 可能与列表顺序不一致：加载时按 zIndex 升序
      // 恢复列表顺序（列表尾 = 最上层），与面板显示口径对齐。
      _resortPageByZIndex(entry.key);
      final List<WbCanvasElement> list = document.snapshot(entry.key);
      try {
        _store?.replaceAll(entry.key, list);
      } catch (_) {
        // 引擎错误：保持内存内容（与 setPage 的容错口径一致）。
      }
      for (final WbCanvasElement element in list) {
        textCache.invalidate(element.id);
      }
    }
    _undoStack.clear();
    _redoStack.clear();
    _selection?.clear();
    _adoptIdSequence(byPage.values);
    _documentRevision++;
    notifyListeners();
  }

  /// 更新单个元素（[transform] 返回新元素；入撤销栈）。
  ///
  /// 供图层面板等外部消费者统一写回；id 不存在返回 null，
  /// transform 返回原实例（未变更）时不产生撤销记录。
  WbCanvasElement? updateElement(
    String id,
    WbCanvasElement Function(WbCanvasElement element) transform,
  ) {
    final WbCanvasElement? element = document.byId(_pageId, id);
    if (element == null) {
      return null;
    }
    final WbCanvasElement next = transform(element);
    if (identical(next, element)) {
      return element;
    }
    _beginEdit();
    document.upsert(_pageId, next);
    textCache.invalidate(id);
    _commitEdit();
    notifyListeners();
    return next;
  }

  /// 删除单个元素（图层面板「删除」；入撤销栈）。
  void removeElement(String id) {
    if (document.byId(_pageId, id) == null) {
      return;
    }
    endTextEditing();
    _beginEdit();
    document.remove(_pageId, id);
    _selection?.remove(id);
    textCache.invalidate(id);
    _commitEdit();
    notifyListeners();
  }

  /// 应用图层新顺序（[topFirstIds] 顶层在前；zIndex = 列表下标）。
  ///
  /// 供图层面板拖拽 / 菜单排序统一回写。物理重排页面列表（列表尾 =
  /// 最上层，与 `zIndex` 升序一致——绘制与命中均按列表顺序），并重
  /// 编号 `zIndex` = 下标；未列出的元素保持相对顺序置于下层。顺序与
  /// `zIndex` 均无变化时不产生撤销记录。
  void applyZOrder(List<String> topFirstIds) {
    if (topFirstIds.isEmpty) {
      return;
    }
    final List<WbCanvasElement> list = document.snapshot(_pageId);
    if (list.isEmpty) {
      return;
    }
    final Map<String, WbCanvasElement> byId = <String, WbCanvasElement>{
      for (final WbCanvasElement e in list) e.id: e,
    };
    // 绘制列表底层在前：显示序（顶层在前）反向追加；未列出者置底。
    final List<WbCanvasElement> listed = <WbCanvasElement>[];
    final Set<String> listedIds = <String>{};
    for (int i = topFirstIds.length - 1; i >= 0; i--) {
      final WbCanvasElement? element = byId[topFirstIds[i]];
      if (element == null || !listedIds.add(element.id)) {
        continue;
      }
      listed.add(element);
    }
    if (listed.isEmpty) {
      return;
    }
    final List<WbCanvasElement> next = <WbCanvasElement>[
      for (final WbCanvasElement e in list)
        if (!listedIds.contains(e.id)) e,
      ...listed,
    ];
    // 重编号：zIndex = 列表下标（「列表顺序与 zIndex 一致」不变量）。
    for (int i = 0; i < next.length; i++) {
      final WbCanvasElement element = next[i];
      if (element.zIndex != i) {
        next[i] = element.copyWith(zIndex: i);
      }
    }
    if (_sameElements(list, next)) {
      return;
    }
    _beginEdit();
    document.replace(_pageId, next);
    _commitEdit();
    notifyListeners();
  }

  /// 原地创建副本（Ctrl+D；偏移 16）。
  void duplicateSelection() {
    final List<WbCanvasElement> selected = selectedElements;
    if (selected.isEmpty) {
      return;
    }
    endTextEditing();
    _beginEdit();
    final List<String> newIds = <String>[];
    int z = _nextZIndex();
    for (final WbCanvasElement source in selected) {
      final WbCanvasElement copy = source.copyWith(
        id: _nextId(),
        x: source.x + 16,
        y: source.y + 16,
        zIndex: z++,
      );
      document.upsert(_pageId, copy);
      newIds.add(copy.id);
    }
    _selection?.select(newIds);
    _commitEdit();
    notifyListeners();
  }

  /// 设置选中元素主色（上下文工具栏「颜色」；入撤销栈）。
  void setSelectionColor(int color) {
    final List<WbCanvasElement> selected = selectedElements;
    if (selected.isEmpty) {
      return;
    }
    _beginEdit();
    for (final WbCanvasElement element in selected) {
      if (element.color == color) {
        continue;
      }
      document.upsert(_pageId, element.copyWith(color: color));
      textCache.invalidate(element.id);
    }
    _commitEdit();
    notifyListeners();
  }

  /// 对齐选中元素（≥ 2 个生效；入撤销栈）。
  ///
  /// [mode]：`left` / `hcenter` / `right` / `top` / `vcenter` / `bottom`。
  void alignSelection(String mode) {
    final List<WbCanvasElement> selected = selectedElements;
    final Rect? bounds = selectionBounds;
    if (selected.length < 2 || bounds == null) {
      return;
    }
    _beginEdit();
    for (final WbCanvasElement element in selected) {
      final WbCanvasElement moved = switch (mode) {
        'left' => element.copyWith(x: bounds.left),
        'hcenter' => element.copyWith(x: bounds.center.dx - element.width / 2),
        'right' => element.copyWith(x: bounds.right - element.width),
        'top' => element.copyWith(y: bounds.top),
        'vcenter' => element.copyWith(y: bounds.center.dy - element.height / 2),
        'bottom' => element.copyWith(y: bounds.bottom - element.height),
        _ => element,
      };
      document.upsert(_pageId, moved);
    }
    _commitEdit();
    notifyListeners();
  }

  /// 分布选中元素（≥ 3 个生效；入撤销栈）。
  ///
  /// [axis]：`horizontal` 按左边界排序后均分间隙；`vertical` 按上边界。
  void distributeSelection(String axis) {
    final List<WbCanvasElement> selected = selectedElements;
    if (selected.length < 3) {
      return;
    }
    final bool horizontal = axis != 'vertical';
    final List<WbCanvasElement> ordered = List<WbCanvasElement>.of(selected)
      ..sort((WbCanvasElement a, WbCanvasElement b) =>
          horizontal ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
    final Rect first = ordered.first.bounds;
    final Rect last = ordered.last.bounds;
    final double spanStart = horizontal ? first.left : first.top;
    final double spanEnd = horizontal ? last.right : last.bottom;
    double extents = 0;
    for (final WbCanvasElement element in ordered) {
      extents += horizontal ? element.width : element.height;
    }
    final double gap = (spanEnd - spanStart - extents) / (ordered.length - 1);
    _beginEdit();
    double cursor = spanStart;
    for (final WbCanvasElement element in ordered) {
      final double extent = horizontal ? element.width : element.height;
      document.upsert(
        _pageId,
        horizontal ? element.copyWith(x: cursor) : element.copyWith(y: cursor),
      );
      cursor += extent + gap;
    }
    _commitEdit();
    notifyListeners();
  }

  /// 置顶选中元素（列表尾 = 最上层；入撤销栈）。
  void bringSelectionToFront() {
    final Set<String> ids = selectedIds;
    if (ids.isEmpty) {
      return;
    }
    _beginEdit();
    final List<WbCanvasElement> list = document.snapshot(_pageId);
    final List<WbCanvasElement> selected = <WbCanvasElement>[
      for (final WbCanvasElement e in list)
        if (ids.contains(e.id)) e,
    ];
    final List<WbCanvasElement> rest = <WbCanvasElement>[
      for (final WbCanvasElement e in list)
        if (!ids.contains(e.id)) e,
    ];
    int z = _nextZIndex();
    document.replace(_pageId, <WbCanvasElement>[
      ...rest,
      for (final WbCanvasElement e in selected) e.copyWith(zIndex: z++),
    ]);
    _commitEdit();
    notifyListeners();
  }

  /// 置底选中元素（列表首 = 最底层；入撤销栈）。
  void sendSelectionToBack() {
    final Set<String> ids = selectedIds;
    if (ids.isEmpty) {
      return;
    }
    _beginEdit();
    final List<WbCanvasElement> list = document.snapshot(_pageId);
    final List<WbCanvasElement> selected = <WbCanvasElement>[
      for (final WbCanvasElement e in list)
        if (ids.contains(e.id)) e,
    ];
    final List<WbCanvasElement> rest = <WbCanvasElement>[
      for (final WbCanvasElement e in list)
        if (!ids.contains(e.id)) e,
    ];
    int minZ = 0;
    for (final WbCanvasElement e in list) {
      if (e.zIndex < minZ) {
        minZ = e.zIndex;
      }
    }
    int z = minZ - selected.length;
    document.replace(_pageId, <WbCanvasElement>[
      for (final WbCanvasElement e in selected) e.copyWith(zIndex: z++),
      ...rest,
    ]);
    _commitEdit();
    notifyListeners();
  }

  /// 设置选中文本类元素字号（便签 / 文本；夹取 8–144；入撤销栈）。
  void setSelectionFontSize(double size) {
    final double clamped = size.clamp(8.0, 144.0).toDouble();
    final List<WbCanvasElement> selected = <WbCanvasElement>[
      for (final WbCanvasElement e in selectedElements)
        if (e.isTextual) e,
    ];
    if (selected.isEmpty) {
      return;
    }
    _beginEdit();
    for (final WbCanvasElement element in selected) {
      document.upsert(_pageId, element.copyWith(fontSize: clamped));
      textCache.invalidate(element.id);
    }
    _commitEdit();
    notifyListeners();
  }

  /// 设置选中文本类元素水平对齐（`left` / `center` / `right`；入撤销栈）。
  void setSelectionTextAlign(String align) {
    final String normalized = switch (align) {
      'center' => 'center',
      'right' => 'right',
      _ => 'left',
    };
    final List<WbCanvasElement> selected = <WbCanvasElement>[
      for (final WbCanvasElement e in selectedElements)
        if (e.isTextual) e,
    ];
    if (selected.isEmpty) {
      return;
    }
    _beginEdit();
    for (final WbCanvasElement element in selected) {
      if (element.textAlign == normalized) {
        continue;
      }
      document.upsert(_pageId, element.copyWith(textAlign: normalized));
      textCache.invalidate(element.id);
    }
    _commitEdit();
    notifyListeners();
  }

  /// 撤销（Ctrl+Z）。
  void undo() {
    _flushRender3dSizeSession();
    if (_undoStack.isEmpty) {
      return;
    }
    cancelGesture();
    endTextEditing();
    final List<WbCanvasElement> before = _undoStack.removeLast();
    _redoStack.add(document.snapshot(_pageId));
    document.replace(_pageId, before);
    _store?.replaceAll(_pageId, before);
    _documentRevision++;
    notifyListeners();
  }

  /// 重做（Ctrl+Shift+Z）。
  void redo() {
    _flushRender3dSizeSession();
    if (_redoStack.isEmpty) {
      return;
    }
    cancelGesture();
    endTextEditing();
    final List<WbCanvasElement> after = _redoStack.removeLast();
    _undoStack.add(document.snapshot(_pageId));
    document.replace(_pageId, after);
    _store?.replaceAll(_pageId, after);
    _documentRevision++;
    notifyListeners();
  }

  /// 方向键微调选中元素（[shift] 时步长 10，否则 1）。
  void nudgeSelection(Offset direction, {bool shift = false}) {
    if (!hasSelection) {
      return;
    }
    final double step = shift ? 10 : 1;
    _beginEdit();
    for (final WbCanvasElement element in selectedElements) {
      document.upsert(
        _pageId,
        element.copyWith(
          x: element.x + direction.dx * step,
          y: element.y + direction.dy * step,
        ),
      );
    }
    _commitEdit();
    notifyListeners();
  }

  /// 键盘快捷键统一入口（由 `CanvasView` 的 Focus 转发）。
  ///
  /// 返回 true 表示已处理（应阻止事件继续传播）。
  bool handleShortcut(
    LogicalKeyboardKey key, {
    bool ctrl = false,
    bool shift = false,
    bool alt = false,
    bool meta = false,
  }) {
    final bool primary = ctrl || meta;
    // 交互关闭（M3 权限收窄）：仅保留视图键（Ctrl+0 / Ctrl+1 / Ctrl±），
    // 编辑类快捷键一律忽略（返回 false 继续传播）。
    if (!_interactionEnabled) {
      final bool viewKey = primary &&
          (key == LogicalKeyboardKey.digit0 ||
              key == LogicalKeyboardKey.digit1 ||
              key == LogicalKeyboardKey.equal ||
              key == LogicalKeyboardKey.add ||
              key == LogicalKeyboardKey.numpadAdd ||
              key == LogicalKeyboardKey.minus ||
              key == LogicalKeyboardKey.numpadSubtract);
      if (!viewKey) {
        return false;
      }
    }
    if (primary && key == LogicalKeyboardKey.keyZ) {
      if (shift) {
        redo();
      } else {
        undo();
      }
      return true;
    }
    if (primary && key == LogicalKeyboardKey.keyA) {
      selectAll();
      return true;
    }
    if (primary && key == LogicalKeyboardKey.keyC) {
      copySelection();
      return true;
    }
    if (primary && key == LogicalKeyboardKey.keyX) {
      cutSelection();
      return true;
    }
    if (primary && key == LogicalKeyboardKey.keyV) {
      pasteClipboard();
      return true;
    }
    if (primary && key == LogicalKeyboardKey.keyD) {
      duplicateSelection();
      return true;
    }
    if (primary && key == LogicalKeyboardKey.digit0) {
      resetView();
      return true;
    }
    if (primary && key == LogicalKeyboardKey.digit1) {
      fitToContent();
      return true;
    }
    if (primary &&
        (key == LogicalKeyboardKey.equal ||
            key == LogicalKeyboardKey.add ||
            key == LogicalKeyboardKey.numpadAdd)) {
      zoomBy(1.2);
      return true;
    }
    if (primary &&
        (key == LogicalKeyboardKey.minus ||
            key == LogicalKeyboardKey.numpadSubtract)) {
      zoomBy(1 / 1.2);
      return true;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      deleteSelected();
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      cancelGesture();
      endTextEditing();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      nudgeSelection(const Offset(-1, 0), shift: shift);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      nudgeSelection(const Offset(1, 0), shift: shift);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      nudgeSelection(const Offset(0, -1), shift: shift);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      nudgeSelection(const Offset(0, 1), shift: shift);
      return true;
    }
    return false;
  }

  // ---- 协同（sync）远端应用入口 -------------------------------------------

  /// 远端软锁快照（elementId → 持有者 userId；不含本端持有的锁）。
  Map<String, String> _remoteLocks = <String, String>{};

  /// 远端软锁状态（元素 id → 持有者 userId；不含本端持有的锁）。
  Map<String, String> get remoteLocks =>
      Map<String, String>.unmodifiable(_remoteLocks);

  /// 刷新远端软锁缓存（宿主在协同状态变化时注入；仅变化时通知重绘）。
  void refreshRemoteLocks(Map<String, String> locks) {
    if (_sameStringMap(_remoteLocks, locks)) {
      return;
    }
    _remoteLocks = Map<String, String>.of(locks);
    notifyListeners();
  }

  /// 元素是否被**他人**软锁持有（本端持有 / 无锁返回 false）。
  bool isLockedByOther(String elementId) {
    final String? holder = _remoteLocks[elementId];
    return holder != null && holder.isNotEmpty;
  }

  /// 元素软锁持有者（无锁返回 null）。
  String? lockHolderOf(String elementId) => _remoteLocks[elementId];

  /// 字符串映射浅比较（锁刷新去抖）。
  static bool _sameStringMap(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (final MapEntry<String, String> entry in a.entries) {
      if (b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  /// 远端笔迹鬼影（strokeId → 增量缓冲；`onRemotePreviews` 消费）。
  final Map<String, WbRemoteInkGhost> _remoteInkGhosts =
      <String, WbRemoteInkGhost>{};

  /// 远端变换鬼影（elementId → 目标几何；绘制时临时变换不落模型）。
  final Map<String, WbRemoteTransformGhost> _remoteTransformGhosts =
      <String, WbRemoteTransformGhost>{};

  /// 远端删除淡出（elementId → 删除前快照；[remoteFadeOutSeconds] 淡出）。
  final Map<String, WbRemoteFadeOut> _remoteFadeOuts =
      <String, WbRemoteFadeOut>{};

  /// 已终态元素 id 记忆（FIFO；丢弃迟到的预览帧）。
  final Set<String> _finalizedStrokeIds = <String>{};

  /// 远端预览入口：批量应用（宿主把 `onRemotePreviews` 批次转交）。
  ///
  /// 逐条按 `kind` 分流；pageId 非当前页 / 已终态 / 非法载荷直接丢弃
  /// （跨端 pageId 命名空间不同，经 `previewPageMatches` 页序后缀近似匹配）。
  /// 光标 / 选区由独立 presence 层消费（本控制器不处理）。
  void applyRemotePreviews(List<dynamic> previews) {
    if (_disposed || previews.isEmpty) {
      return;
    }
    for (final Object? preview in previews) {
      if (preview is Map<String, dynamic>) {
        _applyRemotePreview(preview);
      } else if (preview is Map) {
        _applyRemotePreview(Map<String, dynamic>.from(preview));
      }
    }
  }

  void _applyRemotePreview(Map<String, dynamic> preview) {
    // 跨端 pageId 命名空间不同（发送端本地板 id 派生 vs 本机）：
    // 经页序后缀近似匹配放行同页序帧（见 preview_page_match.dart）。
    final Object? pageId = preview['pageId'];
    if (!previewPageMatches(pageId, _pageId)) {
      return; // 非当前页：丢弃。
    }
    switch (preview['kind']) {
      case 'ink':
        _applyRemoteInkFrame(preview);
      case 'transform':
        _applyRemoteTransformFrame(preview);
      default:
        break;
    }
  }

  void _applyRemoteInkFrame(Map<String, dynamic> preview) {
    final Object? strokeIdValue = preview['strokeId'];
    final String strokeId = strokeIdValue is String ? strokeIdValue : '';
    if (strokeId.isEmpty || _finalizedStrokeIds.contains(strokeId)) {
      return;
    }
    final List<Offset>? delta = _decodePreviewPoints(preview['points']);
    if (delta == null || delta.isEmpty) {
      return;
    }
    final WbRemoteInkGhost ghost = _remoteInkGhosts.putIfAbsent(
      strokeId,
      () => _remoteInkGhostFactory(preview, strokeId),
    );
    ghost.append(delta, maxPoints: remoteInkGhostMaxPoints);
    _ensurePreviewTicker();
    notifyListeners();
  }

  /// 按预览载荷构造笔迹鬼影（样式缺省：深灰细线）。
  WbRemoteInkGhost _remoteInkGhostFactory(
    Map<String, dynamic> preview,
    String strokeId,
  ) {
    final Object? rawStyle = preview['style'];
    final Map<dynamic, dynamic> style =
        rawStyle is Map ? rawStyle : const <dynamic, dynamic>{};
    final Object? rawColor = style['color'];
    final int color = rawColor is num ? rawColor.toInt() : 0xFF1F2933;
    final Object? rawWidth = style['width'];
    final double width = rawWidth is num ? rawWidth.toDouble() : 2;
    return WbRemoteInkGhost(
      strokeId: strokeId,
      color: color,
      strokeWidth: width,
      highlight: preview['highlight'] == true,
    );
  }

  void _applyRemoteTransformFrame(Map<String, dynamic> preview) {
    final Object? idValue = preview['elementId'];
    final String elementId = idValue is String ? idValue : '';
    if (elementId.isEmpty || _finalizedStrokeIds.contains(elementId)) {
      return; // 空 id / 已终态（迟到帧）丢弃。
    }
    final WbCanvasElement? local = document.byId(_pageId, elementId);
    if (local == null) {
      return; // 本地尚无元素（创建中）：忽略，等终态 op。
    }
    // 本地正在同元素手势（拖动 / 缩放）：本地优先，不被远端覆盖。
    for (final _ElementSnapshot snapshot in _gestureOriginals) {
      if (snapshot.id == elementId) {
        return;
      }
    }
    final double? x = _previewDouble(preview['x']);
    final double? y = _previewDouble(preview['y']);
    final double? w = _previewDouble(preview['w']);
    final double? h = _previewDouble(preview['h']);
    if (x == null || y == null || w == null || h == null) {
      return;
    }
    final WbRemoteTransformGhost ghost = _remoteTransformGhosts.putIfAbsent(
      elementId,
      () => WbRemoteTransformGhost(elementId: elementId),
    );
    ghost
      ..x = x
      ..y = y
      ..width = w
      ..height = h
      ..touch();
    _ensurePreviewTicker();
    notifyListeners();
  }

  /// 记忆已终态元素 id（FIFO 淘汰；丢弃迟到的同 id 预览帧）。
  void _markFinalizedStrokeId(String elementId) {
    if (elementId.isEmpty) {
      return;
    }
    _finalizedStrokeIds.add(elementId);
    if (_finalizedStrokeIds.length > finalizedIdsCapacity) {
      // Dart 默认 Set 为 LinkedHashSet：迭代序 = 插入序。
      _finalizedStrokeIds.remove(_finalizedStrokeIds.first);
    }
  }

  /// 解析预览点位载荷（`[[dx, dy], ...]`；坏点跳过、全坏返回 null）。
  static List<Offset>? _decodePreviewPoints(Object? raw) {
    if (raw is! List || raw.isEmpty) {
      return null;
    }
    final List<Offset> points = <Offset>[];
    for (final Object? entry in raw) {
      if (entry is List && entry.length >= 2) {
        final double? dx = _previewDouble(entry[0]);
        final double? dy = _previewDouble(entry[1]);
        if (dx != null && dy != null) {
          points.add(Offset(dx, dy));
        }
      }
    }
    return points;
  }

  static double? _previewDouble(Object? value) =>
      value is num ? value.toDouble() : null;

  // ---- 远端预览读取面（painter / 叠加层消费） -----------------------------

  /// 远端笔迹鬼影快照（按插入序）。
  List<WbRemoteInkGhost> get remoteInkGhosts =>
      List<WbRemoteInkGhost>.unmodifiable(_remoteInkGhosts.values);

  /// 远端删除淡出快照（按插入序）。
  List<WbRemoteFadeOut> get remoteFadeOuts =>
      List<WbRemoteFadeOut>.unmodifiable(_remoteFadeOuts.values);

  /// 远端变换叠加（按 elementId 读取；无鬼影 / 几何近似相同返回 null）。
  ///
  /// 返回映射到目标几何的绘制副本（点集线性映射）供 painter 临时
  /// 变换绘制——不落模型。
  WbRemoteTransformOverlay? remoteTransformOverlay(
    WbCanvasElement element,
  ) {
    final WbRemoteTransformGhost? ghost = _remoteTransformGhosts[element.id];
    if (ghost == null) {
      return null;
    }
    final Rect current = element.bounds;
    final double width = math.max(1, ghost.width);
    final double height = math.max(1, ghost.height);
    if ((ghost.x - current.left).abs() < 0.5 &&
        (ghost.y - current.top).abs() < 0.5 &&
        (width - current.width).abs() < 0.5 &&
        (height - current.height).abs() < 0.5) {
      return null; // 目标与现行几何几乎相同：无需叠加。
    }
    final WbCanvasElement mapped;
    if (element.type == WbElementKind.connector ||
        element.type == WbElementKind.drawing) {
      final double sx = current.width <= 0 ? 1 : width / current.width;
      final double sy = current.height <= 0 ? 1 : height / current.height;
      mapped = element.copyWith(
        x: ghost.x,
        y: ghost.y,
        width: width,
        height: height,
        points: <Offset>[
          for (final Offset p in element.points)
            Offset(
              ghost.x + (p.dx - current.left) * sx,
              ghost.y + (p.dy - current.top) * sy,
            ),
        ],
      );
    } else {
      mapped = element.copyWith(
        x: ghost.x,
        y: ghost.y,
        width: width,
        height: height,
      );
    }
    return WbRemoteTransformOverlay(element: mapped, alpha: ghost.alpha);
  }

  /// 是否持有任何远端预览叠加（测试 / 调试）。
  bool get hasRemoteOverlays =>
      _remoteInkGhosts.isNotEmpty ||
      _remoteTransformGhosts.isNotEmpty ||
      _remoteFadeOuts.isNotEmpty;

  // ---- 鬼影 / 淡出时钟（按需启停） ----------------------------------------

  /// 启动鬼影时钟（幂等；有叠加期间自续期，见 [_onPreviewTick]）。
  void _ensurePreviewTicker() {
    if (_previewTicker != null || _disposed) {
      return;
    }
    _previewTicker = _previewTimerFactory(_previewTickInterval, _onPreviewTick);
  }

  void _onPreviewTick() {
    _previewTicker = null;
    if (_disposed) {
      return;
    }
    final double seconds = _previewTickInterval.inMilliseconds / 1000;
    bool dirty = false;
    _remoteInkGhosts.removeWhere((String _, WbRemoteInkGhost ghost) {
      if (ghost.advance(seconds)) {
        dirty = true;
      }
      return ghost.expired;
    });
    _remoteTransformGhosts.removeWhere(
      (String _, WbRemoteTransformGhost ghost) {
        if (ghost.advance(seconds)) {
          dirty = true;
        }
        return ghost.expired;
      },
    );
    _remoteFadeOuts.removeWhere((String _, WbRemoteFadeOut fade) {
      if (fade.advance(seconds)) {
        dirty = true;
      }
      return fade.expired;
    });
    if (dirty) {
      notifyListeners();
    }
    if (_remoteInkGhosts.isNotEmpty ||
        _remoteTransformGhosts.isNotEmpty ||
        _remoteFadeOuts.isNotEmpty) {
      _ensurePreviewTicker();
    }
  }

  /// 应用远端元素 upsert（协同入口；M1：LWW 覆盖本地未落定显示）。
  ///
  /// [pageId] 为 op 携带的目标页（null / 空串回退当前页——旧发送端
  /// 与未分页帧兼容）；目标页非当前页时仅写入文档（不触发可视效果）。
  /// 与本地编辑结构隔离（**防回发第一层**）：不经过 `_beginEdit` /
  /// `_commitEdit` 提交漏斗、不生成出口批次、不触碰撤销 / 重做栈——
  /// 远端变更不占用本端撤销历史。内容变化递增 [documentRevision]（脏标记）。
  /// 元素落位后按 `zIndex` 升序恢复目标页列表顺序（列表尾 = 最上层），
  /// 使远端层级调整与本端绘制 / 命中口径一致。
  void applyRemoteElement(WbCanvasElement element, {String? pageId}) {
    if (_disposed || element.id.isEmpty) {
      return;
    }
    final String target = (pageId == null || pageId.isEmpty) ? _pageId : pageId;
    // 终态 op 到达：清除对应笔迹 / 变换鬼影并记忆终态 id（丢弃迟到帧）。
    _remoteInkGhosts.remove(element.id);
    _remoteTransformGhosts.remove(element.id);
    _markFinalizedStrokeId(element.id);
    document.upsert(target, element);
    _resortPageByZIndex(target);
    textCache.invalidate(element.id);
    try {
      _store?.upsert(target, element);
    } catch (_) {
      // 存储同步失败不影响本地状态。
    }
    _documentRevision++;
    notifyListeners();
  }

  /// 应用远端元素删除（协同入口；不存在的 id 静默忽略）。
  ///
  /// [pageId] 为 op 携带的目标页；线格式（`el:{id}:exists=false`）不带
  /// 页信息时按元素 id 跨页查找所在页（元素 id 全局唯一）。命中选中
  /// 集合时同步剔除（避免幽灵选中）；同样不进入撤销栈。
  void applyRemoteRemove(String elementId, {String? pageId}) {
    if (_disposed || elementId.isEmpty) {
      return;
    }
    final String target = (pageId == null || pageId.isEmpty)
        ? (document.findPageOf(elementId) ?? _pageId)
        : pageId;
    final bool isCurrent = target == _pageId;
    // 终态删除：清除鬼影 / 记忆终态 id，并保留删除前快照做淡出。
    final WbCanvasElement? before = document.byId(target, elementId);
    _remoteInkGhosts.remove(elementId);
    _remoteTransformGhosts.remove(elementId);
    _markFinalizedStrokeId(elementId);
    final bool removed = document.remove(target, elementId);
    if (removed && before != null && isCurrent) {
      _remoteFadeOuts[elementId] = WbRemoteFadeOut(element: before);
      _ensurePreviewTicker();
    }
    textCache.invalidate(elementId);
    try {
      _store?.remove(target, elementId);
    } catch (_) {
      // 存储同步失败不影响本地状态。
    }
    if (isCurrent && (_selection?.contains(elementId) ?? false)) {
      _selection?.toggle(elementId);
    }
    if (removed) {
      _documentRevision++;
    }
    notifyListeners();
  }

  // ---- 内部工具 ---------------------------------------------------------

  /// 按 `zIndex` 升序重排 [pageId] 列表（同级保持现有相对顺序）。
  ///
  /// 远端 upsert / 整板加载把 `zIndex` 当优先级广播，元素可能乱序
  /// 到达；绘制与命中按列表顺序（尾 = 最上层）——此方法收敛两者。
  /// 仅重排列表，不改写 `zIndex` 值（乱序到达时重编号会破坏收敛）。
  void _resortPageByZIndex(String pageId) {
    final List<WbCanvasElement> list = document.snapshot(pageId);
    if (list.length < 2) {
      return;
    }
    final List<int> order = List<int>.generate(list.length, (int i) => i)
      ..sort((int a, int b) {
        final int byZ = list[a].zIndex.compareTo(list[b].zIndex);
        return byZ != 0 ? byZ : a.compareTo(b);
      });
    bool changed = false;
    for (int i = 0; i < order.length; i++) {
      if (order[i] != i) {
        changed = true;
        break;
      }
    }
    if (!changed) {
      return;
    }
    document.replace(
      pageId,
      <WbCanvasElement>[for (final int i in order) list[i]],
    );
  }

  void _beginEdit() {
    _editSnapshot = document.snapshot(_pageId);
  }

  void _commitEdit({bool emitLocal = true}) {
    final List<WbCanvasElement>? before = _editSnapshot;
    _editSnapshot = null;
    if (before == null || _sameElements(before, elements)) {
      return;
    }
    _persistChanges(before);
    _documentRevision++;
    _undoStack.add(before);
    if (_undoStack.length > maxUndoDepth) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
    if (emitLocal) {
      // 协同出口：与撤销栈入栈同一批落地（防回发窗口内跳过）；
      // 擦除手势的中间批次已由 `_emitEraseBatch` 先行外发，终态传
      // `emitLocal: false` 防重复。
      _emitLocalCommit(before);
    }
  }

  /// 生成落定提交批次并经 [onLocalCommit] 交给协同出口。
  ///
  /// 与 `_persistChanges` 相同 diff 语义（快照比 identical）：当前元素中
  /// 新增 / 变更者为 upsert，快照中残余者视为删除。防回发第二层：
  /// [isRemoteApplying] 为 true（远端应用窗口）时跳过。
  void _emitLocalCommit(List<WbCanvasElement> before) {
    final void Function(WbCanvasCommitBatch batch)? callback = onLocalCommit;
    if (callback == null || (isRemoteApplying?.call() ?? false)) {
      return;
    }
    final Map<String, WbCanvasElement> beforeById = <String, WbCanvasElement>{
      for (final WbCanvasElement e in before) e.id: e,
    };
    final List<WbCanvasElement> upserts = <WbCanvasElement>[];
    for (final WbCanvasElement element in elements) {
      final WbCanvasElement? old = beforeById.remove(element.id);
      if (old == null || !identical(old, element)) {
        upserts.add(element);
      }
    }
    if (upserts.isEmpty && beforeById.isEmpty) {
      return;
    }
    callback(WbCanvasCommitBatch(
      pageId: _pageId,
      upserts: upserts,
      removedIds: beforeById.keys.toList(growable: false),
    ));
  }

  void _restoreEditSnapshot() {
    final List<WbCanvasElement>? snapshot = _editSnapshot;
    _editSnapshot = null;
    if (snapshot != null) {
      document.replace(_pageId, snapshot);
    }
  }

  static bool _sameElements(
    List<WbCanvasElement> a,
    List<WbCanvasElement> b,
  ) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }

  void _persistChanges(List<WbCanvasElement> before) {
    final WbCanvasStore? store = _store;
    if (store == null || _pageId.isEmpty) {
      return;
    }
    try {
      final Map<String, WbCanvasElement> beforeById = <String, WbCanvasElement>{
        for (final WbCanvasElement e in before) e.id: e,
      };
      for (final WbCanvasElement element in elements) {
        final WbCanvasElement? old = beforeById.remove(element.id);
        if (old == null || !identical(old, element)) {
          store.upsert(_pageId, element);
        }
      }
      for (final String id in beforeById.keys) {
        store.remove(_pageId, id);
      }
    } catch (_) {
      // 存储同步失败不影响本地状态。
    }
  }

  void _maybeDoubleTap(Offset screen) {
    if (_spacePressed) {
      return;
    }
    final DateTime now = DateTime.now();
    final DateTime? lastTime = _lastTapTime;
    final Offset? lastPosition = _lastTapPosition;
    final bool isDouble = lastTime != null &&
        lastPosition != null &&
        now.difference(lastTime) < const Duration(milliseconds: 350) &&
        (screen - lastPosition).distance < 24;
    _lastTapTime = now;
    _lastTapPosition = screen;
    if (!isDouble) {
      return;
    }
    _lastTapTime = null;
    _lastTapPosition = null;
    handleDoubleClick(screen);
  }

  String _nextId() => '$_elementIdPrefix$_idNamespace-${++_sequence}';

  /// 提升 id 序列到**本实例命名空间**下已加载元素的最大 N（防新建 id 冲突）。
  ///
  /// 仅识别 `wb-el-<本实例 ns>-N`（同实例重载自身保存的文档时兜底）；其他
  /// 命名空间与旧格式 `wb-el-N` 的新建 id 天然不同号，无需提升。
  void _adoptIdSequence(Iterable<List<WbCanvasElement>> pages) {
    final String prefix = '$_elementIdPrefix$_idNamespace-';
    for (final List<WbCanvasElement> list in pages) {
      for (final WbCanvasElement element in list) {
        final String id = element.id;
        if (!id.startsWith(prefix)) {
          continue;
        }
        final int? parsed = int.tryParse(id.substring(prefix.length));
        if (parsed != null && parsed > _sequence) {
          _sequence = parsed;
        }
      }
    }
  }

  int _nextZIndex() {
    int maxZ = 0;
    for (final WbCanvasElement e in elements) {
      if (e.zIndex > maxZ) {
        maxZ = e.zIndex;
      }
    }
    return maxZ + 1;
  }

  double _clampScale(double value) =>
      math.min(math.max(value, minScale), maxScale);

  @override
  void dispose() {
    _disposed = true;
    _render3dSizeCommitTimer?.cancel();
    _render3dSizeCommitTimer = null;
    _inkThrottle.cancel();
    _transformThrottle.cancel();
    _cursorThrottle.cancel();
    _selectionThrottle.cancel();
    _eraseThrottle.cancel();
    _viewportThrottle.cancel();
    _previewTicker?.cancel();
    _previewTicker = null;
    _selection?.removeListener(_onSelectionChanged);
    if (_ownsImageCache) {
      imageCache.dispose();
    }
    super.dispose();
  }
}

/// 默认一次性定时器工厂（生产路径）。
Timer _oneShotTimer(Duration interval, void Function() onTick) =>
    Timer(interval, onTick);

/// 预览节流器：首沿立即交付 + 窗口内抑制 + 尾沿补发。
///
/// 用于协同预览出口（笔迹 / 变换 / 光标 / 选区 / 擦除批次）：高频
/// 事件按固定窗口合并，首沿保证即时反馈；定时器由注入工厂创建
/// （测试可手动驱动）。尾沿执行的是最近一次 [schedule] 传入的回调。
class _PreviewThrottle {
  _PreviewThrottle(this.interval, this._createTimer);

  /// 节流窗口。
  final Duration interval;

  /// 一次性定时器工厂（注入：测试手动驱动）。
  final Timer Function(Duration interval, void Function() onTick) _createTimer;

  Timer? _timer;
  void Function()? _pending;

  /// 请求交付：窗口空闲时立即执行；窗口内只保留最后一次（尾沿补发）。
  void schedule(void Function() onTick) {
    if (_timer == null) {
      onTick();
      _timer = _createTimer(interval, _onWindowEnd);
      return;
    }
    _pending = onTick;
  }

  /// 取消挂起窗口（手势结束 / 释放时调用；尾沿不再补发）。
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }

  /// 是否有挂起窗口（测试 / 调试）。
  bool get isActive => _timer != null;

  void _onWindowEnd() {
    _timer = null;
    final void Function()? pending = _pending;
    _pending = null;
    if (pending == null) {
      return;
    }
    pending();
    _timer = _createTimer(interval, _onWindowEnd);
  }
}

/// 远端笔迹鬼影：按 strokeId 缓冲增量点，连续绘制（缺口直连兜底）。
class WbRemoteInkGhost {
  WbRemoteInkGhost({
    required this.strokeId,
    required this.color,
    required this.strokeWidth,
    required this.highlight,
  });

  /// 预生成元素 id（终态 op 到达时按此 id 清除）。
  final String strokeId;

  /// 线色（ARGB）。
  final int color;

  /// 线宽（荧光笔 = 14）。
  final double strokeWidth;

  /// 是否荧光笔（半透明叠加绘制）。
  final bool highlight;

  /// 已接收的增量点（世界坐标，按到达序拼接）。
  final List<Offset> points = <Offset>[];

  /// 距上次更新的秒数（时钟 tick 累积）。
  double idleSeconds = 0;

  /// 当前不透明度（TTL 内恒 1，之后线性淡出）。
  double alpha = 1;

  /// 是否已过期（可移除）。
  bool expired = false;

  /// 追加增量点（超出上限丢弃最旧点，防长笔迹内存膨胀）。
  void append(List<Offset> delta, {required int maxPoints}) {
    points.addAll(delta);
    if (points.length > maxPoints) {
      points.removeRange(0, points.length - maxPoints);
    }
    idleSeconds = 0;
    alpha = 1;
    expired = false;
  }

  /// 推进时钟；返回 true 表示透明度变化（需要重绘）。
  bool advance(double seconds) {
    final double before = alpha;
    idleSeconds += seconds;
    const double ttl = WbCanvasController.remoteGhostTtlSeconds;
    const double fade = WbCanvasController.remoteGhostFadeSeconds;
    double next = 1;
    bool done = false;
    if (idleSeconds > ttl) {
      final double progress = (idleSeconds - ttl) / fade;
      if (progress >= 1) {
        next = 0;
        done = true;
      } else {
        next = 1 - progress;
      }
    }
    alpha = next;
    expired = done;
    return done || alpha != before;
  }
}

/// 远端变换鬼影：目标几何（不落模型；绘制时临时变换替换几何）。
class WbRemoteTransformGhost {
  WbRemoteTransformGhost({required this.elementId});

  /// 目标元素 id。
  final String elementId;

  /// 目标几何（世界坐标）。
  double x = 0;
  double y = 0;
  double width = 1;
  double height = 1;

  /// 距上次更新的秒数（时钟 tick 累积）。
  double idleSeconds = 0;

  /// 当前不透明度（TTL 内恒 1，之后线性淡出）。
  double alpha = 1;

  /// 是否已过期（可移除）。
  bool expired = false;

  /// 刷新（新目标帧到达）。
  void touch() {
    idleSeconds = 0;
    alpha = 1;
    expired = false;
  }

  /// 推进时钟；返回 true 表示透明度变化（需要重绘）。
  bool advance(double seconds) {
    final double before = alpha;
    idleSeconds += seconds;
    const double ttl = WbCanvasController.remoteGhostTtlSeconds;
    const double fade = WbCanvasController.remoteGhostFadeSeconds;
    double next = 1;
    bool done = false;
    if (idleSeconds > ttl) {
      final double progress = (idleSeconds - ttl) / fade;
      if (progress >= 1) {
        next = 0;
        done = true;
      } else {
        next = 1 - progress;
      }
    }
    alpha = next;
    expired = done;
    return done || alpha != before;
  }
}

/// 远端删除淡出（表现层）：保留删除前快照逐帧降低不透明度。
class WbRemoteFadeOut {
  WbRemoteFadeOut({required this.element});

  /// 删除前的元素快照（元素不可变，引用安全）。
  final WbCanvasElement element;

  /// 已播放的秒数（时钟 tick 累积）。
  double elapsedSeconds = 0;

  /// 是否已结束（可移除）。
  bool expired = false;

  /// 当前不透明度（线性衰减到 0）。
  double get alpha {
    const double duration = WbCanvasController.remoteFadeOutSeconds;
    if (duration <= 0) {
      return 0;
    }
    final double progress = elapsedSeconds / duration;
    return progress >= 1 ? 0 : 1 - progress;
  }

  /// 推进时钟；淡出每帧都在变化 → 恒返回 true（需要重绘）。
  bool advance(double seconds) {
    elapsedSeconds += seconds;
    if (elapsedSeconds >= WbCanvasController.remoteFadeOutSeconds) {
      expired = true;
    }
    return true;
  }
}

/// 远端变换叠加（painter 消费）：替换几何的绘制副本 + 不透明度。
class WbRemoteTransformOverlay {
  const WbRemoteTransformOverlay({required this.element, required this.alpha});

  /// 映射到目标几何的绘制副本（点集已线性映射）。
  final WbCanvasElement element;

  /// 不透明度（TTL 内恒 1；淡出时 < 1，painter 以 saveLayer 处理）。
  final double alpha;
}
