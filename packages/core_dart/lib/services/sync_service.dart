import '../engine.dart';
import '../utils/json_codec.dart';

/// 同步服务：控制面 + M1/M2/M3 数据面（sync 域）。
///
/// 控制面：[connect] / [disconnect] / [status] / [setOffline]；
/// 数据面：[join] / [sendOperation] / [flush] / [events] / [sendPreview] /
/// [lock]（M2 软锁直通）/ [interactive]（M3 交互通道直通）。
///
/// 全部走引擎统一 UTF-8 JSON 信封（`{"ok":true,"result":{...}}` /
/// `{"ok":false,"error":{...}}`，docs/modules/05-core-collab.md §6），
/// 失败经 [WbCoreException] 抛出。[events] 为 drain 语义（逐调用清空入站
/// 事件），对应 D6 定稿的 50ms 轮询模型（不新增回调通道符号）。
class WbSyncService {
  const WbSyncService(this.ffi);

  final WbEngineCaller ffi;

  /// 连接协作服务（`{endpoint, token?, clientVersion?}`）。
  ///
  /// [endpoint] 必填（空串 → `InvalidArgument`）；[token] 为服务端签发的
  /// JWT（可空）。已连接 → `Conflict`；传输启动失败（含 wasm 构建）→
  /// `NotSupported`。
  ///
  /// 注：M1 控制面符号 `wb_sync_connect(endpoint, token)` 不转发
  /// [clientVersion]，引擎按默认 `"1.0.0"` 处理；参数保留以对齐域契约。
  WbSyncStatusData connect({
    required String endpoint,
    String? token,
    String? clientVersion,
  }) {
    final WbResponse response = WbResponse.parse(
      ffi.call2('wb_sync_connect', endpoint, token ?? ''),
    );
    return WbSyncStatusData.fromJson(response.requireResult());
  }

  /// 断开连接（未确认 op 回灌离线队列，pending 保留不清空）。
  WbSyncStatusData disconnect() {
    final WbResponse response = WbResponse.parse(
      ffi.call0('wb_sync_disconnect'),
    );
    return WbSyncStatusData.fromJson(response.requireResult());
  }

  /// 当前同步状态快照（含 transportState / latencyMs / participants /
  /// reconnectCount 等 M1 增量字段）。
  WbSyncStatusData status() {
    final WbResponse response =
        WbResponse.parse(ffi.call0('wb_sync_status'));
    return WbSyncStatusData.fromJson(response.requireResult());
  }

  /// 切换离线模式（true 时 [join] / [flush] 被推迟、出站进入离线队列）。
  WbSyncStatusData setOffline(bool offline) {
    final WbResponse response = WbResponse.parse(
      ffi.callInt('wb_sync_set_offline', offline ? 1 : 0),
    );
    return WbSyncStatusData.fromJson(response.requireResult());
  }

  /// 加入协作房间（`{boardId, pageId?}`）。
  ///
  /// 须先 [connect] 且传输处于 Connected，否则 `Conflict`；缺 [boardId]
  /// → `InvalidArgument`。响应 `{boardId, joined:true, pageId?}`。
  WbSyncJoinData join(String boardId, {String? pageId}) {
    final WbResponse response = WbResponse.parse(
      ffi.call2('wb_sync_join', boardId, pageId ?? ''),
    );
    return WbSyncJoinData.fromJson(response.requireResult());
  }

  /// 发送一条完整 op（在线 → `sent:true`；未连接/离线 → 入离线队列
  /// `queued:true`）。
  ///
  /// [op] 为完整 op 对象（actor/seq/key/value/timestamp/origin），可直接
  /// 使用 crdt.applyLocal 响应中的 `op` 字段。
  WbSyncSendResult sendOperation(Map<String, dynamic> op) {
    final WbResponse response = WbResponse.parse(
      ffi.call1('wb_sync_send_operation', WbJsonCodec.encode(op)),
    );
    return WbSyncSendResult.fromJson(response.requireResult());
  }

  /// 冲刷离线队列（sync 域 `sync` op）。
  ///
  /// 须在线且非离线模式，否则 `Conflict`；响应
  /// `{synced, pendingCount, syncedCount}`。
  WbSyncFlushData flush() {
    final WbResponse response =
        WbResponse.parse(ffi.call0('wb_sync_flush'));
    return WbSyncFlushData.fromJson(response.requireResult());
  }

  /// 拉取入站事件（drain 语义：逐调用清空 ops/previews/lockAcks/
  /// interactiveAcks/incomingFollows/removed，room/status 为快照，跨调用
  /// 缓存）。
  ///
  /// 返回 `{ops, previews, room, status, interactiveAcks, incomingFollows,
  /// removed}`；`ops` 仅含经过 crdt 过滤的 **生效** op（LWW 败者不下发）；
  /// M3 交互回执（`interactiveAcks` / `incomingFollows` / `removed`）为
  /// 本批次 drain 数据。
  WbSyncEventsData events() {
    final WbResponse response =
        WbResponse.parse(ffi.call0('wb_sync_events'));
    return WbSyncEventsData.fromJson(response.requireResult());
  }

  /// 发送高频预览（可丢，volatile 语义由引擎迟滞队列兜底）。
  ///
  /// [preview] 须含 `kind`（`transform` / `ink`），否则
  /// `InvalidArgument`；未连接/离线/被拒 → `{dropped:true}`。
  WbSyncPreviewResult sendPreview(Map<String, dynamic> preview) {
    final WbResponse response = WbResponse.parse(
      ffi.call1('wb_sync_send_preview', WbJsonCodec.encode(preview)),
    );
    return WbSyncPreviewResult.fromJson(response.requireResult());
  }

  /// 请求软锁变更（sync 域 `lock` op，M2 D2-C 软锁直通）。
  ///
  /// [action] ∈ `acquire` / `release` / `renew`；缺任一 / action 非法 →
  /// `InvalidArgument`。未连接 / 离线 / 传输被拒 → `{requested:false}`；
  /// 在线转发成功 → `{requested:true}`（恒 ok，不抛 Conflict）。异步的
  /// 授予/拒绝结果经 [events] 的 `room.lockAcks` 回执。
  WbSyncLockResult lock({
    required String action,
    required String elementId,
  }) {
    final WbResponse response = WbResponse.parse(
      ffi.call1(
        'wb_sync_lock',
        WbJsonCodec.encode(<String, dynamic>{
          'action': action,
          'elementId': elementId,
        }),
      ),
    );
    return WbSyncLockResult.fromJson(response.requireResult());
  }

  /// 发送交互请求（sync 域 `interactive` op，M3 交互通道直通）。
  ///
  /// [action] ∈ `raiseHand` / `lowerHand` / `startPresent` / `stopPresent` /
  /// `grantControl` / `revokeControl` / `removeUser` / `follow` / `unfollow`；
  /// `grantControl` / `revokeControl` / `removeUser` 必填 [userId]，
  /// `follow` / `unfollow` 必填 [targetUserId]（其余 action 忽略二者）。
  ///
  /// 缺 action / action 非法 / 缺 action 所需字段 → `InvalidArgument`；
  /// 未连接 / 离线 / 传输被拒 → `{requested:false}`；在线转发成功 →
  /// `{requested:true}`（恒 ok，不抛 Conflict）。异步结果经 [events] 的
  /// `interactiveAcks` 回执。
  WbSyncInteractiveResult interactive({
    required String action,
    String? userId,
    String? targetUserId,
  }) {
    final Map<String, dynamic> args = <String, dynamic>{'action': action};
    if (userId != null) {
      args['userId'] = userId;
    }
    if (targetUserId != null) {
      args['targetUserId'] = targetUserId;
    }
    final WbResponse response = WbResponse.parse(
      ffi.call1('wb_sync_interactive', WbJsonCodec.encode(args)),
    );
    return WbSyncInteractiveResult.fromJson(response.requireResult());
  }
}

/// [WbSyncService.status] / [WbSyncService.connect] / [WbSyncService.disconnect]
/// / [WbSyncService.setOffline] 的响应快照。
///
/// JSON 形状：`{connected, endpoint, offline, participants, pendingCount,
/// sentCount, syncedCount, latencyMs, reconnectCount, transport,
/// transportState}`。
class WbSyncStatusData {
  const WbSyncStatusData({
    this.connected = false,
    this.endpoint = '',
    this.offline = false,
    this.participants = 0,
    this.pendingCount = 0,
    this.sentCount = 0,
    this.syncedCount = 0,
    this.latencyMs = 0,
    this.reconnectCount = 0,
    this.transport = '',
    this.transportState = 'disconnected',
  });

  /// 传输是否已连接。
  final bool connected;

  /// 当前（或最近一次尝试的）协作服务端点。
  final String endpoint;

  /// 离线模式。
  final bool offline;

  /// 房间参与者数量。
  final int participants;

  /// 离线队列深度。
  final int pendingCount;

  /// 已发送 / 已同步 op 计数。
  final int sentCount;
  final int syncedCount;

  /// 最近一次 ack RTT（毫秒；0 为未采样哨兵）。
  final int latencyMs;

  /// 重连次数。
  final int reconnectCount;

  /// 传输类型（M1 恒为 `"socketio"`）。
  final String transport;

  /// 传输状态机：disconnected / connecting / connected / reconnecting /
  /// failed。
  final String transportState;

  factory WbSyncStatusData.fromJson(Map<String, dynamic> json) =>
      WbSyncStatusData(
        connected: json['connected'] == true,
        endpoint: _stringAt(json, 'endpoint'),
        offline: json['offline'] == true,
        participants: _intAt(json, 'participants'),
        pendingCount: _intAt(json, 'pendingCount'),
        sentCount: _intAt(json, 'sentCount'),
        syncedCount: _intAt(json, 'syncedCount'),
        latencyMs: _intAt(json, 'latencyMs'),
        reconnectCount: _intAt(json, 'reconnectCount'),
        transport: _stringAt(json, 'transport'),
        transportState: _stringAt(json, 'transportState', 'disconnected'),
      );
}

/// [WbSyncService.join] 的响应：`{boardId, joined:true, pageId?}`。
class WbSyncJoinData {
  const WbSyncJoinData({this.boardId = '', this.joined = false, this.pageId});

  final String boardId;
  final bool joined;

  /// 加入的页面（未指定时为 null）。
  final String? pageId;

  factory WbSyncJoinData.fromJson(Map<String, dynamic> json) {
    final String pageId = _stringAt(json, 'pageId');
    return WbSyncJoinData(
      boardId: _stringAt(json, 'boardId'),
      joined: json['joined'] == true,
      pageId: pageId.isEmpty ? null : pageId,
    );
  }
}

/// [WbSyncService.sendOperation] 的响应。
///
/// 在线：`{sent:true, pendingCount, syncedCount}`；
/// 未连接/离线/发送被拒：`{queued:true, sent:false, pendingCount,
/// syncedCount}`。
class WbSyncSendResult {
  const WbSyncSendResult({
    this.sent = false,
    this.queued = false,
    this.pendingCount = 0,
    this.syncedCount = 0,
  });

  final bool sent;
  final bool queued;
  final int pendingCount;
  final int syncedCount;

  factory WbSyncSendResult.fromJson(Map<String, dynamic> json) =>
      WbSyncSendResult(
        sent: json['sent'] == true,
        queued: json['queued'] == true,
        pendingCount: _intAt(json, 'pendingCount'),
        syncedCount: _intAt(json, 'syncedCount'),
      );
}

/// [WbSyncService.flush] 的响应：`{synced, pendingCount, syncedCount}`。
class WbSyncFlushData {
  const WbSyncFlushData({
    this.synced = 0,
    this.pendingCount = 0,
    this.syncedCount = 0,
  });

  /// 本次成功送出的 op 数。
  final int synced;
  final int pendingCount;
  final int syncedCount;

  factory WbSyncFlushData.fromJson(Map<String, dynamic> json) =>
      WbSyncFlushData(
        synced: _intAt(json, 'synced'),
        pendingCount: _intAt(json, 'pendingCount'),
        syncedCount: _intAt(json, 'syncedCount'),
      );
}

/// [WbSyncService.sendPreview] 的响应。
///
/// 在线：`{sent:true}`；连接建立中：`{queued:true}`（迟滞槽待冲出）；
/// 未连接/离线/被拒：`{dropped:true}`。
class WbSyncPreviewResult {
  const WbSyncPreviewResult({
    this.sent = false,
    this.queued = false,
    this.dropped = false,
  });

  final bool sent;
  final bool queued;
  final bool dropped;

  factory WbSyncPreviewResult.fromJson(Map<String, dynamic> json) =>
      WbSyncPreviewResult(
        sent: json['sent'] == true,
        queued: json['queued'] == true,
        dropped: json['dropped'] == true,
      );
}

/// [WbSyncService.lock] 的响应：`{requested}`。
///
/// 在线且传输接受：`{requested:true}`；未连接/离线/被拒：
/// `{requested:false}`（恒 ok，不抛 Conflict；授予结果异步经
/// [WbSyncRoomData.lockAcks]）。
class WbSyncLockResult {
  const WbSyncLockResult({this.requested = false});

  /// 请求是否已交给传输（不代表锁已授予）。
  final bool requested;

  factory WbSyncLockResult.fromJson(Map<String, dynamic> json) =>
      WbSyncLockResult(requested: json['requested'] == true);
}

/// [WbSyncService.interactive] 的响应：`{requested}`。
///
/// 在线且传输接受：`{requested:true}`；未连接/离线/被拒：
/// `{requested:false}`（恒 ok，不抛 Conflict；服务端受理结果异步经
/// [events] 的 `interactiveAcks` 回执）。
class WbSyncInteractiveResult {
  const WbSyncInteractiveResult({this.requested = false});

  /// 请求是否已交给传输（不代表服务端已受理）。
  final bool requested;

  factory WbSyncInteractiveResult.fromJson(Map<String, dynamic> json) =>
      WbSyncInteractiveResult(requested: json['requested'] == true);
}

/// [WbSyncEventsData.room] 的房间快照：`{participants, mode, selfRole,
/// presenterId, hostUserId, grantedWrite, locks, lockAcks, selfUserId,
/// checkpointStatus, recovered}`。
class WbSyncRoomData {
  const WbSyncRoomData({
    this.participants = const <dynamic>[],
    this.mode = '',
    this.selfRole = '',
    this.presenterId = '',
    this.hostUserId = '',
    this.grantedWrite = false,
    this.locks = const <String, dynamic>{},
    this.lockAcks = const <dynamic>[],
    this.selfUserId = '',
    this.checkpointStatus = 'idle',
    this.recovered = false,
  });

  /// 参与者列表（M1 为字符串元素；保留原始元素形状）。
  final List<dynamic> participants;

  /// 房间模式（如 `free`；未同步时为空串）。
  final String mode;

  /// 本端角色（`Host` / `CoHost` / `Presenter` / `Participant` / `Viewer` /
  /// `Guest` 等；未同步 / 旧引擎为空串）。
  final String selfRole;

  /// 当前演示者 userId（`present` 模式时由服务端署名；无演示 / 已退出
  /// 为空串）。
  final String presenterId;

  /// 当前主持人 userId（`hostChanged` 折叠；未同步为空串）。
  final String hostUserId;

  /// 本端临时写权限（房间级镜像；非布尔载荷归一为 false）。
  final bool grantedWrite;

  /// 锁表快照（M2 软锁）：`elementId → {userId, expiresAt}` 对象 map，
  /// 值保持原始形状；旧引擎 / 旧服务端的数组等旧形态归一为空 map。
  final Map<String, dynamic> locks;

  /// 本调用（drain 批次）内的锁请求回执：`[{elementId, action, granted,
  /// holderUserId?, expiresAt?, ok}]`；逐调用清空，值保持原始形状。
  final List<dynamic> lockAcks;

  /// 服务端签发的本端身份（`board:session`；每连接唯一，未连接 / 旧
  /// 引擎为空串）——UI 据此精确标记「我」。
  final String selfUserId;

  /// 本端 checkpoint 状态（T3.5）：`idle` / `requested` / `uploaded` /
  /// `failed`（缺省 `idle`）。
  final String checkpointStatus;

  /// 是否发生过 join 快照恢复（新成员本地无 crdt 文档时置位；
  /// 旧引擎 / 缺省为 false）。
  final bool recovered;

  factory WbSyncRoomData.fromJson(Map<String, dynamic> json) =>
      WbSyncRoomData(
        participants: _listAt(json, 'participants'),
        mode: _stringAt(json, 'mode'),
        selfRole: _stringAt(json, 'selfRole'),
        presenterId: _stringAt(json, 'presenterId'),
        hostUserId: _stringAt(json, 'hostUserId'),
        grantedWrite: json['grantedWrite'] == true,
        locks: _mapAt(json, 'locks'),
        lockAcks: _listAt(json, 'lockAcks'),
        selfUserId: _stringAt(json, 'selfUserId'),
        checkpointStatus: _stringAt(json, 'checkpointStatus', 'idle'),
        recovered: json['recovered'] == true,
      );
}

/// [WbSyncService.events] 的响应（drain 语义）：
/// `{ops, previews, room, status, interactiveAcks, incomingFollows,
/// removed}`。
class WbSyncEventsData {
  const WbSyncEventsData({
    this.ops = const <Map<String, dynamic>>[],
    this.previews = const <Map<String, dynamic>>[],
    this.room = const WbSyncRoomData(),
    this.status = const WbSyncStatusData(),
    this.interactiveAcks = const <dynamic>[],
    this.incomingFollows = const <dynamic>[],
    this.removed = const <String, dynamic>{},
  });

  /// 自上次调用以来**生效**的远端 op（完整 op 对象）。
  final List<Map<String, dynamic>> ops;

  /// presence 预览（透传载荷，`kind`: transform / ink）。
  final List<Map<String, dynamic>> previews;

  /// 房间快照（参与者 / 模式 / 锁表 / 锁回执，跨调用缓存）。
  final WbSyncRoomData room;

  /// 当前状态快照。
  final WbSyncStatusData status;

  /// 本调用（drain 批次）内的交互请求回执（M3）：
  /// `[{action, ok, reason?}]`（`ok:false` 时 `reason` 为拒绝原因）；
  /// 逐调用清空，值保持原始形状。
  final List<dynamic> interactiveAcks;

  /// 本调用内投给本端的跟随事件（M3）：
  /// `[{followerUserId, action: 'follow' | 'unfollow'}]`；逐调用清空，
  /// 值保持原始形状。
  final List<dynamic> incomingFollows;

  /// `room:removed` 一次性通知（M3）：空 map 表示本批次无移除；非空时
  /// `reason` 为服务端移除原因（字符串，可能为空）；逐调用清空。
  final Map<String, dynamic> removed;

  factory WbSyncEventsData.fromJson(Map<String, dynamic> json) {
    final Object? room = json['room'];
    final Object? status = json['status'];
    return WbSyncEventsData(
      ops: WbJsonCodec.extractList(json['ops']),
      previews: WbJsonCodec.extractList(json['previews']),
      room: WbSyncRoomData.fromJson(
        room is Map ? Map<String, dynamic>.from(room) : const <String, dynamic>{},
      ),
      status: WbSyncStatusData.fromJson(
        status is Map
            ? Map<String, dynamic>.from(status)
            : const <String, dynamic>{},
      ),
      interactiveAcks: _listAt(json, 'interactiveAcks'),
      incomingFollows: _listAt(json, 'incomingFollows'),
      removed: _mapAt(json, 'removed'),
    );
  }
}

int _intAt(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  return value is num ? value.toInt() : 0;
}

String _stringAt(Map<String, dynamic> json, String key, [String fallback = '']) {
  final Object? value = json[key];
  return value is String ? value : fallback;
}

List<dynamic> _listAt(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  return value is List ? List<dynamic>.from(value) : const <dynamic>[];
}

Map<String, dynamic> _mapAt(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  return value is Map
      ? Map<String, dynamic>.from(value)
      : const <String, dynamic>{};
}
