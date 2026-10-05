/// T1.7 桌面协作 UI 组件测试：状态 chip 五态映射与悬停提示 /
/// 参与者面板列表与空态 / 参与者入口徽标与开合 / 互动白板入口按钮与
/// 加入 / 房间对话框（默认本地 → 按需入房；M2 重连预算耗尽恢复入口；
/// fake 引擎 + Provider 注入，不依赖 DLL 与网络）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';
import 'package:whiteboard_desktop/widgets/collab/collab_dialogs.dart';
import 'package:whiteboard_desktop/widgets/collab/collab_entry_button.dart';
import 'package:whiteboard_desktop/widgets/collab/participants_button.dart';
import 'package:whiteboard_desktop/widgets/collab/participants_panel.dart';
import 'package:whiteboard_desktop/widgets/collab/sync_status_chip.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import 'support/fake_collab_engine.dart';

/// 服务 + fake 引擎 + 手动轮询定时器装配。
class _Harness {
  _Harness() {
    service = WbCollabService(
      engine: engine,
      sleep: (Duration _) async {},
      pollTimerFactory: timers.create,
      actorGenerator: () => 'wb-test-actor',
    );
  }

  final FakeCollabEngine engine = FakeCollabEngine();
  final FakePollTimerFactory timers = FakePollTimerFactory();
  late final WbCollabService service;
}

/// 挂载单个组件（Provider 注入服务；普通 MaterialApp 走主题回退）。
Future<void> _pump(
  WidgetTester tester,
  WbCollabService service,
  Widget child,
) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<WbCollabService>.value(
      value: service,
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pump();
}

/// 挂载「入口按钮 + endDrawer 面板」宿主（贴近编辑页接线形态）。
Future<void> _pumpPanelHost(WidgetTester tester, WbCollabService service) async {
  final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();
  await tester.pumpWidget(
    ChangeNotifierProvider<WbCollabService>.value(
      value: service,
      child: MaterialApp(
        home: Scaffold(
          key: scaffoldKey,
          endDrawer: const WbParticipantsPanel(),
          body: Center(
            child: WbParticipantsButton(
              onPressed: () => scaffoldKey.currentState?.openEndDrawer(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 读取 chip 悬停提示文本。
String _chipTooltip(WidgetTester tester) => tester
    .widget<Tooltip>(find.byKey(const Key('wb-sync-status-chip')))
    .message!;

void main() {
  // ---- 状态 chip（五态映射） ---------------------------------------------

  group('WbSyncStatusChip', () {
    testWidgets('offline：灰色「离线」+ 单机端点提示', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await _pump(tester, h.service, const WbSyncStatusChip());

      expect(find.byKey(const Key('wb-sync-status-chip')), findsOneWidget);
      expect(find.text('离线'), findsOneWidget);
      expect(
        _chipTooltip(tester),
        '协作服务未连接（单机模式）：${WbCollabService.defaultEndpoint}',
      );
    });

    testWidgets('connecting：连接中；传输重连时提示次数', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await _pump(tester, h.service, const WbSyncStatusChip());
      await h.service.start(boardId: 'b1');

      h.engine.connected = false;
      h.engine.transportState = 'connecting';
      h.timers.fire();
      await tester.pump();

      expect(find.text('连接中'), findsOneWidget);
      expect(
        _chipTooltip(tester),
        '正在连接协作服务…（${WbCollabService.defaultEndpoint}）',
      );

      // 传输重连：reconnectCount 进入提示。
      h.engine.transportState = 'reconnecting';
      h.engine.reconnectCount = 2;
      h.timers.fire();
      await tester.pump();

      expect(find.text('连接中'), findsOneWidget);
      expect(_chipTooltip(tester), '连接中断，正在重连（第 2 次）…');
    });

    testWidgets('online：已连接 + 人数 / 延迟提示', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await _pump(tester, h.service, const WbSyncStatusChip());
      await h.service.start(boardId: 'b1');

      h.engine.room = const WbSyncRoomData(participants: <dynamic>[
        <String, dynamic>{'userId': 'peer-01'},
        <String, dynamic>{'userId': 'me-02'},
      ]);
      h.engine.latencyMs = 42;
      h.timers.fire();
      await tester.pump();

      expect(find.text('已连接'), findsOneWidget);
      expect(_chipTooltip(tester), '协作服务已连接 · 2 人在线 · 延迟 42ms');
    });

    testWidgets('syncing：同步中 + 待确认提示', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await _pump(tester, h.service, const WbSyncStatusChip());
      await h.service.start(boardId: 'b1');

      h.engine.pendingCount = 3;
      h.engine.latencyMs = 12;
      h.timers.fire();
      await tester.pump();

      expect(find.text('同步中'), findsOneWidget);
      expect(_chipTooltip(tester), '正在同步增量 · 3 条待确认 · 延迟 12ms');
    });

    testWidgets('error：传输 failed → 回退文案', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await _pump(tester, h.service, const WbSyncStatusChip());
      await h.service.start(boardId: 'b1');

      h.engine.connected = false;
      h.engine.transportState = 'failed';
      h.timers.fire();
      await tester.pump();

      expect(find.text('同步错误'), findsOneWidget);
      expect(_chipTooltip(tester), '同步错误（详见协作设置）');
    });

    testWidgets('error：外部上报 → 带错误详情', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await _pump(tester, h.service, const WbSyncStatusChip());

      h.service.reportError('传输失败：连接被重置');
      await tester.pump();

      expect(find.text('同步错误'), findsOneWidget);
      expect(_chipTooltip(tester), '同步错误：传输失败：连接被重置');
    });
  });

  // ---- 参与者面板 ---------------------------------------------------------

  group('WbParticipantsPanel', () {
    testWidgets('offline 空态：单机状态行 + 空态引导', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await _pump(tester, h.service, const WbParticipantsPanel());

      expect(find.byKey(const Key('wb-participants-panel')), findsOneWidget);
      expect(find.text('参与者'), findsOneWidget);
      expect(find.text('(0)'), findsOneWidget);
      expect(find.textContaining('未连接到协作服务（单机模式）'), findsOneWidget);
      expect(find.text('暂无其他参与者'), findsOneWidget);
    });

    testWidgets('列表：「我」标记 / 角色 / 计数 / 状态行', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await _pump(tester, h.service, const WbParticipantsPanel());
      await h.service.start(boardId: 'b1');

      h.engine.room = const WbSyncRoomData(participants: <dynamic>[
        <String, dynamic>{'userId': 'peer-01', 'role': 'Host'},
        <String, dynamic>{'userId': 'me-02', 'role': 'Participant'},
      ]);
      h.timers.fire();
      await tester.pump();

      expect(find.text('(2)'), findsOneWidget);
      expect(find.text('peer-01'), findsOneWidget);
      expect(find.text('主持人'), findsOneWidget);
      expect(find.text('me-02（我）'), findsOneWidget); // 末位 = 本人（M1）
      expect(find.textContaining('已连接 · 2 人在线'), findsOneWidget);
    });

    testWidgets('防御解析：字符串载荷 / 未知角色 / 缺 id 忽略', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await _pump(tester, h.service, const WbParticipantsPanel());
      await h.service.start(boardId: 'b1');

      h.engine.room = const WbSyncRoomData(participants: <dynamic>[
        'raw-peer',
        <String, dynamic>{'userId': 'v1', 'role': 'Visitor'},
        <String, dynamic>{'role': 'Host'}, // 缺 id：忽略
        <String, dynamic>{'userId': 'me-raw', 'role': 'Participant'},
      ]);
      h.timers.fire();
      await tester.pump();

      expect(find.text('(3)'), findsOneWidget);
      expect(find.text('raw-peer'), findsOneWidget);
      expect(find.text('成员'), findsOneWidget); // 空角色回退
      expect(find.text('Visitor'), findsOneWidget); // 未知角色原样
      expect(find.text('me-raw（我）'), findsOneWidget);
    });
  });

  // ---- 参与者入口按钮 -----------------------------------------------------

  group('WbParticipantsButton', () {
    testWidgets('0 人无徽标；>0 显数字；>9 封顶 9+；点击回调', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      int taps = 0;
      await _pump(
        tester,
        h.service,
        WbParticipantsButton(onPressed: () => taps++),
      );

      expect(find.byKey(const Key('wb-participants-button')), findsOneWidget);
      expect(find.byType(WbBadge), findsNothing); // 无参与者：无计数徽标

      await h.service.start(boardId: 'b1');
      h.engine.room = const WbSyncRoomData(participants: <dynamic>[
        <String, dynamic>{'userId': 'p1'},
        <String, dynamic>{'userId': 'me'},
      ]);
      h.timers.fire();
      await tester.pump();
      expect(find.text('2'), findsOneWidget);

      // 超上限封顶：12 → 9+。
      h.engine.room = WbSyncRoomData(
        participants: List<dynamic>.generate(
          12,
          (int i) => <String, dynamic>{'userId': 'u$i'},
        ),
      );
      h.timers.fire();
      await tester.pump();
      expect(find.text('9+'), findsOneWidget);

      await tester.tap(find.byKey(const Key('wb-participants-button')));
      expect(taps, 1);
    });

    testWidgets('宿主集成：点击打开面板 / 「关闭」收起', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await _pumpPanelHost(tester, h.service);
      await h.service.start(boardId: 'b1');
      h.engine.room = const WbSyncRoomData(participants: <dynamic>[
        <String, dynamic>{'userId': 'peer-01', 'role': 'Host'},
        <String, dynamic>{'userId': 'me-02'},
      ]);
      h.timers.fire();
      await tester.pump();

      await tester.tap(find.byKey(const Key('wb-participants-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wb-participants-panel')), findsOneWidget);
      expect(find.text('peer-01'), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byKey(const Key('wb-participants-panel')),
        matching: find.byTooltip('关闭'),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wb-participants-panel')), findsNothing);
    });
  });

  // ---- 互动白板入口按钮（默认本地 → 按需入房） -----------------------------

  group('WbCollabEntryButton', () {
    testWidgets('offline：显示「互动白板」文字按钮；点击回调', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      int taps = 0;
      await _pump(
        tester,
        h.service,
        WbCollabEntryButton(onPressed: () => taps++),
      );

      expect(find.byKey(const Key('wb-collab-entry')), findsOneWidget);
      expect(find.text('互动白板'), findsOneWidget);
      expect(find.byKey(const Key('wb-sync-status-chip')), findsNothing);

      await tester.tap(find.byKey(const Key('wb-collab-entry')));
      expect(taps, 1);
    });

    testWidgets('非 offline：状态 chip 即入口；点击回调', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      int taps = 0;
      await _pump(
        tester,
        h.service,
        WbCollabEntryButton(onPressed: () => taps++),
      );
      await h.service.start(boardId: 'b1');
      await tester.pump();

      expect(find.byKey(const Key('wb-sync-status-chip')), findsOneWidget);
      expect(find.text('互动白板'), findsNothing);

      await tester.tap(find.byKey(const Key('wb-collab-entry')));
      expect(taps, 1);
    });
  });

  // ---- 互动白板对话框（加入房间 / 房间信息） -------------------------------

  group('互动白板对话框', () {
    testWidgets('加入：空输入禁用确认；确认返回 trim 后房间号', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      String? joined;
      await _pump(
        tester,
        h.service,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              joined = await showWbCollabJoinDialog(
                context,
                serverHint: WbCollabService.defaultEndpoint,
              );
            },
            child: const Text('open-join'),
          ),
        ),
      );

      await tester.tap(find.text('open-join'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('wb-collab-join-dialog')),
        findsOneWidget,
      );
      expect(
        find.textContaining('服务器地址：${WbCollabService.defaultEndpoint}'),
        findsOneWidget,
      );
      final FilledButton confirm = tester.widget<FilledButton>(
        find.byKey(const ValueKey<String>('wb-collab-join-confirm')),
      );
      expect(confirm.onPressed, isNull); // 空输入：确认禁用

      await tester.enterText(
        find.byKey(const ValueKey<String>('wb-collab-room-field')),
        '  room-a  ',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('wb-collab-join-confirm')),
      );
      await tester.pumpAndSettle();

      expect(joined, 'room-a'); // trim 后返回
      expect(
        find.byKey(const ValueKey<String>('wb-collab-join-dialog')),
        findsNothing,
      );
    });

    testWidgets('加入：取消返回 null', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      String? joined = 'sentinel';
      await _pump(
        tester,
        h.service,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              joined = await showWbCollabJoinDialog(context, serverHint: '');
            },
            child: const Text('open-join'),
          ),
        ),
      );

      await tester.tap(find.text('open-join'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('wb-collab-join-cancel')),
      );
      await tester.pumpAndSettle();

      expect(joined, isNull);
    });

    testWidgets('房间信息：房间 / 服务器 / 状态与人数；退出返回 true',
        (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.start(boardId: 'room-x');
      h.engine.room = const WbSyncRoomData(participants: <dynamic>[
        <String, dynamic>{'userId': 'peer-01'},
        <String, dynamic>{'userId': 'me-02'},
      ]);
      h.timers.fire();

      bool? left = false;
      await _pump(
        tester,
        h.service,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              left = await showWbCollabRoomDialog(context);
            },
            child: const Text('open-room'),
          ),
        ),
      );

      await tester.tap(find.text('open-room'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('wb-collab-room-dialog')),
        findsOneWidget,
      );
      expect(find.text('room-x'), findsOneWidget);
      expect(find.textContaining('2 人在线'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('wb-collab-room-leave')),
      );
      await tester.pumpAndSettle();

      expect(left, isTrue);
    });

    testWidgets('房间信息：关闭返回 null', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.start(boardId: 'room-x');

      bool? left = true;
      await _pump(
        tester,
        h.service,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              left = await showWbCollabRoomDialog(context);
            },
            child: const Text('open-room'),
          ),
        ),
      );

      await tester.tap(find.text('open-room'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('wb-collab-room-close')),
      );
      await tester.pumpAndSettle();

      expect(left, isNull);
    });

    testWidgets('房间信息：重连预算耗尽 → 失败提示 + 「重新连接」恢复入口（M2）',
        (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.start(boardId: 'room-x');
      h.engine.connected = false;
      h.engine.transportState = 'failed';
      h.engine.reconnectCount = WbCollabService.reconnectBudget;
      h.timers.fire();

      await _pump(
        tester,
        h.service,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              await showWbCollabRoomDialog(context);
            },
            child: const Text('open-room'),
          ),
        ),
      );
      await tester.tap(find.text('open-room'));
      await tester.pumpAndSettle();

      expect(find.textContaining('已重连 5 次'), findsOneWidget);
      final OutlinedButton reconnect = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey<String>('wb-collab-room-reconnect')),
      );
      expect(reconnect.onPressed, isNotNull);

      // 点击重连：stop + 同房 start（重新入房）并轻提示成功。
      await tester.tap(
        find.byKey(const ValueKey<String>('wb-collab-room-reconnect')),
      );
      await tester.pumpAndSettle();

      expect(h.engine.joinedBoards, <String>['room-x', 'room-x']);
      expect(h.engine.connected, isTrue);
      expect(find.text('已重新连接互动白板'), findsOneWidget);

      // 等轻提示自然消退，避免测试结束残留计时器。
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
