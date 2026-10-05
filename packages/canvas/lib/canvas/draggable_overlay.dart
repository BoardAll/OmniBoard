/// 可拖动悬浮面板包装组件。
///
/// 用于画布上层悬浮件（工具调色板 / 迷你地图 + 缩放控件列）的自由摆放：
/// - 子面板按 [alignment] 初始停靠（附加 [padding] 边距，避免贴边），
///   [initialOffset] 可再叠加初始偏移（例如为避让其他悬浮件而上移）；
/// - 拖动走**布局级定位**（[CustomSingleChildLayout]），保证视觉位置与
///   命中区域一致——内部按钮 tap 不受影响，指针移动超过手势 slop 后
///   tap 自动取消、pan 接管；
/// - 拖动范围按父约束 clamp（含 [padding]），窗口 resize 后显示位置按
///   同一规则校正，不会逃出可视区域；
/// - （注意：不可用 `Transform.translate` 实现——其 RenderBox 边界检查
///   基于未变换坐标，会造成视觉位置上的 tap / pan 全部落空。）
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 布局解算结果：对齐基位 + 相对基位的偏移允许范围。
typedef _OverlayLayout = ({
  double baseLeft,
  double baseTop,
  double minDx,
  double maxDx,
  double minDy,
  double maxDy,
});

/// 解算面板布局（对齐基位与偏移范围；输出范围已排序，保证 min ≤ max）。
_OverlayLayout _solveLayout({
  required Size parent,
  required Size child,
  required Alignment alignment,
  required EdgeInsets padding,
}) {
  final double freeX =
      math.max(0, parent.width - child.width - padding.horizontal);
  final double freeY =
      math.max(0, parent.height - child.height - padding.vertical);
  final double baseLeft = padding.left + (alignment.x + 1) / 2 * freeX;
  final double baseTop = padding.top + (alignment.y + 1) / 2 * freeY;
  final double dx1 = padding.left - baseLeft;
  final double dx2 = parent.width - child.width - padding.right - baseLeft;
  final double dy1 = padding.top - baseTop;
  final double dy2 = parent.height - child.height - padding.bottom - baseTop;
  return (
    baseLeft: baseLeft,
    baseTop: baseTop,
    minDx: math.min(dx1, dx2),
    maxDx: math.max(dx1, dx2),
    minDy: math.min(dy1, dy2),
    maxDy: math.max(dy1, dy2),
  );
}

/// 可拖动悬浮面板包装组件。
class WbDraggableOverlay extends StatefulWidget {
  /// 创建可拖动悬浮面板。
  const WbDraggableOverlay({
    super.key,
    required this.child,
    this.alignment = Alignment.topLeft,
    this.padding = const EdgeInsets.all(12),
    this.initialOffset = Offset.zero,
    this.onMoved,
  });

  /// 被包装的面板。
  final Widget child;

  /// 初始停靠位置（相对父约束）。
  final Alignment alignment;

  /// 四周保留边距（同时作为拖动 clamp 边界）。
  final EdgeInsets padding;

  /// 初始额外偏移（在 [alignment] + [padding] 基位上叠加）。
  final Offset initialOffset;

  /// 拖动量回调（供宿主同步状态 / 校正，可空）。
  final ValueChanged<Offset>? onMoved;

  @override
  State<WbDraggableOverlay> createState() => _WbDraggableOverlayState();
}

class _WbDraggableOverlayState extends State<WbDraggableOverlay> {
  final GlobalKey _childKey = GlobalKey(debugLabel: 'wb-draggable-child');

  late Offset _offset;

  @override
  void initState() {
    super.initState();
    _offset = widget.initialOffset;
  }

  /// 子面板当前尺寸（未布局时为零；拖动发生前必然已完成布局）。
  Size _childSize() {
    final RenderObject? renderObject =
        _childKey.currentContext?.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      return renderObject.size;
    }
    return Size.zero;
  }

  void _handlePanUpdate(DragUpdateDetails details, Size parent) {
    final _OverlayLayout layout = _solveLayout(
      parent: parent,
      child: _childSize(),
      alignment: widget.alignment,
      padding: widget.padding,
    );
    setState(() {
      _offset = Offset(
        (_offset.dx + details.delta.dx).clamp(layout.minDx, layout.maxDx),
        (_offset.dy + details.delta.dy).clamp(layout.minDy, layout.maxDy),
      );
    });
    widget.onMoved?.call(details.delta);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size parent = constraints.biggest;
        return CustomSingleChildLayout(
          delegate: _WbDraggableLayoutDelegate(
            alignment: widget.alignment,
            padding: widget.padding,
            offset: _offset,
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.deferToChild,
            onPanUpdate: (DragUpdateDetails details) =>
                _handlePanUpdate(details, parent),
            child: KeyedSubtree(key: _childKey, child: widget.child),
          ),
        );
      },
    );
  }
}

/// 布局委托：child 撑满约束、按对齐基位 + 偏移落位（布局级 hit test）。
class _WbDraggableLayoutDelegate extends SingleChildLayoutDelegate {
  const _WbDraggableLayoutDelegate({
    required this.alignment,
    required this.padding,
    required this.offset,
  });

  final Alignment alignment;
  final EdgeInsets padding;
  final Offset offset;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final _OverlayLayout layout = _solveLayout(
      parent: size,
      child: childSize,
      alignment: alignment,
      padding: padding,
    );
    final double dx = offset.dx.clamp(layout.minDx, layout.maxDx);
    final double dy = offset.dy.clamp(layout.minDy, layout.maxDy);
    return Offset(layout.baseLeft + dx, layout.baseTop + dy);
  }

  @override
  bool shouldRelayout(_WbDraggableLayoutDelegate oldDelegate) =>
      alignment != oldDelegate.alignment ||
      padding != oldDelegate.padding ||
      offset != oldDelegate.offset;
}
