/// 画布工具调色板：11 种工具 + 撤销/重做 + 工具参数（颜色 / 形状 / 线宽 / 3D）。
///
/// 位于画布左上角（`CanvasView` 内 `Positioned(left: 12, top: 12)`）。
///
/// 交互元素 key 约定（供测试与后续自动化引用）：
/// - 工具：`wb-canvas-tool-<toolId>`
/// - 撤销/重做：`wb-canvas-undo` / `wb-canvas-redo`
/// - 更多菜单：`wb-canvas-more`（专业元素 / 平行四边形 / 连线 / 3D 直绘）
/// - 参数：`wb-canvas-note-color-<i>` / `wb-canvas-shape-color-<i>` /
///   `wb-canvas-pen-color-<i>` / `wb-canvas-pen-width-<i>` /
///   `wb-canvas-shape-kind-<kindId>` / `wb-canvas-3d-type-<typeId>` /
///   `wb-canvas-3d-paint-toggle` / `wb-canvas-3d-paint-color-<i>`
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../context_editors/quick_create.dart';
import '../context_editors/render3d_editor.dart';
import 'canvas_controller.dart';
import 'canvas_model.dart';
import 'stroke_style.dart';

/// 悬浮面板统一样式（工具调色板 / 缩放控件共用）。
BoxDecoration wbCanvasPanelDecoration(WbThemeColors colors) {
  return BoxDecoration(
    color: colors.elevated,
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: colors.border),
    boxShadow: const <BoxShadow>[
      BoxShadow(
        color: Color(0x14000000),
        blurRadius: 12,
        offset: Offset(0, 4),
      ),
    ],
  );
}

/// 画布悬浮图标按钮（hover / active / disabled 三态）。
class WbCanvasIconButton extends StatelessWidget {
  /// 创建按钮。
  const WbCanvasIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.active = false,
    this.enabled = true,
    this.size = 32,
    this.iconSize = 18,
  });

  /// 图标。
  final IconData icon;

  /// 点击回调（[enabled] 为 false 时不触发）。
  final VoidCallback onTap;

  /// 悬浮提示（null 不显示）。
  final String? tooltip;

  /// 激活态（高亮背景 + 主色图标）。
  final bool active;

  /// 是否可用。
  final bool enabled;

  /// 按钮边长。
  final double size;

  /// 图标尺寸。
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final Color foreground = enabled
        ? (active ? colors.primary : colors.toolbarIcon)
        : colors.toolbarIcon.withValues(alpha: 0.35);
    final Widget button = Material(
      color: active ? colors.primary.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(6),
        hoverColor: colors.hover,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: iconSize, color: foreground),
        ),
      ),
    );
    final String? message = tooltip;
    if (message == null) {
      return button;
    }
    return Tooltip(
      message: message,
      waitDuration: const Duration(milliseconds: 600),
      child: button,
    );
  }
}

/// 画布工具调色板。
///
/// M3 只读收窄：[drawingEnabled] 为 false 时仅保留导航工具（选择 / 手），
/// 撤销 / 重做与「更多」菜单置灰（与 `FloatingToolbar.drawingEnabled` 同口径）。
class WbCanvasToolPalette extends StatelessWidget {
  /// 创建调色板。
  const WbCanvasToolPalette({
    super.key,
    required this.controller,
    this.onQuickCreate,
    this.drawingEnabled = true,
  });

  /// 画布控制器。
  final WbCanvasController controller;

  /// 「更多」菜单中的专业元素创建回调（null 时隐藏该分组）。
  final ValueChanged<WbQuickCreateKind>? onQuickCreate;

  /// 是否允许编辑（false = 只读：非导航工具 / 撤销重做 / 更多置灰）。
  final bool drawingEnabled;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        final Widget? options = _optionsRow(colors, context);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(4),
              decoration: wbCanvasPanelDecoration(colors),
              child: _toolRow(colors),
            ),
            if (options != null) ...<Widget>[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 5,
                ),
                decoration: wbCanvasPanelDecoration(colors),
                child: options,
              ),
            ],
          ],
        );
      },
    );
  }

  // ---- 工具行 -----------------------------------------------------------

  Widget _toolRow(WbThemeColors colors) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final WbCanvasTool tool in WbCanvasTool.values)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: WbCanvasIconButton(
              key: ValueKey<String>('wb-canvas-tool-${tool.id}'),
              icon: _iconForTool(tool),
              tooltip: tool.label,
              active: controller.tool == tool,
              // M3 只读收窄：保留导航工具（选择 / 手），其余绘制项置灰。
              enabled: drawingEnabled || _isNavigationTool(tool),
              onTap: () => controller.setTool(tool),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Container(width: 1, height: 20, color: colors.border),
        ),
        WbCanvasIconButton(
          key: const Key('wb-canvas-undo'),
          icon: LinearIcons.undo,
          tooltip: '撤销 (Ctrl+Z)',
          // M3 只读收窄：无编辑权限时撤销 / 重做同样置灰。
          enabled: drawingEnabled && controller.canUndo,
          onTap: controller.undo,
        ),
        WbCanvasIconButton(
          key: const Key('wb-canvas-redo'),
          icon: LinearIcons.redo,
          tooltip: '重做 (Ctrl+Shift+Z)',
          enabled: drawingEnabled && controller.canRedo,
          onTap: controller.redo,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Container(width: 1, height: 20, color: colors.border),
        ),
        Builder(
          builder: (BuildContext buttonContext) => WbCanvasIconButton(
            key: const Key('wb-canvas-more'),
            icon: LinearIcons.more,
            tooltip: '更多工具（专业元素 / 平行四边形 / 连线 / 3D 直绘）',
            // M3 只读收窄：「更多」菜单均为编辑入口，无权限时整体置灰。
            enabled: drawingEnabled,
            onTap: () => unawaited(_showMoreMenu(buttonContext)),
          ),
        ),
      ],
    );
  }

  /// 「更多」弹出菜单（B3：圆盘绘图能力并入顶部面板）。
  Future<void> _showMoreMenu(BuildContext buttonContext) async {
    final RenderBox button =
        buttonContext.findRenderObject()! as RenderBox;
    final RenderBox overlay = Navigator.of(buttonContext)
        .overlay!
        .context
        .findRenderObject()! as RenderBox;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final ValueChanged<WbQuickCreateKind>? onCreate = onQuickCreate;
    final String? choice = await showMenu<String>(
      context: buttonContext,
      position: position,
      items: <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(
          value: 'shape.parallelogram',
          height: 36,
          child: _WbMoreMenuRow(icon: LinearIcons.shape, label: '平行四边形'),
        ),
        const PopupMenuItem<String>(
          value: 'tool.connector',
          height: 36,
          child: _WbMoreMenuRow(icon: LinearIcons.connector, label: '连线'),
        ),
        const PopupMenuDivider(),
        for (final Wb3dObjectType type in Wb3dObjectType.values)
          PopupMenuItem<String>(
            value: '3d.${type.id}',
            height: 36,
            child: _WbMoreMenuRow(
              icon: LinearIcons.cube,
              label: '${type.label}（直绘）',
            ),
          ),
        if (onCreate != null) ...<PopupMenuEntry<String>>[
          const PopupMenuDivider(),
          for (final WbQuickCreateKind kind in WbQuickCreateKind.values)
            PopupMenuItem<String>(
              value: 'pro.${kind.id}',
              height: 36,
              child: _WbMoreMenuRow(icon: kind.icon, label: kind.label),
            ),
        ],
      ],
    );
    if (choice == null) {
      return;
    }
    switch (choice) {
      case 'shape.parallelogram':
        controller.setShapeKind(WbShapeKind.parallelogram);
        controller.setTool(WbCanvasTool.shape);
      case 'tool.connector':
        controller.setTool(WbCanvasTool.connector);
      default:
        if (choice.startsWith('3d.')) {
          final String typeId = choice.substring('3d.'.length);
          for (final Wb3dObjectType type in Wb3dObjectType.values) {
            if (type.id == typeId) {
              controller.setRender3dType(type);
              controller.setTool(WbCanvasTool.render3d);
              return;
            }
          }
          return;
        }
        if (!choice.startsWith('pro.')) {
          return;
        }
        final String id = choice.substring('pro.'.length);
        for (final WbQuickCreateKind kind in WbQuickCreateKind.values) {
          if (kind.id == id) {
            onCreate?.call(kind);
            return;
          }
        }
    }
  }

  /// 导航类工具（M3 只读收窄时保留可用：选择 / 手）。
  static bool _isNavigationTool(WbCanvasTool tool) =>
      tool == WbCanvasTool.select || tool == WbCanvasTool.hand;

  static IconData _iconForTool(WbCanvasTool tool) {
    switch (tool) {
      case WbCanvasTool.select:
        return LinearIcons.select;
      case WbCanvasTool.hand:
        return LinearIcons.hand;
      case WbCanvasTool.pen:
        return LinearIcons.pen;
      case WbCanvasTool.highlighter:
        return LinearIcons.highlighter;
      case WbCanvasTool.eraser:
        return LinearIcons.eraser;
      case WbCanvasTool.note:
        return LinearIcons.stickyNote;
      case WbCanvasTool.text:
        return LinearIcons.text;
      case WbCanvasTool.shape:
        return LinearIcons.shape;
      case WbCanvasTool.image:
        return LinearIcons.image;
      case WbCanvasTool.connector:
        return LinearIcons.connector;
      case WbCanvasTool.render3d:
        return LinearIcons.cube;
    }
  }

  // ---- 参数行 -----------------------------------------------------------

  Widget? _optionsRow(WbThemeColors colors, BuildContext context) {
    switch (controller.tool) {
      case WbCanvasTool.note:
        return _swatchRow(
          prefix: 'note',
          label: '便签颜色',
          palette: WbCanvasPalette.noteColors,
          current: controller.noteColor,
          onPick: controller.setNoteColor,
        );
      case WbCanvasTool.shape:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final WbShapeKind kind in WbShapeKind.values) ...<Widget>[
              if (kind != WbShapeKind.values.first)
                const SizedBox(width: 4),
              _ShapeKindButton(
                key: ValueKey<String>('wb-canvas-shape-kind-${kind.id}'),
                kind: kind,
                active: controller.shapeKind == kind,
                onTap: () => controller.setShapeKind(kind),
              ),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Container(width: 1, height: 18, color: colors.border),
            ),
            _swatchRow(
              prefix: 'shape',
              label: '形状颜色',
              palette: WbCanvasPalette.shapeColors,
              current: controller.shapeColor,
              onPick: controller.setShapeColor,
            ),
          ],
        );
      case WbCanvasTool.render3d:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final Wb3dObjectType type in Wb3dObjectType.values) ...<Widget>[
              if (type != Wb3dObjectType.values.first)
                const SizedBox(width: 4),
              _ObjectTypeButton(
                key: ValueKey<String>('wb-canvas-3d-type-${type.id}'),
                type: type,
                active: controller.render3dType == type,
                onTap: () => controller.setRender3dType(type),
              ),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Container(width: 1, height: 18, color: colors.border),
            ),
            Text(
              '单击或拖拽一次放置 3D 模型；拖动旋转、滚轮缩放、双击编辑',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.icon),
            ),
          ],
        );
      case WbCanvasTool.pen:
      case WbCanvasTool.highlighter:
      case WbCanvasTool.connector:
        final bool highlight = controller.tool == WbCanvasTool.highlighter;
        final int highlightAlpha = controller.highlightColor & 0xFF000000;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _swatchRow(
              prefix: 'pen',
              label: highlight ? '荧光笔颜色' : '画笔颜色',
              palette: highlight
                  ? <int>[
                      for (final int c in WbCanvasPalette.penColors)
                        (c & 0x00FFFFFF) | highlightAlpha,
                    ]
                  : WbCanvasPalette.penColors,
              current:
                  highlight ? controller.highlightColor : controller.penColor,
              onPick: highlight
                  ? controller.setHighlightColor
                  : controller.setPenColor,
            ),
            if (!highlight && controller.tool == WbCanvasTool.pen) ...<Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Container(width: 1, height: 18, color: colors.border),
              ),
              for (final WbPenStyle style in WbPenStyle.values)
                _StyleChip(
                  key: ValueKey<String>('wb-canvas-pen-style-${style.id}'),
                  label: style.label,
                  active: controller.penStyle == style,
                  onTap: () => controller.setPenStyle(style),
                ),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Container(width: 1, height: 18, color: colors.border),
            ),
            for (int i = 0; i < WbCanvasPalette.penWidths.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: 4),
              _WidthDot(
                key: ValueKey<String>('wb-canvas-pen-width-$i'),
                width: WbCanvasPalette.penWidths[i],
                active: controller.penWidth == WbCanvasPalette.penWidths[i],
                onTap: () =>
                    controller.setPenWidth(WbCanvasPalette.penWidths[i]),
              ),
            ],
          ],
        );
      case WbCanvasTool.select:
        if (!controller.hasSingleRender3dSelection) {
          return null;
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            WbCanvasIconButton(
              key: const Key('wb-canvas-3d-paint-toggle'),
              icon: LinearIcons.fillColor,
              tooltip: '表面涂色（点击面着色，再点取消）',
              active: controller.render3dPaintMode,
              onTap: () => controller.setRender3dPaintMode(
                !controller.render3dPaintMode,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Container(width: 1, height: 18, color: colors.border),
            ),
            _swatchRow(
              prefix: '3d-paint',
              label: '表面颜色',
              palette: WbCanvasPalette.shapeColors,
              current: controller.render3dPaintColor,
              onPick: controller.setRender3dPaintColor,
            ),
            const SizedBox(width: 10),
            Text(
              '点击表面涂色（再点取消）；拖动旋转，Shift+拖动移动',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.icon),
            ),
          ],
        );
      case WbCanvasTool.hand:
      case WbCanvasTool.eraser:
      case WbCanvasTool.text:
      case WbCanvasTool.image:
        return null;
    }
  }

  Widget _swatchRow({
    required String prefix,
    required String label,
    required List<int> palette,
    required int current,
    required ValueChanged<int> onPick,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < palette.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          _SwatchButton(
            key: ValueKey<String>('wb-canvas-$prefix-color-$i'),
            color: Color(palette[i]),
            active: current == palette[i],
            tooltip: '$label ${i + 1}',
            onTap: () => onPick(palette[i]),
          ),
        ],
      ],
    );
  }
}

// ---- 参数行子控件 ---------------------------------------------------------

/// 「更多」菜单行（图标 + 文本）。
class _WbMoreMenuRow extends StatelessWidget {
  const _WbMoreMenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 16, color: colors.toolbarIcon),
        const SizedBox(width: 8),
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: colors.icon),
        ),
      ],
    );
  }
}

class _SwatchButton extends StatelessWidget {
  const _SwatchButton({
    super.key,
    required this.color,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  final Color color;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: active ? colors.primary : colors.border,
                width: active ? 2 : 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShapeKindButton extends StatelessWidget {
  const _ShapeKindButton({
    super.key,
    required this.kind,
    required this.active,
    required this.onTap,
  });

  final WbShapeKind kind;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final Color glyph = active ? colors.primary : colors.toolbarIcon;
    return Tooltip(
      message: '${kind.label}形状',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 28,
            height: 28,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: active
                  ? colors.primary.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: CustomPaint(
              painter: _ShapeGlyphPainter(kind: kind, color: glyph),
            ),
          ),
        ),
      ),
    );
  }
}

/// 3D 对象类型按钮（文本 label + active 高亮）。
class _ObjectTypeButton extends StatelessWidget {
  const _ObjectTypeButton({
    super.key,
    required this.type,
    required this.active,
    required this.onTap,
  });

  final Wb3dObjectType type;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Tooltip(
      message: '${type.label}直绘',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 7),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active
                  ? colors.primary.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              type.label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: active ? colors.primary : colors.toolbarIcon,
                    fontWeight: active ? FontWeight.w600 : null,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 画笔笔触按钮。
class _StyleChip extends StatelessWidget {
  const _StyleChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? colors.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: active ? colors.primary : colors.toolbarIcon,
                  fontWeight: active ? FontWeight.w600 : null,
                ),
          ),
        ),
      ),
    );
  }
}

class _WidthDot extends StatelessWidget {
  const _WidthDot({
    super.key,
    required this.width,
    required this.active,
    required this.onTap,
  });

  final double width;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Tooltip(
      message: '画笔粗细 ${width.toInt()}',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active
                  ? colors.primary.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Container(
              width: width + 6,
              height: width + 6,
              decoration: BoxDecoration(
                color: colors.toolbarIcon,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShapeGlyphPainter extends CustomPainter {
  const _ShapeGlyphPainter({required this.kind, required this.color});

  final WbShapeKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = color;
    final Rect rect = Rect.fromLTWH(2, 2, size.width - 4, size.height - 4);
    switch (kind) {
      case WbShapeKind.rect:
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(2)),
          paint,
        );
      case WbShapeKind.ellipse:
        canvas.drawOval(rect, paint);
      case WbShapeKind.diamond:
        final Path path = Path()
          ..moveTo(rect.center.dx, rect.top)
          ..lineTo(rect.right, rect.center.dy)
          ..lineTo(rect.center.dx, rect.bottom)
          ..lineTo(rect.left, rect.center.dy)
          ..close();
        canvas.drawPath(path, paint);
      case WbShapeKind.parallelogram:
        final double skew = rect.width * 0.25;
        final Path path = Path()
          ..moveTo(rect.left + skew, rect.top)
          ..lineTo(rect.right, rect.top)
          ..lineTo(rect.right - skew, rect.bottom)
          ..lineTo(rect.left, rect.bottom)
          ..close();
        canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_ShapeGlyphPainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.color != color;
}
