/// 画笔笔触：铅笔、粉笔、圆珠笔、刷子，以及原来的均匀实线。
///
/// 噪声由采样点序号决定，同一条笔迹每次重绘结果相同。
library;

import 'dart:math' as math;
import 'dart:ui';

/// 画笔笔触类型。
enum WbPenStyle {
  pen('pen', '画笔'),
  pencil('pencil', '铅笔'),
  chalk('chalk', '粉笔'),
  ballpoint('ballpoint', '圆珠笔'),
  brush('brush', '刷子');

  const WbPenStyle(this.id, this.label);

  /// 持久化 id。
  final String id;

  /// 中文显示名。
  final String label;

  /// 按 id 反查（未知回退 [WbPenStyle.pen]）。
  static WbPenStyle fromId(String id) {
    for (final WbPenStyle style in values) {
      if (style.id == id) {
        return style;
      }
    }
    return WbPenStyle.pen;
  }
}

/// 按笔触绘制一条折线（世界坐标）。
void paintWbPenStroke(
  Canvas canvas,
  List<Offset> points,
  Color color,
  double width,
  WbPenStyle style,
) {
  if (points.isEmpty) {
    return;
  }
  switch (style) {
    case WbPenStyle.pen:
      _solid(canvas, points, color, width);
    case WbPenStyle.pencil:
      _pencil(canvas, points, color, width);
    case WbPenStyle.chalk:
      _chalk(canvas, points, color, width);
    case WbPenStyle.ballpoint:
      _ballpoint(canvas, points, color, width);
    case WbPenStyle.brush:
      _brush(canvas, points, color, width);
  }
}

void _solid(Canvas canvas, List<Offset> points, Color color, double width) {
  if (points.length == 1) {
    canvas.drawCircle(points.first, width / 2, Paint()..color = color);
    return;
  }
  canvas.drawPath(_polyline(points), _stroke(color, width));
}

void _pencil(Canvas canvas, List<Offset> points, Color color, double width) {
  final List<Offset> grain = _jitter(points, width * 0.22, 1);
  for (int pass = 0; pass < 3; pass++) {
    final List<Offset> layer = _jitter(grain, width * 0.16, 10 + pass);
    canvas.drawPath(
      _polyline(layer),
      _stroke(color.withValues(alpha: color.a * 0.45), width * 0.72),
    );
  }
  canvas.drawPath(
    _polyline(grain),
    _stroke(color.withValues(alpha: color.a * 0.9), width * 0.42),
  );
}

void _chalk(Canvas canvas, List<Offset> points, Color color, double width) {
  final double step = math.max(width * 0.42, 1.4);
  int index = 0;
  for (final Offset point in _resample(points, step)) {
    final int specks = 3 + (_unit(index, 2) * 3).floor();
    for (int s = 0; s < specks; s++) {
      final double ang = _unit(index, 20 + s) * math.pi * 2;
      final double rad = _unit(index, 40 + s) * width * 0.85;
      final Offset at = point + Offset(math.cos(ang), math.sin(ang)) * rad;
      final double radius = width * (0.12 + _unit(index, 60 + s) * 0.28);
      final double alpha = color.a * (0.45 + _unit(index, 80 + s) * 0.55);
      canvas.drawCircle(
        at,
        radius,
        Paint()..color = color.withValues(alpha: alpha),
      );
    }
    index++;
  }
}

void _ballpoint(Canvas canvas, List<Offset> points, Color color, double width) {
  final Path smooth = _smooth(points);
  canvas.drawPath(
    smooth,
    _stroke(color.withValues(alpha: color.a * 0.28), width * 1.35),
  );
  canvas.drawPath(smooth, _stroke(color, width * 0.62));
}

void _brush(Canvas canvas, List<Offset> points, Color color, double width) {
  if (points.length == 1) {
    canvas.drawCircle(points.first, width * 0.7, Paint()..color = color);
    return;
  }
  final List<double> half = List<double>.filled(points.length, width * 0.45);
  for (int i = 1; i < points.length; i++) {
    final double speed = (points[i] - points[i - 1]).distance;
    final double t = (speed / math.max(width * 6, 1)).clamp(0.0, 1.0);
    final double target = width * (0.95 - 0.72 * t);
    half[i] = half[i - 1] * 0.45 + target * 0.55;
  }
  half[0] = half[1];

  final List<Offset> left = <Offset>[];
  final List<Offset> right = <Offset>[];
  for (int i = 0; i < points.length; i++) {
    final Offset dir = _tangent(points, i);
    final Offset normal = Offset(-dir.dy, dir.dx);
    left.add(points[i] + normal * half[i]);
    right.add(points[i] - normal * half[i]);
  }
  final Path ribbon = Path()..moveTo(left.first.dx, left.first.dy);
  for (int i = 1; i < left.length; i++) {
    ribbon.lineTo(left[i].dx, left[i].dy);
  }
  for (int i = right.length - 1; i >= 0; i--) {
    ribbon.lineTo(right[i].dx, right[i].dy);
  }
  ribbon.close();
  canvas.drawPath(ribbon, Paint()..color = color);
}

Paint _stroke(Color color, double width) {
  return Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(0.6, width)
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = color;
}

Path _polyline(List<Offset> points) {
  final Path path = Path()..moveTo(points.first.dx, points.first.dy);
  for (int i = 1; i < points.length; i++) {
    path.lineTo(points[i].dx, points[i].dy);
  }
  return path;
}

Path _smooth(List<Offset> points) {
  if (points.length < 3) {
    return _polyline(points);
  }
  final Path path = Path()..moveTo(points.first.dx, points.first.dy);
  for (int i = 1; i < points.length - 1; i++) {
    final Offset mid = Offset(
      (points[i].dx + points[i + 1].dx) / 2,
      (points[i].dy + points[i + 1].dy) / 2,
    );
    path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
  }
  final Offset last = points.last;
  path.lineTo(last.dx, last.dy);
  return path;
}

List<Offset> _jitter(List<Offset> points, double amount, int salt) {
  if (amount <= 0 || points.length < 2) {
    return points;
  }
  return <Offset>[
    for (int i = 0; i < points.length; i++)
      points[i] + _tangent(points, i).scale(
        (_unit(i, salt) - 0.5) * amount,
        (_unit(i, salt + 7) - 0.5) * amount,
      ) +
          Offset(
            -_tangent(points, i).dy,
            _tangent(points, i).dx,
          ) *
              ((_unit(i, salt + 3) - 0.5) * amount),
  ];
}

Offset _tangent(List<Offset> points, int index) {
  final Offset a = points[math.max(0, index - 1)];
  final Offset b = points[math.min(points.length - 1, index + 1)];
  final Offset delta = b - a;
  final double len = delta.distance;
  if (len < 0.001) {
    return const Offset(1, 0);
  }
  return delta / len;
}

Iterable<Offset> _resample(List<Offset> points, double step) sync* {
  if (points.isEmpty) {
    return;
  }
  yield points.first;
  if (points.length == 1) {
    return;
  }
  double pending = 0;
  for (int i = 1; i < points.length; i++) {
    final Offset a = points[i - 1];
    final Offset b = points[i];
    final double len = (b - a).distance;
    if (len < 0.001) {
      continue;
    }
    double walked = step - pending;
    while (walked <= len) {
      final double t = walked / len;
      yield Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t);
      walked += step;
    }
    pending = len - (walked - step);
  }
}

double _unit(int index, int salt) {
  int x = (index + 1) * 0x9E3779B1 ^ salt * 0x85EBCA6B;
  x = (x ^ (x >> 16)) * 0x7FEB352D;
  x = (x ^ (x >> 15)) & 0x7fffffff;
  return x / 0x7fffffff;
}
