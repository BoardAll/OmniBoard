/// 专业元素画布渲染：把编辑器模型（[WbCanvasElement.payload]）绘制到
/// 画布元素的矩形区域内（问题 9：流程图 / 表格 / 思维导图 / 函数图像 /
/// 3D / 2D 插入画布后可见）。
///
/// 设计：
/// - [measure]：按模型外接矩形给出插入尺寸建议（+ [inset] 留白）；
/// - [paint]：统一「中心对齐 + 等比缩放」把模型内容适配到元素矩形，
///   元素被移动 / 缩放时内容跟随；模型坐标即绘制坐标；
/// - 复用各编辑器已公开的 Painter（节点 / 连线 / 导图边 / 函数图像 /
///   3D 网格 / 2D 图元），主题色固定取亮色默认集（画布口径）；
/// - [payload] 缺失或类型不符时返回 false，宿主画占位框。
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:whiteboard_theme/theme.dart';

import '../context_editors/context_editor_shell.dart';
import '../context_editors/flowchart_editor.dart';
import '../context_editors/function_editor.dart';
import '../context_editors/mindmap_editor.dart';
import '../context_editors/render2d_editor.dart';
import '../context_editors/render3d_editor.dart';
import '../context_editors/table_editor.dart';
import 'canvas_model.dart';

/// 专业元素绘制器（纯静态工具类）。
abstract final class WbProfessionalRenderer {
  /// 逻辑布局画布（思维导图布局的输入尺寸，与编辑器预览一致）。
  static const Size layoutCanvas = Size(420, 320);

  /// 渲染 / 测量共用主题色（画布元素固定亮色口径）。
  static const WbThemeColors colors = WbThemeColors.lightDefaults;

  /// 表格单元格宽 / 高（与编辑器预览一致）。
  static const double tableCellWidth = 112;
  static const double tableCellHeight = 34;

  /// 内容与元素边界之间的留白（世界单位）。
  static const double inset = 16;

  /// 函数图像 / 3D / 2D 的基准内容尺寸（等比缩放适配元素）。
  static const Size _functionSize = Size(360, 270);
  static const Size _render3dSize = Size(300, 300);
  static const Size _render2dSize = Size(260, 260);

  /// 函数图像表达式图例最多显示的曲线条目数。
  static const int maxFunctionLegendEntries = 8;

  /// 中文类型名（缺失 payload 的占位文案用；未知类型返回原 id）。
  static String labelFor(String type) => switch (type) {
        WbElementKind.flowchart => '流程图',
        WbElementKind.table => '表格',
        WbElementKind.mindmap => '思维导图',
        WbElementKind.function => '函数图像',
        WbElementKind.render3d => '3D 对象',
        WbElementKind.render2d => '2D 图元',
        _ => type,
      };

  /// 插入尺寸建议（模型外接矩形 + 两侧留白；最小 140 x 90）。
  ///
  /// [payload] 缺失或类型不符返回 null（调用方回退默认尺寸）。
  static Size? measure(String type, Object? payload) {
    final Rect? bounds = _modelBounds(type, payload);
    if (bounds == null) {
      return null;
    }
    return Size(
      math.max(bounds.width + inset * 2, 140),
      math.max(bounds.height + inset * 2, 90),
    );
  }

  /// 绘制 [element]（模型取自 `element.payload`）。
  ///
  /// 返回 false 表示无法渲染（payload 缺失 / 类型不符），宿主应画占位。
  static bool paint(
    Canvas canvas,
    WbCanvasElement element,
    WbCanvasTextCache textCache,
  ) {
    final Object? payload = element.payload;
    if (payload == null || !_isCompatible(element.type, payload)) {
      return false;
    }
    final Rect modelBounds = _modelBounds(element.type, payload)!;
    final Size content = modelBounds.size;

    // 等比缩放适配元素矩形（插入时恰为 1.0；元素被缩放后内容跟随）。
    final double fit = math.min(
      (element.width - inset * 2) / content.width,
      (element.height - inset * 2) / content.height,
    );
    final double scale = fit < 0.05 ? 0.05 : (fit > 4 ? 4 : fit);

    canvas.save();
    canvas.translate(element.bounds.center.dx, element.bounds.center.dy);
    canvas.scale(scale, scale);
    canvas.translate(-modelBounds.center.dx, -modelBounds.center.dy);

    switch (element.type) {
      case WbElementKind.flowchart:
        _paintFlowchart(canvas, element.id, payload as WbFlowchartModel, textCache);
      case WbElementKind.table:
        _paintTable(canvas, element.id, payload as WbTableModel, textCache);
      case WbElementKind.mindmap:
        _paintMindmap(canvas, element.id, payload as WbMindNode, textCache);
      case WbElementKind.function:
        _paintFunction(canvas, element.id, payload as WbFunctionScene, content, textCache);
      case WbElementKind.render3d:
        _paintRender3d(canvas, payload as Wb3dScene, content);
      case WbElementKind.render2d:
        WbRender2dPainter(scene: payload as WbRender2dScene)
            .paint(canvas, content);
    }
    canvas.restore();
    return true;
  }

  // ---- 模型外接矩形 ------------------------------------------------------

  /// payload 是否与 [type] 匹配。
  static bool _isCompatible(String type, Object payload) => switch (type) {
        WbElementKind.flowchart => payload is WbFlowchartModel,
        WbElementKind.table => payload is WbTableModel,
        WbElementKind.mindmap => payload is WbMindNode,
        WbElementKind.function => payload is WbFunctionScene,
        WbElementKind.render3d => payload is Wb3dScene,
        WbElementKind.render2d => payload is WbRender2dScene,
        _ => false,
      };

  /// 模型外接矩形（模型坐标系；不匹配返回 null）。
  static Rect? _modelBounds(String type, Object? payload) => switch (type) {
        WbElementKind.flowchart => payload is WbFlowchartModel
            ? _flowchartBounds(payload)
            : null,
        WbElementKind.table =>
          payload is WbTableModel ? _tableBounds(payload) : null,
        WbElementKind.mindmap => payload is WbMindNode
            ? _mindmapBounds(_mindLayout(payload))
            : null,
        WbElementKind.function =>
          payload is WbFunctionScene ? (Offset.zero & _functionSize) : null,
        WbElementKind.render3d =>
          payload is Wb3dScene ? (Offset.zero & _render3dSize) : null,
        WbElementKind.render2d =>
          payload is WbRender2dScene ? (Offset.zero & _render2dSize) : null,
        _ => null,
      };

  /// 流程图节点外接矩形（空模型取单节点默认尺寸）。
  static Rect _flowchartBounds(WbFlowchartModel model) {
    Rect? bounds;
    for (final WbFlowNode node in model.nodes) {
      bounds = bounds == null ? node.bounds : bounds.expandToInclude(node.bounds);
    }
    return bounds ??
        const Rect.fromLTWH(0, 0, WbContextMetrics.flowNodeWidth,
            WbContextMetrics.flowNodeHeight);
  }

  /// 表格外接矩形。
  static Rect _tableBounds(WbTableModel model) {
    return Rect.fromLTWH(
      0,
      0,
      math.max(model.columnCount, 1) * tableCellWidth,
      math.max(model.rowCount, 1) * tableCellHeight,
    );
  }

  /// 思维导图布局（与编辑器预览同口径）。
  static WbMindLayoutResult _mindLayout(WbMindNode root) =>
      WbMindLayoutEngine.layout(
        root: root,
        layout: WbMindLayout.right,
        canvas: layoutCanvas,
      );

  /// 思维导图矩形并集（空布局取单节点默认尺寸）。
  static Rect _mindmapBounds(WbMindLayoutResult result) {
    Rect? bounds;
    for (final Rect rect in result.rects.values) {
      bounds = bounds == null ? rect : bounds.expandToInclude(rect);
    }
    return bounds ??
        const Rect.fromLTWH(0, 0, WbContextMetrics.mindNodeWidth,
            WbContextMetrics.mindNodeHeight);
  }

  // ---- 分类型绘制（模型坐标即画布坐标）--------------------------------

  /// 流程图：连线（底层）+ 节点形状 + 节点文本。
  static void _paintFlowchart(
    Canvas canvas,
    String elementId,
    WbFlowchartModel model,
    WbCanvasTextCache textCache,
  ) {
    WbFlowConnectorPainter(
      model: model,
      selectedNodeId: null,
      colors: colors,
    ).paint(canvas, layoutCanvas);

    for (final WbFlowNode node in model.nodes) {
      canvas.save();
      canvas.translate(node.x, node.y);
      WbFlowNodePainter(
        type: node.type,
        selected: false,
        primary: colors.primary,
      ).paint(canvas, Size(node.width, node.height));

      final String text = node.text;
      if (text.isNotEmpty) {
        final TextPainter painter = textCache.layout(
          key: '$elementId|pro-flow|${node.id}|$text',
          text: text,
          style: TextStyle(
            fontSize: 12,
            color: colors.icon,
            height: 1.25,
          ),
          maxWidth: math.max(node.width - 20, 1),
          align: TextAlign.center,
          maxLines: 2,
        );
        painter.paint(
          canvas,
          Offset(
            (node.width - painter.width) / 2,
            (node.height - painter.height) / 2,
          ),
        );
      }
      canvas.restore();
    }
  }

  /// 表格：底色 / 表头 / 斑马纹 / 边框 / 单元格文本。
  static void _paintTable(
    Canvas canvas,
    String elementId,
    WbTableModel model,
    WbCanvasTextCache textCache,
  ) {
    final WbTableStyle style = model.style;
    final int rows = math.max(model.rowCount, 1);
    final int columns = math.max(model.columnCount, 1);
    final Rect table = Rect.fromLTWH(
      0,
      0,
      columns * tableCellWidth,
      rows * tableCellHeight,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(table, const Radius.circular(6)),
      Paint()..color = colors.surface,
    );

    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < columns; c++) {
        final Rect cell = Rect.fromLTWH(
          c * tableCellWidth,
          r * tableCellHeight,
          tableCellWidth,
          tableCellHeight,
        );
        if (r == 0) {
          canvas.drawRect(cell, Paint()..color = style.headerBackground);
        } else if (style.zebraStripes && r.isOdd) {
          canvas.drawRect(cell, Paint()..color = colors.hover);
        }

        final String text = model.cellAt(r, c);
        if (text.isEmpty) {
          continue;
        }
        final bool bold = r == 0 && style.headerBold;
        final TextPainter painter = textCache.layout(
          key: '$elementId|pro-table|$r|$c|$bold|$text',
          text: text,
          style: TextStyle(
            fontSize: 12,
            color: colors.icon,
            fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
          ),
          maxWidth: math.max(tableCellWidth - 16, 1),
          maxLines: 1,
        );
        final double dx = switch (style.align.textAlign) {
          TextAlign.center => cell.center.dx - painter.width / 2,
          TextAlign.right => cell.right - 8 - painter.width,
          _ => cell.left + 8,
        };
        painter.paint(
          canvas,
          Offset(dx, cell.center.dy - painter.height / 2),
        );
      }
    }

    if (style.showBorders) {
      final Paint line = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colors.border;
      for (int c = 0; c <= columns; c++) {
        final double x = c * tableCellWidth;
        canvas.drawLine(Offset(x, 0), Offset(x, table.height), line);
      }
      for (int r = 0; r <= rows; r++) {
        final double y = r * tableCellHeight;
        canvas.drawLine(Offset(0, y), Offset(table.width, y), line);
      }
    }
  }

  /// 思维导图：父子边（底层）+ 节点卡片 + 节点文本。
  static void _paintMindmap(
    Canvas canvas,
    String elementId,
    WbMindNode root,
    WbCanvasTextCache textCache,
  ) {
    final WbMindLayoutResult result = _mindLayout(root);
    WbMindEdgePainter(
      result: result,
      root: root,
      colors: colors,
    ).paint(canvas, layoutCanvas);

    for (final MapEntry<String, Rect> entry in result.rects.entries) {
      final WbMindNode? node = root.nodeById(entry.key);
      if (node == null) {
        continue;
      }
      final Rect rect = entry.value;
      final int depth = result.depths[entry.key] ?? 0;
      final Color accent = WbContextPalette
          .swatches[depth % WbContextPalette.swatches.length];
      final RRect card =
          RRect.fromRectAndRadius(rect, const Radius.circular(8));
      canvas.drawRRect(
        card,
        Paint()..color = WbContextPalette.softFill(accent, alpha: 0.12),
      );
      canvas.drawRRect(
        card,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = accent,
      );

      if (node.text.isEmpty) {
        continue;
      }
      final TextPainter painter = textCache.layout(
        key: '$elementId|pro-mind|${node.id}|${node.text}',
        text: node.text,
        style: TextStyle(
          fontSize: 11.5,
          color: colors.icon,
          height: 1.2,
        ),
        maxWidth: math.max(rect.width - 12, 1),
        align: TextAlign.center,
        maxLines: 2,
      );
      painter.paint(
        canvas,
        Offset(
          rect.center.dx - painter.width / 2,
          rect.center.dy - painter.height / 2,
        ),
      );
    }
  }

  /// 函数图像：白色卡片 + 网格坐标系 + 曲线 + 表达式图例。
  static void _paintFunction(
    Canvas canvas,
    String elementId,
    WbFunctionScene scene,
    Size content,
    WbCanvasTextCache textCache,
  ) {
    _paintCard(canvas, Offset.zero & content);
    WbFunctionPlotPainter(
      geometry: WbFunctionSampler.sample(scene),
      colors: colors,
    ).paint(canvas, content);
    _paintFunctionLegend(canvas, elementId, scene, content, textCache);
  }

  /// 图例条目（曲线色 + 表达式）：仅包含可见且表达式非空的曲线，
  /// 最多 [maxFunctionLegendEntries] 条（画布上多曲线时不致占满卡片）。
  static List<({Color color, String expression})> functionLegendEntries(
    WbFunctionScene scene,
  ) {
    final List<({Color color, String expression})> entries =
        <({Color color, String expression})>[];
    for (final WbCurve curve in scene.curves) {
      if (entries.length >= maxFunctionLegendEntries) {
        break;
      }
      if (!curve.visible) {
        continue;
      }
      final String expression = curve.expression.trim();
      if (expression.isEmpty) {
        continue;
      }
      entries.add((color: curve.color, expression: expression));
    }
    return entries;
  }

  /// 表达式图例：卡片左上角，曲线色块 + 表达式文本，
  /// 半透明白底压在最上层（避免与坐标系 / 曲线混淆）。
  static void _paintFunctionLegend(
    Canvas canvas,
    String elementId,
    WbFunctionScene scene,
    Size content,
    WbCanvasTextCache textCache,
  ) {
    final List<({Color color, String expression})> entries =
        functionLegendEntries(scene);
    if (entries.isEmpty) {
      return;
    }
    const double fontSize = 11;
    const double lineHeight = 16;
    const double swatchWidth = 12;
    const double swatchGap = 6;
    const double paddingX = 6;
    const double paddingY = 5;
    final double maxTextWidth = math.max(content.width * 0.6, 40);

    final List<TextPainter> painters = <TextPainter>[
      for (final ({Color color, String expression}) entry in entries)
        textCache.layout(
          key: '$elementId|pro-func-legend|${entry.expression}',
          text: entry.expression,
          style: const TextStyle(
            fontSize: fontSize,
            color: Color(0xFF1F2933),
            height: 1.2,
          ),
          maxWidth: maxTextWidth,
          maxLines: 1,
        ),
    ];
    double entryWidth = 0;
    for (final TextPainter painter in painters) {
      entryWidth = math.max(entryWidth, painter.width);
    }
    final Rect box = Rect.fromLTWH(
      10,
      10,
      paddingX * 2 + swatchWidth + swatchGap + entryWidth,
      paddingY * 2 + lineHeight * entries.length,
    );
    final RRect boxRRect =
        RRect.fromRectAndRadius(box, const Radius.circular(6));
    canvas.drawRRect(
      boxRRect,
      Paint()..color = colors.surface.withValues(alpha: 0.85),
    );
    canvas.drawRRect(
      boxRRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colors.border,
    );

    for (int i = 0; i < entries.length; i++) {
      final double centerY =
          box.top + paddingY + lineHeight * i + lineHeight / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(box.left + paddingX + swatchWidth / 2, centerY),
            width: swatchWidth,
            height: 3,
          ),
          const Radius.circular(1.5),
        ),
        Paint()..color = entries[i].color,
      );
      painters[i].paint(
        canvas,
        Offset(
          box.left + paddingX + swatchWidth + swatchGap,
          centerY - painters[i].height / 2,
        ),
      );
    }
  }

  /// 3D 对象：白色卡片 + 软件渲染网格。
  static void _paintRender3d(Canvas canvas, Wb3dScene scene, Size content) {
    _paintCard(canvas, Offset.zero & content);
    Wb3dMeshPainter(scene: scene, colors: colors).paint(canvas, content);
  }

  /// 浅色卡片底（白底 + 淡描边），提升画布上的存在感。
  static void _paintCard(Canvas canvas, Rect rect) {
    final RRect card = RRect.fromRectAndRadius(rect, const Radius.circular(10));
    canvas.drawRRect(card, Paint()..color = colors.surface);
    canvas.drawRRect(
      card,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colors.border,
    );
  }
}
