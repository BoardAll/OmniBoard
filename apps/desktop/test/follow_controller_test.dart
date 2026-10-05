/// 协同 M3 跟随控制器测试（fake 引擎 + 真实画布 / 页面状态，无 DLL）：
/// 启动 / 停止 / 切换目标 / 用户手势与切页打断 / 帧消费（viewport 视口、
/// page 页序切页、坏载荷忽略）/ syncWithRoom（目标离开 / 移除 / 断连静默
/// 停止 / present 自动跟随与抑制）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';
import 'package:whiteboard_desktop/state/follow_controller.dart';
import 'package:whiteboard_desktop/state/page_state.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';

import 'support/fake_collab_engine.dart';

/// 服务 + 真实画布 / 页面状态 + 手动定时器装配。
class _Harness {
  _Harness() {
    canvas = WbCanvasController(
      previewTimerFactory: (Duration _, void Function() onTick) =>
          FakePollTimer(onTick),
    );
    service = WbCollabService(
      engine: engine,
      sleep: (Duration _) async {},
      pollTimerFactory: timers.create,
      actorGenerator: () => 'u-self',
      clock: () => DateTime(2026, 10, 1, 12),
    );
    ffi = WbFfiService(candidatePaths: const <String>['__wb_missing__.dll']);
    pages = WbPageState(ops: WbFfiPageOps(ffi))
      ..restore(
        boardId: 'local-b',
        pages: const <WbPage>[
          WbPage(id: 'local-b-page-1', name: '页面 1'),
          WbPage(id: 'local-b-page-3', name: '页面 3'),
          WbPage(id: 'local-b-page-5', name: '页面 5'),
        ],
      );
    follow = WbFollowController(
      collab: service,
      canvas: canvas,
      pageState: pages,
    );
  }

  final FakeCollabEngine engine = FakeCollabEngine();
  final FakePollTimerFactory timers = FakePollTimerFactory();
  late final WbCollabService service;
  late final WbCanvasController canvas;
  late final WbFfiService ffi;
  late final WbPageState pages;
  late final WbFollowController follow;
}

/// 构造房间快照（M3 字段子集）。
WbSyncRoomData _room({
  List<dynamic> participants = const <dynamic>[],
  String mode = '',
  String selfRole = '',
  String presenterId = '',
  String selfUserId = '',
}) =>
    WbSyncRoomData(
      participants: participants,
      mode: mode,
      selfRole: selfRole,
      presenterId: presenterId,
      selfUserId: selfUserId,
    );

/// viewport 帧（服务端附加权威 userId）。
Map<String, dynamic> _viewportFrame(
  String userId, {
  double dx = 120,
  double dy = 45,
  double zoom = 2,
}) =>
    <String, dynamic>{
      'kind': 'viewport',
      'pageId': 'remote-b-page-1',
      'offset': <String, double>{'dx': dx, 'dy': dy},
      'zoom': zoom,
      'userId': userId,
    };

/// page 帧。
Map<String, dynamic> _pageFrame(String userId, String pageId) =>
    <String, dynamic>{'kind': 'page', 'pageId': pageId, 'userId': userId};

/// 启动协同会话（跟随前置：engine + boardId 就绪）。
Future<void> _startSession(_Harness h) async {
  final bool ok = await h.service.start(boardId: 'room-1');
  expect(ok, isTrue);
}

void main() {
  late _Harness h;

  setUp(() {
    h = _Harness();
    addTearDown(h.follow.dispose);
    addTearDown(h.pages.dispose);
    addTearDown(h.canvas.dispose);
    addTearDown(h.service.dispose);
  });

  // ---- 启动 / 停止 ---------------------------------------------------------

  group('WbFollowController 启动 / 停止', () {
    test('startFollow：发 follow 帧 + 状态通知', () async {
      await _startSession(h);
      int notified = 0;
      h.follow.addListener(() => notified++);

      h.follow.startFollow('u2');

      expect(h.follow.isFollowing, isTrue);
      expect(h.follow.followingUserId, 'u2');
      expect(notified, 1);
      expect(h.engine.interactiveCalls.single, <String, dynamic>{
        'action': 'follow',
        'targetUserId': 'u2',
      });
    });

    test('startFollow 幂等：同目标重复调用不发新帧 / 不重复通知', () async {
      await _startSession(h);
      h.follow.startFollow('u2');
      int notified = 0;
      h.follow.addListener(() => notified++);

      h.follow.startFollow('u2');

      expect(h.engine.interactiveCalls.length, 1);
      expect(notified, 0);
    });

    test('startFollow 空 userId：忽略', () async {
      await _startSession(h);

      h.follow.startFollow('');

      expect(h.follow.isFollowing, isFalse);
      expect(h.engine.interactiveCalls, isEmpty);
    });

    test('startFollow 切换目标：先 unfollow 旧再 follow 新', () async {
      await _startSession(h);
      h.follow.startFollow('u2');

      h.follow.startFollow('u3');

      expect(h.follow.followingUserId, 'u3');
      expect(h.engine.interactiveCalls, <Map<String, dynamic>>[
        <String, dynamic>{'action': 'follow', 'targetUserId': 'u2'},
        <String, dynamic>{'action': 'unfollow', 'targetUserId': 'u2'},
        <String, dynamic>{'action': 'follow', 'targetUserId': 'u3'},
      ]);
    });

    test('stopFollow：发 unfollow + 清状态', () async {
      await _startSession(h);
      h.follow.startFollow('u2');

      h.follow.stopFollow();

      expect(h.follow.isFollowing, isFalse);
      expect(h.follow.followingUserId, isEmpty);
      expect(h.engine.interactiveCalls.last, <String, dynamic>{
        'action': 'unfollow',
        'targetUserId': 'u2',
      });
    });

    test('stopFollow 幂等：未跟随时不发帧', () async {
      await _startSession(h);

      h.follow.stopFollow();
      h.follow.stopFollow();

      expect(h.engine.interactiveCalls, isEmpty);
    });
  });

  // ---- 打断（用户手势 / 切页） ---------------------------------------------

  group('WbFollowController 打断', () {
    test('用户视口手势：跟随中 → 停止（发 unfollow）', () async {
      await _startSession(h);
      h.follow.startFollow('u2');

      h.follow.handleUserViewportGesture();

      expect(h.follow.isFollowing, isFalse);
      expect(h.engine.interactiveCalls.last, <String, dynamic>{
        'action': 'unfollow',
        'targetUserId': 'u2',
      });
    });

    test('用户视口手势：未跟随 → 无操作', () async {
      await _startSession(h);

      h.follow.handleUserViewportGesture();

      expect(h.engine.interactiveCalls, isEmpty);
    });

    test('用户本地切页 → 打断跟随', () async {
      await _startSession(h);
      h.follow.startFollow('u2');

      h.follow.handleLocalPageChanged('local-b-page-3');

      expect(h.follow.isFollowing, isFalse);
      expect(h.engine.interactiveCalls.last['action'], 'unfollow');
    });

    test('跟随驱动切页（expected 消费）→ 不打断；再次用户切页 → 打断',
        () async {
      await _startSession(h);
      h.follow.startFollow('u2');
      h.follow.handlePreviews(<Map<String, dynamic>>[
        _pageFrame('u2', 'remote-b-page-3'),
      ]);
      expect(h.pages.currentPageId, 'local-b-page-3');

      // 模拟 canvas.setPage 汇聚点回调（应用层接线）：
      h.follow.handleLocalPageChanged('local-b-page-3');
      expect(h.follow.isFollowing, isTrue); // 程序化切页：标记消费，不打断。

      // 用户再次主动切页（非预期页）→ 打断。
      h.follow.handleLocalPageChanged('local-b-page-5');
      expect(h.follow.isFollowing, isFalse);
    });
  });

  // ---- 帧消费（viewport / page） -------------------------------------------

  group('WbFollowController 帧消费', () {
    test('viewport 帧：applyRemoteViewport 生效（offset + scale）', () async {
      await _startSession(h);
      h.follow.startFollow('u2');

      h.follow.handlePreviews(<Map<String, dynamic>>[_viewportFrame('u2')]);

      expect(h.canvas.offset, const Offset(120, 45));
      expect(h.canvas.scale, 2.0);
      expect(h.follow.isFollowing, isTrue); // 跟随帧不打断。
    });

    test('viewport 帧：程序化应用不触发出口 / 手势回调（防回环）', () async {
      await _startSession(h);
      h.follow.startFollow('u2');
      final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
      int gestures = 0;
      h.canvas.onViewportChanged = frames.add;
      h.canvas.onUserViewportGesture = () => gestures++;

      h.follow.handlePreviews(<Map<String, dynamic>>[_viewportFrame('u2')]);

      expect(frames, isEmpty);
      expect(gestures, 0);
    });

    test('只消费被跟随者的帧（他人帧 / 未知 kind 忽略）', () async {
      await _startSession(h);
      h.follow.startFollow('u2');

      h.follow.handlePreviews(<Map<String, dynamic>>[
        _viewportFrame('u9'), // 他人帧。
        <String, dynamic>{'kind': 'unknown', 'userId': 'u2'},
        <String, dynamic>{'kind': 'cursor', 'userId': 'u2', 'x': 1, 'y': 2},
      ]);

      expect(h.canvas.offset, Offset.zero);
      expect(h.canvas.scale, 1.0);
    });

    test('viewport 坏载荷（缺字段 / 类型错）忽略', () async {
      await _startSession(h);
      h.follow.startFollow('u2');

      h.follow.handlePreviews(<Map<String, dynamic>>[
        <String, dynamic>{'kind': 'viewport', 'userId': 'u2'},
        <String, dynamic>{
          'kind': 'viewport',
          'userId': 'u2',
          'offset': 'bad',
          'zoom': 2,
        },
        <String, dynamic>{
          'kind': 'viewport',
          'userId': 'u2',
          'offset': <String, dynamic>{'dx': 'x', 'dy': 0},
          'zoom': 2,
        },
        <String, dynamic>{
          'kind': 'viewport',
          'userId': 'u2',
          'offset': <String, dynamic>{'dx': 1, 'dy': 2},
        },
      ]);

      expect(h.canvas.offset, Offset.zero);
      expect(h.canvas.scale, 1.0);
    });

    test('未跟随：帧批次整体忽略', () async {
      await _startSession(h);

      h.follow.handlePreviews(<Map<String, dynamic>>[_viewportFrame('u2')]);

      expect(h.canvas.offset, Offset.zero);
      expect(h.canvas.scale, 1.0);
    });

    test('page 帧：切到本地同页序页面（跨端命名空间近似）', () async {
      await _startSession(h);
      h.follow.startFollow('u2');

      h.follow.handlePreviews(<Map<String, dynamic>>[
        _pageFrame('u2', 'remote-b-page-3'),
      ]);

      expect(h.pages.currentPageId, 'local-b-page-3');
      expect(h.follow.isFollowing, isTrue);
    });

    test('page 帧：本地无同页序 → 忽略切页 + 不打断 + 视口继续同步',
        () async {
      await _startSession(h);
      h.follow.startFollow('u2');

      h.follow.handlePreviews(<Map<String, dynamic>>[
        _pageFrame('u2', 'remote-b-page-9'), // 本地无页序 9。
      ]);
      expect(h.pages.currentPageId, 'local-b-page-1'); // 未变。
      expect(h.follow.isFollowing, isTrue);

      h.follow.handlePreviews(<Map<String, dynamic>>[_viewportFrame('u2')]);
      expect(h.canvas.scale, 2.0); // 视口继续同步。
    });

    test('page 帧：无页序后缀 / 空 pageId / 非字符串 → 保守忽略', () async {
      await _startSession(h);
      h.follow.startFollow('u2');

      h.follow.handlePreviews(<Map<String, dynamic>>[
        _pageFrame('u2', 'remote-b'), // 无 -page-N 后缀。
        _pageFrame('u2', ''),
        <String, dynamic>{'kind': 'page', 'pageId': 42, 'userId': 'u2'},
        <String, dynamic>{'kind': 'page', 'userId': 'u2'},
      ]);

      expect(h.pages.currentPageId, 'local-b-page-1');
      expect(h.follow.isFollowing, isTrue);
    });

    test('page 帧：已在同页序页面 → 零动作（不重复切页）', () async {
      await _startSession(h);
      h.follow.startFollow('u2');
      h.follow.handlePreviews(<Map<String, dynamic>>[
        _pageFrame('u2', 'remote-b-page-1'), // 页序 1 = 当前页。
      ]);

      expect(h.pages.currentPageId, 'local-b-page-1');
      expect(h.follow.isFollowing, isTrue);
    });

    test('同批多帧：先切页后视口，按序生效', () async {
      await _startSession(h);
      h.follow.startFollow('u2');

      h.follow.handlePreviews(<Map<String, dynamic>>[
        _pageFrame('u2', 'remote-b-page-5'),
        _viewportFrame('u2', dx: -30, dy: 8, zoom: 1.5),
      ]);

      expect(h.pages.currentPageId, 'local-b-page-5');
      expect(h.canvas.offset, const Offset(-30, 8));
      expect(h.canvas.scale, 1.5);
    });

    test('完整回路：page 帧 → 本地切页 → setPage 汇聚点回调 → 不打断',
        () async {
      await _startSession(h);
      h.follow.startFollow('u2');
      h.canvas.onPagePreview = (Map<String, dynamic> frame) =>
          h.follow.handleLocalPageChanged('${frame['pageId']}');

      h.follow.handlePreviews(<Map<String, dynamic>>[
        _pageFrame('u2', 'remote-b-page-3'),
      ]);
      // 模拟 CanvasView 响应页面状态变化：
      h.canvas.setPage('local-b-page-3');

      expect(h.follow.isFollowing, isTrue);
      expect(h.pages.currentPageId, 'local-b-page-3');
    });
  });

  // ---- syncWithRoom（目标离开 / 移除 / 断连 / 自动跟随） --------------------

  group('WbFollowController syncWithRoom', () {
    test('目标离开（名单非空且无 target）→ 自动停止', () async {
      await _startSession(h);
      h.follow.startFollow('u2');
      h.engine.room = _room(participants: <dynamic>['u3']);
      h.timers.fire();

      h.follow.syncWithRoom();

      expect(h.follow.isFollowing, isFalse);
      expect(h.engine.interactiveCalls.last, <String, dynamic>{
        'action': 'unfollow',
        'targetUserId': 'u2',
      });
    });

    test('目标离开后：不立即重新自动跟随（抑制该目标）', () async {
      await _startSession(h);
      h.engine.room = _room(
        mode: 'present',
        selfRole: roleParticipant,
        presenterId: 'u2',
        selfUserId: 'u-self',
      );
      h.timers.fire();
      h.follow.syncWithRoom(); // present 自动跟随 u2。
      expect(h.follow.followingUserId, 'u2');

      h.engine.room = _room(
        mode: 'present',
        selfRole: roleParticipant,
        presenterId: 'u2',
        selfUserId: 'u-self',
        participants: <dynamic>['u3'], // u2 离开。
      );
      h.timers.fire();
      h.follow.syncWithRoom();
      expect(h.follow.isFollowing, isFalse);

      h.follow.syncWithRoom(); // 再次同步：不重新自动跟随。
      expect(h.follow.isFollowing, isFalse);
    });

    test('目标仍在名单 → 保持跟随', () async {
      await _startSession(h);
      h.follow.startFollow('u2');
      h.engine.room = _room(participants: <dynamic>['u2', 'u3']);
      h.timers.fire();
      final int calls = h.engine.interactiveCalls.length;

      h.follow.syncWithRoom();

      expect(h.follow.isFollowing, isTrue);
      expect(h.engine.interactiveCalls.length, calls); // 无新帧。
    });

    test('名单为空 → 保守等待（不误停）', () async {
      await _startSession(h);
      h.follow.startFollow('u2');
      h.engine.room = _room();
      h.timers.fire();

      h.follow.syncWithRoom();

      expect(h.follow.isFollowing, isTrue);
    });

    test('本端被移出房间 → 停止跟随（发 unfollow）', () async {
      await _startSession(h);
      h.follow.startFollow('u2');
      h.engine.nextRemoved = <String, dynamic>{'reason': 'kicked'};
      h.timers.fire();
      expect(h.service.isRemoved, isTrue);

      h.follow.syncWithRoom();

      expect(h.follow.isFollowing, isFalse);
      expect(h.engine.interactiveCalls.last['action'], 'unfollow');
    });

    test('连接断开 → 静默停止（不发 unfollow）+ 重连后重新自动跟随', () async {
      await _startSession(h);
      h.engine.room = _room(
        mode: 'present',
        selfRole: roleParticipant,
        presenterId: 'u2',
        selfUserId: 'u-self',
      );
      h.timers.fire();
      h.follow.syncWithRoom();
      expect(h.follow.followingUserId, 'u2');
      final int calls = h.engine.interactiveCalls.length;

      // 断连（离线）。
      h.engine.connected = false;
      h.engine.transportState = 'disconnected';
      h.timers.fire();
      expect(h.service.isOnline, isFalse);

      h.follow.syncWithRoom();
      expect(h.follow.isFollowing, isFalse);
      expect(h.engine.interactiveCalls.length, calls); // 静默：无 unfollow。

      // 重连：present 会话未变化 → 重新自动跟随。
      h.engine.connected = true;
      h.engine.transportState = 'connected';
      h.timers.fire();
      h.follow.syncWithRoom();
      expect(h.follow.followingUserId, 'u2');
      expect(h.engine.interactiveCalls.length, calls + 1);
    });
  });

  // ---- present 自动跟随 ----------------------------------------------------

  group('WbFollowController present 自动跟随', () {
    /// 设置 present 快照并同步。
    void enterPresent(_Harness h, String presenterId) {
      h.engine.room = _room(
        mode: 'present',
        selfRole: roleParticipant,
        presenterId: presenterId,
        selfUserId: 'u-self',
      );
      h.timers.fire();
      h.follow.syncWithRoom();
    }

    test('mode=present 且演示者非本端 → 自动 startFollow', () async {
      await _startSession(h);

      enterPresent(h, 'u2');

      expect(h.follow.followingUserId, 'u2');
      expect(h.engine.interactiveCalls.single, <String, dynamic>{
        'action': 'follow',
        'targetUserId': 'u2',
      });
    });

    test('本端即演示者 → 不自动跟随', () async {
      await _startSession(h);

      enterPresent(h, 'u-self');

      expect(h.follow.isFollowing, isFalse);
      expect(h.engine.interactiveCalls, isEmpty);
    });

    test('无演示者 / 非 present → 不自动跟随', () async {
      await _startSession(h);

      h.engine.room = _room(
        mode: 'present',
        selfRole: roleParticipant,
        presenterId: '',
        selfUserId: 'u-self',
      );
      h.timers.fire();
      h.follow.syncWithRoom();
      expect(h.follow.isFollowing, isFalse);

      h.engine.room = _room(
        mode: 'free',
        selfRole: roleParticipant,
        presenterId: 'u2',
        selfUserId: 'u-self',
      );
      h.timers.fire();
      h.follow.syncWithRoom();
      expect(h.follow.isFollowing, isFalse);
    });

    test('手动停止后同一演示者不重复自动触发', () async {
      await _startSession(h);
      enterPresent(h, 'u2');
      expect(h.follow.followingUserId, 'u2');

      h.follow.stopFollow(); // 手动停止（抑制 u2）。
      h.follow.syncWithRoom();
      expect(h.follow.isFollowing, isFalse); // 不重复自动跟随。

      h.follow.syncWithRoom();
      expect(h.follow.isFollowing, isFalse);
    });

    test('演示者变更 → 恢复自动跟随（抑制仅针对旧演示者）', () async {
      await _startSession(h);
      enterPresent(h, 'u2');
      h.follow.stopFollow();

      enterPresent(h, 'u3'); // 演示者换人。

      expect(h.follow.followingUserId, 'u3');
    });

    test('present 结束 → 解除抑制；重新开始演示恢复自动跟随', () async {
      await _startSession(h);
      enterPresent(h, 'u2');
      h.follow.stopFollow();

      // present 结束：清抑制。
      h.engine.room = _room(
        mode: 'free',
        selfRole: roleParticipant,
        selfUserId: 'u-self',
      );
      h.timers.fire();
      h.follow.syncWithRoom();
      expect(h.follow.isFollowing, isFalse);

      // 重新 present 同一演示者 → 恢复自动跟随。
      enterPresent(h, 'u2');
      expect(h.follow.followingUserId, 'u2');
    });

    test('已在手动跟随其他目标 → 不抢占', () async {
      await _startSession(h);
      h.follow.startFollow('u5');

      enterPresent(h, 'u2');

      expect(h.follow.followingUserId, 'u5');
      expect(h.engine.interactiveCalls.length, 1); // 仅初始 follow u5。
    });
  });
}
