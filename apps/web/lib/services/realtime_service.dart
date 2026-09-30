/// W1 实时协作服务：成员 / 连接状态 / presence 元数据（T1.8）。
///
/// 口径（D-H）：Web M1 = **W1 层**——参与者列表 / 连接状态可见即可；
/// **不发送、不应用画布 op**（画布协作 W2 依赖 WASM 核心，后置）。
///
/// 传输抽象（D-G）：底层统一经 [WbSocketIoBridge]（`socketio_js.dart` 桥），
/// 脚本加载器 / 桥工厂可注入——VM（纯 Dart）测试注入桩桥，不加载 JS。
///
/// 事件处理（《互动白板实时协同设计文档》§6）：
/// - C→S：`board:join`（加入 / 切换房间）、`board:leave`（退出）；
/// - S→C：`board:session`（连接后单播 `{userId, authMode, role}`）、
///   `board:joined`（join 快照：`participants` / `role` / `mode`）、
///   `board:participants`（`joined` / `left` / `updated` 增量）、`room:error`。
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
  });

  /// 用户 id（服务端解析：JWT sub 或匿名 dev 回落 `anon-*`）。
  final String userId;

  /// 会话 socket id（服务端参与者表主键，重连会变）。
  final String socketId;

  /// 房间角色（`Host / CoHost / Presenter / Participant / Viewer / Guest`）。
  final String role;

  /// 加入时间（epoch 毫秒）。
  final int joinedAtMs;

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
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WbCollabParticipant &&
      other.userId == userId &&
      other.socketId == socketId &&
      other.role == role &&
      other.joinedAtMs == joinedAtMs;

  @override
  int get hashCode => Object.hash(userId, socketId, role, joinedAtMs);

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
  final Map<String, WbCollabParticipant> _participants = <String, WbCollabParticipant>{};
  WbRealtimeError? _lastError;

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

  /// 当前用户在房间中的角色（`board:joined.role`，未加入时回落 `board:session.role`）。
  String? get role => _role ?? _sessionRole;

  /// 房间模式（`board:joined.mode`；M1 恒为 `free`）。
  String? get mode => _mode;

  /// 参与者列表（插入序；一个 socket 一条）。
  List<WbCollabParticipant> get participants =>
      List<WbCollabParticipant>.unmodifiable(_participants.values);

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

  /// 离开房间并断开连接（幂等；页面退出 / 主动下线调用）。
  ///
  /// 先发 `board:leave`（服务端据此广播 `participants {left}` 并关闭连接，
  /// §5.14）；随后本地断开，旧桥回调与本实例隔离。
  Future<void> leave() async {
    final WbSocketIoBridge? bridge = _bridge;
    _bridge = null;
    _boardId = null;
    _pageId = null;
    _role = null;
    _mode = null;
    _participants.clear();
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
    _lastError = null;
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
    }
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
    if (changed) {
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
