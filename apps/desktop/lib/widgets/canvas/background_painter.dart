/// 页面背景共享绘制：解析背景 JSON、绘制底色 / 图案 / 背景图片。
///
/// - [WbPageBackground]：背景 JSON 的内存视图（对齐 background 域存储形态：
///   `pattern` / `baseColor` / `patternColor` / `spacing` / `opacity` /
///   `imagePath`）；
/// - [paintWbBackgroundPattern] / [WbBackgroundPatternPainter]：
///   solid / dot / grid / lined / squared 图案绘制（设置页预览、页面缩略图
///   与画布共享同一实现）；
/// - [WbPageBackgroundLayer]：底色 + 背景图片 + 图案的 Widget 组合
///   （缩略图 / 预览块使用；画布端由 `WbCanvasPainter` 直接在 Canvas 上绘制）。
library;

import 'package:flutter/widgets.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

/// 页面背景（不可变值对象）。
///
/// 字段命名与 `WbThemeState.backgroundJsonOf` / `WbBackgroundPreset.toBackgroundJson`
/// 的输出保持一致；`imagePath` 为本轮扩展字段（绝对路径引用源文件）。
@immutable
class WbPageBackground {
  const WbPageBackground({
    this.type = 'solid',
    required this.baseColor,
    this.patternColor,
    this.spacing = 0,
    this.opacity = 1,
    this.imagePath = '',
  });

  /// 图案类型：solid / dot / grid / lined / squared。
  final String type;

  /// 底色。
  final Color baseColor;

  /// 图案色（null 时不绘制图案）。
  final Color? patternColor;

  /// 图案间距（逻辑像素；<= 0 时使用默认 20）。
  final double spacing;

  /// 图案不透明度（0–1）。
  final double opacity;

  /// 背景图片绝对路径（空串 = 无背景图）。
  final String imagePath;

  /// 是否有背景图片。
  bool get hasImage => imagePath.isNotEmpty;

  /// 是否需要绘制图案。
  bool get hasPattern =>
      type != 'solid' && patternColor != null && opacity > 0;

  /// 解析页面背景 JSON。
  ///
  /// 兼容字段别名：`pattern`/`type`、`baseColor`/`color`、
  /// `patternColor`/`lineColor`；缺失或非法时回退 [fallback] 底色 + 纯色。
  factory WbPageBackground.fromJson(
    Map<String, dynamic> json, {
    required Color fallback,
  }) {
    Color readColor(Object? value) {
      if (value is int) {
        return Color(value);
      }
      if (value is String && value.trim().isNotEmpty) {
        return WbColorUtils.fromHex(value.trim(), fallback: fallback);
      }
      return fallback;
    }

    final String type =
        json['pattern'] is String && (json['pattern'] as String).isNotEmpty
            ? json['pattern'] as String
            : 'solid';
    final Object? patternColorRaw = json['patternColor'] ?? json['lineColor'];
    final bool hasPatternColor =
        patternColorRaw is int || (patternColorRaw is String && patternColorRaw.trim().isNotEmpty);
    final double spacing =
        json['spacing'] is num ? (json['spacing'] as num).toDouble() : 0;
    final double opacity = json['opacity'] is num
        ? (json['opacity'] as num).toDouble().clamp(0.0, 1.0)
        : 1.0;
    final String imagePath =
        json['imagePath'] is String ? json['imagePath'] as String : '';
    return WbPageBackground(
      type: type,
      baseColor: readColor(json['baseColor'] ?? json['color']),
      patternColor: hasPatternColor ? readColor(patternColorRaw) : null,
      spacing: spacing,
      opacity: opacity,
      imagePath: imagePath,
    );
  }

  /// 复制并覆盖若干字段。
  WbPageBackground copyWith({
    String? type,
    Color? baseColor,
    Color? patternColor,
    double? spacing,
    double? opacity,
    String? imagePath,
  }) {
    return WbPageBackground(
      type: type ?? this.type,
      baseColor: baseColor ?? this.baseColor,
      patternColor: patternColor ?? this.patternColor,
      spacing: spacing ?? this.spacing,
      opacity: opacity ?? this.opacity,
      imagePath: imagePath ?? this.imagePath,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WbPageBackground &&
      other.type == type &&
      other.baseColor == baseColor &&
      other.patternColor == patternColor &&
      other.spacing == spacing &&
      other.opacity == opacity &&
      other.imagePath == imagePath;

  @override
  int get hashCode =>
      Object.hash(type, baseColor, patternColor, spacing, opacity, imagePath);

  @override
  String toString() =>
      'WbPageBackground($type, $baseColor, image=$imagePath)';
}

/// 绘制背景图案（dot 圆点 / grid 双向线 / lined 横线 / squared 方格）。
///
/// 画布与预览共享：`type == 'solid'`、图案色缺失或透明度为 0 时直接返回。
void paintWbBackgroundPattern(
  Canvas canvas,
  Size size, {
  required String type,
  required Color? patternColor,
  required double spacing,
  double opacity = 1.0,
}) {
  if (type == 'solid' || patternColor == null || opacity <= 0 || size.isEmpty) {
    return;
  }
  final double step = (spacing <= 0 ? 20.0 : spacing)
      .clamp(6.0, size.shortestSide / 2)
      .toDouble();
  final Paint linePaint = Paint()
    ..color = patternColor.withValues(alpha: patternColor.a * opacity)
    ..strokeWidth = 1
    ..style = PaintingStyle.stroke;
  switch (type) {
    case 'dot':
      final Paint dotPaint = Paint()..color = linePaint.color;
      for (double y = step; y < size.height; y += step) {
        for (double x = step; x < size.width; x += step) {
          canvas.drawCircle(Offset(x, y), 1.2, dotPaint);
        }
      }
    case 'grid':
    case 'squared':
      for (double x = step; x < size.width; x += step) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
      }
      for (double y = step; y < size.height; y += step) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
      }
    case 'lined':
      for (double y = step; y < size.height; y += step) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
      }
    default:
      return;
  }
}

/// 图案画笔（CustomPaint 包装，供预览块 / 缩略图使用）。
class WbBackgroundPatternPainter extends CustomPainter {
  const WbBackgroundPatternPainter({
    required this.type,
    required this.patternColor,
    required this.spacing,
    this.opacity = 1.0,
  });

  /// 图案类型。
  final String type;

  /// 图案色。
  final Color? patternColor;

  /// 图案间距。
  final double spacing;

  /// 图案不透明度。
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    paintWbBackgroundPattern(
      canvas,
      size,
      type: type,
      patternColor: patternColor,
      spacing: spacing,
      opacity: opacity,
    );
  }

  @override
  bool shouldRepaint(covariant WbBackgroundPatternPainter oldDelegate) =>
      oldDelegate.type != type ||
      oldDelegate.patternColor != patternColor ||
      oldDelegate.spacing != spacing ||
      oldDelegate.opacity != opacity;
}

/// 背景层（Widget 组合：底色 + 背景图片 + 图案 + 内容）。
///
/// [imageBuilder] 由调用方提供图片 Widget（缩略图用 `Image.file`）；
/// 背景无图片或未提供构建器时跳过图片层。图案绘制在图片之上，
/// 内容（如元素数文本）绘制在最上层。
class WbPageBackgroundLayer extends StatelessWidget {
  const WbPageBackgroundLayer({
    super.key,
    required this.background,
    this.imageBuilder,
    this.child,
  });

  /// 背景配置。
  final WbPageBackground background;

  /// 背景图片构建器（可选）。
  final WidgetBuilder? imageBuilder;

  /// 叠在背景上的内容（居中显示）。
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final bool showImage = background.hasImage && imageBuilder != null;
    return Container(
      color: background.baseColor,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (showImage) imageBuilder!(context),
          if (background.hasPattern)
            CustomPaint(
              painter: WbBackgroundPatternPainter(
                type: background.type,
                patternColor: background.patternColor,
                spacing: background.spacing,
                opacity: background.opacity,
              ),
            ),
          if (child != null) Center(child: child),
        ],
      ),
    );
  }
}
