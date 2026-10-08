/// LaTeX 布局树 → Canvas 绘制（零依赖自研）。
///
/// 方案 §6：LaTeX Source → Math Parser → Math AST → Math Layout →
/// Flutter Renderer；不使用低质量 PNG 作为公式主要渲染方式。
/// 本实现将 AST 转为带度量的可绘制盒（[WbMathBox]），以基线左端点为锚，
/// 便于行内公式与文本基线对齐。
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'math_parser.dart';

/// 公式渲染盒（宽 + 基线上下高度 + 绘制闭包）。
class WbMathBox {
  /// 创建渲染盒。
  const WbMathBox({
    required this.width,
    required this.ascent,
    required this.descent,
    required this.draw,
  });

  /// 宽度。
  final double width;

  /// 基线以上高度。
  final double ascent;

  /// 基线以下高度。
  final double descent;

  /// 绘制：以基线左端点（[baseline]）为锚。
  final void Function(Canvas canvas, Offset baseline) draw;

  /// 总高。
  double get height => ascent + descent;
}

/// LaTeX 渲染入口（纯函数；不抛异常）。
abstract final class WbMathRenderer {
  /// 布局 [node]：返回可绘制盒。
  ///
  /// [fontSize] 为基准字号；[color] 公式前景；[errorColor] 错误提示色。
  static WbMathBox layout(
    WbMathNode node, {
    double fontSize = 15,
    Color color = const Color(0xFF1F2933),
    Color errorColor = const Color(0xFFB42318),
  }) {
    try {
      return _build(node, fontSize, color, errorColor);
    } catch (error) {
      return _build(
        WbMathError('公式渲染失败：$error'),
        fontSize,
        color,
        errorColor,
      );
    }
  }

  // ---- 递归构建 -----------------------------------------------------------

  static WbMathBox _build(
    WbMathNode node,
    double fontSize,
    Color color,
    Color errorColor,
  ) {
    switch (node) {
      case WbMathRow():
        return _buildRow(node.children, fontSize, color, errorColor);
      case WbMathAtom():
        return _buildAtom(node.text, fontSize, color, FontWeight.w400);
      case WbMathSpace():
        final double w = node.widthEm * fontSize;
        return WbMathBox(
          width: w < 0 ? 0 : w,
          ascent: fontSize * 0.30,
          descent: fontSize * 0.10,
          draw: (Canvas canvas, Offset baseline) {},
        );
      case WbMathError():
        return _buildAtom(node.message, fontSize, errorColor, FontWeight.w400);
      case WbMathFrac():
        return _buildFrac(node, fontSize, color, errorColor);
      case WbMathSqrt():
        return _buildSqrt(node, fontSize, color, errorColor);
      case WbMathScript():
        return _buildScript(node, fontSize, color, errorColor);
      case WbMathBigOp():
        return _buildBigOp(node, fontSize, color, errorColor);
      case WbMathDelim():
        return _buildDelim(node, fontSize, color, errorColor);
      case WbMathMatrix():
        return _buildMatrix(node, fontSize, color, errorColor);
    }
  }

  static WbMathBox _buildRow(
    List<WbMathNode> children,
    double fontSize,
    Color color,
    Color errorColor,
  ) {
    if (children.isEmpty) {
      return WbMathBox(
        width: 0,
        ascent: fontSize * 0.30,
        descent: fontSize * 0.10,
        draw: (Canvas canvas, Offset baseline) {},
      );
    }
    final List<WbMathBox> boxes = <WbMathBox>[
      for (final WbMathNode child in children)
        _build(child, fontSize, color, errorColor),
    ];
    double width = 0;
    double ascent = 0;
    double descent = 0;
    final List<double> offsets = <double>[];
    for (final WbMathBox box in boxes) {
      offsets.add(width);
      width += box.width;
      ascent = math.max(ascent, box.ascent);
      descent = math.max(descent, box.descent);
    }
    return WbMathBox(
      width: width,
      ascent: ascent,
      descent: descent,
      draw: (Canvas canvas, Offset baseline) {
        for (int i = 0; i < boxes.length; i++) {
          boxes[i].draw(canvas, baseline + Offset(offsets[i], 0));
        }
      },
    );
  }

  static WbMathBox _buildAtom(
    String text,
    double fontSize,
    Color color,
    FontWeight weight,
  ) {
    final TextPainter painter = _atomPainter(text, fontSize, color, weight);
    final double ascent =
        painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    final double descent = math.max(0, painter.height - ascent);
    return WbMathBox(
      width: painter.width,
      ascent: ascent,
      descent: descent,
      draw: (Canvas canvas, Offset baseline) {
        painter.paint(canvas, Offset(baseline.dx, baseline.dy - ascent));
      },
    );
  }

  static WbMathBox _buildFrac(
    WbMathFrac node,
    double fontSize,
    Color color,
    Color errorColor,
  ) {
    final double shrunk = math.max(fontSize * 0.92, 7);
    final WbMathBox numerator =
        _build(node.numerator, shrunk, color, errorColor);
    final WbMathBox denominator =
        _build(node.denominator, shrunk, color, errorColor);
    const double gap = 3.5;
    const double bar = 1.1;
    final double width = math.max(numerator.width, denominator.width) + 8;
    final double ascent = numerator.height + gap + bar / 2;
    final double descent = denominator.height + gap + bar / 2;
    return WbMathBox(
      width: width,
      ascent: ascent,
      descent: descent,
      draw: (Canvas canvas, Offset baseline) {
        final double barY = baseline.dy - bar / 2;
        final Paint barPaint = Paint()
          ..color = color
          ..strokeWidth = bar;
        canvas.drawLine(
          Offset(baseline.dx, barY),
          Offset(baseline.dx + width, barY),
          barPaint,
        );
        numerator.draw(
          canvas,
          Offset(
            baseline.dx + (width - numerator.width) / 2,
            barY - gap - numerator.descent,
          ),
        );
        denominator.draw(
          canvas,
          Offset(
            baseline.dx + (width - denominator.width) / 2,
            barY + gap + denominator.ascent,
          ),
        );
      },
    );
  }

  static WbMathBox _buildSqrt(
    WbMathSqrt node,
    double fontSize,
    Color color,
    Color errorColor,
  ) {
    final WbMathBox child = _build(node.child, fontSize, color, errorColor);
    final double innerHeight = math.max(child.height, fontSize * 0.9);
    final double radicalWidth = math.max(fontSize * 0.62, innerHeight * 0.28);
    const double overline = 1.2;
    WbMathBox? index;
    double indexWidth = 0;
    if (node.index != null) {
      index = _build(
        node.index!,
        math.max(fontSize * 0.5, 6),
        color,
        errorColor,
      );
      indexWidth = index.width + 1.5;
    }
    const double contentTop = overline + 1.5;
    final double ascent = contentTop + child.ascent;
    final double descent = child.descent + 1.5;
    final double totalWidth =
        indexWidth + radicalWidth + child.width + 2.5;
    return WbMathBox(
      width: totalWidth,
      ascent: ascent,
      descent: descent,
      draw: (Canvas canvas, Offset baseline) {
        final double left = baseline.dx + indexWidth;
        final double contentLeft = left + radicalWidth;
        final double top = baseline.dy - ascent;
        final double bottom =
            baseline.dy + child.descent + 1.0;
        // 根号折线路径。
        final Path path = Path()
          ..moveTo(left, top + innerHeight * 0.55)
          ..lineTo(left + radicalWidth * 0.35, top + innerHeight * 0.45)
          ..lineTo(left + radicalWidth * 0.62, bottom)
          ..lineTo(contentLeft + 1.5, top + contentTop)
          ..lineTo(contentLeft + child.width + 2.5, top + contentTop);
        canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
        child.draw(
          canvas,
          Offset(contentLeft, baseline.dy),
        );
        index?.draw(
          canvas,
          Offset(baseline.dx, top + contentTop + index.ascent * 0.15),
        );
      },
    );
  }

  static WbMathBox _buildScript(
    WbMathScript node,
    double fontSize,
    Color color,
    Color errorColor,
  ) {
    final WbMathBox base = _build(node.base, fontSize, color, errorColor);
    final double scriptSize = math.max(fontSize * 0.7, 7);
    final WbMathBox? sup = node.sup == null
        ? null
        : _build(node.sup!, scriptSize, color, errorColor);
    final WbMathBox? sub = node.sub == null
        ? null
        : _build(node.sub!, scriptSize, color, errorColor);
    final double rightWidth = math.max(
      sup?.width ?? 0,
      sub?.width ?? 0,
    );
    final double supRaise = base.ascent * 0.52;
    final double subDrop = base.descent * 0.42;
    final double ascent =
        base.ascent + (sup == null ? 0 : math.max(0, sup.height - supRaise));
    final double descent = base.descent +
        (sub == null ? 0 : math.max(0, sub.height - subDrop - base.descent * 0.1));
    return WbMathBox(
      width: base.width + rightWidth,
      ascent: ascent,
      descent: descent,
      draw: (Canvas canvas, Offset baseline) {
        base.draw(canvas, baseline);
        if (sup != null) {
          final double supBaseline = baseline.dy - supRaise;
          sup.draw(canvas, Offset(baseline.dx + base.width, supBaseline));
        }
        if (sub != null) {
          final double subBaseline =
              baseline.dy + math.max(base.descent, subDrop + sub.ascent * 0.55);
          sub.draw(canvas, Offset(baseline.dx + base.width, subBaseline));
        }
      },
    );
  }

  static WbMathBox _buildBigOp(
    WbMathBigOp node,
    double fontSize,
    Color color,
    Color errorColor,
  ) {
    final bool isSymbol = node.symbol.length == 1 && node.symbol.codeUnitAt(0) < 0x3000;
    final double symbolSize = isSymbol ? fontSize * 1.65 : fontSize * 1.02;
    final TextPainter symbolPainter = _atomPainter(
      node.symbol,
      symbolSize,
      color,
      isSymbol ? FontWeight.w400 : FontWeight.w600,
    );
    final double symbolAscent =
        symbolPainter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    final double symbolDescent =
        math.max(0, symbolPainter.height - symbolAscent);
    final double scriptSize = math.max(fontSize * 0.62, 6.5);
    final WbMathBox? sub = node.sub == null
        ? null
        : _build(node.sub!, scriptSize, color, errorColor);
    final WbMathBox? sup = node.sup == null
        ? null
        : _build(node.sup!, scriptSize, color, errorColor);
    if (sub == null && sup == null) {
      return WbMathBox(
        width: symbolPainter.width,
        ascent: symbolAscent,
        descent: symbolDescent,
        draw: (Canvas canvas, Offset baseline) {
          symbolPainter.paint(
            canvas,
            Offset(baseline.dx, baseline.dy - symbolAscent),
          );
        },
      );
    }
    // 上下限布局（∑ / ∏ / ∫ 等）：符号居中，limits 上下排列。
    const double gap = 1.5;
    final double width = math.max(
      symbolPainter.width,
      math.max(sub?.width ?? 0, sup?.width ?? 0),
    );
    final double ascent =
        symbolAscent + (sup == null ? 0 : sup.height + gap);
    final double descent =
        symbolDescent + (sub == null ? 0 : sub.height + gap);
    return WbMathBox(
      width: width,
      ascent: ascent,
      descent: descent,
      draw: (Canvas canvas, Offset baseline) {
        final double symbolLeft =
            baseline.dx + (width - symbolPainter.width) / 2;
        symbolPainter.paint(
          canvas,
          Offset(symbolLeft, baseline.dy - symbolAscent),
        );
        if (sup != null) {
          final double top = baseline.dy - symbolAscent - gap - sup.height;
          sup.draw(
            canvas,
            Offset(
              baseline.dx + (width - sup.width) / 2,
              top + sup.ascent,
            ),
          );
        }
        if (sub != null) {
          final double top = baseline.dy + symbolDescent + gap;
          sub.draw(
            canvas,
            Offset(
              baseline.dx + (width - sub.width) / 2,
              top + sub.ascent,
            ),
          );
        }
      },
    );
  }

  static WbMathBox _buildDelim(
    WbMathDelim node,
    double fontSize,
    Color color,
    Color errorColor,
  ) {
    final WbMathBox child = _build(node.child, fontSize, color, errorColor);
    final double delimHeight =
        math.max(child.height + 2, fontSize * 1.15);
    final WbMathBox left = _delimiterBox(node.left, delimHeight, fontSize, color);
    final WbMathBox right =
        _delimiterBox(node.right, delimHeight, fontSize, color);
    final double ascent = math.max(
      child.ascent,
      math.max(left.ascent, right.ascent),
    );
    final double descent = math.max(
      child.descent,
      math.max(left.descent, right.descent),
    );
    return WbMathBox(
      width: left.width + child.width + right.width,
      ascent: ascent,
      descent: descent,
      draw: (Canvas canvas, Offset baseline) {
        left.draw(canvas, baseline);
        child.draw(canvas, Offset(baseline.dx + left.width, baseline.dy));
        right.draw(
          canvas,
          Offset(baseline.dx + left.width + child.width, baseline.dy),
        );
      },
    );
  }

  /// 定界符盒：按目标高度放大字号并垂直居中于基线。
  static WbMathBox _delimiterBox(
    String delimiter,
    double targetHeight,
    double fontSize,
    Color color,
  ) {
    if (delimiter.isEmpty) {
      return WbMathBox(
        width: 0,
        ascent: targetHeight / 2,
        descent: targetHeight / 2,
        draw: (Canvas canvas, Offset baseline) {},
      );
    }
    // 先按基准字号测量，再按高度比缩放字号。
    final TextPainter probe = _atomPainter(delimiter, fontSize, color, FontWeight.w400);
    final double naturalHeight = math.max(probe.height, 1);
    final double scaledSize = (fontSize * targetHeight / naturalHeight)
        .clamp(fontSize, fontSize * 3.2);
    final TextPainter painter =
        _atomPainter(delimiter, scaledSize, color, FontWeight.w400);
    final double ascent =
        painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    final double descent = math.max(0, painter.height - ascent);
    return WbMathBox(
      width: painter.width + 1,
      ascent: math.max(ascent, targetHeight / 2),
      descent: math.max(descent, targetHeight / 2),
      draw: (Canvas canvas, Offset baseline) {
        painter.paint(canvas, Offset(baseline.dx, baseline.dy - ascent));
      },
    );
  }

  static WbMathBox _buildMatrix(
    WbMathMatrix node,
    double fontSize,
    Color color,
    Color errorColor,
  ) {
    const double colGap = 12;
    const double rowGap = 7;
    final double cellSize = math.max(fontSize * 0.92, 7);
    final List<List<WbMathBox>> grid = <List<WbMathBox>>[
      for (final List<WbMathNode> row in node.rows)
        <WbMathBox>[
          for (final WbMathNode cell in row)
            _build(cell, cellSize, color, errorColor),
        ],
    ];
    int columns = 0;
    for (final List<WbMathBox> row in grid) {
      columns = math.max(columns, row.length);
    }
    final List<double> colWidths = List<double>.filled(columns, 0);
    final List<double> rowHeights = List<double>.filled(grid.length, 0);
    for (int r = 0; r < grid.length; r++) {
      for (int c = 0; c < grid[r].length; c++) {
        colWidths[c] = math.max(colWidths[c], grid[r][c].width);
        rowHeights[r] = math.max(
          rowHeights[r],
          grid[r][c].ascent + grid[r][c].descent,
        );
      }
    }
    double innerWidth = 0;
    for (final double w in colWidths) {
      innerWidth += w;
    }
    if (columns > 1) {
      innerWidth += colGap * (columns - 1);
    }
    double innerHeight = 0;
    for (final double h in rowHeights) {
      innerHeight += h;
    }
    if (grid.length > 1) {
      innerHeight += rowGap * (grid.length - 1);
    }
    final bool hasDelim = node.left.isNotEmpty || node.right.isNotEmpty;
    final double delimHeight = innerHeight + 4;
    final WbMathBox left = hasDelim
        ? _delimiterBox(node.left, delimHeight, fontSize, color)
        : _delimiterBox('', 0, fontSize, color);
    final WbMathBox right = hasDelim
        ? _delimiterBox(node.right, delimHeight, fontSize, color)
        : _delimiterBox('', 0, fontSize, color);
    final double width = left.width + innerWidth + right.width;
    final double ascent = innerHeight / 2 + 1.5;
    final double descent = innerHeight / 2 + 1.5;
    return WbMathBox(
      width: width,
      ascent: ascent,
      descent: descent,
      draw: (Canvas canvas, Offset baseline) {
        final double top = baseline.dy - innerHeight / 2;
        double y = top;
        for (int r = 0; r < grid.length; r++) {
          double x = baseline.dx + left.width;
          for (int c = 0; c < columns; c++) {
            if (c < grid[r].length) {
              final WbMathBox cell = grid[r][c];
              final double cellBaseline =
                  y + (rowHeights[r] - (cell.ascent + cell.descent)) / 2 +
                      cell.ascent;
              cell.draw(
                canvas,
                Offset(x + (colWidths[c] - cell.width) / 2, cellBaseline),
              );
            }
            x += colWidths[c] + colGap;
          }
          y += rowHeights[r] + rowGap;
        }
        left.draw(canvas, baseline);
        right.draw(
          canvas,
          Offset(baseline.dx + left.width + innerWidth, baseline.dy),
        );
      },
    );
  }

  // ---- 文本测量缓存 -------------------------------------------------------

  static final Map<String, TextPainter> _atomCache = <String, TextPainter>{};

  static TextPainter _atomPainter(
    String text,
    double fontSize,
    Color color,
    FontWeight weight,
  ) {
    final String key =
        '$text|${fontSize.toStringAsFixed(2)}|${color.toARGB32()}|${weight.value}';
    final TextPainter? cached = _atomCache[key];
    if (cached != null) {
      return cached;
    }
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: weight,
          fontFamilyFallback: const <String>['Cambria', 'Segoe UI'],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    if (_atomCache.length >= 256) {
      _atomCache.clear();
    }
    _atomCache[key] = painter;
    return painter;
  }
}
