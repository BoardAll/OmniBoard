/// T1.6 协同测试共享组件：内存协同引擎（无 DLL）+ 手动轮询定时器。
///
/// [FakeCollabEngine] 实现 [WbCollabEngine] 端口，按调用记录 + 可编程
/// 返回值模拟 `whiteboard_core` 的 sync / crdt 域语义；[FakePollTimer]
/// 记录取消状态，tick 由测试持有的回调手动驱动（不真实计时）。
library;

import 'dart:async';

import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';

/// 内存协同引擎：`WbCollabEngine` 端口的测试替身。
class FakeCollabEngine implements WbCollabEngine {
  /// 调用序列（方法名；`connect` / `disconnect` / `status` / `create` /
  /// `join` / `sendOperation` / `events` / `flush` / `applyLocal`）。
  final List<String> calls = <String>[];

  /// 已发送 op（`sendOperation` 实参）。
  final List<Map<String, dynamic>> sentOps = <Map<String, dynamic>>[];

  /// `connect` 收到的 endpoint。
  final List<String> connectedEndpoints = <String>[];

  /// `createDocument` 收到的 docId。
  final List<String> createdDocs = <String>[];

  /// `join` 收到的 boardId。
  final List<String> joinedBoards = <String>[];

  /// 传输连接状态。
  bool connected = false;

  /// 传输状态机状态（`disconnected` / `connected` / `connecting` /
  /// `reconnecting` / `failed`）。
  String transportState = 'disconnected';

  /// 状态快照字段（`status()` 返回值；[statusOverride] 非空时优先）。
  bool offline = false;
  int pendingCount = 0;
  int sentCount = 0;
  int syncedCount = 0;
  int participants = 0;
  int latencyMs = 0;
  int reconnectCount = 0;

  /// 非空时 `status()` 直接返回该快照（模拟任意传输态）。
  WbSyncStatusData? statusOverride;

  /// `connect` 抛出的错误（如已连接 `Conflict`）。
  Object? connectError;

  /// `createDocument` 抛出的错误（如文档已存在 `Conflict`）。
  Object? createError;

  /// `join` 抛出的错误。
  Object? joinError;

  /// `join` 返回值 `joined` 字段。
  bool joinAccepted = true;

  /// `sendOperation` 返回 queued（离线积压仿真）。
  bool sendQueued = false;

  /// `applyLocal` 抛出的错误。
  Object? applyLocalError;

  /// `applyLocal` 返回空 op（模拟未变更）。
  bool applyLocalEmptyOp = false;

  /// `status()` 抛错（模拟引擎异常）。
  bool statusThrows = false;

  /// 下一次 `events()` 返回的 ops（drain：返回后清空）。
  List<Map<String, dynamic>> nextOps = <Map<String, dynamic>>[];

  /// 下一次 `events()` 返回的预览（drain：返回后清空）。
  List<Map<String, dynamic>> nextPreviews = <Map<String, dynamic>>[];

  /// `sendPreview` 收到的预览载荷（按调用顺序）。
  final List<Map<String, dynamic>> sentPreviews = <Map<String, dynamic>>[];

  /// `sendPreview` 返回 `dropped`（模拟未连接 / 离线 / 被拒）。
  bool previewDropped = false;

  /// `sendPreview` 抛出的错误。
  Object? previewError;

  /// `lock` 调用记录（`action:elementId`）。
  final List<String> lockCalls = <String>[];

  /// `lock` 返回的 `requested`（false 模拟未连接 / 离线）。
  bool lockRequested = true;

  /// `lock` 抛出的错误。
  Object? lockError;

  /// `interactive` 调用记录（Map：action / userId? / targetUserId?）。
  final List<Map<String, dynamic>> interactiveCalls =
      <Map<String, dynamic>>[];

  /// `interactive` 返回的 `requested`（false 模拟未连接 / 离线）。
  bool interactiveRequested = true;

  /// `interactive` 抛出的错误。
  Object? interactiveError;

  /// 下一次 `events()` 返回的互动回执（drain：返回后清空）。
  List<dynamic> nextInteractiveAcks = <dynamic>[];

  /// 下一次 `events()` 返回的跟随事件（drain：返回后清空）。
  List<dynamic> nextIncomingFollows = <dynamic>[];

  /// 下一次 `events()` 返回的移除通知（drain：返回后清空）。
  Map<String, dynamic> nextRemoved = <String, dynamic>{};

  /// `events()` 返回的房间快照（跨调用缓存语义；测试编程设置）。
  WbSyncRoomData room = const WbSyncRoomData();

  /// `createDocument` 最近一次的 actor。
  String? lastCreateActor;

  /// `join` 最近一次的 pageId。
  String? lastJoinPageId;

  /// `disconnect` 调用次数。
  int disconnectCount = 0;

  WbSyncStatusData _statusData() => WbSyncStatusData(
        connected: connected,
        offline: offline,
        participants: participants,
        pendingCount: pendingCount,
        sentCount: sentCount,
        syncedCount: syncedCount,
        latencyMs: latencyMs,
        reconnectCount: reconnectCount,
        transportState: transportState,
      );

  @override
  WbSyncStatusData connect({required String endpoint, String? token}) {
    calls.add('connect');
    final Object? error = connectError;
    if (error != null) {
      throw error;
    }
    connectedEndpoints.add(endpoint);
    connected = true;
    transportState = 'connected';
    return _statusData();
  }

  @override
  WbSyncStatusData disconnect() {
    calls.add('disconnect');
    disconnectCount++;
    connected = false;
    transportState = 'disconnected';
    return _statusData();
  }

  @override
  WbSyncStatusData status() {
    calls.add('status');
    if (statusThrows) {
      throw StateError('status unavailable');
    }
    return statusOverride ?? _statusData();
  }

  @override
  WbSyncJoinData join(String boardId, {String? pageId}) {
    calls.add('join');
    final Object? error = joinError;
    if (error != null) {
      throw error;
    }
    joinedBoards.add(boardId);
    lastJoinPageId = pageId;
    return WbSyncJoinData(
      boardId: boardId,
      joined: joinAccepted,
      pageId: pageId,
    );
  }

  @override
  WbSyncSendResult sendOperation(Map<String, dynamic> op) {
    calls.add('sendOperation');
    sentOps.add(op);
    return WbSyncSendResult(
      sent: !sendQueued,
      queued: sendQueued,
      pendingCount: sendQueued ? sentOps.length : 0,
      syncedCount: sendQueued ? 0 : sentOps.length,
    );
  }

  @override
  WbSyncEventsData events() {
    calls.add('events');
    final List<Map<String, dynamic>> ops = nextOps;
    final List<Map<String, dynamic>> previews = nextPreviews;
    final List<dynamic> interactiveAcks = nextInteractiveAcks;
    final List<dynamic> incomingFollows = nextIncomingFollows;
    final Map<String, dynamic> removed = nextRemoved;
    nextOps = <Map<String, dynamic>>[];
    nextPreviews = <Map<String, dynamic>>[];
    nextInteractiveAcks = <dynamic>[];
    nextIncomingFollows = <dynamic>[];
    nextRemoved = <String, dynamic>{};
    return WbSyncEventsData(
      ops: ops,
      previews: previews,
      room: room,
      status: status(),
      interactiveAcks: interactiveAcks,
      incomingFollows: incomingFollows,
      removed: removed,
    );
  }

  @override
  WbSyncFlushData flush() {
    calls.add('flush');
    final int drained = pendingCount;
    pendingCount = 0;
    syncedCount += drained;
    return WbSyncFlushData(
      synced: drained,
      pendingCount: pendingCount,
      syncedCount: syncedCount,
    );
  }

  @override
  WbCrdtCreateData createDocument(String docId, {String? actor}) {
    calls.add('create');
    final Object? error = createError;
    if (error != null) {
      throw error;
    }
    createdDocs.add(docId);
    lastCreateActor = actor;
    return WbCrdtCreateData(docId: docId, actor: actor ?? '', version: 0);
  }

  @override
  WbCrdtApplyData applyLocal(String docId, Map<String, dynamic> op) {
    calls.add('applyLocal');
    final Object? error = applyLocalError;
    if (error != null) {
      throw error;
    }
    if (applyLocalEmptyOp) {
      return const WbCrdtApplyData();
    }
    final int seq = sentOps.length + 1;
    final Map<String, dynamic> normalized = <String, dynamic>{
      'actor': 'fake-actor',
      'seq': seq,
      'origin': 'local',
      ...op,
      'timestamp': 0,
    };
    return WbCrdtApplyData(
      applied: true,
      docId: docId,
      key: op['key'] as String? ?? '',
      origin: 'local',
      seq: seq,
      version: seq,
      op: normalized,
    );
  }

  @override
  WbSyncPreviewResult sendPreview(Map<String, dynamic> preview) {
    calls.add('sendPreview');
    final Object? error = previewError;
    if (error != null) {
      throw error;
    }
    if (previewDropped) {
      return const WbSyncPreviewResult(dropped: true);
    }
    sentPreviews.add(preview);
    return const WbSyncPreviewResult(sent: true);
  }

  @override
  WbSyncLockResult lock({required String action, required String elementId}) {
    calls.add('lock');
    final Object? error = lockError;
    if (error != null) {
      throw error;
    }
    lockCalls.add('$action:$elementId');
    return WbSyncLockResult(requested: lockRequested);
  }

  @override
  WbSyncInteractiveResult interactive({
    required String action,
    String? userId,
    String? targetUserId,
  }) {
    calls.add('interactive');
    final Object? error = interactiveError;
    if (error != null) {
      throw error;
    }
    interactiveCalls.add(<String, dynamic>{
      'action': action,
      if (userId != null) 'userId': userId,
      if (targetUserId != null) 'targetUserId': targetUserId,
    });
    return WbSyncInteractiveResult(requested: interactiveRequested);
  }
}

/// 手动轮询定时器：不真实计时；记录取消状态，tick 由测试驱动。
class FakePollTimer implements Timer {
  FakePollTimer(this._onTick);

  final void Function() _onTick;
  bool _cancelled = false;

  /// 是否已取消。
  bool get cancelled => _cancelled;

  /// 已手动驱动次数。
  int firedCount = 0;

  @override
  bool get isActive => !_cancelled;

  @override
  int get tick => 0;

  /// 手动驱动一次回调（已取消时忽略）。
  void fire() {
    if (_cancelled) {
      return;
    }
    firedCount++;
    _onTick();
  }

  @override
  void cancel() {
    _cancelled = true;
  }
}

/// 轮询定时器工厂：捕获 tick 回调与创建参数，供测试手动驱动。
class FakePollTimerFactory {
  /// 捕获的 tick 回调（`WbCollabService._pollEvents`）。
  void Function()? onTick;

  /// 最近创建的 timer。
  FakePollTimer? lastTimer;

  /// 工厂收到的轮询间隔。
  Duration? interval;

  /// 已创建的 timer 数量。
  int created = 0;

  /// 注入 `WbCollabService(pollTimerFactory: factory.create)`。
  Timer create(Duration interval, void Function() onTick) {
    this.interval = interval;
    this.onTick = onTick;
    created++;
    final FakePollTimer timer = FakePollTimer(onTick);
    lastTimer = timer;
    return timer;
  }

  /// 手动驱动一次最新 tick（若无或已取消则忽略）。
  void fire() => lastTimer?.fire();
}
