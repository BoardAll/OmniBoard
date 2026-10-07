/// Web 上下文工具栏浮层宿主（P3：工具栏 UX 对齐）。
///
/// 监听共享 [WbCanvasController]：选区出现 → [showWbContextToolbar] 以
/// 「选中元素屏幕矩形」为锚点浮出；此后浮层长生命周期保活，经
/// [WbContextToolbarHandle.update] / [WbContextToolbarHandle.setVisible]
/// 增量驱动——隐藏只走 Offstage（组件 State 不销毁：拖动中不显示、拖动
/// 结束后显示；菜单 / 确认框交互期间命令不因 unmount 丢失）。
///
/// - 锚点 = 画布 RenderBox 全局原点 + `worldRectToScreen(selectionBounds)`
///   （本组件直接包裹画布，其 RenderBox 即画布视口，与控制器屏幕坐标同系）；
/// - 类型解析：`document.byId(pageId, id)` 的元素 type → [WbContextTargetType]
///   （drawing 等无上下文类型回落 unknown，落入默认条目集）；
/// - 画布手势（拖动 / 缩放 / 框选 / 绘制…）进行中隐藏，落回 idle 后更新
///   锚点并显示；浮层不设全屏遮罩——空白点击穿透到画布，「点击空白收起」
///   由「清空选区 → 本宿主隐藏」承接（与桌面画布默认手势一致）；
/// - 路由级弹层（对话框 / 菜单 / 底部弹层）期间隐藏：监听所属路由
///   [ModalRoute.secondaryAnimation]（弹层均为 opaque=false 的 PopupRoute，
///   经次级动画 0↔1 感知推入 / 退出），并以「路由非当前」兜底；弹层退出
///   回落 0 后恢复显示——期间不销毁浮层，命令不丢失；
/// - 命令统一透传 [onCommand]（Web 端映射画布 API 子集）；「选色再点表面」
///   待应用样式不做接线（颜色即时应用，偏差已记录）。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_canvas/canvas/canvas_controller.dart';
import 'package:whiteboard_canvas/canvas/canvas_model.dart';
import 'package:whiteboard_canvas/toolbar/context_toolbar.dart';
import 'package:whiteboard_canvas/toolbar/toolbar_config.dart';

/// 上下文工具栏浮层宿主（包裹画布子组件）。
class WbWebContextToolbarHost extends StatefulWidget {
  /// 创建宿主。
  const WbWebContextToolbarHost({
    super.key,
    required this.controller,
    required this.child,
    this.enabled = true,
    this.onCommand,
  });

  /// 共享画布控制器（选区 / 视口 / 文档来源）。
  final WbCanvasController controller;

  /// 是否允许显示浮层（被移出房间的只读态传 false）。
  final bool enabled;

  /// 命令回调（透传给浮层）。
  final ValueChanged<WbToolbarCommand>? onCommand;

  /// 画布子组件。
  final Widget child;

  @override
  State<WbWebContextToolbarHost> createState() =>
      WbWebContextToolbarHostState();
}

/// 上下文工具栏宿主状态（公开：宿主页面经 [GlobalKey] 持有关闭出口）。
class WbWebContextToolbarHostState extends State<WbWebContextToolbarHost> {
  WbContextToolbarHandle? _handle;

  /// 最近一次同步的浮层内容（无变化时跳过重复驱动）。
  WbContextTarget? _lastTarget;
  Rect? _lastAnchor;
  Color? _lastColor;
  double? _lastWidth;
  bool _lastVisible = false;

  /// 所属路由的次级动画（路由级弹层推入 / 退出监测）。
  Animation<double>? _secondary;

  bool _syncScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scheduleSync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Animation<double>? secondary =
        ModalRoute.of(context)?.secondaryAnimation;
    if (!identical(secondary, _secondary)) {
      _secondary?.removeListener(_scheduleSync);
      _secondary = secondary;
      _secondary?.addListener(_scheduleSync);
    }
    // 路由状态变化（isCurrent / 次级动画对象更换）后重同步：弹层退出
    // 完成（路由恢复当前、次级动画回落 0）即恢复显示。
    _scheduleSync();
  }

  @override
  void didUpdateWidget(WbWebContextToolbarHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_scheduleSync);
      widget.controller.addListener(_scheduleSync);
      _destroy();
      _scheduleSync();
    } else if (oldWidget.enabled != widget.enabled) {
      _scheduleSync();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scheduleSync);
    _secondary?.removeListener(_scheduleSync);
    _destroy();
    super.dispose();
  }

  /// 控制器 / 路由动画的高频通知合并到帧末（一帧最多同步一次）。
  void _scheduleSync() {
    // 同步要落到帧末：显式确保下一帧存在（生产环境画布重绘会带帧，
    // 测试与静止场景下避免回调悬挂不触发）。
    WidgetsBinding.instance.scheduleFrame();
    if (_syncScheduled) {
      return;
    }
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (mounted) {
        _sync();
      }
    });
  }

  /// 隐藏当前浮层（外部出口：打开路由级弹层 / 面板前调用）。
  ///
  /// 仅隐藏不销毁（State 保活）；弹层退出（次级动画回落 0）或后续画布
  /// 通知经 [_sync] 自动恢复显示。
  void close() => _hide(_handle);

  /// 隐藏浮层（保活；无浮层 / 已销毁时仅复位显示标记）。
  void _hide(WbContextToolbarHandle? handle) {
    _lastVisible = false;
    if (handle == null || handle.isClosed) {
      return;
    }
    handle.setVisible(false);
  }

  /// 终极销毁浮层与缓存（dispose / 控制器更换时清理）。
  void _destroy() {
    final WbContextToolbarHandle? handle = _handle;
    _handle = null;
    _lastTarget = null;
    _lastAnchor = null;
    _lastColor = null;
    _lastWidth = null;
    _lastVisible = false;
    handle?.close();
  }

  /// 同步浮层到当前选区 / 锚点（增量驱动：不销毁重建）。
  void _sync() {
    final WbContextToolbarHandle? handle = _handle;
    if (!widget.enabled) {
      _hide(handle);
      return;
    }
    final Set<String> ids = widget.controller.selectedIds;
    if (ids.isEmpty) {
      _hide(handle);
      return;
    }
    // 路由级弹层（对话框 / 菜单）推入中 / 已推入 → 隐藏；退出完成
    // （路由恢复当前且次级动画回落 0）后经本方法恢复显示。
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    final double? secondaryValue = route?.secondaryAnimation?.value;
    if (route != null &&
        (!route.isCurrent || (secondaryValue ?? 0) > 0)) {
      _hide(handle);
      return;
    }
    // 画布手势（拖动 / 缩放 / 框选 / 绘制…）全程隐藏；落回 idle 后
    // （控制器通知）更新锚点并显示——「移动过程中不显示、结束后显示」。
    if (widget.controller.gesture != WbCanvasGesture.idle) {
      _hide(handle);
      return;
    }
    final List<String> sorted = ids.toList()..sort();
    final WbContextTarget target = WbContextTarget.fromSelection(
      sorted,
      resolver: _resolveType,
    );
    if (target.isEmpty) {
      _hide(handle);
      return;
    }
    final Rect? anchor = _anchorFor();
    if (anchor == null) {
      _hide(handle);
      return;
    }
    // 单选元素当前样式（选色 / 线宽弹层选中态展示）。
    Color? currentColor;
    double? currentLineWidth;
    if (sorted.length == 1) {
      final WbCanvasElement? element = widget.controller.document.byId(
        widget.controller.pageId,
        sorted.first,
      );
      if (element != null) {
        currentColor = Color(element.color);
        currentLineWidth = element.strokeWidth;
      }
    }
    if (handle != null &&
        !handle.isClosed &&
        _lastVisible &&
        _sameTarget(_lastTarget, target) &&
        _lastAnchor == anchor &&
        _lastColor == currentColor &&
        _lastWidth == currentLineWidth) {
      return;
    }
    if (handle == null || handle.isClosed) {
      _handle = showWbContextToolbar(
        context,
        target: target,
        anchor: anchor,
        currentColor: currentColor,
        currentLineWidth: currentLineWidth,
        onCommand: widget.onCommand,
      );
    } else {
      handle.update(
        target: target,
        anchor: anchor,
        currentColor: currentColor,
        currentLineWidth: currentLineWidth,
      );
      handle.setVisible(true);
    }
    _lastTarget = target;
    _lastAnchor = anchor;
    _lastColor = currentColor;
    _lastWidth = currentLineWidth;
    _lastVisible = true;
  }

  /// 选中元素全局矩形（画布视口原点 + 控制器屏幕坐标）。
  Rect? _anchorFor() {
    final Rect? bounds = widget.controller.selectionBounds;
    if (bounds == null) {
      return null;
    }
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return null;
    }
    return widget.controller
        .worldRectToScreen(bounds)
        .shift(renderObject.localToGlobal(Offset.zero));
  }

  /// 元素类型 → 上下文类型（未知 / 无上下文类型回落 unknown）。
  WbContextTargetType _resolveType(String elementId) {
    final WbCanvasElement? element = widget.controller.document.byId(
      widget.controller.pageId,
      elementId,
    );
    if (element == null) {
      return WbContextTargetType.unknown;
    }
    return switch (element.type) {
      WbElementKind.note => WbContextTargetType.note,
      WbElementKind.text => WbContextTargetType.text,
      WbElementKind.shape => WbContextTargetType.shape,
      WbElementKind.connector => WbContextTargetType.connector,
      WbElementKind.image => WbContextTargetType.image,
      WbElementKind.render3d => WbContextTargetType.render3d,
      WbElementKind.function => WbContextTargetType.function,
      WbElementKind.render2d => WbContextTargetType.render2d,
      WbElementKind.table => WbContextTargetType.table,
      WbElementKind.mindmap => WbContextTargetType.mindmap,
      WbElementKind.flowchart => WbContextTargetType.flowchart,
      WbElementKind.markdown => WbContextTargetType.markdown,
      _ => WbContextTargetType.unknown,
    };
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 上下文目标值比较（`WbContextTarget` 无值相等语义；避开身份比较误判）。
bool _sameTarget(WbContextTarget? a, WbContextTarget? b) {
  if (identical(a, b)) {
    return true;
  }
  if (a == null || b == null) {
    return false;
  }
  if (a.type != b.type || a.count != b.count) {
    return false;
  }
  if (a.elementIds.length != b.elementIds.length) {
    return false;
  }
  for (int i = 0; i < a.elementIds.length; i++) {
    if (a.elementIds[i] != b.elementIds[i]) {
      return false;
    }
  }
  return true;
}
