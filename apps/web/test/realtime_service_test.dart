/// W1 实时协作服务 VM 桩测试（T1.8）：连接状态机 / 事件处理 / 参与者增量。
///
/// 全程注入假脚本加载器与 [FakeSocketIoBridge]，VM（纯 Dart）不加载 JS；
/// 真实浏览器连通性由 `realtime_web_smoke_test.dart`（browser-only）覆盖。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_web/services/realtime_service.dart';
import 'package:whiteboard_web/services/socketio_js.dart';

import 'support/fake_socketio_bridge.dart';

/// 测试用服务地址。
const String _endpoint = 'http://127.0.0.1:8790';

void main() {
  group('连接生命周期', () {
    test('connect：归一化 endpoint、连接 /board、auth 载荷、回调注册', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect('  $_endpoint///  ', token: 'jwt-1');

      expect(h.loadedEndpoints.single, _endpoint);
      expect(h.service.endpoint, _endpoint);
      expect(h.service.status, WbRealtimeStatus.connecting);

      final ({String url, WbSocketIoConnectOptions options}) call =
          h.bridge.connectCalls.single;
      expect(call.url, '$_endpoint/board');
      expect(call.options.reconnection, isTrue);
      expect(call.options.auth['token'], 'jwt-1');
      expect(call.options.auth['clientVersion'], '1.0.0');

      // 生命周期 + 事件处理器均已注册（事件在 connect 之后注册）。
      h.bridge.fireConnected(socketId: 'sock-1', transport: 'websocket');
      expect(h.service.status, WbRealtimeStatus.connected);
      expect(h.service.isConnected, isTrue);
      expect(h.bridge.handlerCount('board:session'), 1);
      expect(h.bridge.handlerCount('board:joined'), 1);
      expect(h.bridge.handlerCount('board:participants'), 1);
      expect(h.bridge.handlerCount('room:error'), 1);
    });

    test('connect：无 token 时 auth 不含 token 键', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);

      expect(h.bridge.connectCalls.single.options.auth.containsKey('token'), isFalse);
    });

    test('connect：空 / 空白 endpoint → disconnected + 错误，不加载脚本', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect('   ');

      expect(h.service.status, WbRealtimeStatus.disconnected);
      expect(h.service.lastError?.message, contains('realtime 服务地址'));
      expect(h.loadedEndpoints, isEmpty);
      expect(h.bridges, isEmpty);
    });

    test('connect：进行中重复调用复用同一尝试；已连接后不再发起', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      final Completer<void> gate = Completer<void>();
      h.loadOverride = (String endpoint) => gate.future;

      final Future<void> first = h.service.connect(_endpoint);
      final Future<void> second = h.service.connect(_endpoint);
      expect(h.loadedEndpoints.length, 1);

      gate.complete();
      await first;
      await second;
      expect(h.bridges.length, 1);

      h.bridge.fireConnected();
      expect(h.service.status, WbRealtimeStatus.connected);
      await h.service.connect(_endpoint);
      expect(h.loadedEndpoints.length, 1);
      expect(h.bridges.length, 1);
    });

    test('connect：脚本加载失败 → disconnected + lastError；可重试成功', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      h.loadOverride = (String endpoint) async {
        throw WbSocketIoLoadException(endpoint: endpoint, message: '脚本加载失败（测试）');
      };

      await h.service.connect(_endpoint);
      expect(h.service.status, WbRealtimeStatus.disconnected);
      expect(h.service.lastError?.message, '脚本加载失败（测试）');
      expect(h.bridges, isEmpty);

      h.loadOverride = null;
      await h.service.connect(_endpoint);
      expect(h.service.status, WbRealtimeStatus.connecting);
      h.bridge.fireConnected();
      expect(h.service.status, WbRealtimeStatus.connected);
      expect(h.service.lastError, isNull);
      expect(h.loadedEndpoints.length, 2);
      expect(h.bridges.length, 1);
    });

    test('首连失败（connect_error）→ disconnected + lastError', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnectError(
        const WbSocketIoConnectError(message: 'Unauthorized: invalid token', code: 'Unauthorized'),
      );

      expect(h.service.status, WbRealtimeStatus.disconnected);
      expect(h.service.lastError?.code, 'Unauthorized');
      expect(h.service.lastError?.message, contains('Unauthorized'));
    });

    test('意外断线 → reconnecting；重连失败保持；重连成功恢复', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      expect(h.service.status, WbRealtimeStatus.connected);

      h.bridge.fireDisconnected('transport close');
      expect(h.service.status, WbRealtimeStatus.reconnecting);

      // 重连尝试失败：保持「重连中」（socket.io 继续退避重试）。
      h.bridge.fireConnectError(const WbSocketIoConnectError(message: 'retry failed'));
      expect(h.service.status, WbRealtimeStatus.reconnecting);

      h.bridge.fireConnected(socketId: 'sock-2');
      expect(h.service.status, WbRealtimeStatus.connected);
      expect(h.service.lastError, isNull);
    });

    test('io server / io client disconnect → disconnected（不自动重连语义）', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireDisconnected('io server disconnect');
      expect(h.service.status, WbRealtimeStatus.disconnected);

      h.bridge.fireConnected(socketId: 'sock-3');
      h.bridge.fireDisconnected('io client disconnect');
      expect(h.service.status, WbRealtimeStatus.disconnected);
    });
  });

  group('board:join', () {
    test('joinBoard：未连接时挂起，连接成功后自动补发（含 pageId）', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      await h.service.joinBoard('board-1', pageId: 'page-7');

      expect(h.service.boardId, 'board-1');
      expect(h.bridge.ackCalls, isEmpty);

      h.bridge.fireConnected();
      await _flush();

      final FakeAckCall joinCall = h.bridge.ackCalls.single;
      expect(joinCall.event, 'board:join');
      expect(joinCall.payload, <String, Object?>{'boardId': 'board-1', 'pageId': 'page-7'});
    });

    test('断线重连成功后自动补发 board:join', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      await h.service.joinBoard('board-1');
      h.bridge.fireConnected();
      await _flush();
      expect(_joinCount(h.bridge), 1);

      h.bridge.fireDisconnected('transport close');
      h.bridge.fireConnected(socketId: 'sock-2');
      await _flush();
      expect(_joinCount(h.bridge), 2);
      expect(h.service.status, WbRealtimeStatus.connected);
    });

    test('joinBoard：ack 失败 → lastError（code / message），状态不受影响', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.ackHandler = (String event, Object? payload) => Future<Object?>.value(
            <String, Object?>{
              'ok': false,
              'error': <String, Object?>{'code': 'Forbidden', 'message': '无权限加入'},
            },
          );

      await h.service.joinBoard('board-2');

      expect(h.service.lastError?.code, 'Forbidden');
      expect(h.service.lastError?.message, '无权限加入');
      expect(h.service.boardId, 'board-2');
      expect(h.service.status, WbRealtimeStatus.connected);
    });

    test('joinBoard：空 id 忽略', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      await h.service.joinBoard('');

      expect(h.service.boardId, isNull);
      expect(h.bridge.ackCalls, isEmpty);
    });
  });

  group('事件处理', () {
    test('board:session：userId / authMode / role 解析；畸形载荷忽略', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      int notifications = 0;
      h.service.addListener(() => notifications += 1);

      h.bridge.fireEvent('board:session', <String, Object?>{
        'userId': 'anon-abcd1234',
        'authMode': 'anonymous',
        'role': 'Participant',
      });

      expect(h.service.userId, 'anon-abcd1234');
      expect(h.service.authMode, 'anonymous');
      expect(h.service.role, 'Participant');
      expect(notifications, greaterThan(0));

      // 畸形：空 userId / 非 Map 载荷 → 不覆盖既有值。
      h.bridge.fireEvent('board:session', <String, Object?>{'userId': ''});
      h.bridge.fireEvent('board:session', 'junk');
      expect(h.service.userId, 'anon-abcd1234');
    });

    test('board:joined：全量替换快照并更新 boardId / role / mode', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('board:joined', <String, Object?>{
        'boardId': 'board-1',
        'role': 'Host',
        'mode': 'free',
        'locks': <Object?>[],
        'stateVector': <String, Object?>{},
        'participants': <Object?>[
          _participant('me-01', 'sock-1', 'Host'),
          _participant('peer-02', 'sock-2', 'Participant'),
        ],
      });

      expect(h.service.boardId, 'board-1');
      expect(h.service.role, 'Host');
      expect(h.service.mode, 'free');
      expect(
        h.service.participants.map((WbCollabParticipant p) => p.userId).toList(),
        <String>['me-01', 'peer-02'],
      );
      expect(() => h.service.participants.clear(), throwsUnsupportedError);

      // 再次快照：全量替换（旧成员不在新集合中即移除）。
      h.bridge.fireEvent('board:joined', <String, Object?>{
        'boardId': 'board-1',
        'participants': <Object?>[_participant('third-03', 'sock-3', 'Viewer')],
      });
      expect(h.service.participants.length, 1);
      expect(h.service.participants.single.userId, 'third-03');
    });

    test('board:participants：joined / updated 按 socketId 合并（替换保序）', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('board:joined', <String, Object?>{
        'participants': <Object?>[
          _participant('me-01', 'sock-1', 'Participant'),
          _participant('peer-02', 'sock-2', 'Viewer'),
        ],
      });

      h.bridge.fireEvent('board:participants', <String, Object?>{
        'joined': <Object?>[
          _participant('peer-02', 'sock-2', 'Participant'),
          _participant('new-03', 'sock-3', 'Viewer'),
        ],
        'updated': <Object?>[_participant('me-01', 'sock-1', 'Presenter')],
      });

      final List<WbCollabParticipant> list = h.service.participants;
      expect(
        list.map((WbCollabParticipant p) => p.userId).toList(),
        <String>['me-01', 'peer-02', 'new-03'],
      );
      expect(list[0].role, 'Presenter');
      expect(list[1].role, 'Participant');
    });

    test('board:participants：left 移除；未知 socketId 无变化', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('board:joined', <String, Object?>{
        'participants': <Object?>[
          _participant('me-01', 'sock-1', 'Participant'),
          _participant('peer-02', 'sock-2', 'Viewer'),
        ],
      });

      h.bridge.fireEvent('board:participants', <String, Object?>{
        'left': <Object?>[_participant('peer-02', 'sock-2', 'Viewer')],
      });
      expect(
        h.service.participants.map((WbCollabParticipant p) => p.userId).toList(),
        <String>['me-01'],
      );

      // 未知 socketId：无变化（不产生幽灵条目 / 不崩溃）。
      h.bridge.fireEvent('board:participants', <String, Object?>{
        'left': <Object?>[_participant('ghost-09', 'sock-9', 'Participant')],
      });
      expect(h.service.participants.length, 1);
    });

    test('畸形载荷容错：非 Map / 非法条目 / 非字符串键 → 忽略不崩溃', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();

      h.bridge.fireEvent('board:participants', 'junk');
      h.bridge.fireEvent('board:participants', <String, Object?>{'joined': 'not-a-list'});
      h.bridge.fireEvent('board:joined', <String, Object?>{'participants': 'nope'});
      h.bridge.fireEvent('board:joined', <Object?, Object?>{42: 'x'});
      expect(h.service.participants, isEmpty);

      h.bridge.fireEvent('board:joined', <String, Object?>{
        'participants': <Object?>[
          'junk',
          42,
          <String, Object?>{'userId': 'no-socket'},
          <String, Object?>{'socketId': 'no-user'},
          _participant('ok-01', 'sock-1', 'Participant'),
        ],
      });
      expect(h.service.participants.length, 1);
      expect(h.service.participants.single.userId, 'ok-01');
    });

    test('room:error：记录 lastError，连接状态不变', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();

      h.bridge.fireEvent('room:error', <String, Object?>{
        'code': 'NotInRoom',
        'message': '会话不在房间内',
        'reason': 'left',
      });
      expect(h.service.lastError?.code, 'NotInRoom');
      expect(h.service.lastError?.message, '会话不在房间内');
      expect(h.service.status, WbRealtimeStatus.connected);

      h.bridge.fireEvent('room:error', 'junk');
      expect(h.service.lastError?.code, 'NotInRoom');
    });
  });

  group('leave / dispose', () {
    test('leave：清空房间态、发 board:leave 后断开；旧桥事件隔离；幂等', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      await h.service.joinBoard('board-1');
      h.bridge.fireEvent('board:joined', <String, Object?>{
        'participants': <Object?>[
          _participant('me-01', 'sock-1', 'Host'),
          _participant('peer-02', 'sock-2', 'Participant'),
        ],
      });

      final FakeSocketIoBridge old = h.bridge;
      await h.service.leave();

      expect(h.service.status, WbRealtimeStatus.disconnected);
      expect(h.service.boardId, isNull);
      expect(h.service.role, isNull);
      expect(h.service.mode, isNull);
      expect(h.service.participants, isEmpty);
      expect(old.ackCalls.last.event, 'board:leave');
      expect(old.disconnectCalls, 1);

      // 旧桥事件隔离：leave 之后不再影响本实例。
      old.fireEvent('board:participants', <String, Object?>{
        'joined': <Object?>[_participant('late-09', 'sock-9', 'Participant')],
      });
      old.fireConnected();
      old.fireDisconnected('transport close');
      expect(h.service.participants, isEmpty);
      expect(h.service.status, WbRealtimeStatus.disconnected);

      // 幂等：再次 leave 不重复触发桥操作。
      await h.service.leave();
      expect(old.disconnectCalls, 1);
    });

    test('leave：ack 挂起 → 状态立即收敛，ack 后断开', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      final Completer<Object?> gate = Completer<Object?>();
      h.bridge.ackHandler = (String event, Object? payload) => gate.future;

      final Future<void> leaving = h.service.leave();
      await _flush();
      expect(h.service.status, WbRealtimeStatus.disconnected);
      expect(h.bridge.disconnectCalls, 0);

      gate.complete(const <String, Object?>{'ok': true});
      await leaving;
      expect(h.bridge.disconnectCalls, 1);
    });

    test('leave：ack 超时 → 兜底断开（不阻塞页面退出）', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      // 永不完成的 ack：验证 800ms 超时兜底后仍完成本地断开。
      final Completer<Object?> gate = Completer<Object?>();
      h.bridge.ackHandler = (String event, Object? payload) => gate.future;

      final Stopwatch watch = Stopwatch()..start();
      await h.service.leave();
      watch.stop();

      expect(h.bridge.disconnectCalls, 1);
      expect(h.service.status, WbRealtimeStatus.disconnected);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('dispose：释放桥；dispose 后事件与 leave 安全', () async {
      final _Harness h = _Harness();
      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      final FakeSocketIoBridge bridge = h.bridge;

      h.service.dispose();
      expect(bridge.offCalls, isNotEmpty);
      expect(bridge.disconnectCalls, 1);

      // dispose 后：旧桥事件 / leave 均安全（状态冻结，无异常）。
      bridge.fireEvent('board:session', <String, Object?>{'userId': 'late-01'});
      bridge.fireConnected();
      bridge.fireConnectError(const WbSocketIoConnectError(message: 'late'));
      await h.service.leave();

      expect(h.service.userId, isNull);
      expect(h.service.status, WbRealtimeStatus.disconnected);
      expect(bridge.disconnectCalls, 1);
    });
  });

  group('数据模型', () {
    test('WbCollabParticipant.tryParse：字段容错 / 相等性 / 错误 toString', () {
      expect(WbCollabParticipant.tryParse(null), isNull);
      expect(WbCollabParticipant.tryParse('junk'), isNull);
      expect(WbCollabParticipant.tryParse(<Object?, Object?>{42: 'x'}), isNull);
      expect(WbCollabParticipant.tryParse(<String, Object?>{'socketId': 's1'}), isNull);
      expect(WbCollabParticipant.tryParse(<String, Object?>{'userId': 'u1'}), isNull);

      final WbCollabParticipant minimal = WbCollabParticipant.tryParse(
        <String, Object?>{'userId': 'u1', 'socketId': 's1'},
      )!;
      expect(minimal.role, '');
      expect(minimal.joinedAtMs, 0);

      final WbCollabParticipant full = WbCollabParticipant.tryParse(
        <String, Object?>{
          'userId': 'u1',
          'socketId': 's1',
          'role': 'Host',
          'joinedAt': 1727000000000,
        },
      )!;
      expect(full.joinedAtMs, 1727000000000);
      expect(
        full,
        const WbCollabParticipant(userId: 'u1', socketId: 's1', role: 'Host', joinedAtMs: 1727000000000),
      );
      expect(
        full.hashCode,
        const WbCollabParticipant(userId: 'u1', socketId: 's1', role: 'Host', joinedAtMs: 1727000000000)
            .hashCode,
      );
      expect(full.toString(), contains('u1@s1'));

      expect(const WbRealtimeError(message: 'm').toString(), 'WbRealtimeError(m)');
      expect(const WbRealtimeError(message: 'm', code: 'C').toString(), 'WbRealtimeError(C: m)');
    });
  });
}

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

/// 测试夹具：注入假加载器 / 假桥并记录调用。
class _Harness {
  final List<String> loadedEndpoints = <String>[];
  final List<FakeSocketIoBridge> bridges = <FakeSocketIoBridge>[];

  /// 覆盖脚本加载行为（缺省：记录后成功）。
  Future<void> Function(String endpoint)? loadOverride;

  late final WbRealtimeService service = WbRealtimeService(
    clientLoader: _load,
    bridgeFactory: _createBridge,
  );

  FakeSocketIoBridge get bridge => bridges.last;

  Future<void> _load(String endpoint) {
    loadedEndpoints.add(endpoint);
    final Future<void> Function(String endpoint)? override = loadOverride;
    if (override != null) {
      return override(endpoint);
    }
    return Future<void>.value();
  }

  WbSocketIoBridge _createBridge() {
    final FakeSocketIoBridge created = FakeSocketIoBridge();
    bridges.add(created);
    return created;
  }
}

/// 构造参与者载荷（服务端 `ParticipantInfo`：userId/socketId/role/joinedAt）。
Map<String, Object?> _participant(String userId, String socketId, String role, {int joinedAt = 1000}) =>
    <String, Object?>{
      'userId': userId,
      'socketId': socketId,
      'role': role,
      'joinedAt': joinedAt,
    };

/// 冲刷微任务。
Future<void> _flush() => Future<void>.delayed(Duration.zero);

/// 某桥 `board:join` 的调用次数。
int _joinCount(FakeSocketIoBridge bridge) =>
    bridge.ackCalls.where((FakeAckCall call) => call.event == 'board:join').length;
