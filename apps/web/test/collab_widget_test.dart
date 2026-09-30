/// W1 协作 UI widget 测试（T1.8）：状态 chip / 参与者面板 / 响应式接线。
///
/// 覆盖：
/// - 编辑页默认（VM 降级）服务：chip「未连接」+ 参与者入口可开面板；
/// - 注入假桥后：已连接 chip、参与者徽标、面板列表（「我」标记 / 角色）；
/// - 断线重连：chip「重连中」、列表保留（防闪烁）、恢复「已连接」；
/// - 窄屏 600：协作入口无布局溢出；
/// - 列表页：无协作 UI；`idle` 态 chip 隐藏。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_web/app.dart';
import 'package:whiteboard_web/routes.dart';
import 'package:whiteboard_web/services/realtime_service.dart';
import 'package:whiteboard_web/state/theme_state.dart';
import 'package:whiteboard_web/widgets/collab/collab_status_chip.dart';

import 'support/fake_socketio_bridge.dart';

void main() {
  testWidgets('默认服务（VM 降级）：chip 未连接 + 参与者面板可用', (WidgetTester tester) async {
    await tester.pumpWidget(
      WhiteboardWebApp(
        router: createWebRouter(initialLocation: WbWebRoutes.boardPath('demo-roadmap')),
      ),
    );
    await tester.pumpAndSettle();

    // VM 下脚本加载失败 → disconnected：chip 显示「未连接」。
    expect(find.byKey(const Key('wb-collab-status-chip')), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.byKey(const Key('wb-participants-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('wb-participants-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-participants-panel')), findsOneWidget);
    expect(find.text('暂无其他参与者'), findsOneWidget);
    expect(find.textContaining('未连接协作服务'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('已连接：chip / 参与者徽标 / 面板列表（含「我」与角色）', (WidgetTester tester) async {
    final _FakeHarness harness = _FakeHarness();
    await _pumpEditPage(tester, harness.service);
    expect(harness.service.status, WbRealtimeStatus.connecting);

    final FakeSocketIoBridge bridge = harness.bridges.single;
    bridge.fireConnected(socketId: 'sock-1');
    await tester.pumpAndSettle();

    expect(harness.service.status, WbRealtimeStatus.connected);
    expect(find.text('已连接'), findsOneWidget);
    // 编辑页以路由 boardId 自动加入房间。
    final FakeAckCall joinCall = bridge.ackCalls.single;
    expect(joinCall.event, 'board:join');
    expect(joinCall.payload, <String, Object?>{'boardId': 'demo-roadmap'});

    bridge.fireEvent('board:session', <String, Object?>{
      'userId': 'me-01',
      'authMode': 'anonymous',
      'role': 'Host',
    });
    bridge.fireEvent('board:joined', <String, Object?>{
      'boardId': 'demo-roadmap',
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
    harness.bridges.single.fireConnected();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('wb-collab-status-chip')), findsOneWidget);
    expect(find.byKey(const Key('wb-participants-button')), findsOneWidget);
    expect(tester.takeException(), isNull);

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

/// 启动注入协作服务的编辑页。
Future<void> _pumpEditPage(WidgetTester tester, WbRealtimeService service, {Size? size}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    WhiteboardWebApp(
      router: createWebRouter(
        initialLocation: WbWebRoutes.boardPath('demo-roadmap', name: '产品路线图'),
      ),
      realtimeService: service,
    ),
  );
  await tester.pumpAndSettle();
}

/// 卸载应用（触发编辑页 `leave()`），并冲刷其微任务 / 超时兜底定时器。
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 900));
}

/// 构造参与者载荷（服务端 `ParticipantInfo`：userId/socketId/role/joinedAt）。
Map<String, Object?> _participant(String userId, String socketId, String role, {int joinedAt = 1000}) =>
    <String, Object?>{
      'userId': userId,
      'socketId': socketId,
      'role': role,
      'joinedAt': joinedAt,
    };
