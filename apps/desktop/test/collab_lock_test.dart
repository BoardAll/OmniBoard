/// M2 软锁（D2-C）测试：
/// - 画布侧闸门：远端锁缓存刷新 / 命中过滤 / 文本编辑拒绝与请求释放 /
///   双击锁定提示（不复位视图）；
/// - 服务侧生命周期：acquire / release / renew 出口，回执消费（授予 /
///   被拒 / 续约失败），10s 续约定时器，reconnect，sendPreview 降级语义，
///   锁快照透传与重连预算判定。
///
/// fake 引擎的 `room.lockAcks` 为跨调用缓存（不 drain，仿真引擎语义）：
/// 回执被消费后需清空 `engine.room` 防重复消费（或断言幂等）。
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';

import 'support/fake_collab_engine.dart';

/// 服务 + fake 引擎 + 轮询 / 续约手动定时器装配。
class _ServiceHarness {
  _ServiceHarness() {
    service = WbCollabService(
      engine: engine,
      sleep: (Duration _) async {},
      pollTimerFactory: pollTimers.create,
      renewTimerFactory: renewTimers.create,
      actorGenerator: () => 'wb-test-actor',
      clock: () => DateTime(2026, 9, 30, 12),
    );
  }

  final FakeCollabEngine engine = FakeCollabEngine();
  final FakePollTimerFactory pollTimers = FakePollTimerFactory();
  final FakePollTimerFactory renewTimers = FakePollTimerFactory();
  late final WbCollabService service;
}

/// 构造锁回执载荷（服务端 `lock:acquired/released` 归一形状）。
Map<String, dynamic> _ack(
  String elementId,
  String action, {
  bool ok = true,
  bool granted = true,
  String? holder,
}) =>
    <String, dynamic>{
      'elementId': elementId,
      'action': action,
      'ok': ok,
      'granted': granted,
      if (holder != null) 'holderUserId': holder,
      'expiresAt': 1000,
    };

/// 授予指定元素锁：写入回执 → 驱动一次轮询消费。
void _grant(_ServiceHarness h, String elementId, {String action = 'acquire'}) {
  h.engine.room = WbSyncRoomData(
    lockAcks: <dynamic>[_ack(elementId, action)],
    selfUserId: 'me',
  );
  h.pollTimers.fire();
}

WbCanvasController _controller() => WbCanvasController();

/// 在 (100,100) 处插入 120x80 的便签（中心 (160,140)）。
WbCanvasElement _insertNote(WbCanvasController controller) =>
    controller.insertElements(<WbElementSpec>[
      const WbElementSpec(
        type: WbElementKind.note,
        size: Size(120, 80),
        position: Offset(100, 100),
      ),
    ]).single;

void main() {
  // ---- 画布侧闸门 ----------------------------------------------------------

  group('画布锁闸门（WbCanvasController）', () {
    test('refreshRemoteLocks：查询 / 同值去抖 / 空持有者视为无锁', () {
      final WbCanvasController controller = _controller();
      addTearDown(controller.dispose);
      int notified = 0;
      controller.addListener(() => notified++);

      controller.refreshRemoteLocks(<String, String>{'e1': 'user-1'});
      expect(notified, 1);
      expect(controller.remoteLocks, <String, String>{'e1': 'user-1'});
      expect(controller.isLockedByOther('e1'), isTrue);
      expect(controller.lockHolderOf('e1'), 'user-1');

      controller.refreshRemoteLocks(<String, String>{'e1': 'user-1'});
      expect(notified, 1, reason: '同值刷新不通知（避免每 tick 重绘）');

      controller.refreshRemoteLocks(<String, String>{'e1': 'user-2'});
      expect(notified, 2);
      expect(controller.lockHolderOf('e1'), 'user-2');

      controller.refreshRemoteLocks(<String, String>{'e2': ''});
      expect(controller.isLockedByOther('e2'), isFalse, reason: '空持有者归一为无锁');

      controller.refreshRemoteLocks(const <String, String>{});
      expect(controller.isLockedByOther('e1'), isFalse);
      expect(controller.lockHolderOf('e1'), isNull);
      expect(controller.remoteLocks, isEmpty);
    });

    test('beginTextEditing：远端锁拒绝并提示；解锁后进入请求锁，退出释放', () {
      final WbCanvasController controller = _controller();
      addTearDown(controller.dispose);
      controller.setPage('p1');
      final WbCanvasElement note = _insertNote(controller);

      final List<String> lockedTapIds = <String>[];
      final List<String> requests = <String>[];
      final List<String> releases = <String>[];
      controller
        ..onLockedElementTap = (WbCanvasElement e) {
          lockedTapIds.add(e.id);
        }
        ..onEditLockRequest = requests.add
        ..onEditLockRelease = releases.add;

      controller.refreshRemoteLocks(<String, String>{note.id: 'user-7'});
      controller.beginTextEditing(note.id);

      expect(lockedTapIds, <String>[note.id], reason: '锁定元素提示不进入编辑');
      expect(controller.editingElementId, isNull);
      expect(requests, isEmpty, reason: '拒绝路径不请求锁');

      controller.refreshRemoteLocks(const <String, String>{});
      controller.beginTextEditing(note.id);

      expect(controller.editingElementId, note.id);
      expect(requests, <String>[note.id], reason: '进入编辑请求软锁');

      controller.endTextEditing();
      expect(controller.editingElementId, isNull);
      expect(releases, <String>[note.id], reason: '退出编辑释放软锁');
    });

    test('hitTestElement：默认过滤远端锁；ignoreRemoteLocks 可反查', () {
      final WbCanvasController controller = _controller();
      addTearDown(controller.dispose);
      controller.setPage('p1');
      final WbCanvasElement note = _insertNote(controller);

      const Offset hit = Offset(160, 140);
      expect(controller.hitTestElement(hit)?.id, note.id);

      controller.refreshRemoteLocks(<String, String>{note.id: 'user-8'});
      expect(controller.hitTestElement(hit), isNull, reason: '锁定元素不可交互');
      expect(
        controller.hitTestElement(hit, ignoreRemoteLocks: true)?.id,
        note.id,
      );
    });

    test('handleDoubleClick：命中锁定元素 → onLockedElementTap 且不复位视图', () {
      final WbCanvasController controller = _controller();
      addTearDown(controller.dispose);
      controller.setPage('p1');
      final WbCanvasElement note = _insertNote(controller);
      controller.refreshRemoteLocks(<String, String>{note.id: 'user-9'});
      controller.panBy(const Offset(40, 20));

      final List<String> lockedTapIds = <String>[];
      controller.onLockedElementTap =
          (WbCanvasElement e) => lockedTapIds.add(e.id);

      // 元素中心 (160,140) → 屏幕 (200,160)。
      controller.handleDoubleClick(const Offset(200, 160));

      expect(lockedTapIds, <String>[note.id]);
      expect(controller.editingElementId, isNull);
      expect(
        controller.offset,
        const Offset(40, 20),
        reason: '锁定提示路径不触发空白双击复位',
      );
    });
  });

  // ---- 服务侧锁生命周期 ----------------------------------------------------

  group('协同服务软锁（WbCollabService）', () {
    late _ServiceHarness h;

    setUp(() {
      h = _ServiceHarness();
      addTearDown(h.service.dispose);
    });

    test('acquire → 引擎出口；授予回执 → 持有 + 10s 续约启动；清空回执不掉持有',
        () async {
      await h.service.start(boardId: 'b1');

      final WbSyncLockResult result = h.service.acquireLock('e1');
      expect(result.requested, isTrue);
      expect(h.engine.lockCalls, <String>['acquire:e1']);
      expect(h.service.isHoldingLock('e1'), isFalse, reason: '回执前不持有');

      _grant(h, 'e1');
      expect(h.service.isHoldingLock('e1'), isTrue);
      expect(h.renewTimers.created, 1);
      expect(h.renewTimers.interval, WbCollabService.lockRenewInterval);

      // 回执重复消费幂等（fake 引擎不 drain；真实引擎逐调用清空）。
      h.engine.room = const WbSyncRoomData();
      h.pollTimers.fire();
      expect(h.service.isHoldingLock('e1'), isTrue);
    });

    test('acquire 被拒：onLockDenied 透传 holderUserId；无 holder 归 null',
        () async {
      await h.service.start(boardId: 'b1');
      final List<String> deniedIds = <String>[];
      final List<String?> deniedHolders = <String?>[];
      h.service.onLockDenied = (String id, String? holder) {
        deniedIds.add(id);
        deniedHolders.add(holder);
      };

      h.service.acquireLock('e1');
      h.engine.room = WbSyncRoomData(
        lockAcks: <dynamic>[
          _ack('e1', 'acquire', granted: false, holder: 'user-9'),
        ],
      );
      h.pollTimers.fire();

      expect(deniedIds, <String>['e1']);
      expect(deniedHolders, <String?>['user-9']);
      expect(h.service.isHoldingLock('e1'), isFalse);

      h.service.acquireLock('e2');
      h.engine.room = WbSyncRoomData(
        lockAcks: <dynamic>[_ack('e2', 'acquire', granted: false)],
      );
      h.pollTimers.fire();

      expect(deniedIds, <String>['e1', 'e2']);
      expect(deniedHolders, <String?>['user-9', null]);
    });

    test('续约周期：fire → renew 出口；renew 失败回执 → 丢失持有 + 停续约',
        () async {
      await h.service.start(boardId: 'b1');
      h.service.acquireLock('e1');
      _grant(h, 'e1');
      expect(h.service.isHoldingLock('e1'), isTrue);

      h.renewTimers.fire();
      expect(h.engine.lockCalls, contains('renew:e1'));

      h.engine.room = WbSyncRoomData(
        lockAcks: <dynamic>[_ack('e1', 'renew', ok: false, granted: false)],
      );
      h.pollTimers.fire();

      expect(h.service.isHoldingLock('e1'), isFalse, reason: '续约失败视为丢失');
      expect(h.renewTimers.lastTimer?.cancelled, isTrue);
    });

    test('releaseLock：立即清除 + 出口 release + 停续约（回执幂等）', () async {
      await h.service.start(boardId: 'b1');
      h.service.acquireLock('e1');
      _grant(h, 'e1');

      final WbSyncLockResult result = h.service.releaseLock('e1');
      expect(result.requested, isTrue);
      expect(h.service.isHoldingLock('e1'), isFalse, reason: '本端立即清除');
      expect(h.engine.lockCalls.last, 'release:e1');
      expect(h.renewTimers.lastTimer?.cancelled, isTrue);

      h.engine.room = WbSyncRoomData(
        lockAcks: <dynamic>[_ack('e1', 'release')],
      );
      h.pollTimers.fire();
      expect(h.service.isHoldingLock('e1'), isFalse);
    });

    test('stop：清空持有锁 + 取消续约 + 断开传输', () async {
      await h.service.start(boardId: 'b1');
      h.service.acquireLock('e1');
      _grant(h, 'e1');
      expect(h.service.isHoldingLock('e1'), isTrue);
      final int disconnects = h.engine.disconnectCount;

      await h.service.stop();

      expect(h.service.isHoldingLock('e1'), isFalse);
      expect(h.renewTimers.lastTimer?.cancelled, isTrue);
      expect(h.engine.disconnectCount, disconnects + 1);
      expect(h.service.boardId, isNull);
    });

    test('reconnect：stop + start 同 boardId；不残留旧锁；未入房 false', () async {
      await h.service.start(boardId: 'b1');
      h.service.acquireLock('e1');
      _grant(h, 'e1');
      expect(h.service.isHoldingLock('e1'), isTrue);
      final int pollsBefore = h.pollTimers.created;

      final bool ok = await h.service.reconnect();

      expect(ok, isTrue);
      expect(h.engine.joinedBoards, <String>['b1', 'b1']);
      expect(h.pollTimers.created, pollsBefore + 1);
      expect(h.service.boardId, 'b1');
      expect(h.service.isHoldingLock('e1'), isFalse, reason: 'stop 清空会话锁');

      final _ServiceHarness fresh = _ServiceHarness();
      addTearDown(fresh.service.dispose);
      expect(await fresh.service.reconnect(), isFalse, reason: '未入房无 boardId');
    });

    test('sendPreview：未 start 不触达引擎；start 后转发；异常降级为 dropped',
        () async {
      final WbSyncLockResult lock = h.service.acquireLock('e1');
      expect(lock.requested, isFalse, reason: '未入房锁请求不被接受');
      expect(h.engine.lockCalls, isEmpty);
      final WbSyncPreviewResult dropped =
          h.service.sendPreview(<String, dynamic>{'kind': 'cursor'});
      expect(dropped.dropped, isTrue);
      expect(h.engine.calls.contains('sendPreview'), isFalse);

      await h.service.start(boardId: 'b1');

      final WbSyncPreviewResult sent = h.service.sendPreview(<String, dynamic>{
        'kind': 'cursor',
        'pageId': 'p1',
        'x': 1.0,
        'y': 2.0,
      });
      expect(sent.sent, isTrue);
      expect(h.engine.sentPreviews.single['kind'], 'cursor');

      h.engine.previewError = StateError('engine down');
      final WbSyncPreviewResult failed =
          h.service.sendPreview(<String, dynamic>{'kind': 'cursor'});
      expect(failed.dropped, isTrue, reason: '预览异常降级为丢弃，不抛出');
      expect(h.service.lastError, contains('engine down'));
    });

    test('locks / remoteLocks：快照透传（含本端）；排除本端；坏载荷忽略', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = const WbSyncRoomData(
        locks: <String, dynamic>{
          'e1': <String, dynamic>{'userId': 'me', 'expiresAt': 100},
          'e2': <String, dynamic>{'userId': 'other-1', 'expiresAt': 200},
          'e3': <String, dynamic>{'expiresAt': 300},
        },
        selfUserId: 'me',
      );
      h.pollTimers.fire();

      expect(h.service.locks, hasLength(3));
      expect(h.service.selfUserId, 'me');
      expect(h.service.remoteLocks, <String, String>{'e2': 'other-1'});
      expect(h.service.lockHolderOf('e2'), 'other-1');
      expect(h.service.lockHolderOf('e1'), isNull, reason: '本端持有不算他人');
      expect(h.service.lockHolderOf('e3'), isNull, reason: '缺 userId 坏载荷忽略');
    });

    test('shouldOfferReconnect：失败态 + 轮次 ≥ 5 才提示', () async {
      await h.service.start(boardId: 'b1');
      expect(h.service.shouldOfferReconnect, isFalse);

      h.engine.transportState = 'failed';
      h.engine.reconnectCount = 5;
      h.pollTimers.fire();

      expect(h.service.status, WbSyncStatus.error);
      expect(h.service.reconnectCount, 5);
      expect(h.service.shouldOfferReconnect, isTrue);

      h.engine.reconnectCount = 4;
      h.pollTimers.fire();
      expect(h.service.shouldOfferReconnect, isFalse, reason: '轮次不足不提示');
    });
  });
}
