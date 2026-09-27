/// 画布背景网格守卫测试（第三轮问题 4）：
/// 未设置页面背景时保留默认辅助网格；设置任意背景（纯色 / 图案 / 图片）
/// 后只显示背景本身，不再叠加默认方格。
///
/// 采用软件光栅化像素采样验证（无 golden，不受字体差异影响）。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/canvas/background_painter.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_painter.dart';

/// 采样画布尺寸（与网格基础步长 24 对齐，至少 5 条网格线）。
const Size _canvasSize = Size(120, 120);

/// 网格交叉点（默认步长 24 下必有网格线经过）。
const Offset _gridCross = Offset(24, 24);

/// 非网格点（距最近网格线 12px）。
const Offset _plainPoint = Offset(36, 12);

const Color _canvasWhite = Color(0xFFFFFFFF);

const Color _green = Color(0xFF3AA76D);

/// 构造仅含背景参数的画布绘制器（无元素 / 无选择 / 无手势）。
WbCanvasPainter _painter({required WbPageBackground? background}) {
  return WbCanvasPainter(
    controller: WbCanvasController(),
    textCache: WbCanvasTextCache(),
    canvasColor: _canvasWhite,
    gridColor: const Color(0x8C64748B),
    selectionColor: const Color(0xFF3366FF),
    pageBackground: background,
  );
}

/// 软件光栅化后采样单像素颜色。
Future<Color> _pixelAt(WbCanvasPainter painter, Offset point) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  painter.paint(canvas, _canvasSize);
  final ui.Image image = await recorder.endRecording().toImage(
        _canvasSize.width.toInt(),
        _canvasSize.height.toInt(),
      );
  final ByteData? data =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final int x = point.dx.round();
  final int y = point.dy.round();
  final int offset = (y * _canvasSize.width.toInt() + x) * 4;
  final Color color = Color.fromARGB(
    data!.getUint8(offset + 3),
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
  );
  image.dispose();
  return color;
}

/// 通道级颜色近似比较（容忍光栅化取整差异）。
bool _sameColor(Color a, Color b, {int tolerance = 2}) {
  final int av = a.toARGB32();
  final int bv = b.toARGB32();
  for (final int shift in <int>[0, 8, 16, 24]) {
    final int channelA = (av >> shift) & 0xFF;
    final int channelB = (bv >> shift) & 0xFF;
    if ((channelA - channelB).abs() > tolerance) {
      return false;
    }
  }
  return true;
}

void main() {
  testWidgets('未设置页面背景：默认辅助网格保留', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final WbCanvasPainter painter = _painter(background: null);
      final Color plain = await _pixelAt(painter, _plainPoint);
      final Color cross = await _pixelAt(painter, _gridCross);

      expect(_sameColor(plain, _canvasWhite), isTrue,
          reason: '非网格点应为底色');
      expect(_sameColor(cross, _canvasWhite), isFalse,
          reason: '网格交叉点应叠加上网格线颜色');
    });
  });

  testWidgets('纯色背景：只显示底色，不再叠加默认网格', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final WbCanvasPainter painter = _painter(
        background: const WbPageBackground(baseColor: _green),
      );
      final Color plain = await _pixelAt(painter, _plainPoint);
      final Color cross = await _pixelAt(painter, _gridCross);

      expect(_sameColor(plain, _green), isTrue, reason: '非网格点应为背景色');
      expect(_sameColor(cross, _green), isTrue,
          reason: '纯色背景下不应叠加默认辅助网格（问题 4）');
    });
  });
}
