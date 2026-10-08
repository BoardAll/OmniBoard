/// 协同 M3 服务层测试（fake 引擎，不依赖 DLL 与网络）：
/// interactive 转发（9 action + 离线 / 异常 / 拒绝降级）/ drain 批次
/// （interactiveAcks / incomingFollows / removed）/ 发起端本地确定性更新
/// （ack 补丁结算 / 失败丢弃 / 重连与 stop 清理）/ canEdit 判定矩阵
/// （free / present × 6 角色 × grantedWrite）/ needsViewportBroadcast /
/// 角色派生 getter 与存续状态透出。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';

import 'support/fake_collab_engine.dart';

/// 服务 + fake 引擎 + 手动定时器装配（同 sync_service_test 模式）。
class _Harness {
  _Harness({String? endpoint}) {
    service = WbCollabService(
      engine: engine,
      endpoint: endpoint,
      sleep: (Duration _) async {},
      pollTimerFactory: timers.create,
      actorGenerator: () => 'wb-test-actor',
      clock: () => DateTime(2026, 10, 1, 12),
    );
  }

  final FakeCollabEngine engine = FakeCollabEngine();
  final FakePollTimerFactory timers = FakePollTimerFactory();
  late final WbCollabService service;
}

/// 构造房间快照（M3 字段全集；未列出字段取缺省）。
WbSyncRoomData _room({
  List<dynamic> participants = const <dynamic>[],
  String mode = '',
  String selfRole = '',
  String presenterId = '',
  String hostUserId = '',
  bool grantedWrite = false,
  String selfUserId = '',
  String checkpointStatus = 'idle',
  bool recovered = false,
}) =>
    WbSyncRoomData(
      participants: participants,
      mode: mode,
      selfRole: selfRole,
      presenterId: presenterId,
      hostUserId: hostUserId,
      grantedWrite: grantedWrite,
      selfUserId: selfUserId,
      checkpointStatus: checkpointStatus,
      recovered: recovered,
    );

void main() {
  late _Harness h;

  setUp(() {
    h = _Harness();
    addTearDown(h.service.dispose);
  });

  // ---- interactive 转发 ---------------------------------------------------

  group('WbCollabService.interactive 转发', () {
    test('raiseHand / lowerHand：无目标参数转发', () async {
      await h.service.start(boardId: 'b1');

      final WbSyncInteractiveResult raise = h.service.raiseHand();
      final WbSyncInteractiveResult lower = h.service.lowerHand();

      expect(raise.requested, isTrue);
      expect(lower.requested, isTrue);
      expect(h.engine.interactiveCalls, <Map<String, dynamic>>[
        <String, dynamic>{'action': 'raiseHand'},
        <String, dynamic>{'action': 'lowerHand'},
      ]);
    });

    test('grantControl / revokeControl / removeUser：userId 载荷', () async {
      await h.service.start(boardId: 'b1');

      h.service.grantControl('u2');
      h.service.revokeControl('u2');
      h.service.removeUser('u3');

      expect(h.engine.interactiveCalls, <Map<String, dynamic>>[
        <String, dynamic>{'action': 'grantControl', 'userId': 'u2'},
        <String, dynamic>{'action': 'revokeControl', 'userId': 'u2'},
        <String, dynamic>{'action': 'removeUser', 'userId': 'u3'},
      ]);
    });

    test('startPresent / stopPresent：无参数转发', () async {
      await h.service.start(boardId: 'b1');

      h.service.startPresent();
      h.service.stopPresent();

      expect(h.engine.interactiveCalls, <Map<String, dynamic>>[
        <String, dynamic>{'action': 'startPresent'},
        <String, dynamic>{'action': 'stopPresent'},
      ]);
    });

    test('follow / unfollow：targetUserId 载荷', () async {
      await h.service.start(boardId: 'b1');

      h.service.follow('u7');
      h.service.unfollow('u7');

      expect(h.engine.interactiveCalls, <Map<String, dynamic>>[
        <String, dynamic>{'action': 'follow', 'targetUserId': 'u7'},
        <String, dynamic>{'action': 'unfollow', 'targetUserId': 'u7'},
      ]);
    });

    test('未 start（离线）：requested:false，不触达引擎', () {
      final WbSyncInteractiveResult result = h.service.raiseHand();

      expect(result.requested, isFalse);
      expect(h.engine.interactiveCalls, isEmpty);
    });

    test('无引擎（演示模式）：requested:false，不抛', () {
      final WbCollabService bare = WbCollabService();
      addTearDown(bare.dispose);

      expect(bare.raiseHand().requested, isFalse);
      expect(bare.follow('u2').requested, isFalse);
    });

    test('引擎抛错：requested:false + lastError 记录，不抛', () async {
      await h.service.start(boardId: 'b1');
      h.engine.interactiveError = StateError('socket down');

      final WbSyncInteractiveResult result = h.service.raiseHand();

      expect(result.requested, isFalse);
      expect(h.service.lastError, contains('socket down'));
    });

    test('引擎受理拒绝（requested:false）：原样透传', () async {
      await h.service.start(boardId: 'b1');
      h.engine.interactiveRequested = false;

      final WbSyncInteractiveResult result = h.service.startPresent();

      expect(result.requested, isFalse);
      expect(h.engine.interactiveCalls.single['action'], 'startPresent');
    });
  });

  // ---- M3 drain 批次 ------------------------------------------------------

  group('WbCollabService M3 drain 批次', () {
    test('interactiveAcks：失败 → onInteractiveError(action, reason)', () async {
      await h.service.start(boardId: 'b1');
      final List<List<String>> errors = <List<String>>[];
      h.service.onInteractiveError = (String action, String reason) =>
          errors.add(<String>[action, reason]);

      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{
          'action': 'grantControl',
          'ok': false,
          'reason': 'forbidden',
        },
        <String, dynamic>{'action': 'raiseHand', 'ok': true},
      ];
      h.timers.fire();

      expect(errors, <List<String>>[
        <String>['grantControl', 'forbidden'],
      ]);
    });

    test('interactiveAcks：成功 / 坏载荷不触发回调', () async {
      await h.service.start(boardId: 'b1');
      int errors = 0;
      h.service.onInteractiveError = (String action, String reason) => errors++;

      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'raiseHand', 'ok': true},
        'garbage',
        42,
      ];
      h.timers.fire();

      expect(errors, 0);
    });

    test('interactiveAcks：失败但无回调（null）时安全空转', () async {
      await h.service.start(boardId: 'b1');

      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'raiseHand', 'ok': false},
      ];
      h.timers.fire(); // 不抛。

      expect(h.service.status, WbSyncStatus.online);
    });

    test('incomingFollows：follow 增 / unfollow 减 + 变化通知', () async {
      await h.service.start(boardId: 'b1');
      int notified = 0;
      h.service.addListener(() => notified++);

      h.engine.nextIncomingFollows = <dynamic>[
        <String, dynamic>{'followerUserId': 'u2', 'action': 'follow'},
      ];
      h.timers.fire();
      expect(h.service.followers, <String>{'u2'});
      expect(notified, 1);

      h.engine.nextIncomingFollows = <dynamic>[
        <String, dynamic>{'followerUserId': 'u2', 'action': 'unfollow'},
      ];
      h.timers.fire();
      expect(h.service.followers, isEmpty);
      expect(notified, 2);
    });

    test('incomingFollows：重复 follow 幂等（无变化不通知）', () async {
      await h.service.start(boardId: 'b1');
      int notified = 0;
      h.service.addListener(() => notified++);

      final List<dynamic> follow = <dynamic>[
        <String, dynamic>{'followerUserId': 'u2', 'action': 'follow'},
      ];
      h.engine.nextIncomingFollows = follow;
      h.timers.fire();
      expect(notified, 1);

      h.engine.nextIncomingFollows = follow;
      h.timers.fire();
      expect(h.service.followers, <String>{'u2'});
      expect(notified, 1); // 无变化：不重复通知。
    });

    test('incomingFollows：坏载荷（非 Map / 缺 id / 未知 action）忽略', () async {
      await h.service.start(boardId: 'b1');

      h.engine.nextIncomingFollows = <dynamic>[
        'garbage',
        <String, dynamic>{'action': 'follow'},
        <String, dynamic>{'followerUserId': '', 'action': 'follow'},
        <String, dynamic>{'followerUserId': 'u2', 'action': 'unknown'},
      ];
      h.timers.fire();

      expect(h.service.followers, isEmpty);
    });

    test('removed：只读态 + reason + 一次性 + 主动断开引擎（停止重连）', () async {
      await h.service.start(boardId: 'b1');
      int notified = 0;
      h.service.addListener(() => notified++);

      h.engine.nextRemoved = <String, dynamic>{'reason': 'RemovedByHost'};
      h.timers.fire();

      expect(h.service.isRemoved, isTrue);
      expect(h.service.removedReason, 'RemovedByHost');
      expect(h.service.removedMessage, '你已被移出此白板，当前为只读');
      expect(h.service.canEdit, isFalse);
      // R5：被移除 → 主动断开引擎（socket.io 自动重连不再拉回房间），状态转 offline。
      // 计数 2 = start 内置 stop 幂等清理 1 次 + 被移除主动断开 1 次。
      expect(h.engine.disconnectCount, 2);
      expect(h.service.status, WbSyncStatus.offline);
      expect(notified, 2); // offline 状态 + removed 横幅

      // 重复通知：不覆盖首个 reason、不重复断开、不重复通知。
      h.engine.nextRemoved = <String, dynamic>{'reason': 'again'};
      h.timers.fire();
      expect(h.service.removedReason, 'RemovedByHost');
      expect(h.engine.disconnectCount, 2);
      expect(notified, 3); // 仅断开后的状态快照变化（connected → disconnected）
    });

    test('followers 与在线名单求交：跟随者离开即剔除', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(participants: <dynamic>['u2', 'u3']);
      h.engine.nextIncomingFollows = <dynamic>[
        <String, dynamic>{'followerUserId': 'u2', 'action': 'follow'},
        <String, dynamic>{'followerUserId': 'u3', 'action': 'follow'},
      ];
      h.timers.fire();
      expect(h.service.followers, <String>{'u2', 'u3'});

      h.engine.room = _room(participants: <dynamic>['u3']);
      h.timers.fire();

      expect(h.service.followers, <String>{'u3'});
    });

    test('followers 求交：名单为空保守不清（等待后续快照）', () async {
      await h.service.start(boardId: 'b1');
      h.engine.nextIncomingFollows = <dynamic>[
        <String, dynamic>{'followerUserId': 'u2', 'action': 'follow'},
      ];
      h.timers.fire();

      h.engine.room = _room(); // participants 空。
      h.timers.fire();

      expect(h.service.followers, <String>{'u2'});
    });

    test('stop：followers / removed / 恢复标记全清', () async {
      await h.service.start(boardId: 'b1');
      h.engine.nextIncomingFollows = <dynamic>[
        <String, dynamic>{'followerUserId': 'u2', 'action': 'follow'},
      ];
      h.engine.nextRemoved = <String, dynamic>{'reason': 'x'};
      h.timers.fire();
      expect(h.service.followers, isNotEmpty);
      expect(h.service.isRemoved, isTrue);

      await h.service.stop();

      expect(h.service.followers, isEmpty);
      expect(h.service.isRemoved, isFalse);
      expect(h.service.removedReason, isEmpty);
    });
  });

  // ---- 发起端本地确定性更新（服务端广播排除发起者） -------------------------

  group('WbCollabService 发起端本地确定性更新', () {
    WbCollabParticipant byId(WbCollabService service, String id) =>
        service.participantList
            .firstWhere((WbCollabParticipant p) => p.id == id);

    test('raiseHand / lowerHand：ack 成功后 selfHandRaised 翻转', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        participants: <dynamic>[
          <String, dynamic>{
            'userId': 'u1',
            'role': 'Participant',
            'handRaised': false,
          },
          <String, dynamic>{'userId': 'u2', 'role': 'Host'},
        ],
        selfUserId: 'u1',
      );
      h.timers.fire();
      expect(h.service.selfHandRaised, isFalse);

      h.service.raiseHand();
      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'raiseHand', 'ok': true},
      ];
      h.timers.fire();
      expect(h.service.selfHandRaised, isTrue);
      // 列表读取面同步合并（行内标记）。
      expect(byId(h.service, 'u1').handRaised, isTrue);

      h.service.lowerHand();
      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'lowerHand', 'ok': true},
      ];
      h.timers.fire();
      expect(h.service.selfHandRaised, isFalse);
      expect(byId(h.service, 'u1').handRaised, isFalse);
    });

    test('ack 失败：不应用补丁 + 报错回调 + 待定丢弃', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        participants: <dynamic>[
          <String, dynamic>{
            'userId': 'u1',
            'role': 'Participant',
            'handRaised': false,
          },
        ],
        selfUserId: 'u1',
      );
      final List<List<String>> errors = <List<String>>[];
      h.service.onInteractiveError = (String action, String reason) =>
          errors.add(<String>[action, reason]);

      h.service.raiseHand();
      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{
          'action': 'raiseHand',
          'ok': false,
          'reason': 'forbidden',
        },
      ];
      h.timers.fire();
      expect(h.service.selfHandRaised, isFalse);
      expect(errors, <List<String>>[
        <String>['raiseHand', 'forbidden'],
      ]);

      // 待定已丢弃：迟到的成功回执不再误应用。
      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'raiseHand', 'ok': true},
      ];
      h.timers.fire();
      expect(h.service.selfHandRaised, isFalse);
    });

    test('转发未受理（requested:false）：不入队，不应用', () async {
      await h.service.start(boardId: 'b1');
      h.engine.interactiveRequested = false;

      h.service.raiseHand();
      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'raiseHand', 'ok': true},
      ];
      h.timers.fire();

      expect(h.service.selfHandRaised, isFalse);
    });

    test('startPresent / stopPresent：ack 后 presentMode / presenterId 翻转',
        () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(selfUserId: 'u1', mode: 'free');
      h.timers.fire();
      expect(h.service.presentMode, isFalse);

      h.service.startPresent();
      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'startPresent', 'ok': true},
      ];
      h.timers.fire();
      expect(h.service.presentMode, isTrue);
      expect(h.service.presenterId, 'u1');

      h.service.stopPresent();
      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'stopPresent', 'ok': true},
      ];
      h.timers.fire();
      expect(h.service.presentMode, isFalse);
      expect(h.service.presenterId, isEmpty);
    });

    test('grantControl / revokeControl：ack 后目标 grantedWrite 合并',
        () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        participants: <dynamic>[
          <String, dynamic>{'userId': 'u1', 'role': 'CoHost'},
          <String, dynamic>{
            'userId': 'u2',
            'role': 'Viewer',
            'grantedWrite': false,
          },
        ],
        selfUserId: 'u1',
      );
      h.timers.fire();

      h.service.grantControl('u2');
      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'grantControl', 'ok': true},
      ];
      h.timers.fire();
      expect(byId(h.service, 'u2').grantedWrite, isTrue);

      h.service.revokeControl('u2');
      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'revokeControl', 'ok': true},
      ];
      h.timers.fire();
      expect(byId(h.service, 'u2').grantedWrite, isFalse);
    });

    test('同 action 多笔待定：按 ack 到达顺序 FIFO 结算', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        participants: <dynamic>[
          <String, dynamic>{'userId': 'u1', 'role': 'CoHost'},
          <String, dynamic>{'userId': 'u2', 'role': 'Viewer'},
          <String, dynamic>{'userId': 'u3', 'role': 'Viewer'},
        ],
        selfUserId: 'u1',
      );
      h.timers.fire();

      h.service.grantControl('u2');
      h.service.grantControl('u3');
      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'grantControl', 'ok': true},
      ];
      h.timers.fire();
      expect(byId(h.service, 'u2').grantedWrite, isTrue); // 首笔先结算。
      expect(byId(h.service, 'u3').grantedWrite, isFalse);

      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'grantControl', 'ok': true},
      ];
      h.timers.fire();
      expect(byId(h.service, 'u3').grantedWrite, isTrue);
    });

    test('grantedWrite 补丁随目标离开裁剪（重新加入不残留）', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        participants: <dynamic>[
          <String, dynamic>{'userId': 'u1', 'role': 'CoHost'},
          <String, dynamic>{'userId': 'u2', 'role': 'Viewer'},
        ],
        selfUserId: 'u1',
      );
      h.timers.fire();

      h.service.grantControl('u2');
      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'grantControl', 'ok': true},
      ];
      h.timers.fire();
      expect(byId(h.service, 'u2').grantedWrite, isTrue);

      // u2 离开 → 补丁裁剪。
      h.engine.room = _room(
        participants: <dynamic>[
          <String, dynamic>{'userId': 'u1', 'role': 'CoHost'},
        ],
        selfUserId: 'u1',
      );
      h.timers.fire();

      // u2 重新加入（服务端快照 grantedWrite:false）：不残留旧补丁。
      h.engine.room = _room(
        participants: <dynamic>[
          <String, dynamic>{'userId': 'u1', 'role': 'CoHost'},
          <String, dynamic>{'userId': 'u2', 'role': 'Viewer'},
        ],
        selfUserId: 'u1',
      );
      h.timers.fire();
      expect(byId(h.service, 'u2').grantedWrite, isFalse);
    });

    test('stop：补丁清空（重启后不残留）', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        participants: <dynamic>[
          <String, dynamic>{
            'userId': 'u1',
            'role': 'Participant',
            'handRaised': false,
          },
        ],
        selfUserId: 'u1',
      );
      h.service.raiseHand();
      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'raiseHand', 'ok': true},
      ];
      h.timers.fire();
      expect(h.service.selfHandRaised, isTrue);

      await h.service.stop();
      h.engine.room = _room(
        participants: <dynamic>[
          <String, dynamic>{
            'userId': 'u1',
            'role': 'Participant',
            'handRaised': false,
          },
        ],
        selfUserId: 'u1',
      );
      await h.service.start(boardId: 'b1');
      h.timers.fire();

      expect(h.service.selfHandRaised, isFalse);
    });

    test('传输重连（reconnectCount 增长）：补丁清空', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        participants: <dynamic>[
          <String, dynamic>{
            'userId': 'u1',
            'role': 'Participant',
            'handRaised': false,
          },
        ],
        selfUserId: 'u1',
      );
      h.service.raiseHand();
      h.engine.nextInteractiveAcks = <dynamic>[
        <String, dynamic>{'action': 'raiseHand', 'ok': true},
      ];
      h.timers.fire();
      expect(h.service.selfHandRaised, isTrue);

      h.engine.reconnectCount = 1;
      h.timers.fire();

      expect(h.service.selfHandRaised, isFalse);
    });
  });

  // ---- canEdit 判定矩阵 ----------------------------------------------------

  group('WbCollabService.canEdit 判定矩阵', () {
    const Map<String, bool> freeMatrix = <String, bool>{
      roleHost: true,
      roleCoHost: true,
      rolePresenter: false,
      roleParticipant: false,
      roleViewer: false,
      roleGuest: false,
    };
    for (final MapEntry<String, bool> entry in freeMatrix.entries) {
      test('free · ${entry.key} → ${entry.value}', () async {
        await h.service.start(boardId: 'b1');
        h.engine.room = _room(selfRole: entry.key, mode: 'free');
        h.timers.fire();

        expect(h.service.canEdit, entry.value);
      });
    }

    const Map<String, bool> presentMatrix = <String, bool>{
      roleHost: true,
      roleCoHost: true,
      rolePresenter: true,
      roleParticipant: false,
      roleViewer: false,
      roleGuest: false,
    };
    for (final MapEntry<String, bool> entry in presentMatrix.entries) {
      test('present · ${entry.key} → ${entry.value}', () async {
        await h.service.start(boardId: 'b1');
        h.engine.room = _room(selfRole: entry.key, mode: 'present');
        h.timers.fire();

        expect(h.service.canEdit, entry.value);
      });
    }

    for (final String role in <String>[
      roleParticipant,
      roleViewer,
      roleGuest,
    ]) {
      test('present · $role · grantedWrite → true（授权优先）', () async {
        await h.service.start(boardId: 'b1');
        h.engine.room =
            _room(selfRole: role, mode: 'present', grantedWrite: true);
        h.timers.fire();

        expect(h.service.canEdit, isTrue);
      });
    }

    test('free · Viewer · grantedWrite → true', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        selfRole: roleViewer,
        mode: 'free',
        grantedWrite: true,
      );
      h.timers.fire();

      expect(h.service.canEdit, isTrue);
    });

    test('角色未同步（空串；单机 / 旧引擎）→ 本地放行 true', () async {
      await h.service.start(boardId: 'b1');

      expect(h.service.selfRole, isEmpty);
      expect(h.service.canEdit, isTrue);
    });

    test('removed 优先于一切（Host + grantedWrite 仍只读）', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        selfRole: roleHost,
        mode: 'free',
        grantedWrite: true,
      );
      h.engine.nextRemoved = <String, dynamic>{'reason': 'kicked'};
      h.timers.fire();

      expect(h.service.canEdit, isFalse);
    });

    test('未在线（未 start）+ 快照 Host：不校验在线（canEdit 仅看权限）',
        () {
      // 未 start 时 room 恒为缺省：canEdit 本地放行（不与在线耦合）。
      expect(h.service.canEdit, isTrue);
    });
  });

  // ---- needsViewportBroadcast --------------------------------------------

  group('WbCollabService.needsViewportBroadcast', () {
    test('默认（无跟随者 / 非演示者）→ false', () async {
      await h.service.start(boardId: 'b1');

      expect(h.service.needsViewportBroadcast, isFalse);
    });

    test('有跟随者 → true；unfollow 后回落 false', () async {
      await h.service.start(boardId: 'b1');

      h.engine.nextIncomingFollows = <dynamic>[
        <String, dynamic>{'followerUserId': 'u2', 'action': 'follow'},
      ];
      h.timers.fire();
      expect(h.service.needsViewportBroadcast, isTrue);

      h.engine.nextIncomingFollows = <dynamic>[
        <String, dynamic>{'followerUserId': 'u2', 'action': 'unfollow'},
      ];
      h.timers.fire();
      expect(h.service.needsViewportBroadcast, isFalse);
    });

    test('present 且本端为演示者 → true', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        mode: 'present',
        presenterId: 'me',
        selfUserId: 'me',
        selfRole: roleHost,
      );
      h.timers.fire();

      expect(h.service.needsViewportBroadcast, isTrue);
    });

    test('present 但演示者非本端 / 无演示者 → false', () async {
      await h.service.start(boardId: 'b1');

      h.engine.room = _room(
        mode: 'present',
        presenterId: 'u9',
        selfUserId: 'me',
        selfRole: roleParticipant,
      );
      h.timers.fire();
      expect(h.service.needsViewportBroadcast, isFalse);

      h.engine.room = _room(
        mode: 'present',
        presenterId: '',
        selfUserId: 'me',
        selfRole: roleParticipant,
      );
      h.timers.fire();
      expect(h.service.needsViewportBroadcast, isFalse);
    });
  });

  // ---- 角色派生 getter 与存续状态 ------------------------------------------

  group('WbCollabService 角色派生 getter', () {
    const Map<String, List<bool>> rankMatrix = <String, List<bool>>{
      // [isHost, isCoHostOrHigher, isPresenterOrHigher]
      roleHost: <bool>[true, true, true],
      roleCoHost: <bool>[false, true, true],
      rolePresenter: <bool>[false, false, true],
      roleParticipant: <bool>[false, false, false],
      roleViewer: <bool>[false, false, false],
      roleGuest: <bool>[false, false, false],
    };
    for (final MapEntry<String, List<bool>> entry in rankMatrix.entries) {
      test('rank · ${entry.key} → ${entry.value}', () async {
        await h.service.start(boardId: 'b1');
        h.engine.room = _room(selfRole: entry.key);
        h.timers.fire();

        expect(h.service.isHost, entry.value[0]);
        expect(h.service.isCoHostOrHigher, entry.value[1]);
        expect(h.service.isPresenterOrHigher, entry.value[2]);
      });
    }

    const Map<String, bool> manageMatrix = <String, bool>{
      roleHost: true,
      roleCoHost: true,
      rolePresenter: false,
      roleParticipant: false,
      roleViewer: false,
      roleGuest: false,
    };
    for (final MapEntry<String, bool> entry in manageMatrix.entries) {
      test('canManageInteractions · ${entry.key} → ${entry.value}', () async {
        await h.service.start(boardId: 'b1');
        h.engine.room = _room(selfRole: entry.key);
        h.timers.fire();

        expect(h.service.canManageInteractions, entry.value);
      });
    }

    const Map<String, bool> raiseMatrix = <String, bool>{
      roleHost: false,
      roleCoHost: false,
      rolePresenter: true,
      roleParticipant: true,
      roleViewer: true,
      roleGuest: false,
    };
    for (final MapEntry<String, bool> entry in raiseMatrix.entries) {
      test('canRaiseHand · ${entry.key} → ${entry.value}', () async {
        await h.service.start(boardId: 'b1');
        h.engine.room = _room(selfRole: entry.key);
        h.timers.fire();

        expect(h.service.canRaiseHand, entry.value);
      });
    }

    test('selfHandRaised：本端 handRaised 标记（服务端权威）', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        selfUserId: 'me',
        participants: <dynamic>[
          <String, dynamic>{
            'userId': 'me',
            'role': roleParticipant,
            'handRaised': true,
          },
          <String, dynamic>{'userId': 'u2', 'role': roleHost},
        ],
      );
      h.timers.fire();

      expect(h.service.selfHandRaised, isTrue);
    });

    test('canGrantControlParticipant / canRemoveParticipant 前置收窄', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(selfUserId: 'me', selfRole: roleCoHost);
      h.timers.fire();

      // CoHost 可对低级别（非 CoHost+、非本人、非空）授权 / 移除。
      expect(h.service.canGrantControlParticipant('u2', roleParticipant), isTrue);
      expect(h.service.canRemoveParticipant('u2', roleParticipant), isTrue);
      // Host 目标（≥ CoHost）/ 本人 / 空 id：拒绝。
      expect(h.service.canGrantControlParticipant('h1', roleHost), isFalse);
      expect(h.service.canGrantControlParticipant('me', roleParticipant), isFalse);
      expect(h.service.canGrantControlParticipant('', roleParticipant), isFalse);
      // CoHost 不可移除 CoHost（rank 不严格大于）。
      expect(h.service.canRemoveParticipant('c2', roleCoHost), isFalse);
    });

    test('presentMode / presenterId / hostUserId / checkpointStatus 透出',
        () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        mode: 'present',
        presenterId: 'p1',
        hostUserId: 'h1',
        checkpointStatus: 'uploaded',
      );
      h.timers.fire();

      expect(h.service.presentMode, isTrue);
      expect(h.service.presenterId, 'p1');
      expect(h.service.hostUserId, 'h1');
      expect(h.service.checkpointStatus, 'uploaded');
      expect(h.service.grantedWrite, isFalse);
    });

    test('free 模式 presentMode=false（与 isDemoMode 无关）', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(mode: 'free');
      h.timers.fire();

      expect(h.service.presentMode, isFalse);
      expect(h.service.presenterId, isEmpty);
    });
  });

  // ---- 存续提示（recovered） ----------------------------------------------

  group('WbCollabService 存续提示', () {
    test('recovered：shouldNotifyRecovered 一次性', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(recovered: true, checkpointStatus: 'uploaded');
      h.timers.fire();

      expect(h.service.recovered, isTrue);
      expect(h.service.shouldNotifyRecovered, isTrue);

      h.service.markRecoveredNotified();
      expect(h.service.shouldNotifyRecovered, isFalse);

      h.timers.fire(); // 后续快照仍 recovered：不再提示。
      expect(h.service.shouldNotifyRecovered, isFalse);
    });

    test('未恢复：shouldNotifyRecovered false', () async {
      await h.service.start(boardId: 'b1');

      expect(h.service.recovered, isFalse);
      expect(h.service.shouldNotifyRecovered, isFalse);
    });
  });
}
