/// 实时协作服务：W1 成员 / 连接状态（T1.8）+ M3 interactive 事件族补全（T3.4）。
///
/// 口径：
/// - W1（D-H）：Web M1 = 参与者列表 / 连接状态可见；
/// - M3（D3-E）：互动展示层——举手 / 角色态 / 临时写权 / 演示模式的状态与
///   操作入口；**不做视口跟随消费**（降级登记 W2/M5，见
///   `docs/modules/12-app-web.md` §2.7）；**被跟随广播已落地**（M3.1：
///   入站 `interactive:follow` / `unfollow` 折叠跟随者集合，
///   [needsViewportBroadcast] 驱动页面外发 viewport / page 帧）；
/// - P4（画布 op + 在场预览）：新增 `board:ops` 批量收发（ack 透传）、
///   `presence:preview` 光标 / 选区帧转发、`board:checkpoint( Request )`
///   双向通道；CRDT 语义（applyLocal / applyRemote / 快照恢复）由
///   `WbCollabSession` 承担，本服务只做传输与回调投递。
///
/// 传输抽象（D-G）：底层统一经 [WbSocketIoBridge]（`socketio_js.dart` 桥），
/// 脚本加载器 / 桥工厂可注入——VM（纯 Dart）测试注入桩桥，不加载 JS。
///
/// 事件处理（《互动白板实时协同设计文档》§5.10 / §5.14 / §6）：
/// - C→S：`board:join` / `board:leave`；
///   M3：`interactive:raiseHand` / `lowerHand`（最低 Viewer）、
///   `interactive:grantControl` / `revokeControl`（`{userId}`；最低 CoHost）、
///   `interactive:startPresent` / `stopPresent`、
///   `interactive:removeUser`（`{userId}`）——统一轻量 ack
///   `{ok:true}` / `{ok:false, reason}`（失败不写入 [WbRealtimeService.lastError]）；
///   P4：`board:ops`（本地 op 批；ack `{ok}` / `{ok,dup}` /
///   `{ok:false,missingSeqs}`）、`presence:preview`（fire-and-forget）、
///   `board:checkpoint`（`{stateVector, payload}` 轻量 ack）；
/// - S→C：`board:session`、`board:joined`（`role` / `mode` / `presenterId` 快照）、
///   `board:participants`（`joined` / `left` / `updated`；M3 扩展
///   `grantedWrite` / `handRaised`）、`room:error`、`room:removed`（单播，置只读态）、
///   `interactive:modeChanged`（广播）、`interactive:roleChanged`（单播自身）、
///   `interactive:hostChanged`（广播）、`interactive:follow` / `unfollow`
///   （单播 `{followerUserId}`；M3.1 折叠跟随者集合）；
///   P4：`board:ops`（批量 op 帧；多参 `(ops, meta)`，meta 含
///   `replay` / `from`）、`presence:preview`（服务端附加 userId 后转发）、
///   `board:checkpointRequest`（单播，协作会话据此上报状态）。
///
/// 连接状态机（断线重连显示支持）：
/// ```text
/// idle → connecting → connected
/// connected --(网络断开，自动重试)--> reconnecting --(重连成功，自动补 join)--> connected
/// 任意 --(主动 leave / 首次连接失败)--> disconnected
/// ```
/// 断线后的重连由 socket.io 客户端（`reconnection: true`）自动进行；
/// 服务只做状态映射与重连后自动重新 `board:join`（§5.12 收敛路径的 W1 子集）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'socketio_js.dart';

/// 默认 realtime 服务地址（`--dart-define=WB_REALTIME_ENDPOINT=...` 可覆盖）。
const String kWbRealtimeEndpoint = String.fromEnvironment(
  'WB_REALTIME_ENDPOINT',
  defaultValue: 'http://127.0.0.1:8790',
);

/// 连接状态（Web W1；对齐 web 既有 ChangeNotifier 状态管理模式）。
enum WbRealtimeStatus {
  /// 未启用（尚未调用 [WbRealtimeService.connect]）；
  /// UI 据此隐藏协作入口（单机模式，功能零阻塞）。
  idle,

  /// 首次连接进行中。
  connecting,

  /// 已连接（可加入房间）。
  connected,

  /// 断线重连中（原会话中断，socket.io 自动重试）。
  reconnecting,

  /// 已断开 / 连接失败（不再自动重试，或等待手动 connect）。
  disconnected,
}

/// 参与者条目（§5.1：一个 socket 一条；`board:joined` / `board:participants` 载荷）。
@immutable
class WbCollabParticipant {
  /// 创建参与者。
  const WbCollabParticipant({
    required this.userId,
    required this.socketId,
    required this.role,
    required this.joinedAtMs,
    this.grantedWrite = false,
    this.handRaised = false,
  });

  /// 用户 id（服务端解析：JWT sub 或匿名 dev 回落 `anon-*`）。
  final String userId;

  /// 会话 socket id（服务端参与者表主键，重连会变）。
  final String socketId;

  /// 房间角色（`Host / CoHost / Presenter / Participant / Viewer / Guest`）。
  final String role;

  /// 加入时间（epoch 毫秒）。
  final int joinedAtMs;

  /// M3：临时写权（`interactive:grantControl` / `revokeControl` 授予 / 收回）。
  final bool grantedWrite;

  /// M3：举手状态（`interactive:raiseHand` / `lowerHand`）。
  final bool handRaised;

  /// 从事件载荷解析；`userId` / `socketId` 缺失时返回 null（畸形数据容错）。
  static WbCollabParticipant? tryParse(Object? value) {
    final Map<String, Object?>? map = _asMap(value);
    if (map == null) {
      return null;
    }
    final Object? userId = map['userId'];
    final Object? socketId = map['socketId'];
    if (userId is! String || userId.isEmpty || socketId is! String || socketId.isEmpty) {
      return null;
    }
    final Object? role = map['role'];
    final Object? joinedAt = map['joinedAt'];
    return WbCollabParticipant(
      userId: userId,
      socketId: socketId,
      role: role is String ? role : '',
      joinedAtMs: joinedAt is num ? joinedAt.toInt() : 0,
      grantedWrite: map['grantedWrite'] == true,
      handRaised: map['handRaised'] == true,
    );
  }

  /// 复制并覆盖指定字段（参与者主键 / 加入时间不变）。
  WbCollabParticipant copyWith({String? role, bool? grantedWrite, bool? handRaised}) =>
      WbCollabParticipant(
        userId: userId,
        socketId: socketId,
        role: role ?? this.role,
        joinedAtMs: joinedAtMs,
        grantedWrite: grantedWrite ?? this.grantedWrite,
        handRaised: handRaised ?? this.handRaised,
      );

  @override
  bool operator ==(Object other) =>
      other is WbCollabParticipant &&
      other.userId == userId &&
      other.socketId == socketId &&
      other.role == role &&
      other.joinedAtMs == joinedAtMs &&
      other.grantedWrite == grantedWrite &&
      other.handRaised == handRaised;

  @override
  int get hashCode => Object.hash(userId, socketId, role, joinedAtMs, grantedWrite, handRaised);

  @override
  String toString() => 'WbCollabParticipant($userId@$socketId, $role)';
}

/// 协作层错误（连接错误 / `room:error` 载荷）。
@immutable
class WbRealtimeError {
  /// 创建错误。
  const WbRealtimeError({required this.message, this.code});

  /// 人类可读错误信息。
  final String message;

  /// 错误码（如 `Unauthorized` / `Forbidden` / `NotInRoom`）；无则为 null。
  final String? code;

  @override
  String toString() => code == null ? 'WbRealtimeError($message)' : 'WbRealtimeError($code: $message)';
}

/// Socket.IO 客户端脚本加载器（可注入；缺省 `loadSocketIoClient`）。
typedef WbSocketIoClientLoader = Future<void> Function(String endpoint);

/// 桥工厂（可注入；缺省 `createWbSocketIoBridge`）。
typedef WbSocketIoBridgeFactory = WbSocketIoBridge Function();

/// W1 实时协作服务（ChangeNotifier，供 Provider 挂载）。
///
/// 用法（编辑页）：
/// ```dart
/// unawaited(service.connect(kWbRealtimeEndpoint)); // 幂等；失败不抛异常
/// unawaited(service.joinBoard(boardId));           // 未连接时挂起，连接后自动补发
/// // M3 互动操作（服务端为权威；权限拒绝时返回 false，不抛异常）：
/// await service.raiseHand();
/// await service.grantControl(userId);
/// // 页面退出：
/// unawaited(service.leave());
/// ```
class WbRealtimeService extends ChangeNotifier {
  /// 创建服务；[clientLoader] / [bridgeFactory] 可注入（测试用），缺省走
  /// socketio_js 桥（浏览器实现 / VM 桩由条件导入决定）。
  WbRealtimeService({
    WbSocketIoClientLoader? clientLoader,
    WbSocketIoBridgeFactory? bridgeFactory,
    String clientVersion = '1.0.0',
  })  : _clientLoader = clientLoader ?? loadSocketIoClient,
        _bridgeFactory = bridgeFactory ?? createWbSocketIoBridge,
        _clientVersion = clientVersion;

  final WbSocketIoClientLoader _clientLoader;
  final WbSocketIoBridgeFactory _bridgeFactory;
  final String _clientVersion;

  WbSocketIoBridge? _bridge;
  Future<void>? _connectAttempt;
  String _endpoint = '';
  String? _pageId;
  bool _everConnected = false;
  bool _disposed = false;

  WbRealtimeStatus _status = WbRealtimeStatus.idle;
  String? _userId;
  String? _authMode;
  String? _sessionRole;
  String? _boardId;
  String? _role;
  String? _mode;
  String? _presenterId;
  bool _grantedWrite = false;
  bool _selfHandRaised = false;
  bool _removed = false;
  String? _removedReason;
  String? _removedMessage;
  final Map<String, WbCollabParticipant> _participants = <String, WbCollabParticipant>{};
  final Set<String> _followers = <String>{};
  WbRealtimeError? _lastError;

  // -------------------------------------------------------------------------
  // P4 协作通道（画布 op / 在场预览 / checkpoint；回调由页面级
  // `WbCollabSession` 装配，本服务不持有 CRDT 语义）
  // -------------------------------------------------------------------------

  /// 房间加入回执（`board:joined` 全量载荷，含 `snapshot` / `stateVector`）。
  ///
  /// 在参与者快照处理后投递；协作会话据此恢复 checkpoint 快照
  /// （仅本端 crdt doc 不存在时）。
  void Function(Map<String, Object?> payload)? onBoardJoined;

  /// 远端 op 批（`board:ops`；`replay` 为真 = 补差分回放帧）。
  void Function(List<Object?> ops, {bool replay})? onRemoteOps;

  /// 远端在场预览帧（`presence:preview`；服务端逐帧转发，此处以单元素
  /// 列表投递，与画布 `onRemotePreviews` 批次口径一致）。
  void Function(List<Object?> previews)? onRemotePreviews;

  /// checkpoint 上传请求（`board:checkpointRequest` 单播；无参数）。
  void Function()? onCheckpointRequest;

  /// join 水位提供者（重连增量回放锚点；返回 `{}` = 新成员语义：
  /// `board:joined` 携带 snapshot + 全量 replay）。
  Map<String, Object?> Function()? lastSeenVersionProvider;

  /// 当前连接状态。
  WbRealtimeStatus get status => _status;

  /// 当前 realtime 服务地址（normalize 后）；未连接过为空串。
  String get endpoint => _endpoint;

  /// 当前用户 id（`board:session` 单播；未连接为 null）。
  String? get userId => _userId;

  /// 认证模式（`jwt` / `anonymous`；`board:session` 携带）。
  String? get authMode => _authMode;

  /// 当前房间 id（最近一次 [joinBoard] 目标；[leave] 后为 null）。
  String? get boardId => _boardId;

  /// 当前用户在房间中的角色（`board:joined.role` 优先；`interactive:roleChanged`
  /// 单播与 `interactive:hostChanged` 会更新；未加入时回落 `board:session.role`）。
  String? get role => _role ?? _sessionRole;

  /// 当前用户自身角色（同 [role] 的语义别名；M3 提供给 UI 明确表达“我”的角色）。
  String? get selfRole => role;

  /// 房间模式（`board:joined.mode` / `interactive:modeChanged`；`free` / `present`）。
  String? get mode => _mode;

  /// 是否处于演示模式（M3；`mode == 'present'`）。
  bool get isPresenting => _mode == 'present';

  /// 当前演示者 userId（present 态为发起者；free 态为 null；M3）。
  String? get presenterId => _presenterId;

  /// 当前用户临时写权（`interactive:roleChanged` 单播 / `participants.updated`；M3）。
  bool get grantedWrite => _grantedWrite;

  /// 当前用户是否已举手（ack 成功本地置位；快照 / 增量同步；M3）。
  bool get selfHandRaised => _selfHandRaised;

  /// 参与者列表（插入序；一个 socket 一条）。
  List<WbCollabParticipant> get participants =>
      List<WbCollabParticipant>.unmodifiable(_participants.values);

  /// 举手者列表（插入序；M3；供 Host/CoHost 处理入口与面板标记）。
  List<WbCollabParticipant> get raisedHands => List<WbCollabParticipant>.unmodifiable(
        _participants.values.where((WbCollabParticipant p) => p.handRaised),
      );

  /// 正在跟随本端的用户集合（`interactive:follow` / `unfollow` 单播折叠；
  /// 跟随者离开房间时经参与者名单求交清理；M3.1）。
  Set<String> get followers => Set<String>.unmodifiable(_followers);

  /// 是否需要外发本端视口 / 页面帧（有跟随者，或本端为演示者；M3.1）。
  ///
  /// 页面在画布视口变化（200ms 节流）与切页时据此决定是否
  /// `presence:preview` 外发；无跟随者且非演示者时丢弃。
  bool get needsViewportBroadcast =>
      _followers.isNotEmpty ||
      (isPresenting && (_presenterId?.isNotEmpty ?? false) && _presenterId == _userId);

  /// 是否已被移出房间（`room:removed` 单播；服务端随后断开连接；M3）。
  bool get isRemoved => _removed;

  /// 被移出原因（`room:removed.reason`；无则为 null）。
  String? get removedReason => _removedReason;

  /// 被移出提示（`room:removed.message`；无则为 null）。
  String? get removedMessage => _removedMessage;

  /// 角色级别是否 ≥ Host（M3 权限判定辅助）。
  bool get isHost => _roleRank(role) >= _roleRank('Host');

  /// 角色级别是否 ≥ CoHost（M3 权限判定辅助：管理操作入口，对齐服务端角色矩阵）。
  bool get isCoHostOrHigher => _roleRank(role) >= _roleRank('CoHost');

  /// 角色级别是否 ≥ Presenter（M3 权限判定辅助）。
  bool get isPresenterOrHigher => _roleRank(role) >= _roleRank('Presenter');

  /// 是否可执行管理操作（授权 / 收权 / 演示 / 移出）：已连接且未被移出，角色 ≥ CoHost。
  bool get canManageInteractions => isConnected && !_removed && isCoHostOrHigher;

  /// 是否可举手：已连接、未被移出、角色在 Viewer～Presenter 之间
  /// （Host/CoHost 不举手；Guest 低于 Viewer，服务端拒绝，不给入口）。
  bool get canRaiseHand =>
      isConnected &&
      !_removed &&
      _roleRank(role) >= _roleRank('Viewer') &&
      !isCoHostOrHigher;

  /// 最近一次错误（连接错误 / `room:error` / join 拒绝）；成功连接后清空。
  WbRealtimeError? get lastError => _lastError;

  /// 是否已连接。
  bool get isConnected => _status == WbRealtimeStatus.connected;

  /// 连接 realtime 服务（幂等；失败不抛异常，状态收敛为 [WbRealtimeStatus.disconnected]）。
  ///
  /// [endpoint] 形如 `http://127.0.0.1:8790`（服务端 `/board` 命名空间由本服务拼接）。
  /// [token] 为 svc-api 签发的 JWT；缺省走服务端匿名 dev 回落（§9 降级）。
  Future<void> connect(String endpoint, {String? token}) {
    final String normalized = _normalizeEndpoint(endpoint);
    if (normalized.isEmpty) {
      _lastError = const WbRealtimeError(message: '未配置 realtime 服务地址（单机模式）');
      _setStatus(WbRealtimeStatus.disconnected);
      return Future<void>.value();
    }
    if (normalized == _endpoint &&
        (_status == WbRealtimeStatus.connecting ||
            _status == WbRealtimeStatus.connected ||
            _status == WbRealtimeStatus.reconnecting)) {
      return _connectAttempt ?? Future<void>.value();
    }
    final Future<void> attempt = _startConnect(normalized, token);
    _connectAttempt = attempt;
    return attempt;
  }

  /// 加入房间（`board:join`）。未连接时挂起；连接建立 / 重连成功后自动补发。
  Future<void> joinBoard(String boardId, {String? pageId}) async {
    if (boardId.isEmpty) {
      return;
    }
    _boardId = boardId;
    _pageId = pageId ?? _pageId;
    final WbSocketIoBridge? bridge = _bridge;
    if (bridge == null || !bridge.isConnected) {
      _notify();
      return;
    }
    await _sendJoin(bridge, boardId);
  }

  /// 离开房间并断开连接（幂等；回到本地模式；页面退出 / 主动下线调用）。
  ///
  /// 先发 `board:leave`（服务端据此广播 `participants {left}` 并关闭连接，
  /// §5.14）；随后本地断开，旧桥回调与本实例隔离；被移出态一并复位。
  Future<void> leave() async {
    final WbSocketIoBridge? bridge = _bridge;
    _bridge = null;
    _boardId = null;
    _pageId = null;
    _role = null;
    _mode = null;
    _presenterId = null;
    _grantedWrite = false;
    _selfHandRaised = false;
    _participants.clear();
    _followers.clear();
    _removed = false;
    _removedReason = null;
    _removedMessage = null;
    _setStatus(WbRealtimeStatus.disconnected);
    if (bridge == null) {
      return;
    }
    try {
      if (bridge.isConnected) {
        await bridge
            .emitWithAck('board:leave', const <String, Object?>{})
            .timeout(const Duration(milliseconds: 800));
      }
    } catch (_) {
      // 超时 / 未连接 / 平台不支持：忽略，继续本地断开。
    }
    try {
      bridge.disconnect();
    } catch (_) {
      // 桩桥等安全降级：忽略。
    }
  }

  Future<void> _startConnect(String endpoint, String? token) async {
    _disposeBridge();
    _endpoint = endpoint;
    _everConnected = false;
    _participants.clear();
    _followers.clear();
    _lastError = null;
    _mode = null;
    _presenterId = null;
    _grantedWrite = false;
    _selfHandRaised = false;
    _removed = false;
    _removedReason = null;
    _removedMessage = null;
    _setStatus(WbRealtimeStatus.connecting);
    try {
      await _clientLoader(endpoint);
      if (_disposed) {
        return;
      }
      final WbSocketIoBridge bridge = _bridgeFactory();
      _bridge = bridge;
      // 生命周期回调先注册（后注册覆盖先注册，桥接口约定）。
      bridge.onConnected((String socketId, String? transport) => _handleConnected(bridge, socketId, transport));
      bridge.onDisconnected((String reason) => _handleDisconnected(bridge, reason));
      bridge.onConnectError((WbSocketIoConnectError error) => _handleConnectError(bridge, error));
      bridge.connect(
        '$endpoint/board',
        WbSocketIoConnectOptions(
          auth: <String, Object?>{
            if (token != null && token.isNotEmpty) 'token': token,
            'clientVersion': _clientVersion,
          },
          reconnection: true,
        ),
      );
      // 事件处理器须在 connect 之后注册（socket 对象此时已创建）。
      bridge.on('board:session', (Object? payload) => _handleSession(bridge, payload));
      bridge.on('board:joined', (Object? payload) => _handleJoined(bridge, payload));
      bridge.on('board:participants', (Object? payload) => _handleParticipants(bridge, payload));
      bridge.on('room:error', (Object? payload) => _handleRoomError(bridge, payload));
      bridge.on('room:removed', (Object? payload) => _handleRemoved(bridge, payload));
      bridge.on('interactive:modeChanged', (Object? payload) => _handleModeChanged(bridge, payload));
      bridge.on('interactive:roleChanged', (Object? payload) => _handleRoleChanged(bridge, payload));
      bridge.on('interactive:hostChanged', (Object? payload) => _handleHostChanged(bridge, payload));
      bridge.on('interactive:follow',
          (Object? payload) => _handleFollowNotification(bridge, payload, following: true));
      bridge.on('interactive:unfollow',
          (Object? payload) => _handleFollowNotification(bridge, payload, following: false));
      bridge.on('board:ops', (Object? payload) => _handleRemoteOpsEvent(bridge, payload));
      bridge.on('presence:preview', (Object? payload) => _handleRemotePreviews(bridge, payload));
      bridge.on('board:checkpointRequest', (Object? payload) => _handleCheckpointRequest(bridge, payload));
    } catch (error) {
      _lastError = WbRealtimeError(message: _describeError(error));
      _disposeBridge();
      _setStatus(WbRealtimeStatus.disconnected);
    }
  }

  Future<void> _sendJoin(WbSocketIoBridge bridge, String boardId) async {
    try {
      final Object? ack = await bridge.emitWithAck('board:join', <String, Object?>{
        'boardId': boardId,
        if (_pageId != null && _pageId!.isNotEmpty) 'pageId': _pageId,
        // P4：join 同步携带本地水位（空对象 = 新成员语义：快照 + 全量回放）。
        'lastSeenVersion':
            lastSeenVersionProvider?.call() ?? const <String, Object?>{},
      });
      if (!identical(bridge, _bridge)) {
        return;
      }
      final Map<String, Object?>? map = _asMap(ack);
      if (map != null && map['ok'] == false) {
        final Map<String, Object?>? error = _asMap(map['error']);
        final Object? message = error?['message'];
        final Object? code = error?['code'];
        _lastError = WbRealtimeError(
          message: message is String && message.isNotEmpty ? message : '加入房间失败',
          code: code is String ? code : null,
        );
        _notify();
      }
    } catch (_) {
      // join 失败不阻塞 UI；重连路径（_handleConnected）会自动重试。
    }
  }

  void _handleConnected(WbSocketIoBridge source, String socketId, String? transport) {
    if (!identical(source, _bridge)) {
      return;
    }
    _everConnected = true;
    _lastError = null;
    _setStatus(WbRealtimeStatus.connected);
    final String? boardId = _boardId;
    if (boardId != null && boardId.isNotEmpty) {
      // 首连 / 重连成功后自动补 join（重连时服务端参与者表已随断开清除）。
      unawaited(_sendJoin(source, boardId));
    }
  }

  void _handleDisconnected(WbSocketIoBridge source, String reason) {
    if (!identical(source, _bridge)) {
      return;
    }
    // `io client disconnect` / `io server disconnect` 不会自动重连（socket.io 语义）。
    final bool withoutRetry = reason == 'io client disconnect' || reason == 'io server disconnect';
    _setStatus(withoutRetry ? WbRealtimeStatus.disconnected : WbRealtimeStatus.reconnecting);
  }

  void _handleConnectError(WbSocketIoBridge source, WbSocketIoConnectError error) {
    if (!identical(source, _bridge)) {
      return;
    }
    _lastError = WbRealtimeError(message: error.message, code: error.code);
    if (_everConnected || _status == WbRealtimeStatus.reconnecting) {
      // 重连尝试失败：保持「重连中」，socket.io 继续退避重试。
      _setStatus(WbRealtimeStatus.reconnecting);
    } else {
      // 首次连接失败：显示「未连接」（后台仍在自动重试，成功后转 connected）。
      _setStatus(WbRealtimeStatus.disconnected);
    }
  }

  void _handleSession(WbSocketIoBridge source, Object? payload) {
    if (!identical(source, _bridge)) {
      return;
    }
    final Map<String, Object?>? map = _asMap(payload);
    if (map == null) {
      return;
    }
    final Object? userId = map['userId'];
    if (userId is String && userId.isNotEmpty) {
      _userId = userId;
    }
    final Object? authMode = map['authMode'];
    if (authMode is String) {
      _authMode = authMode;
    }
    final Object? role = map['role'];
    if (role is String && role.isNotEmpty) {
      _sessionRole = role;
    }
    _notify();
  }

  void _handleJoined(WbSocketIoBridge source, Object? payload) {
    if (!identical(source, _bridge)) {
      return;
    }
    final Map<String, Object?>? map = _asMap(payload);
    if (map == null) {
      return;
    }
    final Object? boardId = map['boardId'];
    if (boardId is String && boardId.isNotEmpty) {
      _boardId = boardId;
    }
    final Object? role = map['role'];
    if (role is String && role.isNotEmpty) {
      _role = role;
    }
    final Object? mode = map['mode'];
    if (mode is String) {
      _mode = mode;
      if (mode == 'present') {
        // M3：present 态携带当前演示者（新加入者据此初始化跟随展示）。
        final Object? presenterId = map['presenterId'];
        if (presenterId is String && presenterId.isNotEmpty) {
          _presenterId = presenterId;
        }
      } else {
        _presenterId = null;
      }
    }
    final Object? rawParticipants = map['participants'];
    if (rawParticipants is List<Object?>) {
      // 快照语义：全量替换（插入序 = 服务端参与者表顺序）。
      _participants.clear();
      for (final Object? item in rawParticipants) {
        final WbCollabParticipant? participant = WbCollabParticipant.tryParse(item);
        if (participant != null) {
          _participants[participant.socketId] = participant;
        }
      }
      _syncSelfState();
      _pruneFollowers();
    }
    // P4：joined 全量透传（含 snapshot / stateVector）供协作会话恢复快照。
    onBoardJoined?.call(map);
    _notify();
  }

  void _handleParticipants(WbSocketIoBridge source, Object? payload) {
    if (!identical(source, _bridge)) {
      return;
    }
    final Map<String, Object?>? map = _asMap(payload);
    if (map == null) {
      return;
    }
    bool changed = false;
    changed = _applyUpsert(map['joined']) || changed;
    changed = _applyUpsert(map['updated']) || changed;
    changed = _applyLeft(map['left']) || changed;
    changed = _pruneFollowers() || changed;
    if (changed) {
      _syncSelfState();
      _notify();
    }
  }

  void _handleRoomError(WbSocketIoBridge source, Object? payload) {
    if (!identical(source, _bridge)) {
      return;
    }
    final Map<String, Object?>? map = _asMap(payload);
    if (map == null) {
      return;
    }
    final Object? message = map['message'];
    final Object? code = map['code'];
    _lastError = WbRealtimeError(
      message: message is String && message.isNotEmpty ? message : 'room:error',
      code: code is String ? code : null,
    );
    _notify();
  }

  /// `joined` / `updated` 增量：按 socketId 新增或替换（幂等）。
  bool _applyUpsert(Object? raw) {
    if (raw is! List<Object?>) {
      return false;
    }
    bool changed = false;
    for (final Object? item in raw) {
      final WbCollabParticipant? participant = WbCollabParticipant.tryParse(item);
      if (participant == null) {
        continue;
      }
      _participants[participant.socketId] = participant;
      changed = true;
    }
    return changed;
  }

  /// `left` 增量：按 socketId 移除。
  bool _applyLeft(Object? raw) {
    if (raw is! List<Object?>) {
      return false;
    }
    bool changed = false;
    for (final Object? item in raw) {
      final WbCollabParticipant? participant = WbCollabParticipant.tryParse(item);
      if (participant == null) {
        continue;
      }
      if (_participants.remove(participant.socketId) != null) {
        changed = true;
      }
    }
    return changed;
  }

  /// 与当前参与者名单求交：剔除已不在房间的跟随者（对齐桌面端
  /// `_pruneFollowers` 语义；名单为空保守等待，避免快照缺失误清）；
  /// 返回是否发生剔除。
  bool _pruneFollowers() {
    if (_followers.isEmpty || _participants.isEmpty) {
      return false;
    }
    final Set<String> online = <String>{
      for (final WbCollabParticipant participant in _participants.values)
        participant.userId,
    };
    final int before = _followers.length;
    _followers.removeWhere((String id) => !online.contains(id));
    return _followers.length != before;
  }

  // -------------------------------------------------------------------------
  // M3 interactive 发送（C→S；轻量 ack：成功 true / 拒绝 false，不抛异常）
  //
  // 服务端广播（modeChanged / participants updated）均排除发起者自身，
  // 故 ack 成功后本端做确定性的本地更新（幂等；快照 / 增量到达后仍一致）。
  // -------------------------------------------------------------------------

  /// 举手（`interactive:raiseHand`；最低 Viewer；不落审计）。
  Future<bool> raiseHand() async {
    final bool ok = await _sendInteractive('interactive:raiseHand', const <String, Object?>{});
    if (ok) {
      _selfHandRaised = true;
      _patchParticipantsByUserId(_userId, (WbCollabParticipant p) => p.copyWith(handRaised: true));
      _notify();
    }
    return ok;
  }

  /// 收手（`interactive:lowerHand`）。
  Future<bool> lowerHand() async {
    final bool ok = await _sendInteractive('interactive:lowerHand', const <String, Object?>{});
    if (ok) {
      _selfHandRaised = false;
      _patchParticipantsByUserId(_userId, (WbCollabParticipant p) => p.copyWith(handRaised: false));
      _notify();
    }
    return ok;
  }

  /// 授权临时写权（`interactive:grantControl`；最低 CoHost；目标非 Host/CoHost）。
  Future<bool> grantControl(String userId) async {
    if (userId.isEmpty) {
      return false;
    }
    final bool ok =
        await _sendInteractive('interactive:grantControl', <String, Object?>{'userId': userId});
    if (ok) {
      _patchParticipantsByUserId(userId, (WbCollabParticipant p) => p.copyWith(grantedWrite: true));
      _notify();
    }
    return ok;
  }

  /// 收回临时写权（`interactive:revokeControl`；最低 CoHost；目标非 Host/CoHost）。
  Future<bool> revokeControl(String userId) async {
    if (userId.isEmpty) {
      return false;
    }
    final bool ok =
        await _sendInteractive('interactive:revokeControl', <String, Object?>{'userId': userId});
    if (ok) {
      _patchParticipantsByUserId(userId, (WbCollabParticipant p) => p.copyWith(grantedWrite: false));
      _notify();
    }
    return ok;
  }

  /// 开始演示（`interactive:startPresent`；最低 CoHost；presenterId = 发起者）。
  Future<bool> startPresent() async {
    final bool ok = await _sendInteractive('interactive:startPresent', const <String, Object?>{});
    if (ok) {
      _mode = 'present';
      _presenterId = _userId;
      _notify();
    }
    return ok;
  }

  /// 结束演示（`interactive:stopPresent`；最低 Presenter，且须处于 present）。
  Future<bool> stopPresent() async {
    final bool ok = await _sendInteractive('interactive:stopPresent', const <String, Object?>{});
    if (ok) {
      _mode = 'free';
      _presenterId = null;
      _notify();
    }
    return ok;
  }

  /// 移出用户（`interactive:removeUser`；发起者 ≥CoHost 且级别严格大于目标）。
  ///
  /// 本端仅发送：目标收到 `room:removed` 单播后断开，其余成员经
  /// `board:participants {left}` 感知；Web 端暂未挂 UI 入口（见模块文档 §2.7）。
  Future<bool> removeUser(String userId) {
    if (userId.isEmpty) {
      return Future<bool>.value(false);
    }
    return _sendInteractive('interactive:removeUser', <String, Object?>{'userId': userId});
  }

  /// interactive 通用发送：连接可用时 `emitWithAck`；ack `{ok:true}` 返回 true。
  ///
  /// 未连接 / 已移除 / ack 拒绝（含异常 / 超时兜底）→ false；
  /// 失败**不写入** [lastError]（不干扰连接状态提示），由 UI 以轻提示反馈。
  Future<bool> _sendInteractive(String event, Object? payload) async {
    final WbSocketIoBridge? bridge = _bridge;
    if (bridge == null || !bridge.isConnected || _removed) {
      return false;
    }
    try {
      final Object? ack = await bridge.emitWithAck(event, payload);
      if (!identical(bridge, _bridge)) {
        return false;
      }
      final Map<String, Object?>? map = _asMap(ack);
      return map != null && map['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // P4 协作通道（发送）
  // -------------------------------------------------------------------------

  /// 发送本地 op 批（`board:ops`）。
  ///
  /// 返回服务端 ack（`{ok}` / `{ok,dup}` / `{ok:false,missingSeqs}` /
  /// 拒绝信封）；未连接 / 已移除 / 异常返回 null（调用方静默跳过）。
  Future<Map<String, Object?>?> sendOps(List<Object?> ops) async {
    final WbSocketIoBridge? bridge = _bridge;
    if (bridge == null || !bridge.isConnected || _removed || ops.isEmpty) {
      return null;
    }
    try {
      final Object? ack = await bridge.emitWithAck('board:ops', ops);
      if (!identical(bridge, _bridge)) {
        return null;
      }
      return _asMap(ack);
    } catch (_) {
      return null;
    }
  }

  /// 发送在场预览帧（`presence:preview`；fire-and-forget）。
  ///
  /// 服务端附加发送者 userId 后转发同房其他成员（排除发送者）。
  void sendPreview(Map<String, Object?> preview) {
    final WbSocketIoBridge? bridge = _bridge;
    if (bridge == null || !bridge.isConnected || _removed || preview.isEmpty) {
      return;
    }
    try {
      bridge.emit('presence:preview', preview);
    } catch (_) {
      // 安全降级：高频通道丢弃单帧不影响一致性。
    }
  }

  /// 上报 checkpoint（`board:checkpoint`；服务端仅 Host/CoHost 接受）。
  ///
  /// 尽力而为：拒绝 / 超时 / 未连接均静默（下次阈值触发会重新请求）。
  Future<void> sendCheckpoint({
    required Map<String, Object?> stateVector,
    required String payload,
  }) async {
    final WbSocketIoBridge? bridge = _bridge;
    if (bridge == null || !bridge.isConnected || _removed) {
      return;
    }
    try {
      await bridge.emitWithAck('board:checkpoint', <String, Object?>{
        'stateVector': stateVector,
        'payload': payload,
      });
    } catch (_) {
      // 忽略：checkpoint 为旁路可靠性通道。
    }
  }

  // -------------------------------------------------------------------------
  // M3 interactive 订阅（S→C）
  // -------------------------------------------------------------------------

  void _handleModeChanged(WbSocketIoBridge source, Object? payload) {
    if (!identical(source, _bridge)) {
      return;
    }
    final Map<String, Object?>? map = _asMap(payload);
    if (map == null) {
      return;
    }
    final Object? mode = map['mode'];
    if (mode is String && mode.isNotEmpty) {
      _mode = mode;
    }
    if (_mode == 'present') {
      // startPresent 携带 presenterId；缺省回落 `by`（发起者）。
      final Object? presenterId = map['presenterId'];
      final Object? by = map['by'];
      if (presenterId is String && presenterId.isNotEmpty) {
        _presenterId = presenterId;
      } else if (by is String && by.isNotEmpty) {
        _presenterId = by;
      }
    } else {
      _presenterId = null;
    }
    _notify();
  }

  void _handleRoleChanged(WbSocketIoBridge source, Object? payload) {
    if (!identical(source, _bridge)) {
      return;
    }
    final Map<String, Object?>? map = _asMap(payload);
    if (map == null) {
      return;
    }
    final Object? targetUserId = map['userId'];
    if (targetUserId is! String || targetUserId.isEmpty || targetUserId != _userId) {
      // 仅处理指向自身的单播；他人角色变更经 board:participants updated 同步。
      return;
    }
    final Object? role = map['role'];
    if (role is String && role.isNotEmpty) {
      _role = role;
    }
    if (map.containsKey('grantedWrite')) {
      _grantedWrite = map['grantedWrite'] == true;
    }
    _notify();
  }

  void _handleHostChanged(WbSocketIoBridge source, Object? payload) {
    if (!identical(source, _bridge)) {
      return;
    }
    final Map<String, Object?>? map = _asMap(payload);
    if (map == null) {
      return;
    }
    final Object? newHostId = map['newHostId'];
    if (newHostId is! String || newHostId.isEmpty) {
      return;
    }
    bool changed = false;
    if (newHostId == _userId) {
      _role = 'Host';
      changed = true;
    }
    // 乐观同步参与者表角色（服务端随后广播 participants updated，先后到达均幂等）。
    changed = _patchParticipantsByUserId(
          newHostId,
          (WbCollabParticipant p) => p.copyWith(role: 'Host'),
        ) ||
        changed;
    if (changed) {
      _notify();
    }
  }

  /// `interactive:follow` / `unfollow` 入站（单播 `{followerUserId}`；
  /// 无 ack 尽力而为）。折叠跟随者集合并通知（驱动
  /// [needsViewportBroadcast]；页面据此外发 viewport / page 帧）。
  void _handleFollowNotification(
    WbSocketIoBridge source,
    Object? payload, {
    required bool following,
  }) {
    if (!identical(source, _bridge)) {
      return;
    }
    final Map<String, Object?>? map = _asMap(payload);
    final Object? followerId = map?['followerUserId'];
    if (followerId is! String || followerId.isEmpty) {
      return;
    }
    final bool changed =
        following ? _followers.add(followerId) : _followers.remove(followerId);
    if (changed) {
      _notify();
    }
  }

  void _handleRemoved(WbSocketIoBridge source, Object? payload) {
    if (!identical(source, _bridge)) {
      return;
    }
    final Map<String, Object?>? map = _asMap(payload);
    final Object? reason = map?['reason'];
    final Object? message = map?['message'];
    _removed = true;
    _removedReason = reason is String && reason.isNotEmpty ? reason : null;
    _removedMessage = message is String && message.isNotEmpty ? message : null;
    _notify();
  }

  // -------------------------------------------------------------------------
  // P4 协作订阅（S→C）
  // -------------------------------------------------------------------------

  /// `board:ops` 入站：解包多参 `(ops, meta)` 或单参数组形态后投递。
  ///
  /// 判别口径：桥对两参发射按 `[ops, meta]` 透传——要求首元素为
  /// List（ops 数组）且次元素为 Map（meta）；单参数组的每个元素均为
  /// op 对象（Map），不会与包裹形态混淆。
  void _handleRemoteOpsEvent(WbSocketIoBridge source, Object? payload) {
    if (!identical(source, _bridge)) {
      return;
    }
    if (payload is! List) {
      return;
    }
    final List<Object?> ops;
    bool replay = false;
    if (payload.length == 2 && payload[0] is List && payload[1] is Map) {
      ops = (payload[0] as List).cast<Object?>();
      final Map<String, Object?>? meta = _asMap(payload[1]);
      replay = meta?['replay'] == true;
    } else {
      ops = payload.cast<Object?>();
    }
    if (ops.isEmpty) {
      return;
    }
    onRemoteOps?.call(ops, replay: replay);
  }

  /// `presence:preview` 入站：单帧包装为单元素列表投递（批次口径）。
  void _handleRemotePreviews(WbSocketIoBridge source, Object? payload) {
    if (!identical(source, _bridge)) {
      return;
    }
    final Map<String, Object?>? map = _asMap(payload);
    if (map == null || map.isEmpty) {
      return;
    }
    onRemotePreviews?.call(<Object?>[map]);
  }

  /// `board:checkpointRequest` 入站：通知协作会话上报状态。
  void _handleCheckpointRequest(WbSocketIoBridge source, Object? payload) {
    if (!identical(source, _bridge)) {
      return;
    }
    onCheckpointRequest?.call();
  }

  /// 从参与者表同步自身互动状态（grantedWrite / handRaised）。
  ///
  /// 在加入快照（全量替换后）与增量更新后调用；多条同 userId 连接时取首个命中。
  void _syncSelfState() {
    final String? selfId = _userId;
    if (selfId == null) {
      return;
    }
    for (final WbCollabParticipant participant in _participants.values) {
      if (participant.userId == selfId) {
        _grantedWrite = participant.grantedWrite;
        _selfHandRaised = participant.handRaised;
        return;
      }
    }
  }

  /// 按 userId 就地更新参与者条目（保持插入序）；返回是否有条目变化。
  bool _patchParticipantsByUserId(
    String? userId,
    WbCollabParticipant Function(WbCollabParticipant participant) update,
  ) {
    if (userId == null || userId.isEmpty) {
      return false;
    }
    bool changed = false;
    for (final MapEntry<String, WbCollabParticipant> entry in _participants.entries.toList()) {
      if (entry.value.userId != userId) {
        continue;
      }
      final WbCollabParticipant next = update(entry.value);
      if (next != entry.value) {
        _participants[entry.key] = next;
        changed = true;
      }
    }
    return changed;
  }

  void _setStatus(WbRealtimeStatus status) {
    _status = status;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _disposeBridge() {
    final WbSocketIoBridge? bridge = _bridge;
    _bridge = null;
    if (bridge == null) {
      return;
    }
    try {
      bridge.off();
    } catch (_) {
      // 安全降级：忽略。
    }
    try {
      bridge.disconnect();
    } catch (_) {
      // 安全降级：忽略。
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _disposeBridge();
    super.dispose();
  }
}

/// 归一化 endpoint（去空白与尾部 `/`）。
String _normalizeEndpoint(String endpoint) {
  String value = endpoint.trim();
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// 错误描述（`WbSocketIoLoadException` 取其 message，避免重复前缀）。
String _describeError(Object error) {
  if (error is WbSocketIoLoadException) {
    return error.message;
  }
  return '$error';
}

/// `dartify` 载荷兼容转换：键必须为 String，否则返回 null。
Map<String, Object?>? _asMap(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map<Object?, Object?>) {
    final Map<String, Object?> out = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final Object? key = entry.key;
      if (key is! String) {
        return null;
      }
      out[key] = entry.value;
    }
    return out;
  }
  return null;
}

/// 角色级别表（对齐服务端 `services/realtime/src/types.ts` ROLE_RANK：
/// `Host > CoHost > Presenter > Participant > Viewer > Guest`）。
const Map<String, int> _kRoleRanks = <String, int>{
  'Host': 5,
  'CoHost': 4,
  'Presenter': 3,
  'Participant': 2,
  'Viewer': 1,
  'Guest': 0,
};

/// 角色级别（未知 / 未加入角色为 -1，任何权限判定均不通过）。
int _roleRank(String? role) => _kRoleRanks[role] ?? -1;
