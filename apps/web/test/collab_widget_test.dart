/// W1 协作 UI widget 测试（T1.8）+ M3 互动 widget 测试（T3.4）：
/// 默认本地入口 / 加入与房间对话框 / 状态 chip / 参与者面板 / 响应式接线 /
/// 举手 / 演示模式 / room:removed。
///
/// 覆盖：
/// - 编辑页默认（VM 降级）：本地模式 —— 入口文字按钮、chip 隐藏、面板
///   单机文案、输入房间号加入失败轻提示；
/// - 加入对话框：空输入禁用「加入」、取消无副作用（不建桥）；
/// - 注入假桥后：经入口输入房间号加入 → 已连接 chip、参与者徽标、面板列表
///   （「我」标记 / 角色）；
/// - 已在房：入口开房间信息对话框（房间号 / 服务器 / 状态）→ 退出回到本地；
/// - 断线重连：chip「重连中」、列表保留（防闪烁）、恢复「已连接」；
/// - 窄屏 600：协作入口无布局溢出；
/// - M3：举手按钮（Viewer 显示 / Guest·Host 隐藏 / 举手·收手 / 失败轻提示）；
/// - M3：参与者面板标记（举手 / Host 徽标 / 可编辑）与授权 / 收回操作；
/// - M3：演示模式入口（CoHost+）与「演示中」chip（广播路径）；
/// - M3：room:removed 只读横幅与编辑入口禁用；
/// - P3：选区浮层（插入元素自动选中 → `wb-context-toolbar-popup` 出现，
///   清空选区收起）；
/// - P4：入房装配远端在场层（`WbRemoteCursorsOverlay`），presence 帧驱动
///   不崩（光标 + 选区）；
/// - 列表页：无协作 UI；`idle` 态 chip 隐藏。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_canvas/canvas/canvas_controller.dart';
import 'package:whiteboard_canvas/canvas/canvas_tool_palette.dart';
import 'package:whiteboard_canvas/collab/remote_cursors.dart';
import 'package:whiteboard_web/app.dart';
import 'package:whiteboard_web/routes.dart';
import 'package:whiteboard_web/services/realtime_service.dart';
import 'package:whiteboard_web/services/wb_core_service.dart';
import 'package:whiteboard_web/state/theme_state.dart';
import 'package:whiteboard_web/widgets/collab/collab_status_chip.dart';
import 'package:whiteboard_web/widgets/context_toolbar_host.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

import 'support/fake_socketio_bridge.dart';

void main() {
  testWidgets('默认本地（VM 降级）：入口文字按钮 / chip 隐藏 / 加入失败提示',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      WhiteboardWebApp(
        router: createWebRouter(
            initialLocation: WbWebRoutes.boardPath('test-board')),
      ),
    );
    await tester.pumpAndSettle();

    // 默认本地：不自动连接 —— 状态 chip 隐藏，入口为「互动白板」文字按钮。
    expect(find.byKey(const Key('wb-collab-status-chip')), findsNothing);
    expect(find.byKey(const Key('wb-collab-entry')), findsOneWidget);
    expect(find.text('互动白板'), findsOneWidget);
    expect(find.byKey(const Key('wb-participants-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('wb-participants-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-participants-panel')), findsOneWidget);
    expect(find.text('暂无其他参与者'), findsOneWidget);
    // 未加入：面板状态行「协作服务未启用（单机模式）」。
    expect(find.textContaining('协作服务未启用'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    // 入口 → 加入对话框（VM 降级：脚本加载失败收敛为「加入失败」）。
    await tester.tap(find.byKey(const Key('wb-collab-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-collab-join-dialog')), findsOneWidget);

    await tester.enterText(
        find.byKey(const Key('wb-collab-room-field')), 'room-1');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wb-collab-join-confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('加入失败：'), findsOneWidget);
    // 失败后仍在本地：chip 不出现（boardId 未设置）。
    expect(find.byKey(const Key('wb-collab-status-chip')), findsNothing);

    // 等待 SnackBar 自动收起（避免残留定时器）。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await _unmount(tester);
  });

  testWidgets('已连接：chip / 参与者徽标 / 面板列表（含「我」与角色）', (WidgetTester tester) async {
    final _FakeHarness harness = _FakeHarness();
    await _pumpEditPage(tester, harness.service);
    expect(harness.service.status, WbRealtimeStatus.idle);

    // 默认本地：经入口输入房间号加入（两端同房间号即同步）。
    await _joinRoom(tester, 'demo-room');
    expect(harness.service.status, WbRealtimeStatus.connecting);

    final FakeSocketIoBridge bridge = harness.bridges.single;
    bridge.fireConnected(socketId: 'sock-1');
    await tester.pumpAndSettle();

    expect(harness.service.status, WbRealtimeStatus.connected);
    expect(find.text('已连接'), findsOneWidget);
    // 已加入的房间号：连接建立后自动补发 `board:join`。
    final FakeAckCall joinCall = bridge.ackCalls.single;
    expect(joinCall.event, 'board:join');
    // P4：join 携带本地水位（无提供者 / 新会话 = 空对象新成员语义）。
    expect(joinCall.payload, <String, Object?>{
      'boardId': 'demo-room',
      'lastSeenVersion': <String, Object?>{},
    });

    bridge.fireEvent('board:session', <String, Object?>{
      'userId': 'me-01',
      'authMode': 'anonymous',
      'role': 'Host',
    });
    bridge.fireEvent('board:joined', <String, Object?>{
      'boardId': 'demo-room',
      'role': 'Host',
      'mode': 'free',
      'participants': <Object?>[
        _participant('me-01', 'sock-1', 'Host'),
        _participant('peer-02', 'sock-2', 'Participant'),
      ],
    });
    await tester.pumpAndSettle();

    // 在线人数徽标（WbBadge.count）。
    expect(
      find.descendant(
        of: find.byKey(const Key('wb-participants-button')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('wb-participants-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-participants-panel')), findsOneWidget);
    expect(find.text('me-01（我）'), findsOneWidget);
    expect(find.text('peer-02'), findsOneWidget);
    expect(find.text('主持人'), findsOneWidget);
    // 面板标题「参与者」+ peer 角色「参与者」。
    expect(find.text('参与者'), findsNWidgets(2));
    expect(find.textContaining('已连接 · 2 人在线'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('断线重连：chip 重连中 / 列表保留 / 恢复已连接', (WidgetTester tester) async {
    final _FakeHarness harness = _FakeHarness();
    await _pumpEditPage(tester, harness.service);
    await _joinRoom(tester, 'demo-room');
    final FakeSocketIoBridge bridge = harness.bridges.single;
    bridge.fireConnected(socketId: 'sock-1');
    bridge.fireEvent('board:session', <String, Object?>{
      'userId': 'me-01',
      'authMode': 'anonymous',
    });
    bridge.fireEvent('board:joined', <String, Object?>{
      'participants': <Object?>[
        _participant('me-01', 'sock-1', 'Participant'),
        _participant('peer-02', 'sock-2', 'Participant'),
      ],
    });
    await tester.pumpAndSettle();

    bridge.fireDisconnected('transport close');
    await tester.pumpAndSettle();
    expect(find.text('重连中'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wb-participants-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('网络中断，正在重连'), findsOneWidget);
    // 掉线期间参与者列表保留（§5.9 防闪烁）。
    expect(find.text('peer-02'), findsOneWidget);

    // 重连成功 → 恢复「已连接」（面板状态行同步更新）。
    bridge.fireConnected(socketId: 'sock-3');
    await tester.pumpAndSettle();
    expect(find.text('已连接'), findsOneWidget);
    expect(find.textContaining('已连接 · 2 人在线'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('窄屏 600：协作入口渲染无溢出', (WidgetTester tester) async {
    final _FakeHarness harness = _FakeHarness();
    await _pumpEditPage(tester, harness.service, size: const Size(600, 800));
    // 默认本地：先经入口加入（窄屏下对话框 / chip 均无溢出）。
    await _joinRoom(tester, 'demo-room');
    harness.bridges.single.fireConnected();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('wb-collab-status-chip')), findsOneWidget);
    expect(find.byKey(const Key('wb-participants-button')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _unmount(tester);
  });

  testWidgets('M3 举手按钮：Viewer 举手/收手；Guest·Host 隐藏',
      (WidgetTester tester) async {
    final _FakeHarness harness = _FakeHarness();
    await _pumpEditPage(tester, harness.service);
    await _joinRoom(tester, 'demo-room');
    final FakeSocketIoBridge bridge = harness.bridges.single;

    // 连接前（connecting）：不显示。
    expect(find.byKey(const Key('wb-raise-hand-button')), findsNothing);

    bridge.fireConnected(socketId: 'sock-1');
    bridge.fireEvent('board:session', <String, Object?>{
      'userId': 'me-01',
      'authMode': 'anonymous',
      'role': 'Viewer',
    });
    await tester.pumpAndSettle();

    // Viewer（≥Viewer 且 <CoHost）：显示「举手」。
    expect(find.byKey(const Key('wb-raise-hand-button')), findsOneWidget);
    expect(find.byTooltip('举手'), findsOneWidget);

    // 举手：发送 raiseHand，ack 成功本地置位 →「收手」。
    await tester.tap(find.byKey(const Key('wb-raise-hand-button')));
    await tester.pumpAndSettle();
    expect(bridge.ackCalls.last.event, 'interactive:raiseHand');
    expect(harness.service.selfHandRaised, isTrue);
    expect(find.byTooltip('收手'), findsOneWidget);

    // 收手：发送 lowerHand，复位 →「举手」。
    await tester.tap(find.byKey(const Key('wb-raise-hand-button')));
    await tester.pumpAndSettle();
    expect(bridge.ackCalls.last.event, 'interactive:lowerHand');
    expect(harness.service.selfHandRaised, isFalse);
    expect(find.byTooltip('举手'), findsOneWidget);

    // roleChanged：Guest（低于 Viewer）→ 隐藏；Participant → 显示；Host → 隐藏。
    bridge.fireEvent('interactive:roleChanged', <String, Object?>{
      'userId': 'me-01',
      'role': 'Guest',
      'grantedWrite': false,
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-raise-hand-button')), findsNothing);

    bridge.fireEvent('interactive:roleChanged', <String, Object?>{
      'userId': 'me-01',
      'role': 'Participant',
      'grantedWrite': false,
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-raise-hand-button')), findsOneWidget);

    bridge.fireEvent('interactive:roleChanged', <String, Object?>{
      'userId': 'me-01',
      'role': 'Host',
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-raise-hand-button')), findsNothing);

    await _unmount(tester);
  });

  testWidgets('M3 举手失败：ack 拒绝 → 轻提示且状态不变', (WidgetTester tester) async {
    final _FakeHarness harness = _FakeHarness();
    await _pumpEditPage(tester, harness.service);
    await _joinRoom(tester, 'demo-room');
    final FakeSocketIoBridge bridge = harness.bridges.single;
    bridge.fireConnected(socketId: 'sock-1');
    bridge.fireEvent('board:session', <String, Object?>{
      'userId': 'me-01',
      'authMode': 'anonymous',
      'role': 'Viewer',
    });
    await tester.pumpAndSettle();

    bridge.ackHandler =
        (String event, Object? payload) => Future<Object?>.value(
              <String, Object?>{
                'ok': false,
                'error': <String, Object?>{
                  'code': 'Forbidden',
                  'message': '服务端拒绝（测试）'
                },
              },
            );

    await tester.tap(find.byKey(const Key('wb-raise-hand-button')));
    await tester.pumpAndSettle();

    expect(harness.service.selfHandRaised, isFalse);
    expect(find.byTooltip('举手'), findsOneWidget);
    expect(find.textContaining('「举手」操作失败'), findsOneWidget);

    // 等待 SnackBar 自动收起（避免残留定时器）。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await _unmount(tester);
  });

  testWidgets('M3 参与者面板：举手标记 / 徽标 / 可编辑 / 授权与收回（授权不设举手前置）',
      (WidgetTester tester) async {
    final _FakeHarness harness = _FakeHarness();
    await _pumpEditPage(tester, harness.service, size: const Size(1400, 800));
    await _joinRoom(tester, 'demo-room');
    final FakeSocketIoBridge bridge = harness.bridges.single;
    bridge.fireConnected(socketId: 'sock-1');
    bridge.fireEvent('board:session', <String, Object?>{
      'userId': 'me-01',
      'authMode': 'anonymous',
      'role': 'Host',
    });
    bridge.fireEvent('board:joined', <String, Object?>{
      'boardId': 'test-board',
      'role': 'Host',
      'mode': 'free',
      'participants': <Object?>[
        _participant('me-01', 'sock-1', 'Host'),
        _participant('peer-02', 'sock-2', 'Participant', handRaised: true),
        _participant('peer-03', 'sock-3', 'CoHost'),
        _participant('peer-04', 'sock-4', 'Participant', grantedWrite: true),
        _participant('peer-05', 'sock-5', 'Participant'),
      ],
    });
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('wb-participants-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-participants-panel')), findsOneWidget);

    // 举手标记（peer-02）+ Host 徽标高亮（自己）。
    expect(find.byKey(const Key('wb-hand-raised-peer-02')), findsOneWidget);
    expect(find.byKey(const Key('wb-role-badge-me-01')), findsOneWidget);
    // M3.1：授权入口不设「先举手」前置——未举手（peer-05）与已举手（peer-02）
    // 均显示「授权控制」；CoHost / Host 目标无操作入口。
    expect(find.byKey(const Key('wb-grant-control-peer-02')), findsOneWidget);
    expect(find.byKey(const Key('wb-grant-control-peer-05')), findsOneWidget);
    expect(find.byKey(const Key('wb-grant-control-peer-03')), findsNothing);
    expect(find.byKey(const Key('wb-revoke-control-peer-03')), findsNothing);
    // 已授权 → 「可编辑」标记 + 「收回控制」。
    expect(find.byKey(const Key('wb-granted-write-peer-04')), findsOneWidget);
    expect(find.byKey(const Key('wb-revoke-control-peer-04')), findsOneWidget);
    expect(find.byKey(const Key('wb-grant-control-peer-04')), findsNothing);

    // 授权 peer-02：ack + 本地确定性更新（授权入口 → 收回入口切换）。
    await tester.tap(find.byKey(const Key('wb-grant-control-peer-02')));
    await tester.pumpAndSettle();
    expect(bridge.ackCalls.last.event, 'interactive:grantControl');
    expect(
        bridge.ackCalls.last.payload, <String, Object?>{'userId': 'peer-02'});
    expect(find.byKey(const Key('wb-granted-write-peer-02')), findsOneWidget);
    expect(find.byKey(const Key('wb-grant-control-peer-02')), findsNothing);
    expect(find.byKey(const Key('wb-revoke-control-peer-02')), findsOneWidget);

    // 收回 peer-02：ack + 标记移除。
    await tester.tap(find.byKey(const Key('wb-revoke-control-peer-02')));
    await tester.pumpAndSettle();
    expect(bridge.ackCalls.last.event, 'interactive:revokeControl');
    expect(
        bridge.ackCalls.last.payload, <String, Object?>{'userId': 'peer-02'});
    expect(find.byKey(const Key('wb-granted-write-peer-02')), findsNothing);

    await _unmount(tester);
  });

  testWidgets('M3 演示模式：Host 入口 start/stop 与「演示中」chip',
      (WidgetTester tester) async {
    final _FakeHarness harness = _FakeHarness();
    await _pumpEditPage(tester, harness.service, size: const Size(1400, 800));
    await _joinRoom(tester, 'demo-room');
    final FakeSocketIoBridge bridge = harness.bridges.single;
    bridge.fireConnected(socketId: 'sock-1');
    bridge.fireEvent('board:session', <String, Object?>{
      'userId': 'me-01',
      'authMode': 'anonymous',
      'role': 'Host',
    });
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('wb-present-button')), findsOneWidget);
    expect(find.byTooltip('开始演示'), findsOneWidget);
    expect(find.byKey(const Key('wb-present-mode-chip')), findsNothing);

    // 开始演示：ack 成功 → 本地置位 + chip。
    await tester.tap(find.byKey(const Key('wb-present-button')));
    await tester.pumpAndSettle();
    expect(bridge.ackCalls.last.event, 'interactive:startPresent');
    expect(harness.service.isPresenting, isTrue);
    expect(harness.service.presenterId, 'me-01');
    expect(find.byKey(const Key('wb-present-mode-chip')), findsOneWidget);
    expect(find.text('演示中'), findsOneWidget);
    expect(find.byTooltip('房间处于演示模式 · 演示者 me-01'), findsOneWidget);
    expect(find.byTooltip('结束演示'), findsOneWidget);

    // 结束演示：chip 隐藏。
    await tester.tap(find.byKey(const Key('wb-present-button')));
    await tester.pumpAndSettle();
    expect(bridge.ackCalls.last.event, 'interactive:stopPresent');
    expect(harness.service.isPresenting, isFalse);
    expect(find.byKey(const Key('wb-present-mode-chip')), findsNothing);
    expect(find.byTooltip('开始演示'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('M3 演示模式：Participant 无入口、仅经广播见 chip',
      (WidgetTester tester) async {
    final _FakeHarness harness = _FakeHarness();
    await _pumpEditPage(tester, harness.service, size: const Size(1400, 800));
    await _joinRoom(tester, 'demo-room');
    final FakeSocketIoBridge bridge = harness.bridges.single;
    bridge.fireConnected(socketId: 'sock-9');
    bridge.fireEvent('board:session', <String, Object?>{
      'userId': 'peer-09',
      'authMode': 'anonymous',
      'role': 'Participant',
    });
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('wb-present-button')), findsNothing);
    expect(find.byKey(const Key('wb-present-mode-chip')), findsNothing);

    // 他人发起演示：modeChanged 广播 → chip（含演示者提示）。
    bridge.fireEvent('interactive:modeChanged', <String, Object?>{
      'mode': 'present',
      'by': 'me-01',
      'presenterId': 'me-01',
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-present-mode-chip')), findsOneWidget);
    expect(find.byTooltip('房间处于演示模式 · 演示者 me-01'), findsOneWidget);

    // 结束演示：chip 隐藏。
    bridge.fireEvent('interactive:modeChanged', <String, Object?>{
      'mode': 'free',
      'by': 'me-01',
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-present-mode-chip')), findsNothing);

    await _unmount(tester);
  });

  testWidgets('M3 room:removed：只读横幅 + 编辑入口禁用 + 互动入口隐藏',
      (WidgetTester tester) async {
    final _FakeHarness harness = _FakeHarness();
    // 注入就绪假核心：挂载共享画布 + 顶部浮动工具面板（palette，
    // P3 宽屏工具栏形态），作为本地编辑入口的断言载体。
    final WbCoreService core = WbCoreService(loader: _ReadyLoader());
    addTearDown(core.dispose);
    await _pumpEditPage(
      tester,
      harness.service,
      size: const Size(1400, 800),
      coreService: core,
    );
    await _joinRoom(tester, 'demo-room');
    final FakeSocketIoBridge bridge = harness.bridges.single;
    bridge.fireConnected(socketId: 'sock-1');
    bridge.fireEvent('board:session', <String, Object?>{
      'userId': 'me-01',
      'authMode': 'anonymous',
      'role': 'Participant',
    });
    bridge.fireEvent('board:joined', <String, Object?>{
      'participants': <Object?>[_participant('me-01', 'sock-1', 'Participant')],
    });
    await tester.pumpAndSettle();

    // 移除前：无横幅、举手入口可见、画笔工具可用。
    expect(find.byKey(const Key('wb-removed-banner')), findsNothing);
    expect(find.byKey(const Key('wb-raise-hand-button')), findsOneWidget);
    expect(_paletteButton(tester, 'wb-canvas-tool-pen').enabled, isTrue);

    bridge.fireEvent('room:removed', <String, Object?>{
      'code': 'Removed',
      'message': '你已被主持人移出该白板',
      'reason': 'removed',
    });
    await tester.pumpAndSettle();

    // 只读横幅 + 互动入口隐藏 + 本地编辑禁用
    // （非导航工具 / 更多置灰，导航工具保留）。
    expect(find.byKey(const Key('wb-removed-banner')), findsOneWidget);
    expect(find.text('你已被移出该白板，当前为只读模式'), findsOneWidget);
    expect(find.byKey(const Key('wb-raise-hand-button')), findsNothing);
    expect(_paletteButton(tester, 'wb-canvas-tool-pen').enabled, isFalse);
    expect(_paletteButton(tester, 'wb-canvas-tool-select').enabled, isTrue);
    expect(_paletteButton(tester, 'wb-canvas-more').enabled, isFalse);

    await _unmount(tester);
  });

  testWidgets('加入对话框：空输入禁用「加入」；取消无副作用', (WidgetTester tester) async {
    final _FakeHarness harness = _FakeHarness();
    await _pumpEditPage(tester, harness.service);

    await tester.tap(find.byKey(const Key('wb-collab-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-collab-join-dialog')), findsOneWidget);

    FilledButton confirm() => tester
        .widget<FilledButton>(find.byKey(const Key('wb-collab-join-confirm')));
    // 空输入 / 纯空格：确认禁用。
    expect(confirm().onPressed, isNull);
    await tester.enterText(
        find.byKey(const Key('wb-collab-room-field')), '   ');
    await tester.pump();
    expect(confirm().onPressed, isNull);
    // 有效输入：确认启用。
    await tester.enterText(
        find.byKey(const Key('wb-collab-room-field')), 'r1');
    await tester.pump();
    expect(confirm().onPressed, isNotNull);

    // 取消：无连接、无副作用（仍在本地）。
    await tester.tap(find.byKey(const Key('wb-collab-join-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-collab-join-dialog')), findsNothing);
    expect(harness.bridges, isEmpty);
    expect(harness.service.status, WbRealtimeStatus.idle);
    expect(find.byKey(const Key('wb-collab-status-chip')), findsNothing);

    await _unmount(tester);
  });

  testWidgets('已在房：入口开房间信息对话框 → 退出回到本地', (WidgetTester tester) async {
    final _FakeHarness harness = _FakeHarness();
    await _pumpEditPage(tester, harness.service);
    await _joinRoom(tester, 'demo-room');
    final FakeSocketIoBridge bridge = harness.bridges.single;
    bridge.fireConnected(socketId: 'sock-1');
    await tester.pumpAndSettle();
    expect(harness.service.status, WbRealtimeStatus.connected);

    // 在房：入口为状态 chip（InkWell），点击打开房间信息。
    await tester.tap(find.byKey(const Key('wb-collab-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-collab-room-dialog')), findsOneWidget);
    expect(find.text('demo-room'), findsOneWidget);
    expect(find.textContaining(kWbRealtimeEndpoint), findsOneWidget);
    expect(find.textContaining('已连接 · 0 人在线'), findsOneWidget);

    // 退出互动白板：回到本地（boardId 清空、入口回文字按钮、chip 消失）。
    await tester.tap(find.byKey(const Key('wb-collab-room-leave')));
    await tester.pumpAndSettle();
    expect(find.text('已退出互动白板（回到本地模式）'), findsOneWidget);
    expect(harness.service.boardId, isNull);
    expect(find.byKey(const Key('wb-collab-entry')), findsOneWidget);
    expect(find.text('互动白板'), findsOneWidget);
    expect(find.byKey(const Key('wb-collab-status-chip')), findsNothing);

    // 等待 SnackBar 自动收起（避免残留定时器）。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await _unmount(tester);
  });

  testWidgets('列表页：无协作 UI', (WidgetTester tester) async {
    await tester.pumpWidget(WhiteboardWebApp(router: createWebRouter()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('wb-collab-status-chip')), findsNothing);
    expect(find.byKey(const Key('wb-participants-button')), findsNothing);

    await _unmount(tester);
  });

  testWidgets('idle 隐藏 chip；connecting 显示「连接中」', (WidgetTester tester) async {
    final WbWebThemeState themeState = WbWebThemeState();
    final WbRealtimeService service = WbRealtimeService(
      clientLoader: (String endpoint) async {},
      bridgeFactory: FakeSocketIoBridge.new,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: themeState.flutterThemeData,
        home: ChangeNotifierProvider<WbRealtimeService>.value(
          value: service,
          child: const Scaffold(body: WbCollabStatusChip()),
        ),
      ),
    );
    expect(find.byKey(const Key('wb-collab-status-chip')), findsNothing);

    await service.connect('http://127.0.0.1:8790');
    await tester.pump();
    expect(find.byKey(const Key('wb-collab-status-chip')), findsOneWidget);
    expect(find.text('连接中'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    service.dispose();
  });

  testWidgets('P3：选区出现上下文工具栏浮层（wb-context-*）', (WidgetTester tester) async {
    final _FakeHarness harness = _FakeHarness();
    final WbCoreService core = WbCoreService(loader: _ReadyLoader());
    addTearDown(core.dispose);
    await _pumpEditPage(
      tester,
      harness.service,
      size: const Size(1400, 800),
      coreService: core,
    );

    final WbWebContextToolbarHost host = tester.widget<WbWebContextToolbarHost>(
      find.byType(WbWebContextToolbarHost),
    );
    final WbCanvasController canvas = host.controller;
    expect(canvas.selection, isNotNull);

    // 无选区：无浮层。
    expect(
      find.byKey(const ValueKey<String>('wb-context-toolbar-popup')),
      findsNothing,
    );

    // 插入元素（自动选中）→ 浮层以选区为锚点浮出。
    canvas.insertElement(type: 'note', size: const Size(120, 80));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('wb-context-toolbar-popup')),
      findsOneWidget,
    );

    // 清空选区 → 浮层收起。
    canvas.selection?.clear();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('wb-context-toolbar-popup')),
      findsNothing,
    );

    await _unmount(tester);
  });

  testWidgets('P4：入房装配远端在场层；presence 帧驱动不崩', (WidgetTester tester) async {
    final _FakeHarness harness = _FakeHarness();
    final WbCoreService core = WbCoreService(loader: _ReadyLoader());
    addTearDown(core.dispose);
    await _pumpEditPage(
      tester,
      harness.service,
      size: const Size(1400, 800),
      coreService: core,
    );

    // 本地：无远端在场层。
    expect(find.byType(WbRemoteCursorsOverlay), findsNothing);

    await _joinRoom(tester, 'demo-room');
    final FakeSocketIoBridge bridge = harness.bridges.single;
    bridge.fireConnected(socketId: 'sock-1');
    await tester.pumpAndSettle();

    // 入房后：在场层装配（引擎缺失时画布 op 链路跳过，远端光标 / 选区
    // 仍可见——在场层与引擎解耦）。
    expect(find.byType(WbRemoteCursorsOverlay), findsOneWidget);

    // 远端光标 / 选区帧（服务端附加 userId 后转发；无 pageId 帧为
    // 兼容口径透传）。
    bridge.fireEvent('presence:preview', <String, Object?>{
      'kind': 'cursor',
      'userId': 'peer-9',
      'x': 120.0,
      'y': 80.0,
    });
    bridge.fireEvent('presence:preview', <String, Object?>{
      'kind': 'selection',
      'userId': 'peer-9',
      'elementIds': <Object?>['el-1'],
    });
    // 在场层 ticker 按墙钟过期（测试墙钟不随假时钟推进）：仅按帧推进，
    // 不用 pumpAndSettle（持续 tick 会超时）。
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);

    await _unmount(tester);
  });
}

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

/// 注入假加载器 / 假桥的协作服务 + 桥收集器。
class _FakeHarness {
  final List<FakeSocketIoBridge> bridges = <FakeSocketIoBridge>[];

  late final WbRealtimeService service = WbRealtimeService(
    clientLoader: (String endpoint) async {},
    bridgeFactory: () {
      final FakeSocketIoBridge created = FakeSocketIoBridge();
      bridges.add(created);
      return created;
    },
  );
}

/// 启动注入协作服务的编辑页；[coreService] 非空时注入（可控引擎状态）。
Future<void> _pumpEditPage(
  WidgetTester tester,
  WbRealtimeService service, {
  Size? size,
  WbCoreService? coreService,
}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    WhiteboardWebApp(
      router: createWebRouter(
        initialLocation: WbWebRoutes.boardPath('test-board', name: '测试白板'),
      ),
      realtimeService: service,
      coreService: coreService,
    ),
  );
  await tester.pumpAndSettle();
}

/// 经入口 UI 加入房间（默认本地：点入口 → 输入房间号 → 确认）。
///
/// 结束后冲刷入房 SnackBar 队列（VM 降级下依次为「画布引擎未就绪」+
/// 「已加入互动白板」两条，各约 4s）——避免残留 snack 阻塞后续断言 / 轻提示。
Future<void> _joinRoom(WidgetTester tester, String room) async {
  await tester.tap(find.byKey(const Key('wb-collab-entry')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('wb-collab-join-dialog')), findsOneWidget);
  await tester.enterText(find.byKey(const Key('wb-collab-room-field')), room);
  await tester.pump();
  await tester.tap(find.byKey(const Key('wb-collab-join-confirm')));
  await tester.pumpAndSettle();
  // 逐条冲刷（一次 pump 只令当前条到期；后续条在其关闭动画结束后
  // 才开始计时，需循环快进）。
  for (int i = 0; i < 3; i++) {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }
}

/// 卸载应用（触发编辑页 `leave()`），并冲刷其微任务 / 超时兜底定时器。
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 900));
}

/// 取顶部浮动工具面板按钮（按 key 命中 `WbCanvasIconButton`）。
WbCanvasIconButton _paletteButton(WidgetTester tester, String key) =>
    tester.widget<WbCanvasIconButton>(find.byKey(ValueKey<String>(key)));

/// 固定 ready 状态的假核心加载器（驱动共享画布与顶部工具面板挂载）。
class _ReadyLoader extends WbCoreLoader {
  @override
  WbCoreStatus get status => WbCoreStatus.ready;

  @override
  bool get isAvailable => WbCoreStatus.ready.isAvailable;

  @override
  Future<WbCoreStatus> load() async => WbCoreStatus.ready;
}

/// 构造参与者载荷（服务端 `ParticipantInfo`：userId/socketId/role/joinedAt
/// + M3 扩展 grantedWrite / handRaised，未传则不包含该键）。
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
