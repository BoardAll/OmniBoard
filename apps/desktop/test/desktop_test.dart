/// 桌面应用骨架测试：服务 / 状态 / 路由 / Widget 冒烟。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:whiteboard_ai/ai_client.dart';
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_desktop/app.dart';
import 'package:whiteboard_desktop/routes.dart';
import 'package:whiteboard_desktop/services/ai_service.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/services/shortcut_service.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';
import 'package:whiteboard_desktop/state/ai_state.dart';
import 'package:whiteboard_desktop/state/board_state.dart';
import 'package:whiteboard_desktop/state/page_state.dart';
import 'package:whiteboard_desktop/state/selection_state.dart';
import 'package:whiteboard_desktop/state/theme_state.dart';

/// 构造演示模式 FFI 服务（候选路径必然失败，保证测试确定性）。
WbFfiService _demoFfi() {
  return WbFfiService(candidatePaths: const <String>['__wb_missing__.dll'])
    ..initialize();
}

/// 流式假提供商（不触网）。
class _FakeProvider extends AiProvider {
  @override
  String get id => 'fake';

  @override
  String get defaultModel => 'fake-model';

  @override
  Future<AiChatResponse> chat(AiChatRequest request) async {
    return AiChatResponse(message: AiMessage.assistant('收到'));
  }

  @override
  Stream<AiStreamEvent> chatStream(AiChatRequest request) async* {
    yield const AiTextDelta('你好');
    yield const AiTextDelta('，白板');
    yield const AiStreamDone();
  }
}

/// 内存协同引擎（无 DLL 测试用；实现 [WbCollabEngine] 端口）。
class _FakeCollabEngine implements WbCollabEngine {
  /// 传输连接状态摆布（`connected` / `disconnected` / `failed` 等）。
  String transportState = 'connected';

  /// 已发送 op（出口契约断言用）。
  final List<Map<String, dynamic>> sentOps = <Map<String, dynamic>>[];

  /// 下一次 events() 返回的入站 op（drain 后清空）。
  List<Map<String, dynamic>> nextOps = <Map<String, dynamic>>[];

  /// disconnect 调用次数。
  int disconnectCount = 0;

  @override
  WbSyncStatusData connect({required String endpoint, String? token}) {
    transportState = 'connected';
    return status();
  }

  @override
  WbSyncStatusData disconnect() {
    disconnectCount++;
    transportState = 'disconnected';
    return status();
  }

  @override
  WbSyncStatusData status() => WbSyncStatusData(
        connected: transportState == 'connected',
        transportState: transportState,
      );

  @override
  WbSyncJoinData join(String boardId, {String? pageId}) =>
      WbSyncJoinData(boardId: boardId, joined: true, pageId: pageId);

  @override
  WbSyncSendResult sendOperation(Map<String, dynamic> op) {
    sentOps.add(op);
    return const WbSyncSendResult(sent: true, syncedCount: 1);
  }

  @override
  WbSyncEventsData events() {
    final List<Map<String, dynamic>> ops = nextOps;
    nextOps = <Map<String, dynamic>>[];
    return WbSyncEventsData(ops: ops, status: status());
  }

  @override
  WbSyncFlushData flush() =>
      const WbSyncFlushData(synced: 0, pendingCount: 0, syncedCount: 0);

  @override
  WbCrdtCreateData createDocument(String docId, {String? actor}) =>
      WbCrdtCreateData(docId: docId, actor: actor ?? '', version: 0);

  @override
  WbCrdtApplyData applyLocal(String docId, Map<String, dynamic> op) {
    final Map<String, dynamic> applied = <String, dynamic>{
      'actor': 'fake-actor',
      'seq': sentOps.length + 1,
      'origin': 'local',
      ...op,
      'timestamp': 0,
    };
    return WbCrdtApplyData(
      applied: true,
      docId: docId,
      key: (op['key'] ?? '').toString(),
      op: applied,
    );
  }
}

void main() {
  group('WbFfiService', () {
    test('加载失败进入演示模式', () {
      final WbFfiService ffi = _demoFfi();
      expect(ffi.isAvailable, isFalse);
      expect(ffi.loadedFrom, isEmpty);
      expect(ffi.error, isNotNull);
      expect(() => ffi.board, throwsStateError);
    });
  });

  group('WbBoardState / WbPageState（演示模式）', () {
    test('打开白板生成默认页面', () {
      final WbFfiService ffi = _demoFfi();
      final WbBoardState board = WbBoardState(ffi: ffi);
      board.open('demo-1', name: '测试白板');
      expect(board.hasBoard, isTrue);
      expect(board.isDemoMode, isTrue);
      expect(board.board?.name, '测试白板');

      final WbPageState pages = WbPageState(ffi: ffi);
      pages.attach(board.board!);
      expect(pages.pages.length, 1);
      expect(pages.currentPageId, 'demo-1-page-1');

      board.dispose();
      pages.dispose();
    });

    test('页面增删改排序', () {
      final WbFfiService ffi = _demoFfi();
      final WbBoardState board = WbBoardState(ffi: ffi)..open('demo-2');
      final WbPageState pages = WbPageState(ffi: ffi)..attach(board.board!);
      final String first = pages.pages.first.id;

      pages.addPage();
      expect(pages.pages.length, 2);
      expect(pages.currentPageId, isNot(first));

      pages.rename(first, '封面');
      expect(pages.pages.first.name, '封面');

      pages.duplicate(first);
      expect(pages.pages.length, 3);
      expect(pages.pages[1].name, '封面 副本');

      pages.move(first, 2);
      expect(pages.pages[2].id, first);

      pages.remove(first);
      expect(pages.pages.length, 2);

      // 至少保留一页。
      pages.remove(pages.pages.first.id);
      pages.remove(pages.pages.first.id);
      expect(pages.pages.length, 1);

      board.dispose();
      pages.dispose();
    });
  });

  group('WbSelectionState', () {
    test('增删切换与清空', () {
      final WbSelectionState selection = WbSelectionState();
      expect(selection.isEmpty, isTrue);

      selection.toggle('e1');
      selection.toggle('e2');
      expect(selection.count, 2);
      expect(selection.hasSelection, isTrue);

      selection.toggle('e1');
      expect(selection.count, 1);
      expect(selection.contains('e1'), isFalse);

      selection.select(<String>['e3', 'e4']);
      expect(selection.ids, <String>{'e3', 'e4'});

      selection.clear();
      expect(selection.isEmpty, isTrue);
      selection.dispose();
    });
  });

  group('WbCollabService（fake 引擎）', () {
    test('离线 → 连接 → 同步 → 断开', () async {
      final _FakeCollabEngine engine = _FakeCollabEngine();
      final WbCollabService sync = WbCollabService(
        engine: engine,
        sleep: (Duration _) async {},
      );
      expect(sync.status, WbSyncStatus.offline);
      expect(sync.isOnline, isFalse);

      // fake 引擎初始 transportState=connected → 连接即就绪（不触网）。
      await sync.connect('http://127.0.0.1:8790');
      expect(sync.status, WbSyncStatus.online);
      expect(sync.endpoint, 'http://127.0.0.1:8790');

      await sync.syncNow();
      expect(sync.lastSyncedAt, isNotNull);
      expect(sync.status, WbSyncStatus.online);

      await sync.disconnect();
      expect(sync.status, WbSyncStatus.offline);
      expect(engine.disconnectCount, 1);
      sync.dispose();
    });
  });

  group('WbShortcutService', () {
    test('默认表与键位格式化', () {
      expect(WbShortcutService.defaults.length, 12);
      expect(WbShortcutService.byId('edit.undo'), isNotNull);
      expect(WbShortcutService.byId('nope'), isNull);

      final String undo = WbShortcutService.describeById('edit.undo');
      expect(undo.contains('Ctrl') || undo.contains('⌘'), isTrue);
      expect(undo.endsWith('Z'), isTrue);
      expect(WbShortcutService.describeById('edit.delete'), 'Delete');
    });
  });

  group('WbAiState', () {
    test('未配置时发送追加系统提示且不触网', () async {
      final WbAiState state =
          WbAiState(aiService: WbAiAppService(ffi: _demoFfi()));
      expect(state.isConfigured, isFalse);

      await state.send('帮我画一个圆');
      expect(state.messages.length, 1);
      expect(state.messages.single.role, AiRoles.system);
      state.dispose();
    });

    test('配置后流式回合生成用户与助手消息', () async {
      final WbAiState state =
          WbAiState(aiService: WbAiAppService(ffi: _demoFfi()))
            ..configure(_FakeProvider());
      expect(state.isConfigured, isTrue);

      await state.send('你好');
      expect(state.messages.length, 2);
      expect(state.messages.first.role, AiRoles.user);
      expect(state.messages.first.content, '你好');
      expect(state.messages.last.role, AiRoles.assistant);
      expect(state.messages.last.content, '你好，白板');
      expect(state.isStreaming, isFalse);
      expect(state.error, isEmpty);
      state.dispose();
    });

    test('语音状态在空闲与聆听间切换', () {
      final WbAiState state =
          WbAiState(aiService: WbAiAppService(ffi: _demoFfi()));
      expect(state.voiceLabel, isEmpty);

      state.toggleVoice();
      expect(state.voice, AiVoiceStates.listening);
      expect(state.voiceLabel, '聆听中');

      state.toggleVoice();
      expect(state.voice, isEmpty);
      state.dispose();
    });
  });

  group('WbThemeState', () {
    test('内置主题可用且可切换', () {
      final WbThemeState state = WbThemeState();
      expect(state.available.length, 9);
      expect(state.current.id, isNotEmpty);

      final String firstId = state.available.first.id;
      state.select(firstId);
      expect(state.current.id, firstId);
      state.dispose();
    });
  });

  group('WbRoutes', () {
    test('路径生成', () {
      expect(WbRoutes.homePath, '/');
      expect(WbRoutes.settingsPath, '/settings');
      expect(WbRoutes.boardPath('b1'), '/board/b1');
    });
  });

  group('Widget 冒烟', () {
    testWidgets('启动渲染白板列表（演示模式）', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final WbThemeState theme = WbThemeState();
      final WbCollabService sync = WbCollabService();
      addTearDown(() {
        theme.dispose();
        sync.dispose();
      });

      await tester.pumpWidget(WhiteboardApp(
        ffiService: _demoFfi(),
        themeState: theme,
        collabService: sync,
        shortcutService: WbShortcutService(),
      ));
      await tester.pumpAndSettle();

      expect(find.text('我的白板'), findsOneWidget);
      expect(find.text('还没有白板'), findsOneWidget);
      expect(find.text('新建白板'), findsOneWidget);
      expect(find.text('演示模式'), findsOneWidget);
    });

    testWidgets('新建白板进入编辑页（画布 + 工具栏 + AI 面板）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final WbThemeState theme = WbThemeState();
      final WbCollabService sync = WbCollabService();
      addTearDown(() {
        theme.dispose();
        sync.dispose();
      });

      await tester.pumpWidget(WhiteboardApp(
        ffiService: _demoFfi(),
        themeState: theme,
        collabService: sync,
        shortcutService: WbShortcutService(),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('新建白板'));
      await tester.pumpAndSettle();

      expect(find.text('演示白板'), findsWidgets);
      expect(find.text('画布就绪'), findsOneWidget);
      expect(find.text('AI 助手'), findsOneWidget);
      expect(find.text('尚未配置 AI 提供商'), findsOneWidget);
      expect(find.text('添加页面'), findsOneWidget);
      expect(find.textContaining('页面 1'), findsWidgets);
    });

    testWidgets('主题通知重建不重置路由（设置页不被顶掉）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final WbThemeState theme = WbThemeState();
      final WbCollabService sync = WbCollabService();
      addTearDown(() {
        theme.dispose();
        sync.dispose();
      });

      final GoRouter router = createRouter();
      await tester.pumpWidget(WhiteboardApp(
        ffiService: _demoFfi(),
        themeState: theme,
        collabService: sync,
        shortcutService: WbShortcutService(),
        router: router,
      ));
      await tester.pumpAndSettle();

      router.go(WbRoutes.settingsPath);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('settings-section-card-主题')),
        findsOneWidget,
      );

      // 触发主题通知：修复前 Consumer 重建会新建 GoRouter，
      // 导航栈被重置回首页（设置页被顶掉）。
      theme.setHighContrast(true);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('settings-section-card-主题')),
        findsOneWidget,
        reason: '主题通知不应重置导航栈',
      );
      router.dispose();
    });
  });
}
