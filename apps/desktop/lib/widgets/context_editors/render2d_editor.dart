/// 2D 图元上下文编辑器（圆盘「函数 / 3D / 2D」组 render2d 入口）。
///
/// 依据《渲染引擎设计》2D 图元能力的演示口径实现：
/// - **图元类型**：正多边形 / 星形 / 圆环（[WbRender2dPrimitive]）；
/// - **参数**：边数（角数）/ 线宽 / 是否填充；
/// - **颜色**：取自 [WbContextPalette.swatches]（与画布元素同色板口径）。
///
/// 预览区为内置矢量绘制器（[WbRender2dPainter]，纯 Dart、无第三方依赖），
/// 同一绘制器在画布渲染专业元素时复用（见 `canvas_painter.dart` 集成）。
///
/// 组件自包含（无 Provider / FFI 依赖），通过 [WbRender2dEditor.onChanged]
/// 上报最新图元场景，由集成层决定插入画布与落盘方式。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import 'context_editor_shell.dart';

/// 2D 图元类型（极简三件套：多边形 / 星形 / 圆环）。
enum WbRender2dPrimitive {
  /// 正多边形。
  polygon('polygon', '多边形'),

  /// 星形（等角星）。
  star('star', '星形'),

  /// 圆环。
  ring('ring', '圆环');

  const WbRender2dPrimitive(this.id, this.label);

  /// 稳定 id（跨端序列化用）。
  final String id;

  /// 中文显示名。
  final String label;
}

/// 2D 图元场景（不可变）：类型 / 边数（角数）/ 线宽 / 填充 / 颜色。
@immutable
class WbRender2dScene {
  /// 创建场景。
  const WbRender2dScene({
    this.primitive = WbRender2dPrimitive.polygon,
    this.count = 6,
    this.thickness = 2,
    this.filled = false,
    this.color = WbContextPalette.defaultElementColor,
  });

  /// 图元类型。
  final WbRender2dPrimitive primitive;

  /// 边数（多边形 3..10）/ 角数（星形 5..12）；圆环忽略。
  final int count;

  /// 线宽（1..8）。
  final double thickness;

  /// 是否浅色填充。
  final bool filled;

  /// 主色。
  final Color color;

  /// 复制并覆盖字段。
  WbRender2dScene copyWith({
    WbRender2dPrimitive? primitive,
    int? count,
    double? thickness,
    bool? filled,
    Color? color,
  }) {
    return WbRender2dScene(
      primitive: primitive ?? this.primitive,
      count: count ?? this.count,
      thickness: thickness ?? this.thickness,
      filled: filled ?? this.filled,
      color: color ?? this.color,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is WbRender2dScene &&
        other.primitive == primitive &&
        other.count == count &&
        other.thickness == thickness &&
        other.filled == filled &&
        other.color.toARGB32() == color.toARGB32();
  }

  @override
  int get hashCode => Object.hash(
        primitive,
        count,
        thickness,
        filled,
        color.toARGB32(),
      );
}

/// 2D 图元矢量绘制器（编辑器预览与画布元素渲染共用）。
class WbRender2dPainter extends CustomPainter {
  /// 创建绘制器。
  const WbRender2dPainter({
    required this.scene,
    this.fillAlpha = 0.12,
  });

  /// 图元场景。
  final WbRender2dScene scene;

  /// 填充透明度（与画布形状元素「淡底彩边」风格一致）。
  final double fillAlpha;

  /// 外接半径占短边比例（世界 / 屏幕统一口径）。
  static const double radiusRatio = 0.36;

  /// 圆环内径比。
  static const double ringInnerRatio = 0.62;

  /// 星形内半径比。
  static const double starInnerRatio = 0.45;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.shortestSide <= 0) {
      return;
    }
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = math.min(size.width, size.height) * radiusRatio;
    final Color color = scene.color;
    final Path path = _buildPath(center, radius);
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = scene.thickness
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    if (scene.filled) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.fill
          ..color = color.withValues(alpha: fillAlpha),
      );
    }
    canvas.drawPath(path, stroke);
  }

  Path _buildPath(Offset center, double radius) {
    switch (scene.primitive) {
      case WbRender2dPrimitive.polygon:
        return _polygonPath(center, radius, scene.count.clamp(3, 10));
      case WbRender2dPrimitive.star:
        return _starPath(center, radius, scene.count.clamp(5, 12));
      case WbRender2dPrimitive.ring:
        return Path()
          ..fillType = PathFillType.evenOdd
          ..addOval(Rect.fromCircle(center: center, radius: radius))
          ..addOval(
            Rect.fromCircle(
              center: center,
              radius: radius * ringInnerRatio,
            ),
          );
    }
  }

  static Path _polygonPath(Offset center, double radius, int sides) {
    final Path path = Path();
    for (int i = 0; i < sides; i++) {
      final double angle = -math.pi / 2 + 2 * math.pi * i / sides;
      final Offset point =
          center + Offset(math.cos(angle), math.sin(angle)) * radius;
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    return path;
  }

  static Path _starPath(Offset center, double radius, int points) {
    final Path path = Path();
    for (int i = 0; i < points * 2; i++) {
      final double r = i.isEven ? radius : radius * starInnerRatio;
      final double angle = -math.pi / 2 + math.pi * i / points;
      final Offset point = center + Offset(math.cos(angle), math.sin(angle)) * r;
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(WbRender2dPainter oldDelegate) =>
      oldDelegate.scene != scene || oldDelegate.fillAlpha != fillAlpha;
}

/// 2D 图元上下文编辑器。
class WbRender2dEditor extends StatefulWidget {
  /// 创建编辑器。
  const WbRender2dEditor({
    super.key,
    this.initialScene,
    this.onChanged,
    this.onClose,
    this.width = WbContextMetrics.defaultWidth,
  });

  /// 初始场景（null 使用默认多边形场景）。
  final WbRender2dScene? initialScene;

  /// 场景变更回调。
  final ValueChanged<WbRender2dScene>? onChanged;

  /// 关闭回调。
  final VoidCallback? onClose;

  /// 面板宽度。
  final double width;

  @override
  State<WbRender2dEditor> createState() => _WbRender2dEditorState();
}

class _WbRender2dEditorState extends State<WbRender2dEditor> {
  late WbRender2dScene _scene;

  @override
  void initState() {
    super.initState();
    _scene = widget.initialScene ?? const WbRender2dScene();
  }

  void _update(WbRender2dScene next) {
    if (next == _scene) {
      return;
    }
    setState(() => _scene = next);
    widget.onChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final bool isRing = _scene.primitive == WbRender2dPrimitive.ring;
    final bool isStar = _scene.primitive == WbRender2dPrimitive.star;
    return WbContextEditorShell(
      title: '2D 图元',
      icon: LinearIcons.shape,
      subtitle: '多边形 / 星形 / 圆环（矢量预览）',
      onClose: widget.onClose,
      width: widget.width,
      child: SingleChildScrollView(
        padding: WbContextMetrics.panelPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Container(
                key: const ValueKey<String>('wb-ctx-render2d-preview'),
                decoration: BoxDecoration(
                  color: colors.canvas.withValues(alpha: 0.6),
                  borderRadius:
                      BorderRadius.circular(WbContextMetrics.controlRadius),
                  border: Border.all(color: colors.cardBorder),
                ),
                child: CustomPaint(
                  painter: WbRender2dPainter(scene: _scene),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const WbEditorSectionTitle(title: '图元类型'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final WbRender2dPrimitive primitive
                    in WbRender2dPrimitive.values)
                  WbEditorChip(
                    key: ValueKey<String>(
                      'wb-ctx-render2d-kind-${primitive.id}',
                    ),
                    label: primitive.label,
                    selected: _scene.primitive == primitive,
                    onTap: () => _update(_scene.copyWith(primitive: primitive)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const WbEditorSectionTitle(title: '参数'),
            if (!isRing)
              WbEditorSlider(
                label: isStar ? '角数' : '边数',
                value: _scene.count.toDouble(),
                min: isStar ? 5 : 3,
                max: isStar ? 12 : 10,
                divisions: isStar ? 7 : 7,
                valueLabel: '${_scene.count}',
                onChanged: (double value) =>
                    _update(_scene.copyWith(count: value.round())),
              ),
            WbEditorSlider(
              label: '线宽',
              value: _scene.thickness,
              min: 1,
              max: 8,
              divisions: 7,
              onChanged: (double value) =>
                  _update(_scene.copyWith(thickness: value)),
            ),
            WbEditorSwitchRow(
              label: '浅色填充',
              value: _scene.filled,
              onChanged: (bool value) =>
                  _update(_scene.copyWith(filled: value)),
            ),
            const SizedBox(height: 12),
            const WbEditorSectionTitle(title: '颜色'),
            WbEditorColorRow(
              keyPrefix: 'wb-ctx-render2d-color',
              colors: WbContextPalette.swatches,
              selected: _scene.color,
              onSelect: (Color color) => _update(_scene.copyWith(color: color)),
            ),
            const SizedBox(height: 10),
            const WbEditorHint('提示：关闭编辑器后图元将插入画布，可用 Ctrl+Z 撤销。'),
          ],
        ),
      ),
    );
  }
}
