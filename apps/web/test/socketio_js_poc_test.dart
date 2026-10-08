/// T0.2 POC：官方 socket.io JS 客户端浏览器真实连通测试（对 :8790）。
///
/// 仅浏览器运行（VM 下自动跳过，不影响既有 `flutter test`）：
/// ```
/// flutter test --no-pub --platform chrome test/socketio_js_poc_test.dart
/// ```
/// 前置：services/realtime 已启动（`node dist/server.js`，默认 :8790）。
/// 可覆盖服务地址：--dart-define=WB_REALTIME_ENDPOINT=http://127.0.0.1:8790
/// gated 拒连轮次：--dart-define=WB_POC_BAD_TOKEN=<非法 token>（服务端需 WB_JWT_SECRET）。
///
/// 覆盖断言（任务 T0.2）：
/// - 脚本动态加载幂等（`{endpoint}/socket.io/socket.io.min.js`）；
/// - 连接成功 + board:session 单播 userId + 默认传输升级 websocket；
/// - board:join / board:ping ack；board:echo 自端排除 + 第二连接收广播；
/// - board:direct 单播；volatile 可用性（volatile 发送的服务端回执）；
/// - transports:['websocket'] 直连 / ['polling'] 降级对照（连接时序 + transport 名）。
@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_web/services/socketio_js.dart';

/// realtime 服务地址（测试轮次可用 --dart-define 覆盖）。
const String kEndpoint = String.fromEnvironment(
  'WB_REALTIME_ENDPOINT',
  defaultValue: 'http://127.0.0.1:8790',
);

/// gated 拒连轮次的非法 token；为空时相关用例自动跳过。
const String kBadToken = String.fromEnvironment('WB_POC_BAD_TOKEN');

void main() {
  group('脚本加载与连接基础', () {
    test('loadSocketIoClient 幂等：重复调用共享同一加载结果', () async {
      await loadSocketIoClient(kEndpoint);
      final stopwatch = Stopwatch()..start();
      await loadSocketIoClient(kEndpoint);
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(500));
      debugPrint('[POC] load socket.io client x2 ok; second_call=${stopwatch.elapsedMilliseconds}ms');
    });

    test('连接成功：socketId 非空 + board:session 单播 userId/authMode', () async {
      final client = await _connectSession();
      addTearDown(client.dispose);

      expect(client.socketId, isNotEmpty);
      expect(client.bridge.isConnected, isTrue);
      expect(client.bridge.state, WbSocketIoConnectionState.connected);
      expect(client.userId, isNotEmpty);
      expect(client.authMode, 'anonymous');
      debugPrint(
        '[POC] connected id=${client.socketId} userId=${client.userId} '
        'authMode=${client.authMode} transportAtConnect=${client.transportAtConnect} '
        'connect=${client.connectElapsed.inMilliseconds}ms',
      );
    });
  });

  group('事件往返', () {
    test('board:join / board:ping：ack 契约', () async {
      final client = await _connectSession();
      addTearDown(client.dispose);
      final boardId = _uniqueBoardId('join');

      final joined = await _ack(client.bridge, 'board:join', <String, Object?>{'boardId': boardId});
      expect(joined['ok'], isTrue);
      expect(joined['boardId'], boardId);
      expect(joined['role'], 'Participant');
      expect(joined['mode'], 'free');

      final pong = await _ack(
        client.bridge,
        'board:ping',
        <String, Object?>{'clientTime': DateTime.now().millisecondsSinceEpoch},
      );
      expect(pong['ok'], isTrue);
      expect(pong['serverTime'], isA<num>());
      debugPrint('[POC] join+ping ok; boardId=$boardId serverTime=${pong['serverTime']}');
    });

    test('board:echo：第二连接收到广播、自端被排除', () async {
      final first = await _connectSession();
      addTearDown(first.dispose);
      final second = await _connectSession();
      addTearDown(second.dispose);

      final boardId = _uniqueBoardId('echo');
      await _ack(first.bridge, 'board:join', <String, Object?>{'boardId': boardId});
      await _ack(second.bridge, 'board:join', <String, Object?>{'boardId': boardId});

      var selfBroadcasts = 0;
      first.bridge.on('board:broadcast', (Object? _) => selfBroadcasts += 1);
      final received = _nextEvent(second.bridge, 'board:broadcast');

      final ack = await _ack(first.bridge, 'board:echo', <String, Object?>{'payload': 'poc-hello'});
      expect(ack['ok'], isTrue);
      expect(ack['echo'], 'poc-hello');

      final broadcast = await _asMapAsync(received);
      expect(broadcast['from'], first.userId);
      expect(broadcast['payload'], 'poc-hello');

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(selfBroadcasts, 0);
      debugPrint('[POC] echo ok; secondReceived from=${broadcast['from']} selfBroadcasts=$selfBroadcasts');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('board:direct：单播到目标用户（board:directed）', () async {
      final sender = await _connectSession();
      addTearDown(sender.dispose);
      final target = await _connectSession();
      addTearDown(target.dispose);

      var senderDirected = 0;
      sender.bridge.on('board:directed', (Object? _) => senderDirected += 1);
      final received = _nextEvent(target.bridge, 'board:directed');

      final ack = await _ack(
        sender.bridge,
        'board:direct',
        <String, Object?>{'toUserId': target.userId, 'payload': 'poc-dm'},
      );
      expect(ack['ok'], isTrue);

      final directed = await _asMapAsync(received);
      expect(directed['from'], sender.userId);
      expect(directed['toUserId'], target.userId);
      expect(directed['payload'], 'poc-dm');

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(senderDirected, 0);
      debugPrint('[POC] direct ok; from=${directed['from']} to=${directed['toUserId']}');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('volatile 可用性', () {
    test('supportsVolatile + volatile 消息可达服务端（board:join 回执）', () async {
      final client = await _connectSession();
      addTearDown(client.dispose);
      expect(client.bridge.supportsVolatile, isTrue);

      final boardId = _uniqueBoardId('volatile');
      final joinedFuture = _nextEvent(client.bridge, 'board:joined');
      client.bridge.volatileEmit('board:join', <String, Object?>{'boardId': boardId});
      final joined = await _asMapAsync(joinedFuture);
      expect(joined['boardId'], boardId);
      expect(client.bridge.isConnected, isTrue);
      debugPrint('[POC] volatile ok; board:joined received for $boardId');
    });
  });

  group('传输与降级差异', () {
    test('transports:["websocket"]：直连 WS（无 polling 阶段）', () async {
      final client = await _connectSession(transports: const <String>['websocket']);
      addTearDown(client.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(client.transportAtConnect, 'websocket');
      expect(client.bridge.engineTransportName, 'websocket');
      debugPrint(
        '[POC] websocket-only: transportAtConnect=${client.transportAtConnect} '
        'connect=${client.connectElapsed.inMilliseconds}ms',
      );
    });

    test('transports:["polling"]：降级对照，transport 保持 polling 不升级', () async {
      final client = await _connectSession(transports: const <String>['polling']);
      addTearDown(client.dispose);
      expect(client.transportAtConnect, 'polling');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(client.bridge.engineTransportName, 'polling');
      debugPrint(
        '[POC] polling-only: transportAtConnect=${client.transportAtConnect} '
        'transportAfter800ms=${client.bridge.engineTransportName} '
        'connect=${client.connectElapsed.inMilliseconds}ms',
      );
    });

    test('默认配置：polling 起步 → 自动升级 websocket', () async {
      final client = await _connectSession();
      addTearDown(client.dispose);
      final upgradeWatch = Stopwatch()..start();
      await _waitUntil(
        () => client.bridge.engineTransportName == 'websocket',
        timeout: const Duration(seconds: 15),
        reason: '等待 transport 升级到 websocket',
      );
      upgradeWatch.stop();
      debugPrint(
        '[POC] default: transportAtConnect=${client.transportAtConnect} '
        'upgraded=websocket upgradeWait=${upgradeWatch.elapsedMilliseconds}ms '
        'connect=${client.connectElapsed.inMilliseconds}ms',
      );
    });
  });

  group('gated 拒连（可选轮次）', () {
    test(
      '非法 token：connect_error.code == Unauthorized',
      () async {
        final bridge = createWbSocketIoBridge();
        addTearDown(bridge.disconnect);
        final errorFuture = Completer<WbSocketIoConnectError>();
        bridge.onConnectError((WbSocketIoConnectError error) {
          if (!errorFuture.isCompleted) {
            errorFuture.complete(error);
          }
        });
        bridge.connect(
          '$kEndpoint/board',
          const WbSocketIoConnectOptions(
            auth: <String, Object?>{'token': kBadToken, 'boardId': 'poc-gated'},
            reconnection: false,
          ),
        );
        final error = await errorFuture.future.timeout(const Duration(seconds: 15));
        expect(error.code, 'Unauthorized');
        expect(error.message, contains('Unauthorized'));
        expect(bridge.state, WbSocketIoConnectionState.connectError);
        debugPrint('[POC] gated rejected: code=${error.code} message=${error.message}');
      },
      skip: kBadToken.isEmpty ? '需 --dart-define=WB_POC_BAD_TOKEN + 服务端 WB_JWT_SECRET 轮次' : false,
    );
  });
}

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

/// 连接 + 等待 board:session 后的会话句柄。
class _PocSession {
  _PocSession({
    required this.bridge,
    required this.socketId,
    required this.transportAtConnect,
    required this.connectElapsed,
    required this.userId,
    required this.authMode,
  });

  final WbSocketIoBridge bridge;
  final String socketId;
  final String? transportAtConnect;
  final Duration connectElapsed;
  final String userId;
  final String authMode;

  void dispose() => bridge.disconnect();
}

/// 新建桥、连接 `/board` 并等待 `board:session` 回执（含连接时序）。
Future<_PocSession> _connectSession({
  List<String>? transports,
  Map<String, Object?> auth = const <String, Object?>{},
}) async {
  final bridge = createWbSocketIoBridge();
  final connected = Completer<({String socketId, String? transport})>();
  bridge.onConnected((String socketId, String? transport) {
    if (!connected.isCompleted) {
      connected.complete((socketId: socketId, transport: transport));
    }
  });
  bridge.onConnectError((WbSocketIoConnectError error) {
    if (!connected.isCompleted) {
      connected.completeError(StateError('connect_error: $error'));
    }
  });
  final stopwatch = Stopwatch()..start();
  bridge.connect(
    '$kEndpoint/board',
    WbSocketIoConnectOptions(auth: auth, transports: transports, reconnection: false),
  );
  // connect() 同步创建 socket 并发起连接；同 tick 内注册不会错过 board:session
  // （网络事件仍在后续 tick 才到达）。
  final sessionFuture = _nextEvent(bridge, 'board:session');
  final info = await connected.future.timeout(const Duration(seconds: 15));
  stopwatch.stop();
  final session = await _asMapAsync(sessionFuture.timeout(const Duration(seconds: 15)));
  final userId = session['userId'];
  if (userId is! String || userId.isEmpty) {
    throw StateError('board:session userId 缺失: $session');
  }
  return _PocSession(
    bridge: bridge,
    socketId: info.socketId,
    transportAtConnect: info.transport,
    connectElapsed: stopwatch.elapsed,
    userId: userId,
    authMode: session['authMode'] is String ? session['authMode']! as String : '',
  );
}

/// 等待下一次 [event] 事件（一次性；超时抛 TimeoutException）。
Future<Object?> _nextEvent(WbSocketIoBridge bridge, String event) {
  final completer = Completer<Object?>();
  bridge.on(event, (Object? payload) {
    if (!completer.isCompleted) {
      completer.complete(payload);
    }
  });
  return completer.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => throw TimeoutException('等待事件 $event 超时（10s）'),
  );
}

/// 发送事件并等待 ack（10s 超时），ack 载荷转为 Map。
Future<Map<Object?, Object?>> _ack(WbSocketIoBridge bridge, String event, Object? payload) async {
  final raw = await bridge.emitWithAck(event, payload).timeout(const Duration(seconds: 10));
  return _asMap(raw);
}

/// 轮询等待条件成立（50ms 间隔）。
Future<void> _waitUntil(
  bool Function() predicate, {
  required Duration timeout,
  required String reason,
}) async {
  final stopwatch = Stopwatch()..start();
  while (!predicate()) {
    if (stopwatch.elapsed > timeout) {
      throw TimeoutException('$reason（超时 ${timeout.inSeconds}s）');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// dartify 载荷（Map<Object?, Object?>）转换与校验。
Map<Object?, Object?> _asMap(Object? value) {
  if (value is Map<Object?, Object?>) {
    return value;
  }
  if (value is Map) {
    return Map<Object?, Object?>.from(value);
  }
  fail('期望 Map 载荷，实际: $value');
}

/// await Future 后再转 Map（供 Completer 等待链使用）。
Future<Map<Object?, Object?>> _asMapAsync(Future<Object?> future) async {
  return _asMap(await future);
}

/// 每个用例使用独立房间，避免并发用例互相干扰。
String _uniqueBoardId(String tag) => 't02-$tag-${DateTime.now().millisecondsSinceEpoch}';
