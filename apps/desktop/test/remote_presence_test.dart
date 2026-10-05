/// M2 在场层测试（T2f）：远端光标 / 选区仓库与覆盖层。
///
/// - 仓库：cursor / selection 帧消费（pageId 过滤 / 切页清空 / 空集合移除）、
///   500ms 缓动插值（从视觉位置续接）、5s 静置淡出、10s 超时清理、
///   哈希配色与短标签、坏载荷安全跳过；
/// - 覆盖层：IgnorePointer + 独立 Ticker 随条目启停、世界坐标换算落点
///   （像素采样）、卸载无挂起。
///
/// 时钟注入（[_FakeClock]）驱动插值 / 淡出 / 清理，不真实计时。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';
import 'package:whiteboard_desktop/widgets/collab/remote_cursors.dart';

/// 假时钟（测试推进插值 / 淡出 / 清理）。
class _FakeClock {
  DateTime _now = DateTime(2026, 9, 30, 12);

  DateTime now() => _now;

  void advance(Duration duration) => _now = _now.add(duration);
}

/// 构造 cursor 预览帧。
Map<String, dynamic> _cursor(
  String userId,
  double x,
  double y, {
  String? pageId,
}) =>
    <String, dynamic>{
      'kind': 'cursor',
      'userId': userId,
      'x': x,
      'y': y,
      if (pageId != null) 'pageId': pageId,
    };

/// 构造 selection 预览帧。
Map<String, dynamic> _selection(
  String userId,
  List<String> ids, {
  String? pageId,
}) =>
    <String, dynamic>{
      'kind': 'selection',
      'userId': userId,
      'elementIds': ids,
      if (pageId != null) 'pageId': pageId,
    };

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

/// 采样 RGBA 图像像素。
Color _pixelAt(ByteData bytes, int width, int x, int y) {
  final int offset = (y * width + x) * 4;
  return Color.fromARGB(
    bytes.getUint8(offset + 3),
    bytes.getUint8(offset),
    bytes.getUint8(offset + 1),
    bytes.getUint8(offset + 2),
  );
}

void main() {
  // ---- 仓库：消费 / 过滤 / 切页 --------------------------------------------

  group('在场仓库', () {
    test('cursor / selection 消费：pageId 过滤 + 切页清空', () {
      final _FakeClock clock = _FakeClock();
      final WbRemotePresenceStore store =
          WbRemotePresenceStore(clock: clock.now);
      addTearDown(store.dispose);

      store.handlePreviews(
        <dynamic>[
          _cursor('u1', 1, 2),
          _selection('u2', <String>['a']),
        ],
        pageId: 'p1',
      );
      expect(store.pageId, 'p1');
      expect(store.cursors, hasLength(1));
      expect(store.selections, hasLength(1));
      expect(store.hasEntries, isTrue);

      // 非当前页帧丢弃（不新增）。
      store.handlePreviews(
        <dynamic>[
          _cursor('u3', 5, 6, pageId: 'p2'),
          _selection('u3', <String>['b'], pageId: 'p2'),
        ],
        pageId: 'p1',
      );
      expect(store.cursors, hasLength(1));
      expect(store.selections, hasLength(1));

      // 无 pageId 帧放行（兼容旧载荷）。
      store.handlePreviews(<dynamic>[_cursor('u3', 5, 6)], pageId: 'p1');
      expect(store.cursors, hasLength(2));

      // 切页：非当前页残留清空。
      store.handlePreviews(const <dynamic>[], pageId: 'p2');
      expect(store.pageId, 'p2');
      expect(store.cursors, isEmpty);
      expect(store.selections, isEmpty);
      expect(store.hasEntries, isFalse);
    });

    test('跨板同页序放行（M3 D3-0）：cursor / selection 帧不再被误丢弃', () {
      final _FakeClock clock = _FakeClock();
      final WbRemotePresenceStore store =
          WbRemotePresenceStore(clock: clock.now);
      addTearDown(store.dispose);

      // 发送端本地板 id 命名空间（boardA-page-1）→ 本机 boardB-page-1：
      // 同页序 → cursor / selection 均消费。
      store.handlePreviews(
        <dynamic>[
          _cursor('u1', 1, 2, pageId: 'boardA-page-1'),
          _selection('u2', <String>['a'], pageId: 'boardA-page-1'),
        ],
        pageId: 'boardB-page-1',
      );
      expect(store.cursors, hasLength(1));
      expect(store.selections, hasLength(1));

      // 跨页（页序不同）：仍丢弃。
      store.handlePreviews(
        <dynamic>[
          _cursor('u3', 3, 4, pageId: 'boardA-page-2'),
          _selection('u3', <String>['b'], pageId: 'boardA-page-2'),
        ],
        pageId: 'boardB-page-1',
      );
      expect(store.cursors, hasLength(1));
      expect(store.selections, hasLength(1));
    });

    test('光标插值：500ms easeOutCubic（视觉位置续接，不跳跃）', () {
      final _FakeClock clock = _FakeClock();
      final WbRemotePresenceStore store =
          WbRemotePresenceStore(clock: clock.now);
      addTearDown(store.dispose);

      store.handlePreviews(<dynamic>[_cursor('u1', 0, 0)], pageId: 'p1');
      final WbRemoteCursorState cursor = store.cursors.single;
      expect(cursor.positionAt(clock.now()), Offset.zero);

      // 200ms 后重定向 (100,0)：段起点 = 当前视觉位置 (0,0)。
      clock.advance(const Duration(milliseconds: 200));
      store.handlePreviews(<dynamic>[_cursor('u1', 100, 0)], pageId: 'p1');
      expect(cursor.target, const Offset(100, 0));

      // 段内 +250ms（t = 0.5）：eased = 1 - 0.5³ = 0.875 → x = 87.5。
      clock.advance(const Duration(milliseconds: 250));
      expect(cursor.positionAt(clock.now()).dx, closeTo(87.5, 0.01));

      // 段中途（t = 0.6）再次重定向：瞬间位置连续（从视觉位置出发）。
      clock.advance(const Duration(milliseconds: 50));
      final Offset at = cursor.positionAt(clock.now());
      expect(at.dx, closeTo(100 * (1 - 0.4 * 0.4 * 0.4), 0.01)); // 93.6
      store.handlePreviews(<dynamic>[_cursor('u1', 200, 0)], pageId: 'p1');
      expect(cursor.positionAt(clock.now()), at);

      // 段结束（t ≥ 1）：停在目标。
      clock.advance(const Duration(milliseconds: 500));
      expect(cursor.positionAt(clock.now()), const Offset(200, 0));
    });

    test('静置淡出：5s 内恒 1 → 2s 线性 → 10s 清理（frameTick 自停）', () {
      final _FakeClock clock = _FakeClock();
      final WbRemotePresenceStore store =
          WbRemotePresenceStore(clock: clock.now);
      addTearDown(store.dispose);

      store.handlePreviews(<dynamic>[_cursor('u1', 0, 0)], pageId: 'p1');
      final WbRemoteCursorState cursor = store.cursors.single;

      double alpha() => cursor.alphaAt(
            clock.now(),
            idleFadeAfter: store.idleFadeAfter,
            fadeDuration: store.fadeDuration,
          );

      clock.advance(const Duration(seconds: 5));
      expect(alpha(), 1); // 边界：5s 整仍不淡出
      clock.advance(const Duration(seconds: 1));
      expect(alpha(), closeTo(0.5, 0.01)); // 6s → 半透明
      clock.advance(const Duration(seconds: 1));
      expect(alpha(), 0); // 7s → 完全透明

      // 清理：10s（>= cleanupAfter）前保留，之后移除并返回 false。
      clock.advance(const Duration(seconds: 2, milliseconds: 900));
      expect(store.frameTick(), isTrue);
      expect(store.cursors, hasLength(1));
      clock.advance(const Duration(milliseconds: 100));
      expect(store.frameTick(), isFalse);
      expect(store.cursors, isEmpty);
      expect(store.hasEntries, isFalse);
    });

    test('选区：整体替换 / 空集合移除 / 过期清理', () {
      final _FakeClock clock = _FakeClock();
      final WbRemotePresenceStore store =
          WbRemotePresenceStore(clock: clock.now);
      addTearDown(store.dispose);

      store.handlePreviews(
        <dynamic>[_selection('u1', <String>['a', 'b'])],
        pageId: 'p1',
      );
      expect(store.selections.single.elementIds, <String>['a', 'b']);

      clock.advance(const Duration(seconds: 1));
      store.handlePreviews(
        <dynamic>[_selection('u1', <String>['c'])],
        pageId: 'p1',
      );
      final WbRemoteSelectionState selection = store.selections.single;
      expect(selection.elementIds, <String>['c']);
      expect(
        selection.alphaAt(
          clock.now(),
          idleFadeAfter: store.idleFadeAfter,
          fadeDuration: store.fadeDuration,
        ),
        1,
      ); // 更新后回到不透明

      // 空集合 = 取消选中 → 移除条目。
      store.handlePreviews(
        <dynamic>[_selection('u1', const <String>[])],
        pageId: 'p1',
      );
      expect(store.selections, isEmpty);

      // 过期清理与光标同口径。
      clock.advance(const Duration(seconds: 2));
      store.handlePreviews(<dynamic>[_selection('u9', <String>['x'])],
          pageId: 'p1');
      expect(store.selections, hasLength(1));
      clock.advance(const Duration(seconds: 10));
      expect(store.frameTick(), isFalse);
      expect(store.selections, isEmpty);
    });

    test('坏载荷：缺 userId / 坏坐标 / 非 Map 安全跳过', () {
      final _FakeClock clock = _FakeClock();
      final WbRemotePresenceStore store =
          WbRemotePresenceStore(clock: clock.now);
      addTearDown(store.dispose);

      store.handlePreviews(<dynamic>[
        null,
        42,
        'text',
        <String, dynamic>{'kind': 'cursor', 'x': 1, 'y': 2}, // 缺 userId
        <String, dynamic>{
          'kind': 'cursor',
          'userId': 'u1',
          'x': 'bad',
          'y': 0,
        }, // 坏坐标
        <String, dynamic>{
          'kind': 'selection',
          'userId': 'u2',
          'elementIds': 'nope',
        }, // 非列表
        <String, dynamic>{'kind': 'ink', 'strokeId': 's1'},
      ], pageId: 'p1');

      expect(store.hasEntries, isFalse);
    });

    test('配色与标签：哈希稳定 / 空 id 收敛', () {
      expect(WbRemotePresenceStore.colorFor(''), const Color(0xFF6B7280));
      final Color a = WbRemotePresenceStore.colorFor('user-alpha');
      expect(WbRemotePresenceStore.colorFor('user-alpha'), a); // 稳定
      expect(a.a, 1.0); // 不透明
      expect(WbRemotePresenceStore.colorFor('user-beta') == a, isFalse);

      expect(WbRemotePresenceStore.labelFor(''), '成员');
      expect(WbRemotePresenceStore.labelFor('abc'), '成员 abc');
      expect(WbRemotePresenceStore.labelFor('peer-123456'), '成员 123456');
    });
  });

  // ---- 覆盖层（widget） ----------------------------------------------------

  testWidgets('覆盖层：Ticker 随条目启停 + 世界坐标换算落点 + 卸载无挂起', (
    WidgetTester tester,
  ) async {
    final _FakeClock clock = _FakeClock();
    final WbRemotePresenceStore store =
        WbRemotePresenceStore(clock: clock.now);
    addTearDown(store.dispose);
    final WbCanvasController controller = WbCanvasController();
    addTearDown(controller.dispose);
    controller
      ..setPage('p1')
      ..panBy(const Offset(40, 20));

    // 画布元素：供他人选区绘制（冒烟）。
    final WbCanvasElement note = controller.insertElements(<WbElementSpec>[
      const WbElementSpec(
        type: WbElementKind.note,
        size: Size(100, 50),
        position: Offset(200, 10),
      ),
    ]).single;

    const Key boundaryKey = ValueKey<String>('presence-boundary');
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: 400,
              height: 300,
              child: Stack(
                children: <Widget>[
                  WbRemoteCursorsOverlay(store: store, controller: controller),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(WbRemoteCursorsOverlay), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0); // 空仓库：零帧开销

    // 注入光标 / 选区帧 → Ticker 启动。
    store.handlePreviews(
      <dynamic>[
        _cursor('u1', 100, 60),
        _selection('u2', <String>[note.id]),
      ],
      pageId: 'p1',
    );
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 16));

    // 像素：世界 (100,60) 经 panBy(40,20) → 屏幕 (140,80)；箭头内部
    // （相对原点 +2,+4）应为主色填充（白描边在内侧 1.25px 之外）。
    final Color expected = store.cursors.single.color;
    final ui.Image image = (await tester.runAsync(() async {
      final RenderRepaintBoundary boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
      return boundary.toImage(pixelRatio: 1.0);
    }))!;
    final ByteData? rawBytes = await tester.runAsync<ByteData?>(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    final ByteData bytes = rawBytes!;
    final Color sampled = _pixelAt(bytes, image.width, 142, 84);
    expect(_sameColor(sampled, expected), isTrue,
        reason: '箭头填充应为用户色（采样 $sampled / 期望 $expected）');
    image.dispose();

    // 时钟推进 10s → 下一帧清理全部条目 → Ticker 自停。
    clock.advance(const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 16));
    expect(store.hasEntries, isFalse);
    expect(tester.binding.transientCallbackCount, 0);

    // 卸载（Ticker 已停；dispose 路径无异常）。
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
