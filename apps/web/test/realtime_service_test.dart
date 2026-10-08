/// 实时协作服务 VM 桩测试（T1.8 + M3 / T3.4）：
/// 连接状态机 / 事件处理 / 参与者增量 / interactive 发送与订阅 / 权限判定。
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
      expect(h.bridge.handlerCount('room:removed'), 1);
      expect(h.bridge.handlerCount('interactive:modeChanged'), 1);
      expect(h.bridge.handlerCount('interactive:roleChanged'), 1);
      expect(h.bridge.handlerCount('interactive:hostChanged'), 1);
      expect(h.bridge.handlerCount('interactive:follow'), 1);
      expect(h.bridge.handlerCount('interactive:unfollow'), 1);
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
      expect(joinCall.payload, <String, Object?>{
        'boardId': 'board-1',
        'pageId': 'page-7',
        // P4：join 携带本地水位（无提供者 / 新会话 = 空对象新成员语义）。
        'lastSeenVersion': <String, Object?>{},
      });
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

  group('interactive 发送（C→S）', () {
    test('raiseHand / lowerHand：ack 成功本地置位与复位；失败不更新', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      // 未连接：直接 false，不发送。
      expect(await h.service.raiseHand(), isFalse);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('board:session', <String, Object?>{
        'userId': 'me-01',
        'authMode': 'anonymous',
        'role': 'Participant',
      });
      h.bridge.fireEvent('board:joined', <String, Object?>{
        'participants': <Object?>[_participant('me-01', 'sock-1', 'Participant')],
      });

      expect(await h.service.raiseHand(), isTrue);
      final FakeAckCall raiseCall = h.bridge.ackCalls.last;
      expect(raiseCall.event, 'interactive:raiseHand');
      expect(raiseCall.payload, const <String, Object?>{});
      expect(h.service.selfHandRaised, isTrue);
      expect(h.service.participants.single.handRaised, isTrue);
      expect(h.service.raisedHands.single.userId, 'me-01');

      expect(await h.service.lowerHand(), isTrue);
      expect(h.bridge.ackCalls.last.event, 'interactive:lowerHand');
      expect(h.service.selfHandRaised, isFalse);
      expect(h.service.participants.single.handRaised, isFalse);
      expect(h.service.raisedHands, isEmpty);

      // 服务端拒绝（`{ok:false, reason}`）：返回 false，本地态不变。
      h.bridge.ackHandler = (String event, Object? payload) async =>
          <String, Object?>{'ok': false, 'reason': 'forbidden'};
      expect(await h.service.raiseHand(), isFalse);
      expect(h.service.selfHandRaised, isFalse);
      expect(h.service.participants.single.handRaised, isFalse);
    });

    test('grantControl / revokeControl：{userId} 载荷 + ack 成功本地乐观更新', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('board:session', <String, Object?>{
        'userId': 'me-01',
        'authMode': 'anonymous',
        'role': 'CoHost',
      });
      h.bridge.fireEvent('board:joined', <String, Object?>{
        'participants': <Object?>[
          _participant('me-01', 'sock-1', 'CoHost'),
          _participant('peer-02', 'sock-2', 'Participant'),
        ],
      });

      expect(await h.service.grantControl('peer-02'), isTrue);
      final FakeAckCall grantCall = h.bridge.ackCalls.last;
      expect(grantCall.event, 'interactive:grantControl');
      expect(grantCall.payload, <String, Object?>{'userId': 'peer-02'});
      expect(_participantOf(h.service, 'peer-02').grantedWrite, isTrue);

      expect(await h.service.revokeControl('peer-02'), isTrue);
      expect(h.bridge.ackCalls.last.event, 'interactive:revokeControl');
      expect(h.bridge.ackCalls.last.payload, <String, Object?>{'userId': 'peer-02'});
      expect(_participantOf(h.service, 'peer-02').grantedWrite, isFalse);

      // 空 userId：false 且不发送；ack 失败：false 且不更新。
      final int before = h.bridge.ackCalls.length;
      expect(await h.service.grantControl(''), isFalse);
      expect(h.bridge.ackCalls.length, before);

      h.bridge.ackHandler = (String event, Object? payload) async =>
          <String, Object?>{'ok': false, 'reason': 'forbidden'};
      expect(await h.service.grantControl('peer-02'), isFalse);
      expect(_participantOf(h.service, 'peer-02').grantedWrite, isFalse);
    });

    test('startPresent / stopPresent：ack 成功更新本地模式；失败不更新', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('board:session', <String, Object?>{
        'userId': 'me-01',
        'authMode': 'anonymous',
        'role': 'CoHost',
      });

      expect(h.service.isPresenting, isFalse);
      expect(await h.service.startPresent(), isTrue);
      expect(h.bridge.ackCalls.last.event, 'interactive:startPresent');
      expect(h.service.isPresenting, isTrue);
      expect(h.service.presenterId, 'me-01');

      expect(await h.service.stopPresent(), isTrue);
      expect(h.bridge.ackCalls.last.event, 'interactive:stopPresent');
      expect(h.service.isPresenting, isFalse);
      expect(h.service.presenterId, isNull);

      h.bridge.ackHandler = (String event, Object? payload) async =>
          <String, Object?>{'ok': false, 'reason': 'forbidden'};
      expect(await h.service.startPresent(), isFalse);
      expect(h.service.isPresenting, isFalse);
      expect(h.service.presenterId, isNull);
    });

    test('removeUser：{userId} 载荷；未连接 / 已移除均 false 且不发送', () async {
      final _Harness cold = _Harness();
      addTearDown(cold.service.dispose);
      expect(await cold.service.removeUser('peer-02'), isFalse);
      expect(cold.bridges, isEmpty);

      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('board:session', <String, Object?>{
        'userId': 'me-01',
        'authMode': 'anonymous',
        'role': 'Host',
      });

      expect(await h.service.removeUser('peer-02'), isTrue);
      expect(h.bridge.ackCalls.last.event, 'interactive:removeUser');
      expect(h.bridge.ackCalls.last.payload, <String, Object?>{'userId': 'peer-02'});

      // 已移除（room:removed）后禁止再发送互动命令。
      h.bridge.fireEvent('room:removed', <String, Object?>{
        'code': 'Removed',
        'message': 'Removed from the board',
        'reason': 'removed',
      });
      final int before = h.bridge.ackCalls.length;
      expect(await h.service.removeUser('peer-02'), isFalse);
      expect(h.bridge.ackCalls.length, before);
    });
  });

  group('interactive 订阅（S→C）', () {
    test('modeChanged：present 更新 mode / presenterId（缺省回落 by）；free 清空', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();

      h.bridge.fireEvent('interactive:modeChanged', <String, Object?>{
        'mode': 'present',
        'by': 'host-01',
        'presenterId': 'host-01',
      });
      expect(h.service.isPresenting, isTrue);
      expect(h.service.mode, 'present');
      expect(h.service.presenterId, 'host-01');

      // presenterId 缺省：回落发起者 `by`。
      h.bridge.fireEvent('interactive:modeChanged', <String, Object?>{
        'mode': 'present',
        'by': 'host-02',
      });
      expect(h.service.presenterId, 'host-02');

      h.bridge.fireEvent('interactive:modeChanged', <String, Object?>{'mode': 'free', 'by': 'host-02'});
      expect(h.service.isPresenting, isFalse);
      expect(h.service.mode, 'free');
      expect(h.service.presenterId, isNull);

      // 畸形载荷忽略。
      h.bridge.fireEvent('interactive:modeChanged', 'junk');
      expect(h.service.mode, 'free');
    });

    test('roleChanged：self 更新 role / grantedWrite；他人单播忽略', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('board:session', <String, Object?>{
        'userId': 'me-01',
        'authMode': 'anonymous',
        'role': 'Participant',
      });
      h.bridge.fireEvent('board:joined', <String, Object?>{
        'role': 'Participant',
        'participants': <Object?>[_participant('me-01', 'sock-1', 'Participant')],
      });

      // 他人单播：不改自身。
      h.bridge.fireEvent('interactive:roleChanged', <String, Object?>{
        'userId': 'peer-02',
        'role': 'Host',
        'grantedWrite': true,
      });
      expect(h.service.role, 'Participant');
      expect(h.service.grantedWrite, isFalse);

      // 自身：roleChanged 单播更新角色 + 临时写权。
      h.bridge.fireEvent('interactive:roleChanged', <String, Object?>{
        'userId': 'me-01',
        'role': 'Presenter',
        'grantedWrite': true,
      });
      expect(h.service.selfRole, 'Presenter');
      expect(h.service.grantedWrite, isTrue);
      expect(h.service.isPresenterOrHigher, isTrue);

      // 缺 grantedWrite 键：仅更新角色，写权保持。
      h.bridge.fireEvent('interactive:roleChanged', <String, Object?>{'userId': 'me-01', 'role': 'Viewer'});
      expect(h.service.role, 'Viewer');
      expect(h.service.grantedWrite, isTrue);
    });

    test('hostChanged：newHostId 为自己 → 角色升为 Host；参与者表角色同步', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('board:session', <String, Object?>{
        'userId': 'me-01',
        'authMode': 'anonymous',
        'role': 'Participant',
      });
      h.bridge.fireEvent('board:joined', <String, Object?>{
        'participants': <Object?>[
          _participant('me-01', 'sock-1', 'Participant'),
          _participant('peer-02', 'sock-2', 'Presenter'),
        ],
      });

      // 他人接任：本端角色不变，参与者表角色乐观同步。
      h.bridge.fireEvent('interactive:hostChanged', <String, Object?>{'newHostId': 'peer-02'});
      expect(h.service.isHost, isFalse);
      expect(_participantOf(h.service, 'peer-02').role, 'Host');
      expect(h.service.role, 'Participant');

      // 自己接任：角色升为 Host（服务端随后单播 roleChanged，幂等）。
      h.bridge.fireEvent('interactive:hostChanged', <String, Object?>{'newHostId': 'me-01'});
      expect(h.service.role, 'Host');
      expect(h.service.isHost, isTrue);
      expect(_participantOf(h.service, 'me-01').role, 'Host');

      // 畸形：空 newHostId 忽略。
      h.bridge.fireEvent('interactive:hostChanged', <String, Object?>{'newHostId': ''});
      expect(h.service.role, 'Host');
    });

    test('follow / unfollow：折叠跟随者集合驱动 needsViewportBroadcast；离开求交清理', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('board:session', <String, Object?>{
        'userId': 'me-01',
        'authMode': 'anonymous',
        'role': 'Host',
      });
      h.bridge.fireEvent('board:joined', <String, Object?>{
        'participants': <Object?>[
          _participant('me-01', 'sock-1', 'Host'),
          _participant('peer-02', 'sock-2', 'Participant'),
          _participant('peer-03', 'sock-3', 'Participant'),
        ],
      });
      expect(h.service.needsViewportBroadcast, isFalse);

      // 跟随单播折叠（无 ack 尽力而为）；重复 follow 幂等。
      h.bridge.fireEvent('interactive:follow', <String, Object?>{'followerUserId': 'peer-02'});
      h.bridge.fireEvent('interactive:follow', <String, Object?>{'followerUserId': 'peer-02'});
      expect(h.service.followers, <String>{'peer-02'});
      expect(h.service.needsViewportBroadcast, isTrue);

      h.bridge.fireEvent('interactive:follow', <String, Object?>{'followerUserId': 'peer-03'});
      expect(h.service.followers, <String>{'peer-02', 'peer-03'});

      // unfollow 移除单个；畸形载荷忽略。
      h.bridge.fireEvent('interactive:unfollow', <String, Object?>{'followerUserId': 'peer-02'});
      expect(h.service.followers, <String>{'peer-03'});
      h.bridge.fireEvent('interactive:follow', 'junk');
      h.bridge.fireEvent('interactive:follow', <String, Object?>{'followerUserId': ''});
      expect(h.service.followers, <String>{'peer-03'});

      // 跟随者离开房间：名单求交清理 → 恢复不外发。
      h.bridge.fireEvent('board:participants', <String, Object?>{
        'left': <Object?>[_participant('peer-03', 'sock-3', 'Participant')],
      });
      expect(h.service.followers, isEmpty);
      expect(h.service.needsViewportBroadcast, isFalse);

      // leave 复位：跟随者集合清空。
      h.bridge.fireEvent('interactive:follow', <String, Object?>{'followerUserId': 'peer-02'});
      expect(h.service.followers, <String>{'peer-02'});
      await h.service.leave();
      expect(h.service.followers, isEmpty);
      expect(h.service.needsViewportBroadcast, isFalse);
    });

    test('follow 广播：present 演示者（自己）时 needsViewportBroadcast 为真', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('board:session', <String, Object?>{
        'userId': 'me-01',
        'authMode': 'anonymous',
        'role': 'Host',
      });
      h.bridge.fireEvent('board:joined', <String, Object?>{'mode': 'free'});
      expect(h.service.needsViewportBroadcast, isFalse);

      // 自己开始演示：presenterId == self → 需要广播（供远端跟随）。
      h.bridge.fireEvent('interactive:modeChanged', <String, Object?>{
        'mode': 'present',
        'by': 'me-01',
        'presenterId': 'me-01',
      });
      expect(h.service.isPresenting, isTrue);
      expect(h.service.needsViewportBroadcast, isTrue);

      // 他人演示：本端不广播。
      h.bridge.fireEvent('interactive:modeChanged', <String, Object?>{
        'mode': 'present',
        'by': 'peer-02',
        'presenterId': 'peer-02',
      });
      expect(h.service.needsViewportBroadcast, isFalse);

      // present 结束恢复默认。
      h.bridge.fireEvent('interactive:modeChanged', <String, Object?>{'mode': 'free', 'by': 'peer-02'});
      expect(h.service.needsViewportBroadcast, isFalse);
    });

    test('participants updated：grantedWrite / handRaised 入库并同步自身状态', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('board:session', <String, Object?>{
        'userId': 'me-01',
        'authMode': 'anonymous',
        'role': 'Participant',
      });
      h.bridge.fireEvent('board:joined', <String, Object?>{
        'participants': <Object?>[
          _participant('me-01', 'sock-1', 'Participant'),
          _participant('peer-02', 'sock-2', 'Participant'),
        ],
      });

      h.bridge.fireEvent('board:participants', <String, Object?>{
        'updated': <Object?>[
          _participant('me-01', 'sock-1', 'Participant', grantedWrite: true, handRaised: true),
          _participant('peer-02', 'sock-2', 'Participant', handRaised: true),
        ],
      });

      expect(h.service.grantedWrite, isTrue);
      expect(h.service.selfHandRaised, isTrue);
      expect(
        h.service.raisedHands.map((WbCollabParticipant p) => p.userId).toList(),
        <String>['me-01', 'peer-02'],
      );

      // 新增举手成员 + 收手增量：均生效（插入序保持）。
      h.bridge.fireEvent('board:participants', <String, Object?>{
        'joined': <Object?>[_participant('peer-03', 'sock-3', 'Viewer', handRaised: true)],
        'updated': <Object?>[_participant('peer-02', 'sock-2', 'Participant', handRaised: false)],
      });
      expect(h.service.participants.length, 3);
      expect(
        h.service.raisedHands.map((WbCollabParticipant p) => p.userId).toList(),
        <String>['me-01', 'peer-03'],
      );
    });

    test('room:removed：removed 状态 / 原因 / 消息；重连成功后重置', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('board:session', <String, Object?>{
        'userId': 'me-01',
        'authMode': 'anonymous',
        'role': 'CoHost',
      });
      h.bridge.fireEvent('board:joined', <String, Object?>{
        'participants': <Object?>[_participant('me-01', 'sock-1', 'CoHost')],
      });
      expect(h.service.canManageInteractions, isTrue);

      h.bridge.fireEvent('room:removed', <String, Object?>{
        'code': 'Removed',
        'message': 'Removed from the board',
        'reason': 'removed',
      });

      expect(h.service.isRemoved, isTrue);
      expect(h.service.removedReason, 'removed');
      expect(h.service.removedMessage, 'Removed from the board');
      expect(h.service.canManageInteractions, isFalse);
      expect(h.service.canRaiseHand, isFalse);

      // 服务端随后断开（io server disconnect）→ disconnected；重连成功后重置 removed。
      h.bridge.fireDisconnected('io server disconnect');
      expect(h.service.status, WbRealtimeStatus.disconnected);
      await h.service.connect(_endpoint);
      expect(h.service.isRemoved, isFalse);
      expect(h.service.removedReason, isNull);
      expect(h.service.removedMessage, isNull);
    });

    test('room:removed：畸形载荷仍置 removed（原因 / 消息缺省 null）', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('room:removed', 'junk');

      expect(h.service.isRemoved, isTrue);
      expect(h.service.removedReason, isNull);
      expect(h.service.removedMessage, isNull);
      expect(h.service.canManageInteractions, isFalse);
      expect(h.service.canRaiseHand, isFalse);
    });
  });

  group('权限判定辅助（M3）', () {
    test('角色层级与互动入口：Host / CoHost / Participant / Viewer / Guest / 断线', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();

      // 未加入（角色未知）：互动入口全部关闭。
      expect(h.service.selfRole, isNull);
      expect(h.service.isHost, isFalse);
      expect(h.service.isCoHostOrHigher, isFalse);
      expect(h.service.canManageInteractions, isFalse);
      expect(h.service.canRaiseHand, isFalse);

      h.bridge.fireEvent('board:session', <String, Object?>{
        'userId': 'me-01',
        'authMode': 'anonymous',
        'role': 'Participant',
      });
      expect(h.service.selfRole, 'Participant');
      expect(h.service.canRaiseHand, isTrue);
      expect(h.service.canManageInteractions, isFalse);

      h.bridge.fireEvent('interactive:roleChanged', <String, Object?>{
        'userId': 'me-01',
        'role': 'CoHost',
        'grantedWrite': false,
      });
      expect(h.service.isCoHostOrHigher, isTrue);
      expect(h.service.canManageInteractions, isTrue);
      expect(h.service.canRaiseHand, isFalse);

      h.bridge.fireEvent('interactive:roleChanged', <String, Object?>{'userId': 'me-01', 'role': 'Host'});
      expect(h.service.isHost, isTrue);
      expect(h.service.canManageInteractions, isTrue);

      // Guest 低于 Viewer（服务端拒绝举手）：不给入口。
      h.bridge.fireEvent('interactive:roleChanged', <String, Object?>{'userId': 'me-01', 'role': 'Guest'});
      expect(h.service.canRaiseHand, isFalse);
      expect(h.service.canManageInteractions, isFalse);

      h.bridge.fireEvent('interactive:roleChanged', <String, Object?>{'userId': 'me-01', 'role': 'Viewer'});
      expect(h.service.canRaiseHand, isTrue);
      expect(h.service.canManageInteractions, isFalse);

      // 断线：互动入口关闭（防误操作）。
      h.bridge.fireDisconnected('transport close');
      expect(h.service.canRaiseHand, isFalse);
      expect(h.service.canManageInteractions, isFalse);
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
      h.bridge.fireEvent('interactive:modeChanged', <String, Object?>{'mode': 'present', 'by': 'me-01'});

      final FakeSocketIoBridge old = h.bridge;
      await h.service.leave();

      expect(h.service.status, WbRealtimeStatus.disconnected);
      expect(h.service.boardId, isNull);
      expect(h.service.role, isNull);
      expect(h.service.mode, isNull);
      expect(h.service.presenterId, isNull);
      expect(h.service.grantedWrite, isFalse);
      expect(h.service.selfHandRaised, isFalse);
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

    test('leave：复位被移出态（回到本地模式）', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected();
      h.bridge.fireEvent('room:removed', <String, Object?>{
        'code': 'Removed',
        'message': '你已被主持人移出该白板',
        'reason': 'removed',
      });
      expect(h.service.isRemoved, isTrue);

      await h.service.leave();

      // 退出房间回到本地：被移出态复位（只读横幅 / 编辑禁用随之解除）。
      expect(h.service.isRemoved, isFalse);
      expect(h.service.removedReason, isNull);
      expect(h.service.removedMessage, isNull);
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

  group('P4 协作通道（C→S 发送）', () {
    test('sendOps：ack 三态原样透传（{ok} / {ok,dup} / {ok:false,missingSeqs}）', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.connect(_endpoint);
      h.bridge.fireConnected(socketId: 'sock-1');

      final List<Object?> ops = <Object?>[
        <String, Object?>{'key': 'el:e1:data', 'value': 1, 'actor': 'a1', 'seq': 1},
      ];

      h.bridge.ackResponse = <String, Object?>{'ok': true};
      expect(await h.service.sendOps(ops), <String, Object?>{'ok': true});

      h.bridge.ackResponse = <String, Object?>{'ok': true, 'dup': true};
      expect(await h.service.sendOps(ops),
          <String, Object?>{'ok': true, 'dup': true});

      h.bridge.ackResponse = <String, Object?>{
        'ok': false,
        'missingSeqs': <Object?>[1, 2],
      };
      expect(await h.service.sendOps(ops), <String, Object?>{
        'ok': false,
        'missingSeqs': <Object?>[1, 2],
      });

      // 事件与载荷口径：三态同批透传（调用方负责补发）。
      expect(h.bridge.ackCalls, hasLength(3));
      expect(h.bridge.ackCalls.first.event, 'board:ops');
      expect(h.bridge.ackCalls.first.payload, ops);
    });

    test('sendOps：未连接 / 空批 → null 且不触达桥', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);

      // 未连接（无桥）→ null。
      expect(await h.service.sendOps(<Object?>[1]), isNull);

      await h.service.connect(_endpoint);
      h.bridge.fireConnected(socketId: 'sock-1');
      // 已连接但空批 → null，不发 ack 调用。
      expect(await h.service.sendOps(const <Object?>[]), isNull);
      expect(h.bridge.ackCalls, isEmpty);
    });

    test('sendPreview：连接时 emit presence:preview；空帧 / 未连接丢弃', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.connect(_endpoint);
      h.bridge.fireConnected(socketId: 'sock-1');

      h.service.sendPreview(<String, Object?>{
        'kind': 'cursor',
        'pageId': 'p1',
        'x': 1.5,
        'y': 2.5,
      });
      expect(h.bridge.emits.single.event, 'presence:preview');
      expect(h.bridge.emits.single.payload, <String, Object?>{
        'kind': 'cursor',
        'pageId': 'p1',
        'x': 1.5,
        'y': 2.5,
      });

      h.service.sendPreview(const <String, Object?>{}); // 空帧丢弃
      expect(h.bridge.emits, hasLength(1));
    });

    test('sendCheckpoint：emitWithAck board:checkpoint（stateVector + payload）', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.connect(_endpoint);
      h.bridge.fireConnected(socketId: 'sock-1');

      await h.service.sendCheckpoint(
        stateVector: <String, Object?>{'a1': 3},
        payload: '{"el:e1:data":{}}',
      );

      final FakeAckCall call = h.bridge.ackCalls.single;
      expect(call.event, 'board:checkpoint');
      expect(call.payload, <String, Object?>{
        'stateVector': <String, Object?>{'a1': 3},
        'payload': '{"el:e1:data":{}}',
      });
    });
  });

  group('P4 协作通道（S→C 订阅）', () {
    test('board:ops：单参数组投递（replay=false）；两参 [ops,meta] 透传 replay=true', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.connect(_endpoint);
      h.bridge.fireConnected(socketId: 'sock-1');

      List<Object?>? received;
      bool? receivedReplay;
      h.service.onRemoteOps = (List<Object?> ops, {bool replay = false}) {
        received = ops;
        receivedReplay = replay;
      };

      // 广播帧（单参 ops 数组）。
      h.bridge.fireEvent('board:ops', <Object?>[
        <String, Object?>{'key': 'el:e1:data', 'seq': 1},
      ]);
      expect(received, hasLength(1));
      expect(receivedReplay, isFalse);

      // 回放帧（桥透传 [ops, meta]：两参发射）。
      h.bridge.fireEvent('board:ops', <Object?>[
        <Object?>[
          <String, Object?>{'key': 'el:e1:data', 'seq': 1},
          <String, Object?>{'key': 'el:e2:data', 'seq': 2},
        ],
        <String, Object?>{'replay': true},
      ]);
      expect(received, hasLength(2));
      expect(receivedReplay, isTrue);

      // 空批不投递。
      h.bridge.fireEvent('board:ops', const <Object?>[]);
      expect(received, hasLength(2));
    });

    test('presence:preview：单帧包装为单元素列表投递；空帧丢弃', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.connect(_endpoint);
      h.bridge.fireConnected(socketId: 'sock-1');

      List<Object?>? received;
      h.service.onRemotePreviews = (List<Object?> previews) => received = previews;

      h.bridge.fireEvent('presence:preview', <String, Object?>{
        'kind': 'cursor',
        'userId': 'u2',
        'x': 10.0,
        'y': 20.0,
      });
      expect(received, hasLength(1));
      expect((received!.single! as Map<String, Object?>)['userId'], 'u2');

      h.bridge.fireEvent('presence:preview', const <String, Object?>{});
      expect(received, hasLength(1));
    });

    test('board:checkpointRequest：通知回调', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.connect(_endpoint);
      h.bridge.fireConnected(socketId: 'sock-1');

      int requests = 0;
      h.service.onCheckpointRequest = () => requests += 1;

      h.bridge.fireEvent('board:checkpointRequest', <String, Object?>{
        'stateVector': <String, Object?>{},
      });
      expect(requests, 1);
    });

    test('board:joined：全量 ack 透传到 onBoardJoined（含 snapshot）', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.connect(_endpoint);
      h.bridge.fireConnected(socketId: 'sock-1');

      Map<String, Object?>? joined;
      h.service.onBoardJoined = (Map<String, Object?> payload) => joined = payload;

      h.bridge.fireEvent('board:joined', <String, Object?>{
        'boardId': 'board-1',
        'role': 'Host',
        'mode': 'free',
        'snapshot': <String, Object?>{
          'stateVector': <String, Object?>{'a1': 1},
          'payload': '{}',
        },
      });

      expect(joined?['boardId'], 'board-1');
      expect(joined?['role'], 'Host');
      expect(
          (joined?['snapshot'] as Map<String, Object?>?)?['payload'], '{}');
    });

    test('join 载荷携带 lastSeenVersionProvider 水位（重连增量语义）', () async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.connect(_endpoint);

      h.service.lastSeenVersionProvider =
          () => <String, Object?>{'a1': 5, 'a2': 2};
      await h.service.joinBoard('board-1');
      h.bridge.fireConnected(socketId: 'sock-1');
      await _flush();

      final FakeAckCall joinCall = h.bridge.ackCalls.single;
      expect(joinCall.event, 'board:join');
      expect(joinCall.payload, <String, Object?>{
        'boardId': 'board-1',
        'lastSeenVersion': <String, Object?>{'a1': 5, 'a2': 2},
      });
    });
  });

  group('数据模型', () {
    test('WbCollabParticipant.tryParse：字段容错 / M3 扩展字段 / 相等性 / 错误 toString', () {
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
      expect(minimal.grantedWrite, isFalse);
      expect(minimal.handRaised, isFalse);

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

      // M3 扩展字段：grantedWrite / handRaised 解析、copyWith、相等性。
      final WbCollabParticipant m3 = WbCollabParticipant.tryParse(
        <String, Object?>{
          'userId': 'u2',
          'socketId': 's2',
          'role': 'Participant',
          'grantedWrite': true,
          'handRaised': true,
        },
      )!;
      expect(m3.grantedWrite, isTrue);
      expect(m3.handRaised, isTrue);
      expect(m3.copyWith(handRaised: false).handRaised, isFalse);
      expect(m3.copyWith(handRaised: false).grantedWrite, isTrue);
      expect(m3.copyWith(role: 'Presenter').role, 'Presenter');
      expect(m3.copyWith(handRaised: false) == m3, isFalse);
      expect(
        m3.copyWith(),
        const WbCollabParticipant(
          userId: 'u2',
          socketId: 's2',
          role: 'Participant',
          joinedAtMs: 0,
          grantedWrite: true,
          handRaised: true,
        ),
      );

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

/// 构造参与者载荷（服务端 `ParticipantInfo`：userId/socketId/role/joinedAt
/// + M3 扩展 grantedWrite / handRaised，按需携带）。
Map<String, Object?> _participant(
  String userId,
  String socketId,
  String role, {
  int joinedAt = 1000,
  bool? grantedWrite,
  bool? handRaised,
}) =>
    <String, Object?>{
      'userId': userId,
      'socketId': socketId,
      'role': role,
      'joinedAt': joinedAt,
      if (grantedWrite != null) 'grantedWrite': grantedWrite,
      if (handRaised != null) 'handRaised': handRaised,
    };

/// 服务内指定 userId 的参与者（不存在则抛 [StateError]）。
WbCollabParticipant _participantOf(WbRealtimeService service, String userId) =>
    service.participants.firstWhere((WbCollabParticipant p) => p.userId == userId);

/// 冲刷微任务。
Future<void> _flush() => Future<void>.delayed(Duration.zero);

/// 某桥 `board:join` 的调用次数。
int _joinCount(FakeSocketIoBridge bridge) =>
    bridge.ackCalls.where((FakeAckCall call) => call.event == 'board:join').length;
