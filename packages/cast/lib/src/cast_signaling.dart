/// 投屏信令客户端（复用 realtime 服务的 `/cast` namespace）。
///
/// 传输选型：`socket_io_client`（纯 Dart，VM + Web 通用）。
/// 现有白板协同走 C++ 引擎的 Socket.IO 传输（FFI），其协议面为 `/board` 专用；
/// 投屏事件独立（`cast:*`），因此不扩展 FFI 符号表，Dart 侧直连同一服务的
/// 第二个 namespace——**不新建独立信令服务**。
///
/// 约定：
/// - 所有请求走 ack；失败统一抛 [WbCastFailure]（code 对齐服务端）；
/// - SDP / ICE 是单向事件（服务端只转发，不 ack）；
/// - 服务端分配的 `senderId` 是 SDP/ICE 的关联键，客户端不得自行生成。
library;

import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as sio;

import 'cast_models.dart';

/// 服务端 → 客户端的投屏事件（控制器消费）。
sealed class WbCastSignalEvent {
  const WbCastSignalEvent();
}

/// 传输已连接（首次连接与重连成功都会触发）。
class WbCastTransportConnected extends WbCastSignalEvent {
  const WbCastTransportConnected();
}

/// 传输断开（Socket.IO 会自动重连；服务端有 15s / 30s 宽限）。
class WbCastTransportDisconnected extends WbCastSignalEvent {
  const WbCastTransportDisconnected(this.reason);

  /// Socket.IO 断开原因。
  final String reason;
}

/// 传输错误（连接失败 / 鉴权失败）。
class WbCastTransportError extends WbCastSignalEvent {
  const WbCastTransportError(this.message);

  /// 可直接展示的错误。
  final String message;
}

/// 房间快照更新（接受 / 拒绝 / 换码 / 设置变化）。
class WbCastRoomUpdated extends WbCastSignalEvent {
  const WbCastRoomUpdated(this.room);

  /// 最新快照。
  final WbCastRoomSnapshot room;
}

/// 新发送端申请（autoAccept=false）。
class WbCastRequestReceived extends WbCastSignalEvent {
  const WbCastRequestReceived({
    required this.senderId,
    required this.deviceName,
    required this.userId,
  });

  /// 发送端标识。
  final String senderId;

  /// 设备名称。
  final String deviceName;

  /// 用户 id。
  final String userId;
}

/// 发送端被接受（接收端 manual accept 或 autoAccept）。
class WbCastAccepted extends WbCastSignalEvent {
  const WbCastAccepted({required this.senderId, required this.code});

  /// 发送端标识。
  final String senderId;

  /// 当前投屏码（可能已换码）。
  final String code;
}

/// 发送端被拒绝（释放席位）。
class WbCastRejected extends WbCastSignalEvent {
  const WbCastRejected({required this.senderId, required this.reason});

  /// 发送端标识。
  final String senderId;

  /// 拒绝原因。
  final String reason;
}

/// 收到 SDP Offer（接收端）。
class WbCastOfferReceived extends WbCastSignalEvent {
  const WbCastOfferReceived({required this.senderId, required this.sdp});

  /// 发送端标识。
  final String senderId;

  /// SDP 文本。
  final String sdp;
}

/// 收到 SDP Answer（发送端）。
class WbCastAnswerReceived extends WbCastSignalEvent {
  const WbCastAnswerReceived({required this.senderId, required this.sdp});

  /// 发送端标识。
  final String senderId;

  /// SDP 文本。
  final String sdp;
}

/// 收到 ICE Candidate（`candidate == null` 表示候选结束）。
class WbCastIceReceived extends WbCastSignalEvent {
  const WbCastIceReceived({required this.senderId, required this.candidate});

  /// 发送端标识。
  final String senderId;

  /// 候选 JSON 或 null。
  final WbCastIceCandidate? candidate;
}

/// 单路离开（主动离开 / 被踢 / 宽限超时）。
class WbCastPeerLeft extends WbCastSignalEvent {
  const WbCastPeerLeft({required this.senderId, required this.reason});

  /// 发送端标识。
  final String senderId;

  /// `left` / `kicked` / `rejected` / `disconnected`。
  final String reason;
}

/// 房间关闭（主动关闭 / 过期 / 接收端离线超时）。
class WbCastRoomClosed extends WbCastSignalEvent {
  const WbCastRoomClosed({required this.code, required this.reason});

  /// 房间号。
  final String code;

  /// `closed` / `expired` / `receiver-left`。
  final String reason;
}

/// 服务端错误（同时可能来自失败 ack 的重复广播）。
class WbCastErrorEvent extends WbCastSignalEvent {
  const WbCastErrorEvent({required this.code, required this.message});

  /// 错误码。
  final String code;

  /// 错误说明。
  final String message;
}

/// 投屏信令端口（控制器可注入 fake 做单测）。
abstract interface class WbCastSignaling {
  /// 事件流（广播）。
  Stream<WbCastSignalEvent> get events;

  /// 是否已连接。
  bool get connected;

  /// 连接 `endpoint`（如 `http://127.0.0.1:8790`）。
  Future<void> connect({required String endpoint, String? token});

  /// 主动断开（关闭 Socket，不再自动重连）。
  Future<void> disconnect();

  /// 建房（服务端分配四位码）。
  Future<WbCastCreateResult> createRoom({
    String? deviceName,
    int? maxSenders,
    bool? autoAccept,
    int? ttlMs,
  });

  /// 断线恢复（receiverToken 或 senderToken）。
  Future<WbCastResumeResult> resume({
    required String code,
    String? receiverToken,
    String? senderToken,
  });

  /// 更新房间设置。
  Future<WbCastRoomSnapshot> updateSettings({
    int? maxSenders,
    bool? autoAccept,
    int? extendTtlMs,
  });

  /// 换码（旧码立即失效）。
  Future<WbCastCreateResult> regenerate();

  /// 关闭房间。
  Future<void> closeRoom();

  /// 心跳续期。
  Future<void> heartbeat();

  /// 发送端加入。
  Future<WbCastJoinResult> join({
    required String code,
    required String deviceName,
  });

  /// 接收端接受 / 拒绝某一路。
  Future<void> decide(String senderId, bool accept, {String? reason});

  /// 离开（发送端自离；接收端携带 senderId 踢出单路）。
  Future<void> leave({String? senderId, String? reason});

  /// 发送 SDP Offer（发送端）。
  Future<void> sendOffer(String sdp, {String? senderId});

  /// 发送 SDP Answer（接收端，必须指定 senderId）。
  Future<void> sendAnswer(String sdp, {required String senderId});

  /// 发送 ICE Candidate（candidate 为 null 表示候选结束）。
  Future<void> sendIce(WbCastIceCandidate? candidate, {String? senderId});
}

/// `/cast` namespace 的 Socket.IO 实现。
class WbCastSocketSignaling implements WbCastSignaling {
  /// 创建实现。
  WbCastSocketSignaling({this.ackTimeout = const Duration(seconds: 10)});

  /// 请求 ack 超时。
  final Duration ackTimeout;

  final StreamController<WbCastSignalEvent> _events =
      StreamController<WbCastSignalEvent>.broadcast();

  sio.Socket? _socket;
  String? _baseEndpoint;
  String? _token;

  @override
  Stream<WbCastSignalEvent> get events => _events.stream;

  @override
  bool get connected => _socket?.connected ?? false;

  @override
  Future<void> connect({required String endpoint, String? token}) async {
    final String base = _normalizeEndpoint(endpoint);
    if (_socket != null && _baseEndpoint == base && _token == token) {
      if (_socket!.connected) return;
      _socket!.connect();
      await _awaitConnected();
      return;
    }
    await disconnect();
    _baseEndpoint = base;
    _token = token;

    final sio.Socket socket = sio.io(
      '$base/cast',
      sio.OptionBuilder()
          .setTransports(<String>['websocket'])
          .disableAutoConnect()
          .setAuth(<String, dynamic>{if (token != null) 'token': token})
          .enableReconnection()
          .setReconnectionAttempts(8)
          .setReconnectionDelay(600)
          .setReconnectionDelayMax(4000)
          .setTimeout(10000)
          .build(),
    );
    _socket = socket;

    socket.onConnect((_) => _emit(const WbCastTransportConnected()));
    socket.onDisconnect((Object? reason) =>
        _emit(WbCastTransportDisconnected('$reason')));
    socket.onConnectError((Object? error) {
      _emit(WbCastTransportError('投屏服务连接失败：$error'));
    });
    socket.on('error', (Object? error) {
      _emit(WbCastTransportError('投屏服务错误：$error'));
    });

    socket.on('cast:room', (Object? data) {
      final Map<String, dynamic>? json = _asMap(data);
      if (json != null) _emit(WbCastRoomUpdated(WbCastRoomSnapshot.fromJson(json)));
    });
    socket.on('cast:request', (Object? data) {
      final Map<String, dynamic>? json = _asMap(data);
      if (json == null) return;
      _emit(WbCastRequestReceived(
        senderId: _string(json['senderId']),
        deviceName: _string(json['deviceName'], fallback: '未知设备'),
        userId: _string(json['userId']),
      ));
    });
    socket.on('cast:accepted', (Object? data) {
      final Map<String, dynamic>? json = _asMap(data);
      if (json == null) return;
      _emit(WbCastAccepted(
        senderId: _string(json['senderId']),
        code: _string(json['code']),
      ));
    });
    socket.on('cast:rejected', (Object? data) {
      final Map<String, dynamic>? json = _asMap(data);
      if (json == null) return;
      _emit(WbCastRejected(
        senderId: _string(json['senderId']),
        reason: _string(json['reason'], fallback: 'rejected'),
      ));
    });
    socket.on('cast:offer', (Object? data) {
      final Map<String, dynamic>? json = _asMap(data);
      if (json == null) return;
      _emit(WbCastOfferReceived(
        senderId: _string(json['senderId']),
        sdp: _string(json['sdp']),
      ));
    });
    socket.on('cast:answer', (Object? data) {
      final Map<String, dynamic>? json = _asMap(data);
      if (json == null) return;
      _emit(WbCastAnswerReceived(
        senderId: _string(json['senderId']),
        sdp: _string(json['sdp']),
      ));
    });
    socket.on('cast:ice', (Object? data) {
      final Map<String, dynamic>? json = _asMap(data);
      if (json == null) return;
      final Object? candidate = json['candidate'];
      _emit(WbCastIceReceived(
        senderId: _string(json['senderId']),
        candidate: candidate is Map
            ? candidate.map((Object? key, Object? value) =>
                MapEntry<String, dynamic>('$key', value))
            : null,
      ));
    });
    socket.on('cast:peerLeft', (Object? data) {
      final Map<String, dynamic>? json = _asMap(data);
      if (json == null) return;
      _emit(WbCastPeerLeft(
        senderId: _string(json['senderId']),
        reason: _string(json['reason'], fallback: 'left'),
      ));
    });
    socket.on('cast:roomClosed', (Object? data) {
      final Map<String, dynamic>? json = _asMap(data);
      if (json == null) return;
      _emit(WbCastRoomClosed(
        code: _string(json['code']),
        reason: _string(json['reason'], fallback: 'closed'),
      ));
    });
    socket.on('cast:error', (Object? data) {
      final Map<String, dynamic>? json = _asMap(data);
      if (json == null) return;
      _emit(WbCastErrorEvent(
        code: _string(json['code'], fallback: 'Error'),
        message: _string(json['message'], fallback: '投屏服务返回错误'),
      ));
    });

    final Future<void> connected = _awaitConnected();
    socket.connect();
    await connected;
  }

  @override
  Future<void> disconnect() async {
    final sio.Socket? socket = _socket;
    _socket = null;
    _baseEndpoint = null;
    _token = null;
    if (socket != null) {
      socket.dispose();
    }
  }

  @override
  Future<WbCastCreateResult> createRoom({
    String? deviceName,
    int? maxSenders,
    bool? autoAccept,
    int? ttlMs,
  }) async {
    final Map<String, dynamic> ack = await _emitAck('cast:create', <String, dynamic>{
      if (deviceName != null) 'deviceName': deviceName,
      if (maxSenders != null) 'maxSenders': maxSenders,
      if (autoAccept != null) 'autoAccept': autoAccept,
      if (ttlMs != null) 'ttlMs': ttlMs,
    });
    return WbCastCreateResult(
      room: WbCastRoomSnapshot.fromJson(_asMap(ack['room']) ?? const <String, dynamic>{}),
      receiverToken: _string(ack['receiverToken']),
    );
  }

  @override
  Future<WbCastResumeResult> resume({
    required String code,
    String? receiverToken,
    String? senderToken,
  }) async {
    final Map<String, dynamic> ack = await _emitAck('cast:resume', <String, dynamic>{
      'code': code,
      if (receiverToken != null) 'receiverToken': receiverToken,
      if (senderToken != null) 'senderToken': senderToken,
    });
    final String role = _string(ack['role'], fallback: 'receiver');
    return WbCastResumeResult(
      role: role == 'sender' ? WbCastRole.sender : WbCastRole.receiver,
      room: ack['room'] is Map
          ? WbCastRoomSnapshot.fromJson(_asMap(ack['room'])!)
          : null,
      senderId: ack['senderId'] is String ? ack['senderId'] as String : null,
      senderState: ack['state'] is String ? ack['state'] as String : null,
    );
  }

  @override
  Future<WbCastRoomSnapshot> updateSettings({
    int? maxSenders,
    bool? autoAccept,
    int? extendTtlMs,
  }) async {
    final Map<String, dynamic> ack = await _emitAck('cast:update', <String, dynamic>{
      if (maxSenders != null) 'maxSenders': maxSenders,
      if (autoAccept != null) 'autoAccept': autoAccept,
      if (extendTtlMs != null) 'extendTtlMs': extendTtlMs,
    });
    return WbCastRoomSnapshot.fromJson(
      _asMap(ack['room']) ?? const <String, dynamic>{},
    );
  }

  @override
  Future<WbCastCreateResult> regenerate() async {
    final Map<String, dynamic> ack = await _emitAck('cast:regenerate', const <String, dynamic>{});
    return WbCastCreateResult(
      room: WbCastRoomSnapshot.fromJson(_asMap(ack['room']) ?? const <String, dynamic>{}),
      receiverToken: _string(ack['receiverToken']),
    );
  }

  @override
  Future<void> closeRoom() async {
    await _emitAck('cast:close', const <String, dynamic>{});
  }

  @override
  Future<void> heartbeat() async {
    await _emitAck('cast:heartbeat', const <String, dynamic>{});
  }

  @override
  Future<WbCastJoinResult> join({
    required String code,
    required String deviceName,
  }) async {
    final Map<String, dynamic> ack = await _emitAck('cast:join', <String, dynamic>{
      'code': code,
      'deviceName': deviceName,
    });
    return WbCastJoinResult(
      code: _string(ack['code'], fallback: code),
      senderId: _string(ack['senderId']),
      senderToken: _string(ack['senderToken']),
      accepted: ack['accepted'] == true,
      maxSenders: _int(ack['maxSenders'], fallback: 4),
    );
  }

  @override
  Future<void> decide(String senderId, bool accept, {String? reason}) async {
    await _emitAck('cast:decision', <String, dynamic>{
      'senderId': senderId,
      'accept': accept,
      if (reason != null) 'reason': reason,
    });
  }

  @override
  Future<void> leave({String? senderId, String? reason}) async {
    await _emitAck('cast:leave', <String, dynamic>{
      if (senderId != null) 'senderId': senderId,
      if (reason != null) 'reason': reason,
    });
  }

  @override
  Future<void> sendOffer(String sdp, {String? senderId}) async {
    _emitRaw('cast:offer', <String, dynamic>{
      'sdp': sdp,
      if (senderId != null) 'senderId': senderId,
    });
  }

  @override
  Future<void> sendAnswer(String sdp, {required String senderId}) async {
    _emitRaw('cast:answer', <String, dynamic>{'senderId': senderId, 'sdp': sdp});
  }

  @override
  Future<void> sendIce(WbCastIceCandidate? candidate, {String? senderId}) async {
    // candidate 必须显式传 null（服务端据此结束远端候选队列）。
    _emitRaw('cast:ice', <String, dynamic>{
      if (senderId != null) 'senderId': senderId,
      'candidate': candidate,
    });
  }

  // —— 内部 ——

  Future<Map<String, dynamic>> _emitAck(
    String event,
    Map<String, dynamic> payload,
  ) async {
    final sio.Socket? socket = _socket;
    if (socket == null || !socket.connected) {
      throw const WbCastFailure('NotConnected', '投屏服务未连接');
    }
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    socket.emitWithAck(event, payload, ack: (Object? data) {
      if (completer.isCompleted) return;
      completer.complete(_asMap(data) ?? const <String, dynamic>{});
    });
    final Map<String, dynamic> ack = await completer.future.timeout(
      ackTimeout,
      onTimeout: () => throw const WbCastFailure('Timeout', '投屏服务响应超时，请检查网络'),
    );
    if (ack['ok'] != true) {
      final Map<String, dynamic> error =
          _asMap(ack['error']) ?? const <String, dynamic>{};
      throw WbCastFailure(
        _string(error['code'], fallback: 'Error'),
        _string(error['message'], fallback: '投屏请求失败'),
      );
    }
    return ack;
  }

  void _emitRaw(String event, Map<String, dynamic> payload) {
    final sio.Socket? socket = _socket;
    if (socket == null || !socket.connected) {
      throw const WbCastFailure('NotConnected', '投屏服务未连接');
    }
    socket.emit(event, payload);
  }

  Future<void> _awaitConnected() {
    final sio.Socket? socket = _socket;
    if (socket == null) {
      return Future<void>.error(const WbCastFailure('NotConnected', '投屏服务未初始化'));
    }
    if (socket.connected) return Future<void>.value();
    final Completer<void> completer = Completer<void>();
    late final void Function(Object?) onError;
    void onConnect([Object? _]) {
      socket.off('connect', onConnect);
      socket.off('connect_error', onError);
      if (!completer.isCompleted) completer.complete();
    }

    onError = (Object? error) {
      socket.off('connect', onConnect);
      socket.off('connect_error', onError);
      if (!completer.isCompleted) {
        completer.completeError(WbCastFailure('NotConnected', '投屏服务连接失败：$error'));
      }
    };
    socket.on('connect', onConnect);
    socket.on('connect_error', onError);
    return completer.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        socket.off('connect', onConnect);
        socket.off('connect_error', onError);
        throw const WbCastFailure('Timeout', '连接投屏服务超时');
      },
    );
  }

  void _emit(WbCastSignalEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  static String _normalizeEndpoint(String endpoint) {
    String value = endpoint.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.endsWith('/cast')) {
      value = value.substring(0, value.length - '/cast'.length);
    }
    return value;
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((Object? key, Object? value) =>
          MapEntry<String, dynamic>('$key', value));
    }
    return null;
  }

  static String _string(Object? value, {String fallback = ''}) =>
      value is String && value.isNotEmpty ? value : fallback;

  static int _int(Object? value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }
}
