/// M2 远端渲染层像素测试（T2f）：
/// - 软锁角标：他人编辑中元素加虚线框 + 「编辑中」橙色标签（屏幕空间）；
/// - 笔迹鬼影：增量点连续绘制（横向 / 纵向段中心像素命中）；
/// - transform 叠加：按目标几何临时绘制且不落模型；
/// - 删除淡出：快照全量 → 衰减 → 过期移除。
///
/// 采用软件光栅化像素采样（无 golden，不受字体差异影响）；鬼影 / 淡出
/// 时钟使用可注入的一次性定时器工厂手动驱动，不真实计时。
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/canvas/background_painter.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_painter.dart';

/// 采样画布尺寸（世界 = 屏幕：scale 1 / offset 0）。
const Size _canvasSize = Size(240, 200);

/// 纯白背景（避免默认辅助网格干扰像素判定）。
const Color _canvasWhite = Color(0xFFFFFFFF);

/// 软锁角标颜色（与 painter `_lockBadgeColor` 一致）。
const Color _lockBadge = Color(0xFFE8590C);

/// 远端预览线色（任意可辨识色）。
const Color _inkColor = Color(0xFF112233);

/// 鬼影时钟步进间隔（与控制器 `_previewTickInterval` 一致）。
const Duration _ghostTickInterval = Duration(milliseconds: 40);

/// 手动一次性定时器（tick 由测试驱动；触发后即失效）。
class _ManualTimer implements Timer {
  _ManualTimer(this.interval, this._onTick);

  final Duration interval;
  final void Function() _onTick;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  @override
  bool get isActive => !_cancelled;

  @override
  int get tick => 0;

  /// 手动触发一次回调（已取消时忽略；一次性语义与真实 `Timer` 一致）。
  void fire() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _onTick();
  }

  @override
  void cancel() {
    _cancelled = true;
  }
}

/// 一次性定时器工厂：捕获创建的定时器，按间隔手动驱动。
class _TimerHub {
  final List<_ManualTimer> timers = <_ManualTimer>[];

  Timer create(Duration interval, void Function() onTick) {
    final _ManualTimer timer = _ManualTimer(interval, onTick);
    timers.add(timer);
    return timer;
  }

  /// 驱动最近一个未取消的指定间隔定时器（无则忽略）。
  void fire(Duration interval) {
    for (int i = timers.length - 1; i >= 0; i--) {
      final _ManualTimer timer = timers[i];
      if (!timer.cancelled && timer.interval == interval) {
        timer.fire();
        return;
      }
    }
  }
}

/// 装配控制器（手动定时器 + 视口 + 单页）。
WbCanvasController _controller(_TimerHub hub) {
  final WbCanvasController controller =
      WbCanvasController(previewTimerFactory: hub.create);
  controller
    ..setViewportSize(_canvasSize)
    ..setPage('p1');
  return controller;
}

/// 构造纯白背景画布绘制器。
WbCanvasPainter _painter(WbCanvasController controller) => WbCanvasPainter(
      controller: controller,
      textCache: WbCanvasTextCache(),
      canvasColor: _canvasWhite,
      gridColor: const Color(0x8C64748B),
      selectionColor: const Color(0xFF3366FF),
      pageBackground: const WbPageBackground(baseColor: _canvasWhite),
    );

/// 在 (40,40) 处插入 100x60 便签（默认主色即可，预期值从元素读取）。
WbCanvasElement _insertNote(WbCanvasController controller) =>
    controller.insertElements(<WbElementSpec>[
      const WbElementSpec(
        type: WbElementKind.note,
        size: Size(100, 60),
        position: Offset(40, 40),
      ),
    ]).single;

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
bool _sameColor(Color a, Color b, {int tolerance = 3}) {
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
  // ---- 软锁角标 ------------------------------------------------------------

  testWidgets('软锁角标：虚线框覆盖 + 间隙留白 + 「编辑中」标签实色', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      final WbCanvasElement note = _insertNote(controller);

      // 未加锁：角标区域为纯白。
      WbCanvasPainter painter = _painter(controller);
      expect(_sameColor(await _pixelAt(painter, const Offset(42, 32)), _canvasWhite),
          isTrue,
          reason: '无远端锁时不绘制角标');

      controller.refreshRemoteLocks(<String, String>{
        note.id: 'user-abcdef123456',
      });
      painter = _painter(controller);

      // 虚线框：帧 top 边 y=38（bounds.inflate(2)），dash 5 / gap 3。
      // 首段 dash 覆盖 x∈[38,43) → (40,38) 有描边；间隙 [43,46) → (44,38) 留白。
      final Color dash = await _pixelAt(painter, const Offset(40, 38));
      final Color gap = await _pixelAt(painter, const Offset(44, 38));
      expect(_sameColor(dash, _canvasWhite, tolerance: 4), isFalse,
          reason: '虚线框 dash 段应有描边色');
      expect(_sameColor(gap, _canvasWhite), isTrue, reason: 'dash 间隙保持背景');

      // 「编辑中」标签胶囊（实色橙；bottom = screen.top - 4 = 34）。
      final Color badge = await _pixelAt(painter, const Offset(42, 32));
      expect(_sameColor(badge, _lockBadge), isTrue,
          reason: '角标胶囊为实色 0xFFE8590C');
    });
  });

  // ---- 笔迹鬼影 ------------------------------------------------------------

  testWidgets('笔迹鬼影：增量点连续绘制（横 / 纵段中心像素命中）', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);

      controller.applyRemotePreviews(<dynamic>[
        <String, dynamic>{
          'kind': 'ink',
          'strokeId': 'remote-stroke-1',
          'pageId': 'p1',
          'points': <dynamic>[
            <double>[60, 60],
            <double>[120, 60],
            <double>[120, 120],
          ],
          'style': <String, dynamic>{'color': 0xFF112233, 'width': 8.0},
          'highlight': false,
        },
      ]);
      expect(controller.remoteInkGhosts, hasLength(1));

      final WbCanvasPainter painter = _painter(controller);
      final Color horizontal = await _pixelAt(painter, const Offset(90, 60));
      final Color vertical = await _pixelAt(painter, const Offset(120, 90));
      expect(_sameColor(horizontal, _inkColor), isTrue,
          reason: '横向段中点应为线色 0xFF112233');
      expect(_sameColor(vertical, _inkColor), isTrue,
          reason: '纵向段中点应为线色（缺口直连兜底）');

      // 终态 op 到达（删除）：鬼影清除，同一位置回落为背景。
      controller.applyRemoteRemove('remote-stroke-1');
      expect(controller.remoteInkGhosts, isEmpty);
      final Color cleared = await _pixelAt(_painter(controller), const Offset(90, 60));
      expect(_sameColor(cleared, _canvasWhite), isTrue, reason: '终态清除后鬼影不再绘制');
    });
  });

  // ---- transform 叠加 -------------------------------------------------------

  testWidgets('transform 叠加：按目标几何临时绘制且不落模型', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      final WbCanvasElement note = _insertNote(controller);
      final Color elementColor = Color(note.color);

      final WbCanvasPainter before = _painter(controller);
      expect(_sameColor(await _pixelAt(before, const Offset(90, 70)), elementColor),
          isTrue,
          reason: '原始位置应绘制元素本体');

      controller.applyRemotePreviews(<dynamic>[
        <String, dynamic>{
          'kind': 'transform',
          'elementId': note.id,
          'pageId': 'p1',
          'x': 140.0,
          'y': 40.0,
          'w': 100.0,
          'h': 60.0,
        },
      ]);
      expect(controller.remoteTransformOverlay(note), isNotNull);
      expect(controller.document.byId('p1', note.id)!.x, 40,
          reason: '叠加为临时绘制，不落模型');

      final WbCanvasPainter after = _painter(controller);
      final Color oldSpot = await _pixelAt(after, const Offset(90, 70));
      final Color newSpot = await _pixelAt(after, const Offset(190, 70));
      expect(_sameColor(oldSpot, _canvasWhite), isTrue, reason: '原位置让位背景');
      expect(_sameColor(newSpot, elementColor), isTrue, reason: '目标位置绘制元素');
    });
  });

  // ---- 删除淡出 -------------------------------------------------------------

  testWidgets('删除淡出：快照全量 → 衰减 → 过期移除', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      final WbCanvasElement note = _insertNote(controller);
      final Color elementColor = Color(note.color);

      controller.applyRemoteRemove(note.id);
      expect(controller.document.byId('p1', note.id), isNull, reason: '模型已删除');
      expect(controller.remoteFadeOuts, hasLength(1));

      // 初始帧：快照全量不透明。
      final Color full = await _pixelAt(_painter(controller), const Offset(90, 70));
      expect(_sameColor(full, elementColor), isTrue, reason: '淡出起始为全量快照');

      // 2 tick（0.08s / 0.15s）：半透明过渡（既非纯白也非原色）。
      hub.fire(_ghostTickInterval);
      hub.fire(_ghostTickInterval);
      final Color mid = await _pixelAt(_painter(controller), const Offset(90, 70));
      expect(_sameColor(mid, _canvasWhite, tolerance: 6), isFalse);
      expect(_sameColor(mid, elementColor, tolerance: 6), isFalse,
          reason: '中途应处于衰减混合态');

      // 再 2 tick（0.16s ≥ 0.15s）：过期移除，位置回落背景。
      hub.fire(_ghostTickInterval);
      hub.fire(_ghostTickInterval);
      expect(controller.remoteFadeOuts, isEmpty);
      expect(controller.hasRemoteOverlays, isFalse);
      final Color gone = await _pixelAt(_painter(controller), const Offset(90, 70));
      expect(_sameColor(gone, _canvasWhite), isTrue, reason: '淡出结束后回落背景');
    });
  });
}
