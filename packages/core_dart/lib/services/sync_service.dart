import '../utils/json_codec.dart';
import '../wb_core_ffi.dart';

/// 同步服务：控制面 + M1 数据面（sync 域）。
///
/// 控制面：[connect] / [disconnect] / [status] / [setOffline]；
/// 数据面：[join] / [sendOperation] / [flush] / [events] / [sendPreview]。
///
/// 全部走引擎统一 UTF-8 JSON 信封（`{"ok":true,"result":{...}}` /
/// `{"ok":false,"error":{...}}`，docs/modules/05-core-collab.md §6），
/// 失败经 [WbCoreException] 抛出。[events] 为 drain 语义（逐调用清空入站
/// 事件），对应 D6 定稿的 50ms 轮询模型（不新增回调通道符号）。
class WbSyncService {
  const WbSyncService(this.ffi);

  final WbCoreFfi ffi;

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
      ffi.call2(ffi.bindings.wbSyncConnect, endpoint, token ?? ''),
    );
    return WbSyncStatusData.fromJson(response.requireResult());
  }

  /// 断开连接（未确认 op 回灌离线队列，pending 保留不清空）。
  WbSyncStatusData disconnect() {
    final WbResponse response = WbResponse.parse(
      ffi.call0(ffi.bindings.wbSyncDisconnect),
    );
    return WbSyncStatusData.fromJson(response.requireResult());
  }

  /// 当前同步状态快照（含 transportState / latencyMs / participants /
  /// reconnectCount 等 M1 增量字段）。
  WbSyncStatusData status() {
    final WbResponse response =
        WbResponse.parse(ffi.call0(ffi.bindings.wbSyncStatus));
    return WbSyncStatusData.fromJson(response.requireResult());
  }

  /// 切换离线模式（true 时 [join] / [flush] 被推迟、出站进入离线队列）。
  WbSyncStatusData setOffline(bool offline) {
    final WbResponse response = WbResponse.parse(
      ffi.callInt(ffi.bindings.wbSyncSetOffline, offline ? 1 : 0),
    );
    return WbSyncStatusData.fromJson(response.requireResult());
  }

  /// 加入协作房间（`{boardId, pageId?}`）。
  ///
  /// 须先 [connect] 且传输处于 Connected，否则 `Conflict`；缺 [boardId]
  /// → `InvalidArgument`。响应 `{boardId, joined:true, pageId?}`。
  WbSyncJoinData join(String boardId, {String? pageId}) {
    final WbResponse response = WbResponse.parse(
      ffi.call2(ffi.bindings.wbSyncJoin, boardId, pageId ?? ''),
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
      ffi.call1(ffi.bindings.wbSyncSendOperation, WbJsonCodec.encode(op)),
    );
    return WbSyncSendResult.fromJson(response.requireResult());
  }

  /// 冲刷离线队列（sync 域 `sync` op）。
  ///
  /// 须在线且非离线模式，否则 `Conflict`；响应
  /// `{synced, pendingCount, syncedCount}`。
  WbSyncFlushData flush() {
    final WbResponse response =
        WbResponse.parse(ffi.call0(ffi.bindings.wbSyncFlush));
    return WbSyncFlushData.fromJson(response.requireResult());
  }

  /// 拉取入站事件（drain 语义：逐调用清空 ops/previews，room/status 为
  /// 快照，跨调用缓存）。
  ///
  /// 返回 `{ops, previews, room, status}`；`ops` 仅含经过 crdt 过滤的
  /// **生效** op（LWW 败者不下发）。
  WbSyncEventsData events() {
    final WbResponse response =
        WbResponse.parse(ffi.call0(ffi.bindings.wbSyncEvents));
    return WbSyncEventsData.fromJson(response.requireResult());
  }

  /// 发送高频预览（可丢，volatile 语义由引擎迟滞队列兜底）。
  ///
  /// [preview] 须含 `kind`（`transform` / `ink`），否则
  /// `InvalidArgument`；未连接/离线/被拒 → `{dropped:true}`。
  WbSyncPreviewResult sendPreview(Map<String, dynamic> preview) {
    final WbResponse response = WbResponse.parse(
      ffi.call1(ffi.bindings.wbSyncSendPreview, WbJsonCodec.encode(preview)),
    );
    return WbSyncPreviewResult.fromJson(response.requireResult());
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

/// [WbSyncEventsData.room] 的房间快照：`{participants, mode, locks,
/// selfUserId}`。
class WbSyncRoomData {
  const WbSyncRoomData({
    this.participants = const <dynamic>[],
    this.mode = '',
    this.locks = const <dynamic>[],
    this.selfUserId = '',
  });

  /// 参与者列表（M1 为字符串元素；保留原始元素形状）。
  final List<dynamic> participants;

  /// 房间模式（如 `free`；未同步时为空串）。
  final String mode;

  /// 锁表快照（原始形状，M2 软锁落地）。
  final List<dynamic> locks;

  /// 服务端签发的本端身份（`board:session`；每连接唯一，未连接 / 旧
  /// 引擎为空串）——UI 据此精确标记「我」。
  final String selfUserId;

  factory WbSyncRoomData.fromJson(Map<String, dynamic> json) =>
      WbSyncRoomData(
        participants: _listAt(json, 'participants'),
        mode: _stringAt(json, 'mode'),
        locks: _listAt(json, 'locks'),
        selfUserId: _stringAt(json, 'selfUserId'),
      );
}

/// [WbSyncService.events] 的响应（drain 语义）：
/// `{ops, previews, room, status}`。
class WbSyncEventsData {
  const WbSyncEventsData({
    this.ops = const <Map<String, dynamic>>[],
    this.previews = const <Map<String, dynamic>>[],
    this.room = const WbSyncRoomData(),
    this.status = const WbSyncStatusData(),
  });

  /// 自上次调用以来**生效**的远端 op（完整 op 对象）。
  final List<Map<String, dynamic>> ops;

  /// presence 预览（透传载荷，`kind`: transform / ink）。
  final List<Map<String, dynamic>> previews;

  /// 房间快照（参与者 / 模式 / 锁表，跨调用缓存）。
  final WbSyncRoomData room;

  /// 当前状态快照。
  final WbSyncStatusData status;

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
