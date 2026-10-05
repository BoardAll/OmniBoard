/// 画布绘制器：网格背景、元素、手势预览与选择 overlay。
///
/// 坐标策略：
/// - 背景与网格在**屏幕空间**绘制（网格步长随缩放自适应，保持 12–96px）；
/// - 元素与笔迹预览在**世界空间**绘制（`translate(offset) + scale(scale)`）；
/// - 创建预览、框选、选择框与缩放柄在**屏幕空间 overlay** 绘制（线宽恒定）。
///
/// 通过 `super(repaint: controller)` 绑定控制器：状态变更即局部重绘，
/// 配合 `RepaintBoundary` 与画布视口隔离，避免整页 rebuild。
library;

import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../context_editors/flow_components.dart';
import '../context_editors/render3d_editor.dart';
import 'background_painter.dart';
import 'canvas_image_cache.dart';
import 'canvas_controller.dart';
import 'canvas_model.dart';
import 'professional_painter.dart';
import 'wb3d_projection.dart';

/// 画布绘制器（无状态；状态全部来自 [controller] 与 [textCache]）。
class WbCanvasPainter extends CustomPainter {
  /// 创建绘制器（通常由 `CanvasView` 构建）。
  WbCanvasPainter({
    required this.controller,
    required this.textCache,
    required this.canvasColor,
    required this.gridColor,
    required this.selectionColor,
    this.pageBackground,
  }) : super(
          repaint: Listenable.merge(
            <Listenable>[
              controller,
              controller.imageCache,
              // 组件图片（「我的组件」）解码完成自动重绘主画布。
              WbFlowComponentCache.instance,
            ],
          ),
        );

  /// 状态源（视口 / 元素 / 手势预览 / 选择）。
  final WbCanvasController controller;

  /// 文本布局缓存（便签正文 / 文本元素）。
  final WbCanvasTextCache textCache;

  /// 画布背景色（无页面背景时的底色）。
  final Color canvasColor;

  /// 网格线颜色。
  final Color gridColor;

  /// 选择框 / 框选 / 创建预览主色。
  final Color selectionColor;

  /// 页面背景（null = 主题底色 + 网格）。
  final WbPageBackground? pageBackground;

  /// 网格基础步长（世界单位）。
  static const double _gridBaseStep = 24;

  /// 网格屏幕步长下限。
  static const double _gridMinStep = 12;

  /// 网格屏幕步长上限。
  static const double _gridMaxStep = 96;

  /// 便签圆角半径（世界单位）。
  static const double _noteRadius = 8;

  /// 形状圆角半径（世界单位）。
  static const double _shapeRadius = 4;

  /// 图片占位圆角半径（世界单位）。
  static const double _imageRadius = 8;

  /// 选择控制点边长（屏幕像素）。
  static const double _handleSize = 8;

  static const Color _noteTextColor = Color(0xFF1F2933);
  static const Color _imageBorderColor = Color(0xFFCBD2DC);
  static const Color _imageGlyphColor = Color(0xFF98A2B3);
  static const Color _lockBadgeColor = Color(0xFFE8590C);

  @override
  void paint(Canvas canvas, Size size) {
    final WbPageBackground? background = pageBackground;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = background?.baseColor ?? canvasColor,
    );
    if (background != null) {
      _paintBackgroundImage(canvas, size, background);
      paintWbBackgroundPattern(
        canvas,
        size,
        type: background.type,
        patternColor: background.patternColor,
        spacing: background.spacing,
        opacity: background.opacity,
      );
    } else {
      // 未设置页面背景时才显示默认辅助网格；设置任意背景（纯色 / 点 /
      // 方格 / 线 / 图片）只显示背景本身，不再叠加默认方格。
      _paintGrid(canvas, size);
    }

    final double scale = controller.scale;
    final Offset offset = controller.offset;

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale, scale);

    // 视口外的元素跳过（世界单位下外扩，保证描边 / 阴影不截断）。
    final Rect visibleWorld = controller.visibleWorldRect.inflate(64 / scale);
    for (final WbCanvasElement element in controller.elements) {
      if (!element.visible) {
        continue;
      }
      // 远端变换鬼影（M2）：以目标几何临时变换绘制（不落模型）。
      final WbRemoteTransformOverlay? overlay =
          controller.remoteTransformOverlay(element);
      final WbCanvasElement painted = overlay?.element ?? element;
      if (!element.bounds.overlaps(visibleWorld) &&
          !painted.bounds.overlaps(visibleWorld)) {
        continue;
      }
      if (overlay != null && overlay.alpha < 1) {
        canvas.saveLayer(
          element.bounds
              .expandToInclude(painted.bounds)
              .inflate(16 / scale),
          Paint()
            ..color =
                const Color(0xFF000000).withValues(alpha: overlay.alpha),
        );
        _paintElement(canvas, painted);
        canvas.restore();
        continue;
      }
      _paintElement(canvas, painted);
    }
    _paintRemoteInkGhosts(canvas);
    _paintRemoteFadeOuts(canvas);
    _paintStrokePreview(canvas);
    canvas.restore();

    _paintCreatePreview(canvas);
    _paintMarquee(canvas);
    _paintSelection(canvas);
    _paintRemoteLockBadges(canvas);
  }

  // ---- 背景 -------------------------------------------------------------

  /// 背景图片（cover 铺满视口；未解码时请求后台加载，完成后重绘）。
  void _paintBackgroundImage(
    Canvas canvas,
    Size size,
    WbPageBackground background,
  ) {
    if (!background.hasImage || size.isEmpty) {
      return;
    }
    final WbCanvasImageCache cache = controller.imageCache;
    final ui.Image? image = cache.imageFor(background.imagePath);
    if (image == null) {
      cache.request(background.imagePath);
      return;
    }
    canvas.drawImageRect(
      image,
      _coverSrcRect(image, size),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  /// cover 源矩形：等比放大填充目标尺寸后取中心裁剪区。
  static Rect _coverSrcRect(ui.Image image, Size size) {
    final double iw = image.width.toDouble();
    final double ih = image.height.toDouble();
    if (iw <= 0 || ih <= 0 || size.isEmpty) {
      return Rect.fromLTWH(0, 0, iw, ih);
    }
    final double scale = math.max(size.width / iw, size.height / ih);
    final double sw = math.min(iw, size.width / scale);
    final double sh = math.min(ih, size.height / scale);
    return Rect.fromCenter(
      center: Offset(iw / 2, ih / 2),
      width: sw,
      height: sh,
    );
  }

  void _paintGrid(Canvas canvas, Size size) {
    double step = _gridBaseStep * controller.scale;
    while (step < _gridMinStep) {
      step *= 2;
    }
    while (step > _gridMaxStep) {
      step /= 2;
    }
    final Paint line = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    final Offset offset = controller.offset;
    // Dart 的 `%` 为欧几里得取模（负偏移也返回非负余数），网格始终与
    // 世界原点对齐。
    for (double x = offset.dx % step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (double y = offset.dy % step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  // ---- 元素 -------------------------------------------------------------

  void _paintElement(Canvas canvas, WbCanvasElement element) {
    switch (element.type) {
      case WbElementKind.note:
        _paintNote(canvas, element);
      case WbElementKind.text:
        _paintTextElement(canvas, element);
      case WbElementKind.shape:
        _paintShape(canvas, element);
      case WbElementKind.image:
        _paintImage(canvas, element);
      case WbElementKind.drawing:
        _paintStroke(
          canvas,
          element.points,
          Color(element.color),
          element.strokeWidth,
        );
      case WbElementKind.connector:
        _paintConnector(canvas, element);
      case WbElementKind.flowchart:
      case WbElementKind.table:
      case WbElementKind.mindmap:
      case WbElementKind.function:
      case WbElementKind.render3d:
      case WbElementKind.render2d:
        _paintProfessional(canvas, element);
      default:
        // 引擎扩展的未知类型不绘制（前向兼容）。
        break;
    }
  }

  /// 专业元素：优先交给 [WbProfessionalRenderer]；payload 缺失
  /// （如引擎往返后）时画可辨识的占位框。
  void _paintProfessional(Canvas canvas, WbCanvasElement element) {
    if (WbProfessionalRenderer.paint(canvas, element, textCache)) {
      return;
    }
    final Rect rect = element.bounds;
    final RRect rrect =
        RRect.fromRectAndRadius(rect, const Radius.circular(_imageRadius));
    canvas.drawRRect(rrect, Paint()..color = const Color(WbCanvasPalette.imageFill));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _imageBorderColor,
    );
    final String label =
        '${WbProfessionalRenderer.labelFor(element.type)} · 待编辑';
    final TextPainter painter = textCache.layout(
      key: '${element.id}|pro-empty|$label|${rect.width}|${rect.height}',
      text: label,
      style: const TextStyle(
        fontSize: 13,
        color: Color(WbCanvasPalette.mutedTextColor),
      ),
      maxWidth: math.max(rect.width - 16, 1),
      align: TextAlign.center,
      maxLines: 1,
    );
    painter.paint(
      canvas,
      Offset(
        rect.center.dx - painter.width / 2,
        rect.center.dy - painter.height / 2,
      ),
    );
  }

  void _paintNote(Canvas canvas, WbCanvasElement element) {
    final Rect rect = element.bounds;
    final RRect rrect =
        RRect.fromRectAndRadius(rect, const Radius.circular(_noteRadius));
    canvas.drawRRect(rrect, Paint()..color = Color(element.color));

    final String text = element.text;
    if (text.isEmpty) {
      return;
    }
    const double padding = WbCanvasPalette.notePadding;
    final double fontSize = element.effectiveFontSize;
    final double lineHeight = fontSize * 1.35;
    final int maxLines =
        math.max(1, ((rect.height - padding * 2) / lineHeight).floor());
    final TextPainter painter = textCache.layout(
      key: '${element.id}|note|$text|${rect.width}|${rect.height}|'
          '$fontSize|${element.textAlign}',
      text: text,
      style: TextStyle(
        fontSize: fontSize,
        color: _noteTextColor,
        height: 1.35,
      ),
      maxWidth: rect.width - padding * 2,
      maxLines: maxLines,
      align: WbTextAlignId.toTextAlign(element.textAlign),
    );
    painter.paint(canvas, rect.topLeft + const Offset(padding, padding));
  }

  void _paintTextElement(Canvas canvas, WbCanvasElement element) {
    final String text = element.text;
    if (text.isEmpty) {
      return;
    }
    final Rect rect = element.bounds;
    final TextPainter painter = textCache.layout(
      key: '${element.id}|text|$text|${rect.width}|${element.color}|'
          '${element.effectiveFontSize}|${element.textAlign}',
      text: text,
      style: TextStyle(
        fontSize: element.effectiveFontSize,
        color: Color(element.color),
        height: 1.3,
      ),
      maxWidth: rect.width,
      align: WbTextAlignId.toTextAlign(element.textAlign),
    );
    final double dy = rect.top + math.max(0, (rect.height - painter.height) / 2);
    painter.paint(canvas, Offset(rect.left, dy));
  }

  void _paintShape(Canvas canvas, WbCanvasElement element) {
    final Rect rect = element.bounds;
    final Color color = Color(element.color);
    final Paint fill = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: 0.12);
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = element.strokeWidth
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    switch (element.shapeKind) {
      case WbShapeKindId.ellipse:
        final Rect deflated = rect.deflate(element.strokeWidth / 2);
        canvas.drawOval(deflated, fill);
        canvas.drawOval(deflated, stroke);
      case WbShapeKindId.diamond:
        final Path path = Path()
          ..moveTo(rect.center.dx, rect.top)
          ..lineTo(rect.right, rect.center.dy)
          ..lineTo(rect.center.dx, rect.bottom)
          ..lineTo(rect.left, rect.center.dy)
          ..close();
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
      case WbShapeKindId.parallelogram:
        final double skew = rect.width * 0.25;
        final Path path = Path()
          ..moveTo(rect.left + skew, rect.top)
          ..lineTo(rect.right, rect.top)
          ..lineTo(rect.right - skew, rect.bottom)
          ..lineTo(rect.left, rect.bottom)
          ..close();
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
      default:
        final RRect rrect =
            RRect.fromRectAndRadius(rect, const Radius.circular(_shapeRadius));
        canvas.drawRRect(rrect, fill);
        canvas.drawRRect(rrect, stroke);
    }
  }

  /// 连线：起止点直线 + 终点箭头（世界空间绘制，线宽随缩放）。
  void _paintConnector(Canvas canvas, WbCanvasElement element) {
    final List<Offset> points = element.points;
    if (points.length < 2) {
      return;
    }
    final Offset start = points.first;
    final Offset end = points.last;
    final double width = math.max(1, element.strokeWidth);
    final Color color = Color(element.color);
    canvas.drawLine(
      start,
      end,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
    final Offset direction = end - start;
    final double length = direction.distance;
    if (length < 0.5) {
      return;
    }
    final Offset unit = direction / length;
    final Offset normal = Offset(-unit.dy, unit.dx);
    final double headLength = math.max(10, width * 4);
    final Offset neck = end - unit * headLength;
    final double headHalf = headLength * 0.5;
    final Path head = Path()
      ..moveTo(end.dx, end.dy)
      ..lineTo(neck.dx + normal.dx * headHalf, neck.dy + normal.dy * headHalf)
      ..lineTo(neck.dx - normal.dx * headHalf, neck.dy - normal.dy * headHalf)
      ..close();
    canvas.drawPath(head, Paint()..color = color);
  }

  /// 图片元素：解码命中时 cover + 圆角裁切绘制；否则画占位图并请求加载。
  void _paintImage(Canvas canvas, WbCanvasElement element) {
    final String path = element.imagePath;
    final ui.Image? image =
        path.isEmpty ? null : controller.imageCache.imageFor(path);
    if (image == null) {
      if (path.isNotEmpty) {
        controller.imageCache.request(path);
      }
      _paintImagePlaceholder(canvas, element);
      return;
    }
    final Rect rect = element.bounds;
    final RRect rrect =
        RRect.fromRectAndRadius(rect, const Radius.circular(_imageRadius));
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawImageRect(
      image,
      _coverSrcRect(image, rect.size),
      rect,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = _imageBorderColor,
    );
  }

  /// 图片占位：圆角底板 + 山形 / 太阳矢量图案（无外部资源依赖）。
  void _paintImagePlaceholder(Canvas canvas, WbCanvasElement element) {
    final Rect rect = element.bounds;
    final RRect rrect =
        RRect.fromRectAndRadius(rect, const Radius.circular(_imageRadius));
    canvas.drawRRect(rrect, Paint()..color = Color(element.color));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = _imageBorderColor,
    );

    final double glyphHeight = math.min(rect.width * 0.5, rect.height * 0.5);
    if (glyphHeight < 16) {
      return;
    }
    final Rect area = Rect.fromCenter(
      center: rect.center,
      width: glyphHeight * 1.7,
      height: glyphHeight,
    );
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, glyphHeight * 0.08)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = _imageGlyphColor;
    final Path mountain = Path()
      ..moveTo(area.left, area.bottom)
      ..lineTo(area.left + area.width * 0.45, area.top)
      ..lineTo(area.right, area.bottom);
    canvas.drawPath(mountain, stroke);
    canvas.drawCircle(
      Offset(area.right - area.width * 0.14, area.top + area.height * 0.15),
      math.max(1.5, glyphHeight * 0.1),
      stroke,
    );
  }

  void _paintStroke(
    Canvas canvas,
    List<Offset> points,
    Color color,
    double width,
  ) {
    if (points.isEmpty) {
      return;
    }
    if (points.length == 1) {
      canvas.drawCircle(points.first, width / 2, Paint()..color = color);
      return;
    }
    final Path path = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  // ---- 手势预览 ---------------------------------------------------------

  void _paintStrokePreview(Canvas canvas) {
    final List<Offset>? stroke = controller.pendingStroke;
    if (stroke == null || stroke.isEmpty) {
      return;
    }
    final bool highlight = controller.tool == WbCanvasTool.highlighter;
    _paintStroke(
      canvas,
      stroke,
      highlight
          ? const Color(WbCanvasPalette.highlightColor)
          : Color(controller.penColor),
      highlight ? 14 : controller.penWidth,
    );
  }

  /// 远端笔迹鬼影（M2）：按 strokeId 缓冲的增量点连续绘制
  /// （缺口由直连线段兜底；荧光笔保留半透明底色）。
  void _paintRemoteInkGhosts(Canvas canvas) {
    final List<WbRemoteInkGhost> ghosts = controller.remoteInkGhosts;
    for (final WbRemoteInkGhost ghost in ghosts) {
      final List<Offset> points = ghost.points;
      if (points.isEmpty) {
        continue;
      }
      final Color color = Color(ghost.color);
      final Paint paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ghost.strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = _alphaColor(color, ghost.alpha);
      if (points.length == 1) {
        canvas.drawCircle(points.first, ghost.strokeWidth / 2, paint);
        continue;
      }
      final Path path = Path()..moveTo(points.first.dx, points.first.dy);
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  /// 远端删除淡出（M2）：保留删除前快照按
  /// [WbCanvasController.remoteFadeOutSeconds] 淡出。
  void _paintRemoteFadeOuts(Canvas canvas) {
    final List<WbRemoteFadeOut> fades = controller.remoteFadeOuts;
    for (final WbRemoteFadeOut fade in fades) {
      final double alpha = fade.alpha;
      if (alpha <= 0) {
        continue;
      }
      canvas.saveLayer(
        fade.element.bounds.inflate(16),
        Paint()..color = const Color(0xFF000000).withValues(alpha: alpha),
      );
      _paintElement(canvas, fade.element);
      canvas.restore();
    }
  }

  void _paintCreatePreview(Canvas canvas) {
    final Wb3dScene? scene3d = controller.render3dPreviewScene;
    final Rect? rect3d = controller.render3dPreviewRect;
    if (scene3d != null && rect3d != null) {
      // 3D 直绘：半透明投影预览（不画矩形创建预览）。
      _paintRender3dPreview(canvas, scene3d, rect3d);
      return;
    }
    final Offset? connectorStart = controller.connectorPreviewStart;
    if (connectorStart != null) {
      // 连线工具：屏幕空间直线预览（起止点由控制器给出世界坐标）。
      final Offset from = controller.worldToScreen(connectorStart);
      final Offset to = controller.worldToScreen(
        controller.connectorPreviewEnd ?? connectorStart,
      );
      canvas.drawLine(
        from,
        to,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = selectionColor,
      );
      return;
    }
    final Rect? preview = controller.createPreview;
    if (preview == null) {
      return;
    }
    final Rect screen = controller.worldRectToScreen(preview);
    if (screen.width < 0.5 || screen.height < 0.5) {
      return;
    }
    canvas.drawRect(
      screen,
      Paint()..color = selectionColor.withValues(alpha: 0.08),
    );
    _drawDashedRect(
      canvas,
      screen,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = selectionColor,
    );
  }

  /// 3D 直绘半透明预览（世界矩形 → 屏幕，按元素 fit 缩放投影后逐面绘制）。
  ///
  /// 缩放系数 = 元素内容 fit × 视口缩放：与
  /// `professional_painter.dart` 对 3D 元素的绘制口径一致。
  void _paintRender3dPreview(Canvas canvas, Wb3dScene scene, Rect worldRect) {
    final Rect screen = controller.worldRectToScreen(worldRect);
    if (screen.width < 2 || screen.height < 2) {
      return;
    }
    final double fit = Wb3dProjector.contentFit(worldRect.size);
    final Wb3dProjection projection = Wb3dProjector.project(
      scene: scene,
      size: const Size(300, 300),
      colors: WbThemeColors.lightDefaults,
    );
    canvas.save();
    canvas.translate(screen.center.dx, screen.center.dy);
    canvas.scale(fit * controller.scale);
    canvas.translate(-150, -150);
    for (final Wb3dProjectedFace face in projection.faces) {
      canvas.drawPath(
        face.path,
        Paint()..color = face.fill.withValues(alpha: 0.55),
      );
      canvas.drawPath(
        face.path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 / fit
          ..color = selectionColor.withValues(alpha: 0.85),
      );
    }
    canvas.restore();
  }

  void _paintMarquee(Canvas canvas) {
    final Rect? marquee = controller.marqueeRect;
    if (marquee == null) {
      return;
    }
    canvas.drawRect(
      marquee,
      Paint()..color = selectionColor.withValues(alpha: 0.08),
    );
    canvas.drawRect(
      marquee,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = selectionColor,
    );
  }

  void _paintSelection(Canvas canvas) {
    if (controller.editingElementId != null) {
      // 文本编辑中隐藏选择框，避免与输入框视觉重叠。
      return;
    }
    final Rect? bounds = controller.selectionBounds;
    if (bounds == null) {
      return;
    }
    final Rect screen = controller.worldRectToScreen(bounds);
    canvas.drawRect(
      screen,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = selectionColor,
    );
    final Paint handleFill = Paint()..color = const Color(0xFFFFFFFF);
    final Paint handleBorder = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = selectionColor;
    for (final WbSelectionHandle handle in WbSelectionHandle.values) {
      final Offset center = WbCanvasController.handlePosition(handle, screen);
      final RRect rrect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: center,
          width: _handleSize,
          height: _handleSize,
        ),
        const Radius.circular(2),
      );
      canvas.drawRRect(rrect, handleFill);
      canvas.drawRRect(rrect, handleBorder);
    }
    final Rect? badge = controller.sizeBadgeScreenRect;
    if (badge != null) {
      _paintSizeBadge(canvas, badge);
    }
  }

  /// 尺寸角标：圆角胶囊底 + 白色文本（3D / 2D 元素单选时显示宽高）。
  ///
  /// 几何由 [WbCanvasController.sizeBadgeScreenRect] 单一来源给出，
  /// 这里只绘制（每帧读取，缩放柄拖动 / 滚轮缩放时自动跟随）。
  void _paintSizeBadge(Canvas canvas, Rect rect) {
    final RRect rrect =
        RRect.fromRectAndRadius(rect, const Radius.circular(4));
    canvas.drawRRect(rrect, Paint()..color = const Color(0xE01F2933));
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: controller.sizeBadgeLabel,
        style: WbTypography.apply(
          const TextStyle(
            fontSize: 11,
            color: Color(0xFFFFFFFF),
          ),
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    painter.paint(
      canvas,
      Offset(
        rect.center.dx - painter.width / 2,
        rect.center.dy - painter.height / 2,
      ),
    );
  }

  // ---- 工具 -------------------------------------------------------------

  /// 屏幕空间虚线矩形（创建预览用）。
  void _drawDashedRect(
    Canvas canvas,
    Rect rect,
    Paint paint, {
    double dash = 6,
    double gap = 4,
  }) {
    if (rect.width <= 0 || rect.height <= 0) {
      return;
    }
    final Path path = Path()..addRect(rect);
    for (final PathMetric metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double end = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  /// 远端软锁角标（M2）：他人编辑中的元素加虚线框 + 「编辑中」标签。
  ///
  /// 屏幕空间绘制（线宽 / 字号恒定）；命中 / 拖动 / 双击等交互入口
  /// 已由控制器跳过，这里只做视觉标识（仍可查看）。
  void _paintRemoteLockBadges(Canvas canvas) {
    if (controller.remoteLocks.isEmpty) {
      return;
    }
    final double scale = controller.scale;
    for (final WbCanvasElement element in controller.elements) {
      final String? holder = controller.lockHolderOf(element.id);
      if (holder == null || holder.isEmpty || !element.visible) {
        continue;
      }
      final Rect screen =
          controller.worldRectToScreen(element.bounds.inflate(2 / scale));
      if (screen.width < 2 || screen.height < 2) {
        continue;
      }
      _drawDashedRect(
        canvas,
        screen,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = _lockBadgeColor,
        dash: 5,
        gap: 3,
      );
      _paintLockBadge(canvas, screen, holder);
    }
  }

  /// 「编辑中 · 短id」标签（元素上方；无身份时显示「其他成员」）。
  void _paintLockBadge(Canvas canvas, Rect screen, String holder) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: '编辑中 · ${_shortUserId(holder)}',
        style: WbTypography.apply(
          const TextStyle(fontSize: 10, color: Color(0xFFFFFFFF)),
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    final double top = screen.top - painter.height - 8 < 0
        ? screen.top + 2
        : screen.top - painter.height - 8;
    final Rect capsule = Rect.fromLTWH(
      screen.left,
      top,
      painter.width + 10,
      painter.height + 4,
    );
    final RRect rrect =
        RRect.fromRectAndRadius(capsule, const Radius.circular(3));
    canvas.drawRRect(rrect, Paint()..color = _lockBadgeColor);
    painter.paint(canvas, Offset(capsule.left + 5, capsule.top + 2));
  }

  /// 用户 id 短标签（尾 6 字符；空 id →「其他成员」）。
  static String _shortUserId(String userId) {
    if (userId.isEmpty) {
      return '其他成员';
    }
    return userId.length <= 6
        ? userId
        : userId.substring(userId.length - 6);
  }

  /// 按 [alpha]（0–1）缩放颜色现有不透明度。
  static Color _alphaColor(Color color, double alpha) =>
      color.withValues(alpha: color.a * alpha);

  @override
  bool shouldRepaint(WbCanvasPainter oldDelegate) =>
      oldDelegate.controller != controller ||
      oldDelegate.textCache != textCache ||
      oldDelegate.canvasColor != canvasColor ||
      oldDelegate.gridColor != gridColor ||
      oldDelegate.selectionColor != selectionColor ||
      oldDelegate.pageBackground != pageBackground;
}
