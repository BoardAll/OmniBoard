/// Markdown 布局引擎：Document AST → Render Scene（绘制指令序列）。
///
/// 按元素宽度逐节点排版，输出每个块的绝对矩形与绘制闭包（[WbMdDrawOp]）；
/// 表格列宽分配、代码块横向截断、公式 / Mermaid 图自适应缩放；
/// 行内公式与图片通过 U+FFFC 占位符嵌入文本流后二次定位绘制。
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../canvas/canvas_model.dart';
import 'markdown_ast.dart';
import 'markdown_theme.dart';
import 'math_parser.dart';
import 'math_renderer.dart';
import 'mermaid_parser.dart';
import 'mermaid_renderer.dart';

/// 布局结果（整篇渲染场景）。
class WbMdLayoutResult {
  /// 创建结果。
  const WbMdLayoutResult({
    required this.width,
    required this.height,
    required this.ops,
    required this.headings,
  });

  /// 布局宽度（= 元素宽度）。
  final double width;

  /// 内容总高度。
  final double height;

  /// 绘制指令（按 y 升序）。
  final List<WbMdDrawOp> ops;

  /// 标题锚点（目录 / 滚动定位）。
  final List<WbMdHeadingAnchor> headings;
}

/// 标题锚点。
class WbMdHeadingAnchor {
  /// 创建锚点。
  const WbMdHeadingAnchor({
    required this.level,
    required this.text,
    required this.top,
  });

  /// 级别（1..6）。
  final int level;

  /// 标题纯文本。
  final String text;

  /// 内容坐标 top（含内边距）。
  final double top;
}

/// 绘制指令：一块区域 + 绘制闭包（绝对内容坐标）。
class WbMdDrawOp {
  /// 创建指令。
  const WbMdDrawOp({
    required this.rect,
    required this.draw,
    this.searchText = '',
    this.mermaidCode = '',
  });

  /// 块区域（绝对内容坐标）。
  final Rect rect;

  /// 绘制闭包（坐标 = [rect] 所在的内容坐标系）。
  final void Function(Canvas canvas) draw;

  /// 搜索文本（全文搜索高亮用）。
  final String searchText;

  /// Mermaid 图源码（非空 = 该块为 Mermaid 图，点击可放大查看）。
  final String mermaidCode;
}

/// 布局引擎入口（纯函数；不抛异常）。
abstract final class WbMarkdownLayoutEngine {
  /// 布局文档。
  ///
  /// [width] 为元素宽度；[textCache] 提供跨帧 [TextPainter] 复用；
  /// [cachePrefix] 为文本缓存 key 前缀（建议元素 id）。
  static WbMdLayoutResult layout({
    required WbMdDocument document,
    required WbMarkdownTheme theme,
    required double width,
    required double minHeight,
    WbCanvasTextCache? textCache,
    String cachePrefix = 'wb-md',
  }) {
    try {
      final _LayoutBuilder builder = _LayoutBuilder(
        document: document,
        theme: theme,
        width: math.max(width, 80),
        textCache: textCache,
        cachePrefix: cachePrefix,
      );
      builder.build();
      return WbMdLayoutResult(
        width: builder.width,
        height: math.max(builder.totalHeight, minHeight),
        ops: builder.ops,
        headings: builder.headings,
      );
    } catch (_) {
      // 兜底：渲染为空文档（保底高度），不抛出。
      return WbMdLayoutResult(
        width: width,
        height: minHeight,
        ops: const <WbMdDrawOp>[],
        headings: const <WbMdHeadingAnchor>[],
      );
    }
  }
}

/// 块布局构建器（内部实现）。
class _LayoutBuilder {
  _LayoutBuilder({
    required this.document,
    required this.theme,
    required this.width,
    required this.textCache,
    required this.cachePrefix,
  });

  final WbMdDocument document;
  final WbMarkdownTheme theme;
  final double width;
  final WbCanvasTextCache? textCache;
  final String cachePrefix;

  final List<WbMdDrawOp> ops = <WbMdDrawOp>[];
  final List<WbMdHeadingAnchor> headings = <WbMdHeadingAnchor>[];

  /// 内容纵向游标（不含内边距）。
  double cursorY = 0;

  /// 当前左边距（引用等嵌套容器会增加）。
  double _leftInset = 0;

  /// 内边距。
  double get padding => theme.padding;

  /// 可用内容宽度。
  double get _contentWidth => width - padding - _leftInset;

  /// 总高度（含上下内边距）。
  double get totalHeight => 2 * padding + math.max(0, cursorY);

  /// 构建整篇。
  void build() {
    for (final WbMdBlock block in document.blocks) {
      _block(block);
    }
  }

  // ---- 块分发 -------------------------------------------------------------

  void _block(WbMdBlock block) {
    switch (block) {
      case WbMdHeading():
        _heading(block);
      case WbMdParagraph():
        _paragraph(block);
      case WbMdListBlock():
        _list(block, 0);
      case WbMdQuote():
        _quote(block);
      case WbMdCodeBlock():
        _codeBlock(block);
      case WbMdTableBlock():
        _table(block);
      case WbMdDivider():
        _divider();
      case WbMdMathBlock():
        _mathBlock(block);
      case WbMdMermaidBlock():
        _mermaid(block);
      case WbMdErrorBlock():
        _errorCard(block.message, block.detail);
    }
  }

  double _gapFor(WbMdBlock block) {
    switch (block) {
      case WbMdHeading(level: 1):
        return 14;
      case WbMdHeading(level: 2):
        return 12;
      case WbMdHeading():
        return 10;
      case WbMdDivider():
        return 16;
      case WbMdCodeBlock():
        return 12;
      case WbMdTableBlock():
        return 12;
      case WbMdMathBlock():
        return 12;
      case WbMdMermaidBlock():
        return 12;
      case WbMdQuote():
        return 12;
      case WbMdListBlock():
        return 9;
      case WbMdErrorBlock():
        return 12;
      case WbMdParagraph():
        return 10;
    }
  }

  // ---- 文本基础设施 -------------------------------------------------------

  TextStyle _baseStyle({
    double? fontSize,
    Color? color,
    FontWeight? weight,
    bool italic = false,
    bool strike = false,
    bool monospace = false,
    double? height,
  }) {
    return TextStyle(
      fontSize: fontSize ?? theme.baseFontSize,
      color: color ?? theme.foreground,
      fontWeight: weight,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      decoration: strike ? TextDecoration.lineThrough : TextDecoration.none,
      decorationColor: theme.muted,
      fontFamily: monospace ? 'Consolas' : null,
      fontFamilyFallback:
          monospace ? WbMarkdownTheme.monoFontFallback : null,
      height: height ?? theme.lineHeight,
    );
  }

  TextPainter _painter(
    InlineSpan span,
    double maxWidth, {
    TextAlign align = TextAlign.left,
    bool cached = true,
  }) {
    final double layoutWidth =
        maxWidth.isFinite ? math.max(maxWidth, 1) : maxWidth;
    if (cached && textCache != null) {
      final String widthKey =
          layoutWidth.isFinite ? layoutWidth.round().toString() : 'inf';
      final String key =
          '$cachePrefix|${span.hashCode}|$widthKey';
      return textCache!.layoutSpan(
        key: key,
        span: span,
        maxWidth: layoutWidth,
        align: align,
      );
    }
    return TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(maxWidth: layoutWidth);
  }

  /// 行内槽（公式 / 图片）在文本流中的定位信息。
  final List<_InlineSlot> _slots = <_InlineSlot>[];

  /// 构建行内 [TextSpan]；同时填充 [_slots] 与 [plain] 索引表。
  InlineSpan _inlineSpan(
    List<WbMdInline> inlines,
    TextStyle base,
    StringBuffer plain,
  ) {
    final List<InlineSpan> children = <InlineSpan>[];
    for (final WbMdInline inline in inlines) {
      switch (inline) {
        case WbMdText():
          plain.write(inline.text);
          children.add(TextSpan(
            text: inline.text,
            style: base.copyWith(
              fontWeight: inline.bold ? FontWeight.w700 : base.fontWeight,
              fontStyle:
                  inline.italic ? FontStyle.italic : base.fontStyle,
              decoration: inline.strike
                  ? TextDecoration.lineThrough
                  : base.decoration,
              color: inline.code
                  ? theme.codeForeground
                  : inline.link.isNotEmpty
                      ? theme.link
                      : base.color,
              backgroundColor:
                  inline.code ? theme.inlineCodeBackground : null,
              fontFamily: inline.code ? 'Consolas' : base.fontFamily,
              fontFamilyFallback: inline.code
                  ? WbMarkdownTheme.monoFontFallback
                  : base.fontFamilyFallback,
              fontSize: inline.code
                  ? (base.fontSize ?? theme.baseFontSize) - 1
                  : base.fontSize,
            ),
          ));
        case WbMdInlineMath():
          plain.write('\uFFFC');
          _slots.add(_InlineSlot(
            charIndex: plain.length - 1,
            kind: _InlineSlotKind.math,
            payload: inline.latex,
          ));
          children.add(TextSpan(text: '\uFFFC', style: base));
        case WbMdImage():
          plain.write('\uFFFC');
          _slots.add(_InlineSlot(
            charIndex: plain.length - 1,
            kind: _InlineSlotKind.image,
            payload: inline.alt.isEmpty ? inline.url : inline.alt,
          ));
          children.add(TextSpan(text: '\uFFFC', style: base));
      }
    }
    if (children.length == 1) {
      return children.first;
    }
    return TextSpan(style: base, children: children);
  }

  /// 绘制行内槽（公式 / 图片占位）。
  void _paintSlots(
    Canvas canvas,
    TextPainter painter,
    Offset topLeft,
    List<_InlineSlot> slots,
  ) {
    for (final _InlineSlot slot in slots) {
      final List<TextBox> boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: slot.charIndex, extentOffset: slot.charIndex + 1),
      );
      if (boxes.isEmpty) {
        continue;
      }
      final Rect rect = boxes.first.toRect().shift(topLeft);
      if (slot.kind == _InlineSlotKind.math) {
        _paintInlineMath(canvas, rect, slot.payload);
      } else {
        _paintImageIcon(canvas, rect, theme.muted);
      }
    }
  }

  void _paintInlineMath(Canvas canvas, Rect rect, String latex) {
    final WbMathBox box = WbMathRenderer.layout(
      WbMathParser.parse(latex),
      fontSize: theme.baseFontSize * 0.98,
      color: theme.mathForeground,
      errorColor: theme.errorForeground,
    );
    if (box.width <= 0) {
      return;
    }
    double scale = 1;
    final double maxHeight = rect.height * 1.9;
    if (box.height > maxHeight) {
      scale = maxHeight / box.height;
    }
    final double drawWidth = box.width * scale;
    final double left = rect.center.dx - drawWidth / 2;
    canvas.save();
    canvas.translate(left, rect.bottom - 2 * scale);
    canvas.scale(scale);
    box.draw(canvas, Offset(0, -box.descent));
    canvas.restore();
  }

  void _paintImageIcon(Canvas canvas, Rect cell, Color color) {
    final double size = math.min(cell.height, theme.baseFontSize * 1.4);
    final Rect rect = Rect.fromCenter(
      center: cell.center,
      width: size,
      height: size,
    );
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      stroke,
    );
    final Paint fill = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    final Path path = Path()
      ..moveTo(rect.left + 2, rect.bottom - 3)
      ..lineTo(rect.left + rect.width * 0.38, rect.top + rect.height * 0.45)
      ..lineTo(rect.left + rect.width * 0.62, rect.bottom - 3)
      ..moveTo(rect.left + rect.width * 0.52, rect.bottom - 3)
      ..lineTo(rect.left + rect.width * 0.72, rect.top + rect.height * 0.58)
      ..lineTo(rect.right - 2, rect.bottom - 3);
    canvas.drawPath(path, fill);
    canvas.drawCircle(
      Offset(rect.left + rect.width * 0.3, rect.top + rect.height * 0.3),
      1.4,
      Paint()..color = color,
    );
  }

  /// 布局一个行内文本块（生成 op 并推进游标）。
  void _layoutTextBlock(
    List<WbMdInline> inlines, {
    required TextStyle style,
    double? maxWidth,
    double? indent,
    double topGap = 0,
    double bottomGap = 0,
    String? searchOverride,
    void Function(Canvas canvas, Rect rect, TextPainter painter)? beforeText,
    double trailing = 0,
  }) {
    cursorY += topGap;
    final double left = padding + (indent ?? _leftInset);
    final double available =
        maxWidth ?? (width - left - padding);
    final StringBuffer plain = StringBuffer();
    _slots.clear();
    final InlineSpan span = _inlineSpan(inlines, style, plain);
    final List<_InlineSlot> localSlots = List<_InlineSlot>.of(_slots);
    _slots.clear();
    final TextPainter painter = _painter(span, math.max(available, 1));
    final Rect rect =
        Rect.fromLTWH(left, padding + cursorY, available, painter.height);
    final String searchText = searchOverride ?? plain.toString();
    ops.add(WbMdDrawOp(
      rect: rect,
      searchText: searchText,
      draw: (Canvas canvas) {
        beforeText?.call(canvas, rect, painter);
        painter.paint(canvas, rect.topLeft);
        _paintSlots(canvas, painter, rect.topLeft, localSlots);
      },
    ));
    cursorY += painter.height + bottomGap + trailing;
  }

  // ---- 各块实现 -----------------------------------------------------------

  void _heading(WbMdHeading block) {
    final double fontSize = theme.headingFontSize(block.level);
    final TextStyle style = _baseStyle(
      fontSize: fontSize,
      weight: FontWeight.w700,
      height: 1.35,
    );
    final StringBuffer plain = StringBuffer();
    _slots.clear();
    final InlineSpan span = _inlineSpan(block.inlines, style, plain);
    final List<_InlineSlot> localSlots = List<_InlineSlot>.of(_slots);
    _slots.clear();
    final TextPainter painter =
        _painter(span, math.max(_contentWidth, 1));
    final double topGap = cursorY > 0 ? (block.level <= 2 ? 8 : 6) : 0;
    cursorY += topGap;
    final Rect rect =
        Rect.fromLTWH(padding, padding + cursorY, _contentWidth, painter.height);
    final bool underline = block.level <= 2;
    ops.add(WbMdDrawOp(
      rect: rect,
      searchText: plain.toString(),
      draw: (Canvas canvas) {
        painter.paint(canvas, rect.topLeft);
        _paintSlots(canvas, painter, rect.topLeft, localSlots);
        if (underline) {
          canvas.drawLine(
            Offset(rect.left, rect.bottom + 3),
            Offset(rect.right, rect.bottom + 3),
            Paint()
              ..color = theme.headingBorder
              ..strokeWidth = 1,
          );
        }
      },
    ));
    headings.add(WbMdHeadingAnchor(
      level: block.level,
      text: plain.toString(),
      top: rect.top,
    ));
    cursorY += painter.height + (underline ? 6 : 0);
  }

  void _paragraph(WbMdParagraph block) {
    // 独占图片提升为块级卡片。
    if (block.inlines.length == 1 && block.inlines.first is WbMdImage) {
      final WbMdImage image = block.inlines.first as WbMdImage;
      _imageCard(image);
      return;
    }
    _layoutTextBlock(block.inlines, style: _baseStyle());
  }

  void _imageCard(WbMdImage image) {
    const double height = 86;
    final Rect rect =
        Rect.fromLTWH(padding, padding + cursorY, _contentWidth, height);
    final TextPainter alt = _painter(
      TextSpan(
        text: image.alt.isEmpty ? '图片' : image.alt,
        style: _baseStyle(weight: FontWeight.w600),
      ),
      rect.width - 70,
    );
    final TextPainter url = _painter(
      TextSpan(
        text: image.url,
        style: _baseStyle(fontSize: theme.baseFontSize - 2, color: theme.muted),
      ),
      rect.width - 70,
    );
    ops.add(WbMdDrawOp(
      rect: rect,
      searchText: '${image.alt} ${image.url}',
      draw: (Canvas canvas) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(8)),
          Paint()..color = theme.imageBackground,
        );
        final Rect iconRect =
            Rect.fromLTWH(rect.left + 14, rect.center.dy - 16, 32, 32);
        _paintImageIcon(canvas, iconRect, theme.muted);
        final double textLeft = rect.left + 60;
        alt.paint(canvas, Offset(textLeft, rect.center.dy - alt.height - 2));
        url.paint(canvas, Offset(textLeft, rect.center.dy + 2));
      },
    ));
    cursorY += height;
  }

  void _list(WbMdListBlock block, double indent) {
    cursorY += 3;
    for (int i = 0; i < block.items.length; i++) {
      final WbMdListItem item = block.items[i];
      const double markerWidth = 22;
      final double left = padding + _leftInset + indent;
      final double available = width - left - padding - markerWidth;
      final TextStyle style = _baseStyle();
      final StringBuffer plain = StringBuffer();
      _slots.clear();
      final InlineSpan span = _inlineSpan(item.inlines, style, plain);
      final List<_InlineSlot> localSlots = List<_InlineSlot>.of(_slots);
      _slots.clear();
      final TextPainter painter = _painter(span, math.max(available, 1));
      final String marker = block.ordered ? '${block.start + i}.' : '•';
      final bool hasTask = item.checked != null;
      final Rect markerRect = Rect.fromLTWH(
        left,
        padding + cursorY,
        markerWidth,
        painter.height,
      );
      final Rect textRect = Rect.fromLTWH(
        left + markerWidth,
        padding + cursorY,
        math.max(available, 1),
        painter.height,
      );
      ops.add(WbMdDrawOp(
        rect: Rect.fromLTWH(
          left,
          padding + cursorY,
          markerWidth + textRect.width,
          painter.height,
        ),
        searchText: plain.toString(),
        draw: (Canvas canvas) {
          if (hasTask) {
            _paintCheckbox(
              canvas,
              Rect.fromLTWH(
                left + 2,
                markerRect.center.dy - 7,
                14,
                14,
              ),
              item.checked!,
            );
          } else if (block.ordered) {
            final TextPainter markerPainter = _painter(
              TextSpan(
                text: marker,
                style: _baseStyle(
                  color: theme.muted,
                  weight: FontWeight.w600,
                ),
              ),
              markerWidth,
              cached: false,
            );
            markerPainter.paint(
              canvas,
              Offset(left, markerRect.center.dy - markerPainter.height / 2),
            );
          } else {
            canvas.drawCircle(
              Offset(left + 8, markerRect.center.dy),
              2.6,
              Paint()..color = theme.muted,
            );
          }
          painter.paint(canvas, textRect.topLeft);
          _paintSlots(canvas, painter, textRect.topLeft, localSlots);
        },
      ));
      cursorY += painter.height + 2;
      final WbMdListBlock? children = item.children;
      if (children != null) {
        _list(children, indent + 20);
      }
    }
    cursorY += 2;
  }

  void _paintCheckbox(Canvas canvas, Rect rect, bool checked) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()
        ..color = checked ? theme.primary : theme.background
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()
        ..color = checked ? theme.primary : theme.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    if (checked) {
      final Path check = Path()
        ..moveTo(rect.left + 3, rect.center.dy)
        ..lineTo(rect.left + 6, rect.bottom - 4)
        ..lineTo(rect.right - 3, rect.top + 4);
      canvas.drawPath(
        check,
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  void _quote(WbMdQuote block) {
    final double savedInset = _leftInset;
    final int startIndex = ops.length;
    final double startY = cursorY;
    _leftInset = savedInset + 14;
    for (final WbMdBlock inner in block.blocks) {
      _block(inner);
      cursorY += _gapFor(inner);
    }
    if (cursorY > startY) {
      cursorY -= 2;
    }
    _leftInset = savedInset;
    final Rect rect = Rect.fromLTWH(
      padding + savedInset,
      padding + startY,
      width - padding - savedInset - padding,
      math.max(cursorY - startY, 0),
    );
    ops.insert(
      startIndex,
      WbMdDrawOp(
        rect: rect,
        searchText: _collectText(block),
        draw: (Canvas canvas) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(6)),
            Paint()..color = theme.quoteBackground,
          );
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              rect,
              topLeft: const Radius.circular(6),
              bottomLeft: const Radius.circular(6),
            ),
            Paint()
              ..color = theme.quoteBorder
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.4,
          );
        },
      ),
    );
  }

  String _collectText(WbMdBlock block) {
    final StringBuffer buffer = StringBuffer();
    void walk(WbMdBlock b) {
      switch (b) {
        case WbMdHeading():
          buffer.write(wbMdInlinePlainText(b.inlines));
        case WbMdParagraph():
          buffer.write(wbMdInlinePlainText(b.inlines));
        case WbMdListBlock():
          for (final WbMdListItem item in b.items) {
            buffer.write(wbMdInlinePlainText(item.inlines));
            final WbMdListBlock? children = item.children;
            if (children != null) {
              walk(children);
            }
          }
        case WbMdQuote():
          for (final WbMdBlock inner in b.blocks) {
            walk(inner);
          }
        case WbMdCodeBlock():
          buffer.write(b.code);
        case WbMdTableBlock():
          for (final List<WbMdInline> cell in b.header) {
            buffer.write(wbMdInlinePlainText(cell));
          }
          for (final List<List<WbMdInline>> row in b.rows) {
            for (final List<WbMdInline> cell in row) {
              buffer.write(wbMdInlinePlainText(cell));
            }
          }
        case WbMdMathBlock():
          buffer.write(b.latex);
        case WbMdMermaidBlock():
          buffer.write(b.code);
        case WbMdDivider():
          break;
        case WbMdErrorBlock():
          buffer.write(b.message);
      }
    }

    walk(block);
    return buffer.toString();
  }

  void _divider() {
    cursorY += 6;
    final Rect rect =
        Rect.fromLTWH(padding, padding + cursorY, _contentWidth, 1);
    ops.add(WbMdDrawOp(
      rect: rect,
      draw: (Canvas canvas) {
        canvas.drawLine(
          rect.topLeft,
          rect.topRight,
          Paint()
            ..color = theme.divider
            ..strokeWidth = 1,
        );
      },
    ));
    cursorY += 1 + 6;
  }

  void _codeBlock(WbMdCodeBlock block) {
    const double padX = 12;
    const double padY = 10;
    final bool hasLanguage = block.language.trim().isNotEmpty;
    final double headerH = hasLanguage ? 18 : 0;
    final InlineSpan codeSpan = _CodeHighlighter.highlight(
      block.code,
      block.language,
      theme,
    );
    final TextPainter painter = _painter(
      codeSpan,
      double.infinity,
      cached: true,
    );
    final double height = painter.height + padY * 2 + headerH;
    final Rect rect =
        Rect.fromLTWH(padding, padding + cursorY, _contentWidth, height);
    final TextPainter? languageLabel = hasLanguage
        ? _painter(
            TextSpan(
              text: block.language,
              style: _baseStyle(
                fontSize: theme.baseFontSize - 2.5,
                color: theme.muted,
                monospace: true,
              ),
            ),
            200,
            cached: false,
          )
        : null;
    final Rect contentRect = Rect.fromLTWH(
      rect.left + padX,
      rect.top + padY + headerH,
      rect.width - padX * 2,
      painter.height,
    );
    ops.add(WbMdDrawOp(
      rect: rect,
      searchText: block.code,
      draw: (Canvas canvas) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(8)),
          Paint()..color = theme.codeBackground,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(8)),
          Paint()
            ..color = theme.codeBorder
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
        if (languageLabel != null) {
          languageLabel.paint(
            canvas,
            Offset(
              rect.right - padX - languageLabel.width,
              rect.top + 3,
            ),
          );
        }
        // 横向截断：超出内容区的部分裁剪。
        canvas.save();
        canvas.clipRect(contentRect);
        painter.paint(canvas, contentRect.topLeft);
        canvas.restore();
      },
    ));
    cursorY += height;
  }

  void _table(WbMdTableBlock block) {
    const double cellPadX = 10;
    const double cellPadY = 6;
    final int columns = block.columnCount;
    if (columns == 0) {
      return;
    }
    final double available = _contentWidth;
    // 阶段 1：固有宽度（单行）。
    final List<List<List<WbMdInline>>> allRows = <List<List<WbMdInline>>>[
      block.header,
      ...block.rows,
    ];
    final List<double> intrinsic = List<double>.filled(columns, 0);
    for (final List<List<WbMdInline>> row in allRows) {
      for (int c = 0; c < columns && c < row.length; c++) {
        final StringBuffer plain = StringBuffer();
        _slots.clear();
        final InlineSpan span = _inlineSpan(
          row[c],
          _baseStyle(),
          plain,
        );
        _slots.clear();
        final TextPainter probe =
            _painter(span, double.infinity, cached: false);
        intrinsic[c] = math.max(intrinsic[c], probe.width);
      }
    }
    double intrinsicTotal = 0;
    for (final double w in intrinsic) {
      intrinsicTotal += w + cellPadX * 2;
    }
    // 列宽分配：总宽收缩到可用宽度（最小 56）。
    final List<double> colWidths = <double>[];
    if (intrinsicTotal <= available) {
      // 有富余时按比例轻微拉伸填充。
      final double extra = available - intrinsicTotal;
      for (int c = 0; c < columns; c++) {
        final double share = columns == 0
            ? 0
            : extra * ((intrinsic[c] + cellPadX * 2) / intrinsicTotal);
        colWidths.add(intrinsic[c] + cellPadX * 2 + share);
      }
    } else {
      final double scale = available / intrinsicTotal;
      for (int c = 0; c < columns; c++) {
        colWidths.add(math.max((intrinsic[c] + cellPadX * 2) * scale, 56));
      }
      // 收缩后仍超宽：等分兜底。
      double total = 0;
      for (final double w in colWidths) {
        total += w;
      }
      if (total > available) {
        final double equal = available / columns;
        for (int c = 0; c < columns; c++) {
          colWidths[c] = math.min(colWidths[c], equal);
        }
      }
    }
    // 阶段 2：按列宽换行布局。
    final List<TextPainter> headerPainters = <TextPainter>[
      for (int c = 0; c < columns; c++)
        _tableCellPainter(
          c < block.header.length ? block.header[c] : const <WbMdInline>[],
          colWidths[c] - cellPadX * 2,
        ),
    ];
    final List<List<TextPainter>> rowPainters =
        <List<TextPainter>>[];
    final List<double> rowHeights = <double>[];
    double headerHeight = 0;
    for (final TextPainter p in headerPainters) {
      headerHeight = math.max(headerHeight, p.height);
    }
    headerHeight += cellPadY * 2;
    for (final List<List<WbMdInline>> row in block.rows) {
      final List<TextPainter> painters = <TextPainter>[
        for (int c = 0; c < columns; c++)
          _tableCellPainter(
            c < row.length ? row[c] : const <WbMdInline>[],
            colWidths[c] - cellPadX * 2,
          ),
      ];
      double rowHeight = 0;
      for (final TextPainter p in painters) {
        rowHeight = math.max(rowHeight, p.height);
      }
      rowPainters.add(painters);
      rowHeights.add(rowHeight + cellPadY * 2);
    }
    double totalHeight = headerHeight;
    for (final double h in rowHeights) {
      totalHeight += h;
    }
    final Rect rect =
        Rect.fromLTWH(padding, padding + cursorY, available, totalHeight);
    final StringBuffer searchBuffer = StringBuffer();
    for (final List<WbMdInline> cell in block.header) {
      searchBuffer.write(wbMdInlinePlainText(cell));
      searchBuffer.write(' ');
    }
    for (final List<List<WbMdInline>> row in block.rows) {
      for (final List<WbMdInline> cell in row) {
        searchBuffer.write(wbMdInlinePlainText(cell));
        searchBuffer.write(' ');
      }
    }
    final List<WbMdTableAlign> aligns = block.aligns;
    ops.add(WbMdDrawOp(
      rect: rect,
      searchText: searchBuffer.toString(),
      draw: (Canvas canvas) {
        final Paint borderPaint = Paint()
          ..color = theme.tableBorder
          ..strokeWidth = 1;
        // 表头底。
        canvas.drawRect(
          Rect.fromLTWH(rect.left, rect.top, rect.width, headerHeight),
          Paint()..color = theme.tableHeaderBackground,
        );
        double y = rect.top;
        // 表头。
        double x = rect.left;
        for (int c = 0; c < columns; c++) {
          final TextPainter p = headerPainters[c];
          final WbMdTableAlign align =
              c < aligns.length ? aligns[c] : WbMdTableAlign.left;
          _paintCell(canvas, p, x, y, colWidths[c], headerHeight, align, cellPadX);
          x += colWidths[c];
        }
        y += headerHeight;
        for (int r = 0; r < rowPainters.length; r++) {
          // 横向条纹背景（隔行）。
          if (r.isOdd) {
            canvas.drawRect(
              Rect.fromLTWH(rect.left, y, rect.width, rowHeights[r]),
              Paint()..color = theme.tableHeaderBackground.withValues(alpha: 0.5),
            );
          }
          x = rect.left;
          for (int c = 0; c < columns; c++) {
            final TextPainter p = rowPainters[r][c];
            final WbMdTableAlign align =
                c < aligns.length ? aligns[c] : WbMdTableAlign.left;
            _paintCell(canvas, p, x, y, colWidths[c], rowHeights[r], align, cellPadX);
            canvas.drawLine(
              Offset(x, rect.top),
              Offset(x, rect.bottom),
              borderPaint,
            );
            x += colWidths[c];
          }
          y += rowHeights[r];
          canvas.drawLine(
            Offset(rect.left, y),
            Offset(rect.right, y),
            borderPaint,
          );
        }
        canvas.drawLine(Offset(rect.left, rect.top), Offset(rect.left, rect.bottom), borderPaint);
        canvas.drawLine(Offset(rect.right - 0.5, rect.top), Offset(rect.right - 0.5, rect.bottom), borderPaint);
        canvas.drawRect(rect, Paint()
          ..color = theme.tableBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
        canvas.drawLine(
          Offset(rect.left, rect.top + headerHeight),
          Offset(rect.right, rect.top + headerHeight),
          borderPaint,
        );
      },
    ));
    cursorY += totalHeight;
  }

  TextPainter _tableCellPainter(List<WbMdInline> inlines, double maxWidth) {
    final StringBuffer plain = StringBuffer();
    _slots.clear();
    final InlineSpan span = _inlineSpan(inlines, _baseStyle(), plain);
    _slots.clear();
    return _painter(span, math.max(maxWidth, 10));
  }

  void _paintCell(
    Canvas canvas,
    TextPainter painter,
    double x,
    double y,
    double width,
    double height,
    WbMdTableAlign align,
    double padX,
  ) {
    double dx = x + padX;
    if (align == WbMdTableAlign.center) {
      dx = x + (width - painter.width) / 2;
    } else if (align == WbMdTableAlign.right) {
      dx = x + width - padX - painter.width;
    }
    painter.paint(
      canvas,
      Offset(dx, y + (height - painter.height) / 2),
    );
  }

  void _mathBlock(WbMdMathBlock block) {
    final WbMathNode node = WbMathParser.parse(block.latex);
    final WbMathBox box = WbMathRenderer.layout(
      node,
      fontSize: theme.baseFontSize * 1.18,
      color: theme.mathForeground,
      errorColor: theme.errorForeground,
    );
    if (node is WbMathError || box.width <= 0) {
      _errorCard(node is WbMathError ? node.message : '空公式', block.latex);
      return;
    }
    double scale = 1;
    if (box.width > _contentWidth) {
      scale = _contentWidth / box.width;
    }
    final double drawWidth = box.width * scale;
    final double drawHeight = box.height * scale;
    final Rect rect = Rect.fromLTWH(
      padding,
      padding + cursorY,
      _contentWidth,
      drawHeight + 8,
    );
    final double left = padding + (_contentWidth - drawWidth) / 2;
    final double baseline = rect.top + 4 + box.ascent * scale;
    ops.add(WbMdDrawOp(
      rect: rect,
      searchText: block.latex,
      draw: (Canvas canvas) {
        canvas.save();
        canvas.translate(left, baseline);
        canvas.scale(scale);
        box.draw(canvas, Offset.zero);
        canvas.restore();
      },
    ));
    cursorY += rect.height;
  }

  void _mermaid(WbMdMermaidBlock block) {
    final WbMermaidDiagram diagram = WbMermaidParser.parse(block.code);
    final WbMermaidBox box = WbMermaidRenderer.layout(
      diagram,
      theme: theme,
      maxWidth: _contentWidth,
      fontSize: theme.baseFontSize - 1.5,
    );
    final double left =
        padding + (_contentWidth - box.size.width) / 2;
    final Rect rect = Rect.fromLTWH(
      padding,
      padding + cursorY,
      _contentWidth,
      box.size.height + 4,
    );
    ops.add(WbMdDrawOp(
      rect: rect,
      searchText: block.code,
      mermaidCode: block.code,
      draw: (Canvas canvas) {
        canvas.save();
        canvas.translate(left, rect.top + 2);
        box.draw(canvas);
        canvas.restore();
      },
    ));
    cursorY += rect.height;
  }

  void _errorCard(String message, String detail) {
    const double padX = 12;
    const double padY = 10;
    final TextPainter title = _painter(
      TextSpan(
        text: message,
        style: _baseStyle(
          color: theme.errorForeground,
          weight: FontWeight.w600,
        ),
      ),
      _contentWidth - padX * 2,
      cached: false,
    );
    final TextPainter? detailPainter = detail.trim().isEmpty
        ? null
        : _painter(
            TextSpan(
              text: detail,
              style: _baseStyle(
                fontSize: theme.baseFontSize - 2,
                color: theme.muted,
                monospace: true,
              ),
            ),
            _contentWidth - padX * 2,
            cached: false,
          );
    final double height =
        title.height + (detailPainter?.height ?? 0) + padY * 2 + 8;
    final Rect rect =
        Rect.fromLTWH(padding, padding + cursorY, _contentWidth, height);
    ops.add(WbMdDrawOp(
      rect: rect,
      searchText: '$message $detail',
      draw: (Canvas canvas) {
        final RRect rrect =
            RRect.fromRectAndRadius(rect, const Radius.circular(8));
        canvas.drawRRect(rrect, Paint()..color = theme.errorBackground);
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = theme.errorBorder
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
        title.paint(canvas, Offset(rect.left + padX, rect.top + padY));
        detailPainter?.paint(
          canvas,
          Offset(
            rect.left + padX,
            rect.top + padY + title.height + 2,
          ),
        );
      },
    ));
    cursorY += height;
  }
}

/// 行内槽类型。
enum _InlineSlotKind {
  /// 行内公式。
  math,

  /// 行内图片。
  image,
}

/// 行内槽（占位符定位信息）。
class _InlineSlot {
  _InlineSlot({
    required this.charIndex,
    required this.kind,
    required this.payload,
  });

  final int charIndex;
  final _InlineSlotKind kind;
  final String payload;
}

/// 轻量语法高亮（通用子集：注释 / 字符串 / 数字 / 关键字）。
abstract final class _CodeHighlighter {
  static const Map<String, List<String>> _keywords = <String, List<String>>{
    'dart': <String>[
      'abstract', 'as', 'assert', 'async', 'await', 'break', 'case',
      'catch', 'class', 'const', 'continue', 'default', 'do', 'dynamic',
      'else', 'enum', 'extends', 'extension', 'external', 'factory',
      'false', 'final', 'finally', 'for', 'get', 'if', 'implements',
      'import', 'in', 'interface', 'is', 'late', 'library', 'mixin',
      'new', 'null', 'on', 'operator', 'part', 'required', 'return',
      'set', 'static', 'super', 'switch', 'this', 'throw', 'true',
      'try', 'typedef', 'var', 'void', 'while', 'with', 'yield',
    ],
    'javascript': <String>[
      'async', 'await', 'break', 'case', 'catch', 'class', 'const',
      'continue', 'default', 'delete', 'do', 'else', 'export',
      'extends', 'false', 'finally', 'for', 'function', 'if',
      'implements', 'import', 'in', 'instanceof', 'interface', 'let',
      'new', 'null', 'of', 'return', 'static', 'super', 'switch',
      'this', 'throw', 'true', 'try', 'typeof', 'undefined', 'var',
      'void', 'while', 'yield',
    ],
    'python': <String>[
      'and', 'as', 'assert', 'async', 'await', 'break', 'class',
      'continue', 'def', 'del', 'elif', 'else', 'except', 'False',
      'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is',
      'lambda', 'None', 'nonlocal', 'not', 'or', 'pass', 'raise',
      'return', 'True', 'try', 'while', 'with', 'yield', 'self',
    ],
    'java': <String>[
      'abstract', 'assert', 'boolean', 'break', 'byte', 'case',
      'catch', 'char', 'class', 'const', 'continue', 'default', 'do',
      'double', 'else', 'enum', 'extends', 'false', 'final',
      'finally', 'float', 'for', 'if', 'implements', 'import',
      'instanceof', 'int', 'interface', 'long', 'native', 'new',
      'null', 'package', 'private', 'protected', 'public', 'return',
      'short', 'static', 'strictfp', 'super', 'switch',
      'synchronized', 'this', 'throw', 'throws', 'transient', 'true',
      'try', 'var', 'void', 'volatile', 'while',
    ],
    'c': <String>[
      'auto', 'break', 'case', 'char', 'const', 'continue', 'default',
      'do', 'double', 'else', 'enum', 'extern', 'float', 'for',
      'goto', 'if', 'int', 'long', 'register', 'return', 'short',
      'signed', 'sizeof', 'static', 'struct', 'switch', 'typedef',
      'union', 'unsigned', 'void', 'volatile', 'while', 'class',
      'namespace', 'template', 'public', 'private', 'protected',
      'new', 'delete', 'try', 'catch', 'throw', 'using', 'nullptr',
      'true', 'false', 'constexpr', 'override', 'virtual',
    ],
    'go': <String>[
      'break', 'case', 'chan', 'const', 'continue', 'default', 'defer',
      'else', 'fallthrough', 'for', 'func', 'go', 'goto', 'if',
      'import', 'interface', 'map', 'package', 'range', 'return',
      'select', 'struct', 'switch', 'type', 'var', 'nil', 'true',
      'false', 'make', 'new', 'len', 'cap', 'append',
    ],
    'rust': <String>[
      'as', 'async', 'await', 'break', 'const', 'continue', 'crate',
      'dyn', 'else', 'enum', 'extern', 'false', 'fn', 'for', 'if',
      'impl', 'in', 'let', 'loop', 'match', 'mod', 'move', 'mut',
      'pub', 'ref', 'return', 'self', 'static', 'struct', 'super',
      'trait', 'true', 'type', 'unsafe', 'use', 'where', 'while',
    ],
    'sql': <String>[
      'ALTER', 'AND', 'AS', 'ASC', 'BEGIN', 'BETWEEN', 'BY', 'CASE',
      'COMMIT', 'CREATE', 'DELETE', 'DESC', 'DISTINCT', 'DROP',
      'ELSE', 'END', 'EXISTS', 'FROM', 'GROUP', 'HAVING', 'IN',
      'INDEX', 'INNER', 'INSERT', 'INTO', 'IS', 'JOIN', 'LEFT',
      'LIKE', 'LIMIT', 'NOT', 'NULL', 'ON', 'OR', 'ORDER', 'OUTER',
      'PRIMARY', 'RIGHT', 'ROLLBACK', 'SELECT', 'SET', 'TABLE',
      'THEN', 'UNION', 'UPDATE', 'VALUES', 'WHERE',
    ],
    'shell': <String>[
      'case', 'do', 'done', 'elif', 'else', 'esac', 'fi', 'for',
      'function', 'if', 'in', 'local', 'return', 'then', 'until',
      'while', 'export', 'echo', 'cd', 'sudo', 'source', 'exit',
    ],
    'yaml': <String>[
      'true', 'false', 'null', 'on', 'off', 'yes', 'no',
    ],
    'json': <String>['true', 'false', 'null'],
    'html': <String>[],
    'css': <String>[],
  };

  static const Map<String, String> _aliases = <String, String>{
    'js': 'javascript', 'jsx': 'javascript', 'ts': 'javascript',
    'tsx': 'javascript', 'typescript': 'javascript',
    'py': 'python', 'py3': 'python',
    'kt': 'java', 'kotlin': 'java', 'scala': 'java',
    'cpp': 'c', 'c++': 'c', 'cc': 'c', 'h': 'c', 'hpp': 'c',
    'cs': 'java', 'csharp': 'java',
    'rs': 'rust', 'golang': 'go',
    'sh': 'shell', 'bash': 'shell', 'zsh': 'shell', 'shellscript': 'shell',
    'yml': 'yaml', 'toml': 'yaml',
    'xml': 'html', 'svg': 'html',
    'scss': 'css', 'less': 'css',
    'rb': 'python', 'ruby': 'python', 'php': 'python', 'perl': 'python',
  };

  static const Set<String> _hashCommentLangs = <String>{
    'python', 'shell', 'yaml', 'ruby', 'perl', 'php', 'toml',
  };

  /// 高亮代码为富文本 [TextSpan]（整块一个 span，多行不换行）。
  static InlineSpan highlight(
    String code,
    String language,
    WbMarkdownTheme theme,
  ) {
    final String lang = _aliases[language.toLowerCase()] ??
        language.toLowerCase();
    final TextStyle base = TextStyle(
      fontSize: theme.codeFontSize,
      color: theme.codeForeground,
      fontFamily: 'Consolas',
      fontFamilyFallback: WbMarkdownTheme.monoFontFallback,
      height: theme.codeLineHeight,
    );
    final List<String> keywords = _keywords[lang] ?? const <String>[];
    final bool caseInsensitive = lang == 'sql';
    final Set<String> keywordSet = <String>{
      for (final String word in keywords)
        caseInsensitive ? word.toLowerCase() : word,
    };
    final List<TextSpan> spans = <TextSpan>[];
    final StringBuffer plain = StringBuffer();

    void flush() {
      if (plain.isEmpty) {
        return;
      }
      spans.add(TextSpan(text: plain.toString()));
      plain.clear();
    }

    void token(String text, Color color) {
      flush();
      spans.add(TextSpan(text: text, style: TextStyle(color: color)));
    }

    final List<String> lines = code.split('\n');
    for (int li = 0; li < lines.length; li++) {
      final String line = lines[li];
      int i = 0;
      while (i < line.length) {
        final String ch = line[i];
        // 注释。
        if (ch == '/' && i + 1 < line.length && line[i + 1] == '/') {
          token(line.substring(i), theme.codeComment);
          i = line.length;
          break;
        }
        if (ch == '#' &&
            (_hashCommentLangs.contains(lang) || lang.isEmpty)) {
          token(line.substring(i), theme.codeComment);
          i = line.length;
          break;
        }
        if (lang == 'sql' && ch == '-' && i + 1 < line.length && line[i + 1] == '-') {
          token(line.substring(i), theme.codeComment);
          i = line.length;
          break;
        }
        // 字符串。
        if (ch == '"' || ch == "'" || ch == '`') {
          int j = i + 1;
          while (j < line.length) {
            if (line[j] == r'\' && j + 1 < line.length) {
              j += 2;
              continue;
            }
            if (line[j] == ch) {
              j++;
              break;
            }
            j++;
          }
          token(line.substring(i, j), theme.codeString);
          i = j;
          continue;
        }
        // 数字。
        if (_isDigit(ch)) {
          int j = i + 1;
          while (j < line.length &&
              (_isDigit(line[j]) ||
                  line[j] == '.' ||
                  line[j] == 'x' ||
                  line[j] == 'X' ||
                  _isHexLetter(line[j]))) {
            j++;
          }
          token(line.substring(i, j), theme.codeNumber);
          i = j;
          continue;
        }
        // 标识符 / 关键字。
        if (_isIdentStart(ch)) {
          int j = i + 1;
          while (j < line.length && _isIdentPart(line[j])) {
            j++;
          }
          final String word = line.substring(i, j);
          final String probe =
              caseInsensitive ? word.toLowerCase() : word;
          if (keywordSet.contains(probe)) {
            token(word, theme.codeKeyword);
          } else {
            plain.write(word);
          }
          i = j;
          continue;
        }
        plain.write(ch);
        i++;
      }
      flush();
      if (li < lines.length - 1) {
        spans.add(const TextSpan(text: '\n'));
      }
    }
    return TextSpan(style: base, children: spans);
  }

  static bool _isDigit(String ch) {
    final int code = ch.codeUnitAt(0);
    return code >= 0x30 && code <= 0x39;
  }

  static bool _isHexLetter(String ch) {
    final int code = ch.codeUnitAt(0);
    return (code >= 0x61 && code <= 0x66) || (code >= 0x41 && code <= 0x46);
  }

  static bool _isIdentStart(String ch) {
    final int code = ch.codeUnitAt(0);
    return (code >= 0x41 && code <= 0x5A) ||
        (code >= 0x61 && code <= 0x7A) ||
        ch == '_' ||
        ch == r'$' ||
        code > 0x7F;
  }

  static bool _isIdentPart(String ch) =>
      _isIdentStart(ch) || _isDigit(ch);
}
