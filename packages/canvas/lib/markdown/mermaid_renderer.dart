/// Mermaid 图模型 → Canvas 绘制（零依赖自研，独立 DiagramRenderer）。
///
/// 方案 §5：架构上使用独立的 DiagramRenderer，不把各种图表写死在
/// Markdown Renderer 中。本文件实现 5 类图的布局与绘制：
/// flowchart（分层）/ classDiagram（网格）/ sequenceDiagram（泳道）/
/// stateDiagram（分层）/ erDiagram（网格）；错误返回错误卡片（§20）。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'markdown_theme.dart';
import 'mermaid_parser.dart';

/// 图渲染盒（尺寸 + 以 (0,0) 为原点的绘制闭包）。
class WbMermaidBox {
  /// 创建渲染盒。
  const WbMermaidBox({required this.size, required this.draw});

  /// 布局尺寸（含内部缩放的最终尺寸）。
  final Size size;

  /// 绘制（原点为盒左上角）。
  final void Function(Canvas canvas) draw;
}

/// Mermaid 渲染入口（纯函数；不抛异常）。
abstract final class WbMermaidRenderer {
  /// 布局并生成绘制闭包。
  ///
  /// 图宽超过 [maxWidth] 时按比例整体缩放（矢量缩放保持清晰）。
  static WbMermaidBox layout(
    WbMermaidDiagram diagram, {
    required WbMarkdownTheme theme,
    required double maxWidth,
    double fontSize = 13,
  }) {
    try {
      switch (diagram) {
        case WbMermaidFlowchart():
          return _flowchart(diagram, theme, maxWidth, fontSize);
        case WbMermaidClassDiagram():
          return _classDiagram(diagram, theme, maxWidth, fontSize);
        case WbMermaidSequenceDiagram():
          return _sequence(diagram, theme, maxWidth, fontSize);
        case WbMermaidStateDiagram():
          return _state(diagram, theme, maxWidth, fontSize);
        case WbMermaidErDiagram():
          return _er(diagram, theme, maxWidth, fontSize);
        case WbMermaidError():
          return _errorBox(diagram, theme, maxWidth, fontSize);
      }
    } catch (error) {
      return _errorBox(
        WbMermaidError(detail: 'Render error: $error'),
        theme,
        maxWidth,
        fontSize,
      );
    }
  }

  /// 统一包一层缩放：布局宽 > maxWidth 时缩小绘制。
  static WbMermaidBox _scaled(
    Size size,
    void Function(Canvas canvas) draw,
    double maxWidth,
  ) {
    if (maxWidth <= 0 || size.width <= maxWidth) {
      return WbMermaidBox(size: size, draw: draw);
    }
    final double scale = maxWidth / size.width;
    return WbMermaidBox(
      size: Size(maxWidth, size.height * scale),
      draw: (Canvas canvas) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(0, 0, maxWidth, size.height * scale));
        canvas.scale(scale);
        draw(canvas);
        canvas.restore();
      },
    );
  }

  // ---- 错误卡片 -----------------------------------------------------------

  static WbMermaidBox _errorBox(
    WbMermaidError error,
    WbMarkdownTheme theme,
    double maxWidth,
    double fontSize,
  ) {
    final double width = math.min(maxWidth, 380);
    const double headerH = 26;
    final TextPainter title =
        _text('Mermaid', fontSize * 0.82, theme.muted, FontWeight.w600);
    final TextPainter message =
        _text(error.message, fontSize, theme.errorForeground, null);
    final TextPainter detail = _text(
      error.detail,
      fontSize * 0.85,
      theme.muted,
      null,
      maxWidth: width - 28,
    );
    final double height =
        headerH + message.height + detail.height + 26;
    return WbMermaidBox(
      size: Size(width, height),
      draw: (Canvas canvas) {
        final Rect rect = Rect.fromLTWH(0, 0, width, height);
        _roundRect(
          canvas,
          rect,
          fill: theme.errorBackground,
          stroke: theme.errorBorder,
          radius: 8,
        );
        title.paint(canvas, const Offset(14, 9));
        message.paint(canvas, const Offset(14, headerH));
        detail.paint(canvas, Offset(14, headerH + message.height + 4));
      },
    );
  }

  // ---- flowchart ----------------------------------------------------------

  static WbMermaidBox _flowchart(
    WbMermaidFlowchart diagram,
    WbMarkdownTheme theme,
    double maxWidth,
    double fontSize,
  ) {
    const double itemGap = 32; // 轨道内 / 散节点间隔。
    const double trackGap = 56; // 轨道间距。
    const double groupPad = 14; // 子图框内边距。
    const double headerH = 20; // 子图标题带高度。
    final bool horizontal =
        diagram.direction == 'LR' || diagram.direction == 'RL';
    final bool reversed =
        diagram.direction == 'BT' || diagram.direction == 'RL';
    final double laneGap = diagram.subgraphs.isEmpty ? 52 : 76;
    if (diagram.nodes.isEmpty) {
      return WbMermaidBox(size: Size.zero, draw: (Canvas canvas) {});
    }

    // 节点尺寸（文本换行测量）。
    final Map<String, Size> sizes = <String, Size>{};
    final Map<String, TextPainter> labels = <String, TextPainter>{};
    for (final WbMermaidNode node in diagram.nodes) {
      final double maxText = horizontal ? 150 : 168;
      final TextPainter painter = _text(
        node.label,
        fontSize,
        theme.diagramText,
        null,
        maxWidth: maxText,
        center: true,
      );
      labels[node.id] = painter;
      double w = painter.width + 26;
      double h = painter.height + 16;
      switch (node.shape) {
        case WbMermaidNodeShape.circle:
          w = math.max(w, h + 10);
          h = math.max(h, w);
        case WbMermaidNodeShape.diamond:
          w = w * 1.25 + 12;
          h = h * 1.5;
        case WbMermaidNodeShape.hexagon:
          w += 18;
        case WbMermaidNodeShape.asymmetric:
          w += 12;
        default:
          break;
      }
      sizes[node.id] = Size(math.max(w, 64), math.max(h, 34));
    }

    // 分层：Bellman-Ford 风格松弛（对环有上限保护）。
    final Map<String, int> rank = <String, int>{
      for (final WbMermaidNode node in diagram.nodes) node.id: 0,
    };
    final int cap = diagram.nodes.length;
    for (int iter = 0; iter < cap; iter++) {
      bool changed = false;
      for (final WbMermaidEdge edge in diagram.edges) {
        if (!rank.containsKey(edge.from) || !rank.containsKey(edge.to)) {
          continue;
        }
        if (rank[edge.from]! + 1 > rank[edge.to]! &&
            rank[edge.from]! + 1 <= cap) {
          rank[edge.to] = rank[edge.from]! + 1;
          changed = true;
        }
      }
      if (!changed) {
        break;
      }
    }

    // 行（rank → 节点序；声明序）。
    final Map<int, List<String>> rows = <int, List<String>>{};
    for (final WbMermaidNode node in diagram.nodes) {
      rows.putIfAbsent(rank[node.id]!, () => <String>[]).add(node.id);
    }
    final List<int> rowKeys = rows.keys.toList()..sort();

    // 主 / 交叉轴辅助（布局均在视觉坐标系中完成）。
    double mainOf(Size s) => horizontal ? s.width : s.height;
    double crossOf(Size s) => horizontal ? s.height : s.width;

    // 子图轨道：节点 → 组（-1 为散节点区）。
    final Map<String, int> nodeGroup = <String, int>{};
    for (int g = 0; g < diagram.subgraphs.length; g++) {
      for (final String id in diagram.subgraphs[g].nodeIds) {
        nodeGroup.putIfAbsent(id, () => g);
      }
    }
    int groupOf(String id) => nodeGroup[id] ?? -1;
    final List<int> trackGroups = <int>[
      for (int g = 0; g < diagram.subgraphs.length; g++)
        if (diagram.subgraphs[g].nodeIds.isNotEmpty) g,
    ];

    // 轨道交叉轴尺寸（各行取最大；成员在该轨道内居中）。
    final Map<int, double> trackCrossSize = <int, double>{};
    for (final int g in <int>[...trackGroups, -1]) {
      double need = 0;
      for (final int r in rowKeys) {
        double line = 0;
        int count = 0;
        for (final String id in rows[r]!) {
          if (groupOf(id) == g) {
            line += crossOf(sizes[id]!);
            count++;
          }
        }
        if (count > 0) {
          need = math.max(need, line + (count - 1) * itemGap);
        }
      }
      trackCrossSize[g] = need;
    }
    final List<int> trackOrder = <int>[
      ...trackGroups,
      if (trackCrossSize[-1]! > 0) -1,
    ];

    // 轨道交叉轴位置。
    final Map<int, double> trackStart = <int, double>{};
    double crossCursor = groupPad;
    for (final int g in trackOrder) {
      trackStart[g] = crossCursor;
      crossCursor += trackCrossSize[g]! + trackGap;
    }
    crossCursor = trackOrder.isEmpty ? 0 : crossCursor - trackGap;
    double totalCross = crossCursor + groupPad;

    // 行主轴位置（子图标题带在流向起点端预留）。
    final bool hasGroups = trackGroups.isNotEmpty;
    final double mainOrigin = hasGroups ? headerH + groupPad : 0;
    final Map<int, double> rowMainSize = <int, double>{};
    final Map<int, double> rowTop = <int, double>{};
    double mainCursor = mainOrigin;
    for (final int r in rowKeys) {
      double m = 0;
      for (final String id in rows[r]!) {
        m = math.max(m, mainOf(sizes[id]!));
      }
      rowMainSize[r] = m;
      rowTop[r] = mainCursor;
      mainCursor += m + laneGap;
    }
    final double mainEnd = mainCursor - laneGap;
    final double totalMain = mainEnd + (hasGroups ? headerH + groupPad : 0);

    // 节点矩形（轨道内居中）。
    final Map<String, Rect> rects = <String, Rect>{};
    for (final int r in rowKeys) {
      for (final int g in trackOrder) {
        final List<String> members = <String>[
          for (final String id in rows[r]!)
            if (groupOf(id) == g) id,
        ];
        if (members.isEmpty) {
          continue;
        }
        double line = 0;
        for (final String id in members) {
          line += crossOf(sizes[id]!);
        }
        line += (members.length - 1) * itemGap;
        double cross = trackStart[g]! + (trackCrossSize[g]! - line) / 2;
        for (final String id in members) {
          final Size s = sizes[id]!;
          final double m = rowTop[r]! + (rowMainSize[r]! - mainOf(s)) / 2;
          rects[id] = horizontal
              ? Rect.fromLTWH(m, cross, s.width, s.height)
              : Rect.fromLTWH(cross, m, s.width, s.height);
          cross += crossOf(s) + itemGap;
        }
      }
    }

    // BT / RL：主轴镜像（视觉流向反转）。
    if (reversed) {
      double flip(double value, double span) =>
          mainOrigin + mainEnd - value - span;
      for (final String id in rects.keys.toList()) {
        final Rect rect = rects[id]!;
        rects[id] = horizontal
            ? Rect.fromLTWH(
                flip(rect.left, rect.width), rect.top, rect.width, rect.height)
            : Rect.fromLTWH(rect.left, flip(rect.top, rect.height),
                rect.width, rect.height);
      }
      for (final int key in rowKeys) {
        rowTop[key] = flip(rowTop[key]!, rowMainSize[key]!);
      }
    }

    // 边折线路由（相邻行段 + 行间 lane；跨行经行内间隙通道）。
    final List<List<Offset>> edgePaths = List<List<Offset>>.generate(
      diagram.edges.length,
      (_) => const <Offset>[],
    );
    final List<int> corridorEdges = <int>[];
    for (int i = 0; i < diagram.edges.length; i++) {
      final WbMermaidEdge edge = diagram.edges[i];
      final Rect? from = rects[edge.from];
      final Rect? to = rects[edge.to];
      if (from == null || to == null) {
        continue;
      }
      if (edge.from == edge.to) {
        // 自环：主轴两侧出、交叉轴外侧绕行。
        final double mC = horizontal ? from.center.dy : from.center.dx;
        final double cE = horizontal ? from.right : from.bottom;
        final double cOut = cE + 30;
        edgePaths[i] = horizontal
            ? <Offset>[
                Offset(cE, mC - 10),
                Offset(cOut, mC - 10),
                Offset(cOut, mC + 10),
                Offset(cE, mC + 10),
              ]
            : <Offset>[
                Offset(mC - 10, cE),
                Offset(mC - 10, cOut),
                Offset(mC + 10, cOut),
                Offset(mC + 10, cE),
              ];
        continue;
      }
      final bool forward = horizontal
          ? (reversed
              ? to.center.dx < from.center.dx
              : to.center.dx > from.center.dx)
          : (reversed
              ? to.center.dy < from.center.dy
              : to.center.dy > from.center.dy);
      if (!forward) {
        // 同层 / 逆层：交叉轴外侧走廊（稍后统一生成，逐条错开）。
        corridorEdges.add(i);
        continue;
      }
      edgePaths[i] = _flowEdgePath(
        from: from,
        to: to,
        fromRank: rank[edge.from]!,
        toRank: rank[edge.to]!,
        nodes: diagram.nodes,
        rank: rank,
        rects: rects,
        rowKeys: rowKeys,
        rowTop: rowTop,
        rowMainSize: rowMainSize,
        horizontal: horizontal,
        reversed: reversed,
      );
    }
    double corridorCross = 0;
    for (final Rect rect in rects.values) {
      corridorCross =
          math.max(corridorCross, horizontal ? rect.bottom : rect.right);
    }
    corridorCross += 16;
    for (int k = 0; k < corridorEdges.length; k++) {
      final int i = corridorEdges[k];
      final WbMermaidEdge edge = diagram.edges[i];
      final Rect from = rects[edge.from]!;
      final Rect to = rects[edge.to]!;
      final double mFrom = horizontal ? from.center.dx : from.center.dy;
      final double mTo = horizontal ? to.center.dx : to.center.dy;
      final double cFrom = horizontal ? from.bottom : from.right;
      final double cTo = horizontal ? to.bottom : to.right;
      final double lane = corridorCross + k * 9;
      edgePaths[i] = horizontal
          ? <Offset>[
              Offset(mFrom, cFrom),
              Offset(mFrom, lane),
              Offset(mTo, lane),
              Offset(mTo, cTo),
            ]
          : <Offset>[
              Offset(cFrom, mFrom),
              Offset(lane, mFrom),
              Offset(lane, mTo),
              Offset(cTo, mTo),
            ];
    }
    if (corridorEdges.isNotEmpty) {
      totalCross = math.max(
        totalCross,
        corridorCross + (corridorEdges.length - 1) * 9 + 8,
      );
    }

    // 子图框（成员包围盒 + 标题带）。
    final Map<int, Rect> groupFrames = <int, Rect>{};
    final Map<int, TextPainter> groupTitles = <int, TextPainter>{};
    for (final int g in trackGroups) {
      double mMin = double.infinity;
      double mMax = -double.infinity;
      double cMin = double.infinity;
      double cMax = -double.infinity;
      for (final String id in diagram.subgraphs[g].nodeIds) {
        final Rect? rect = rects[id];
        if (rect == null) {
          continue;
        }
        mMin = math.min(mMin, horizontal ? rect.left : rect.top);
        mMax = math.max(mMax, horizontal ? rect.right : rect.bottom);
        cMin = math.min(cMin, horizontal ? rect.top : rect.left);
        cMax = math.max(cMax, horizontal ? rect.bottom : rect.right);
      }
      if (mMin > mMax) {
        continue;
      }
      // 标题带位于流向起点端（reversed 时在视觉另一端）。
      final double m0 = reversed ? mMin - groupPad : mMin - headerH - groupPad;
      final double m1 = reversed ? mMax + headerH + groupPad : mMax + groupPad;
      groupFrames[g] = horizontal
          ? Rect.fromLTRB(m0, cMin - groupPad, m1, cMax + groupPad)
          : Rect.fromLTRB(cMin - groupPad, m0, cMax + groupPad, m1);
      groupTitles[g] = _text(
        diagram.subgraphs[g].title,
        fontSize * 0.85,
        theme.diagramText.withValues(alpha: 0.85),
        FontWeight.w600,
      );
    }

    final Size total = horizontal
        ? Size(totalMain, totalCross)
        : Size(totalCross, totalMain);
    return _scaled(
      total,
      (Canvas canvas) {
        // 子图框（最底层）。
        for (final int g in trackGroups) {
          final Rect? frame = groupFrames[g];
          if (frame == null) {
            continue;
          }
          _roundRect(
            canvas,
            frame,
            fill: theme.diagramFill.withValues(alpha: 0.5),
            stroke: theme.diagramStroke.withValues(alpha: 0.35),
            radius: 8,
            strokeWidth: 1.1,
          );
          final TextPainter title = groupTitles[g]!;
          final double tx;
          final double ty;
          if (!reversed) {
            tx = frame.left + 10;
            ty = frame.top + 5;
          } else if (horizontal) {
            tx = frame.right - title.width - 10;
            ty = frame.top + 5;
          } else {
            tx = frame.left + 10;
            ty = frame.bottom - title.height - 5;
          }
          title.paint(canvas, Offset(tx, ty));
        }
        // 连线（节点下层；虚线最后画，交叉处不被实线盖没）。
        for (int pass = 0; pass < 2; pass++) {
          for (int i = 0; i < diagram.edges.length; i++) {
            final WbMermaidEdge edge = diagram.edges[i];
            final bool dotted = edge.style == WbMermaidEdgeStyle.dotted;
            if (pass == 0 && dotted) {
              continue;
            }
            if (pass == 1 && !dotted) {
              continue;
            }
            final List<Offset> points = edgePaths[i];
            if (points.length < 2) {
              continue;
            }
            _drawFlowEdgePath(canvas, points, edge, theme);
          }
        }
        // 节点。
        for (final WbMermaidNode node in diagram.nodes) {
          final Rect? rect = rects[node.id];
          if (rect == null) {
            continue;
          }
          _drawFlowNode(canvas, rect, node.shape, theme, labels[node.id]!);
        }
        // 连线标签（顶层：限宽换行 + 底色描边，不被节点 / 线遮盖）。
        for (int i = 0; i < diagram.edges.length; i++) {
          final WbMermaidEdge edge = diagram.edges[i];
          if (edge.label.isEmpty) {
            continue;
          }
          _flowEdgeLabel(canvas, edge.label, edgePaths[i], theme, fontSize);
        }
      },
      maxWidth,
    );
  }

  /// 前向（跨行）边折线：逐行经 lane 水平段 + 行内间隙通道。
  static List<Offset> _flowEdgePath({
    required Rect from,
    required Rect to,
    required int fromRank,
    required int toRank,
    required List<WbMermaidNode> nodes,
    required Map<String, int> rank,
    required Map<String, Rect> rects,
    required List<int> rowKeys,
    required Map<int, double> rowTop,
    required Map<int, double> rowMainSize,
    required bool horizontal,
    required bool reversed,
  }) {
    double exitMain(Rect rect) => reversed
        ? (horizontal ? rect.left : rect.top)
        : (horizontal ? rect.right : rect.bottom);
    double entryMain(Rect rect) => reversed
        ? (horizontal ? rect.right : rect.bottom)
        : (horizontal ? rect.left : rect.top);
    double crossCenter(Rect rect) =>
        horizontal ? rect.center.dy : rect.center.dx;
    double leadingEdge(int r) =>
        reversed ? rowTop[r]! + rowMainSize[r]! : rowTop[r]!;
    double trailingEdge(int r) =>
        reversed ? rowTop[r]! : rowTop[r]! + rowMainSize[r]!;
    Offset at(double main, double cross) =>
        horizontal ? Offset(main, cross) : Offset(cross, main);

    final List<Offset> points = <Offset>[];
    final double fromCross = crossCenter(from);
    final double toCross = crossCenter(to);
    double curCross = fromCross;
    double curMain = exitMain(from);
    points.add(at(curMain, curCross));
    // 中间行（rank 位于起止之间）：行间 lane 调整后竖直穿过该行。
    for (final int r in rowKeys) {
      if (r <= fromRank || r >= toRank) {
        continue;
      }
      final double lane = (curMain + leadingEdge(r)) / 2;
      final double ratio = (r - fromRank) / (toRank - fromRank);
      final double preferred = fromCross + (toCross - fromCross) * ratio;
      final List<Rect> rowRects = <Rect>[
        for (final WbMermaidNode node in nodes)
          if (rank[node.id] == r && rects.containsKey(node.id))
            rects[node.id]!,
      ];
      final double px = _channelCross(rowRects, preferred, horizontal);
      points.add(at(lane, curCross));
      points.add(at(lane, px));
      points.add(at(trailingEdge(r), px));
      curCross = px;
      curMain = trailingEdge(r);
    }
    final double lastLane = (curMain + entryMain(to)) / 2;
    points.add(at(lastLane, curCross));
    points.add(at(lastLane, toCross));
    points.add(at(entryMain(to), toCross));
    return points;
  }

  /// 行内竖直通道：优先 [preferred]，被节点挡住时取最近的间隙。
  static double _channelCross(
    List<Rect> rowRects,
    double preferred,
    bool horizontal,
  ) {
    if (rowRects.isEmpty) {
      return preferred;
    }
    double crossStart(Rect rect) => horizontal ? rect.top : rect.left;
    double crossEnd(Rect rect) => horizontal ? rect.bottom : rect.right;
    bool blocked(double value) {
      for (final Rect rect in rowRects) {
        if (value > crossStart(rect) - 6 && value < crossEnd(rect) + 6) {
          return true;
        }
      }
      return false;
    }

    if (!blocked(preferred)) {
      return preferred;
    }
    double best = preferred;
    double bestDistance = double.infinity;
    void consider(double candidate) {
      if (blocked(candidate)) {
        return;
      }
      final double distance = (candidate - preferred).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = candidate;
      }
    }

    double minCross = double.infinity;
    double maxCross = -double.infinity;
    for (final Rect rect in rowRects) {
      minCross = math.min(minCross, crossStart(rect));
      maxCross = math.max(maxCross, crossEnd(rect));
      consider(crossStart(rect) - 8);
      consider(crossEnd(rect) + 8);
    }
    consider(minCross - 12);
    consider(maxCross + 12);
    return best;
  }

  /// 按平滑曲线画一条流程图连线（虚线 / 粗线 / 箭头；标签由调用方顶层绘制）。
  static void _drawFlowEdgePath(
    Canvas canvas,
    List<Offset> points,
    WbMermaidEdge edge,
    WbMarkdownTheme theme,
  ) {
    if (points.length < 2) {
      return;
    }
    final Paint paint = Paint()
      ..color = theme.diagramStroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = edge.style == WbMermaidEdgeStyle.thick ? 2.4 : 1.3;
    final Path path = _flowEdgeCurve(points);
    if (edge.style == WbMermaidEdgeStyle.dotted) {
      _dashedPath(canvas, path, paint);
    } else {
      canvas.drawPath(path, paint);
    }
    if (edge.hasArrow) {
      // 方向 = 末段方向（末端不做圆角）；基座在节点外，不被后绘制的
      // 节点填充遮盖。
      _arrowHead(
        canvas,
        points.last,
        points.last - points[points.length - 2],
        theme.diagramStroke,
      );
    }
  }

  /// 折线控制点 → 圆角平滑曲线（转角半径按相邻段长折半、限幅 18，
  /// 长段接短段也不会过冲；相邻重复点先去重）。
  static Path _flowEdgeCurve(List<Offset> points) {
    final List<Offset> pts = <Offset>[];
    for (final Offset p in points) {
      if (pts.isEmpty || (p - pts.last).distance > 0.5) {
        pts.add(p);
      }
    }
    final Path path = Path()..moveTo(pts.first.dx, pts.first.dy);
    if (pts.length < 2) {
      return path;
    }
    for (int i = 1; i + 1 < pts.length; i++) {
      final Offset prev = pts[i - 1];
      final Offset v = pts[i];
      final Offset next = pts[i + 1];
      final double lenIn = (v - prev).distance;
      final double lenOut = (next - v).distance;
      final double r = math.min(math.min(lenIn, lenOut) * 0.5, 18);
      if (r < 1) {
        path.lineTo(v.dx, v.dy);
        continue;
      }
      final Offset enter = v - (v - prev) * (r / lenIn);
      final Offset exit = v + (next - v) * (r / lenOut);
      path.lineTo(enter.dx, enter.dy);
      path.quadraticBezierTo(v.dx, v.dy, exit.dx, exit.dy);
    }
    path.lineTo(pts.last.dx, pts.last.dy);
    return path;
  }

  /// 折线上按累计长度取 50% 处的位置。
  static Offset _polylineMidpoint(List<Offset> points) {
    double total = 0;
    for (int i = 0; i + 1 < points.length; i++) {
      total += (points[i + 1] - points[i]).distance;
    }
    if (total <= 0.01) {
      return points.first;
    }
    double target = total / 2;
    for (int i = 0; i + 1 < points.length; i++) {
      final double segment = (points[i + 1] - points[i]).distance;
      if (target <= segment) {
        final double t = segment <= 0.01 ? 0 : target / segment;
        return points[i] + (points[i + 1] - points[i]) * t;
      }
      target -= segment;
    }
    return points.last;
  }

  /// 流程图连线标签：折线中点、限宽换行、底色 + 细描边（顶层绘制）。
  static void _flowEdgeLabel(
    Canvas canvas,
    String text,
    List<Offset> points,
    WbMarkdownTheme theme,
    double fontSize,
  ) {
    if (points.length < 2) {
      return;
    }
    final TextPainter painter = _text(
      text,
      fontSize * 0.86,
      theme.diagramText,
      null,
      maxWidth: 168,
      center: true,
    );
    final Rect rect = Rect.fromCenter(
      center: _polylineMidpoint(points),
      width: painter.width + 10,
      height: painter.height + 4,
    );
    _roundRect(
      canvas,
      rect,
      fill: theme.background,
      stroke: theme.border,
      radius: 4,
      strokeWidth: 0.8,
    );
    painter.paint(
      canvas,
      Offset(
        rect.center.dx - painter.width / 2,
        rect.center.dy - painter.height / 2,
      ),
    );
  }

  static void _drawFlowNode(
    Canvas canvas,
    Rect rect,
    WbMermaidNodeShape shape,
    WbMarkdownTheme theme,
    TextPainter label,
  ) {
    final Paint fill = Paint()..color = theme.diagramFill;
    final Paint stroke = Paint()
      ..color = theme.diagramStroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    switch (shape) {
      case WbMermaidNodeShape.round:
        _roundRect(canvas, rect, fill: theme.diagramFill, stroke: theme.diagramStroke, radius: math.min(rect.height / 2, 12));
      case WbMermaidNodeShape.stadium:
        _roundRect(canvas, rect, fill: theme.diagramFill, stroke: theme.diagramStroke, radius: rect.height / 2);
      case WbMermaidNodeShape.circle:
        canvas.drawOval(rect, fill);
        canvas.drawOval(rect, stroke);
      case WbMermaidNodeShape.diamond:
        final Path path = Path()
          ..moveTo(rect.center.dx, rect.top)
          ..lineTo(rect.right, rect.center.dy)
          ..lineTo(rect.center.dx, rect.bottom)
          ..lineTo(rect.left, rect.center.dy)
          ..close();
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
      case WbMermaidNodeShape.hexagon:
        final double inset = rect.height / 2;
        final Path path = Path()
          ..moveTo(rect.left + inset, rect.top)
          ..lineTo(rect.right - inset, rect.top)
          ..lineTo(rect.right, rect.center.dy)
          ..lineTo(rect.right - inset, rect.bottom)
          ..lineTo(rect.left + inset, rect.bottom)
          ..lineTo(rect.left, rect.center.dy)
          ..close();
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
      case WbMermaidNodeShape.subroutine:
        _roundRect(canvas, rect, fill: theme.diagramFill, stroke: theme.diagramStroke, radius: 4);
        canvas.drawLine(
          Offset(rect.left + 8, rect.top),
          Offset(rect.left + 8, rect.bottom),
          stroke,
        );
        canvas.drawLine(
          Offset(rect.right - 8, rect.top),
          Offset(rect.right - 8, rect.bottom),
          stroke,
        );
      case WbMermaidNodeShape.asymmetric:
        final Path path = Path()
          ..moveTo(rect.left, rect.top)
          ..lineTo(rect.right, rect.top)
          ..lineTo(rect.right, rect.bottom)
          ..lineTo(rect.left, rect.bottom)
          ..lineTo(rect.left + 10, rect.center.dy)
          ..close();
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
      case WbMermaidNodeShape.rect:
        _roundRect(canvas, rect, fill: theme.diagramFill, stroke: theme.diagramStroke, radius: 6);
    }
    label.paint(
      canvas,
      Offset(
        rect.center.dx - label.width / 2,
        rect.center.dy - label.height / 2,
      ),
    );
  }

  // ---- classDiagram -------------------------------------------------------

  static WbMermaidBox _classDiagram(
    WbMermaidClassDiagram diagram,
    WbMarkdownTheme theme,
    double maxWidth,
    double fontSize,
  ) {
    const double titleH = 30;
    const double memberH = 19;
    final Map<String, Rect> rects = <String, Rect>{};
    final Map<String, List<TextPainter>> memberPainters =
        <String, List<TextPainter>>{};
    final Map<String, TextPainter> titlePainters = <String, TextPainter>{};
    final List<({String name, double w, double h})> boxes =
        <({String name, double w, double h})>[];
    for (final WbMermaidClass cls in diagram.classes) {
      final TextPainter title =
          _text(cls.name, fontSize, theme.diagramText, FontWeight.w600);
      titlePainters[cls.name] = title;
      double w = title.width + 28;
      final List<TextPainter> members = <TextPainter>[];
      for (final String member in cls.members) {
        final TextPainter painter = _text(
          member,
          fontSize * 0.9,
          theme.diagramText,
          null,
          maxWidth: 220,
        );
        members.add(painter);
        w = math.max(w, painter.width + 28);
      }
      memberPainters[cls.name] = members;
      w = w.clamp(110, 260);
      final double h = titleH + math.max(members.length, 1) * memberH + 10;
      boxes.add((name: cls.name, w: w, h: h));
    }
    // 网格排布。
    const double gapX = 28;
    const double gapY = 34;
    double cursorX = 0;
    double cursorY = 0;
    double rowH = 0;
    double totalW = 0;
    for (final ({String name, double w, double h}) box in boxes) {
      if (cursorX > 0 && cursorX + box.w > maxWidth) {
        cursorX = 0;
        cursorY += rowH + gapY;
        rowH = 0;
      }
      rects[box.name] = Rect.fromLTWH(cursorX, cursorY, box.w, box.h);
      cursorX += box.w + gapX;
      rowH = math.max(rowH, box.h);
      totalW = math.max(totalW, cursorX - gapX);
    }
    final double totalH = cursorY + rowH;

    return _scaled(
      Size(totalW, totalH),
      (Canvas canvas) {
        // 同盒多条关系的端点槽位（在同一边缘上错开，避免完全重叠）。
        final Map<String, int> outSlot = <String, int>{};
        final Map<String, int> inSlot = <String, int>{};
        final Map<String, int> outTotal = <String, int>{};
        final Map<String, int> inTotal = <String, int>{};
        for (final WbMermaidClassRelation relation in diagram.relations) {
          outTotal[relation.from] = (outTotal[relation.from] ?? 0) + 1;
          inTotal[relation.to] = (inTotal[relation.to] ?? 0) + 1;
        }
        for (final WbMermaidClassRelation relation in diagram.relations) {
          final Rect? from = rects[relation.from];
          final Rect? to = rects[relation.to];
          if (from == null || to == null) {
            continue;
          }
          final int os = outSlot[relation.from] ?? 0;
          outSlot[relation.from] = os + 1;
          final int ins = inSlot[relation.to] ?? 0;
          inSlot[relation.to] = ins + 1;
          _drawClassRelation(
            canvas,
            from,
            to,
            relation,
            theme,
            fontSize,
            startSlot: (os, outTotal[relation.from]!),
            endSlot: (ins, inTotal[relation.to]!),
          );
        }
        for (final WbMermaidClass cls in diagram.classes) {
          final Rect? rect = rects[cls.name];
          if (rect == null) {
            continue;
          }
          _roundRect(canvas, rect, fill: theme.diagramFill, stroke: theme.diagramStroke, radius: 4);
          canvas.drawLine(
            Offset(rect.left, rect.top + titleH),
            Offset(rect.right, rect.top + titleH),
            Paint()
              ..color = theme.diagramStroke
              ..strokeWidth = 1,
          );
          final TextPainter title = titlePainters[cls.name]!;
          title.paint(
            canvas,
            Offset(rect.center.dx - title.width / 2, rect.top + (titleH - title.height) / 2),
          );
          final List<TextPainter> members = memberPainters[cls.name]!;
          final double startY = rect.top + titleH + 5;
          for (int i = 0; i < members.length; i++) {
            members[i].paint(canvas, Offset(rect.left + 10, startY + i * memberH));
          }
        }
      },
      maxWidth,
    );
  }

  static void _drawClassRelation(
    Canvas canvas,
    Rect from,
    Rect to,
    WbMermaidClassRelation relation,
    WbMarkdownTheme theme,
    double fontSize, {
    required (int, int) startSlot,
    required (int, int) endSlot,
  }) {
    final (Offset start, Offset end) = _classAnchors(from, to, startSlot, endSlot);
    final (Offset c1, Offset c2) = _classCurveControls(start, end);
    final Path path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
    final String marker = relation.marker;
    final bool dashed = marker.contains('..');
    final Paint paint = Paint()
      ..color = theme.diagramStroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    if (dashed) {
      _dashedPath(canvas, path, paint);
    } else {
      canvas.drawPath(path, paint);
    }
    // 端点切线方向（起点为向外方向、终点为指向终点方向）。
    final Offset startDir = start - c1;
    final Offset endDir = end - c2;
    // 左端标记。
    if (marker.startsWith('<|')) {
      _hollowTriangle(canvas, start, startDir, theme.diagramStroke,
          fill: theme.background);
    } else if (marker.startsWith('<')) {
      _openArrow(canvas, start, startDir, theme.diagramStroke);
    } else if (marker.startsWith('*')) {
      _diamondMarker(canvas, start, startDir, theme.diagramStroke,
          filled: true);
    } else if (marker.startsWith('o')) {
      _diamondMarker(canvas, start, startDir, theme.diagramStroke,
          filled: false, hollowFill: theme.background);
    }
    // 右端标记。
    if (marker.endsWith('|>')) {
      _hollowTriangle(canvas, end, endDir, theme.diagramStroke,
          fill: theme.background);
    } else if (marker.endsWith('>')) {
      _arrowHead(canvas, end, endDir, theme.diagramStroke);
    } else if (marker.endsWith('*')) {
      _diamondMarker(canvas, end, endDir, theme.diagramStroke, filled: true);
    } else if (marker.endsWith('o')) {
      _diamondMarker(canvas, end, endDir, theme.diagramStroke,
          filled: false, hollowFill: theme.background);
    }
    if (relation.label.isNotEmpty) {
      final Offset mid = _cubicAt(start, c1, c2, end, 0.5);
      _edgeLabel(canvas, relation.label, mid, mid, theme, fontSize);
    }
  }

  /// 类图连线锚点：按主方向取边缘中点（曲线沿边缘法线进出）。
  ///
  /// 同盒多条关系按槽位在边缘错开，避免线条完全重叠。
  static (Offset, Offset) _classAnchors(
    Rect from,
    Rect to,
    (int, int) startSlot,
    (int, int) endSlot,
  ) {
    final Offset dc = to.center - from.center;
    double slotOffset(double center, (int, int) slot, double span) {
      final int count = slot.$2;
      if (count <= 1) {
        return center;
      }
      final double step = math.min(16, (span - 16) / (count - 1));
      return center + (slot.$1 - (count - 1) / 2) * step;
    }
    if (dc.dx.abs() >= dc.dy.abs()) {
      final bool rightward = dc.dx >= 0;
      return (
        Offset(rightward ? from.right : from.left,
            slotOffset(from.center.dy, startSlot, from.height)),
        Offset(rightward ? to.left : to.right,
            slotOffset(to.center.dy, endSlot, to.height)),
      );
    }
    final bool downward = dc.dy >= 0;
    return (
      Offset(slotOffset(from.center.dx, startSlot, from.width),
          downward ? from.bottom : from.top),
      Offset(slotOffset(to.center.dx, endSlot, to.width),
          downward ? to.top : to.bottom),
    );
  }

  /// 类图 S 形曲线控制点（按主方向水平/垂直进出）。
  static (Offset, Offset) _classCurveControls(Offset start, Offset end) {
    final double dx = end.dx - start.dx;
    final double dy = end.dy - start.dy;
    if (dx.abs() >= dy.abs()) {
      return (
        Offset(start.dx + dx * 0.5, start.dy),
        Offset(end.dx - dx * 0.5, end.dy),
      );
    }
    return (
      Offset(start.dx, start.dy + dy * 0.5),
      Offset(end.dx, end.dy - dy * 0.5),
    );
  }

  // ---- sequenceDiagram ----------------------------------------------------

  static WbMermaidBox _sequence(
    WbMermaidSequenceDiagram diagram,
    WbMarkdownTheme theme,
    double maxWidth,
    double fontSize,
  ) {
    const double headH = 40;
    const double startY = 20;
    const double rowGap = 40;
    final Map<String, TextPainter> labelPainters = <String, TextPainter>{};
    final Map<String, double> laneWidth = <String, double>{};
    for (final WbMermaidParticipant p in diagram.participants) {
      final TextPainter painter =
          _text(p.label, fontSize, theme.diagramText, FontWeight.w600);
      labelPainters[p.id] = painter;
      laneWidth[p.id] = math.max(painter.width + 30, 90);
    }
    // 消息文字与序号（序号跳过 note 行）。
    final List<TextPainter> messageTexts = <TextPainter>[];
    final List<TextPainter?> numberPainters = <TextPainter?>[];
    int seq = 0;
    for (final WbMermaidMessage m in diagram.messages) {
      messageTexts.add(_text(m.text, fontSize * 0.92, theme.diagramText, null,
          maxWidth: 200, center: true));
      if (m.note == WbMermaidNotePosition.none) {
        seq++;
        numberPainters.add(
            _text('$seq', fontSize * 0.7, theme.diagramText, FontWeight.w600));
      } else {
        numberPainters.add(null);
      }
    }
    // 相邻泳道消息的箭头必须长于其文字（两端留余量），据此撑大泳道间距。
    final List<String> laneIds = diagram.participants
        .map((WbMermaidParticipant p) => p.id)
        .toList(growable: false);
    double laneGap = 36;
    for (int i = 0; i < diagram.messages.length; i++) {
      final WbMermaidMessage m = diagram.messages[i];
      if (m.note != WbMermaidNotePosition.none) {
        continue;
      }
      final int ai = laneIds.indexOf(m.from);
      final int bi = laneIds.indexOf(m.to);
      if (ai < 0 || bi < 0 || (ai - bi).abs() != 1) {
        continue;
      }
      final double need = messageTexts[i].width +
          24 -
          (laneWidth[m.from]! + laneWidth[m.to]!) / 2;
      laneGap = math.max(laneGap, need);
    }
    // 泳道中心。
    final Map<String, double> laneX = <String, double>{};
    double cursor = 0;
    for (final WbMermaidParticipant p in diagram.participants) {
      laneX[p.id] = cursor + laneWidth[p.id]! / 2;
      cursor += laneWidth[p.id]! + laneGap;
    }
    final double totalW = math.max(0, cursor - laneGap);
    // note 行几何（独立于行基线，布局阶段预计算，行距占位与绘制复用）。
    final List<({double left, double width, double height, TextPainter text})?>
        noteLayouts =
        <({double left, double width, double height, TextPainter text})?>[];
    for (final WbMermaidMessage m in diagram.messages) {
      noteLayouts.add(m.note == WbMermaidNotePosition.none
          ? null
          : _sequenceNoteLayout(m, laneX, laneWidth, theme, fontSize));
    }
    const double bodyTop = startY + headH;
    // 每行相对基线的上下占位：行底 = 序号圆 / note 半高，行顶 = 文字块 /
    // note 半高；行距据此在垂直方向撑开，序号圆不再被下一行文字底色盖住。
    double aboveGap(int i) {
      final ({double left, double width, double height, TextPainter text})?
          note = noteLayouts[i];
      return note != null ? note.height / 2 + 8 : messageTexts[i].height + 8;
    }

    double belowGap(int i) {
      final ({double left, double width, double height, TextPainter text})?
          note = noteLayouts[i];
      if (note != null) {
        return note.height / 2 + 8;
      }
      return 24; // 序号圆底（lineY + 18）+ 余量。
    }

    // 首行留白按首条消息占位（多行文字 / note 不得顶入参与者头）。
    double y = bodyTop + 26;
    if (diagram.messages.isNotEmpty) {
      y = bodyTop + math.max(26, aboveGap(0));
    }
    final List<double> messageY = <double>[];
    for (int i = 0; i < diagram.messages.length; i++) {
      messageY.add(y);
      final double nextAbove =
          i + 1 < diagram.messages.length ? aboveGap(i + 1) : 6;
      y += math.max(rowGap, belowGap(i) + nextAbove);
    }
    final double totalH = y + 8;

    return _scaled(
      Size(totalW, totalH),
      (Canvas canvas) {
        // 生命线。
        for (final WbMermaidParticipant p in diagram.participants) {
          _dashedLine(
            canvas,
            Offset(laneX[p.id]!, bodyTop),
            Offset(laneX[p.id]!, totalH - 4),
            Paint()
              ..color = theme.diagramStroke
              ..strokeWidth = 1,
          );
        }
        // 消息。
        for (int i = 0; i < diagram.messages.length; i++) {
          final WbMermaidMessage message = diagram.messages[i];
          final double lineY = messageY[i];
          if (message.note != WbMermaidNotePosition.none) {
            final ({double left, double width, double height, TextPainter text})?
                note = noteLayouts[i];
            if (note != null) {
              _paintSequenceNote(canvas, note, lineY, theme);
            }
            continue;
          }
          final double? ax = laneX[message.from];
          final double? bx = laneX[message.to];
          if (ax == null || bx == null) {
            continue;
          }
          final Paint paint = Paint()
            ..color = theme.diagramStroke
            ..strokeWidth = 1.3;
          if (message.dashed) {
            _dashedLine(canvas, Offset(ax, lineY), Offset(bx, lineY), paint);
          } else {
            canvas.drawLine(Offset(ax, lineY), Offset(bx, lineY), paint);
          }
          final Offset dir = Offset(bx - ax, 0);
          if (message.arrow == WbMermaidMessageArrow.cross) {
            final Offset c = Offset(bx, lineY);
            canvas.drawLine(c + const Offset(-4, -4), c + const Offset(4, 4), paint..strokeWidth = 1.6);
            canvas.drawLine(c + const Offset(-4, 4), c + const Offset(4, -4), paint);
          } else if (message.arrow == WbMermaidMessageArrow.openCircle) {
            canvas.drawCircle(
              Offset(bx - 4, lineY),
              4,
              paint..strokeWidth = 1.4,
            );
          } else if (message.arrow == WbMermaidMessageArrow.open) {
            _openArrow(canvas, Offset(bx, lineY), dir, theme.diagramStroke);
          } else {
            _arrowHead(canvas, Offset(bx, lineY), dir, theme.diagramStroke);
          }
          // 文本标签居中于线上方（箭头保证不短于文字）。
          final TextPainter text = messageTexts[i];
          double tx = (ax + bx) / 2 - text.width / 2;
          tx = tx.clamp(2, math.max(2, totalW - text.width - 2));
          final double textY = lineY - text.height - 4;
          _roundRect(
            canvas,
            Rect.fromLTWH(tx - 3, textY - 1, text.width + 6, text.height + 2),
            fill: theme.background,
            radius: 3,
          );
          text.paint(canvas, Offset(tx, textY));
          // 消息序号：圆圈内数字（起点泳道生命线上）。
          final TextPainter? number = numberPainters[i];
          if (number != null) {
            _sequenceNumber(canvas, Offset(ax, lineY + 10), number, theme);
          }
        }
        // 参与者头。
        for (final WbMermaidParticipant p in diagram.participants) {
          final double w = laneWidth[p.id]!;
          final Rect rect = Rect.fromLTWH(
            laneX[p.id]! - w / 2,
            startY,
            w,
            headH,
          );
          _roundRect(canvas, rect, fill: theme.diagramFill, stroke: theme.diagramStroke, radius: 6);
          final TextPainter painter = labelPainters[p.id]!;
          painter.paint(
            canvas,
            Offset(rect.center.dx - painter.width / 2, rect.center.dy - painter.height / 2),
          );
        }
      },
      maxWidth,
    );
  }

  /// 时序图 note 几何（left / width / height 与文字，独立于行基线）。
  /// 泳道未能定位时返回 null。
  static ({double left, double width, double height, TextPainter text})?
      _sequenceNoteLayout(
    WbMermaidMessage note,
    Map<String, double> laneX,
    Map<String, double> laneWidth,
    WbMarkdownTheme theme,
    double fontSize,
  ) {
    final double laneW =
        math.max(laneWidth[note.from] ?? 90, laneWidth[note.to] ?? 90);
    double left;
    double width;
    if (note.note == WbMermaidNotePosition.over) {
      final double? a = laneX[note.from];
      final double? b = laneX[note.to];
      if (a == null || b == null) {
        return null;
      }
      left = math.min(a, b) - laneW / 2 - 6;
      width = (math.max(a, b) - math.min(a, b)) + laneW + 12;
    } else {
      final double? a = laneX[note.from];
      if (a == null) {
        return null;
      }
      width = 118;
      left = note.note == WbMermaidNotePosition.leftOf
          ? a - laneW / 2 - width - 8
          : a + laneW / 2 + 8;
      if (left < 0) {
        left = a - laneW / 2 - width - 8;
      }
    }
    final TextPainter text = _text(note.text, fontSize * 0.9,
        theme.diagramText, null,
        maxWidth: math.max(width - 14, 60), center: true);
    return (left: left, width: width, height: text.height + 12, text: text);
  }

  /// 绘制时序图 note（几何由布局阶段预计算，垂直以 lineY 居中）。
  static void _paintSequenceNote(
    Canvas canvas,
    ({double left, double width, double height, TextPainter text}) note,
    double lineY,
    WbMarkdownTheme theme,
  ) {
    final Rect rect = Rect.fromLTWH(
        note.left, lineY - note.height / 2, note.width, note.height);
    _roundRect(canvas, rect,
        fill: theme.searchHighlight, stroke: theme.diagramAccent, radius: 6);
    note.text.paint(
        canvas,
        Offset(rect.center.dx - note.text.width / 2,
            rect.center.dy - note.text.height / 2));
  }

  /// 时序图消息序号（圆圈内数字）。
  static void _sequenceNumber(
    Canvas canvas,
    Offset center,
    TextPainter number,
    WbMarkdownTheme theme,
  ) {
    const double radius = 8;
    canvas.drawCircle(center, radius, Paint()..color = theme.background);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = theme.diagramStroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );
    number.paint(
      canvas,
      Offset(center.dx - number.width / 2, center.dy - number.height / 2),
    );
  }

  // ---- stateDiagram -------------------------------------------------------

  static WbMermaidBox _state(
    WbMermaidStateDiagram diagram,
    WbMarkdownTheme theme,
    double maxWidth,
    double fontSize,
  ) {
    const double gapMain = 40;
    const double gapCross = 30;
    final Map<String, Size> sizes = <String, Size>{};
    final Map<String, TextPainter> labels = <String, TextPainter>{};
    for (final WbMermaidState state in diagram.states) {
      if (state.isPseudo) {
        sizes[state.id] = const Size(22, 22);
        continue;
      }
      final TextPainter painter = _text(state.label, fontSize, theme.diagramText, FontWeight.w500, maxWidth: 160, center: true);
      labels[state.id] = painter;
      sizes[state.id] = Size(math.max(painter.width + 28, 88), math.max(painter.height + 18, 40));
    }
    final Map<String, int> rank = <String, int>{
      for (final WbMermaidState state in diagram.states) state.id: 0,
    };
    final int cap = diagram.states.length;
    for (int iter = 0; iter < cap; iter++) {
      bool changed = false;
      for (final WbMermaidTransition t in diagram.transitions) {
        if (!rank.containsKey(t.from) || !rank.containsKey(t.to)) {
          continue;
        }
        if (rank[t.from]! + 1 > rank[t.to]! && rank[t.from]! + 1 <= cap) {
          rank[t.to] = rank[t.from]! + 1;
          changed = true;
        }
      }
      if (!changed) {
        break;
      }
    }
    final Map<int, List<String>> rows = <int, List<String>>{};
    for (final WbMermaidState state in diagram.states) {
      rows.putIfAbsent(rank[state.id]!, () => <String>[]).add(state.id);
    }
    final List<int> rowKeys = rows.keys.toList()..sort();
    double cursorY = 0;
    double totalW = 0;
    final Map<String, Rect> rects = <String, Rect>{};
    for (final int key in rowKeys) {
      double rowW = 0;
      double rowH = 0;
      for (final String id in rows[key]!) {
        rowW += sizes[id]!.width + gapMain;
        rowH = math.max(rowH, sizes[id]!.height);
      }
      rowW = math.max(0, rowW - gapMain);
      totalW = math.max(totalW, rowW);
      cursorY += rowH / 2;
      double cursorX = -rowW / 2;
      for (final String id in rows[key]!) {
        final Size s = sizes[id]!;
        rects[id] = Rect.fromLTWH(cursorX, cursorY - s.height / 2, s.width, s.height);
        cursorX += s.width + gapMain;
      }
      cursorY += rowH / 2 + gapCross;
    }
    final double totalH = math.max(0, cursorY - gapCross);
    // 归一坐标到左上原点。
    double minX = double.infinity;
    double maxX = -double.infinity;
    for (final Rect r in rects.values) {
      minX = math.min(minX, r.left);
      maxX = math.max(maxX, r.right);
    }
    final double shift = minX.isFinite ? -minX : 0;
    final Map<String, Rect> finalRects = <String, Rect>{
      for (final MapEntry<String, Rect> e in rects.entries)
        e.key: e.value.shift(Offset(shift, 0)),
    };
    final double width = maxX.isFinite ? maxX - minX : 0;

    return _scaled(
      Size(width, totalH),
      (Canvas canvas) {
        for (final WbMermaidTransition t in diagram.transitions) {
          final Rect? from = finalRects[t.from];
          final Rect? to = finalRects[t.to];
          if (from == null || to == null) {
            continue;
          }
          final Offset a = Offset(from.center.dx, from.bottom);
          final Offset b = Offset(to.center.dx, to.top);
          final Paint paint = Paint()
            ..color = theme.diagramStroke
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3;
          final double midY = (a.dy + b.dy) / 2;
          final Path path = Path()
            ..moveTo(a.dx, a.dy)
            ..lineTo(a.dx, midY)
            ..lineTo(b.dx, midY)
            ..lineTo(b.dx, b.dy);
          canvas.drawPath(path, paint);
          _arrowHead(canvas, b, b - Offset(b.dx, midY), theme.diagramStroke);
          if (t.label.isNotEmpty) {
            _edgeLabel(canvas, t.label, Offset(a.dx, midY), Offset(b.dx, midY), theme, fontSize);
          }
        }
        for (final WbMermaidState state in diagram.states) {
          final Rect? rect = finalRects[state.id];
          if (rect == null) {
            continue;
          }
          if (state.isPseudo) {
            final bool isStart = _isStartPseudo(diagram, state.id);
            if (isStart) {
              canvas.drawCircle(rect.center, 8, Paint()..color = theme.diagramStroke);
            } else {
              canvas.drawCircle(
                rect.center,
                8,
                Paint()
                  ..color = theme.diagramStroke
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1.4,
              );
              canvas.drawCircle(rect.center, 5, Paint()..color = theme.diagramStroke);
            }
            continue;
          }
          _roundRect(canvas, rect, fill: theme.diagramFill, stroke: theme.diagramStroke, radius: 8);
          final TextPainter painter = labels[state.id]!;
          painter.paint(canvas, Offset(rect.center.dx - painter.width / 2, rect.center.dy - painter.height / 2));
        }
      },
      maxWidth,
    );
  }

  static bool _isStartPseudo(WbMermaidStateDiagram diagram, String id) {
    for (final WbMermaidTransition t in diagram.transitions) {
      if (t.from == id) {
        return true;
      }
    }
    return false;
  }

  // ---- erDiagram ----------------------------------------------------------

  static WbMermaidBox _er(
    WbMermaidErDiagram diagram,
    WbMarkdownTheme theme,
    double maxWidth,
    double fontSize,
  ) {
    const double titleH = 28;
    const double attrH = 18;
    const Map<String, String> cardLabels = <String, String>{
      '||': '1', 'o|': '0..1', '|o': '0..1', '}|': '1..*',
      '}o': '0..*', '{|': '1..*', '{o': '0..*', '}{': '1..*',
      'o{': '0..*', '|{': '1..*',
    };
    final Map<String, Rect> rects = <String, Rect>{};
    final Map<String, TextPainter> titlePainters = <String, TextPainter>{};
    final Map<String, List<TextPainter>> attrPainters =
        <String, List<TextPainter>>{};
    final List<({String name, double w, double h})> boxes =
        <({String name, double w, double h})>[];
    for (final WbMermaidEntity entity in diagram.entities) {
      final TextPainter title =
          _text(entity.name, fontSize, theme.diagramText, FontWeight.w600);
      titlePainters[entity.name] = title;
      double w = title.width + 28;
      final List<TextPainter> attrs = <TextPainter>[];
      for (final String attr in entity.attributes) {
        final TextPainter painter =
            _text(attr, fontSize * 0.88, theme.diagramText, null, maxWidth: 220);
        attrs.add(painter);
        w = math.max(w, painter.width + 24);
      }
      attrPainters[entity.name] = attrs;
      w = w.clamp(120, 260);
      final double h = titleH + math.max(attrs.length, 1) * attrH + 8;
      boxes.add((name: entity.name, w: w, h: h));
    }
    const double gapX = 30;
    const double gapY = 36;
    double cursorX = 0;
    double cursorY = 0;
    double rowH = 0;
    double totalW = 0;
    for (final ({String name, double w, double h}) box in boxes) {
      if (cursorX > 0 && cursorX + box.w > maxWidth) {
        cursorX = 0;
        cursorY += rowH + gapY;
        rowH = 0;
      }
      rects[box.name] = Rect.fromLTWH(cursorX, cursorY, box.w, box.h);
      cursorX += box.w + gapX;
      rowH = math.max(rowH, box.h);
      totalW = math.max(totalW, cursorX - gapX);
    }
    final double totalH = cursorY + rowH;

    return _scaled(
      Size(totalW, totalH),
      (Canvas canvas) {
        for (final WbMermaidErRelation relation in diagram.relations) {
          final Rect? from = rects[relation.left];
          final Rect? to = rects[relation.right];
          if (from == null || to == null) {
            continue;
          }
          final Offset a = _rectEdgePoint(from, to.center);
          final Offset b = _rectEdgePoint(to, from.center);
          final Paint paint = Paint()
            ..color = theme.diagramStroke
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3;
          if (relation.dashed) {
            _dashedLine(canvas, a, b, paint);
          } else {
            canvas.drawLine(a, b, paint);
          }
          final Offset dir = b - a;
          final double len = dir.distance;
          if (len > 1) {
            final Offset unit = dir / len;
            final TextPainter leftCard = _text(
              cardLabels[relation.leftCard] ?? relation.leftCard,
              fontSize * 0.78,
              theme.diagramAccent,
              FontWeight.w600,
            );
            final TextPainter rightCard = _text(
              cardLabels[relation.rightCard] ?? relation.rightCard,
              fontSize * 0.78,
              theme.diagramAccent,
              FontWeight.w600,
            );
            leftCard.paint(canvas, a + unit * 5 - Offset(leftCard.width / 2, leftCard.height + 2));
            rightCard.paint(canvas, b - unit * 5 - Offset(rightCard.width / 2, rightCard.height + 2));
          }
          if (relation.label.isNotEmpty) {
            _edgeLabel(canvas, relation.label, a, b, theme, fontSize);
          }
        }
        for (final WbMermaidEntity entity in diagram.entities) {
          final Rect? rect = rects[entity.name];
          if (rect == null) {
            continue;
          }
          _roundRect(canvas, rect, fill: theme.diagramFill, stroke: theme.diagramStroke, radius: 4);
          canvas.drawLine(
            Offset(rect.left, rect.top + titleH),
            Offset(rect.right, rect.top + titleH),
            Paint()
              ..color = theme.diagramStroke
              ..strokeWidth = 1,
          );
          final TextPainter title = titlePainters[entity.name]!;
          title.paint(canvas, Offset(rect.center.dx - title.width / 2, rect.top + (titleH - title.height) / 2));
          final List<TextPainter> attrs = attrPainters[entity.name]!;
          final double startY = rect.top + titleH + 4;
          for (int i = 0; i < attrs.length; i++) {
            attrs[i].paint(canvas, Offset(rect.left + 10, startY + i * attrH));
          }
        }
      },
      maxWidth,
    );
  }

  // ---- 绘制辅助 -----------------------------------------------------------

  /// 矩形边界上朝向 [target] 的交点（用于连线端点）。
  static Offset _rectEdgePoint(Rect rect, Offset target) {
    final Offset dir = target - rect.center;
    if (dir.dx == 0 && dir.dy == 0) {
      return rect.center;
    }
    final double scaleX = dir.dx == 0 ? double.infinity : (rect.width / 2) / dir.dx.abs();
    final double scaleY = dir.dy == 0 ? double.infinity : (rect.height / 2) / dir.dy.abs();
    final double scale = math.min(scaleX, scaleY);
    return rect.center + dir * scale;
  }

  static TextPainter _text(
    String text,
    double fontSize,
    Color color,
    FontWeight? weight, {
    double? maxWidth,
    bool center = false,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: weight ?? FontWeight.w400,
          height: 1.3,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: center ? TextAlign.center : TextAlign.left,
    )..layout(maxWidth: maxWidth ?? double.infinity);
    return painter;
  }

  static void _roundRect(
    Canvas canvas,
    Rect rect, {
    Color? fill,
    Color? stroke,
    double radius = 6,
    double strokeWidth = 1.3,
  }) {
    final RRect rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    if (fill != null) {
      canvas.drawRRect(rrect, Paint()..color = fill);
    }
    if (stroke != null) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = stroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth,
      );
    }
  }

  static void _dashedLine(
    Canvas canvas,
    Offset a,
    Offset b,
    Paint paint, {
    double dash = 5,
    double gap = 3,
  }) {
    final Offset delta = b - a;
    final double len = delta.distance;
    if (len <= 0.01) {
      return;
    }
    final Offset unit = delta / len;
    double t = 0;
    while (t < len) {
      final double end = math.min(t + dash, len);
      canvas.drawLine(a + unit * t, a + unit * end, paint);
      t = end + gap;
    }
  }

  /// 沿路径画虚线（按 PathMetric 均匀取段）。
  static void _dashedPath(
    Canvas canvas,
    Path path,
    Paint paint, {
    double dash = 5,
    double gap = 3,
  }) {
    for (final ui.PathMetric metric in path.computeMetrics()) {
      double t = 0;
      while (t < metric.length) {
        final double end = math.min(t + dash, metric.length);
        canvas.drawPath(metric.extractPath(t, end), paint);
        t = end + gap;
      }
    }
  }

  /// 三次贝塞尔曲线在参数 [t] 处的点。
  static Offset _cubicAt(
    Offset p0,
    Offset p1,
    Offset p2,
    Offset p3,
    double t,
  ) {
    final double u = 1 - t;
    return p0 * (u * u * u) +
        p1 * (3 * u * u * t) +
        p2 * (3 * u * t * t) +
        p3 * (t * t * t);
  }

  /// 实心箭头（[tip] 处，[dir] 指向节点外侧→内侧方向的反向）。
  static void _arrowHead(
    Canvas canvas,
    Offset tip,
    Offset dir,
    Color color, {
    double size = 8,
  }) {
    final double len = dir.distance;
    if (len < 0.01) {
      return;
    }
    final Offset unit = dir / len;
    final Offset back = -unit;
    final Offset normal = Offset(-unit.dy, unit.dx);
    final Path path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx + back.dx * size + normal.dx * size * 0.45,
          tip.dy + back.dy * size + normal.dy * size * 0.45)
      ..lineTo(tip.dx + back.dx * size - normal.dx * size * 0.45,
          tip.dy + back.dy * size - normal.dy * size * 0.45)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  /// 开放箭头（两段线）。
  static void _openArrow(Canvas canvas, Offset tip, Offset dir, Color color) {
    final double len = dir.distance;
    if (len < 0.01) {
      return;
    }
    final Offset unit = dir / len;
    final Offset back = -unit;
    final Offset normal = Offset(-unit.dy, unit.dx);
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawLine(tip, tip + back * 9 + normal * 4, paint);
    canvas.drawLine(tip, tip + back * 9 - normal * 4, paint);
  }

  /// 空心三角（继承标记）。
  static void _hollowTriangle(
    Canvas canvas,
    Offset tip,
    Offset dir,
    Color color, {
    Color fill = const Color(0xFFFFFFFF),
  }) {
    final double len = dir.distance;
    if (len < 0.01) {
      return;
    }
    final Offset unit = dir / len;
    final Offset back = -unit;
    final Offset normal = Offset(-unit.dy, unit.dx);
    final Path path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx + back.dx * 11 + normal.dx * 6,
          tip.dy + back.dy * 11 + normal.dy * 6)
      ..lineTo(tip.dx + back.dx * 11 - normal.dx * 6,
          tip.dy + back.dy * 11 - normal.dy * 6)
      ..close();
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  /// 菱形标记（组合/聚合）。
  static void _diamondMarker(
    Canvas canvas,
    Offset tip,
    Offset dir,
    Color color, {
    required bool filled,
    Color hollowFill = const Color(0xFFFFFFFF),
  }) {
    final double len = dir.distance;
    if (len < 0.01) {
      return;
    }
    final Offset unit = dir / len;
    final Offset back = -unit;
    final Offset normal = Offset(-unit.dy, unit.dx);
    final Path path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx + back.dx * 7 + normal.dx * 4,
          tip.dy + back.dy * 7 + normal.dy * 4)
      ..lineTo(tip.dx + back.dx * 14, tip.dy + back.dy * 14)
      ..lineTo(tip.dx + back.dx * 7 - normal.dx * 4,
          tip.dy + back.dy * 7 - normal.dy * 4)
      ..close();
    canvas.drawPath(
      path,
      Paint()..color = filled ? color : hollowFill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  /// 连线中点标签（带底色）。
  static void _edgeLabel(
    Canvas canvas,
    String text,
    Offset a,
    Offset b,
    WbMarkdownTheme theme,
    double fontSize,
  ) {
    final TextPainter painter =
        _text(text, fontSize * 0.86, theme.diagramText, null);
    final Offset center = (a + b) / 2;
    final Rect rect = Rect.fromCenter(
      center: center,
      width: painter.width + 8,
      height: painter.height + 2,
    );
    _roundRect(canvas, rect, fill: theme.background, radius: 3);
    painter.paint(
      canvas,
      Offset(rect.center.dx - painter.width / 2, rect.center.dy - painter.height / 2),
    );
  }
}
