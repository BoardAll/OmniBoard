/// 投屏控制器单测：用 fake 信令 + fake 对端验证状态机，
/// 不依赖 flutter_webrtc / socket_io_client 插件（可在 CI 无设备环境运行）。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_cast/cast.dart';

/// 可编程的信令 fake：记录所有上行调用，测试通过 [emit] 注入服务端事件。
class FakeSignaling implements WbCastSignaling {
  final StreamController<WbCastSignalEvent> _events =
      StreamController<WbCastSignalEvent>.broadcast();

  bool _connected = false;
  int connectCalls = 0;
  int disconnectCalls = 0;
  int closeRoomCalls = 0;
  int heartbeatCalls = 0;
  int resumeCalls = 0;

  WbCastCreateResult Function()? onCreateRoom;
  WbCastCreateResult Function()? onRegenerate;
  WbCastJoinResult Function(String code)? onJoin;
  WbCastRoomSnapshot Function(int? maxSenders, bool? autoAccept)? onUpdate;
  WbCastResumeResult Function()? onResume;
  WbCastFailure? updateFailure;

  final List<String> offers = <String>[];
  final List<String> answers = <String>[];
  final List<String> answerTargets = <String>[];
  final List<String> iceTargets = <String>[];
  final List<WbCastIceCandidate?> iceCandidates = <WbCastIceCandidate?>[];
  final List<String> decided = <String>[];
  final List<String> leftSenders = <String>[];
  final List<String> leftReasons = <String>[];
  final List<String> joinedCodes = <String>[];
  final List<String> connectEndpoints = <String>[];
  final List<String?> connectTokens = <String?>[];
  int createCalls = 0;

  @override
  Stream<WbCastSignalEvent> get events => _events.stream;

  @override
  bool get connected => _connected;

  void emit(WbCastSignalEvent event) => _events.add(event);

  @override
  Future<void> connect({required String endpoint, String? token}) async {
    connectCalls += 1;
    connectEndpoints.add(endpoint);
    connectTokens.add(token);
    _connected = true;
    // 真实实现连接成功后立即推 TransportConnected（用于标记 everConnected）。
    scheduleMicrotask(() => emit(const WbCastTransportConnected()));
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls += 1;
    _connected = false;
  }

  @override
  Future<WbCastCreateResult> createRoom({
    String? deviceName,
    int? maxSenders,
    bool? autoAccept,
    int? ttlMs,
  }) async {
    createCalls += 1;
    final WbCastCreateResult Function()? handler = onCreateRoom;
    if (handler == null) throw const WbCastFailure('Unavailable', '未配置建房结果');
    return handler();
  }

  @override
  Future<WbCastResumeResult> resume({
    required String code,
    String? receiverToken,
    String? senderToken,
  }) async {
    resumeCalls += 1;
    final WbCastResumeResult Function()? handler = onResume;
    if (handler == null) throw const WbCastFailure('NotFound', '房间不存在');
    return handler();
  }

  @override
  Future<WbCastRoomSnapshot> updateSettings({
    int? maxSenders,
    bool? autoAccept,
    int? extendTtlMs,
  }) async {
    final WbCastFailure? failure = updateFailure;
    if (failure != null) throw failure;
    final WbCastRoomSnapshot Function(int?, bool?)? handler = onUpdate;
    if (handler == null) throw const WbCastFailure('Forbidden', '未开启投屏接收');
    return handler(maxSenders, autoAccept);
  }

  @override
  Future<WbCastCreateResult> regenerate() async {
    final WbCastCreateResult Function()? handler = onRegenerate;
    if (handler == null) throw const WbCastFailure('Forbidden', '未开启投屏接收');
    return handler();
  }

  @override
  Future<void> closeRoom() async {
    closeRoomCalls += 1;
  }

  @override
  Future<void> heartbeat() async {
    heartbeatCalls += 1;
  }

  @override
  Future<WbCastJoinResult> join({
    required String code,
    required String deviceName,
  }) async {
    joinedCodes.add(code);
    final WbCastJoinResult Function(String)? handler = onJoin;
    if (handler == null) throw const WbCastFailure('NotFound', '房间不存在');
    return handler(code);
  }

  @override
  Future<void> decide(String senderId, bool accept, {String? reason}) async {
    decided.add('$senderId:$accept');
  }

  @override
  Future<void> leave({String? senderId, String? reason}) async {
    leftSenders.add(senderId ?? '');
    leftReasons.add(reason ?? '');
  }

  @override
  Future<void> sendOffer(String sdp, {String? senderId}) async {
    offers.add(sdp);
  }

  @override
  Future<void> sendAnswer(String sdp, {required String senderId}) async {
    answers.add(sdp);
    answerTargets.add(senderId);
  }

  @override
  Future<void> sendIce(WbCastIceCandidate? candidate, {String? senderId}) async {
    iceCandidates.add(candidate);
    iceTargets.add(senderId ?? '');
  }

  Future<void> close() => _events.close();
}

/// 可注入失败与事件的对端 fake。
class FakePeer implements WbCastPeer {
  final String name;

  FakePeer(this.name);

  bool receiverStarted = false;
  bool senderStarted = false;
  bool disposed = false;
  int disposeCalls = 0;
  WbCastMediaSource? source;
  bool failStartSender = false;
  String? offer;
  String? answer;
  String? appliedOffer;
  String? appliedAnswer;
  final List<WbCastIceCandidate?> addedIce = <WbCastIceCandidate?>[];

  void Function(WbCastIceCandidate?)? _onIce;
  void Function(WbCastVideoFeed)? _onFeed;
  void Function(WbCastPeerState)? _onState;

  void emitLocalIce(WbCastIceCandidate? candidate) => _onIce?.call(candidate);

  void emitFeed(WbCastVideoFeed feed) => _onFeed?.call(feed);

  void emitState(WbCastPeerState state) => _onState?.call(state);

  @override
  void onLocalIceCandidate(void Function(WbCastIceCandidate? candidate) handler) {
    _onIce = handler;
  }

  @override
  void onVideoFeed(void Function(WbCastVideoFeed feed) handler) {
    _onFeed = handler;
  }

  @override
  void onState(void Function(WbCastPeerState state) handler) {
    _onState = handler;
  }

  @override
  Future<void> startReceiver() async {
    receiverStarted = true;
  }

  @override
  Future<void> startSender(WbCastMediaSource source) async {
    if (failStartSender) throw const WbCastFailure('PermissionDenied', '采集权限被拒绝');
    senderStarted = true;
    this.source = source;
  }

  @override
  Future<String> createOffer() async {
    if (!senderStarted) throw const WbCastFailure('SdpEmpty', '未采集媒体');
    return offer ?? 'offer-$name';
  }

  @override
  Future<String> acceptOffer(String sdp) async {
    appliedOffer = sdp;
    return answer ?? 'answer-$name';
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    appliedAnswer = sdp;
  }

  @override
  Future<void> addIceCandidate(WbCastIceCandidate? candidate) async {
    addedIce.add(candidate);
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    disposeCalls += 1;
  }
}

WbCastRoomSnapshot roomOf(
  String code, {
  int maxSenders = 4,
  bool autoAccept = true,
  List<WbCastSenderSnapshot> senders = const <WbCastSenderSnapshot>[],
}) {
  return WbCastRoomSnapshot(
    code: code,
    maxSenders: maxSenders,
    autoAccept: autoAccept,
    expiresAt: null,
    senders: senders,
  );
}

WbCastSenderSnapshot senderOf(String senderId, {bool accepted = true}) {
  return WbCastSenderSnapshot(
    senderId: senderId,
    userId: 'user-$senderId',
    deviceName: '设备-$senderId',
    state: accepted ? 'accepted' : 'pending',
    reconnecting: false,
  );
}

WbCastVideoFeed feedOf(String tag, {void Function()? onDispose}) {
  return WbCastVideoFeed(
    renderer: null,
    dispose: () async => onDispose?.call(),
  );
}

Future<void> waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
  String? reason,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(reason ?? 'waitFor 超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('WbCastCodes（四位码按字符串保留前导零）', () {
    test('normalize 接受 0000–9999 且拒绝非四位', () {
      expect(WbCastCodes.normalize('0000'), '0000');
      expect(WbCastCodes.normalize(' 0042 '), '0042');
      expect(WbCastCodes.normalize('1234'), '1234');
      expect(WbCastCodes.normalize('0999'), '0999');
      expect(WbCastCodes.normalize('999'), isNull);
      expect(WbCastCodes.normalize('10000'), isNull);
      expect(WbCastCodes.normalize('12a4'), isNull);
      expect(WbCastCodes.normalize(null), isNull);
    });

    test('sanitizeInput 只保留数字并截断到 4 位', () {
      expect(WbCastCodes.sanitizeInput('00 42'), '0042');
      expect(WbCastCodes.sanitizeInput('ab12c34'), '1234');
      expect(WbCastCodes.sanitizeInput('123456'), '1234');
    });

    test('display 保持原始字符串形态', () {
      expect(WbCastCodes.display('0007'), '0007');
      expect(WbCastCodes.display(null), '----');
      expect(WbCastCodes.display(''), '----');
    });
  });

  group('接收端会话', () {
    late FakeSignaling signaling;
    late List<FakePeer> peers;
    late WbCastController controller;

    setUp(() {
      signaling = FakeSignaling();
      peers = <FakePeer>[];
      controller = WbCastController(
        signaling: signaling,
        peerFactory: () {
          final FakePeer peer = FakePeer('p${peers.length + 1}');
          peers.add(peer);
          return peer;
        },
        config: const WbCastConfig(heartbeatInterval: Duration(hours: 1)),
      );
    });

    tearDown(() async {
      controller.dispose();
      await signaling.close();
    });

    test('建房成功后展示服务端分配的四位码（保留前导零）', () async {
      signaling.onCreateRoom = () => WbCastCreateResult(
            room: roomOf('0007'),
            receiverToken: 'token-1',
          );

      final bool ok = await controller.startReceiver(maxSenders: 3);

      expect(ok, isTrue);
      expect(controller.code, '0007');
      expect(controller.codeDisplay, '0007');
      expect(controller.hasActiveRoom, isTrue);
      expect(controller.status, WbCastSessionStatus.waiting);
      expect(controller.maxSenders, 4); // 以服务端快照为准
      expect(signaling.createCalls, 1);
      expect(signaling.connectEndpoints.single, WbCastConfig.defaultEndpoint);
    });

    test('房间快照驱动接收端状态：有已接受发送端时 active，清空后回到 waiting', () async {
      signaling.onCreateRoom = () => WbCastCreateResult(
            room: roomOf('1234'),
            receiverToken: 'token-1',
          );
      await controller.startReceiver();
      expect(controller.status, WbCastSessionStatus.waiting);

      // 自动接受时服务端不会单独推 cast:accepted，房间快照是唯一权威来源。
      signaling.emit(WbCastRoomUpdated(
        roomOf('1234', senders: <WbCastSenderSnapshot>[senderOf('s1')]),
      ));
      await waitFor(() => controller.status == WbCastSessionStatus.active);
      expect(controller.acceptedCount, 1);

      signaling.emit(WbCastRoomUpdated(roomOf('1234')));
      await waitFor(() => controller.status == WbCastSessionStatus.waiting);
      expect(controller.acceptedCount, 0);
    });

    test('建房失败时不展示投屏码并进入错误态', () async {
      signaling.onCreateRoom =
          () => throw const WbCastFailure('Unavailable', '投屏服务不可用');

      final bool ok = await controller.startReceiver();

      expect(ok, isFalse);
      expect(controller.code, isNull);
      expect(controller.codeDisplay, '----');
      expect(controller.hasActiveRoom, isFalse);
      expect(controller.status, WbCastSessionStatus.error);
      expect(controller.errorMessage, contains('投屏服务不可用'));
    });

    test('换码后展示新码，重新生成失败时保留旧码', () async {
      signaling.onCreateRoom = () => WbCastCreateResult(
            room: roomOf('1234'),
            receiverToken: 'token-1',
          );
      await controller.startReceiver();
      signaling.onRegenerate = () => WbCastCreateResult(
            room: roomOf('5678'),
            receiverToken: 'token-2',
          );

      expect(await controller.regenerateCode(), isTrue);
      expect(controller.code, '5678');

      signaling.onRegenerate = null;
      expect(await controller.regenerateCode(), isFalse);
      expect(controller.code, '5678');
      expect(controller.errorMessage, isNotNull);
    });

    test('两个发送端的 Offer 分别创建独立 Peer 并按 senderId 回复 Answer', () async {
      signaling.onCreateRoom = () => WbCastCreateResult(
            room: roomOf('1234', senders: <WbCastSenderSnapshot>[senderOf('s1')]),
            receiverToken: 'token-1',
          );
      await controller.startReceiver();

      signaling.emit(const WbCastOfferReceived(senderId: 's1', sdp: 'offer-s1'));
      signaling.emit(const WbCastOfferReceived(senderId: 's2', sdp: 'offer-s2'));
      await waitFor(() => signaling.answers.length == 2, reason: '两个 Answer 未发齐');

      expect(peers.length, 2);
      expect(signaling.answerTargets.toSet(), <String>{'s1', 's2'});
      expect(peers[0].appliedOffer, 'offer-s1');
      expect(peers[1].appliedOffer, 'offer-s2');
      expect(peers[0].receiverStarted, isTrue);
      expect(peers[1].receiverStarted, isTrue);
    });

    test('先到的 ICE 在 Peer 创建后按序投递，不串到其他路', () async {
      signaling.onCreateRoom = () => WbCastCreateResult(
            room: roomOf('1234'),
            receiverToken: 'token-1',
          );
      await controller.startReceiver();

      signaling.emit(const WbCastIceReceived(
        senderId: 's9',
        candidate: <String, dynamic>{'candidate': 'cand-1'},
      ));
      signaling.emit(const WbCastOfferReceived(senderId: 's9', sdp: 'offer-s9'));
      await waitFor(() => signaling.answers.length == 1, reason: 'Answer 未发出');
      await waitFor(() => peers.single.addedIce.isNotEmpty, reason: '缓冲 ICE 未投递');

      expect(peers.single.addedIce.single?['candidate'], 'cand-1');
      expect(signaling.iceTargets, isEmpty);
    });

    test('远端视频就绪后按 senderId 绑定独立浮层数据', () async {
      signaling.onCreateRoom = () => WbCastCreateResult(
            room: roomOf('1234'),
            receiverToken: 'token-1',
          );
      await controller.startReceiver();
      signaling.emit(const WbCastOfferReceived(senderId: 's1', sdp: 'o1'));
      signaling.emit(const WbCastOfferReceived(senderId: 's2', sdp: 'o2'));
      await waitFor(() => peers.length == 2);

      final WbCastVideoFeed feed1 = feedOf('f1');
      final WbCastVideoFeed feed2 = feedOf('f2');
      peers[0].emitFeed(feed1);
      peers[1].emitFeed(feed2);

      expect(controller.feeds['s1'], same(feed1));
      expect(controller.feeds['s2'], same(feed2));
      expect(controller.linkStateOf('s1'), WbCastLinkState.connected);
    });

    test('单路断开只清理该路的 Peer / 渲染器，其他路不受影响', () async {
      signaling.onCreateRoom = () => WbCastCreateResult(
            room: roomOf('1234', senders: <WbCastSenderSnapshot>[
              senderOf('s1'),
              senderOf('s2'),
            ]),
            receiverToken: 'token-1',
          );
      await controller.startReceiver();
      signaling.emit(const WbCastOfferReceived(senderId: 's1', sdp: 'o1'));
      signaling.emit(const WbCastOfferReceived(senderId: 's2', sdp: 'o2'));
      await waitFor(() => peers.length == 2);

      int feed1Disposed = 0;
      final WbCastVideoFeed feed1 = feedOf('f1', onDispose: () => feed1Disposed += 1);
      final WbCastVideoFeed feed2 = feedOf('f2');
      peers[0].emitFeed(feed1);
      peers[1].emitFeed(feed2);

      signaling.emit(const WbCastPeerLeft(senderId: 's1', reason: 'left'));
      await waitFor(() => !controller.feeds.containsKey('s1'), reason: 's1 未清理');

      expect(feed1Disposed, 1);
      expect(peers[0].disposeCalls, 1);
      expect(peers[1].disposeCalls, 0);
      expect(controller.feeds['s2'], same(feed2));
      expect(controller.linkStateOf('s2'), WbCastLinkState.connected);
    });

    test('接收端断开某一路按 senderId 调用 leave(kicked)', () async {
      signaling.onCreateRoom = () => WbCastCreateResult(
            room: roomOf('1234', senders: <WbCastSenderSnapshot>[senderOf('s2')]),
            receiverToken: 'token-1',
          );
      await controller.startReceiver();

      await controller.disconnectSender('s2');

      expect(signaling.leftSenders.single, 's2');
      expect(signaling.leftReasons.single, 'kicked');
    });

    test('下调最大路数被服务端拒绝时给出明确提示且不改本地快照', () async {
      signaling.onCreateRoom = () => WbCastCreateResult(
            room: roomOf('1234', maxSenders: 4, senders: <WbCastSenderSnapshot>[
              senderOf('s1'),
              senderOf('s2'),
            ]),
            receiverToken: 'token-1',
          );
      await controller.startReceiver(maxSenders: 4);
      signaling.updateFailure =
          const WbCastFailure('ConnectionsExceedLimit', '现有连接数超过新上限');

      final String? error = await controller.updateMaxSenders(1);

      expect(error, contains('当前已有 2 路连接'));
      expect(controller.maxSenders, 4);
      expect(controller.errorMessage, error);
    });

    test('手动确认 / 拒绝请求分别调用 decide 并更新单路状态', () async {
      signaling.onCreateRoom = () => WbCastCreateResult(
            room: roomOf('1234', autoAccept: false),
            receiverToken: 'token-1',
          );
      await controller.startReceiver(autoAccept: false);

      signaling.emit(const WbCastRequestReceived(
        senderId: 's5',
        deviceName: '手机',
        userId: 'u5',
      ));
      await waitFor(
        () => controller.linkStateOf('s5') == WbCastLinkState.pending,
        reason: '请求事件未投递',
      );

      await controller.approve('s5');
      await controller.reject('s6');

      expect(signaling.decided, <String>['s5:true', 's6:false']);
      expect(controller.linkStateOf('s5'), WbCastLinkState.connecting);
    });

    test('房间关闭（过期）后清空投屏码并释放全部 Peer 与渲染器', () async {
      signaling.onCreateRoom = () => WbCastCreateResult(
            room: roomOf('1234', senders: <WbCastSenderSnapshot>[
              senderOf('s1'),
              senderOf('s2'),
            ]),
            receiverToken: 'token-1',
          );
      await controller.startReceiver();
      signaling.emit(const WbCastOfferReceived(senderId: 's1', sdp: 'o1'));
      signaling.emit(const WbCastOfferReceived(senderId: 's2', sdp: 'o2'));
      await waitFor(() => peers.length == 2);

      int disposedFeeds = 0;
      peers[0].emitFeed(feedOf('f1', onDispose: () => disposedFeeds += 1));
      peers[1].emitFeed(feedOf('f2', onDispose: () => disposedFeeds += 1));

      signaling.emit(const WbCastRoomClosed(code: '1234', reason: 'expired'));
      await waitFor(() => controller.code == null, reason: '房间未清理');

      expect(controller.status, WbCastSessionStatus.error);
      expect(controller.errorMessage, contains('已过期'));
      expect(controller.feeds, isEmpty);
      expect(peers.every((FakePeer peer) => peer.disposeCalls == 1), isTrue);
      expect(disposedFeeds, 2);
    });

    test('endSession 幂等：重复调用只关房 / 断连一次', () async {
      signaling.onCreateRoom = () => WbCastCreateResult(
            room: roomOf('1234'),
            receiverToken: 'token-1',
          );
      await controller.startReceiver();

      await Future.wait<void>(<Future<void>>[
        controller.endSession(),
        controller.endSession(),
      ]);
      await controller.endSession();

      expect(signaling.closeRoomCalls, 1);
      expect(signaling.disconnectCalls, 1);
      expect(controller.status, WbCastSessionStatus.idle);
      expect(controller.code, isNull);
    });

    test('信令断开后提示，重连成功自动 resume 恢复房间', () async {
      signaling.onCreateRoom = () => WbCastCreateResult(
            room: roomOf('1234'),
            receiverToken: 'token-1',
          );
      await controller.startReceiver();
      await waitFor(() => controller.signalingOnline, reason: '首次连接事件未处理');

      signaling.emit(const WbCastTransportDisconnected('transport close'));
      await waitFor(
        () => controller.errorMessage != null,
        reason: '断开事件未处理',
      );
      expect(controller.errorMessage, contains('信令已断开'));

      signaling.onResume = () => WbCastResumeResult(
            role: WbCastRole.receiver,
            room: roomOf('1234', senders: <WbCastSenderSnapshot>[senderOf('s1')]),
          );
      signaling.emit(const WbCastTransportConnected());
      await waitFor(() => signaling.resumeCalls == 1, reason: '未触发 resume');

      expect(controller.errorMessage, isNull);
      expect(controller.code, '1234');
      expect(controller.status, WbCastSessionStatus.active);
    });
  });

  group('发送端会话', () {
    late FakeSignaling signaling;
    late List<FakePeer> peers;
    late WbCastController controller;

    setUp(() {
      signaling = FakeSignaling();
      peers = <FakePeer>[];
      controller = WbCastController(
        signaling: signaling,
        peerFactory: () {
          final FakePeer peer = FakePeer('s${peers.length + 1}');
          peers.add(peer);
          return peer;
        },
        config: const WbCastConfig(heartbeatInterval: Duration(hours: 1)),
      );
    });

    tearDown(() async {
      controller.dispose();
      await signaling.close();
    });

    test('join 校验四位码：非法输入不发请求', () async {
      final bool ok = await controller.join(code: '12');

      expect(ok, isFalse);
      expect(controller.errorMessage, contains('四位数字'));
      expect(signaling.connectCalls, 0);
      expect(signaling.joinedCodes, isEmpty);
    });

    test('RoomFull / NotFound 映射为可直接展示的中文提示', () async {
      signaling.onJoin =
          (String code) => throw const WbCastFailure('RoomFull', '房间已满');
      expect(await controller.join(code: '1234'), isFalse);
      expect(controller.errorMessage, '接收端已达到最大投屏路数');

      signaling.onJoin =
          (String code) => throw const WbCastFailure('NotFound', '房间不存在');
      expect(await controller.join(code: '9999'), isFalse);
      expect(controller.errorMessage, '投屏码不存在或已失效');
    });

    test('自动接受后采集媒体并发送 Offer', () async {
      signaling.onJoin = (String code) => WbCastJoinResult(
            code: code,
            senderId: 'send-1',
            senderToken: 'st-1',
            accepted: true,
            maxSenders: 4,
          );

      final bool ok = await controller.join(
        code: '0042',
        mediaSource: WbCastMediaSource.camera,
      );
      await waitFor(() => signaling.offers.isNotEmpty, reason: 'Offer 未发送');

      expect(ok, isTrue);
      expect(signaling.joinedCodes.single, '0042');
      expect(peers.single.senderStarted, isTrue);
      expect(peers.single.source, WbCastMediaSource.camera);
      expect(signaling.offers.single, 'offer-s1');
      expect(controller.status, WbCastSessionStatus.active);
    });

    test('待确认时不启动 Peer，收到 Accepted 后采样并发送 Offer', () async {
      signaling.onJoin = (String code) => WbCastJoinResult(
            code: code,
            senderId: 'send-7',
            senderToken: 'st-7',
            accepted: false,
            maxSenders: 4,
          );

      expect(await controller.join(code: '1234'), isTrue);
      expect(controller.status, WbCastSessionStatus.pendingApproval);
      expect(peers, isEmpty);

      signaling.emit(const WbCastAccepted(senderId: 'send-7', code: '1234'));
      await waitFor(() => signaling.offers.isNotEmpty, reason: 'Accepted 后未发送 Offer');

      expect(peers.single.senderStarted, isTrue);
      expect(controller.status, WbCastSessionStatus.active);
    });

    test('媒体采集失败时释放 Peer 并提示', () async {
      signaling.onJoin = (String code) => WbCastJoinResult(
            code: code,
            senderId: 'send-2',
            senderToken: 'st-2',
            accepted: true,
            maxSenders: 4,
          );
      final FakePeer failing = FakePeer('fail')..failStartSender = true;
      peers.add(failing);
      final WbCastController failingController = WbCastController(
        signaling: signaling,
        peerFactory: () => failing,
        config: const WbCastConfig(heartbeatInterval: Duration(hours: 1)),
      );
      addTearDown(failingController.dispose);

      expect(await failingController.join(code: '1234'), isTrue);
      await waitFor(
        () => failingController.status == WbCastSessionStatus.error,
        reason: '采集失败未进入错误态',
      );

      expect(failingController.errorMessage, contains('权限被拒绝'));
      expect(failing.disposeCalls, 1);
      expect(signaling.offers, isEmpty);
    });

    test('被接收端拒绝后进入错误态并释放 Peer', () async {
      signaling.onJoin = (String code) => WbCastJoinResult(
            code: code,
            senderId: 'send-3',
            senderToken: 'st-3',
            accepted: true,
            maxSenders: 4,
          );
      await controller.join(code: '1234');
      await waitFor(() => peers.isNotEmpty);

      signaling.emit(const WbCastRejected(senderId: 'send-3', reason: 'manual'));
      await waitFor(
        () => controller.status == WbCastSessionStatus.error,
        reason: '拒绝后未进入错误态',
      );

      expect(controller.errorMessage, contains('拒绝'));
      expect(peers.single.disposeCalls, 1);
    });

    test('收到 Answer / ICE 时只作用于本发送端', () async {
      signaling.onJoin = (String code) => WbCastJoinResult(
            code: code,
            senderId: 'send-4',
            senderToken: 'st-4',
            accepted: true,
            maxSenders: 4,
          );
      await controller.join(code: '1234');
      await waitFor(() => peers.isNotEmpty);

      signaling.emit(const WbCastAnswerReceived(senderId: 'other', sdp: 'a-other'));
      signaling.emit(const WbCastAnswerReceived(senderId: 'send-4', sdp: 'a-mine'));
      await waitFor(
        () => peers.single.appliedAnswer == 'a-mine',
        reason: '未应用本端 Answer',
      );

      signaling.emit(const WbCastIceReceived(
        senderId: 'send-4',
        candidate: <String, dynamic>{'candidate': 'c-4'},
      ));
      await waitFor(() => peers.single.addedIce.isNotEmpty, reason: 'ICE 未投递');

      expect(peers.single.appliedAnswer, 'a-mine');
      expect(peers.single.addedIce.single?['candidate'], 'c-4');
    });

    test('leaveAsSender 释放 Peer、离开房间并回到 idle', () async {
      signaling.onJoin = (String code) => WbCastJoinResult(
            code: code,
            senderId: 'send-5',
            senderToken: 'st-5',
            accepted: true,
            maxSenders: 4,
          );
      await controller.join(code: '1234');
      await waitFor(() => peers.isNotEmpty);

      await controller.leaveAsSender();

      expect(signaling.leftSenders.single, 'send-5');
      expect(peers.single.disposeCalls, 1);
      expect(controller.status, WbCastSessionStatus.idle);
      expect(controller.code, isNull);
      expect(controller.role, isNull);
    });
  });
}
