/// 圆盘条目按钮与最近使用快捷条。
///
/// 视觉规范：《齿轮圆盘交互详细设计 v1.1》8.1 / 8.4——
/// 悬停主色 12%、高亮 20%、选中实色 + 白色图标，图标悬停放大 1.1x、
/// 拖拽经过放大 1.15x；颜色全部走主题 token（`context.wbColors`）。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerEnterEvent, PointerExitEvent;
import 'package:flutter/material.dart';
import 'package:whiteboard_theme/theme.dart';

import 'radial_models.dart';

/// 圆盘条目按钮（内环 / 外环 / 子环 / 最近使用共用）。
class RadialItemButton extends StatefulWidget {
  const RadialItemButton({
    super.key,
    required this.icon,
    required this.label,
    required this.size,
    required this.iconSize,
    this.onTap,
    this.onDoubleTap,
    this.onVerticalDragUpdate,
    this.onVerticalDragStart,
    this.selected = false,
    this.highlighted = false,
    this.focused = false,
    this.dimmed = false,
    this.showLabel = false,
    this.labelFontSize = 11,
    this.iconScaleOnHighlight = 1.15,
    this.tooltip,
  });

  /// 图标。
  final IconData icon;

  /// 文字标签（Tooltip / 可访问名 / 条内小字）。
  final String label;

  /// 按钮边长。
  final double size;

  /// 图标尺寸。
  final double iconSize;

  /// 单击回调（可为空，表示纯展示）。
  final VoidCallback? onTap;

  /// 双击回调。
  final VoidCallback? onDoubleTap;

  /// 垂直拖拽（子环滚动，文档 6.2 触屏上下滑动）。
  final GestureDragUpdateCallback? onVerticalDragUpdate;

  /// 垂直拖拽开始。
  final GestureDragStartCallback? onVerticalDragStart;

  /// 是否为"当前工具"（实色填充 + 白色图标/标签）。
  final bool selected;

  /// 拖拽经过 / 父扇区展开等临时高亮（主色 20%）。
  final bool highlighted;

  /// 键盘导航焦点（2px 主色焦点环）。
  final bool focused;

  /// 其他扇区在子工具展开时变暗（文档 8.4：透明度降至 40%）。
  final bool dimmed;

  /// 是否在按钮内显示小字标签（文档 11：默认显示）。
  final bool showLabel;

  /// 标签字号（基准 11px）。
  final double labelFontSize;

  /// 高亮时图标放大系数（拖拽 1.15）。
  final double iconScaleOnHighlight;

  /// Tooltip 文案（为空时使用 [label]）。
  final String? tooltip;

  @override
  State<RadialItemButton> createState() => _RadialItemButtonState();
}

class _RadialItemButtonState extends State<RadialItemButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final Color accent = colors.radialHighlight;
    final Color baseIcon = colors.toolbarIcon;

    final Color background;
    if (widget.selected) {
      background = accent;
    } else if (widget.highlighted) {
      background = accent.withValues(alpha: 0.20);
    } else if (_hovered) {
      background = accent.withValues(alpha: 0.12);
    } else {
      background = Colors.transparent;
    }
    final Color foreground = widget.selected ? Colors.white : baseIcon;
    final double iconScale = widget.highlighted
        ? widget.iconScaleOnHighlight
        : (_hovered ? 1.10 : 1.0);
    // 视觉内边距：按按钮可用空间收窄图标（含标签时让出标签行），
    // 保证条目块内留白、相邻按钮不粘连（文档 8.1 视觉规范微调）。
    // 固定扣除 4px 聚焦边框预留：边框随 decoration 动画淡入淡出时
    // 布局滞后，恒扣可保证过渡帧也不溢出（图标尺寸不随聚焦跳变）。
    const double borderInset = 4;
    final double labelBlock =
        widget.showLabel ? widget.labelFontSize * 1.05 + 1 : 0;
    final double iconSize = math.max(
      12,
      math.min(
        widget.iconSize,
        widget.size - 5 - labelBlock - borderInset,
      ),
    );

    return Opacity(
      opacity: widget.dimmed ? 0.4 : 1,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (PointerEnterEvent event) => setState(() => _hovered = true),
        onExit: (PointerExitEvent event) => setState(() => _hovered = false),
        child: Semantics(
          button: true,
          label: widget.label,
          selected: widget.selected,
          child: Tooltip(
            message: widget.tooltip ?? widget.label,
            waitDuration: const Duration(milliseconds: 600),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onDoubleTap: widget.onDoubleTap,
              onVerticalDragStart: widget.onVerticalDragStart,
              onVerticalDragUpdate: widget.onVerticalDragUpdate,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 80),
                curve: Curves.easeOut,
                width: widget.size,
                height: widget.size,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(10),
                  border: widget.focused
                      ? Border.all(color: accent, width: 2)
                      : null,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    // 兜底：尺寸档位 / 字号切换的过渡帧由 FittedBox 收窄，
                    // 避免容器动画滞后于图标尺寸变化时瞬时溢出。
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: AnimatedScale(
                        duration: const Duration(milliseconds: 80),
                        curve: Curves.easeOut,
                        scale: iconScale,
                        child: Icon(
                          widget.icon,
                          size: iconSize,
                          color: foreground,
                        ),
                      ),
                    ),
                    if (widget.showLabel) ...<Widget>[
                      const SizedBox(height: 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: widget.labelFontSize,
                            height: 1.05,
                            color: foreground.withValues(alpha: 0.82),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 最近使用快捷条（文档 3.2：中心下方，最多 3 个，单击选中并收起）。
class RadialRecentBar extends StatelessWidget {
  const RadialRecentBar({
    super.key,
    required this.tools,
    required this.itemSize,
    required this.iconSize,
    this.activeToolId = '',
    this.onTap,
    this.spacing = 6,
    this.padding = 4,
  });

  /// 最近使用工具（已按设置截断）。
  final List<RadialTool> tools;

  /// 单项尺寸（文档 2.2：最近使用图标 28px）。
  final double itemSize;

  /// 图标尺寸。
  final double iconSize;

  /// 当前工具 id（高亮）。
  final String activeToolId;

  /// 点击回调。
  final ValueChanged<RadialTool>? onTap;

  /// 项间距。
  final double spacing;

  /// 条内边距。
  final double padding;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final double width =
        tools.length * itemSize + (tools.length - 1) * spacing + padding * 2;
    return Container(
      width: width,
      height: itemSize + padding * 2,
      decoration: BoxDecoration(
        color: colors.radialBackground.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.cardBorder),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          for (int i = 0; i < tools.length; i++) ...<Widget>[
            if (i > 0) SizedBox(width: spacing),
            SizedBox.square(
              dimension: itemSize,
              child: RadialItemButton(
                key: ValueKey<String>('radial-recent-${tools[i].id}'),
                icon: tools[i].icon,
                label: tools[i].label,
                size: itemSize,
                iconSize: iconSize,
                selected: tools[i].id == activeToolId,
                onTap: onTap == null ? null : () => onTap!(tools[i]),
                tooltip: '最近使用：${tools[i].label}',
              ),
            ),
          ],
        ],
      ),
    );
  }
}
