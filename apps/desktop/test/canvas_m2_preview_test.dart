/// M2 画布高频预览测试（T2f）：
/// - 出口：笔迹两阶段（预生成 id / 33ms 增量节流 / DP 抽稀）、transform
///   目标几何（33ms）、光标（50ms）、选区（100ms）、擦除逐批（100ms）；
/// - 入口：远端 ink / transform 鬼影（pageId 过滤 / 终态清除 / finalized
///   丢帧 / TTL 淡出 / 删除淡出）；
/// - 零开销守卫：未注入出口回调时手势不创建定时器。
///
/// 节流器使用可注入的一次性定时器工厂（[_TimerHub]）手动驱动，不真实计时。
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/state/selection_state.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';

/// 手动一次性定时器（记录间隔与取消状态；tick 由测试驱动）。
class _ManualTimer implements Timer {
  _ManualTimer(this.interval, this._onTick);

  /// 创建时记录的节流窗口（驱动时按间隔定位）。
  final Duration interval;
  final void Function() _onTick;
  bool _cancelled = false;
  int firedCount = 0;

  bool get cancelled => _cancelled;

  @override
  bool get isActive => !_cancelled;

  @override
  int get tick => 0;

  /// 手动触发一次回调（已取消时忽略；一次性定时器触发后即失效，
  /// 与真实 `Timer` 语义一致——供「时钟停止」断言使用）。
  void fire() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    firedCount++;
    _onTick();
  }

  @override
  void cancel() {
    _cancelled = true;
  }
}

/// 一次性定时器工厂：捕获全部创建的定时器，供测试按间隔驱动。
class _TimerHub {
  final List<_ManualTimer> timers = <_ManualTimer>[];

  Timer create(Duration interval, void Function() onTick) {
    final _ManualTimer timer = _ManualTimer(interval, onTick);
    timers.add(timer);
    return timer;
  }

  /// 最近创建且未取消的指定间隔定时器。
  _ManualTimer? lastActive(Duration interval) {
    for (int i = timers.length - 1; i >= 0; i--) {
      final _ManualTimer timer = timers[i];
      if (!timer.cancelled && timer.interval == interval) {
        return timer;
      }
    }
    return null;
  }

  /// 驱动最近一个未取消的指定间隔定时器（无则忽略）。
  void fire(Duration interval) => lastActive(interval)?.fire();
}

/// 笔迹 / 变换预览节流间隔（与控制器 `previewInterval` 一致）。
const Duration _previewInterval = Duration(milliseconds: 33);

/// 光标预览节流间隔（与控制器 `cursorInterval` 一致）。
const Duration _cursorInterval = Duration(milliseconds: 50);

/// 选区 / 擦除批次节流间隔（与控制器 `selectionInterval` 一致）。
const Duration _batchInterval = Duration(milliseconds: 100);

/// 远端鬼影时钟 tick 间隔（与控制器 `_previewTickInterval` 一致）。
const Duration _ghostTickInterval = Duration(milliseconds: 40);

WbCanvasController _controller(_TimerHub hub, {WbSelectionState? selection}) =>
    WbCanvasController(selection: selection, previewTimerFactory: hub.create);

void main() {
  // ---- 出口：笔迹两阶段 ----------------------------------------------------

  group('笔迹两阶段出口', () {
    test('pen 按下即发首帧（预生成 id）；抬笔终态同 id 走 op', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      final List<Map<String, dynamic>> previews = <Map<String, dynamic>>[];
      final List<WbCanvasCommitBatch> batches = <WbCanvasCommitBatch>[];
      controller
        ..setPage('p1')
        ..onInkPreview = previews.add
        ..onLocalCommit = batches.add
        ..setTool(WbCanvasTool.pen);

      controller.handlePointerDown(1, const Offset(100, 100), shift: false);

      expect(previews, hasLength(1)); // 首沿立即交付
      final Map<String, dynamic> first = previews.single;
      expect(first['kind'], 'ink');
      expect(first['pageId'], 'p1');
      final String strokeId = first['strokeId'] as String;
      expect(strokeId, isNotEmpty);
      expect(first['points'], <dynamic>[
        <double>[100.0, 100.0],
      ]);
      expect(first['highlight'], isFalse);
      final Map<String, dynamic> style =
          first['style'] as Map<String, dynamic>;
      expect(style['color'], WbCanvasPalette.penColors.first);
      expect(style['width'], WbCanvasPalette.penWidths[1]);

      controller.handlePointerMove(1, const Offset(140, 100));
      expect(previews, hasLength(1)); // 窗口内抑制
      expect(controller.canUndo, isFalse); // 绘制中不入撤销栈

      hub.fire(_previewInterval); // 尾沿补发
      expect(previews, hasLength(2));
      expect(previews[1]['strokeId'], strokeId);
      expect(previews[1]['points'], <dynamic>[
        <double>[140.0, 100.0],
      ]); // 增量：仅未发送区间

      controller.handlePointerUp(1, const Offset(140, 100));

      expect(batches, hasLength(1));
      final WbCanvasElement terminal = batches.single.upserts.single;
      expect(terminal.id, strokeId); // 终态 id = 预览预生成 id
      expect(terminal.type, WbElementKind.drawing);
      expect(controller.canUndo, isTrue);
      expect(controller.elements.single.id, strokeId);
    });

    test('highlighter：highlight 标记与固定线宽 / 颜色', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      final List<Map<String, dynamic>> previews = <Map<String, dynamic>>[];
      final List<WbCanvasCommitBatch> batches = <WbCanvasCommitBatch>[];
      controller
        ..onInkPreview = previews.add
        ..onLocalCommit = batches.add
        ..setTool(WbCanvasTool.highlighter);

      controller.handlePointerDown(2, const Offset(0, 0), shift: false);
      final Map<String, dynamic> preview = previews.single;
      expect(preview['highlight'], isTrue);
      final Map<String, dynamic> style =
          preview['style'] as Map<String, dynamic>;
      expect(style['width'], 14);
      expect(style['color'], WbCanvasPalette.highlightColor);

      controller.handlePointerMove(2, const Offset(60, 0));
      controller.handlePointerUp(2, const Offset(60, 0));

      final WbCanvasElement terminal = batches.single.upserts.single;
      expect(terminal.strokeWidth, 14);
      expect(terminal.color, WbCanvasPalette.highlightColor);
    });

    test('33ms 窗口合并：窗口内多次移动仅尾沿补发一次（全量增量）', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      final List<Map<String, dynamic>> previews = <Map<String, dynamic>>[];
      final List<WbCanvasCommitBatch> batches = <WbCanvasCommitBatch>[];
      controller
        ..onInkPreview = previews.add
        ..onLocalCommit = batches.add
        ..setTool(WbCanvasTool.pen);

      controller.handlePointerDown(1, const Offset(0, 0), shift: false);
      controller.handlePointerMove(1, const Offset(10, 0));
      controller.handlePointerMove(1, const Offset(20, 0));
      controller.handlePointerMove(1, const Offset(30, 0));
      controller.handlePointerMove(1, const Offset(40, 0));
      expect(previews, hasLength(1)); // 全部落在同一窗口

      hub.fire(_previewInterval);
      expect(previews, hasLength(2));
      expect(previews[1]['points'], <dynamic>[
        <double>[10.0, 0.0],
        <double>[20.0, 0.0],
        <double>[30.0, 0.0],
        <double>[40.0, 0.0],
      ]);

      hub.fire(_previewInterval); // 无新点：窗口自然关闭，不再补发
      expect(previews, hasLength(2));

      controller.handlePointerUp(1, const Offset(40, 0));
      // 落定前 DP 抽稀：近直线点集压缩到首尾。
      expect(batches.single.upserts.single.points.length, 2);
    });

    test('DP 抽稀：公差内近直线点丢弃、保留首尾（世界坐标 0.75）', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      final List<WbCanvasCommitBatch> batches = <WbCanvasCommitBatch>[];
      controller
        ..onLocalCommit = batches.add
        ..setTool(WbCanvasTool.pen);

      controller.handlePointerDown(1, Offset.zero, shift: false);
      controller.handlePointerMove(1, const Offset(10, 0.3));
      controller.handlePointerMove(1, const Offset(20, -0.4));
      controller.handlePointerMove(1, const Offset(30, 0.2));
      controller.handlePointerMove(1, const Offset(40, 0.5));
      controller.handlePointerMove(1, const Offset(50, -0.3));
      controller.handlePointerMove(1, const Offset(60, 0));
      controller.handlePointerUp(1, const Offset(60, 0));

      final WbCanvasElement terminal = batches.single.upserts.single;
      expect(terminal.points, <Offset>[Offset.zero, const Offset(60, 0)]);
    });
  });

  // ---- 出口：transform 预览 -------------------------------------------------

  group('transform 预览出口', () {
    test('move 拖动：33ms 节流发目标几何；落定走既有终态 op', () {
      final _TimerHub hub = _TimerHub();
      final WbSelectionState selection = WbSelectionState();
      addTearDown(selection.dispose);
      final WbCanvasController controller =
          _controller(hub, selection: selection);
      addTearDown(controller.dispose);
      final List<Map<String, dynamic>> previews = <Map<String, dynamic>>[];
      final List<WbCanvasCommitBatch> batches = <WbCanvasCommitBatch>[];
      controller
        ..setPage('p1')
        ..onTransformPreview = previews.add
        ..onLocalCommit = batches.add;

      final WbCanvasElement note = controller.insertElements(<WbElementSpec>[
        const WbElementSpec(
          type: WbElementKind.note,
          size: Size(120, 80),
          position: Offset(100, 100),
        ),
      ]).single;
      batches.clear(); // 插入批次不属本用例断言（仅看移动落定批次）。

      controller.handlePointerDown(1, const Offset(150, 140), shift: false);
      expect(previews, isEmpty); // 按下不产生几何变化

      controller.handlePointerMove(1, const Offset(180, 140)); // +30
      expect(previews, hasLength(1)); // 首沿立即
      final Map<String, dynamic> first = previews.single;
      expect(first['kind'], 'transform');
      expect(first['elementId'], note.id);
      expect(first['pageId'], 'p1');
      expect(first['x'], 130.0);
      expect(first['y'], 100.0);
      expect(first['w'], 120.0);
      expect(first['h'], 80.0);

      controller.handlePointerMove(1, const Offset(230, 190)); // +50,+50
      expect(previews, hasLength(1)); // 窗口内抑制

      hub.fire(_previewInterval);
      expect(previews, hasLength(2));
      expect(previews[1]['x'], 180.0);
      expect(previews[1]['y'], 150.0);

      controller.handlePointerUp(1, const Offset(230, 190));
      expect(batches.single.upserts.single.x, 180.0);
      expect(batches.single.upserts.single.y, 150.0);
    });

    test('scale 缩放：目标宽高帧（同帧内元素逐条）', () {
      final _TimerHub hub = _TimerHub();
      final WbSelectionState selection = WbSelectionState();
      addTearDown(selection.dispose);
      final WbCanvasController controller =
          _controller(hub, selection: selection);
      addTearDown(controller.dispose);
      final List<Map<String, dynamic>> previews = <Map<String, dynamic>>[];
      controller
        ..setPage('p1')
        ..onTransformPreview = previews.add;

      controller.insertElements(<WbElementSpec>[
        const WbElementSpec(
          type: WbElementKind.note,
          size: Size(120, 80),
          position: Offset(100, 100),
        ),
      ]);
      final Rect bounds = controller.selectionBounds!;
      final Offset handle = WbCanvasController.handlePosition(
        WbSelectionHandle.bottomRight,
        controller.worldRectToScreen(bounds),
      );

      controller.handlePointerDown(3, handle, shift: false);
      controller.handlePointerMove(3, handle + const Offset(50, 30));
      expect(previews, hasLength(1));
      expect(previews.single['w'], 170.0);
      expect(previews.single['h'], 110.0);

      controller.handlePointerMove(3, handle + const Offset(90, 50));
      expect(previews, hasLength(1));
      hub.fire(_previewInterval);
      expect(previews, hasLength(2));
      expect(previews[1]['w'], 210.0);
      expect(previews[1]['h'], 130.0);

      controller.handlePointerUp(3, handle + const Offset(90, 50));
    });

    test('帧上限：同帧最多 maxTransformPreviews 条（保序截断）', () {
      final _TimerHub hub = _TimerHub();
      final WbSelectionState selection = WbSelectionState();
      addTearDown(selection.dispose);
      final WbCanvasController controller =
          _controller(hub, selection: selection);
      addTearDown(controller.dispose);
      final List<Map<String, dynamic>> previews = <Map<String, dynamic>>[];
      controller
        ..setPage('p1')
        ..onTransformPreview = previews.add;

      controller.insertElements(<WbElementSpec>[
        for (int i = 0; i < 13; i++)
          WbElementSpec(
            type: WbElementKind.note,
            size: const Size(60, 40),
            position: Offset(40 + i * 30, 40 + i * 30),
          ),
      ]);

      controller.handlePointerDown(1, const Offset(60, 60), shift: false);
      controller.handlePointerMove(1, const Offset(80, 80));

      expect(previews, hasLength(WbCanvasController.maxTransformPreviews));
    });
  });

  // ---- 出口：光标 / 选区 ----------------------------------------------------

  group('光标与选区出口', () {
    test('hover 50ms 节流：世界坐标换算 + 首沿 / 尾沿', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      final List<Map<String, dynamic>> previews = <Map<String, dynamic>>[];
      controller
        ..onCursorMoved = previews.add
        ..panBy(const Offset(40, 20));

      controller.handlePointerHover(const Offset(140, 120)); // world (100,100)
      expect(previews, hasLength(1));
      expect(previews.single['kind'], 'cursor');
      expect(previews.single['pageId'], controller.pageId);
      expect(previews.single['x'], 100.0);
      expect(previews.single['y'], 100.0);

      controller.handlePointerHover(const Offset(240, 220)); // world (200,200)
      expect(previews, hasLength(1)); // 窗口内抑制

      hub.fire(_cursorInterval);
      expect(previews, hasLength(2));
      expect(previews[1]['x'], 200.0);
      expect(previews[1]['y'], 200.0);
    });

    test('选区 100ms 节流：含清空；尾沿交付最新集合', () {
      final _TimerHub hub = _TimerHub();
      final WbSelectionState selection = WbSelectionState();
      addTearDown(selection.dispose);
      final WbCanvasController controller =
          _controller(hub, selection: selection);
      addTearDown(controller.dispose);
      final List<Map<String, dynamic>> previews = <Map<String, dynamic>>[];
      controller
        ..setPage('p1')
        ..onSelectionChanged = previews.add;

      selection.select(<String>['a']);
      expect(previews, hasLength(1));
      expect(previews.single['kind'], 'selection');
      expect(previews.single['pageId'], 'p1');
      expect(previews.single['elementIds'], <String>['a']);

      selection.select(<String>['a', 'b']);
      selection.clear(); // pending 覆盖为最近一次
      expect(previews, hasLength(1));

      hub.fire(_batchInterval);
      expect(previews, hasLength(2));
      expect(previews[1]['elementIds'], isEmpty); // 清空同样外发
    });
  });

  // ---- 零开销守卫 -----------------------------------------------------------

  test('未注入出口回调：手势 / 悬停 / 选区零定时器开销', () {
    final _TimerHub hub = _TimerHub();
    final WbSelectionState selection = WbSelectionState();
    addTearDown(selection.dispose);
    final WbCanvasController controller =
        _controller(hub, selection: selection);
    addTearDown(controller.dispose);

    controller.insertElements(<WbElementSpec>[
      const WbElementSpec(
        type: WbElementKind.note,
        size: Size(120, 80),
        position: Offset(100, 100),
      ),
    ]);

    // 笔迹。
    controller
      ..setTool(WbCanvasTool.pen)
      ..handlePointerDown(1, const Offset(0, 0), shift: false)
      ..handlePointerMove(1, const Offset(30, 0))
      ..handlePointerUp(1, const Offset(30, 0));
    // 变换。
    controller
      ..setTool(WbCanvasTool.select)
      ..handlePointerDown(2, const Offset(150, 140), shift: false)
      ..handlePointerMove(2, const Offset(200, 140))
      ..handlePointerUp(2, const Offset(200, 140));
    // 光标 / 选区。
    controller.handlePointerHover(const Offset(10, 10));
    selection.select(<String>['x']);
    // 擦除。
    controller
      ..setTool(WbCanvasTool.eraser)
      ..handlePointerDown(3, const Offset(150, 140), shift: false)
      ..handlePointerUp(3, const Offset(150, 140));

    expect(hub.timers, isEmpty);
  });

  // ---- 入口：远端预览（鬼影） -----------------------------------------------

  group('远端预览入口', () {
    Map<String, dynamic> inkFrame(
      String strokeId,
      List<List<double>> points, {
      String? pageId,
      int color = 0xFF112233,
      double width = 3,
    }) =>
        <String, dynamic>{
          'kind': 'ink',
          'strokeId': strokeId,
          'pageId': pageId,
          'points': points,
          'style': <String, dynamic>{'color': color, 'width': width},
          'highlight': false,
        };

    test('ink 帧：按 strokeId 建鬼影并累积增量点（样式解析）', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      controller.setPage('p1');

      controller.applyRemotePreviews(<dynamic>[
        inkFrame(
          's1',
          <List<double>>[
            <double>[0, 0],
            <double>[10, 0],
          ],
          pageId: 'p1',
        ),
      ]);

      final WbRemoteInkGhost ghost = controller.remoteInkGhosts.single;
      expect(ghost.strokeId, 's1');
      expect(ghost.points, <Offset>[Offset.zero, const Offset(10, 0)]);
      expect(ghost.color, 0xFF112233);
      expect(ghost.strokeWidth, 3);
      expect(ghost.highlight, isFalse);
      expect(ghost.alpha, 1);
      expect(controller.hasRemoteOverlays, isTrue);

      controller.applyRemotePreviews(<dynamic>[
        inkFrame(
          's1',
          <List<double>>[
            <double>[10, 0],
            <double>[20, 0],
          ],
          pageId: 'p1',
        ),
      ]);
      expect(controller.remoteInkGhosts.single.points, hasLength(4));
    });

    test('样式缺省：深灰细线兜底；坏点跳过', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      controller.setPage('p1');

      controller.applyRemotePreviews(<dynamic>[
        <String, dynamic>{
          'kind': 'ink',
          'strokeId': 's1',
          'pageId': 'p1',
          'points': <dynamic>[
            <double>[0, 0],
            <dynamic>['bad', 0],
            <dynamic>[5],
            <double>[8, 8],
          ],
        },
      ]);

      final WbRemoteInkGhost ghost = controller.remoteInkGhosts.single;
      expect(ghost.color, 0xFF1F2933);
      expect(ghost.strokeWidth, 2);
      expect(ghost.points, <Offset>[Offset.zero, const Offset(8, 8)]);
    });

    test('终态 op 到达：清除鬼影并丢弃迟到帧（finalized 记忆）', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      controller.setPage('p1');

      controller.applyRemotePreviews(<dynamic>[
        inkFrame('s1', <List<double>>[
          <double>[0, 0],
        ], pageId: 'p1'),
      ]);
      expect(controller.remoteInkGhosts, hasLength(1));

      controller.applyRemoteElement(const WbCanvasElement(
        id: 's1',
        type: WbElementKind.drawing,
        x: 0,
        y: 0,
        width: 10,
        height: 2,
      ));
      expect(controller.remoteInkGhosts, isEmpty);
      expect(controller.hasRemoteOverlays, isFalse);

      // 迟到帧：终态 id 已记忆 → 丢弃。
      controller.applyRemotePreviews(<dynamic>[
        inkFrame('s1', <List<double>>[
          <double>[30, 0],
        ], pageId: 'p1'),
      ]);
      expect(controller.remoteInkGhosts, isEmpty);

      // 删除同样清除鬼影并记忆终态。
      controller.applyRemotePreviews(<dynamic>[
        inkFrame('s2', <List<double>>[
          <double>[0, 0],
        ], pageId: 'p1'),
      ]);
      controller.applyRemoteRemove('s2');
      expect(controller.remoteInkGhosts, isEmpty);
      controller.applyRemotePreviews(<dynamic>[
        inkFrame('s2', <List<double>>[
          <double>[40, 0],
        ], pageId: 'p1'),
      ]);
      expect(controller.remoteInkGhosts, isEmpty);
    });

    test('pageId 过滤：非当前页丢弃（无 pageId 帧放行）', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      controller.setPage('p1');

      controller.applyRemotePreviews(<dynamic>[
        inkFrame('s1', <List<double>>[
          <double>[0, 0],
        ], pageId: 'p2'),
        <String, dynamic>{
          'kind': 'transform',
          'elementId': 'e1',
          'pageId': 'p2',
          'x': 0,
          'y': 0,
          'w': 1,
          'h': 1,
        },
      ]);
      expect(controller.hasRemoteOverlays, isFalse); // 全部丢弃

      controller.applyRemotePreviews(<dynamic>[
        inkFrame('s1', <List<double>>[
          <double>[0, 0],
        ], pageId: 'p1'),
        inkFrame('s2', <List<double>>[
          <double>[0, 0],
        ]),
      ]);
      expect(controller.remoteInkGhosts, hasLength(2));
    });

    test('跨板同页序放行（M3 D3-0）：命名空间不同的 -page-1 帧不再被误丢弃', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      controller.setPage('boardB-page-1');

      final WbCanvasElement note = controller.insertElements(<WbElementSpec>[
        const WbElementSpec(
          type: WbElementKind.note,
          size: Size(120, 80),
          position: Offset(100, 100),
        ),
      ]).single;

      // 发送端本地板 id 命名空间（boardA-page-1）→ 本机 boardB-page-1：
      // 同页序 → ink 鬼影 / transform 叠加均接受。
      controller.applyRemotePreviews(<dynamic>[
        inkFrame(
          's1',
          <List<double>>[
            <double>[0, 0],
            <double>[10, 0],
          ],
          pageId: 'boardA-page-1',
        ),
        <String, dynamic>{
          'kind': 'transform',
          'elementId': note.id,
          'pageId': 'boardA-page-1',
          'x': 140,
          'y': 120,
          'w': 160,
          'h': 100,
        },
      ]);

      expect(controller.remoteInkGhosts, hasLength(1));
      expect(controller.hasRemoteOverlays, isTrue);
      final WbRemoteTransformOverlay? overlay =
          controller.remoteTransformOverlay(note);
      expect(overlay, isNotNull);
      expect(overlay!.element.bounds, const Rect.fromLTWH(140, 120, 160, 100));
    });

    test('跨页丢弃保留（M3 D3-0）：异页序 / 无可提取页序的帧仍丢弃', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      controller.setPage('boardB-page-1');

      controller.applyRemotePreviews(<dynamic>[
        inkFrame('s1', <List<double>>[
          <double>[0, 0],
        ], pageId: 'boardA-page-2'),
        inkFrame('s2', <List<double>>[
          <double>[0, 0],
        ], pageId: 'plain-room'),
      ]);

      expect(controller.hasRemoteOverlays, isFalse); // 全部丢弃
    });

    test('transform 帧：目标几何叠加（不落模型）；近似同几何返回 null', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      controller.setPage('p1');

      final WbCanvasElement note = controller.insertElements(<WbElementSpec>[
        const WbElementSpec(
          type: WbElementKind.note,
          size: Size(120, 80),
          position: Offset(100, 100),
        ),
      ]).single;

      controller.applyRemotePreviews(<dynamic>[
        <String, dynamic>{
          'kind': 'transform',
          'elementId': note.id,
          'pageId': 'p1',
          'x': 140,
          'y': 120,
          'w': 160,
          'h': 100,
        },
      ]);

      final WbCanvasElement element =
          controller.document.byId('p1', note.id)!;
      final WbRemoteTransformOverlay? overlay =
          controller.remoteTransformOverlay(element);
      expect(overlay, isNotNull);
      expect(
        overlay!.element.bounds,
        const Rect.fromLTWH(140, 120, 160, 100),
      );
      expect(overlay.alpha, 1);
      // 模型未被修改（仅绘制层叠加）。
      expect(element.bounds, const Rect.fromLTWH(100, 100, 120, 80));

      // 目标 ≈ 现行几何（< 0.5）：无需叠加。
      controller.applyRemotePreviews(<dynamic>[
        <String, dynamic>{
          'kind': 'transform',
          'elementId': note.id,
          'pageId': 'p1',
          'x': 100.2,
          'y': 100.1,
          'w': 120.2,
          'h': 80.2,
        },
      ]);
      expect(controller.remoteTransformOverlay(element), isNull);

      // 未知元素：忽略。
      controller.applyRemotePreviews(<dynamic>[
        <String, dynamic>{
          'kind': 'transform',
          'elementId': 'nope',
          'pageId': 'p1',
          'x': 0,
          'y': 0,
          'w': 10,
          'h': 10,
        },
      ]);
      expect(controller.remoteTransformOverlay(element), isNull);
    });

    test('ink 鬼影 TTL：5s 内恒 1，之后 1s 线性淡出并移除（40ms tick）', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      controller.setPage('p1');

      controller.applyRemotePreviews(<dynamic>[
        inkFrame('s1', <List<double>>[
          <double>[0, 0],
          <double>[10, 0],
        ], pageId: 'p1'),
      ]);

      for (int i = 0; i < 100; i++) {
        hub.fire(_ghostTickInterval); // 4s
      }
      expect(controller.remoteInkGhosts.single.alpha, 1);

      for (int i = 0; i < 40; i++) {
        hub.fire(_ghostTickInterval); // 累计 5.6s
      }
      expect(controller.remoteInkGhosts.single.alpha, closeTo(0.4, 0.05));

      for (int i = 0; i < 20; i++) {
        hub.fire(_ghostTickInterval); // 累计 6.4s ≥ 5 + 1
      }
      expect(controller.remoteInkGhosts, isEmpty);
      expect(controller.hasRemoteOverlays, isFalse);
      expect(hub.lastActive(_ghostTickInterval), isNull); // 时钟停止
    });

    test('删除淡出：快照保留并随 tick 线性衰减移除', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      controller.setPage('p1');

      final WbCanvasElement note = controller.insertElements(<WbElementSpec>[
        const WbElementSpec(
          type: WbElementKind.note,
          size: Size(120, 80),
          position: Offset(100, 100),
        ),
      ]).single;

      controller.applyRemoteRemove(note.id);

      expect(controller.document.byId('p1', note.id), isNull);
      final WbRemoteFadeOut fade = controller.remoteFadeOuts.single;
      expect(fade.element.id, note.id);
      expect(fade.alpha, 1);

      hub.fire(_ghostTickInterval); // 0.04s / 0.15s
      expect(fade.alpha, closeTo(1 - 0.04 / 0.15, 0.01));
      expect(controller.remoteFadeOuts, hasLength(1));

      hub.fire(_ghostTickInterval);
      hub.fire(_ghostTickInterval);
      hub.fire(_ghostTickInterval); // 累计 0.16s ≥ 0.15s
      expect(controller.remoteFadeOuts, isEmpty);
      expect(hub.lastActive(_ghostTickInterval), isNull);
    });

    test('坏载荷安全空转（非 Map / 缺 kind / cursor 帧不进画布层）', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      controller.setPage('p1');

      controller.applyRemotePreviews(<dynamic>[
        null,
        42,
        'text',
        <String, dynamic>{'kind': 'ink'},
        <String, dynamic>{'kind': 'cursor', 'x': 1, 'y': 2},
        <String, dynamic>{'kind': 'selection', 'elementIds': <String>['a']},
      ]);

      expect(controller.hasRemoteOverlays, isFalse);
    });
  });

  // ---- 出口：擦除逐批提交 ---------------------------------------------------

  group('擦除逐批提交', () {
    test('100ms 逐批 + 抬笔终态 flush；整段一个撤销单元', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      final List<WbCanvasCommitBatch> batches = <WbCanvasCommitBatch>[];
      controller
        ..setPage('p1')
        ..onLocalCommit = batches.add;

      final List<WbCanvasElement> created =
          controller.insertElements(<WbElementSpec>[
        const WbElementSpec(
          type: WbElementKind.note,
          size: Size(120, 80),
          position: Offset(100, 100),
        ),
        const WbElementSpec(
          type: WbElementKind.note,
          size: Size(120, 80),
          position: Offset(300, 100),
        ),
        const WbElementSpec(
          type: WbElementKind.note,
          size: Size(120, 80),
          position: Offset(500, 100),
        ),
      ]);
      controller.setTool(WbCanvasTool.eraser);

      batches.clear(); // 插入批次不属本用例断言（仅看擦除批次）。
      controller.handlePointerDown(9, const Offset(150, 140), shift: false);
      expect(batches, hasLength(1)); // 首沿立即：本批删除
      expect(batches.single.removedIds, <String>[created[0].id]);
      expect(batches.single.upserts, isEmpty);
      expect(controller.undoDepth, 1); // 中间批次不入撤销栈

      controller.handlePointerMove(9, const Offset(350, 140));
      controller.handlePointerMove(9, const Offset(550, 140));
      expect(batches, hasLength(1)); // 窗口内合并

      hub.fire(_batchInterval);
      expect(batches, hasLength(2));
      expect(batches[1].removedIds, <String>[created[1].id, created[2].id]);

      controller.handlePointerUp(9, const Offset(550, 140));
      expect(batches, hasLength(2)); // 终态 flush 无残余：不重复外发
      expect(controller.elements, isEmpty);
      expect(controller.undoDepth, 2); // 插入 1 步 + 擦除整段 1 步

      controller.undo();
      expect(controller.elements, hasLength(3)); // 一次撤销恢复整段
    });

    test('擦除跳过锁定元素（命中过滤）', () {
      final _TimerHub hub = _TimerHub();
      final WbCanvasController controller = _controller(hub);
      addTearDown(controller.dispose);
      final List<WbCanvasCommitBatch> batches = <WbCanvasCommitBatch>[];
      controller
        ..setPage('p1')
        ..onLocalCommit = batches.add;

      final List<WbCanvasElement> created =
          controller.insertElements(<WbElementSpec>[
        const WbElementSpec(
          type: WbElementKind.note,
          size: Size(120, 80),
          position: Offset(100, 100),
        ),
        const WbElementSpec(
          type: WbElementKind.note,
          size: Size(120, 80),
          position: Offset(300, 100),
        ),
      ]);
      controller
        ..refreshRemoteLocks(<String, String>{created[1].id: 'peer-42'})
        ..setTool(WbCanvasTool.eraser);

      batches.clear(); // 插入批次不属本用例断言（仅看擦除批次）。
      controller.handlePointerDown(9, const Offset(350, 140), shift: false);
      expect(controller.document.byId('p1', created[1].id), isNotNull);
      expect(batches, isEmpty);
      controller.handlePointerUp(9, const Offset(350, 140));

      controller.handlePointerDown(8, const Offset(150, 140), shift: false);
      expect(controller.document.byId('p1', created[0].id), isNull);
      expect(batches.single.removedIds, <String>[created[0].id]);
      controller.handlePointerUp(8, const Offset(150, 140));
    });
  });
}
