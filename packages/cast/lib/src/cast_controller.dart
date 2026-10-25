/// 投屏控制器（接收端 / 发送端共用一个状态机）。
///
/// 职责边界：
/// - 只负责投屏会话：房间、连接、媒体对端、浮层数据；**不触碰白板文档模型**；
/// - 不把投屏状态写入白板内容 / 撤销栈 / 导出；
/// - 一个发送端 = 一个 PeerConnection = 一个视频浮层（单路异常互不影响）；
/// - 退出白板必须调用 [endSession]（幂等），释放 Peer / 渲染器 / 定时器 / Socket。
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'cast_models.dart';
import 'cast_peer.dart';
import 'cast_signaling.dart';

/// 投屏配置。
class WbCastConfig {
  /// 创建配置。
  const WbCastConfig({
    this.endpoint = defaultEndpoint,
    this.token,
    this.deviceName = '',
    this.maxSenders = 4,
    this.autoAccept = true,
    this.mediaSource = WbCastMediaSource.screen,
    this.showCode = true,
    this.iceServers = const <Map<String, dynamic>>[],
    this.heartbeatInterval = const Duration(seconds: 45),
  });

  /// realtime 服务默认地址（与白板协同同端口）。
  static const String defaultEndpoint = 'http://127.0.0.1:8790';

  /// 服务地址（不含 `/cast`）。
  final String endpoint;

  /// JWT（可空；非生产环境服务端允许匿名回落）。
  final String? token;

  /// 设备名称（显示在接收端连接列表）。
  final String deviceName;

  /// 默认最大并发路数。
  final int maxSenders;

  /// 默认是否自动接受。
  final bool autoAccept;

  /// 默认媒体源。
  final WbCastMediaSource mediaSource;

  /// 默认是否显示投屏码。
  final bool showCode;

  /// ICE 服务器（局域网直连留空）。
  final List<Map<String, dynamic>> iceServers;

  /// 心跳间隔（服务端默认有效期 30 分钟）。
  final Duration heartbeatInterval;

  /// 复制并覆盖字段。
  WbCastConfig copyWith({
    String? endpoint,
    String? token,
    String? deviceName,
    int? maxSenders,
    bool? autoAccept,
    WbCastMediaSource? mediaSource,
    bool? showCode,
  }) {
    return WbCastConfig(
      endpoint: endpoint ?? this.endpoint,
      token: token ?? this.token,
      deviceName: deviceName ?? this.deviceName,
      maxSenders: maxSenders ?? this.maxSenders,
      autoAccept: autoAccept ?? this.autoAccept,
      mediaSource: mediaSource ?? this.mediaSource,
      showCode: showCode ?? this.showCode,
      iceServers: iceServers,
      heartbeatInterval: heartbeatInterval,
    );
  }
}

/// 投屏控制器。
class WbCastController extends ChangeNotifier {
  /// 创建控制器（可注入信令 / 对端工厂做单测）。
  WbCastController({
    WbCastSignaling? signaling,
    WbCastPeerFactory? peerFactory,
    WbCastConfig config = const WbCastConfig(),
  })  : _signaling = signaling ?? WbCastSocketSignaling(),
        _peerFactory = peerFactory ??
            (() => WbFlutterWebrtcPeer(iceServers: config.iceServers)),
        _config = config,
        _showCode = config.showCode,
        _mediaSource = config.mediaSource {
    _subscription = _signaling.events.listen(_onSignal, onError: (Object error) {
      _setError('投屏信令异常：$error');
    });
  }

  final WbCastSignaling _signaling;
  final WbCastPeerFactory _peerFactory;
  WbCastConfig _config;
  StreamSubscription<WbCastSignalEvent>? _subscription;

  WbCastSessionStatus _status = WbCastSessionStatus.idle;
  WbCastRole? _role;
  WbCastRoomSnapshot? _room;
  String? _code;
  String? _receiverToken;
  String? _senderId;
  String? _senderToken;
  String? _error;
  bool _showCode;
  bool _transportOnline = false;
  bool _everConnected = false;
  bool _ending = false;
  bool _disposed = false;
  WbCastMediaSource _mediaSource;
  Timer? _heartbeat;

  final Map<String, WbCastPeer> _peers = <String, WbCastPeer>{};
  final Map<String, WbCastVideoFeed> _feeds = <String, WbCastVideoFeed>{};
  final Map<String, WbCastLinkState> _links = <String, WbCastLinkState>{};
  final Map<String, List<WbCastIceCandidate?>> _pendingIce =
      <String, List<WbCastIceCandidate?>>{};
  final Map<String, Future<void>> _serial = <String, Future<void>>{};

  /// 当前会话状态。
  WbCastSessionStatus get status => _status;

  /// 当前角色（未开启为 null）。
  WbCastRole? get role => _role;

  /// 房间快照（未建房 / 未加入为 null）。
  WbCastRoomSnapshot? get room => _room;

  /// 发送端标识（服务端分配；仅当本端为发送端时有值）。
  String? get senderId => _senderId;

  /// 四位投屏码（**服务端确认建房成功后**才有值）。
  String? get code => _code;

  /// 投屏码展示（未就绪显示 `----`）。
  String get codeDisplay => WbCastCodes.display(_code);

  /// 是否显示投屏码（隐藏不结束会话）。
  bool get showCode => _showCode;

  /// 已使用路数。
  int get acceptedCount => _room?.acceptedCount ?? 0;

  /// 最大路数。
  int get maxSenders => _room?.maxSenders ?? _config.maxSenders;

  /// 是否自动接受。
  bool get autoAccept => _room?.autoAccept ?? _config.autoAccept;

  /// 信令是否在线。
  bool get signalingOnline => _transportOnline;

  /// 错误文案（成功后清空）。
  String? get errorMessage => _error;

  /// 当前媒体源（发送端）。
  WbCastMediaSource get mediaSource => _mediaSource;

  /// 服务地址。
  String get endpoint => _config.endpoint;

  /// 房间内的发送端（服务端快照）。
  List<WbCastSenderSnapshot> get senders =>
      _room?.senders ?? const <WbCastSenderSnapshot>[];

  /// 视频浮层数据（senderId → 渲染句柄）。
  Map<String, WbCastVideoFeed> get feeds =>
      UnmodifiableMapView<String, WbCastVideoFeed>(_feeds);

  /// 单路连接状态（WebRTC 层；用于浮层角标）。
  WbCastLinkState linkStateOf(String senderId) =>
      _links[senderId] ?? WbCastLinkState.connecting;

  /// 是否处于可展示投屏码的会话中。
  bool get hasActiveRoom => _code != null && _role == WbCastRole.receiver;

  /// 更新服务地址与令牌（在 Settings 中配置后调用）。
  void configure({String? endpoint, String? token}) {
    _config = _config.copyWith(
      endpoint: endpoint?.trim().isEmpty ?? true ? null : endpoint!.trim(),
      token: token,
    );
  }

  /// 设置发送端媒体源（下次 join / 重连生效）。
  void setMediaSource(WbCastMediaSource source) {
    if (_mediaSource == source) return;
    _mediaSource = source;
    _notify();
  }

  /// 显示 / 隐藏投屏码（不结束会话）。
  void setShowCode(bool value) {
    if (_showCode == value) return;
    _showCode = value;
    _notify();
  }

  // —— 接收端 ——

  /// 开启投屏接收（建房成功后才有有效投屏码）。
  Future<bool> startReceiver({
    String? endpoint,
    String? token,
    String? deviceName,
    int? maxSenders,
    bool? autoAccept,
  }) async {
    if (_role == WbCastRole.receiver &&
        (_status == WbCastSessionStatus.waiting ||
            _status == WbCastSessionStatus.active)) {
      return true;
    }
    configure(endpoint: endpoint, token: token);
    if (deviceName != null && deviceName.trim().isNotEmpty) {
      _config = _config.copyWith(deviceName: deviceName.trim());
    }
    _role = WbCastRole.receiver;
    _status = WbCastSessionStatus.connecting;
    _error = null;
    _notify();
    try {
      await _signaling.connect(endpoint: _config.endpoint, token: _config.token);
      final WbCastCreateResult created = await _signaling.createRoom(
        deviceName: _config.deviceName,
        maxSenders: maxSenders ?? _config.maxSenders,
        autoAccept: autoAccept ?? _config.autoAccept,
      );
      _code = created.room.code;
      _receiverToken = created.receiverToken;
      _room = created.room;
      _status = created.room.senders.isEmpty
          ? WbCastSessionStatus.waiting
          : WbCastSessionStatus.active;
      _startHeartbeat();
      _notify();
      return true;
    } on WbCastFailure catch (failure) {
      _fail(failure.message);
      return false;
    } catch (error) {
      _fail('开启投屏接收失败：$error');
      return false;
    }
  }

  /// 重新生成投屏码（旧码立即失效，已连接的路保留）。
  Future<bool> regenerateCode() async {
    if (_role != WbCastRole.receiver || _code == null) return false;
    try {
      final WbCastCreateResult rotated = await _signaling.regenerate();
      _code = rotated.room.code;
      _receiverToken = rotated.receiverToken;
      _room = rotated.room;
      _error = null;
      _notify();
      return true;
    } on WbCastFailure catch (failure) {
      _setError(failure.message);
      return false;
    }
  }

  /// 更新最大并发路数；服务端拒绝（低于现有连接数）时返回错误文案。
  Future<String?> updateMaxSenders(int value) async {
    if (_role != WbCastRole.receiver || _code == null) return '未开启投屏接收';
    if (value < 1 || value > 4) return '最多同时接收 1–4 路投屏';
    try {
      _room = await _signaling.updateSettings(maxSenders: value);
      _error = null;
      _notify();
      return null;
    } on WbCastFailure catch (failure) {
      final String message = failure.code == 'ConnectionsExceedLimit'
          ? '当前已有 $acceptedCount 路连接，请先断开部分连接再下调到 $value 路'
          : failure.message;
      _setError(message);
      return message;
    }
  }

  /// 更新自动接受开关。
  Future<String?> updateAutoAccept(bool value) async {
    if (_role != WbCastRole.receiver || _code == null) return '未开启投屏接收';
    try {
      _room = await _signaling.updateSettings(autoAccept: value);
      _error = null;
      _notify();
      return null;
    } on WbCastFailure catch (failure) {
      _setError(failure.message);
      return failure.message;
    }
  }

  /// 接受某一路投屏请求。
  Future<void> approve(String senderId) => _decide(senderId, true);

  /// 拒绝某一路投屏请求。
  Future<void> reject(String senderId) => _decide(senderId, false);

  /// 断开某一路投屏（不影响其他路）。
  Future<void> disconnectSender(String senderId) async {
    try {
      await _signaling.leave(senderId: senderId, reason: 'kicked');
    } on WbCastFailure catch (failure) {
      _setError(failure.message);
    }
  }

  Future<void> _decide(String senderId, bool accept) async {
    try {
      await _signaling.decide(senderId, accept);
      if (accept) {
        _links[senderId] = WbCastLinkState.connecting;
      }
      _notify();
    } on WbCastFailure catch (failure) {
      _setError(failure.message);
    }
  }

  // —— 发送端 ——

  /// 输入四位投屏码并申请投屏。
  Future<bool> join({
    required String code,
    String? endpoint,
    String? token,
    String? deviceName,
    WbCastMediaSource? mediaSource,
  }) async {
    final String? normalized = WbCastCodes.normalize(code);
    if (normalized == null) {
      _setError('投屏码必须是四位数字');
      return false;
    }
    if (mediaSource != null) _mediaSource = mediaSource;
    configure(endpoint: endpoint, token: token);
    if (deviceName != null && deviceName.trim().isNotEmpty) {
      _config = _config.copyWith(deviceName: deviceName.trim());
    }
    _role = WbCastRole.sender;
    _code = normalized;
    _status = WbCastSessionStatus.connecting;
    _error = null;
    _notify();
    try {
      await _signaling.connect(endpoint: _config.endpoint, token: _config.token);
      final WbCastJoinResult joined = await _signaling.join(
        code: normalized,
        deviceName: _config.deviceName,
      );
      _senderId = joined.senderId;
      _senderToken = joined.senderToken;
      if (joined.accepted) {
        await _startSenderPeer();
      } else {
        _status = WbCastSessionStatus.pendingApproval;
      }
      _notify();
      return true;
    } on WbCastFailure catch (failure) {
      final String message = switch (failure.code) {
        'NotFound' => '投屏码不存在或已失效',
        'RoomFull' => '接收端已达到最大投屏路数',
        'ReceiverOffline' => '接收端暂时离线，请稍后重试',
        'TooManyAttempts' => '尝试次数过多，请稍后再试',
        'InvalidCode' => '投屏码必须是四位数字',
        _ => failure.message,
      };
      _fail(message);
      return false;
    } catch (error) {
      _fail('发起投屏失败：$error');
      return false;
    }
  }

  Future<void> _startSenderPeer() async {
    final String? senderId = _senderId;
    if (senderId == null) return;
    await _disposePeer(senderId);
    final WbCastPeer peer = _peerFactory();
    _peers[senderId] = peer;
    _links[senderId] = WbCastLinkState.connecting;
    peer.onLocalIceCandidate((WbCastIceCandidate? candidate) {
      _signaling
          .sendIce(candidate, senderId: senderId)
          .catchError((Object _) {});
    });
    peer.onState((WbCastPeerState state) => _applyPeerState(senderId, state));
    try {
      await peer.startSender(_mediaSource);
      final String offer = await peer.createOffer();
      if (offer.isEmpty) throw const WbCastFailure('SdpEmpty', 'SDP 生成失败');
      await _signaling.sendOffer(offer);
      _status = WbCastSessionStatus.active;
      _error = null;
    } on WbCastFailure catch (failure) {
      _fail(failure.message);
      await _disposePeer(senderId);
    } catch (error) {
      _fail('媒体采集失败：$error');
      await _disposePeer(senderId);
    }
  }

  /// 主动结束发送（关闭 Peer 并离开房间，不影响接收端其他路）。
  Future<void> leaveAsSender() async {
    if (_role != WbCastRole.sender) return;
    try {
      await _signaling.leave(senderId: _senderId);
    } catch (_) {
      // 网络已断时忽略；服务端宽限期会回收席位。
    }
    await _resetLocalSession();
    await _signaling.disconnect();
    _status = WbCastSessionStatus.idle;
    _notify();
  }

  // —— 通用 ——

  /// 结束当前会话（关闭房间 / 离开 + 释放资源），幂等。
  Future<void> endSession() async {
    if (_ending) return;
    if (_role == null && _code == null && _status == WbCastSessionStatus.idle) {
      // 已结束：重复清理直接 no-op（不得重复断开/关闭）。
      return;
    }
    _ending = true;
    try {
      _heartbeat?.cancel();
      _heartbeat = null;
      if (_role == WbCastRole.receiver && _code != null) {
        try {
          await _signaling.closeRoom();
        } catch (_) {
          // 已断开 / 已过期：服务端会自行清理。
        }
      } else if (_role == WbCastRole.sender && _code != null) {
        try {
          await _signaling.leave(senderId: _senderId);
        } catch (_) {
          // 同上。
        }
      }
      await _signaling.disconnect();
      await _resetLocalSession();
      _status = WbCastSessionStatus.idle;
      _notify();
    } finally {
      _ending = false;
    }
  }

  /// 重试连接 / 恢复（错误页按钮）。
  Future<void> retry() async {
    if (_role == WbCastRole.sender && _code != null) {
      final String? senderToken = _senderToken;
      if (senderToken != null) {
        await _resume();
        return;
      }
    }
    if (_role == WbCastRole.receiver && _code != null) {
      final String? receiverToken = _receiverToken;
      if (receiverToken != null) {
        await _resume();
        return;
      }
    }
    _status = WbCastSessionStatus.idle;
    _error = null;
    _notify();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(endSession());
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  // —— 事件处理 ——

  void _onSignal(WbCastSignalEvent event) {
    if (_disposed) return;
    switch (event) {
      case WbCastTransportConnected():
        final bool wasOffline = !_transportOnline && _everConnected;
        _transportOnline = true;
        _everConnected = true;
        if (wasOffline && _code != null) {
          unawaited(_resume());
        } else {
          _notify();
        }
      case WbCastTransportDisconnected(:final String reason):
        _transportOnline = false;
        if (_status != WbCastSessionStatus.idle) {
          _error = '投屏信令已断开（$reason），正在重连…';
        }
        _notify();
      case WbCastTransportError(:final String message):
        _transportOnline = false;
        _setError(message);
      case WbCastRoomUpdated(:final WbCastRoomSnapshot room):
        _room = room;
        if (_role == WbCastRole.receiver && _code != null && room.code != _code) {
          // 换码：接收端凭同一会话继续（token 不变）。
          _code = room.code;
        }
        // 接收端：房间快照是唯一权威来源（自动接受时不会有 cast:accepted），
        // 据此在「等待接入」与「已连接」之间切换。
        if (_role == WbCastRole.receiver &&
            (_status == WbCastSessionStatus.waiting ||
                _status == WbCastSessionStatus.active)) {
          _status = room.acceptedCount > 0
              ? WbCastSessionStatus.active
              : WbCastSessionStatus.waiting;
        }
        _syncLinksWithRoom(room);
        _notify();
      case WbCastRequestReceived(:final String senderId):
        _links[senderId] = WbCastLinkState.pending;
        _notify();
      case WbCastAccepted(:final String senderId):
        if (_role != WbCastRole.sender || senderId != _senderId) return;
        _status = WbCastSessionStatus.active;
        unawaited(_startSenderPeer());
      case WbCastRejected(:final String senderId):
        if (_role != WbCastRole.sender) return;
        if (_senderId != null && senderId.isNotEmpty && senderId != _senderId) {
          return;
        }
        _fail('接收端拒绝了本次投屏');
      case WbCastOfferReceived(:final String senderId, :final String sdp):
        if (_role != WbCastRole.receiver) return;
        _runSerial(
          senderId,
          () => _handleOffer(senderId, sdp),
        );
      case WbCastAnswerReceived(:final String senderId, :final String sdp):
        if (_role != WbCastRole.sender) return;
        if (_senderId != null && senderId.isNotEmpty && senderId != _senderId) {
          return;
        }
        _runSerial(senderId, () => _handleAnswer(senderId, sdp));
      case WbCastIceReceived(:final String senderId, :final candidate):
        if (_role == WbCastRole.sender) {
          if (_senderId != null && senderId.isNotEmpty && senderId != _senderId) {
            return;
          }
        }
        _handleIce(senderId, candidate);
      case WbCastPeerLeft(:final String senderId, :final String reason):
        unawaited(_removeSender(senderId));
        if (_role == WbCastRole.sender) {
          _fail(reason == 'kicked' ? '接收端已断开本次投屏' : '投屏连接已结束');
        }
      case WbCastRoomClosed(:final String reason):
        unawaited(_handleRoomClosed(reason));
      case WbCastErrorEvent(:final String code, :final String message):
        if (code == 'NotFound' && _status == WbCastSessionStatus.idle) return;
        _setError(message);
    }
  }

  Future<void> _handleOffer(String senderId, String sdp) async {
    final bool created = _peers[senderId] == null;
    final WbCastPeer peer = _peers[senderId] ??= _createReceiverPeer(senderId);
    try {
      final String answer = await peer.acceptOffer(sdp);
      await _signaling.sendAnswer(answer, senderId: senderId);
      if (created) await _flushPendingIce(senderId);
    } catch (error) {
      _links[senderId] = WbCastLinkState.failed;
      _setError('接收投屏画面失败：$error');
    }
  }

  WbCastPeer _createReceiverPeer(String senderId) {
    final WbCastPeer peer = _peerFactory();
    _peers[senderId] = peer;
    _links[senderId] = WbCastLinkState.connecting;
    peer.onLocalIceCandidate((WbCastIceCandidate? candidate) {
      _signaling
          .sendIce(candidate, senderId: senderId)
          .catchError((Object _) {});
    });
    peer.onVideoFeed((WbCastVideoFeed feed) {
      final WbCastVideoFeed? previous = _feeds[senderId];
      _feeds[senderId] = feed;
      _links[senderId] = WbCastLinkState.connected;
      if (previous != null && previous.renderer != feed.renderer) {
        unawaited(previous.dispose());
      }
      _notify();
    });
    peer.onState((WbCastPeerState state) => _applyPeerState(senderId, state));
    unawaited(peer.startReceiver());
    return peer;
  }

  Future<void> _handleAnswer(String senderId, String sdp) async {
    final WbCastPeer? peer = _peers[senderId];
    if (peer == null) return;
    try {
      await peer.acceptAnswer(sdp);
      _links[senderId] = WbCastLinkState.connecting;
      await _flushPendingIce(senderId);
    } catch (error) {
      _links[senderId] = WbCastLinkState.failed;
      _setError('投屏协商失败：$error');
    }
  }

  void _handleIce(String senderId, WbCastIceCandidate? candidate) {
    final WbCastPeer? peer = _peers[senderId];
    if (peer == null) {
      final List<WbCastIceCandidate?> pending =
          _pendingIce.putIfAbsent(senderId, () => <WbCastIceCandidate?>[]);
      if (pending.length < 32) pending.add(candidate);
      return;
    }
    peer.addIceCandidate(candidate).catchError((Object _) {});
  }

  Future<void> _flushPendingIce(String senderId) async {
    final List<WbCastIceCandidate?>? pending = _pendingIce.remove(senderId);
    final WbCastPeer? peer = _peers[senderId];
    if (pending == null || peer == null) return;
    for (final WbCastIceCandidate? candidate in pending) {
      try {
        await peer.addIceCandidate(candidate);
      } catch (_) {
        // 过期候选可忽略。
      }
    }
  }

  void _applyPeerState(String senderId, WbCastPeerState state) {
    switch (state) {
      case WbCastPeerState.connecting:
        _links[senderId] = WbCastLinkState.connecting;
      case WbCastPeerState.connected:
        _links[senderId] = WbCastLinkState.connected;
      case WbCastPeerState.disconnected:
        _links[senderId] = WbCastLinkState.connecting;
      case WbCastPeerState.failed:
        _links[senderId] = WbCastLinkState.failed;
      case WbCastPeerState.closed:
        _links[senderId] = WbCastLinkState.closed;
    }
    _notify();
  }

  Future<void> _removeSender(String senderId) async {
    _pendingIce.remove(senderId);
    final WbCastVideoFeed? feed = _feeds.remove(senderId);
    _links.remove(senderId);
    await _disposePeer(senderId);
    if (feed != null) await feed.dispose();
    _notify();
  }

  Future<void> _disposePeer(String senderId) async {
    final WbCastPeer? peer = _peers.remove(senderId);
    if (peer != null) {
      try {
        await peer.dispose();
      } catch (_) {
        // 幂等清理：重复关闭不抛。
      }
    }
  }

  Future<void> _handleRoomClosed(String reason) async {
    final String message = switch (reason) {
      'expired' => '投屏码已过期，请重新开启投屏',
      'receiver-left' => '接收端已离开，投屏结束',
      'closed' => '投屏已被接收端关闭',
      _ => '投屏房间已关闭',
    };
    await _disposeAllPeers();
    _code = null;
    _receiverToken = null;
    _senderId = null;
    _senderToken = null;
    _room = null;
    _links.clear();
    _heartbeat?.cancel();
    _heartbeat = null;
    _status = WbCastSessionStatus.error;
    _error = message;
    _notify();
  }

  Future<void> _resume() async {
    final String? code = _code;
    if (code == null) return;
    try {
      final WbCastResumeResult result = await _signaling.resume(
        code: code,
        receiverToken: _role == WbCastRole.receiver ? _receiverToken : null,
        senderToken: _role == WbCastRole.sender ? _senderToken : null,
      );
      _error = null;
      if (result.role == WbCastRole.receiver) {
        final WbCastRoomSnapshot? room = result.room;
        if (room != null) {
          _room = room;
          _code = room.code;
          _syncLinksWithRoom(room);
        }
        _status = (room?.acceptedCount ?? 0) > 0
            ? WbCastSessionStatus.active
            : WbCastSessionStatus.waiting;
        _startHeartbeat();
      } else {
        _senderId = result.senderId ?? _senderId;
        if (result.senderState == 'accepted' && _senderId != null) {
          _status = WbCastSessionStatus.active;
          await _startSenderPeer();
        } else {
          _status = WbCastSessionStatus.pendingApproval;
        }
      }
      _notify();
    } on WbCastFailure catch (failure) {
      _fail('投屏会话已失效：${failure.message}');
    } catch (error) {
      _setError('恢复投屏失败：$error');
    }
  }

  void _syncLinksWithRoom(WbCastRoomSnapshot room) {
    for (final WbCastSenderSnapshot sender in room.senders) {
      final WbCastLinkState? state = _links[sender.senderId];
      if (state == null || state == WbCastLinkState.closed) {
        _links[sender.senderId] = sender.accepted
            ? WbCastLinkState.connecting
            : WbCastLinkState.pending;
      }
    }
    final Set<String> known =
        room.senders.map((WbCastSenderSnapshot item) => item.senderId).toSet();
    for (final String senderId in _links.keys.toList(growable: false)) {
      if (!known.contains(senderId)) _links.remove(senderId);
    }
  }

  void _runSerial(String senderId, Future<void> Function() task) {
    final Future<void> previous =
        _serial[senderId] ?? Future<void>.value();
    final Future<void> next = previous.then((_) => task()).catchError(
      (Object error) {
        _setError('投屏信令处理失败：$error');
      },
    );
    _serial[senderId] = next;
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_config.heartbeatInterval, (_) {
      if (_role != WbCastRole.receiver || _code == null) return;
      _signaling.heartbeat().catchError((Object _) {});
    });
  }

  Future<void> _resetLocalSession() async {
    await _disposeAllPeers();
    _pendingIce.clear();
    _serial.clear();
    _links.clear();
    _heartbeat?.cancel();
    _heartbeat = null;
    _role = null;
    _room = null;
    _code = null;
    _receiverToken = null;
    _senderId = null;
    _senderToken = null;
    _error = null;
    _transportOnline = false;
    _everConnected = false;
  }

  Future<void> _disposeAllPeers() async {
    final List<String> ids = _peers.keys.toList(growable: false);
    for (final String senderId in ids) {
      await _disposePeer(senderId);
    }
    final List<WbCastVideoFeed> feeds =
        _feeds.values.toList(growable: false);
    _feeds.clear();
    for (final WbCastVideoFeed feed in feeds) {
      try {
        await feed.dispose();
      } catch (_) {
        // 幂等。
      }
    }
  }

  void _fail(String message) {
    _status = WbCastSessionStatus.error;
    _error = message;
    unawaited(_disposeAllPeers());
    _notify();
  }

  void _setError(String message) {
    _error = message;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}
