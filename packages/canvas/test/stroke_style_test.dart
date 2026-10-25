/// 笔触渲染回归测试：中点平滑对稀疏折线的「可见切角」须保留顶点。
///
/// 背景：拟合角点图形（三角形 4 点 / 矩形 5 点闭环）边段长达数十像素，
/// 若无条件用「中点锚 + 顶点控制」二次贝塞尔平滑，顶点会被切掉数十像素，
/// 整体渲染呈弧形；本测试锁定「顶点着墨、内部留白」的折角保留语义。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_canvas/canvas/stroke_style.dart';

const int _side = 400;

/// 软件光栅化一条笔迹并返回 rawRgba 像素。
Future<ByteData> _render(List<ui.Offset> points) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  paintWbPenStroke(
    canvas,
    points,
    const ui.Color(0xFF000000),
    3,
    WbPenStyle.pen,
  );
  final ui.Image image = await recorder.endRecording().toImage(_side, _side);
  final ByteData? data = await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  );
  image.dispose();
  return data!;
}

/// 采样单像素 alpha（背景透明 → 0；着墨 > 0）。
bool _inked(ByteData data, ui.Offset p) {
  final int x = p.dx.round();
  final int y = p.dy.round();
  return data.getUint8((y * _side + x) * 4 + 3) > 0;
}

void main() {
  testWidgets('拟合三角形（4 点闭环）：三个顶点均着墨、内部留白', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final ByteData data = await _render(const <ui.Offset>[
        ui.Offset(120, 80),
        ui.Offset(320, 320),
        ui.Offset(60, 320),
        ui.Offset(120, 80),
      ]);
      for (final ui.Offset v in const <ui.Offset>[
        ui.Offset(120, 80),
        ui.Offset(320, 320),
        ui.Offset(60, 320),
      ]) {
        expect(_inked(data, v), isTrue, reason: '顶点 $v 应着墨（折角保留）');
      }
      expect(
        _inked(data, const ui.Offset(167, 240)),
        isFalse,
        reason: '三角形内部不应着墨',
      );
    });
  });

  testWidgets('拟合矩形（5 点闭环）：四角均着墨、中心留白', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final ByteData data = await _render(const <ui.Offset>[
        ui.Offset(80, 60),
        ui.Offset(340, 60),
        ui.Offset(340, 300),
        ui.Offset(80, 300),
        ui.Offset(80, 60),
      ]);
      for (final ui.Offset v in const <ui.Offset>[
        ui.Offset(80, 60),
        ui.Offset(340, 60),
        ui.Offset(340, 300),
        ui.Offset(80, 300),
      ]) {
        expect(_inked(data, v), isTrue, reason: '角点 $v 应着墨（折角保留）');
      }
      expect(
        _inked(data, const ui.Offset(210, 180)),
        isFalse,
        reason: '矩形内部不应着墨',
      );
    });
  });

  testWidgets('拟合圆（49 点闭环）：圆周着墨、圆心留白（平滑不被误锚定）', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      const ui.Offset center = ui.Offset(200, 200);
      const double radius = 120;
      final List<ui.Offset> points = <ui.Offset>[];
      for (int i = 0; i <= 48; i++) {
        final double a = i / 48 * 2 * math.pi;
        points.add(
          ui.Offset(
            center.dx + radius * math.cos(a),
            center.dy + radius * math.sin(a),
          ),
        );
      }
      final ByteData data = await _render(points);
      expect(
        _inked(data, const ui.Offset(320, 200)),
        isTrue,
        reason: '圆周（右端点）应着墨',
      );
      expect(_inked(data, center), isFalse, reason: '圆心不应着墨');
    });
  });
}
