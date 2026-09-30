/// 画布视图：选择 / 平移 / 缩放 / 绘制 / 创建 / 编辑的完整交互画布。
///
/// 结构（由下至上）：
/// 1. [_CanvasSurface]：指针手势层（Listener）+ 绘制层（`WbCanvasPainter`
///    经 `RepaintBoundary` 隔离，控制器通知即局部重绘）；
/// 2. `_CanvasEmptyHint`：空画布提示（"画布就绪"，不拦截指针）；
/// 3. `WbCanvasTextEditor`：内联文本编辑浮层；
/// 4. `WbCanvasToolPalette`：工具调色板（左上，可拖动）；
/// 5. `WbMinimap` + `WbZoomControls`：迷你地图与缩放控件（右下，可拖动）。
///
/// 键盘：Focus（autofocus）手动分发 —— 空格临时平移、Ctrl+Z/Shift+Z、
/// Ctrl+A/C/X/V/D、Ctrl+0/1/+/-、Delete/Backspace、Esc、方向键微调；
/// 文本编辑期间除空格状态清理外全部透传给编辑层。
///
/// 演示模式（无 DLL）：控制器以内存 `WbCanvasDocument` 为权威数据驱动
/// 完整交互；引擎模式由 `WbFfiCanvasStore` 在事务提交点尽力同步。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../state/page_state.dart';
import '../state/selection_state.dart';
import 'canvas/background_painter.dart';
import 'canvas/canvas_capture.dart';
import 'canvas/canvas_controller.dart';
import 'canvas/canvas_painter.dart';
import 'canvas/canvas_text_editor.dart';
import 'canvas/canvas_tool_palette.dart';
import 'canvas/draggable_overlay.dart';
import 'canvas/minimap.dart';
import 'canvas/zoom_controls.dart';
import 'context_editors/quick_create.dart';

/// 画布视图。
///
/// `board_edit_page` 以 `const CanvasView()` 无参构造使用；测试 / 高级
/// 场景可注入 [controller] 与 [selection] 直接驱动状态（构造仍为 const）。
class CanvasView extends StatefulWidget {
  /// 创建画布视图。
  const CanvasView({
    super.key,
    this.controller,
    this.selection,
    this.showToolPalette = true,
    this.onQuickCreate,
  });

  /// 外部控制器（null 时内部创建并随 [State] 释放）。
  final WbCanvasController? controller;

  /// 外部选区（null 时从 Provider 读取 `WbSelectionState`）。
  final WbSelectionState? selection;

  /// 是否显示左上角工具面板（B3：工具栏风格二选一，'top' 风格显示）。
  final bool showToolPalette;

  /// 工具面板「更多」→ 专业元素创建回调（null 时隐藏该分组）。
  final ValueChanged<WbQuickCreateKind>? onQuickCreate;

  @override
  State<CanvasView> createState() => _CanvasViewState();
}

class _CanvasViewState extends State<CanvasView> {
  late final WbCanvasController _controller;
  late final bool _ownsController;
  final FocusNode _focusNode = FocusNode(debugLabel: 'wb-canvas');

  WbSelectionState? _selection;
  bool _wasEditing = false;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? WbCanvasController();
    _wasEditing = _controller.editingElementId != null;
    _controller.addListener(_onControllerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final WbSelectionState? selection =
        widget.selection ?? _maybeOf<WbSelectionState>(context);
    if (!identical(selection, _selection)) {
      _selection = selection;
      // postFrame 同步：避免 build / didChangeDependencies 期间触发通知。
      _schedulePostFrame(() => _controller.attachSelection(selection));
    }
    final WbPageState? pages = _maybeOf<WbPageState>(context);
    if (pages != null) {
      final String pageId = pages.currentPageId;
      if (pageId.isNotEmpty && pageId != _controller.pageId) {
        _schedulePostFrame(() => _controller.setPage(pageId));
      }
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) {
      _controller.dispose();
    }
    _focusNode.dispose();
    super.dispose();
  }

  /// 控制器状态变化：编辑结束（提交 / 取消）后把焦点交还画布，
  /// 保证快捷键持续可用。
  void _onControllerChanged() {
    final bool editing = _controller.editingElementId != null;
    if (editing == _wasEditing) {
      return;
    }
    _wasEditing = editing;
    if (editing) {
      return;
    }
    _schedulePostFrame(() {
      if (_controller.editingElementId == null && !_focusNode.hasFocus) {
        _focusNode.requestFocus();
      }
    });
  }

  void _schedulePostFrame(VoidCallback action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        action();
      }
    });
  }

  static T? _maybeOf<T>(BuildContext context) {
    try {
      return Provider.of<T>(context, listen: true);
    } on ProviderNotFoundException {
      return null;
    }
  }

  // ---- 键盘 -------------------------------------------------------------

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      if (event.logicalKey == LogicalKeyboardKey.space) {
        _controller.setSpacePressed(false);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // 文本编辑中不拦截快捷键（Esc / Ctrl+Enter 由编辑层处理）。
    if (_controller.editingElementId != null) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      _controller.setSpacePressed(true);
      return KeyEventResult.handled;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool handled = _controller.handleShortcut(
      key,
      ctrl: keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
      meta: keyboard.isMetaPressed,
    );
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  // ---- 构建 -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    // 页面背景（问题 1）：从 WbPageState 读当前页 background，随其变更
    // 经依赖刷新重建 painter；未配置时 null（回退主题画布色 + 网格）。
    final WbPageState? pages = _maybeOf<WbPageState>(context);
    final Map<String, dynamic> backgroundJson =
        pages?.currentPage?.background ?? const <String, dynamic>{};
    final WbPageBackground? background = backgroundJson.isEmpty
        ? null
        : WbPageBackground.fromJson(backgroundJson, fallback: colors.canvas);
    if (background != null && background.hasImage) {
      _controller.imageCache.request(background.imagePath);
    }
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          _controller.setViewportSize(constraints.biggest);
          // SizedBox.expand 将 Stack 约束收紧为全屏：即使未来出现非
          // positioned 子项（会使 Stack 收缩为子项尺寸），也不会塌缩布局。
          return ClipRect(
            child: SizedBox.expand(
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: _CanvasSurface(
                      controller: _controller,
                      colors: colors,
                      pageBackground: background,
                    ),
                  ),
                  Positioned.fill(
                    child: _CanvasEmptyHint(controller: _controller),
                  ),
                  WbCanvasTextEditor(controller: _controller),
                  if (widget.showToolPalette)
                    WbDraggableOverlay(
                      alignment: Alignment.topLeft,
                      padding: const EdgeInsets.all(12),
                      child: WbCanvasToolPalette(
                        controller: _controller,
                        onQuickCreate: widget.onQuickCreate,
                      ),
                    ),
                  WbDraggableOverlay(
                    alignment: Alignment.bottomRight,
                    padding: const EdgeInsets.all(16),
                    // 原位置 bottom: 372 → 在右下 16px 基位上再上移 356，
                    // 避免与右下圆盘工具栏初始位置重叠。
                    initialOffset: const Offset(0, -356),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        WbMinimap(controller: _controller),
                        const SizedBox(height: 8),
                        WbZoomControls(controller: _controller),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 指针手势层 + 绘制层。
///
/// `Listener` 只包裹最底层绘制（`HitTestBehavior.opaque`）；上层悬浮件
/// （调色板 / 迷你地图 / 文本编辑器）命中后不再向下传递，避免误触手势。
class _CanvasSurface extends StatelessWidget {
  const _CanvasSurface({
    required this.controller,
    required this.colors,
    this.pageBackground,
  });

  final WbCanvasController controller;
  final WbThemeColors colors;

  /// 页面背景（null = 主题底色 + 网格）。
  final WbPageBackground? pageBackground;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        return MouseRegion(cursor: _cursorFor(), child: child);
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handlePointerDown,
        onPointerMove: (PointerMoveEvent event) =>
            controller.handlePointerMove(event.pointer, event.localPosition),
        onPointerUp: (PointerUpEvent event) =>
            controller.handlePointerUp(event.pointer, event.localPosition),
        onPointerCancel: (PointerCancelEvent event) =>
            controller.handlePointerCancel(event.pointer),
        onPointerSignal: _handlePointerSignal,
        onPointerPanZoomStart: (PointerPanZoomStartEvent event) =>
            controller.handlePanZoomStart(),
        onPointerPanZoomUpdate: (PointerPanZoomUpdateEvent event) =>
            controller.handlePanZoomUpdate(
          event.localPosition,
          event.panDelta,
          event.scale,
        ),
        onPointerPanZoomEnd: (PointerPanZoomEndEvent event) =>
            controller.handlePanZoomEnd(),
        child: RepaintBoundary(
          key: WbCanvasCapture.boundaryKey,
          child: CustomPaint(
            painter: WbCanvasPainter(
              controller: controller,
              textCache: controller.textCache,
              canvasColor: colors.canvas,
              gridColor: colors.border.withValues(alpha: 0.55),
              selectionColor: colors.primary,
              pageBackground: pageBackground,
            ),
          ),
        ),
      ),
    );
  }

  MouseCursor _cursorFor() {
    if (controller.spacePressed) {
      return SystemMouseCursors.grab;
    }
    switch (controller.tool) {
      case WbCanvasTool.hand:
        return SystemMouseCursors.grab;
      case WbCanvasTool.pen:
      case WbCanvasTool.highlighter:
      case WbCanvasTool.note:
      case WbCanvasTool.text:
      case WbCanvasTool.shape:
      case WbCanvasTool.image:
      case WbCanvasTool.connector:
      case WbCanvasTool.render3d:
        return SystemMouseCursors.precise;
      case WbCanvasTool.select:
      case WbCanvasTool.eraser:
        return SystemMouseCursors.basic;
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    controller.handlePointerDown(
      event.pointer,
      event.localPosition,
      shift: HardwareKeyboard.instance.isShiftPressed,
      middleButton: event.buttons & kMiddleMouseButton != 0,
      secondaryButton: event.buttons & kSecondaryMouseButton != 0,
      touch: event.kind == PointerDeviceKind.touch,
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    controller.handleScroll(
      event.localPosition,
      event.scrollDelta,
      ctrl: keyboard.isControlPressed || keyboard.isMetaPressed,
      shift: keyboard.isShiftPressed,
    );
  }
}

/// 空画布提示（保留 Wave 2.5 的「画布就绪」文案；不拦截指针）。
class _CanvasEmptyHint extends StatelessWidget {
  const _CanvasEmptyHint({required this.controller});

  final WbCanvasController controller;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: controller,
        builder: (BuildContext context, Widget? child) {
          if (controller.elements.isNotEmpty) {
            return const SizedBox.shrink();
          }
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(LinearIcons.pen, size: 44, color: colors.border),
                const SizedBox(height: 12),
                Text(
                  '画布就绪',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  '滚轮平移 · Ctrl+滚轮缩放 · 空格拖拽 · 双击复位 · 左上角选择工具',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: colors.icon),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
