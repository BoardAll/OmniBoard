/// 协同 M3 widget 测试：参与者面板 M3 操作与标记（跟随 / 举手 / 授权 /
/// 移除）/ 演示收窄禁用态（浮动工具栏 drawingEnabled + 画布交互开关）/
/// 跟随 HUD / present chip / removed 只读横幅（fake 引擎 + Provider 注入，
/// 不依赖 DLL 与网络）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_desktop/app.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/services/shortcut_service.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';
import 'package:whiteboard_desktop/state/follow_controller.dart';
import 'package:whiteboard_desktop/state/theme_state.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_tool_palette.dart';
import 'package:whiteboard_desktop/widgets/collab/participants_panel.dart';
import 'package:whiteboard_desktop/widgets/floating_toolbar.dart';
import 'package:whiteboard_desktop/widgets/toolbar/toolbar_item.dart';

import 'support/fake_collab_engine.dart';

/// 服务 + fake 引擎 + 手动定时器装配。
class _Harness {
  _Harness() {
    service = WbCollabService(
      engine: engine,
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

/// 演示模式 FFI 服务（候选路径必然失败，保证测试确定性）。
WbFfiService _demoFfi() {
  return WbFfiService(candidatePaths: const <String>['__wb_missing__.dll'])
    ..initialize();
}

/// 挂载单个组件（Provider 注入服务；可选跟随控制器）。
Future<void> _pump(
  WidgetTester tester,
  WbCollabService service,
  Widget child, {
  WbFollowController? follow,
}) async {
  Widget app = MaterialApp(home: Scaffold(body: child));
  if (follow != null) {
    app = ChangeNotifierProvider<WbFollowController>.value(
      value: follow,
      child: app,
    );
  }
  await tester.pumpWidget(
    ChangeNotifierProvider<WbCollabService>.value(value: service, child: app),
  );
  await tester.pump();
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));

/// 读取工具栏按钮渲染数据（enabled 等）。
WbToolbarIconButton _toolButton(WidgetTester tester, String toolId) =>
    tester.widget<WbToolbarIconButton>(_key('wb-toolbar-$toolId'));

/// 启动应用并进入编辑页（1600x1000 视口，fake 引擎注入）。
Future<_Harness> _pumpEditor(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final WbThemeState theme = WbThemeState();
  final _Harness h = _Harness();
  addTearDown(() {
    theme.dispose();
    h.service.dispose();
  });

  await tester.pumpWidget(WhiteboardApp(
    ffiService: _demoFfi(),
    themeState: theme,
    collabService: h.service,
    shortcutService: WbShortcutService(),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('新建白板'));
  await tester.pumpAndSettle();
  return h;
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

void main() {
  // ---- 参与者面板 M3 操作 ---------------------------------------------------

  group('WbParticipantsPanel M3 操作', () {
    testWidgets('行内标记：已举手 / 已授权 / 演示中', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        mode: 'present',
        presenterId: 'u2',
        selfUserId: 'me',
        selfRole: roleHost,
        participants: <dynamic>[
          <String, dynamic>{
            'userId': 'u2',
            'role': rolePresenter,
            'handRaised': true,
          },
          <String, dynamic>{
            'userId': 'u3',
            'role': roleParticipant,
            'grantedWrite': true,
          },
          <String, dynamic>{'userId': 'me', 'role': roleHost},
        ],
      );
      h.timers.fire();
      await _pump(tester, h.service, const WbParticipantsPanel());

      expect(find.text('已举手'), findsOneWidget);
      expect(find.text('已授权'), findsOneWidget);
      expect(find.text('演示中'), findsOneWidget);
      expect(_key('wb-participant-u2'), findsOneWidget);
      expect(_key('wb-participant-u3'), findsOneWidget);
    });

    testWidgets('跟随按钮：点击 startFollow → 停止跟随；self 行无操作按钮',
        (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        selfUserId: 'me',
        selfRole: roleHost,
        participants: <dynamic>[
          <String, dynamic>{'userId': 'me', 'role': roleHost},
          <String, dynamic>{'userId': 'u2', 'role': roleParticipant},
        ],
      );
      h.timers.fire();

      final WbCanvasController canvas = WbCanvasController();
      final WbFollowController follow =
          WbFollowController(collab: h.service, canvas: canvas);
      addTearDown(follow.dispose);
      addTearDown(canvas.dispose);

      await _pump(
        tester,
        h.service,
        const WbParticipantsPanel(),
        follow: follow,
      );

      // self 行无跟随按钮（自身操作在面板底部）。
      expect(_key('wb-participant-follow-me'), findsNothing);

      await tester.tap(_key('wb-participant-follow-u2'));
      await tester.pump();
      expect(follow.followingUserId, 'u2');
      expect(h.engine.interactiveCalls.single, <String, dynamic>{
        'action': 'follow',
        'targetUserId': 'u2',
      });
      expect(find.byTooltip('停止跟随'), findsOneWidget);

      await tester.tap(_key('wb-participant-follow-u2'));
      await tester.pump();
      expect(follow.isFollowing, isFalse);
      expect(h.engine.interactiveCalls.last['action'], 'unfollow');
    });

    testWidgets('跟随按钮（无 Provider）：降级直发 follow 请求',
        (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        selfUserId: 'me',
        selfRole: roleHost,
        participants: <dynamic>[
          <String, dynamic>{'userId': 'me', 'role': roleHost},
          <String, dynamic>{'userId': 'u2', 'role': roleParticipant},
        ],
      );
      h.timers.fire();
      await _pump(tester, h.service, const WbParticipantsPanel());

      await tester.tap(_key('wb-participant-follow-u2'));
      await tester.pump();

      expect(h.engine.interactiveCalls.single, <String, dynamic>{
        'action': 'follow',
        'targetUserId': 'u2',
      });
    });

    testWidgets('举手 / 收手（Participant 自身；服务端标记驱动文案）',
        (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        selfUserId: 'me',
        selfRole: roleParticipant,
        participants: <dynamic>[
          <String, dynamic>{'userId': 'me', 'role': roleParticipant},
          <String, dynamic>{'userId': 'u2', 'role': roleHost},
        ],
      );
      h.timers.fire();
      await _pump(tester, h.service, const WbParticipantsPanel());

      expect(find.text('举手'), findsOneWidget);
      await tester.tap(_key('wb-panel-hand-toggle'));
      await tester.pump();
      expect(h.engine.interactiveCalls.single['action'], 'raiseHand');

      // 服务端广播 handRaised → 文案变「收手」。
      h.engine.room = _room(
        selfUserId: 'me',
        selfRole: roleParticipant,
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
      await tester.pump();
      expect(find.text('收手'), findsOneWidget);

      await tester.tap(_key('wb-panel-hand-toggle'));
      await tester.pump();
      expect(h.engine.interactiveCalls.last['action'], 'lowerHand');
    });

    testWidgets('Host 自身：不显示举手按钮（可管理互动）',
        (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        selfUserId: 'me',
        selfRole: roleHost,
        participants: <dynamic>[
          <String, dynamic>{'userId': 'me', 'role': roleHost},
        ],
      );
      h.timers.fire();
      await _pump(tester, h.service, const WbParticipantsPanel());

      expect(_key('wb-panel-hand-toggle'), findsNothing);
    });

    testWidgets('开始演示 / 结束演示（Host；署名行展示演示者）',
        (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        selfUserId: 'me',
        selfRole: roleHost,
        participants: <dynamic>[
          <String, dynamic>{'userId': 'me', 'role': roleHost},
          <String, dynamic>{'userId': 'u2', 'role': roleParticipant},
        ],
      );
      h.timers.fire();
      await _pump(tester, h.service, const WbParticipantsPanel());

      expect(find.text('开始演示'), findsOneWidget);
      await tester.tap(_key('wb-panel-present-toggle'));
      await tester.pump();
      expect(h.engine.interactiveCalls.single['action'], 'startPresent');

      // 服务端广播 present → 「结束演示」+ 署名行。
      h.engine.room = _room(
        mode: 'present',
        presenterId: 'me',
        selfUserId: 'me',
        selfRole: roleHost,
        participants: <dynamic>[
          <String, dynamic>{'userId': 'me', 'role': roleHost},
          <String, dynamic>{'userId': 'u2', 'role': roleParticipant},
        ],
      );
      h.timers.fire();
      await tester.pump();
      expect(find.text('结束演示'), findsOneWidget);
      expect(find.textContaining('演示中 · '), findsOneWidget);

      await tester.tap(_key('wb-panel-present-toggle'));
      await tester.pump();
      expect(h.engine.interactiveCalls.last['action'], 'stopPresent');
    });

    testWidgets('授权控制 / 收回控制（CoHost 对 Participant）',
        (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        selfUserId: 'me',
        selfRole: roleCoHost,
        participants: <dynamic>[
          <String, dynamic>{'userId': 'me', 'role': roleCoHost},
          <String, dynamic>{'userId': 'u2', 'role': roleParticipant},
        ],
      );
      h.timers.fire();
      await _pump(tester, h.service, const WbParticipantsPanel());

      expect(_key('wb-participant-grant-u2'), findsOneWidget);
      await tester.tap(_key('wb-participant-grant-u2'));
      await tester.pump();
      expect(h.engine.interactiveCalls.single, <String, dynamic>{
        'action': 'grantControl',
        'userId': 'u2',
      });

      // u2 grantedWrite → 「收回控制」。
      h.engine.room = _room(
        selfUserId: 'me',
        selfRole: roleCoHost,
        participants: <dynamic>[
          <String, dynamic>{'userId': 'me', 'role': roleCoHost},
          <String, dynamic>{
            'userId': 'u2',
            'role': roleParticipant,
            'grantedWrite': true,
          },
        ],
      );
      h.timers.fire();
      await tester.pump();
      expect(find.byTooltip('收回控制'), findsOneWidget);

      await tester.tap(_key('wb-participant-grant-u2'));
      await tester.pump();
      expect(h.engine.interactiveCalls.last, <String, dynamic>{
        'action': 'revokeControl',
        'userId': 'u2',
      });
    });

    testWidgets('CoHost 目标：不显示授权按钮（invalid-target 前置收窄）',
        (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        selfUserId: 'me',
        selfRole: roleHost,
        participants: <dynamic>[
          <String, dynamic>{'userId': 'me', 'role': roleHost},
          <String, dynamic>{'userId': 'u2', 'role': roleCoHost},
        ],
      );
      h.timers.fire();
      await _pump(tester, h.service, const WbParticipantsPanel());

      expect(_key('wb-participant-grant-u2'), findsNothing);
      // Host 可移除 CoHost（层级严格高于目标）。
      expect(_key('wb-participant-remove-u2'), findsOneWidget);
    });

    testWidgets('移除成员（Host 对 Participant）', (WidgetTester tester) async {
      final _Harness h = _Harness();
      addTearDown(h.service.dispose);
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        selfUserId: 'me',
        selfRole: roleHost,
        participants: <dynamic>[
          <String, dynamic>{'userId': 'me', 'role': roleHost},
          <String, dynamic>{'userId': 'u2', 'role': roleParticipant},
        ],
      );
      h.timers.fire();
      await _pump(tester, h.service, const WbParticipantsPanel());

      await tester.tap(_key('wb-participant-remove-u2'));
      await tester.pump();

      expect(h.engine.interactiveCalls.single, <String, dynamic>{
        'action': 'removeUser',
        'userId': 'u2',
      });
    });
  });

  // ---- 浮动工具栏禁用态（drawingEnabled） -----------------------------------

  group('FloatingToolbar drawingEnabled', () {
    testWidgets('drawingEnabled=false：绘制项禁用、导航项保留、撤销禁用',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Align(child: FloatingToolbar(drawingEnabled: false)),
        ),
      ));
      await tester.pumpAndSettle();

      expect(_toolButton(tester, 'pen').enabled, isFalse);
      expect(_toolButton(tester, 'sticky').enabled, isFalse);
      expect(_toolButton(tester, 'shape').enabled, isFalse);
      expect(_toolButton(tester, 'select').enabled, isTrue);
      expect(_toolButton(tester, 'hand').enabled, isTrue);
      expect(_toolButton(tester, 'edit.undo').enabled, isFalse);
      expect(_toolButton(tester, 'edit.redo').enabled, isFalse);
    });

    testWidgets('drawingEnabled=true（默认）：绘制项可用', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Align(child: FloatingToolbar())),
      ));
      await tester.pumpAndSettle();

      expect(_toolButton(tester, 'pen').enabled, isTrue);
      expect(_toolButton(tester, 'select').enabled, isTrue);
    });
  });

  // ---- 画布工具面板禁用态（drawingEnabled） ---------------------------------

  group('WbCanvasToolPalette drawingEnabled', () {
    /// 构造含一条可撤销记录的控制器（验证撤销置灰与栈状态无关）。
    WbCanvasController seededCanvas() {
      final WbCanvasController canvas = WbCanvasController()
        ..setViewportSize(const Size(800, 600));
      canvas.insertElements(<WbElementSpec>[
        const WbElementSpec(
          type: WbElementKind.note,
          position: Offset(10, 10),
          size: Size(100, 80),
        ),
      ]);
      return canvas;
    }

    WbCanvasIconButton buttonOf(WidgetTester tester, String key) =>
        tester.widget<WbCanvasIconButton>(find.byKey(ValueKey<String>(key)));

    testWidgets('false：非导航工具 / 撤销重做 / 更多置灰，点击不切换工具',
        (WidgetTester tester) async {
      final WbCanvasController canvas = seededCanvas();
      addTearDown(canvas.dispose);
      expect(canvas.canUndo, isTrue);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WbCanvasToolPalette(
            controller: canvas,
            drawingEnabled: false,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(buttonOf(tester, 'wb-canvas-tool-select').enabled, isTrue);
      expect(buttonOf(tester, 'wb-canvas-tool-hand').enabled, isTrue);
      expect(buttonOf(tester, 'wb-canvas-tool-pen').enabled, isFalse);
      expect(buttonOf(tester, 'wb-canvas-tool-sticky').enabled, isFalse);
      expect(buttonOf(tester, 'wb-canvas-undo').enabled, isFalse);
      expect(buttonOf(tester, 'wb-canvas-redo').enabled, isFalse);
      expect(buttonOf(tester, 'wb-canvas-more').enabled, isFalse);

      await tester.tap(
        find.byKey(const ValueKey<String>('wb-canvas-tool-pen')),
      );
      await tester.pump();
      expect(canvas.tool, WbCanvasTool.select);
    });

    testWidgets('true（默认）：工具 / 撤销 / 更多可用', (WidgetTester tester) async {
      final WbCanvasController canvas = seededCanvas();
      addTearDown(canvas.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: WbCanvasToolPalette(controller: canvas)),
      ));
      await tester.pumpAndSettle();

      expect(buttonOf(tester, 'wb-canvas-tool-pen').enabled, isTrue);
      expect(buttonOf(tester, 'wb-canvas-undo').enabled, isTrue);
      expect(buttonOf(tester, 'wb-canvas-more').enabled, isTrue);

      await tester.tap(
        find.byKey(const ValueKey<String>('wb-canvas-tool-pen')),
      );
      await tester.pump();
      expect(canvas.tool, WbCanvasTool.pen);
    });
  });

  // ---- 画布交互收窄（setInteractionEnabled） --------------------------------

  group('WbCanvasController setInteractionEnabled', () {
    test('false：编辑手势忽略（保持 idle）→ 恢复后可绘制', () {
      final WbCanvasController canvas = WbCanvasController();
      addTearDown(canvas.dispose);
      canvas.setTool(WbCanvasTool.pen);
      canvas.setInteractionEnabled(false);

      canvas.handlePointerDown(1, const Offset(100, 100), shift: false);
      expect(canvas.gesture, WbCanvasGesture.idle);
      expect(canvas.pendingStroke, isNull);

      canvas.setInteractionEnabled(true);
      canvas.handlePointerDown(1, const Offset(100, 100), shift: false);
      expect(canvas.gesture, WbCanvasGesture.draw);
    });

    test('false：编辑快捷键忽略、视图键保留', () {
      final WbCanvasController canvas = WbCanvasController();
      addTearDown(canvas.dispose);
      canvas.setInteractionEnabled(false);

      expect(canvas.handleShortcut(LogicalKeyboardKey.keyZ, ctrl: true),
          isFalse); // 撤销被忽略。
      expect(canvas.handleShortcut(LogicalKeyboardKey.digit0, ctrl: true),
          isTrue); // 复位视图保留。

      canvas.setInteractionEnabled(true);
      expect(
          canvas.handleShortcut(LogicalKeyboardKey.keyZ, ctrl: true), isTrue);
    });
  });

  // ---- 编辑页整页（HUD / chip / removed） -----------------------------------

  group('编辑页 M3 状态条', () {
    testWidgets('present 自动跟随：HUD 显示；停止按钮收起 HUD',
        (WidgetTester tester) async {
      final _Harness h = await _pumpEditor(tester);
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        mode: 'present',
        presenterId: 'user-2',
        selfUserId: 'user-1',
        selfRole: roleParticipant,
      );
      h.timers.fire();
      await tester.pumpAndSettle();

      expect(_key('wb-follow-hud'), findsOneWidget);
      expect(find.textContaining('跟随中'), findsOneWidget);

      await tester.tap(_key('wb-follow-stop'));
      await tester.pumpAndSettle();
      expect(_key('wb-follow-hud'), findsNothing);
      expect(h.engine.interactiveCalls.last['action'], 'unfollow');
    });

    testWidgets('面板「跟随」→ HUD（整页链路：Provider 同实例）',
        (WidgetTester tester) async {
      final _Harness h = await _pumpEditor(tester);
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        selfUserId: 'user-1',
        selfRole: roleHost,
        participants: <dynamic>[
          <String, dynamic>{'userId': 'user-1', 'role': roleHost},
          <String, dynamic>{'userId': 'user-2', 'role': roleParticipant},
        ],
      );
      h.timers.fire();
      await tester.pumpAndSettle();

      await tester.tap(_key('wb-participants-button'));
      await tester.pumpAndSettle();
      await tester.tap(_key('wb-participant-follow-user-2'));
      await tester.pumpAndSettle();

      // 关闭面板（HUD 在画布 Stack 顶层）。
      await tester.tap(find.descendant(
        of: _key('wb-participants-panel'),
        matching: find.byTooltip('关闭'),
      ));
      await tester.pumpAndSettle();

      expect(_key('wb-follow-hud'), findsOneWidget);
      expect(find.text('跟随中 · user-2'), findsOneWidget);
    });

    testWidgets('present chip：本人演示（不自动跟随、编辑可用）',
        (WidgetTester tester) async {
      final _Harness h = await _pumpEditor(tester);
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        mode: 'present',
        presenterId: 'user-1',
        selfUserId: 'user-1',
        selfRole: roleHost,
      );
      h.timers.fire();
      await tester.pumpAndSettle();

      expect(_key('wb-present-chip'), findsOneWidget);
      expect(_key('wb-follow-hud'), findsNothing); // 本人演示：不自动跟随。
      expect(_toolButton(tester, 'pen').enabled, isTrue);
    });

    testWidgets('present 非演示者：绘制项禁用 + 自动跟随 HUD',
        (WidgetTester tester) async {
      final _Harness h = await _pumpEditor(tester);
      await h.service.start(boardId: 'b1');
      h.engine.room = _room(
        mode: 'present',
        presenterId: 'user-2',
        selfUserId: 'user-1',
        selfRole: roleParticipant,
      );
      h.timers.fire();
      await tester.pumpAndSettle();

      expect(_key('wb-present-chip'), findsOneWidget);
      expect(_toolButton(tester, 'pen').enabled, isFalse);
      expect(_toolButton(tester, 'select').enabled, isTrue);
      expect(_key('wb-follow-hud'), findsOneWidget);
    });

    testWidgets('removed：只读横幅 + 绘制项禁用', (WidgetTester tester) async {
      final _Harness h = await _pumpEditor(tester);
      await h.service.start(boardId: 'b1');
      h.engine.nextRemoved = <String, dynamic>{'reason': 'RemovedByHost'};
      h.timers.fire();
      await tester.pumpAndSettle();

      expect(_key('wb-removed-banner'), findsOneWidget);
      expect(find.text('你已被移出此白板，当前为只读'), findsOneWidget);
      expect(_toolButton(tester, 'pen').enabled, isFalse);
    });
  });
}
