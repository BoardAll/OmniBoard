/// 单笔图形识别测试：
/// - 识别器（`WbShapeRecognizer`）：合成笔画逐类回归（固定种子噪声），
///   覆盖直线 / 圆 / 椭圆 / 矩形（含边中部起笔与正方形）/ 平行四边形
///   （含菱形与画歪 20° 自动校平）/ 梯形（等腰、直角与画歪下底校平）/
///   三角形 / 正六边形 / 五角星（轮廓与一笔交叉）/ 开放折线（含首尾
///   短勾剪裁：小勾吸直）/ 箭头（杆 + 端部折翼：回描 / 甩笔 / 先画头
///   双翼与单翼自动镜像补全、杆拉直两翼对称、微弯杆仍吸附；L 长边
///   拐角与大 V 不吸附）；未闭合（缺口三角形 / 矩形 /
///   270° 圆）与画过头（超出尾段不参与）、宽松平行 / 垂直判定；圆角与
///   回描（圆角矩形 / 大圆角 / 两圈回描 / 大噪声 / 未闭合圆角）；
///   拒绝用例（波浪线 / 花瓣乱涂 / 过小笔画 / 大缺口弧线 / 任意四边形）。
/// - 控制器集成：画笔抬笔拟合为规整折线（drawing 元素 48 点闭环 + 单条
///   撤销）；开关关闭与荧光笔不拟合（保留 DP 抽稀原笔迹）。
///
/// 断言阈值取几何量级（圆心半径 ±4、角点 ±8 等），噪声固定 seed=42
/// 保证确定性回归。阈值常量语义见 [WbShapeRecognizer] 公开成员。
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_canvas/canvas/canvas_controller.dart';
import 'package:whiteboard_canvas/canvas/canvas_model.dart';
import 'package:whiteboard_canvas/canvas/shape_recognition.dart';

/// 固定种子噪声源与合成笔画生成器。
class _Noise {
  _Noise([int seed = 42]) : _rng = math.Random(seed);

  final math.Random _rng;

  /// 叠加各向同性均匀噪声（幅值 ±[amp]；[amp] ≤ 0 原样返回）。
  Offset jitter(Offset p, double amp) {
    if (amp <= 0) {
      return p;
    }
    return Offset(
      p.dx + (_rng.nextDouble() * 2 - 1) * amp,
      p.dy + (_rng.nextDouble() * 2 - 1) * amp,
    );
  }

  /// 折线路径采样（相邻节点间均分 [stepsPerEdge] 段；[close] 时回到首节点）。
  List<Offset> path(
    List<Offset> nodes,
    int stepsPerEdge,
    double amp, {
    bool close = false,
  }) {
    final List<Offset> stops =
        close ? <Offset>[...nodes, nodes.first] : nodes;
    final List<Offset> out = <Offset>[];
    for (int i = 0; i + 1 < stops.length; i++) {
      for (int s = 0; s < stepsPerEdge; s++) {
        final double t = s / stepsPerEdge;
        out.add(jitter(Offset.lerp(stops[i], stops[i + 1], t)!, amp));
      }
    }
    out.add(jitter(stops.last, amp));
    return out;
  }

  /// 圆采样（[samples] 段整周；含闭环重复点）。
  List<Offset> circle(
    Offset center,
    double radius,
    int samples,
    double amp, {
    double startAngle = 0,
  }) {
    return <Offset>[
      for (int i = 0; i <= samples; i++)
        jitter(
          center +
              Offset(
                radius * math.cos(startAngle + 2 * math.pi * i / samples),
                radius * math.sin(startAngle + 2 * math.pi * i / samples),
              ),
          amp,
        ),
    ];
  }

  /// 椭圆采样（半轴 [a] / [b]，[rotation] 弧度；[samples] 段整周）。
  List<Offset> ellipse(
    Offset center,
    double a,
    double b,
    double rotation,
    int samples,
    double amp,
  ) {
    final Offset u1 = Offset(math.cos(rotation), math.sin(rotation));
    final Offset u2 = Offset(-u1.dy, u1.dx);
    return <Offset>[
      for (int i = 0; i <= samples; i++)
        jitter(() {
          final double t = 2 * math.pi * i / samples;
          return center + u1 * (a * math.cos(t)) + u2 * (b * math.sin(t));
        }(), amp),
    ];
  }
}

/// 闭合断言（首尾点重合，容差亚像素级）。
void _expectClosed(List<Offset> points) {
  expect((points.first - points.last).distance, lessThan(0.5));
}

/// 断言 [expected] 中每个点都能在 [actual] 中找到 [tolerance] 内的近邻。
void _expectCorners(
  List<Offset> actual,
  List<Offset> expected,
  double tolerance,
) {
  for (final Offset e in expected) {
    double best = double.infinity;
    for (final Offset a in actual) {
      best = math.min(best, (a - e).distance);
    }
    expect(best, lessThan(tolerance));
  }
}

/// 正多边形顶点（以 [startDeg] 为起点的等角分布）。
List<Offset> _regularVertices(
  Offset center,
  double radius,
  int count, {
  double startDeg = -90,
}) {
  return <Offset>[
    for (int i = 0; i < count; i++)
      center +
          Offset(
            radius * math.cos((startDeg + 360 * i / count) * math.pi / 180),
            radius * math.sin((startDeg + 360 * i / count) * math.pi / 180),
          ),
  ];
}

/// 闭合笔迹后再沿起笔轨迹续描 [overLength] 弧长（模拟画过头）。
List<Offset> _overdraw(List<Offset> pts, double overLength) {
  final List<Offset> out = List<Offset>.of(pts);
  double acc = 0;
  for (int i = 1; i < pts.length && acc < overLength; i++) {
    acc += (pts[i] - pts[i - 1]).distance;
    out.add(pts[i]);
  }
  return out;
}

/// 从尾部按弧长裁掉 [cutLength]（模拟未画闭合；至少保留首点）。
List<Offset> _cutTail(List<Offset> pts, double cutLength) {
  double acc = 0;
  int i = pts.length - 1;
  while (i > 1 && acc < cutLength) {
    acc += (pts[i] - pts[i - 1]).distance;
    i--;
  }
  return pts.sublist(0, i + 1);
}

/// 圆角矩形采样（[verts] 为四角顶点，[cut] 为直角边切长；圆角以二次
/// 贝塞尔折线近似，[arcSteps] 为单个圆角弧的采样段数；含闭环重复点）。
List<Offset> _roundedRect(
  _Noise n,
  List<Offset> verts,
  double cut,
  int stepsPerEdge,
  double amp, {
  int arcSteps = 12,
}) {
  final int m = verts.length;
  Offset entry(int i) {
    final Offset v = verts[i];
    final Offset prev = verts[(i - 1 + m) % m];
    final Offset d = v - prev;
    return v - d / d.distance * cut;
  }

  Offset exit(int i) {
    final Offset v = verts[i];
    final Offset next = verts[(i + 1) % m];
    final Offset d = next - v;
    return v + d / d.distance * cut;
  }

  Offset quad(Offset p0, Offset p1, Offset p2, double t) {
    final double u = 1 - t;
    return p0 * (u * u) + p1 * (2 * u * t) + p2 * (t * t);
  }

  final List<Offset> stops = <Offset>[];
  for (int i = 0; i < m; i++) {
    final Offset from = exit((i - 1 + m) % m);
    final Offset to = entry(i);
    for (int s = 0; s < stepsPerEdge; s++) {
      stops.add(Offset.lerp(from, to, s / stepsPerEdge)!);
    }
    for (int s = 0; s <= arcSteps; s++) {
      stops.add(quad(entry(i), verts[i], exit(i), s / arcSteps));
    }
  }
  final List<Offset> out = <Offset>[
    for (final Offset p in stops) n.jitter(p, amp),
  ];
  out.add(n.jitter(stops.first, amp));
  return out;
}

void main() {
  const Offset center = Offset(300, 300);

  // ---- 识别器：逐类拟合 ----------------------------------------------------

  group('WbShapeRecognizer 逐类拟合', () {
    test('直线：加噪线段 → line 两端投影', () {
      final _Noise n = _Noise();
      final List<Offset> pts = n.path(
        <Offset>[const Offset(100, 100), const Offset(400, 300)],
        60,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.line);
      expect(fit.points, hasLength(2));
      expect((fit.points.first - const Offset(100, 100)).distance,
          lessThan(4));
      expect((fit.points.last - const Offset(400, 300)).distance, lessThan(4));
    });

    test('圆：加噪整圆 → circle 48 点闭环（起点贴首笔朝向）', () {
      final _Noise n = _Noise();
      const double radius = 120;
      final List<Offset> pts = n.circle(center, radius, 72, 1.5);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.circle);
      expect(fit.points, hasLength(WbShapeRecognizer.curveSamples + 1));
      _expectClosed(fit.points);
      for (final Offset p in fit.points) {
        expect(((p - center).distance - radius).abs(), lessThan(4));
      }
      // 首笔朝向 0° → 起点 ≈ (420, 300)。
      expect((fit.points.first - const Offset(420, 300)).distance,
          lessThan(6));
    });

    test('椭圆：旋转 30° 加噪椭圆 → ellipse 48 点闭环', () {
      final _Noise n = _Noise();
      const double a = 120;
      const double b = 60;
      const double rotation = math.pi / 6;
      final List<Offset> pts = n.ellipse(center, a, b, rotation, 80, 1.5);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.ellipse);
      expect(fit.points, hasLength(WbShapeRecognizer.curveSamples + 1));
      _expectClosed(fit.points);
      // 采样点应落在真实椭圆方程上（归一化二次型 ≈ 1）。
      final Offset u1 = Offset(math.cos(rotation), math.sin(rotation));
      final Offset u2 = Offset(-u1.dy, u1.dx);
      for (final Offset p in fit.points) {
        final Offset rel = p - center;
        final double vx = rel.dx * u1.dx + rel.dy * u1.dy;
        final double vy = rel.dx * u2.dx + rel.dy * u2.dy;
        expect((vx / a) * (vx / a) + (vy / b) * (vy / b), closeTo(1, 0.08));
      }
    });

    test('矩形：从边中部起笔 → rectangle 5 点闭环、四角吸附', () {
      final _Noise n = _Noise();
      const Offset tl = Offset(200, 160);
      const Offset tr = Offset(440, 160);
      const Offset br = Offset(440, 340);
      const Offset bl = Offset(200, 340);
      final List<Offset> pts = n.path(
        <Offset>[const Offset(320, 160), tr, br, bl, tl, const Offset(320, 160)],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.rectangle);
      expect(fit.points, hasLength(5));
      _expectClosed(fit.points);
      _expectCorners(
        fit.points.sublist(0, 4),
        <Offset>[tl, tr, br, bl],
        8,
      );
    });

    test('正方形 → rectangle 且四边近等长', () {
      final _Noise n = _Noise();
      const Offset tl = Offset(240, 240);
      const Offset tr = Offset(440, 240);
      const Offset br = Offset(440, 440);
      const Offset bl = Offset(240, 440);
      final List<Offset> pts =
          n.path(<Offset>[tl, tr, br, bl], 40, 1.5, close: true);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.rectangle);
      expect(fit.points, hasLength(5));
      _expectClosed(fit.points);
      final List<Offset> corners = fit.points.sublist(0, 4);
      final List<double> sides = <double>[
        for (int i = 0; i < 4; i++)
          (corners[(i + 1) % 4] - corners[i]).distance,
      ];
      for (final double side in sides) {
        expect(side, closeTo(200, 8));
      }
    });

    test('菱形 → parallelogram（并入平行四边形族，非矩形）', () {
      final _Noise n = _Noise();
      const Offset top = Offset(300, 150);
      const Offset right = Offset(470, 290);
      const Offset bottom = Offset(300, 430);
      const Offset left = Offset(130, 290);
      final List<Offset> pts =
          n.path(<Offset>[top, right, bottom, left], 40, 1.5, close: true);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.parallelogram,
          reason: '菱形不再单独识别，归入平行四边形');
      expect(fit.points, hasLength(5));
      _expectClosed(fit.points);
      _expectCorners(
        fit.points.sublist(0, 4),
        <Offset>[top, right, bottom, left],
        8,
      );
    });

    test('平行四边形 → parallelogram（邻边斜交不误判矩形）', () {
      final _Noise n = _Noise();
      const Offset a = Offset(200, 200);
      const Offset b = Offset(400, 220);
      const Offset c = Offset(440, 340);
      const Offset d = Offset(240, 320);
      final List<Offset> pts =
          n.path(<Offset>[a, b, c, d], 40, 1.5, close: true);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.parallelogram);
      expect(fit.points, hasLength(5));
      _expectClosed(fit.points);
      _expectCorners(
        fit.points.sublist(0, 4),
        <Offset>[a, b, c, d],
        8,
      );
    });

    test('等腰梯形 → trapezoid 5 点闭环', () {
      final _Noise n = _Noise();
      const Offset tl = Offset(200, 200);
      const Offset tr = Offset(500, 200);
      const Offset br = Offset(560, 400);
      const Offset bl = Offset(140, 400);
      final List<Offset> pts =
          n.path(<Offset>[tl, tr, br, bl], 40, 1.5, close: true);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.trapezoid);
      expect(fit.points, hasLength(5));
      _expectClosed(fit.points);
      _expectCorners(fit.points.sublist(0, 4), <Offset>[tl, tr, br, bl], 8);
    });

    test('直角梯形 → trapezoid', () {
      final _Noise n = _Noise();
      const Offset tl = Offset(200, 200);
      const Offset tr = Offset(500, 200);
      const Offset br = Offset(500, 420);
      const Offset bl = Offset(320, 420);
      final List<Offset> pts =
          n.path(<Offset>[tl, tr, br, bl], 40, 1.5, close: true);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.trapezoid);
      expect(fit.points, hasLength(5));
      _expectClosed(fit.points);
      _expectCorners(fit.points.sublist(0, 4), <Offset>[tl, tr, br, bl], 8);
    });

    test('画歪的平行四边形（两腰差 20°）→ parallelogram 且自动校平', () {
      final _Noise n = _Noise();
      const Offset a = Offset(100, 100);
      const Offset b = Offset(400, 100);
      const Offset c = Offset(525, 300);
      const Offset d = Offset(142, 300);
      final List<Offset> pts =
          n.path(<Offset>[a, b, c, d], 40, 1.5, close: true);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.parallelogram,
          reason: '两腰差 20° 应落在软性容差内被吸附');
      expect(fit.points, hasLength(5));
      _expectClosed(fit.points);
      final List<Offset> q = fit.points.sublist(0, 4);
      // 校正后两组对边严格平行且等长。
      double sinBetween(Offset u, Offset v) =>
          (u.dx * v.dy - u.dy * v.dx).abs() / (u.distance * v.distance);
      final Offset s0 = q[1] - q[0];
      final Offset s1 = q[2] - q[1];
      final Offset s2 = q[3] - q[2];
      final Offset s3 = q[0] - q[3];
      expect(sinBetween(s0, s2), lessThan(0.001));
      expect(sinBetween(s1, s3), lessThan(0.001));
      expect((s0.distance - s2.distance).abs(), lessThan(0.5));
      expect((s1.distance - s3.distance).abs(), lessThan(0.5));
      _expectCorners(q, <Offset>[a, b, c, d], 30);
    });

    test('画歪的梯形（下底倾斜 12°）→ trapezoid 两底严格平行、长度保持', () {
      final _Noise n = _Noise();
      const Offset tl = Offset(200, 200);
      const Offset tr = Offset(500, 200);
      const Offset br = Offset(560, 489);
      const Offset bl = Offset(140, 400);
      final List<Offset> pts =
          n.path(<Offset>[tl, tr, br, bl], 40, 1.5, close: true);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.trapezoid);
      expect(fit.points, hasLength(5));
      _expectClosed(fit.points);
      final List<Offset> q = fit.points.sublist(0, 4);
      double sinBetween(Offset u, Offset v) =>
          (u.dx * v.dy - u.dy * v.dx).abs() / (u.distance * v.distance);
      final Offset s0 = q[1] - q[0];
      final Offset s1 = q[2] - q[1];
      final Offset s2 = q[3] - q[2];
      final Offset s3 = q[0] - q[3];
      // 恰有一组对边（两底）严格平行，另一组（两腰）保持不平行。
      final double pairA = sinBetween(s0, s2);
      final double pairB = sinBetween(s1, s3);
      expect(math.min(pairA, pairB), lessThan(0.001));
      expect(math.max(pairA, pairB), greaterThan(0.3));
      // 两底长度保持（上底 300 / 下底 ≈429.3）。
      final List<double> bases = (pairA <= pairB
          ? <double>[s0.distance, s2.distance]
          : <double>[s1.distance, s3.distance])
        ..sort();
      expect(bases[0], closeTo(300, 2));
      expect(bases[1], closeTo(429.3, 2));
      _expectCorners(q, <Offset>[tl, tr, br, bl], 30);
    });

    test('三角形 → triangle 4 点闭环', () {
      final _Noise n = _Noise();
      const Offset a = Offset(150, 340);
      const Offset b = Offset(370, 300);
      const Offset c = Offset(260, 140);
      final List<Offset> pts =
          n.path(<Offset>[a, b, c], 40, 1.5, close: true);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.triangle);
      expect(fit.points, hasLength(4));
      _expectClosed(fit.points);
      _expectCorners(fit.points.sublist(0, 3), <Offset>[a, b, c], 8);
    });

    test('正六边形 → regularPolygon 7 点闭环、半径均匀', () {
      final _Noise n = _Noise();
      const double radius = 110;
      final List<Offset> verts = _regularVertices(center, radius, 6);
      final List<Offset> pts = n.path(verts, 30, 1.5, close: true);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.regularPolygon);
      expect(fit.points, hasLength(7));
      _expectClosed(fit.points);
      for (final Offset p in fit.points.sublist(0, 6)) {
        expect(((p - center).distance - radius).abs(), lessThan(6));
      }
    });

    test('五角星轮廓：10 角交替半径 → star 11 点闭环', () {
      final _Noise n = _Noise();
      const double outer = 100;
      const double inner = 38;
      final List<Offset> verts = <Offset>[
        for (int i = 0; i < 10; i++)
          center +
              Offset(
                (i.isEven ? outer : inner) *
                    math.cos((-90 + 36.0 * i) * math.pi / 180),
                (i.isEven ? outer : inner) *
                    math.sin((-90 + 36.0 * i) * math.pi / 180),
              ),
      ];
      final List<Offset> pts = n.path(verts, 20, 1.2, close: true);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.star);
      expect(fit.points, hasLength(11));
      _expectClosed(fit.points);
      for (int i = 0; i < 10; i++) {
        final double expected = i.isEven ? outer : inner;
        expect(((fit.points[i] - center).distance - expected).abs(),
            lessThan(6));
      }
    });

    test('一笔交叉五角星：5 角 144° 步长 → star 6 点闭环', () {
      final _Noise n = _Noise();
      const double radius = 110;
      final List<Offset> verts = <Offset>[
        for (int i = 0; i < 5; i++)
          center +
              Offset(
                radius * math.cos((90 + 144.0 * i) * math.pi / 180),
                radius * math.sin((90 + 144.0 * i) * math.pi / 180),
              ),
      ];
      final List<Offset> pts = n.path(verts, 40, 1.2, close: true);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.star);
      expect(fit.points, hasLength(6));
      _expectClosed(fit.points);
      for (final Offset p in fit.points.sublist(0, 5)) {
        expect(((p - center).distance - radius).abs(), lessThan(6));
      }
    });

    test('开放折线：Z 形 → polyline 保留端点', () {
      final _Noise n = _Noise();
      const Offset a = Offset(150, 150);
      const Offset b = Offset(400, 150);
      const Offset c = Offset(400, 320);
      const Offset d = Offset(180, 320);
      final List<Offset> pts = n.path(<Offset>[a, b, c, d], 40, 1.5);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.polyline);
      expect(fit.points, hasLength(4));
      expect((fit.points.first - a).distance, lessThan(5));
      expect((fit.points.last - d).distance, lessThan(5));
      _expectCorners(fit.points, <Offset>[a, b, c, d], 8);
    });

    test('横线末端向下短勾（约 12% 弧长）→ line（小勾吸直）', () {
      final _Noise n = _Noise();
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(400, 340),
        ],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.line,
          reason: '收笔短勾应被忽略、吸附为直线');
      expect(fit.points, hasLength(2));
      expect(
          (fit.points.first - const Offset(100, 300)).distance, lessThan(6));
      expect((fit.points.last - const Offset(400, 300)).distance, lessThan(6));
    });

    test('横线末端向上短勾 → line', () {
      final _Noise n = _Noise();
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(400, 260),
        ],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.line);
      expect(fit.points, hasLength(2));
      expect(
          (fit.points.first - const Offset(100, 300)).distance, lessThan(6));
      expect((fit.points.last - const Offset(400, 300)).distance, lessThan(6));
    });

    test('横线起笔短勾 → line（起笔手抖忽略）', () {
      final _Noise n = _Noise();
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(100, 340),
          const Offset(100, 300),
          const Offset(400, 300),
        ],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.line);
      expect(fit.points, hasLength(2));
      expect(
          (fit.points.first - const Offset(100, 300)).distance, lessThan(6));
      expect((fit.points.last - const Offset(400, 300)).distance, lessThan(6));
    });

    test('横线末端大勾（约 21% 弧长）→ arrow：杆拉直并补全对侧翼', () {
      final _Noise n = _Noise();
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(400, 380),
        ],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.arrow,
          reason: '明显大勾视为箭头意图：吸附为箭头并镜像补全另一翼');
      expect(fit.points, hasLength(5));
      // 输出结构：杆尾 → 尖端 → 已画翼 → 尖端（回描）→ 补全翼。
      expect((fit.points[1] - fit.points[3]).distance, lessThan(0.5));
      _expectCorners(
        fit.points,
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(400, 380),
          const Offset(400, 220),
        ],
        8,
      );
    });

    test('一笔箭头（回描双翼）→ arrow：杆拉直、两翼对称', () {
      final _Noise n = _Noise();
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(372, 270),
          const Offset(400, 300),
          const Offset(372, 330),
        ],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.arrow);
      expect(fit.points, hasLength(5));
      expect((fit.points[1] - fit.points[3]).distance, lessThan(0.5));
      _expectCorners(
        fit.points,
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(372, 270),
          const Offset(372, 330),
        ],
        8,
      );
    });

    test('一笔箭头（先画头后回描杆）→ arrow', () {
      final _Noise n = _Noise();
      // 笔序：上翼 → 尖端 → 下翼 → 回描尖端 → 杆到尾。
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(372, 270),
          const Offset(400, 300),
          const Offset(372, 330),
          const Offset(400, 300),
          const Offset(100, 300),
        ],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.arrow);
      expect(fit.points, hasLength(5));
      _expectCorners(
        fit.points,
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(372, 270),
          const Offset(372, 330),
        ],
        8,
      );
    });

    test('一笔箭头（甩笔式双翼不回描）→ arrow：两翼取均值对称', () {
      final _Noise n = _Noise();
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(372, 270),
          const Offset(392, 330),
        ],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.arrow);
      expect(fit.points, hasLength(5));
      // 两翼回指 / 横偏分量取均值（(28+8)/2 = 18，(30+30)/2 = 30）。
      _expectCorners(
        fit.points,
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(382, 270),
          const Offset(382, 330),
        ],
        8,
      );
    });

    test('横线末端 45° 单翼大回勾 → arrow：镜像补全', () {
      final _Noise n = _Noise();
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(330, 230),
        ],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.arrow);
      expect(fit.points, hasLength(5));
      _expectCorners(
        fit.points,
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(330, 230),
          const Offset(330, 370),
        ],
        8,
      );
    });

    test('横线末端中短勾（约 17% 弧长）→ arrow：短翼仍吸附补全', () {
      final _Noise n = _Noise();
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(400, 351),
        ],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.arrow,
          reason: '翼略短（17%）但明显达标：吸附为箭头并镜像补全');
      expect(fit.points, hasLength(5));
      expect((fit.points[1] - fit.points[3]).distance, lessThan(0.5));
      _expectCorners(
        fit.points,
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(400, 351),
          const Offset(400, 249),
        ],
        8,
      );
    });

    test('微弯杆（中点上拱 20px）+ 末端短翼 → arrow：杆拉直并补全双翼', () {
      final _Noise n = _Noise();
      // 用户手绘「弯一点」的杆（拱 20px）+ 17% 末端垂直翼：杆拉直后
      // 仍须吸附为完整箭头（双边翼），不能退化为单边折线。
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(100, 300),
          const Offset(250, 280),
          const Offset(400, 300),
          const Offset(400, 351),
        ],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.arrow,
          reason: '杆弯曲不应破坏箭头识别：拉直杆并镜像补全另一翼');
      expect(fit.points, hasLength(5));
      expect((fit.points[1] - fit.points[3]).distance, lessThan(0.5));
      // 杆吸附为拱的折中线（y≈290）：起点 (100,300) / 中点 (250,280) /
      // 终点 (400,300) 对称拱，PCA 主方向线过重心 y≈290。
      _expectCorners(
        fit.points,
        <Offset>[
          const Offset(100, 290),
          const Offset(400, 290),
          const Offset(400, 343),
          const Offset(400, 237),
        ],
        8,
      );
    });

    test('下拱弯杆 + 末端短翼 → arrow：尖端锚定角点不被拱高带偏', () {
      final _Noise n = _Noise();
      // 下拱 20px：若尖端校正以杆拟合线（被拱高抬至 y≈310）为基准，
      // 会把尖端拉歪致翼长缩水被拒；校正须锚在 DP 角点上。
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(100, 300),
          const Offset(250, 320),
          const Offset(400, 300),
          const Offset(400, 351),
        ],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.arrow);
      expect(fit.points, hasLength(5));
      _expectCorners(
        fit.points,
        <Offset>[
          const Offset(100, 310),
          const Offset(400, 310),
          const Offset(400, 363),
          const Offset(400, 257),
        ],
        8,
      );
    });

    test('波浪杆（多点手抖 ±8px）+ 末端短翼 → arrow：杆拉直补全双翼', () {
      final _Noise n = _Noise();
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(100, 300),
          const Offset(175, 292),
          const Offset(250, 300),
          const Offset(325, 308),
          const Offset(400, 300),
          const Offset(400, 351),
        ],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.arrow,
          reason: '多点手抖的杆仍应吸附为箭头，不能退化为折线');
      expect(fit.points, hasLength(5));
      _expectCorners(
        fit.points,
        <Offset>[
          const Offset(100, 294),
          const Offset(400, 306),
          const Offset(400, 359),
          const Offset(400, 253),
        ],
        8,
      );
    });

    test('小尺寸箭头（杆 60、末端垂直短翼）→ arrow：不因采样偏差误拒', () {
      final _Noise n = _Noise();
      // 手绘级采样密度（≈2.5px 步距）与噪声（±1px）。
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(100, 300),
          const Offset(160, 300),
          const Offset(160, 313),
        ],
        24,
        1.0,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.arrow,
          reason: '短翼（占弦距约 18%）不应因采样 / 噪声偏差被拒');
      expect(fit.points, hasLength(5));
      expect((fit.points[1] - fit.points[3]).distance, lessThan(0.5));
      _expectCorners(
        fit.points,
        <Offset>[
          const Offset(100, 300),
          const Offset(160, 300),
          const Offset(160, 313),
          const Offset(160, 287),
        ],
        6,
      );
    });

    test('小尺寸回描双翼箭头（杆 60、翼长 10%）→ arrow：绝对下限适配短杆', () {
      final _Noise n = _Noise();
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(100, 300),
          const Offset(160, 300),
          const Offset(155.8, 295.8),
          const Offset(160, 300),
          const Offset(155.8, 304.2),
        ],
        24,
        1.0,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.arrow,
          reason: '双翼绝对下限适配短杆：翼长 6px 的小箭头仍吸附');
      expect(fit.points, hasLength(5));
      expect((fit.points[1] - fit.points[3]).distance, lessThan(0.5));
      _expectCorners(
        fit.points,
        <Offset>[
          const Offset(100, 300),
          const Offset(160, 300),
          const Offset(155.8, 295.8),
          const Offset(155.8, 304.2),
        ],
        6,
      );
    });

    test('长边拐角（第二段超杆长 40%）→ polyline 不吸附箭头', () {
      final _Noise n = _Noise();
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(400, 140),
        ],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.polyline,
          reason: '长边拐角是折线而非箭翼');
      expect(fit.points, hasLength(3));
      _expectCorners(
        fit.points,
        <Offset>[
          const Offset(100, 300),
          const Offset(400, 300),
          const Offset(400, 140),
        ],
        8,
      );
    });

    test('大 V（对勾）折线 → polyline 不吸附箭头', () {
      final _Noise n = _Noise();
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(150, 200),
          const Offset(300, 380),
          const Offset(420, 220),
        ],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.polyline);
      expect(fit.points, hasLength(3));
      _expectCorners(
        fit.points,
        <Offset>[
          const Offset(150, 200),
          const Offset(300, 380),
          const Offset(420, 220),
        ],
        8,
      );
    });
  });

  // ---- 识别器：未闭合 / 画过头 / 宽松平行 ---------------------------------

  group('WbShapeRecognizer 未闭合与画过头', () {
    test('未闭合三角形（缺口跨顶点）：断口补角 → triangle', () {
      final _Noise n = _Noise();
      const Offset a = Offset(170, 400);
      const Offset b = Offset(470, 400);
      const Offset c = Offset(320, 120);
      // 起笔在 a→b 边中部，收笔在 c→a 边距 a 约 90px 处（缺口含顶点 a）。
      final List<Offset> pts = n.path(
        <Offset>[const Offset(300, 400), b, c, const Offset(212, 321)],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.triangle);
      expect(fit.points, hasLength(4));
      _expectClosed(fit.points);
      _expectCorners(fit.points.sublist(0, 3), <Offset>[a, b, c], 12);
    });

    test('未闭合矩形（缺口在边中部）：平角伪角剔除 → rectangle', () {
      final _Noise n = _Noise();
      const Offset tl = Offset(180, 180);
      const Offset tr = Offset(460, 180);
      const Offset br = Offset(460, 420);
      const Offset bl = Offset(180, 420);
      // 收笔停在 bl→tl 边距 tl 60px 处。
      final List<Offset> pts = n.path(
        <Offset>[tl, tr, br, bl, const Offset(180, 240)],
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.rectangle);
      expect(fit.points, hasLength(5));
      _expectClosed(fit.points);
      _expectCorners(fit.points.sublist(0, 4), <Offset>[tl, tr, br, bl], 8);
    });

    test('缺口圆：270° → circle；240° → null', () {
      final _Noise n = _Noise();
      for (final double sweep in <double>[270, 240]) {
        final List<Offset> pts = <Offset>[
          for (int i = 0; i <= 60; i++)
            n.jitter(
              center +
                  Offset(
                    120 * math.cos((-90 + sweep * i / 60) * math.pi / 180),
                    120 * math.sin((-90 + sweep * i / 60) * math.pi / 180),
                  ),
              1.5,
            ),
        ];
        final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
        if (sweep >= 260) {
          expect(fit, isNotNull, reason: '$sweep° 缺口圆应吸附为 circle');
          expect(fit!.kind, WbFittedShapeKind.circle);
          expect(fit.points, hasLength(WbShapeRecognizer.curveSamples + 1));
          _expectClosed(fit.points);
        } else {
          expect(fit, isNull, reason: '$sweep° 缺口过大不应识别');
        }
      }
    });

    test('画过头矩形（超出尾段不参与）：rectangle 非 ellipse', () {
      final _Noise n = _Noise();
      const Offset tl = Offset(180, 180);
      const Offset tr = Offset(460, 180);
      const Offset br = Offset(460, 420);
      const Offset bl = Offset(180, 420);
      // 90px 为收笔小甩；200px 需通过「重描前段」检查才截尾。
      for (final double over in <double>[90, 200]) {
        final List<Offset> pts = _overdraw(
          n.path(<Offset>[tl, tr, br, bl], 40, 1.5, close: true),
          over,
        );
        final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
        expect(fit, isNotNull, reason: '画过头 $over 应可识别');
        expect(fit!.kind, WbFittedShapeKind.rectangle,
            reason: '画过头 $over 应为 rectangle（非 ellipse）');
        expect(fit.points, hasLength(5));
        _expectClosed(fit.points);
        _expectCorners(fit.points.sublist(0, 4), <Offset>[tl, tr, br, bl], 8);
      }
    });

    test('画过头圆：circle（超出尾段不参与）', () {
      final _Noise n = _Noise();
      final List<Offset> pts = _overdraw(n.circle(center, 120, 72, 1.5), 80);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.circle);
      expect(fit.points, hasLength(WbShapeRecognizer.curveSamples + 1));
      _expectClosed(fit.points);
    });

    test('宽松平行四边形（对边差 13°~16°）→ parallelogram', () {
      final _Noise n = _Noise();
      const Offset a = Offset(200, 420);
      const Offset b = Offset(520, 425);
      const Offset c = Offset(590, 260);
      const Offset d = Offset(230, 170);
      final List<Offset> pts =
          n.path(<Offset>[a, b, c, d], 40, 1.5, close: true);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.parallelogram);
      expect(fit.points, hasLength(5));
    });

    test('宽松矩形（邻边偏差 8°、边长比 1.07）→ rectangle', () {
      final _Noise n = _Noise();
      const double a1 = -7.6 * math.pi / 180;
      const double a2 = a1 + 98 * math.pi / 180;
      final Offset la = Offset(300 * math.cos(a1), 300 * math.sin(a1));
      final Offset lb = Offset(280 * math.cos(a2), 280 * math.sin(a2));
      const Offset va = Offset(200, 220);
      final Offset vb = va + la;
      final Offset vc = vb + lb;
      final Offset vd = va + lb;
      final List<Offset> pts =
          n.path(<Offset>[va, vb, vc, vd], 40, 1.5, close: true);
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.rectangle);
      expect(fit.points, hasLength(5));
    });
  });

  // ---- 识别器：圆角与回描 --------------------------------------------------

  group('WbShapeRecognizer 圆角与回描', () {
    test('圆角矩形（切角 30）：rectangle', () {
      final _Noise n = _Noise();
      const Offset tl = Offset(240, 260);
      const Offset tr = Offset(540, 260);
      const Offset br = Offset(540, 500);
      const Offset bl = Offset(240, 500);
      final List<Offset> pts = _roundedRect(
        n,
        <Offset>[tl, tr, br, bl],
        30,
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.rectangle);
      expect(fit.points, hasLength(5));
      _expectClosed(fit.points);
      _expectCorners(fit.points.sublist(0, 4), <Offset>[tl, tr, br, bl], 12);
    });

    test('大圆角矩形（切角 75）：rectangle 非 ellipse', () {
      final _Noise n = _Noise();
      const Offset tl = Offset(240, 260);
      const Offset tr = Offset(540, 260);
      const Offset br = Offset(540, 500);
      const Offset bl = Offset(240, 500);
      final List<Offset> pts = _roundedRect(
        n,
        <Offset>[tl, tr, br, bl],
        75,
        40,
        1.5,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.rectangle,
          reason: '大圆角不得被椭圆候选劫持');
      expect(fit.points, hasLength(5));
      _expectClosed(fit.points);
      _expectCorners(fit.points.sublist(0, 4), <Offset>[tl, tr, br, bl], 25);
    });

    test('矩形两圈回描：rectangle 非 ellipse', () {
      final _Noise n = _Noise();
      const Offset tl = Offset(200, 220);
      const Offset tr = Offset(520, 220);
      const Offset br = Offset(520, 480);
      const Offset bl = Offset(200, 480);
      final List<Offset> pts = _overdraw(
        _roundedRect(n, <Offset>[tl, tr, br, bl], 30, 40, 1.5),
        1e9,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.rectangle,
          reason: '第二圈重描应被截尾，不得被椭圆候选劫持');
      expect(fit.points, hasLength(5));
      _expectClosed(fit.points);
      _expectCorners(fit.points.sublist(0, 4), <Offset>[tl, tr, br, bl], 12);
    });

    test('大噪声矩形（幅值 3.5）：rectangle 非 ellipse', () {
      final _Noise n = _Noise();
      const Offset tl = Offset(200, 220);
      const Offset tr = Offset(520, 220);
      const Offset br = Offset(520, 480);
      const Offset bl = Offset(200, 480);
      final List<Offset> pts = n.path(
        <Offset>[tl, tr, br, bl],
        40,
        3.5,
        close: true,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.rectangle,
          reason: '大噪声不得被椭圆候选劫持');
      expect(fit.points, hasLength(5));
      _expectClosed(fit.points);
      _expectCorners(fit.points.sublist(0, 4), <Offset>[tl, tr, br, bl], 15);
    });

    test('未闭合圆角矩形（缺口跨角）：rectangle', () {
      final _Noise n = _Noise();
      const Offset tl = Offset(240, 260);
      const Offset tr = Offset(540, 260);
      const Offset br = Offset(540, 500);
      const Offset bl = Offset(240, 500);
      final List<Offset> pts = _cutTail(
        _roundedRect(n, <Offset>[tl, tr, br, bl], 30, 40, 1.5),
        140,
      );
      final WbShapeFit? fit = WbShapeRecognizer.recognize(pts);
      expect(fit, isNotNull);
      expect(fit!.kind, WbFittedShapeKind.rectangle);
      expect(fit.points, hasLength(5));
      _expectClosed(fit.points);
      _expectCorners(fit.points.sublist(0, 4), <Offset>[tl, tr, br, bl], 15);
    });
  });

  // ---- 识别器：拒绝用例 ----------------------------------------------------

  group('WbShapeRecognizer 拒绝用例', () {
    test('波浪线：正弦波 → null', () {
      final _Noise n = _Noise();
      final List<Offset> pts = <Offset>[
        for (int i = 0; i <= 300; i++)
          n.jitter(
            Offset(
              50 + 2.0 * i,
              300 + 80 * math.sin(2 * math.pi * (2.0 * i) / 90),
            ),
            1.5,
          ),
      ];
      expect(WbShapeRecognizer.recognize(pts), isNull);
    });

    test('乱涂：花瓣曲线（7 瓣 / 13 瓣）→ null', () {
      final _Noise n = _Noise();
      for (final int petals in <int>[7, 13]) {
        final List<Offset> pts = <Offset>[
          for (int i = 0; i <= 400; i++)
            n.jitter(() {
              final double t = 2 * math.pi * i / 400;
              final double r = 150 + 60 * math.sin(petals * t);
              return Offset(
                center.dx + r * math.cos(t),
                center.dy + r * math.sin(t),
              );
            }(), 1.5),
        ];
        expect(
          WbShapeRecognizer.recognize(pts),
          isNull,
          reason: '$petals 瓣花瓣不应被识别',
        );
      }
    });

    test('过小笔画：半径 5 圆 → null（对角线下限）', () {
      final _Noise n = _Noise();
      final List<Offset> pts = n.circle(center, 5, 48, 0);
      expect(WbShapeRecognizer.recognize(pts), isNull);
    });

    test('大缺口弧线：200° 圆弧 → null（不误吸附为折线）', () {
      final _Noise n = _Noise();
      final List<Offset> pts = <Offset>[
        for (int i = 0; i <= 80; i++)
          n.jitter(
            Offset(
              120 * math.cos(200 * math.pi * i / 80 / 180),
              120 * math.sin(200 * math.pi * i / 80 / 180),
            ),
            1.5,
          ),
      ];
      expect(WbShapeRecognizer.recognize(pts), isNull);
    });

    test('任意四边形（两组对边均不平行）→ null', () {
      final _Noise n = _Noise();
      const Offset a = Offset(200, 180);
      const Offset b = Offset(520, 220);
      const Offset c = Offset(600, 420);
      const Offset d = Offset(200, 540);
      final List<Offset> pts =
          n.path(<Offset>[a, b, c, d], 40, 1.5, close: true);
      expect(WbShapeRecognizer.recognize(pts), isNull);
    });
  });

  // ---- 控制器集成 ----------------------------------------------------------

  group('WbCanvasController 集成', () {
    /// 以画笔工具按世界坐标序列完成一笔（下笔 / 移动 / 抬笔）。
    void stroke(
      WbCanvasController controller,
      List<Offset> points, {
      int pointerId = 1,
      WbCanvasTool tool = WbCanvasTool.pen,
    }) {
      controller.setTool(tool);
      controller.handlePointerDown(pointerId, points.first, shift: false);
      for (int i = 1; i < points.length; i++) {
        controller.handlePointerMove(pointerId, points[i]);
      }
      controller.handlePointerUp(pointerId, points.last);
    }

    test('默认开启；setShapeRecognitionEnabled 变更通知', () {
      final WbCanvasController controller = WbCanvasController();
      addTearDown(controller.dispose);
      expect(controller.shapeRecognitionEnabled, isTrue);

      int notified = 0;
      controller.addListener(() => notified++);
      controller.setShapeRecognitionEnabled(false);
      expect(controller.shapeRecognitionEnabled, isFalse);
      expect(notified, 1);
      controller.setShapeRecognitionEnabled(false); // 同值不通知
      expect(notified, 1);
      controller.setShapeRecognitionEnabled(true);
      expect(notified, 2);
    });

    test('画笔整圆：落定 drawing 拟合 48 点闭环 + 单条撤销', () {
      final WbCanvasController controller = WbCanvasController();
      addTearDown(controller.dispose);
      final _Noise n = _Noise();
      final List<Offset> pts = n.circle(center, 120, 72, 1.5);

      stroke(controller, pts);

      expect(controller.elements, hasLength(1));
      final WbCanvasElement element = controller.elements.single;
      expect(element.type, WbElementKind.drawing);
      expect(element.points, hasLength(WbShapeRecognizer.curveSamples + 1));
      expect((element.points.first - element.points.last).distance,
          lessThan(0.5));
      for (final Offset p in element.points) {
        expect(((p - center).distance - 120).abs(), lessThan(4));
      }
      expect(controller.canUndo, isTrue);
      controller.undo();
      expect(controller.elements, isEmpty);
    });

    test('开关关闭：同手势落定原笔迹（DP 抽稀、端点不吸附）', () {
      final WbCanvasController controller = WbCanvasController();
      addTearDown(controller.dispose);
      controller.setShapeRecognitionEnabled(false);
      final _Noise n = _Noise();
      final List<Offset> pts = n.circle(center, 120, 72, 1.5);

      stroke(controller, pts);

      final WbCanvasElement element = controller.elements.single;
      expect(element.type, WbElementKind.drawing);
      // DP 抽稀保留原始终末点（未拟合为 48 点闭环）。
      expect(element.points.first, pts.first);
      expect(element.points.last, pts.last);
      expect(element.points, isNot(hasLength(WbShapeRecognizer.curveSamples + 1)));
    });

    test('荧光笔：不拟合（开放笔迹保持原端点）', () {
      final WbCanvasController controller = WbCanvasController();
      addTearDown(controller.dispose);
      final _Noise n = _Noise();
      final List<Offset> pts = n.path(
        <Offset>[
          const Offset(150, 150),
          const Offset(400, 150),
          const Offset(400, 320),
          const Offset(180, 320),
        ],
        40,
        1.5,
      );

      stroke(controller, pts, tool: WbCanvasTool.highlighter);

      final WbCanvasElement element = controller.elements.single;
      expect(element.points.first, pts.first);
      expect(element.points.last, pts.last);
      // 若被误拟合，折线候选将吸附为 4 点；DP 笔迹点数远多于阈值。
      expect(element.points.length, greaterThan(6));
    });
  });
}
