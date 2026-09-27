/// 透明批注右上角悬浮工具栏（《透明批注模式技术方案》§9）。
///
/// 内容：笔 / 荧光笔 / 橡皮 / 激光笔、颜色与线宽、撤销 / 重做、
/// 穿透态切换、折叠与退出；位置距右边 / 顶边 24px，可拖拽、可折叠为
/// 小胶囊（§9.1 / §9.3）。穿透态下工具栏半透明并显示「穿透中」徽标，
/// 但始终可点击（§4.1：工具栏仍可点击）。
library;

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../../state/annotation_state.dart';
import 'annotation_controller.dart';

/// 右上角批注工具栏（可独立挂载的浮层组件）。
class AnnotationToolbar extends StatefulWidget {
  const AnnotationToolbar({super.key, required this.controller});

  /// 批注控制器。
  final WbAnnotationController controller;

  /// 整体透明度 key（穿透态半透明；测试与集成可读取）。
  static const ValueKey<String> opacityKey =
      ValueKey<String>('annotation-toolbar-opacity');

  @override
  State<AnnotationToolbar> createState() => _AnnotationToolbarState();
}

class _AnnotationToolbarState extends State<AnnotationToolbar> {
  bool _collapsed = false;
  bool _paletteOpen = false;
  Offset _drag = Offset.zero;

  void _toggleCollapsed() {
    setState(() {
      _collapsed = !_collapsed;
      _paletteOpen = false;
    });
  }

  /// 选择绘图工具：穿透态下先切回批注态（否则笔迹不可见也画不上）。
  void _selectTool(WbAnnotationController controller, WbAnnotationTool tool) {
    if (controller.isPenetrating) {
      unawaited(controller.setPenetrate(false));
    }
    controller.state.selectTool(tool);
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final WbAnnotationController controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? child) {
        final bool penetrating = controller.isPenetrating;
        return Transform.translate(
          offset: _drag,
          child: Opacity(
            key: AnnotationToolbar.opacityKey,
            opacity: penetrating ? 0.62 : 1,
            child: _collapsed
                ? _buildCapsule(colors, controller)
                : _buildBar(colors, controller),
          ),
        );
      },
    );
  }

  // ---- 展开态 ----

  Widget _buildBar(WbThemeColors colors, WbAnnotationController controller) {
    final WbAnnotationState state = controller.state;
    return _wrapDrag(
      Material(
        key: const ValueKey<String>('annotation-toolbar'),
        color: Colors.transparent,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: colors.toolbarBackground.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.cardBorder),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (controller.isPenetrating) ...<Widget>[
                        const _PenetrateBadge(),
                        const _Separator(),
                      ],
                      _ToolbarButton(
                        icon: LinearIcons.pen,
                        tooltip: '画笔',
                        active: state.tool == WbAnnotationTool.pen &&
                            !controller.isPenetrating,
                        onTap: () => _selectTool(
                          controller,
                          WbAnnotationTool.pen,
                        ),
                      ),
                      _ToolbarButton(
                        icon: LinearIcons.highlighter,
                        tooltip: '荧光笔',
                        active: state.tool == WbAnnotationTool.highlighter &&
                            !controller.isPenetrating,
                        onTap: () => _selectTool(
                          controller,
                          WbAnnotationTool.highlighter,
                        ),
                      ),
                      _ToolbarButton(
                        icon: LinearIcons.eraser,
                        tooltip: '橡皮',
                        active: state.tool == WbAnnotationTool.eraser &&
                            !controller.isPenetrating,
                        onTap: () => _selectTool(
                          controller,
                          WbAnnotationTool.eraser,
                        ),
                      ),
                      _ToolbarButton(
                        icon: LinearIcons.light,
                        tooltip: '激光笔',
                        active: state.tool == WbAnnotationTool.laser &&
                            !controller.isPenetrating,
                        onTap: () => _selectTool(
                          controller,
                          WbAnnotationTool.laser,
                        ),
                      ),
                      const _Separator(),
                      _ToolbarButton(
                        icon: LinearIcons.undo,
                        tooltip: '撤销',
                        onTap: state.canUndo ? () => state.undo() : null,
                      ),
                      _ToolbarButton(
                        icon: LinearIcons.redo,
                        tooltip: '重做',
                        onTap: state.canRedo ? () => state.redo() : null,
                      ),
                      const _Separator(),
                      _ToolbarButton(
                        icon: LinearIcons.palette,
                        tooltip: '颜色与线宽',
                        active: _paletteOpen,
                        onTap: () =>
                            setState(() => _paletteOpen = !_paletteOpen),
                      ),
                      const _Separator(),
                      _ToolbarButton(
                        key: const ValueKey<String>('annotation-mode-annotate'),
                        icon: LinearIcons.pen,
                        tooltip: '批注：在桌面上绘制',
                        active: !controller.isPenetrating,
                        onTap: () =>
                            unawaited(controller.setPenetrate(false)),
                      ),
                      _ToolbarButton(
                        key: const ValueKey<String>('annotation-mode-mouse'),
                        icon: LinearIcons.hand,
                        tooltip: '鼠标：穿透操作电脑',
                        active: controller.isPenetrating,
                        onTap: () => unawaited(controller.setPenetrate(true)),
                      ),
                      _ToolbarButton(
                        icon: LinearIcons.more,
                        tooltip: '折叠工具栏',
                        onTap: _toggleCollapsed,
                      ),
                      _ToolbarButton(
                        key: const ValueKey<String>('annotation-exit'),
                        icon: LinearIcons.close,
                        tooltip: '退出透明批注模式',
                        onTap: controller.requestExit,
                      ),
                    ],
                  ),
                  if (_paletteOpen) _PalettePanel(controller: controller),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---- 折叠态（小胶囊，§9.1） ----

  Widget _buildCapsule(
    WbThemeColors colors,
    WbAnnotationController controller,
  ) {
    return _wrapDrag(
      Material(
        key: const ValueKey<String>('annotation-toolbar-capsule'),
        color: Colors.transparent,
        child: Tooltip(
          message: '展开工具栏',
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: _toggleCollapsed,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colors.toolbarBackground.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: colors.cardBorder),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    LinearIcons.pen,
                    size: 18,
                    color: colors.toolbarIcon,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${controller.state.strokeCount}',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: colors.toolbarIcon),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wrapDrag(Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanUpdate: (DragUpdateDetails details) =>
          setState(() => _drag += details.delta),
      child: child,
    );
  }
}

/// 单个工具栏按钮（32×32，图标 20px，§9.4）。
class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        hoverColor: colors.cardHover,
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: active ? colors.toolbarActive.withValues(alpha: 0.16) : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 20,
            color: active
                ? colors.toolbarActive
                : colors.toolbarIcon.withValues(alpha: onTap == null ? 0.35 : 1),
          ),
        ),
      ),
    );
  }
}

/// 分隔线。
class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: colors.cardBorder,
    );
  }
}

/// 穿透态徽标（§4.1：提示鼠标事件已穿透）。
class _PenetrateBadge extends StatelessWidget {
  const _PenetrateBadge();

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Tooltip(
      message: '鼠标事件已穿透到桌面；按 Alt+Shift+A 或右侧按钮切回批注态',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: colors.toolbarActive.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: colors.toolbarActive,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '穿透中',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.toolbarActive),
            ),
            const SizedBox(width: 6),
            Text(
              '${WbAnnotationShortcuts.togglePenetrateLabel} 切回批注',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.toolbarActive.withValues(alpha: 0.72),
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 颜色与线宽弹层（§9.2 🎨：颜色跟随主题、线宽三档）。
class _PalettePanel extends StatelessWidget {
  const _PalettePanel({required this.controller});

  final WbAnnotationController controller;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final WbAnnotationState state = controller.state;
    final TextStyle? caption = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: colors.toolbarIcon);
    return Container(
      key: const ValueKey<String>('annotation-palette'),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.toolbarBackground.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.cardBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('颜色', style: caption),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (int i = 0; i < WbAnnotationPalette.colors.length; i++)
                _ColorDot(
                  index: i,
                  color: WbAnnotationPalette.colors[i],
                  selected: state.color == WbAnnotationPalette.colors[i],
                  onTap: () => state.setColor(WbAnnotationPalette.colors[i]),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text('线宽', style: caption),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: <Widget>[
              for (int i = 0; i < WbAnnotationPalette.widths.length; i++)
                _WidthDot(
                  index: i,
                  width: WbAnnotationPalette.widths[i],
                  selected: state.width == WbAnnotationPalette.widths[i],
                  onTap: () => state.setWidth(WbAnnotationPalette.widths[i]),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 颜色圆点。
class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.index,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Tooltip(
      message: '颜色 ${index + 1}',
      child: InkWell(
        key: ValueKey<String>('annotation-color-$index'),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? colors.toolbarActive : colors.cardBorder,
              width: selected ? 3 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// 线宽圆点。
class _WidthDot extends StatelessWidget {
  const _WidthDot({
    required this.index,
    required this.width,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final double width;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Tooltip(
      message: '线宽 ${width.toStringAsFixed(0)}',
      child: InkWell(
        key: ValueKey<String>('annotation-width-$index'),
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? colors.toolbarActive.withValues(alpha: 0.14) : null,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? colors.toolbarActive : Colors.transparent,
            ),
          ),
          child: Container(
            width: width + 2,
            height: width + 2,
            decoration: BoxDecoration(
              color: colors.toolbarIcon,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}
