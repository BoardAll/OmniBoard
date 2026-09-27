/// 齿轮圆盘可视化主体：背景盘 + 内环 + 外环 + 子环 + 最近使用条 + 中心按钮。
///
/// 布局与视觉遵循《齿轮圆盘交互详细设计 v1.1》2.1 / 2.2 / 3.2 / 6.1 / 8.x：
/// - 中心 56px 圆（齿轮 / 当前工具 / 锁）；内环 6 项（40px）半径 56；
/// - 外环 8 组（44px）半径 96；子环（40px）半径 156、弧跨度 56°、最多同显 6 项；
/// - 底盘直径 240px（[RadialMetrics.discDiameter]）；
/// - 子工具展开时父扇区保持高亮、其余扇区透明度 40%；
/// - 一切颜色取自 `context.wbColors`（含暗色适配）。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerEnterEvent, PointerExitEvent;
import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import 'radial_item.dart';
import 'radial_layout.dart';
import 'radial_models.dart';

/// 圆盘状态（文档 7.1：collapsed / expanded / subExpanded / dragging / locked / hidden）。
enum RadialPhase {
  /// 收起：只显示中心齿轮（或当前工具）。
  collapsed,

  /// 展开：内环 + 外环 + 最近使用。
  expanded,

  /// 子工具展开。
  subExpanded,

  /// 拖拽选中中。
  dragging,

  /// 锁定常驻。
  locked,

  /// 隐藏（仅保留恢复把手）。
  hidden,
}

/// 圆盘菜单主体（不含中心按钮；由 `RadialToolbar` 叠加并接线手势）。
class RadialMenu extends StatelessWidget {
  const RadialMenu({
    super.key,
    required this.metrics,
    this.expanded = false,
    this.activeToolId = '',
    this.expandedGroupId,
    this.subScroll = 0,
    this.recentTools = const <RadialTool>[],
    this.highlight,
    this.focusHit,
    this.showLabels = true,
    this.showRecent = true,
    this.animations = true,
    this.onInnerTap,
    this.onOuterTap,
    this.onOuterDoubleTap,
    this.onSubTap,
    this.onSubScroll,
    this.onRecentTap,
  });

  /// 几何度量。
  final RadialMetrics metrics;

  /// 环是否可见（expanded / subExpanded / dragging / locked）。
  final bool expanded;

  /// 当前工具 id。
  final String activeToolId;

  /// 子环展开的分组 id。
  final String? expandedGroupId;

  /// 子环滚动偏移。
  final int subScroll;

  /// 最近使用工具（已截断）。
  final List<RadialTool> recentTools;

  /// 拖拽高亮（[RadialZone.inner] / [RadialZone.outer] / [RadialZone.sub]）。
  final RadialHit? highlight;

  /// 键盘焦点高亮。
  final RadialHit? focusHit;

  /// 是否显示条目标签。
  final bool showLabels;

  /// 是否显示最近使用条。
  final bool showRecent;

  /// 是否启用动效。
  final bool animations;

  /// 内环点击。
  final ValueChanged<RadialTool>? onInnerTap;

  /// 外环单击（展开 / 收起子工具）。
  final ValueChanged<RadialGroup>? onOuterTap;

  /// 外环双击（选中默认工具）。
  final ValueChanged<RadialGroup>? onOuterDoubleTap;

  /// 子工具点击。
  final ValueChanged<RadialTool>? onSubTap;

  /// 子环滚动（-1 / +1）。
  final ValueChanged<int>? onSubScroll;

  /// 最近使用点击。
  final ValueChanged<RadialTool>? onRecentTap;

  bool get _subOpen => expandedGroupId != null && expandedGroupId!.isNotEmpty;

  Duration get _motion =>
      animations ? const Duration(milliseconds: 180) : Duration.zero;

  Duration get _collapseMotion =>
      animations ? const Duration(milliseconds: 150) : Duration.zero;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final WbThemeData theme = context.wbTheme;
    final RadialGroup? expandedGroup = _expandedGroup;
    final bool dimOthers = _subOpen;
    final bool reduceMotion = !animations;

    final double backgroundOpacity =
        MediaQuery.highContrastOf(context) ? 1.0 : theme.opacity.radial;

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // 背景盘（毛玻璃感：高不透明度圆 + 细边框 + 大阴影，文档 8.2）。
        Center(
          child: AnimatedContainer(
            duration: expanded ? _motion : _collapseMotion,
            curve: expanded ? kRadialExpandCurve : kRadialCollapseCurve,
            width: expanded ? metrics.discDiameter : 0,
            height: expanded ? metrics.discDiameter : 0,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color:
                  colors.radialBackground.withValues(alpha: backgroundOpacity),
              border: Border.all(color: colors.cardBorder),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 32,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
          ),
        ),
        // 内环：6 个固定工具。
        ..._buildInner(reduceMotion),
        // 外环：8 个分组。
        ..._buildOuter(dimOthers),
        // 子环。
        if (expandedGroup != null) ..._buildSub(expandedGroup),
        // 最近使用条。
        if (showRecent && recentTools.isNotEmpty) _buildRecent(),
      ],
    );
  }

  /// 当前展开的分组。
  RadialGroup? get _expandedGroup {
    final String? id = expandedGroupId;
    return id == null ? null : RadialCatalog.groupById(id);
  }

  List<Widget> _buildInner(bool reduceMotion) {
    final List<Widget> children = <Widget>[];
    for (int i = 0; i < RadialCatalog.inner.length; i++) {
      final RadialTool tool = RadialCatalog.inner[i];
      final Offset center = metrics.center +
          offsetAt(
            metrics.innerRadius,
            angleForIndex(i, RadialCatalog.inner.length),
          );
      final bool hit =
          highlight?.zone == RadialZone.inner && highlight?.index == i;
      final bool focus =
          focusHit?.zone == RadialZone.inner && focusHit?.index == i;
      children.add(
        _positioned(
          center: center,
          size: metrics.innerItemSize,
          child: _fade(
            ignore: !expanded,
            reduceMotion: reduceMotion,
            child: RadialItemButton(
              key: ValueKey<String>('radial-inner-${tool.id}'),
              icon: tool.icon,
              label: tool.label,
              size: metrics.innerItemSize,
              iconSize: metrics.iconSize,
              selected: tool.id == activeToolId,
              highlighted: hit || focus,
              focused: focus,
              dimmed: _subOpen,
              showLabel: showLabels,
              labelFontSize: metrics.labelFontSize,
              onTap: onInnerTap == null ? null : () => onInnerTap!(tool),
            ),
          ),
        ),
      );
    }
    return children;
  }

  List<Widget> _buildOuter(bool dimOthers) {
    final List<Widget> children = <Widget>[];
    for (int i = 0; i < RadialCatalog.groups.length; i++) {
      final RadialGroup group = RadialCatalog.groups[i];
      final Offset center = metrics.center +
          offsetAt(
            metrics.outerRadius,
            angleForIndex(i, RadialCatalog.groups.length),
          );
      final bool hit =
          highlight?.zone == RadialZone.outer && highlight?.index == i;
      final bool focus =
          focusHit?.zone == RadialZone.outer && focusHit?.index == i;
      final bool isParent = group.id == expandedGroupId;
      children.add(
        _positioned(
          center: center,
          size: metrics.outerItemSize,
          child: _fade(
            ignore: !expanded,
            reduceMotion: !animations,
            child: RadialItemButton(
              key: ValueKey<String>('radial-group-${group.id}'),
              icon: group.icon,
              label: group.label,
              size: metrics.outerItemSize,
              iconSize: metrics.iconSize,
              highlighted: hit || focus || isParent,
              focused: focus,
              dimmed: dimOthers && !isParent,
              showLabel: showLabels,
              labelFontSize: metrics.labelFontSize,
              onTap: onOuterTap == null ? null : () => onOuterTap!(group),
              onDoubleTap: onOuterDoubleTap == null
                  ? null
                  : () => onOuterDoubleTap!(group),
            ),
          ),
        ),
      );
    }
    return children;
  }

  List<Widget> _buildSub(RadialGroup group) {
    final List<Widget> children = <Widget>[];
    final int groupIndex = RadialCatalog.groupIndex(group.id);
    if (groupIndex < 0) {
      return children;
    }
    final double groupAngle =
        angleForIndex(groupIndex, RadialCatalog.groups.length);
    final int visible = math.min(kSubVisibleSlots, group.tools.length);
    final int offset = clampSubScroll(subScroll, group.tools.length);
    final Duration motion =
        animations ? const Duration(milliseconds: 150) : Duration.zero;

    for (int slot = 0; slot < visible; slot++) {
      final int toolIndex = offset + slot;
      if (toolIndex >= group.tools.length) {
        break;
      }
      final RadialTool tool = group.tools[toolIndex];
      final double angle = subSlotAngle(groupAngle, slot, visible);
      final Offset center = metrics.center + offsetAt(metrics.subRadius, angle);
      final bool hit =
          highlight?.zone == RadialZone.sub && highlight?.index == toolIndex;
      final bool focus =
          focusHit?.zone == RadialZone.sub && focusHit?.index == toolIndex;
      children.add(
        _positioned(
          center: center,
          size: metrics.subItemSize,
          child: _fade(
            ignore: !expanded,
            reduceMotion: !animations,
            duration: motion,
            child: RadialItemButton(
              key: ValueKey<String>('radial-sub-${tool.id}'),
              icon: tool.icon,
              label: tool.label,
              size: metrics.subItemSize,
              iconSize: metrics.iconSize,
              selected: tool.id == activeToolId,
              highlighted: hit || focus,
              focused: focus,
              showLabel: showLabels,
              labelFontSize: metrics.labelFontSize * 0.95,
              onTap: onSubTap == null ? null : () => onSubTap!(tool),
              onVerticalDragUpdate: onSubScroll == null
                  ? null
                  : (DragUpdateDetails details) =>
                      onSubScroll!(details.delta.dy < 0 ? 1 : -1),
            ),
          ),
        ),
      );
    }
    return children;
  }

  Widget _buildRecent() {
    final double item = metrics.recentItemSize;
    const double spacing = 6;
    const double padding = 4;
    final double barWidth = recentTools.length * item +
        (recentTools.length - 1) * spacing +
        padding * 2;
    return Positioned(
      left: metrics.center.dx - barWidth / 2,
      top: metrics.center.dy + metrics.centerRadius + 6,
      child: IgnorePointer(
        ignoring: !expanded,
        child: AnimatedOpacity(
          opacity: expanded ? 1 : 0,
          duration: expanded ? _motion : _collapseMotion,
          child: RadialRecentBar(
            key: const ValueKey<String>('radial-recent-bar'),
            tools: recentTools,
            itemSize: item,
            iconSize: item * 0.62,
            activeToolId: activeToolId,
            onTap: onRecentTap,
          ),
        ),
      ),
    );
  }

  Widget _positioned({
    required Offset center,
    required double size,
    required Widget child,
  }) {
    return Positioned(
      left: center.dx - size / 2,
      top: center.dy - size / 2,
      width: size,
      height: size,
      child: child,
    );
  }

  Widget _fade({
    required bool ignore,
    required bool reduceMotion,
    Duration? duration,
    required Widget child,
  }) {
    final Duration motion = duration ?? _motion;
    if (reduceMotion) {
      return IgnorePointer(
        ignoring: ignore,
        child: Opacity(opacity: ignore ? 0 : 1, child: child),
      );
    }
    return IgnorePointer(
      ignoring: ignore,
      child: AnimatedOpacity(
        opacity: ignore ? 0 : 1,
        duration: motion,
        child: AnimatedScale(
          scale: ignore ? 0.4 : 1,
          duration: motion,
          child: child,
        ),
      ),
    );
  }
}

/// 中心按钮：收起显示当前工具、展开显示齿轮（90° 旋转）、锁定显示锁。
class RadialCenterButton extends StatefulWidget {
  const RadialCenterButton({
    super.key,
    required this.metrics,
    required this.phase,
    required this.activeIcon,
    this.onTap,
    this.onLongPress,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
  });

  /// 几何度量。
  final RadialMetrics metrics;

  /// 当前相位。
  final RadialPhase phase;

  /// 当前工具图标（收起态显示）。
  final IconData activeIcon;

  /// 单击（展开 / 收起）。
  final VoidCallback? onTap;

  /// 长按（锁定 / 解锁）。
  final VoidCallback? onLongPress;

  /// 从中心向外拖动开始（本地坐标，相对按钮左上角）。
  final ValueChanged<Offset>? onPanStart;

  /// 拖动更新（本地坐标，相对按钮左上角）。
  final ValueChanged<Offset>? onPanUpdate;

  /// 拖动结束。
  final VoidCallback? onPanEnd;

  @override
  State<RadialCenterButton> createState() => _RadialCenterButtonState();
}

class _RadialCenterButtonState extends State<RadialCenterButton> {
  bool _hovered = false;

  bool get _locked => widget.phase == RadialPhase.locked;

  bool get _ringVisible =>
      widget.phase == RadialPhase.expanded ||
      widget.phase == RadialPhase.subExpanded ||
      widget.phase == RadialPhase.dragging ||
      _locked;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final double diameter = widget.metrics.centerRadius * 2;
    final IconData icon = _locked
        ? LinearIcons.lock
        : (_ringVisible ? LinearIcons.grid : widget.activeIcon);
    final String tooltip =
        _locked ? '已锁定（长按解锁）' : (_ringVisible ? '收起工具盘' : '展开工具盘');

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (PointerEnterEvent event) => setState(() => _hovered = true),
      onExit: (PointerExitEvent event) => setState(() => _hovered = false),
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          onPanStart: widget.onPanStart == null
              ? null
              : (DragStartDetails details) =>
                  widget.onPanStart!(details.localPosition),
          onPanUpdate: widget.onPanUpdate == null
              ? null
              : (DragUpdateDetails details) =>
                  widget.onPanUpdate!(details.localPosition),
          onPanEnd: widget.onPanEnd == null
              ? null
              : (DragEndDetails details) => widget.onPanEnd!(),
          child: AnimatedScale(
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
            scale: _hovered ? 1.05 : 1.0,
            child: Container(
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.toolbarBackground,
                border: Border.all(
                  color: _locked ? colors.radialHighlight : colors.cardBorder,
                  width: _locked ? 2 : 1,
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.16),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Center(
                child: AnimatedRotation(
                  turns: _ringVisible && !_locked ? 0.25 : 0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: Curves.easeInOut,
                    switchOutCurve: Curves.easeInOut,
                    child: Icon(
                      icon,
                      key: ValueKey<IconData>(icon),
                      size: widget.metrics.iconSize,
                      color: colors.toolbarIcon,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 展开曲线：cubic-bezier(0.34, 1.56, 0.64, 1)（文档 8.3）。
const Curve kRadialExpandCurve = Cubic(0.34, 1.56, 0.64, 1);

/// 收起曲线：cubic-bezier(0.4, 0, 1, 1)（文档 8.3）。
const Curve kRadialCollapseCurve = Cubic(0.4, 0, 1, 1);
