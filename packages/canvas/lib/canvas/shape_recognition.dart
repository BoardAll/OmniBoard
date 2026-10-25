/// 单笔图形识别与最小二乘拟合（纯几何模块）。
///
/// 输入画笔抬笔后的世界坐标点集，把「一笔画」笔迹拟合为最接近的规整图形：
/// 直线 / 折线 / 三角形 / 矩形（含正方形）/ 菱形 / 平行四边形 / 圆 /
/// 椭圆 / 正多边形（5~8 边）/ 五角星。各分支先用形状专属门槛（如缺口、
/// 拉长度、半径均匀度）筛选候选，再统一以「原始点集到候选折线的平均点到
/// 线段距离 / 包围盒对角线 D」评估残差，取残差最小且不超过
/// [WbShapeRecognizer.maxRelativeResidual] 者；无可接受结果返回 null
/// （调用方保持原笔迹）。
///
/// 未闭合容差：首尾缺口 ≤ [WbShapeRecognizer.closedGapRatio]·D 视为未画满
/// 的闭合图形（角点族自动补齐闭合）；圆 / 椭圆另以绕心角覆盖（≥ 260°）
/// 把关。闭合后画过头（后半段折返至起笔附近）时超出尾段不参与拟合。
///
/// 阈值全部以包围盒对角线归一化（与笔迹大小无关），常量提为静态成员
/// 便于测试固定。模块只依赖 dart:math / dart:ui，供
/// `WbCanvasController._finishStroke` 与测试直接使用。
library;

import 'dart:math' as math;
import 'dart:ui';

/// 拟合图形种类。
enum WbFittedShapeKind {
  /// 直线段。
  line,

  /// 开放折线（多段线）。
  polyline,

  /// 一笔箭头（杆为直线 + 端部箭翼；单翼画法的另一翼由识别镜像补全）。
  arrow,

  /// 三角形。
  triangle,

  /// 矩形（含正方形；输出保证邻边垂直）。
  rectangle,

  /// 平行四边形（含菱形等两组对边平行的四边形）。
  parallelogram,

  /// 梯形（恰有一组对边平行）。
  trapezoid,

  /// 圆。
  circle,

  /// 椭圆。
  ellipse,

  /// 正多边形（5~8 边）。
  regularPolygon,

  /// 五角星（10 角轮廓笔画或 5 角一笔交叉笔画）。
  star,
}

/// 单笔拟合结果。
class WbShapeFit {
  const WbShapeFit({
    required this.kind,
    required this.points,
    required this.residual,
  });

  /// 图形种类。
  final WbFittedShapeKind kind;

  /// 拟合后的规整折线（世界坐标；闭合图形末点与首点重合）。
  final List<Offset> points;

  /// 平均几何偏差 / 包围盒对角线 D（越小越贴合）。
  final double residual;
}

/// 候选图形（识别内部中间表示）。
class _Candidate {
  const _Candidate(this.kind, this.points);

  final WbFittedShapeKind kind;
  final List<Offset> points;
}

/// 端勾剪裁结果：剪后点集与被剪短勾点集（按原笔序从两端截下，供剪口
/// 求交补齐）。
class _OpenTrim {
  const _OpenTrim(this.work, this.headDropped, this.tailDropped);

  final List<Offset> work;
  final List<Offset> headDropped;
  final List<Offset> tailDropped;
}

/// 角点族拟合结果：候选集 + 「任意四边形证据」标志（见
/// [WbShapeRecognizer._fitClosedCornerShapes]）。
class _CornerFit {
  const _CornerFit(this.candidates, {this.quadLike = false});

  final List<_Candidate> candidates;
  final bool quadLike;
}

/// 拟合直线（锚点 + 单位方向）。
class _Line {
  const _Line(this.point, this.dir);

  final Offset point;
  final Offset dir;
}

/// 单笔图形识别器。
abstract final class WbShapeRecognizer {
  // ---- 公开阈值（测试固定） ------------------------------------------------

  /// 包围盒对角线下限（世界坐标；过小不识别）。
  static const double minDiagonal = 16;

  /// 平均几何偏差 / D 上限（候选统一残差门槛）。
  static const double maxRelativeResidual = 0.08;

  /// 首尾缺口距离 / D 上限：不超过视为未画满的闭合图形（自动补齐闭合）。
  static const double closedGapRatio = 0.32;

  /// 画过头尾段弧长 / 全笔迹弧长上限（超过视为长回环，不截断；
  /// 上限内仍须通过重描检查，套索回尾会被拒）。
  static const double _overshootMaxTailFraction = 0.60;

  /// 尾段弧长 / 全笔迹弧长不超过该值时视为「收笔小甩」直接截断。
  static const double _overshootShortTailFraction = 0.10;

  /// 尾段重描前段的贴合容差 / D（超过视为独立回尾不截断）。
  static const double _overshootRetraceRatio = 0.05;

  /// 圆 / 椭圆输出采样点数（另加一个闭环重复点）。
  static const int curveSamples = 48;

  // ---- 直线门槛 ------------------------------------------------------------

  /// 平均垂直距绝对下限（世界坐标）。
  static const double _lineMaxMeanPerpAbs = 1.0;

  /// 平均垂直距 / D 上限。
  static const double _lineMaxMeanPerpRatio = 0.015;

  /// 主方向拉长度（纵向跨距 / 横向跨距）下限。
  static const double _lineMinElongation = 4.0;

  // ---- 圆 / 椭圆门槛 -------------------------------------------------------

  /// 平均半径偏差 / 半径上限。
  static const double _circleMaxRadiusDev = 0.10;

  /// 绕心角覆盖下限（弧度；≈260°，未画满的圆 / 椭圆仍吸附，弧线排除）。
  static const double _curveMinCoverage = 260 * math.pi / 180;

  /// 半轴比下限（更扁视为非椭圆）。
  static const double _ellipseMinRatio = 0.25;

  /// 半轴比上限（达到即归一为圆，交由圆分支）。
  static const double _ellipseMaxRatio = 0.88;

  /// 椭圆近似欧氏距（|f| / |∇f|）均值 / D 上限。
  static const double _ellipseMaxApproxDevRatio = 0.06;

  /// 「任意四边形证据」成立时曲线族（圆 / 椭圆）候选的残差上限：恰好
  /// 提取出 4 个真实角点但四类判类不成立，说明笔迹有明确棱角——曲线
  /// 须以远高于常规的贴合度才能胜出（实测棱角四边形椭圆残差 0.04+，
  /// 真曲线 ≤0.005），否则任意四边形会被椭圆候选吸附。
  static const double _quadLikeCurveMaxResidual = 0.03;

  // ---- 角点族门槛 ----------------------------------------------------------

  /// DP 自适应公差 / D。
  static const double _cornerToleranceRatio = 0.035;

  /// DP 自适应公差绝对下限（世界坐标）。
  static const double _cornerToleranceMin = 1.2;

  /// 闭合伪角（近直）剔除阈值：夹角 ≥ 该值视为落在边上的伪角。
  static const double _closedFlatCorner = 150 * math.pi / 180;

  /// 开放伪角剔除阈值：更严，避免平滑圆弧被误折线化。
  static const double _openFlatCorner = 130 * math.pi / 180;

  /// 断口补角方向窗口的相邻步折转累计上限（≈50°；进入下一条边即停）。
  static const double _bridgeMaxTurn = 50 * math.pi / 180;

  /// 最短边 / D（更短的边合并）。
  static const double _minEdgeRatio = 0.06;

  /// 最短边绝对下限（世界坐标）。
  static const double _minEdgeAbs = 1.0;

  /// 开放折线最多顶点数（含首尾端点；≤6 段）。
  static const int _maxOpenCorners = 7;

  /// 开放笔迹首 / 尾短勾剪裁阈（勾长 / 总长上限，均按折点弦距度量、
  /// 与采样密度无关）：不超过视为收笔手抖的小勾，剪去后吸附为直线；
  /// 明显大勾（超过阈）不剪，交由箭头候选 [_fitOpenArrow] 吸附为箭头
  /// （单翼自动补全另一翼；其翼长阈 [_arrowSingleBarbMinRatio] 略低于
  /// 本阈，二者之间由箭头候选优先接管）。
  static const double _openHookMaxArcRatio = 0.15;

  /// 首 / 尾短段被判为「勾」的最小转折余弦上限：与相邻段方向的 |cos|
  /// 不超过该值（转折 ≥45°）才剪——圆弧的弦化分段转折稳定 ≈30°
  /// （|cos|≈0.87），避免弧线首 / 尾段被误剪导致弧被吸附为折线。
  static const double _openHookMaxTurnCos = 0.7071;

  /// 开放笔迹「箭翼」判定：端部折段长度 / 杆长上限——超过视为普通
  /// 拐角的长边（如 L 形、Z 形折线），不吸附为箭头。
  static const double _arrowBarbMaxShaftRatio = 0.4;

  /// 箭翼回指分量（翼向量在「杆方向反向」上的投影）/ 翼长下限：低于
  /// 该值（转折 ≲96°、折段朝前摆）不算翼；直角拐角（≈0）通过。
  /// 比例之门外另取绝对底限 [_arrowBarbBackAbsMin]。
  static const double _arrowBarbBackRatioMin = -0.1;

  /// 箭翼回指分量门限的绝对容差（世界坐标）：短翼按 10% 比例只有 1px
  /// 级余量，不足采样噪声（±1px）量级，小箭头的翼会被噪声误拒；
  /// 1.5px 前倾容差下语义仍由横向偏离门（25% 翼长）把关。
  static const double _arrowBarbBackAbsMin = 1.5;

  /// 箭翼横向偏离 / 翼长下限（几乎沿杆回描的尖刺不算翼）。
  static const double _arrowBarbMinOutRatio = 0.25;

  /// 双翼（完整箭头头）画法下每翼最小长度 / 杆长：回描式箭头的
  /// 「总弦距」含折返双计，不能沿用单翼的小勾阈；低于该值（另加
  /// [_arrowBarbAbsMin] 绝对下限）视为收笔毛刺，仍走小勾剪直。
  static const double _arrowDoubleBarbMinRatio = 0.08;

  /// 单翼（一侧折勾）画法下箭翼长度 / 总弦距下限：略低于小勾剪直阈
  /// [_openHookMaxArcRatio]，使「翼略短但仍明显」的单侧箭头优先吸附
  /// 为箭头（自动补全另一翼），更小的收笔勾仍落入剪直。
  static const double _arrowSingleBarbMinRatio = 0.13;

  /// 箭翼绝对长度下限（世界坐标）：杆短则翼短，小箭头（杆 ≲ 60px）
  /// 的翼常在 3~6px，过高的硬下限会把整类小箭头拒之门外；2px 级
  /// 以下的回摆视为收笔毛刺，不算翼。
  static const double _arrowBarbAbsMin = 2.0;

  /// 开放折线顶点回漂 / DP 公差上限（拟合交点远离角点即非真实拐角）。
  static const double _openSnapDriftTolerance = 1.8;

  /// 开放折线顶点回漂 / D 上限。
  static const double _openSnapDriftRatio = 0.05;

  // ---- 四边形判类门槛 ------------------------------------------------------

  /// 平行判定正弦容差（≈ sin 14°，手绘放宽）。
  static const double _quadParallelSin = 0.2419;

  /// 矩形邻边垂直判定正弦容差（≈ sin 10°；不宜放宽，过宽会把近菱形
  /// 四边近等的夹 101° 类图形吞并成矩形）。
  static const double _quadPerpSin = 0.1736;

  /// 矩形单角垂直宽限正弦容差（≈ sin 14°，同 [_quadParallelSin]）：
  /// 允许至多一个角宽限到该值（吸附顶点偶发单角偏移，如大圆角矩形
  /// 的短边拟合）；两个角同时超差（斜腰平行四边形特征）即拒。
  static const double _quadPerpMaxSin = 0.2419;

  /// 平行四边形严格平行差容差（≈ sin 18°，手绘放宽）。
  static const double _parallelogramParallelSin = 0.3090;

  /// 平行四边形软性平行差容差（≈ sin 26°）：「像就吸」——两组对边都
  /// 落在此容差内、且至少一组在严格容差内，即视为画歪的平行四边形并
  /// 自动校平；明显不像（两组都超）仍不识别。
  static const double _parallelogramLooseSin = 0.4384;

  /// 多伪角四边形提取：未入选角点到所在边拟合直线的距离 / D 上限
  /// （伪角须「贴边」，过大即视为真实顶点，拒绝提取）。
  static const double _quadSubsetDevRatio = 0.08;

  // ---- 正多边形 / 星形门槛 -------------------------------------------------

  /// 参观序相邻角步长偏差上限（弧度；12°）。
  static const double _polygonStepDev = 12 * math.pi / 180;

  /// 顶点半径偏差 / 平均半径上限。
  static const double _polygonRadiusDev = 0.15;

  /// 星形外 / 内半径比下限。
  static const double _starMinRadiusRatio = 1.4;

  // ---- 入口 ----------------------------------------------------------------

  /// 识别单笔图形；不可识别返回 null。
  static WbShapeFit? recognize(List<Offset> points) {
    final List<Offset> pts = _cleanPoints(points);
    if (pts.length < 3) {
      return null;
    }
    final double d = _diagonal(pts);
    if (d < minDiagonal || !d.isFinite) {
      return null;
    }

    // 缺口 / 画过头分析：后半段折返至起笔附近（明显近于终点缺口）且
    // 超出尾段不过长时，截去尾段只拟合主环——超出区域不参与识别。
    // 尾段须重描前段（覆盖式回画）或足够短（收笔小甩），否则视为
    // 独立回尾（套索 / 螺旋）不截断。
    List<Offset> shapePts = pts;
    final double gap = (pts.last - pts.first).distance;
    int closure = -1;
    double closureDist = gap;
    if (pts.length > 12) {
      // 到起笔距离序列在中后段的「首个谷底（≤ 缺口容差）」即笔迹首次
      // 回到起笔附近的位置（两圈回描的第一闭合点、套索的回环点）；
      // 尾部单向逼近起点（未闭合缺口停在边上）不构成谷底，不截尾。
      final int from = pts.length ~/ 2;
      final double tol = closedGapRatio * d;
      double prev = double.infinity;
      for (int i = from; i < pts.length; i++) {
        final double dist = (pts[i] - pts.first).distance;
        if (prev <= tol && prev <= dist) {
          closure = i - 1;
          closureDist = prev;
          break;
        }
        prev = dist;
      }
      if (closure > 0 &&
          closure < pts.length - 3 &&
          closureDist <= closedGapRatio * d) {
        double tail = 0;
        double total = 0;
        for (int i = 0; i + 1 < pts.length; i++) {
          final double seg = (pts[i + 1] - pts[i]).distance;
          total += seg;
          if (i >= closure) {
            tail += seg;
          }
        }
        if (total > 1e-9 && tail <= _overshootMaxTailFraction * total) {
          bool keep = tail <= _overshootShortTailFraction * total;
          if (!keep) {
            // 尾段须整体贴近前段（覆盖式重描）才算画过头。
            final double retraceTol =
                math.max(6.0, _overshootRetraceRatio * d);
            keep = true;
            for (int i = closure + 1; i < pts.length && keep; i++) {
              double nearest = double.infinity;
              for (int j = 0; j <= closure; j++) {
                final double dist = (pts[i] - pts[j]).distance;
                if (dist < nearest) {
                  nearest = dist;
                }
              }
              if (nearest > retraceTol) {
                keep = false;
              }
            }
          }
          if (keep) {
            shapePts = pts.sublist(0, closure + 1);
          }
        }
      }
    }
    final bool trimmed = !identical(shapePts, pts);
    final double shapeD = trimmed ? _diagonal(shapePts) : d;
    final bool closedShape =
        (shapePts.last - shapePts.first).distance <=
            closedGapRatio * shapeD;

    // 所有候选统一在截尾后的主环点集上拟合与评分——超出区域不参与。
    final List<_Candidate> candidates = <_Candidate>[];
    final _Candidate? line = _fitStraightLine(shapePts, shapeD);
    if (line != null) {
      candidates.add(line);
    }
    // 曲线族：闭合与否均可（缺口由绕心角覆盖把关，未画满的圆 / 椭圆
    // 吸附为完整曲线）。
    final _Candidate? circle = _fitCircle(shapePts, shapeD);
    if (circle != null) {
      candidates.add(circle);
    }
    final _Candidate? ellipse = _fitEllipse(shapePts, shapeD);
    if (ellipse != null) {
      candidates.add(ellipse);
    }
    if (!closedShape) {
      // 开放笔迹：先试箭头（杆 + 端部折翼；单翼自动补全另一翼），
      // 不成箭头再退回折线（多段线）。
      final _Candidate? arrow = _fitOpenArrow(shapePts, shapeD);
      final _Candidate? polyline =
          arrow == null ? _fitOpenPolyline(shapePts, shapeD) : null;
      if (arrow != null) {
        candidates.add(arrow);
      } else if (polyline != null) {
        candidates.add(polyline);
      }
    }

    // 角点族（三角形 / 四边形 / 正多边形 / 星形）：按主环点集评分。
    // 「4 个真实角点但四类判类不成」即任意四边形证据——此时曲线族
    // 须以远严于常规的残差门槛参与竞争（见 [_quadLikeCurveMaxResidual]）。
    bool quadLike = false;
    if (closedShape) {
      final _CornerFit corner = _fitClosedCornerShapes(shapePts, shapeD);
      candidates.addAll(corner.candidates);
      quadLike = corner.quadLike;
    }

    WbShapeFit? best;
    void consider(_Candidate candidate, List<Offset> scorePts, double scoreD) {
      final double residual =
          _polylineResidual(scorePts, candidate.points) / scoreD;
      final bool curve = candidate.kind == WbFittedShapeKind.circle ||
          candidate.kind == WbFittedShapeKind.ellipse;
      final double limit =
          quadLike && curve ? _quadLikeCurveMaxResidual : maxRelativeResidual;
      if (residual > limit) {
        return;
      }
      final WbShapeFit? current = best;
      if (current == null || residual < current.residual) {
        best = WbShapeFit(
          kind: candidate.kind,
          points: candidate.points,
          residual: residual,
        );
      }
    }

    for (final _Candidate candidate in candidates) {
      consider(candidate, shapePts, shapeD);
    }
    return best;
  }

  // ---- 基础几何 ------------------------------------------------------------

  /// 清洗相邻重复点（距离 ≤ 0.01 世界坐标）。
  static List<Offset> _cleanPoints(List<Offset> points) {
    final List<Offset> out = <Offset>[];
    for (final Offset p in points) {
      if (out.isEmpty || (p - out.last).distance > 0.01) {
        out.add(p);
      }
    }
    return out;
  }

  /// 点集包围盒对角线长度。
  static double _diagonal(List<Offset> pts) {
    double minX = pts.first.dx;
    double maxX = minX;
    double minY = pts.first.dy;
    double maxY = minY;
    for (final Offset p in pts) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final double w = maxX - minX;
    final double h = maxY - minY;
    return math.sqrt(w * w + h * h);
  }

  static Offset _centroid(List<Offset> pts) {
    double x = 0;
    double y = 0;
    for (final Offset p in pts) {
      x += p.dx;
      y += p.dy;
    }
    return Offset(x / pts.length, y / pts.length);
  }

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final Offset ab = b - a;
    final double lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lengthSquared <= 1e-12) {
      return (p - a).distance;
    }
    final double raw =
        ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lengthSquared;
    final double t = raw.clamp(0.0, 1.0).toDouble();
    return (p - Offset(a.dx + ab.dx * t, a.dy + ab.dy * t)).distance;
  }

  /// 点集到折线的平均点到线段距离。
  static double _polylineResidual(List<Offset> pts, List<Offset> poly) {
    if (poly.length < 2) {
      return double.infinity;
    }
    double sum = 0;
    for (final Offset p in pts) {
      double nearest = double.infinity;
      for (int i = 0; i + 1 < poly.length; i++) {
        final double dist = _distanceToSegment(p, poly[i], poly[i + 1]);
        if (dist < nearest) {
          nearest = dist;
        }
      }
      sum += nearest;
    }
    return sum / pts.length;
  }

  /// 角度归一化到 (−π, π]。
  static double _normalizeAngle(double angle) {
    final double t = angle % (2 * math.pi);
    return t > math.pi ? t - 2 * math.pi : t;
  }

  /// b 处的折转量：直线为 0，直角为 π/2。
  static double _turning(Offset a, Offset b, Offset c) {
    final Offset v1 = a - b;
    final Offset v2 = c - b;
    final double l1 = v1.distance;
    final double l2 = v2.distance;
    if (l1 <= 1e-9 || l2 <= 1e-9) {
      return 0;
    }
    final double cos = ((v1.dx * v2.dx + v1.dy * v2.dy) / (l1 * l2))
        .clamp(-1.0, 1.0)
        .toDouble();
    return math.pi - math.acos(cos);
  }

  /// 顶点 [cur]（索引序）处的夹角：π = 直线（近直）。
  static double _angleAt(List<Offset> pts, int prev, int cur, int next) {
    final Offset v1 = pts[prev] - pts[cur];
    final Offset v2 = pts[next] - pts[cur];
    final double l1 = v1.distance;
    final double l2 = v2.distance;
    if (l1 <= 1e-9 || l2 <= 1e-9) {
      return math.pi;
    }
    final double cos = ((v1.dx * v2.dx + v1.dy * v2.dy) / (l1 * l2))
        .clamp(-1.0, 1.0)
        .toDouble();
    return math.acos(cos);
  }

  /// 高斯消元（部分主元）；系数矩阵奇异返回 null。
  static List<double>? _solveLinear(List<List<double>> a, List<double> b) {
    final int n = b.length;
    final List<List<double>> m = <List<double>>[];
    for (int i = 0; i < n; i++) {
      final List<double> row = List<double>.of(a[i]);
      row.add(b[i]);
      m.add(row);
    }
    for (int col = 0; col < n; col++) {
      int pivot = col;
      for (int r = col + 1; r < n; r++) {
        if (m[r][col].abs() > m[pivot][col].abs()) {
          pivot = r;
        }
      }
      if (m[pivot][col].abs() < 1e-12) {
        return null;
      }
      if (pivot != col) {
        final List<double> tmp = m[pivot];
        m[pivot] = m[col];
        m[col] = tmp;
      }
      final double diag = m[col][col];
      for (int c = col; c <= n; c++) {
        m[col][c] /= diag;
      }
      for (int r = 0; r < n; r++) {
        if (r == col) {
          continue;
        }
        final double factor = m[r][col];
        if (factor == 0) {
          continue;
        }
        for (int c = col; c <= n; c++) {
          m[r][c] -= factor * m[col][c];
        }
      }
    }
    return <double>[for (int i = 0; i < n; i++) m[i][n]];
  }

  // ---- 直线（total-LS / PCA 主方向） ---------------------------------------

  static _Candidate? _fitStraightLine(
    List<Offset> pts,
    double d, {
    bool requireStraight = true,
  }) {
    final Offset c = _centroid(pts);
    double sxx = 0;
    double sxy = 0;
    double syy = 0;
    for (final Offset p in pts) {
      final double dx = p.dx - c.dx;
      final double dy = p.dy - c.dy;
      sxx += dx * dx;
      sxy += dx * dy;
      syy += dy * dy;
    }
    if (sxx + syy <= 1e-9) {
      return null;
    }
    final double theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
    final Offset axis = Offset(math.cos(theta), math.sin(theta));
    final Offset normal = Offset(-axis.dy, axis.dx);
    double minT = double.infinity;
    double maxT = -double.infinity;
    double minS = double.infinity;
    double maxS = -double.infinity;
    double sumAbsS = 0;
    for (final Offset p in pts) {
      final double dx = p.dx - c.dx;
      final double dy = p.dy - c.dy;
      final double t = dx * axis.dx + dy * axis.dy;
      final double s = dx * normal.dx + dy * normal.dy;
      minT = math.min(minT, t);
      maxT = math.max(maxT, t);
      minS = math.min(minS, s);
      maxS = math.max(maxS, s);
      sumAbsS += s.abs();
    }
    final double spanAlong = maxT - minT;
    final double spanPerp = maxS - minS;
    final double elongation =
        spanPerp <= 1e-6 ? double.infinity : spanAlong / spanPerp;
    if (requireStraight && elongation < _lineMinElongation) {
      return null;
    }
    final double meanPerp = sumAbsS / pts.length;
    if (requireStraight &&
        meanPerp > math.max(_lineMaxMeanPerpAbs, _lineMaxMeanPerpRatio * d)) {
      return null;
    }
    // 保留用户起笔方向：首点投影接近哪一端，哪一端在前。
    final double firstT =
        (pts.first.dx - c.dx) * axis.dx + (pts.first.dy - c.dy) * axis.dy;
    final bool reversed = (firstT - maxT).abs() < (firstT - minT).abs();
    final Offset start = c + axis * (reversed ? maxT : minT);
    final Offset end = c + axis * (reversed ? minT : maxT);
    return _Candidate(WbFittedShapeKind.line, <Offset>[start, end]);
  }

  // ---- 圆（Kåsa 代数最小二乘） ---------------------------------------------

  static _Candidate? _fitCircle(List<Offset> pts, double d) {
    final Offset c0 = _centroid(pts);
    double sxx = 0;
    double sxy = 0;
    double syy = 0;
    double sx = 0;
    double sy = 0;
    double sxq = 0;
    double syq = 0;
    double sq = 0;
    for (final Offset p in pts) {
      final double x = p.dx - c0.dx;
      final double y = p.dy - c0.dy;
      final double q = x * x + y * y;
      sxx += x * x;
      sxy += x * y;
      syy += y * y;
      sx += x;
      sy += y;
      sxq += x * q;
      syq += y * q;
      sq += q;
    }
    final List<double>? sol = _solveLinear(
      <List<double>>[
        <double>[sxx, sxy, sx],
        <double>[sxy, syy, sy],
        <double>[sx, sy, pts.length.toDouble()],
      ],
      <double>[-sxq, -syq, -sq],
    );
    if (sol == null) {
      return null;
    }
    final Offset center = Offset(c0.dx - sol[0] / 2, c0.dy - sol[1] / 2);
    final double r2 = sol[0] * sol[0] / 4 + sol[1] * sol[1] / 4 - sol[2];
    if (!r2.isFinite || r2 <= 1e-9) {
      return null;
    }
    final double radius = math.sqrt(r2);
    double dev = 0;
    for (final Offset p in pts) {
      dev += ((p - center).distance - radius).abs();
    }
    dev /= pts.length;
    if (dev / radius > _circleMaxRadiusDev) {
      return null;
    }
    if (_angularCoverage(pts, center) < _curveMinCoverage) {
      return null;
    }
    // 以首点朝向为起点的均匀采样闭环。
    final Offset first = pts.first - center;
    final double start = math.atan2(first.dy, first.dx);
    final List<Offset> samples = <Offset>[];
    for (int i = 0; i < curveSamples; i++) {
      final double t = start + 2 * math.pi * i / curveSamples;
      samples.add(
        Offset(
          center.dx + radius * math.cos(t),
          center.dy + radius * math.sin(t),
        ),
      );
    }
    samples.add(samples.first);
    return _Candidate(WbFittedShapeKind.circle, samples);
  }

  /// 点集绕 [center] 的角度覆盖（弧度）：2π − 最大角度空隙。
  static double _angularCoverage(List<Offset> pts, Offset center) {
    if (pts.length < 2) {
      return 0;
    }
    final List<double> angles = <double>[
      for (final Offset p in pts)
        math.atan2(p.dy - center.dy, p.dx - center.dx),
    ]..sort();
    double maxGap = angles.first + 2 * math.pi - angles.last;
    for (int i = 1; i < angles.length; i++) {
      maxGap = math.max(maxGap, angles[i] - angles[i - 1]);
    }
    return math.max(0, 2 * math.pi - maxGap);
  }

  // ---- 椭圆（中心化圆锥最小二乘 A x² + B xy + C y² + D x + E y = 1） --------

  static _Candidate? _fitEllipse(List<Offset> pts, double d) {
    final Offset c0 = _centroid(pts);
    final List<List<double>> m = <List<double>>[
      for (int i = 0; i < 5; i++) List<double>.filled(5, 0),
    ];
    final List<double> rhs = List<double>.filled(5, 0);
    for (final Offset p in pts) {
      final double x = p.dx - c0.dx;
      final double y = p.dy - c0.dy;
      final List<double> f = <double>[x * x, x * y, y * y, x, y];
      for (int i = 0; i < 5; i++) {
        for (int j = 0; j < 5; j++) {
          m[i][j] += f[i] * f[j];
        }
        rhs[i] += f[i];
      }
    }
    final List<double>? sol = _solveLinear(m, rhs);
    if (sol == null) {
      return null;
    }
    final double a = sol[0];
    final double b = sol[1];
    final double c = sol[2];
    final double dd = sol[3];
    final double e = sol[4];
    final double disc = b * b - 4 * a * c;
    if (disc >= -1e-9) {
      return null; // 非椭圆（双曲线 / 抛物线 / 退化）
    }
    final double denom = 4 * a * c - b * b;
    final double cx = (b * e - 2 * c * dd) / denom;
    final double cy = (b * dd - 2 * a * e) / denom;
    // 平移后圆锥：a x'² + b x'y' + c y'² = k（k = q(center) + 1）。
    final double k = a * cx * cx + b * cx * cy + c * cy * cy + 1;
    if (!k.isFinite || k <= 1e-9) {
      return null;
    }
    final double half = (a + c) / 2;
    final double detQ = a * c - b * b / 4;
    final double eigDisc = half * half - detQ;
    if (eigDisc < 0) {
      return null;
    }
    final double sq = math.sqrt(eigDisc);
    final double l1 = half + sq;
    final double l2 = half - sq;
    if (l1 <= 1e-9 || l2 <= 1e-9) {
      return null;
    }
    final double semi1 = math.sqrt(k / l1);
    final double semi2 = math.sqrt(k / l2);
    final double ratio =
        math.min(semi1, semi2) / math.max(semi1, semi2);
    if (ratio < _ellipseMinRatio || ratio >= _ellipseMaxRatio) {
      return null; // 过扁或已达圆形，交由圆分支 / 不识别
    }
    // 主轴方向（对应 l1 的特征向量）。
    Offset u1;
    if ((b / 2).abs() < 1e-12) {
      u1 = a >= c ? const Offset(1, 0) : const Offset(0, 1);
    } else {
      final Offset v = Offset(b / 2, l1 - a);
      final double len = v.distance;
      if (len <= 1e-12) {
        return null;
      }
      u1 = v / len;
    }
    final Offset u2 = Offset(-u1.dy, u1.dx);
    // 近似欧氏距（|f| / |∇f|）把关。
    double sum = 0;
    for (final Offset p in pts) {
      final double x = p.dx - c0.dx;
      final double y = p.dy - c0.dy;
      final double fx = a * x * x + b * x * y + c * y * y + dd * x + e * y - 1;
      final double gx = 2 * a * x + b * y + dd;
      final double gy = b * x + 2 * c * y + e;
      final double g = math.sqrt(gx * gx + gy * gy);
      sum += g < 1e-12 ? 0 : fx.abs() / g;
    }
    if (sum / pts.length > _ellipseMaxApproxDevRatio * d) {
      return null;
    }
    final Offset center = c0 + Offset(cx, cy);
    // 归一化空间绕心角覆盖：缺口过大（弧线）不视为椭圆。
    final List<Offset> normalized = <Offset>[
      for (final Offset p in pts)
        Offset(
          ((p.dx - center.dx) * u1.dx + (p.dy - center.dy) * u1.dy) / semi1,
          ((p.dx - center.dx) * u2.dx + (p.dy - center.dy) * u2.dy) / semi2,
        ),
    ];
    if (_angularCoverage(normalized, Offset.zero) < _curveMinCoverage) {
      return null;
    }
    // 以首点参数角为起点的均匀采样闭环。
    final Offset rel = pts.first - center;
    final double px = rel.dx * u1.dx + rel.dy * u1.dy;
    final double py = rel.dx * u2.dx + rel.dy * u2.dy;
    final double t0 = math.atan2(py / semi2, px / semi1);
    final List<Offset> samples = <Offset>[];
    for (int i = 0; i < curveSamples; i++) {
      final double t = t0 + 2 * math.pi * i / curveSamples;
      final double cosT = math.cos(t);
      final double sinT = math.sin(t);
      samples.add(
        Offset(
          center.dx + u1.dx * semi1 * cosT + u2.dx * semi2 * sinT,
          center.dy + u1.dy * semi1 * cosT + u2.dy * semi2 * sinT,
        ),
      );
    }
    samples.add(samples.first);
    return _Candidate(WbFittedShapeKind.ellipse, samples);
  }

  // ---- 角点族 --------------------------------------------------------------

  /// Douglas-Peucker 抽稀（迭代实现；保留首尾索引）。
  static List<int> _douglasPeuckerIndices(List<Offset> pts, double tolerance) {
    final int n = pts.length;
    final List<bool> keep = List<bool>.filled(n, false);
    keep[0] = true;
    keep[n - 1] = true;
    final List<List<int>> stack = <List<int>>[
      <int>[0, n - 1],
    ];
    while (stack.isNotEmpty) {
      final List<int> range = stack.removeLast();
      final int start = range[0];
      final int end = range[1];
      double maxDistance = 0;
      int maxIndex = -1;
      for (int i = start + 1; i < end; i++) {
        final double distance =
            _distanceToSegment(pts[i], pts[start], pts[end]);
        if (distance > maxDistance) {
          maxDistance = distance;
          maxIndex = i;
        }
      }
      if (maxIndex != -1 && maxDistance > tolerance) {
        keep[maxIndex] = true;
        stack.add(<int>[start, maxIndex]);
        stack.add(<int>[maxIndex, end]);
      }
    }
    return <int>[
      for (int i = 0; i < n; i++)
        if (keep[i]) i,
    ];
  }

  /// 闭合笔迹旋转到「最大折转点」为 DP 起点——避免起笔落在边中部时，
  /// 接缝把一条边切成两段产生伪角。
  static List<Offset> _rotateClosedLoop(List<Offset> loop) {
    final int m = loop.length;
    if (m < 3) {
      return <Offset>[...loop, loop.first];
    }
    final int k = math.max(1, math.min(3, m ~/ 20));
    int seam = 0;
    double bestTurn = -1;
    for (int i = 0; i < m; i++) {
      final double turn = _turning(
        loop[(i - k) % m],
        loop[i],
        loop[(i + k) % m],
      );
      if (turn > bestTurn) {
        bestTurn = turn;
        seam = i;
      }
    }
    return <Offset>[
      for (int j = 0; j < m; j++) loop[(seam + j) % m],
      loop[seam],
    ];
  }

  /// 闭合图形角点过滤：剔除近直伪角与过短边（至少保留 3 个角）。
  static List<int> _filterClosedCorners(
    List<Offset> rotated,
    List<int> corners,
    double d,
  ) {
    final List<int> work = List<int>.of(corners);
    final double minEdge = math.max(_minEdgeAbs, _minEdgeRatio * d);
    bool changed = true;
    while (changed && work.length > 3) {
      changed = false;
      for (int i = 0; i < work.length; i++) {
        if (_closedCornerAngle(rotated, work, i) >= _closedFlatCorner) {
          work.removeAt(i);
          changed = true;
          break;
        }
      }
      if (changed) {
        continue;
      }
      for (int i = 0; i < work.length; i++) {
        final int j = (i + 1) % work.length;
        if ((rotated[work[j]] - rotated[work[i]]).distance < minEdge) {
          final double angleI = _closedCornerAngle(rotated, work, i);
          final double angleJ = _closedCornerAngle(rotated, work, j);
          work.removeAt(angleI >= angleJ ? i : j);
          changed = true;
          break;
        }
      }
    }
    return work;
  }

  /// 闭合角点 [index] 处夹角（循环视图；π = 直线）。
  static double _closedCornerAngle(
    List<Offset> rotated,
    List<int> work,
    int index,
  ) {
    final int m = work.length;
    return _angleAt(
      rotated,
      work[(index - 1) % m],
      work[index],
      work[(index + 1) % m],
    );
  }

  /// 开放图形角点过滤：剔除近直伪角（阈值更严）与过短边；端点保留。
  static List<int> _filterOpenCorners(
    List<Offset> pts,
    List<int> corners,
    double d,
  ) {
    final List<int> work = List<int>.of(corners);
    final double minEdge = math.max(_minEdgeAbs, _minEdgeRatio * d);
    bool changed = true;
    while (changed) {
      changed = false;
      for (int i = 1; i + 1 < work.length; i++) {
        final double angle = _angleAt(pts, work[i - 1], work[i], work[i + 1]);
        if (angle >= _openFlatCorner) {
          work.removeAt(i);
          changed = true;
          break;
        }
      }
      if (changed) {
        continue;
      }
      for (int i = 0; i + 1 < work.length; i++) {
        if ((pts[work[i + 1]] - pts[work[i]]).distance >= minEdge) {
          continue;
        }
        final bool canLeft = i >= 1;
        final bool canRight = i + 1 <= work.length - 2;
        if (!canLeft && !canRight) {
          continue;
        }
        int removeAt;
        if (canLeft && canRight) {
          final double angleL = _angleAt(pts, work[i - 1], work[i], work[i + 1]);
          final double angleR =
              _angleAt(pts, work[i], work[i + 1], work[i + 2]);
          removeAt = angleL >= angleR ? i : i + 1;
        } else {
          removeAt = canLeft ? i : i + 1;
        }
        work.removeAt(removeAt);
        changed = true;
        break;
      }
    }
    return work;
  }

  /// 逐边总最小二乘拟合（返回各边直线；开放图形末顶点不留尾边）。
  static List<_Line>? _edgeLines(
    List<Offset> pts,
    List<int> corners, {
    required bool closed,
  }) {
    final int n = corners.length;
    final List<_Line> lines = <_Line>[];
    for (int i = 0; i < n; i++) {
      final int start = corners[i];
      final int end;
      if (i + 1 < n) {
        end = corners[i + 1];
      } else if (closed) {
        end = pts.length - 1;
      } else {
        break;
      }
      if (end <= start) {
        return null;
      }
      lines.add(_fitEdgeLine(pts.sublist(start, end + 1)));
    }
    return lines;
  }

  /// 单条边的 total-LS 直线（锚点取质心，方向取主方向）。
  static _Line _fitEdgeLine(List<Offset> pts) {
    final Offset c = _centroid(pts);
    double sxx = 0;
    double sxy = 0;
    double syy = 0;
    for (final Offset p in pts) {
      final double dx = p.dx - c.dx;
      final double dy = p.dy - c.dy;
      sxx += dx * dx;
      sxy += dx * dy;
      syy += dy * dy;
    }
    final double theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
    return _Line(c, Offset(math.cos(theta), math.sin(theta)));
  }

  /// 两条直线求交；近平行返回 null。
  static Offset? _intersect(_Line a, _Line b) {
    final double denom = a.dir.dx * b.dir.dy - a.dir.dy * b.dir.dx;
    if (denom.abs() < 1e-9) {
      return null;
    }
    final double dx = b.point.dx - a.point.dx;
    final double dy = b.point.dy - a.point.dy;
    final double t = (dx * b.dir.dy - dy * b.dir.dx) / denom;
    final Offset v = a.point + a.dir * t;
    if (!v.dx.isFinite || !v.dy.isFinite) {
      return null;
    }
    return v;
  }

  /// 点向直线投影。
  static Offset _projectOnLine(Offset p, _Line line) {
    final double t = (p.dx - line.point.dx) * line.dir.dx +
        (p.dy - line.point.dy) * line.dir.dy;
    return line.point + line.dir * t;
  }

  /// 闭合图形吸附顶点：角点 = 相邻两边拟合直线交点。
  static List<Offset>? _snapClosedVertices(List<_Line> lines) {
    final int n = lines.length;
    final List<Offset> verts = <Offset>[];
    for (int j = 0; j < n; j++) {
      final Offset? v = _intersect(lines[(j - 1 + n) % n], lines[j]);
      if (v == null) {
        return null;
      }
      verts.add(v);
    }
    return verts;
  }

  /// 闭合角点族总入口：三角形 / 四边形 / 正多边形 / 星形。
  ///
  /// [pts] 末点与首点重合（含亚像素噪声）时裁去重复点；未画满的缺口
  /// 笔迹保留原末点——缺口段在环内作为一条「虚拟边」参与边拟合，顶点
  /// 仍由相邻边直线交点吸附（缺口落在角上时自动补齐）。
  ///
  /// [quadLike] 为「任意四边形证据」：恰好提取出 4 个真实角点（边均为
  /// 直线）但四类判类（长方形 / 正方形 / 平行四边形 / 梯形）不成立时
  /// 置位，供调用方收紧曲线族门槛（防棱角笔迹被椭圆吸附）。
  static _CornerFit _fitClosedCornerShapes(
    List<Offset> pts,
    double d,
  ) {
    if (pts.length < 4) {
      return const _CornerFit(<_Candidate>[]);
    }
    final bool sealed = (pts.last - pts.first).distance <= 0.5;
    List<Offset> loop = sealed ? pts.sublist(0, pts.length - 1) : pts;
    if (!sealed) {
      // 断口补角：缺口两端内侧方向的延长线交点（缺口跨越真实角点时
      // 恢复该角，否则会被缺口弦切掉、使末端伪角混入角点集）。
      final Offset? bridge = _bridgeClosedGap(loop, d);
      if (bridge != null) {
        loop = <Offset>[...loop, bridge];
      }
    }
    final List<Offset> rotated = _rotateClosedLoop(loop);
    final double tolerance =
        math.max(_cornerToleranceMin, _cornerToleranceRatio * d);
    List<int> corners = _douglasPeuckerIndices(rotated, tolerance);
    if (corners.length > 1) {
      // 末点是旋转后的重复起点，去掉。
      corners = corners.sublist(0, corners.length - 1);
    }
    corners = _filterClosedCorners(rotated, corners, d);
    final int n = corners.length;
    if (n != 3 && n != 4 && (n < 5 || n > 12)) {
      return const _CornerFit(<_Candidate>[]);
    }
    final List<_Line>? lines = _edgeLines(rotated, corners, closed: true);
    if (lines == null) {
      return const _CornerFit(<_Candidate>[]);
    }
    final List<Offset>? verts = _snapClosedVertices(lines);
    if (verts == null) {
      return const _CornerFit(<_Candidate>[]);
    }
    switch (n) {
      case 3:
        return _CornerFit(<_Candidate>[
          _Candidate(WbFittedShapeKind.triangle, _closeLoop(verts)),
        ]);
      case 4:
        final WbFittedShapeKind? kind = _classifyQuad(verts);
        if (kind == null) {
          return const _CornerFit(<_Candidate>[], quadLike: true);
        }
        return _CornerFit(<_Candidate>[
          _Candidate(kind, _closeLoop(_regularizeQuad(kind, verts))),
        ]);
      case 10:
        final _Candidate? star = _fitStarOutline(verts);
        if (star != null) {
          return _CornerFit(<_Candidate>[star]);
        }
        return _CornerFit(_fitQuadBySubset(rotated, corners, d));
      default:
        final _Candidate? polygon = _fitRegularPolygon(verts);
        if (polygon != null) {
          return _CornerFit(<_Candidate>[polygon]);
        }
        if (n == 5) {
          final _Candidate? star = _fitPentagram(verts);
          if (star != null) {
            return _CornerFit(<_Candidate>[star]);
          }
        }
        return _CornerFit(_fitQuadBySubset(rotated, corners, d));
    }
  }

  /// 多伪角四边形提取：n=5..12 的角点集在规则多边形 / 星形失败时，
  /// 尝试剔除伪角（圆角弧上被 DP 保留的点、回描重复角、孤立噪声角）后
  /// 的 4 角子集——未入选角点到四条边拟合直线的最小距离须小于
  /// [_quadSubsetDevRatio]·D（伪角「贴边」）才接受；供圆角矩形、大噪声
  /// 矩形、两圈回描等场景兜底（否则候选空置会被椭圆候选劫持）。
  static List<_Candidate> _fitQuadBySubset(
    List<Offset> rotated,
    List<int> corners,
    double d,
  ) {
    final int n = corners.length;
    if (n < 5 || n > 12) {
      return const <_Candidate>[];
    }
    final double maxDev = _quadSubsetDevRatio * d;
    final List<_Candidate> out = <_Candidate>[];
    for (int a = 0; a < n; a++) {
      for (int b = a + 1; b < n; b++) {
        for (int c = b + 1; c < n; c++) {
          for (int e = c + 1; e < n; e++) {
            final List<int> pick = <int>[
              corners[a],
              corners[b],
              corners[c],
              corners[e],
            ];
            final List<_Line>? lines =
                _edgeLines(rotated, pick, closed: true);
            if (lines == null) {
              continue;
            }
            final List<Offset>? verts = _snapClosedVertices(lines);
            if (verts == null) {
              continue;
            }
            final WbFittedShapeKind? kind = _classifyQuad(verts);
            if (kind == null) {
              continue;
            }
            bool ok = true;
            for (int k = 0; k < n && ok; k++) {
              if (k == a || k == b || k == c || k == e) {
                continue;
              }
              // 伪角可能跨越「索引段」（如两圈回描的重复角），故按到
              // 四条边线的最小距离判定「贴边」而非按索引区间映射。
              final Offset p = rotated[corners[k]];
              double nearest = double.infinity;
              for (final _Line line in lines) {
                final double dist = (p - _projectOnLine(p, line)).distance;
                if (dist < nearest) {
                  nearest = dist;
                }
              }
              if (nearest > maxDev) {
                ok = false;
              }
            }
            if (!ok) {
              continue;
            }
            out.add(
                _Candidate(kind, _closeLoop(_regularizeQuad(kind, verts))));
          }
        }
      }
    }
    return out;
  }

  /// 四边形判类：矩形（两组对边平行 + 邻边垂直，含正方形）→
  /// 平行四边形（两组对边均在软性容差内平行、且至少一组在严格容差
  /// 内——「像就吸」，菱形并入此族）→ 梯形（恰有一组对边在软性容差
  /// 内平行）→ 无（明显任意四边形不识别，保留原笔迹）。
  static WbFittedShapeKind? _classifyQuad(List<Offset> v) {
    final Offset s0 = v[1] - v[0];
    final Offset s1 = v[2] - v[1];
    final Offset s2 = v[3] - v[2];
    final Offset s3 = v[0] - v[3];
    final bool parallel02 = _nearlyParallel(s0, s2, _quadParallelSin);
    final bool parallel13 = _nearlyParallel(s1, s3, _quadParallelSin);
    // 四角垂直度：至多一个角可宽限到 14°，允许的角都须 ≤14°。
    // 成对超差（斜腰平行四边形特征）即拒；判据为四角集合统计，
    // 与环起点轮换无关。
    int deviating = 0;
    bool anglesOk = true;
    for (final double c in <double>[
      _turnCos(s0, s1),
      _turnCos(s1, s2),
      _turnCos(s2, s3),
      _turnCos(s3, s0),
    ]) {
      if (c > _quadPerpMaxSin) {
        anglesOk = false;
        break;
      }
      if (c > _quadPerpSin) {
        deviating++;
      }
    }
    if (parallel02 && parallel13 && anglesOk && deviating <= 1) {
      return WbFittedShapeKind.rectangle;
    }
    final bool strict02 = _nearlyParallel(s0, s2, _parallelogramParallelSin);
    final bool strict13 = _nearlyParallel(s1, s3, _parallelogramParallelSin);
    final bool loose02 = _nearlyParallel(s0, s2, _parallelogramLooseSin);
    final bool loose13 = _nearlyParallel(s1, s3, _parallelogramLooseSin);
    if (loose02 && loose13 && (strict02 || strict13)) {
      return WbFittedShapeKind.parallelogram;
    }
    if (loose02 != loose13) {
      return WbFittedShapeKind.trapezoid;
    }
    return null;
  }

  /// 断口端点的内侧行进方向：从 [index] 沿 [step] 方向取窗口 [wMax]
  /// 点内的平均方向；相邻步折转累计超过 [_bridgeMaxTurn] 即停（窗口
  /// 已抵近下一条边或真实角），避免跨角使方向失真；退化返回 zero。
  static Offset _innerDirection(
    List<Offset> loop,
    int index,
    int step,
    int wMax,
  ) {
    final int n = loop.length;
    final double stepF = step.toDouble();
    Offset anchor = loop[index];
    Offset? prevDir;
    double accTurn = 0;
    int stop = index;
    for (int k = 1; k <= wMax; k++) {
      final int i = index + step * k;
      if (i < 0 || i >= n) {
        break;
      }
      final Offset p = loop[i];
      final Offset seg = (p - anchor) * stepF;
      anchor = p;
      if (seg.distance <= 1e-9) {
        continue;
      }
      final Offset nd = seg / seg.distance;
      if (prevDir != null) {
        final double dot =
            (prevDir.dx * nd.dx + prevDir.dy * nd.dy).clamp(-1.0, 1.0);
        accTurn += math.acos(dot);
        if (accTurn > _bridgeMaxTurn) {
          break;
        }
      }
      prevDir = nd;
      stop = i;
    }
    final Offset v = (loop[stop] - loop[index]) * stepF;
    return v.distance <= 1e-9 ? Offset.zero : v / v.distance;
  }

  /// 断口补角：未闭合环末端与起端内侧方向直线的交点。缺口恰好跨越一个
  /// 真实角（如三角形缺了半个角）时恢复该角，使接缝两侧方向延续为
  /// 直线（缺口伪角自然成为平角被剔除）；两端近共线（缺口落在边上，
  /// 如矩形封口没画满）或交点过远时返回 null。
  static Offset? _bridgeClosedGap(List<Offset> loop, double d) {
    final int n = loop.length;
    if (n < 8) {
      return null;
    }
    final int w = math.min(20, n ~/ 6);
    final Offset end = loop.last;
    final Offset start = loop.first;
    final Offset inDir = _innerDirection(loop, n - 1, -1, w);
    final Offset outDir = _innerDirection(loop, 0, 1, w);
    if (inDir.distance <= 1e-6 || outDir.distance <= 1e-6) {
      return null;
    }
    final Offset? cross =
        _intersect(_Line(end, inDir), _Line(start, outDir));
    if (cross == null) {
      return null;
    }
    final Offset toCross = cross - end;
    final double t = toCross.dx * inDir.dx + toCross.dy * inDir.dy;
    final Offset toStart = start - cross;
    final double u = toStart.dx * outDir.dx + toStart.dy * outDir.dy;
    final double maxExt = math.max(2 * (start - end).distance, 0.25 * d);
    if (t < -1 || t > maxExt || u < -1 || u > maxExt) {
      return null;
    }
    return cross;
  }

  static bool _nearlyParallel(Offset a, Offset b, double sinTolerance) {
    return _parallelSin(a, b) <= sinTolerance;
  }

  /// 两向量夹角正弦（|cross| / |a||b|；退化返回 ∞）。
  static double _parallelSin(Offset a, Offset b) {
    final double la = a.distance;
    final double lb = b.distance;
    if (la <= 1e-9 || lb <= 1e-9) {
      return double.infinity;
    }
    return (a.dx * b.dy - a.dy * b.dx).abs() / (la * lb);
  }

  /// 矩形精确重建：中心 + 主方向 + 边长取对边均值，输出四角保证邻边垂直
  /// （保持用户笔序方向）。
  static List<Offset> _rectangleCorners(List<Offset> v) {
    final Offset center = _centroid(v);
    final Offset s0 = v[1] - v[0];
    final Offset s1 = v[2] - v[1];
    final Offset s2 = v[3] - v[2];
    final Offset s3 = v[0] - v[3];
    Offset u = s0 - s2;
    if (u.distance <= 1e-9) {
      u = s1 - s3;
    }
    if (u.distance <= 1e-9) {
      u = s0;
    }
    if (u.distance <= 1e-9) {
      return v;
    }
    final Offset w = u / u.distance;
    Offset n = Offset(-w.dy, w.dx);
    if (n.dx * s1.dx + n.dy * s1.dy < 0) {
      n = Offset(-n.dx, -n.dy);
    }
    final double halfW = (s0.distance + s2.distance) / 4;
    final double halfH = (s1.distance + s3.distance) / 4;
    return <Offset>[
      center - w * halfW - n * halfH,
      center + w * halfW - n * halfH,
      center + w * halfW + n * halfH,
      center - w * halfW + n * halfH,
    ];
  }

  /// 四边形输出规整化：矩形 → 精确垂直矩形；平行四边形 → 对边严格
  /// 平行且等长；梯形 → 更平行的一组对边强制平行（该组两边中点与长度
  /// 保持，另一组腰随动）。
  static List<Offset> _regularizeQuad(
    WbFittedShapeKind kind,
    List<Offset> verts,
  ) {
    switch (kind) {
      case WbFittedShapeKind.rectangle:
        return _rectangleCorners(verts);
      case WbFittedShapeKind.parallelogram:
        return _parallelogramCorners(verts);
      case WbFittedShapeKind.trapezoid:
        return _trapezoidCorners(verts);
      default:
        return verts;
    }
  }

  /// 平行四边形精确重建：中心 + 两组对边平均向量，输出对边严格平行
  /// 且等长（保持用户笔序方向）。
  static List<Offset> _parallelogramCorners(List<Offset> v) {
    final Offset center = _centroid(v);
    final Offset e = (v[1] - v[0] - (v[3] - v[2])) / 2;
    final Offset f = (v[2] - v[1] - (v[0] - v[3])) / 2;
    if (e.distance <= 1e-9 || f.distance <= 1e-9) {
      return v;
    }
    return <Offset>[
      center - (e + f) / 2,
      center + (e - f) / 2,
      center + (e + f) / 2,
      center + (f - e) / 2,
    ];
  }

  /// 梯形精确重建：更平行的一组对边方向取平均后强制平行，该组两边的
  /// 中点与长度保持（另一组腰随动）；平行组退化时原样返回。
  static List<Offset> _trapezoidCorners(List<Offset> v) {
    final Offset s0 = v[1] - v[0];
    final Offset s1 = v[2] - v[1];
    final Offset s2 = v[3] - v[2];
    final Offset s3 = v[0] - v[3];
    if (_parallelSin(s0, s2) <= _parallelSin(s1, s3)) {
      // 边 01 / 23 为平行组（上 / 下底）。
      final Offset dir = s0 - s2;
      if (dir.distance <= 1e-9) {
        return v;
      }
      final Offset u = dir / dir.distance;
      final Offset m01 = (v[0] + v[1]) / 2;
      final Offset m23 = (v[2] + v[3]) / 2;
      return <Offset>[
        m01 - u * (s0.distance / 2),
        m01 + u * (s0.distance / 2),
        m23 + u * (s2.distance / 2),
        m23 - u * (s2.distance / 2),
      ];
    }
    // 边 12 / 30 为平行组。
    final Offset dir = s1 - s3;
    if (dir.distance <= 1e-9) {
      return v;
    }
    final Offset u = dir / dir.distance;
    final Offset m12 = (v[1] + v[2]) / 2;
    final Offset m30 = (v[3] + v[0]) / 2;
    return <Offset>[
      m30 - u * (s3.distance / 2),
      m12 - u * (s1.distance / 2),
      m12 + u * (s1.distance / 2),
      m30 + u * (s3.distance / 2),
    ];
  }

  /// 正多边形（5~8 边）：参观序角步长均匀 + 半径均匀 → 按 2π/N 对称角吸附。
  static _Candidate? _fitRegularPolygon(List<Offset> verts) {
    final int n = verts.length;
    final Offset center = _centroid(verts);
    final double expected = 2 * math.pi / n;
    if (_maxAngularStepDeviation(verts, center, expected) > _polygonStepDev) {
      return null;
    }
    if (_maxRadiusDeviation(verts, center) > _polygonRadiusDev) {
      return null;
    }
    final double dir = _stepSign(verts, center);
    double sum = 0;
    for (int i = 0; i < n; i++) {
      final double theta =
          math.atan2(verts[i].dy - center.dy, verts[i].dx - center.dx);
      sum += _normalizeAngle(theta - dir * expected * i);
    }
    final double phi = _normalizeAngle(sum / n);
    final double radius = _meanRadius(verts, center);
    final List<Offset> samples = <Offset>[];
    for (int i = 0; i < n; i++) {
      final double t = phi + dir * expected * i;
      samples.add(
        Offset(
          center.dx + radius * math.cos(t),
          center.dy + radius * math.sin(t),
        ),
      );
    }
    return _Candidate(WbFittedShapeKind.regularPolygon, _closeLoop(samples));
  }

  /// 一笔交叉五角星（5 角、参观序步长 ≈ 144°）。
  static _Candidate? _fitPentagram(List<Offset> verts) {
    final Offset center = _centroid(verts);
    const double expected = 4 * math.pi / 5;
    if (_maxAngularStepDeviation(verts, center, expected) > _polygonStepDev) {
      return null;
    }
    if (_maxRadiusDeviation(verts, center) > _polygonRadiusDev) {
      return null;
    }
    final double dir = _stepSign(verts, center);
    double sum = 0;
    for (int i = 0; i < 5; i++) {
      final double theta =
          math.atan2(verts[i].dy - center.dy, verts[i].dx - center.dx);
      sum += _normalizeAngle(theta - dir * expected * i);
    }
    final double phi = _normalizeAngle(sum / 5);
    final double radius = _meanRadius(verts, center);
    final List<Offset> samples = <Offset>[];
    for (int i = 0; i < 5; i++) {
      final double t = phi + dir * expected * i;
      samples.add(
        Offset(
          center.dx + radius * math.cos(t),
          center.dy + radius * math.sin(t),
        ),
      );
    }
    return _Candidate(WbFittedShapeKind.star, _closeLoop(samples));
  }

  /// 十角轮廓五角星：36° 均匀步长 + 外 / 内半径交替（比 ≥ 1.4）。
  static _Candidate? _fitStarOutline(List<Offset> verts) {
    final Offset center = _centroid(verts);
    const double expected = math.pi / 5;
    if (_maxAngularStepDeviation(verts, center, expected) > _polygonStepDev) {
      return null;
    }
    final List<double> radii = <double>[
      for (final Offset v in verts) (v - center).distance,
    ];
    double evenSum = 0;
    double oddSum = 0;
    for (int i = 0; i < 10; i++) {
      if (i.isEven) {
        evenSum += radii[i];
      } else {
        oddSum += radii[i];
      }
    }
    final double evenMean = evenSum / 5;
    final double oddMean = oddSum / 5;
    final double outer = math.max(evenMean, oddMean);
    final double inner = math.min(evenMean, oddMean);
    if (inner <= 1e-9 || outer / inner < _starMinRadiusRatio) {
      return null;
    }
    for (int i = 0; i < 10; i++) {
      final double mean = i.isEven ? evenMean : oddMean;
      if (mean <= 1e-9 || (radii[i] - mean).abs() / mean > _polygonRadiusDev) {
        return null;
      }
    }
    final double dir = _stepSign(verts, center);
    double sum = 0;
    for (int i = 0; i < 10; i++) {
      final double theta =
          math.atan2(verts[i].dy - center.dy, verts[i].dx - center.dx);
      sum += _normalizeAngle(theta - dir * expected * i);
    }
    final double phi = _normalizeAngle(sum / 10);
    final List<Offset> samples = <Offset>[];
    for (int i = 0; i < 10; i++) {
      final double t = phi + dir * expected * i;
      final double radius = i.isEven ? evenMean : oddMean;
      samples.add(
        Offset(
          center.dx + radius * math.cos(t),
          center.dy + radius * math.sin(t),
        ),
      );
    }
    return _Candidate(WbFittedShapeKind.star, _closeLoop(samples));
  }

  /// 参观序相邻顶点角步长相对 [expected] 的最大偏差（方位自动适配）。
  static double _maxAngularStepDeviation(
    List<Offset> verts,
    Offset center,
    double expected,
  ) {
    final int n = verts.length;
    double maxDev = 0;
    for (int i = 0; i < n; i++) {
      final Offset a = verts[i] - center;
      final Offset b = verts[(i + 1) % n] - center;
      final double step = _normalizeAngle(
        math.atan2(b.dy, b.dx) - math.atan2(a.dy, a.dx),
      );
      final double dev = math.min(
        (step - expected).abs(),
        (step + expected).abs(),
      );
      maxDev = math.max(maxDev, dev);
    }
    return maxDev;
  }

  /// 参观序方向（+1 逆时针 / −1 顺时针）。
  static double _stepSign(List<Offset> verts, Offset center) {
    if (verts.length < 2) {
      return 1;
    }
    final Offset a = verts[0] - center;
    final Offset b = verts[1] - center;
    final double step = _normalizeAngle(
      math.atan2(b.dy, b.dx) - math.atan2(a.dy, a.dx),
    );
    return step >= 0 ? 1 : -1;
  }

  static double _maxRadiusDeviation(List<Offset> verts, Offset center) {
    final double mean = _meanRadius(verts, center);
    if (mean <= 1e-9) {
      return double.infinity;
    }
    double maxDev = 0;
    for (final Offset v in verts) {
      maxDev = math.max(maxDev, ((v - center).distance - mean).abs() / mean);
    }
    return maxDev;
  }

  static double _meanRadius(List<Offset> verts, Offset center) {
    double sum = 0;
    for (final Offset v in verts) {
      sum += (v - center).distance;
    }
    return sum / verts.length;
  }

  /// 开放折线：DP 角点（近直伪角更严剔除）→ 逐边拟合 → 内点求交、
  /// 端点投影（保留用户首末笔位置）；首 / 尾短勾先剪后拟合。
  static _Candidate? _fitOpenPolyline(List<Offset> pts, double d) {
    final double tolerance =
        math.max(_cornerToleranceMin, _cornerToleranceRatio * d);
    final _OpenTrim trim = _trimOpenHook(pts, tolerance);
    final List<Offset> work = trim.work;
    List<int> corners = _douglasPeuckerIndices(work, tolerance);
    if (corners.length < 3) {
      // 短勾剪去后主体已近直线：直接对剪后点集给出直线候选——含勾
      // 整笔的平均垂直距超限，外层对原笔迹拟合的直线候选兜不住此
      // 场景（否则横线带小勾会识别失败）。
      if (work.length == pts.length) {
        return null;
      }
      final _Candidate? line = _fitStraightLine(work, d);
      if (line == null) {
        return null;
      }
      return _extendLineToJunctions(line, trim);
    }
    corners = _filterOpenCorners(work, corners, d);
    if (corners.length < 3 || corners.length > _maxOpenCorners) {
      return null;
    }
    final List<_Line>? lines = _edgeLines(work, corners, closed: false);
    if (lines == null) {
      return null;
    }
    final List<Offset> verts = <Offset>[
      _projectOnLine(work[corners.first], lines.first),
    ];
    for (int i = 0; i + 1 < lines.length; i++) {
      final Offset? v = _intersect(lines[i], lines[i + 1]);
      if (v == null) {
        return null;
      }
      verts.add(v);
    }
    verts.add(_projectOnLine(work[corners.last], lines.last));
    if (verts.length != corners.length) {
      return null;
    }
    // 顶点回漂守卫：平滑圆弧的「拐角」来自抽稀伪角，其相邻边切向线
    // 交点会漂到弧外很远处（平均残差仍可能偏低）；真实折线的顶点应
    // 落在角点附近（噪声量级）。漂移超限即拒绝吸附、保留原笔迹。
    final double maxDrift =
        math.max(_openSnapDriftTolerance * tolerance, _openSnapDriftRatio * d);
    for (int i = 0; i < verts.length; i++) {
      if ((verts[i] - work[corners[i]]).distance > maxDrift) {
        return null;
      }
    }
    return _Candidate(WbFittedShapeKind.polyline, verts);
  }

  /// 开放笔迹「箭头」拟合：杆（DP 后最长段）按拟合直线拉直，端部
  /// 折翼吸附为双翼——单翼画法以已画翼的回指 / 横偏分量镜像补全。
  ///
  /// 折翼要求：折段只落在杆的一端（另一端即笔迹端点）、长度上限
  /// [_arrowBarbMaxShaftRatio] × 杆长、回指分量与横向偏离达标；单翼
  /// 还须超过 [_arrowSingleBarbMinRatio] × 总弦距（略低于小勾剪直
  /// 阈，翼稍短的单侧箭头仍吸附），双翼按 [_arrowDoubleBarbMinRatio]
  /// 与 [_arrowBarbAbsMin] 取更松下限。小勾、L / Z 长边拐角与
  /// 两端都有折段的画法（双向箭头等）不在此吸附，返回 null。
  static _Candidate? _fitOpenArrow(List<Offset> pts, double d) {
    final double tolerance =
        math.max(_cornerToleranceMin, _cornerToleranceRatio * d);
    List<int> corners = _douglasPeuckerIndices(pts, tolerance);
    if (corners.length < 3) {
      return null;
    }
    corners = _filterOpenCorners(pts, corners, d);
    if (corners.length < 3 || corners.length > 6) {
      return null;
    }
    double totalChord = 0;
    double shaftLen = -1;
    int shaftIndex = 0;
    for (int i = 0; i + 1 < corners.length; i++) {
      final double len = (pts[corners[i + 1]] - pts[corners[i]]).distance;
      totalChord += len;
      if (len > shaftLen) {
        shaftLen = len;
        shaftIndex = i;
      }
    }
    if (totalChord <= 1e-9 || shaftLen <= 1e-9) {
      return null;
    }
    // 单头：折段只允许分布在杆的一端，另一端必须是杆端点本身。
    final int lastCorner = corners.length - 1;
    final bool headAtEnd = shaftIndex + 1 <= lastCorner - 1;
    final bool headAtStart = shaftIndex >= 1;
    if (headAtEnd == headAtStart) {
      return null;
    }
    final int tipIndex = corners[headAtEnd ? shaftIndex + 1 : shaftIndex];
    final int tailIndex = corners[headAtEnd ? 0 : lastCorner];
    Offset tipRaw = pts[tipIndex];
    final Offset tailRaw = pts[tailIndex];
    // 杆点集 = 笔迹中不含头部折段的一侧，拉直拟合。箭头语义即「杆
    // 拉直」：手绘「弯一点」的杆（拱高可超直线度门槛）仍应吸附，
    // 宽松模式跳过直线度 / 拉长度检查（弯曲伪角已由角点过滤处理）。
    final _Candidate? shaft = _fitStraightLine(
      headAtEnd ? pts.sublist(0, tipIndex + 1) : pts.sublist(tipIndex),
      d,
      requireStraight: false,
    );
    if (shaft == null) {
      return null;
    }
    final Offset dir = shaft.points.last - shaft.points.first;
    final double lineLen = dir.distance;
    if (lineLen <= 1e-9) {
      return null;
    }
    final _Line frame = _Line(shaft.points.first, dir / lineLen);
    // 尖端校正：DP 角点常落在杆侧最后采样点（离真实折点可差一个采样
    // 步距），沿杆偏差会污染翼向量的回指分量而误拒大翼——以「过角点、
    // 沿杆方向」的直线与「首翼段点集 PCA 主方向线」的交点替代角点
    // （锚在角点，弯杆不被杆拟合线的拱高带偏翼长；首翼段剔除 DP 尖点
    // 本身，避免杆侧残留污染方向；求交退化、翼点不足或交距跳远则
    // 退回角点）。
    final int wingFar = headAtEnd ? shaftIndex + 2 : shaftIndex - 1;
    final int wingNear = headAtEnd ? tipIndex + 1 : tipIndex - 1;
    if (wingFar >= 0 &&
        wingFar < corners.length &&
        wingNear >= 0 &&
        wingNear < pts.length) {
      final int wa = math.min(wingNear, corners[wingFar]);
      final int wb = math.max(wingNear, corners[wingFar]);
      if (wb > wa) {
        double mx = 0;
        double my = 0;
        for (int i = wa; i <= wb; i++) {
          mx += pts[i].dx;
          my += pts[i].dy;
        }
        final double wc = (wb - wa + 1).toDouble();
        mx /= wc;
        my /= wc;
        double sxx = 0;
        double sxy = 0;
        double syy = 0;
        for (int i = wa; i <= wb; i++) {
          final double dx = pts[i].dx - mx;
          final double dy = pts[i].dy - my;
          sxx += dx * dx;
          sxy += dx * dy;
          syy += dy * dy;
        }
        if (sxx + syy > 1e-9) {
          final double theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
          final Offset wingDir = Offset(math.cos(theta), math.sin(theta));
          final double denom =
              frame.dir.dx * wingDir.dy - frame.dir.dy * wingDir.dx;
          if (denom.abs() >= 0.2) {
            final Offset w = Offset(mx, my) - tipRaw;
            final double t = (w.dx * wingDir.dy - w.dy * wingDir.dx) / denom;
            final Offset cross = tipRaw + frame.dir * t;
            final double cd = (cross - tipRaw).distance;
            // 接受半径与 DP 容差挂钩：稀采样（大步距）下角点沿杆偏
            // 差可达一个步距，固定 6px 会拦下本应生效的校正。
            if (cd <= math.max(6.0, 2.0 * tolerance)) {
              tipRaw = cross;
            }
          }
        }
      }
    }
    final Offset tailProj = _projectOnLine(tailRaw, frame);
    final Offset tipProj = _projectOnLine(tipRaw, frame);
    final Offset axis = tipProj - tailProj;
    final double axisLen = axis.distance;
    if (axisLen <= 1e-9) {
      return null;
    }
    final Offset u = axis / axisLen;
    final Offset n = Offset(-u.dy, u.dx);
    // 头部折段角点按「离尖端由近及远」排列（先头后杆的笔序取反），
    // 忽略尖端附近回描产生的重复角（tip'）。
    final double tipEps = math.max(2.5, 0.5 * tolerance);
    final List<Offset> chain = <Offset>[
      if (headAtEnd)
        for (int i = shaftIndex + 2; i <= lastCorner; i++) pts[corners[i]]
      else
        for (int i = shaftIndex - 1; i >= 0; i--) pts[corners[i]],
    ];
    final List<Offset> barbs = <Offset>[
      for (final Offset p in chain)
        if ((p - tipRaw).distance > tipEps) p,
    ];
    if (barbs.isEmpty) {
      return null;
    }
    final bool dual = barbs.length >= 2 &&
        (barbs.last - barbs.first).distance > tipEps;
    final double barbMin = dual
        ? math.max(_arrowBarbAbsMin, _arrowDoubleBarbMinRatio * shaftLen)
        : math.max(_minEdgeAbs, _arrowSingleBarbMinRatio * totalChord);
    final double barbMax = _arrowBarbMaxShaftRatio * shaftLen;
    bool isBarb(Offset p) {
      final Offset v = p - tipRaw;
      final double len = v.distance;
      if (len <= barbMin || len > barbMax) {
        return false;
      }
      final double back = -(v.dx * u.dx + v.dy * u.dy);
      final double backMin = -math.max(
        _arrowBarbBackAbsMin,
        _arrowBarbBackRatioMin.abs() * len,
      );
      if (back < backMin) {
        return false;
      }
      return (v.dx * n.dx + v.dy * n.dy).abs() >=
          _arrowBarbMinOutRatio * len;
    }

    final Offset first = barbs.first;
    final Offset? second = dual ? barbs.last : null;
    if (!isBarb(first) || (second != null && !isBarb(second))) {
      return null;
    }
    // 规整化：两翼取已画翼回指 / 横偏分量的均值，从尖端镜像对称。
    double sumBack = 0;
    double sumOut = 0;
    int count = 0;
    for (final Offset p in <Offset>[first, if (second != null) second]) {
      final Offset v = p - tipRaw;
      sumBack += -(v.dx * u.dx + v.dy * u.dy);
      sumOut += (v.dx * n.dx + v.dy * n.dy).abs();
      count++;
    }
    final double backAvg = sumBack / count;
    final double outAvg = sumOut / count;
    final Offset firstV = first - tipRaw;
    final double side = firstV.dx * n.dx + firstV.dy * n.dy >= 0 ? 1 : -1;
    final Offset barb1 = tipProj - u * backAvg + n * (side * outAvg);
    final Offset barb2 = tipProj - u * backAvg - n * (side * outAvg);
    return _Candidate(
      WbFittedShapeKind.arrow,
      <Offset>[tailProj, tipProj, barb1, tipProj, barb2],
    );
  }

  /// 剪口端点补齐：主体拟合线与剪钩（被剪点集的 PCA 主方向线）求交，
  /// 交点在端点外则把端点延至交点——DP 顶点量化会让剪口提前一两个
  /// 采样点（采样步距越大提前越多），直接截断端点会短一截；外延过远
  /// （超过钩跨度 2 倍，求交不稳定）时放弃该端。
  static _Candidate _extendLineToJunctions(_Candidate line, _OpenTrim trim) {
    Offset a = line.points.first;
    Offset b = line.points.last;
    final Offset dir = b - a;
    final double len = dir.distance;
    if (len <= 1e-9) {
      return line;
    }
    final Offset u = dir / len;
    final Offset? headCross = _hookJunction(a, u, trim.headDropped);
    if (headCross != null) {
      final Offset rel = headCross - a;
      if (rel.dx * u.dx + rel.dy * u.dy < -1e-6) {
        a = headCross;
      }
    }
    final Offset? tailCross = _hookJunction(b, u, trim.tailDropped);
    if (tailCross != null) {
      final Offset rel = tailCross - b;
      if (rel.dx * u.dx + rel.dy * u.dy > 1e-6) {
        b = tailCross;
      }
    }
    return _Candidate(line.kind, <Offset>[a, b]);
  }

  /// 剪钩主方向线与「过 [end]、方向 [u]」直线的交点；钩点不足、退化、
  /// 平行或交点离端点超过钩跨度 2 倍（不稳定）时返回 null。
  static Offset? _hookJunction(Offset end, Offset u, List<Offset> hook) {
    if (hook.length < 2) {
      return null;
    }
    final Offset c = _centroid(hook);
    double sxx = 0;
    double sxy = 0;
    double syy = 0;
    for (final Offset p in hook) {
      final double dx = p.dx - c.dx;
      final double dy = p.dy - c.dy;
      sxx += dx * dx;
      sxy += dx * dy;
      syy += dy * dy;
    }
    if (sxx + syy <= 1e-9) {
      return null;
    }
    final double theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
    final Offset axis = Offset(math.cos(theta), math.sin(theta));
    final Offset? cross = _intersect(_Line(end, u), _Line(c, axis));
    if (cross == null || (cross - end).distance > 2 * _diagonal(hook)) {
      return null;
    }
    return cross;
  }

  /// 开放笔迹首 / 尾「短勾」剪裁：DP 后首段或末段长度（按折点弦距
  /// 度量）不超过 max([_minEdgeAbs], [_openHookMaxArcRatio] × 总长/
  /// 折点弦距和) 且与相邻段转折 ≥45° 时，视为收笔手抖的小勾剪去
  /// （首尾都短时各剪一次，最多两轮），由调用方重新抽稀——短勾落入
  /// 直线 / 相邻段；明显大勾（超过阈）不剪，改由箭头候选
  /// [_fitOpenArrow] 吸附或在折线中保留。返回剪后点集与两端被剪勾
  /// 点集（供剪口求交补齐）。
  static _OpenTrim _trimOpenHook(List<Offset> pts, double tolerance) {
    List<Offset> work = pts;
    for (int pass = 0; pass < 2; pass++) {
      final List<int> corners = _douglasPeuckerIndices(work, tolerance);
      if (corners.length < 3) {
        break;
      }
      // 总长与勾长均按折点弦距度量：密集采样（步距 ≲ 噪声幅）时逐点
      // 弧长会因噪声抖动膨胀近一倍，导致小勾漏剪；弦距与采样密度无关。
      double total = 0;
      for (int i = 0; i + 1 < corners.length; i++) {
        total += (work[corners[i + 1]] - work[corners[i]]).distance;
      }
      if (total <= 1e-9) {
        break;
      }
      final double limit = math.max(_minEdgeAbs, _openHookMaxArcRatio * total);
      final double firstLen = (work[corners[1]] - work[corners[0]]).distance;
      final double lastLen =
          (work[work.length - 1] - work[corners[corners.length - 2]]).distance;
      // 勾须为急转折短段（与相邻段方向的转折 ≥45°）：圆弧的弦化
      // 分段转折小，不剪。
      final double turnFirst = _turnCos(
        work[corners[1]] - work[corners[0]],
        work[corners[2]] - work[corners[1]],
      );
      final double turnLast = _turnCos(
        work[corners[corners.length - 2]] -
            work[corners[corners.length - 3]],
        work[corners[corners.length - 1]] -
            work[corners[corners.length - 2]],
      );
      if (firstLen <= limit &&
          firstLen <= lastLen &&
          turnFirst <= _openHookMaxTurnCos) {
        work = work.sublist(corners[1]);
      } else if (lastLen <= limit && turnLast <= _openHookMaxTurnCos) {
        work = work.sublist(0, corners[corners.length - 2] + 1);
      } else {
        break;
      }
    }
    if (identical(work, pts)) {
      return _OpenTrim(work, const <Offset>[], const <Offset>[]);
    }
    // 剪口边界回原始点集定位（sublist 保留元素引用，按 identical 找）。
    int head = 0;
    while (!identical(pts[head], work.first)) {
      head++;
    }
    int tail = pts.length - 1;
    while (!identical(pts[tail], work.last)) {
      tail--;
    }
    return _OpenTrim(work, pts.sublist(0, head), pts.sublist(tail + 1));
  }

  /// 两向量夹角余弦的绝对值（退化返回 1——视为未转折）。
  static double _turnCos(Offset a, Offset b) {
    final double la = a.distance;
    final double lb = b.distance;
    if (la <= 1e-9 || lb <= 1e-9) {
      return 1;
    }
    return (a.dx * b.dx + a.dy * b.dy).abs() / (la * lb);
  }

  /// 闭合折线：末点补首点（渲染闭环）。
  static List<Offset> _closeLoop(List<Offset> verts) {
    return <Offset>[...verts, verts.first];
  }
}
