/// AI 面板深度交互与命令面板测试（Wave 3.5，《AI 助手与 MCP 设计》§4 / §8）。
///
/// 覆盖：
/// - 对话流：流式打字机（▍ / 生成中）、时间状态、未配置降级系统消息；
/// - 执行卡片：确认 / 拒绝 / 参数预览 / 批量执行 / 撤销（§8.2）；
/// - 幽灵预览：生成、toJson 契约与手动清除（§8.3，仅状态层数据）；
/// - 上下文引用：@元素 / #页面选择器、芯片删除、发送时并入上下文（§4.4）；
/// - 语音状态视觉：录音 / 转写 / 播报（§4.6，纯视觉模拟）；
/// - 命令面板：Ctrl+K 唤起、↑↓ 导航、Enter 执行、Esc 关闭（§8.1）、模糊搜索。
///
/// 说明：测试不依赖真实网络与 DLL —— AI 走假提供商（`ai_service` 装配面），
/// FFI 走演示模式（候选 DLL 路径必然失败）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_ai/ai_client.dart';
import 'package:whiteboard_desktop/services/ai_service.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/state/ai_state.dart';
import 'package:whiteboard_desktop/state/board_state.dart';
import 'package:whiteboard_desktop/state/page_state.dart';
import 'package:whiteboard_desktop/state/selection_state.dart';
import 'package:whiteboard_desktop/widgets/ai_panel.dart';
import 'package:whiteboard_desktop/widgets/command_palette.dart';

// ---------------------------------------------------------------------------
// 测试基础设施
// ---------------------------------------------------------------------------

/// 构造演示模式 FFI 服务（候选路径必然失败，保证测试确定性）。
WbFfiService _demoFfi() {
  return WbFfiService(candidatePaths: const <String>['__wb_missing__.dll'])
    ..initialize();
}

/// 读取 AI 面板输入框当前文本。
String _panelInputText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('ai.panel.input')))
    .controller!
    .text;

/// 仅文本增量的假提供商（打字机效果）。
class _StreamProvider extends AiProvider {
  @override
  String get id => 'fake-stream';

  @override
  String get defaultModel => 'fake-1';

  @override
  Future<AiChatResponse> chat(AiChatRequest request) async =>
      AiChatResponse(message: AiMessage.assistant(''));

  @override
  Stream<AiStreamEvent> chatStream(AiChatRequest request) async* {
    yield const AiTextDelta('好的，');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    yield const AiTextDelta('我来处理。');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    yield const AiStreamDone();
  }
}

/// 产出两条工具调用（element_create / element_delete）的假提供商。
class _ToolCallProvider extends AiProvider {
  @override
  String get id => 'fake-tools';

  @override
  String get defaultModel => 'fake-1';

  @override
  Future<AiChatResponse> chat(AiChatRequest request) async =>
      AiChatResponse(message: AiMessage.assistant(''));

  @override
  Stream<AiStreamEvent> chatStream(AiChatRequest request) async* {
    yield const AiTextDelta('我计划：先创建便签，再清理失效元素。');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    yield const AiToolCallDelta(
      index: 0,
      id: 'call_1',
      name: 'element_create',
      argumentsDelta: '{"elements":[{"id":"g1","type":"note","label":"痛点",'
          '"position":{"x":10,"y":20},',
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    yield const AiToolCallDelta(
      index: 0,
      argumentsDelta: '"size":{"width":120,"height":80}},'
          '{"id":"g2","type":"note","label":"场景",'
          '"position":{"x":150,"y":20},"size":{"width":120,"height":80}}]}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    yield const AiToolCallDelta(
      index: 1,
      id: 'call_2',
      name: 'element_delete',
      argumentsDelta: '{"ids":["e1"]}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    yield const AiStreamDone();
  }
}

/// 测试级状态组合（演示板 `b1`，页面 `b1-page-1`）。
class _Harness {
  _Harness({AiProvider? provider}) {
    ffi = _demoFfi();
    aiService = WbAiAppService(ffi: ffi);
    if (provider != null) {
      aiService.configure(provider);
    }
    ai = WbAiState(aiService: aiService);
    board = WbBoardState(ffi: ffi)..open('b1', name: '测试白板');
    pages = WbPageState(ffi: ffi)..attach(board.board!);
    selection = WbSelectionState();
  }

  late final WbFfiService ffi;
  late final WbAiAppService aiService;
  late final WbAiState ai;
  late final WbBoardState board;
  late final WbPageState pages;
  late final WbSelectionState selection;

  void dispose() {
    selection.dispose();
    pages.dispose();
    board.dispose();
    ai.dispose();
  }
}

/// 泵出带 Provider 环境的 AI 面板（360 逻辑像素宽，竖长视口）。
Future<_Harness> _pumpPanel(
  WidgetTester tester, {
  AiProvider? provider,
}) async {
  final _Harness harness = _Harness(provider: provider);
  tester.view.physicalSize = const Size(560, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(harness.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WbAiState>.value(value: harness.ai),
        ChangeNotifierProvider<WbSelectionState>.value(
          value: harness.selection,
        ),
        ChangeNotifierProvider<WbPageState>.value(value: harness.pages),
        Provider<WbFfiService>.value(value: harness.ffi),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SizedBox(width: 360, child: AiPanel())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

/// 输入文本并发送，等待一轮流式回复结束。
Future<void> _runTurn(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('ai.panel.input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const Key('ai.panel.send')));
  await tester.pump();
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
  await tester.pumpAndSettle();
}

/// 发送 `Ctrl + K`（按下 control → keyK → 松开 control）。
Future<void> _sendCtrlK(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

void main() {
  group('AI 面板交互（widget）', () {
    testWidgets('对话流：流式打字机、时间与状态', (WidgetTester tester) async {
      final _Harness h = await _pumpPanel(tester, provider: _StreamProvider());
      await tester.enterText(find.byKey(const Key('ai.panel.input')), '你好');
      await tester.pump();
      await tester.tap(find.byKey(const Key('ai.panel.send')));
      await tester.pump();
      await tester.pump();

      // 流式首帧：追加光标 ▍ 与「生成中」。
      expect(find.textContaining('▍'), findsOneWidget);
      expect(find.text('生成中'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpAndSettle();

      expect(find.text('好的，我来处理。'), findsOneWidget);
      expect(find.textContaining('▍'), findsNothing);
      expect(find.byKey(const Key('ai.panel.bubble.time')), findsWidgets);
      expect(h.ai.messages.length, 2);
      expect(h.ai.isStreaming, isFalse);
    });

    testWidgets('未配置提供商：空态引导与降级系统消息', (WidgetTester tester) async {
      final _Harness h = await _pumpPanel(tester);
      expect(find.text('AI 助手'), findsOneWidget);
      expect(find.text('尚未配置 AI 提供商'), findsOneWidget);
      expect(find.byKey(const Key('ai.panel.statusDot')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('ai.panel.input')), '你好');
      await tester.pump();
      await tester.tap(find.byKey(const Key('ai.panel.send')));
      await tester.pumpAndSettle();

      expect(
        find.text('AI 提供商未配置：请在「设置」中选择模型服务后再试。'),
        findsOneWidget,
      );
      expect(h.ai.messages.single.role, AiRoles.system);
      expect(tester.takeException(), isNull);
    });

    testWidgets('执行卡片：渲染、参数预览与批量执行', (WidgetTester tester) async {
      final _Harness h = await _pumpPanel(tester, provider: _ToolCallProvider());
      await _runTurn(tester, '整理便签');

      expect(find.text('执行计划'), findsOneWidget);
      expect(find.text('element_create'), findsOneWidget);
      expect(find.text('element_delete'), findsOneWidget);
      expect(find.text('待确认'), findsNWidgets(2));
      expect(find.text('需预览'), findsOneWidget);
      expect(find.text('需确认'), findsOneWidget);
      expect(find.text('全部执行'), findsOneWidget);

      // 参数预览展开 / 收起。
      await tester.tap(find.byKey(const Key('ai.panel.toolcall.call_1.args')));
      await tester.pump();
      expect(find.textContaining('"type": "note"'), findsOneWidget);
      expect(find.text('收起参数'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ai.panel.toolcall.call_1.args')));
      await tester.pump();
      expect(find.textContaining('"type": "note"'), findsNothing);
      expect(find.text('参数预览'), findsNWidgets(2));

      // 批量执行。
      await tester.tap(find.byKey(const Key('ai.panel.plan.approveAll')));
      await tester.pumpAndSettle();
      expect(find.text('✓ 已执行'), findsNWidgets(2));
      expect(h.ai.hasPendingToolCalls, isFalse);
    });

    testWidgets('幽灵预览：生成、执行回填结果与撤销', (WidgetTester tester) async {
      final _Harness h = await _pumpPanel(tester, provider: _ToolCallProvider());
      await _runTurn(tester, '整理便签');

      await tester.tap(find.byKey(const Key('ai.panel.toolcall.call_1.preview')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ai.panel.ghostBanner')), findsOneWidget);
      expect(find.text('幽灵预览：2 个元素（半透明，未落盘）'), findsOneWidget);
      expect(find.text('幽灵预览已生成，等待确认'), findsOneWidget);
      expect(h.ai.isToolCallPreviewed('call_1'), isTrue);
      expect(h.ai.ghostElements.length, 2);
      final WbGhostElement first = h.ai.ghostElements.first;
      expect(first.type, 'note');
      expect(first.x, 10.0);
      expect(first.width, 120.0);
      expect(h.ai.ghostElements.last.label, '场景');

      // 执行：幽灵清除、结果摘要回填、可撤销。
      await tester.tap(find.byKey(const Key('ai.panel.toolcall.call_1.approve')));
      await tester.pumpAndSettle();
      expect(find.text('✓ 已执行'), findsOneWidget);
      expect(find.text('已执行 element_create（影响 2 个元素）'), findsOneWidget);
      expect(h.ai.ghostElements, isEmpty);
      expect(find.byKey(const Key('ai.panel.ghostBanner')), findsNothing);
      final Finder undoFinder =
          find.byKey(const Key('ai.panel.toolcall.call_1.undo'));
      expect(undoFinder, findsOneWidget);

      // 事务级撤销。
      await tester.tap(undoFinder);
      await tester.pumpAndSettle();
      expect(h.ai.isToolCallReverted('call_1'), isTrue);
      expect(find.text('已撤销'), findsOneWidget);
      expect(find.text('已撤销：element_create'), findsOneWidget);
      expect(undoFinder, findsNothing);
    });

    testWidgets('执行卡片：拒绝后取消并可继续处理其余调用', (WidgetTester tester) async {
      final _Harness h = await _pumpPanel(tester, provider: _ToolCallProvider());
      await _runTurn(tester, '整理便签');

      await tester.tap(find.byKey(const Key('ai.panel.toolcall.call_2.reject')));
      await tester.pumpAndSettle();
      expect(h.ai.toolCallById('call_2')!.status, AiToolCallStatus.cancelled);
      expect(find.text('已取消'), findsOneWidget);
      expect(find.byKey(const Key('ai.panel.toolcall.call_2.undo')), findsNothing);
      expect(
        find.byKey(const Key('ai.panel.toolcall.call_2.approve')),
        findsNothing,
      );
      expect(find.text('待确认'), findsOneWidget);
      expect(find.text('全部执行'), findsNothing);
    });

    testWidgets('幽灵预览：toJson 契约与手动清除', (WidgetTester tester) async {
      final _Harness h = await _pumpPanel(tester, provider: _ToolCallProvider());
      await _runTurn(tester, '整理便签');

      await tester.tap(find.byKey(const Key('ai.panel.toolcall.call_1.preview')));
      await tester.pumpAndSettle();
      final Map<String, dynamic> json = h.ai.ghostElements.first.toJson();
      expect(json['ghost'], isTrue);
      expect(json['type'], 'note');
      expect(json['opacity'], 0.35);
      expect(json['position'], <String, double>{'x': 10.0, 'y': 20.0});
      expect(json['size'], <String, double>{'width': 120.0, 'height': 80.0});

      await tester.tap(find.byKey(const Key('ai.panel.ghostClear')));
      await tester.pumpAndSettle();
      expect(h.ai.hasGhostPreview, isFalse);
      expect(find.byKey(const Key('ai.panel.ghostBanner')), findsNothing);
    });

    testWidgets('上下文引用：@ 元素选择器、芯片与发送上下文', (WidgetTester tester) async {
      final _Harness h = await _pumpPanel(tester, provider: _StreamProvider());

      // 无选区时给出提示。
      await tester.enterText(find.byKey(const Key('ai.panel.input')), '@');
      await tester.pump();
      expect(find.text('暂无选中元素（先在画布中选择）'), findsOneWidget);

      // 有选区后选择元素引用。
      h.selection.select(<String>['e1', 'e2']);
      await tester.pump();
      expect(find.byKey(const Key('ai.panel.suggestion.@e1')), findsOneWidget);
      expect(find.byKey(const Key('ai.panel.suggestion.@e2')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ai.panel.suggestion.@e1')));
      await tester.pump();
      expect(h.ai.contextRefs.single.id, 'e1');
      expect(h.ai.contextRefs.single.kind, WbContextRefKinds.element);
      expect(h.ai.contextRefs.single.token, '@e1');
      expect(
        find.byKey(const Key('ai.panel.ref.remove.element.e1')),
        findsOneWidget,
      );
      expect(_panelInputText(tester), '@e1 ');

      // 发送：引用并入选区上下文。
      h.selection.clear();
      await tester.pump();
      await tester.tap(find.byKey(const Key('ai.panel.send')));
      await tester.pump();
      for (int i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pumpAndSettle();
      expect(h.ai.lastContext, isNotNull);
      expect(h.ai.lastContext!.selection, <String>['e1']);
      expect(h.ai.lastContext!.scope, AiContextScope.selection);

      // 删除芯片。
      await tester.tap(find.byKey(const Key('ai.panel.ref.remove.element.e1')));
      await tester.pump();
      expect(h.ai.contextRefs, isEmpty);
    });

    testWidgets('上下文引用：# 页面选择器与发送上下文', (WidgetTester tester) async {
      final _Harness h = await _pumpPanel(tester, provider: _StreamProvider());

      await tester.tap(find.text('# 页面'));
      await tester.pump();
      expect(find.byKey(const Key('ai.panel.suggestion.#b1-page-1')), findsOneWidget);
      expect(find.text('页面引用'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ai.panel.suggestion.#b1-page-1')));
      await tester.pump();
      expect(h.ai.contextRefs.single.token, '#页面 1');
      expect(h.ai.contextRefs.single.kind, WbContextRefKinds.page);
      expect(
        find.byKey(const Key('ai.panel.ref.remove.page.b1-page-1')),
        findsOneWidget,
      );
      expect(_panelInputText(tester), '#页面 1 ');

      await tester.tap(find.byKey(const Key('ai.panel.send')));
      await tester.pump();
      for (int i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pumpAndSettle();
      expect(h.ai.lastContext!.pageId, 'b1-page-1');
      expect(h.ai.lastContext!.scope, AiContextScope.page);
    });

    testWidgets('语音状态视觉：录音 → 转写 → 文本回填', (WidgetTester tester) async {
      final _Harness h = await _pumpPanel(tester, provider: _StreamProvider());

      await tester.tap(find.byKey(const Key('ai.panel.mic')));
      await tester.pump();
      expect(h.ai.voice, WbVoicePhases.recording);
      expect(find.byKey(const Key('ai.panel.voiceStrip')), findsOneWidget);
      expect(find.text('语音：录音中'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ai.panel.mic')));
      await tester.pump();
      expect(h.ai.voice, WbVoicePhases.transcribing);
      expect(find.text('语音：转写中'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(h.ai.voice, '');
      expect(h.ai.voiceTranscript, '帮我把选中的便签按主题分组');
      expect(find.byKey(const Key('ai.panel.voiceStrip')), findsNothing);
      expect(_panelInputText(tester), '帮我把选中的便签按主题分组');

      // Alt+Space 按住说话链路（§4.1）。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(h.ai.voice, WbVoicePhases.transcribing);
      expect(find.text('语音：转写中'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(h.ai.voice, '');
      expect(find.byKey(const Key('ai.panel.voiceStrip')), findsNothing);
    });

    testWidgets('语音状态视觉：语音发起回合的播报状态', (WidgetTester tester) async {
      final _Harness h = await _pumpPanel(tester, provider: _StreamProvider());

      // 先完成一次语音转写（回合将由语音发起）。
      await tester.tap(find.byKey(const Key('ai.panel.mic')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('ai.panel.mic')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(h.ai.voice, '');

      await tester.tap(find.byKey(const Key('ai.panel.send')));
      await tester.pump();
      expect(h.ai.voice, WbVoicePhases.speaking);
      expect(find.text('语音：播报中'), findsOneWidget);

      for (int i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pump();
      expect(h.ai.voice, '');
      expect(find.byKey(const Key('ai.panel.voiceStrip')), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('命令面板：Ctrl+K 唤起、键盘导航执行与 Esc 关闭', (WidgetTester tester) async {
      final _Harness h = await _pumpPanel(tester, provider: _StreamProvider());

      // Ctrl+K 唤起。
      await _sendCtrlK(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('command_palette.input')), findsOneWidget);
      expect(find.text('全部命令'), findsOneWidget);
      expect(find.text('画流程图'), findsOneWidget);

      // ↓ 选中第二条（画流程图），Enter 执行 → 关闭并回填输入框。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('command_palette.input')), findsNothing);
      expect(_panelInputText(tester), '画一个流程：用户进入 → 浏览白板 → 导出分享');
      expect(h.ai.messages, isEmpty);

      // 再次唤起：新命令进入「最近使用」。
      await _sendCtrlK(tester);
      await tester.pumpAndSettle();
      expect(find.text('最近使用'), findsOneWidget);
      expect(
        find.byKey(const Key('command_palette.item.ai.flowchart.create')),
        findsOneWidget,
      );

      // Esc 关闭（组件与框架协同，不误关下层面板）。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('command_palette.input')), findsNothing);
      expect(find.byKey(const Key('ai.panel.input')), findsOneWidget);
    });

    testWidgets('命令面板组件：模糊搜索与点击执行', (WidgetTester tester) async {
      final List<String> executed = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommandPalette(
              recentIds: const <String>['ai.cluster'],
              onCommand: (WbCommand command) => executed.add(command.id),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('最近使用'), findsOneWidget);
      expect(find.text('全部命令'), findsOneWidget);
      expect(find.text('按主题分组'), findsOneWidget);

      // 无匹配空态。
      await tester.enterText(
        find.byKey(const Key('command_palette.input')),
        'qqzz',
      );
      await tester.pump();
      expect(find.text('无匹配命令'), findsOneWidget);

      // 中文模糊搜索 + Enter 执行。
      await tester.enterText(
        find.byKey(const Key('command_palette.input')),
        '分组',
      );
      await tester.pump();
      expect(
        find.byKey(const Key('command_palette.item.ai.cluster')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('command_palette.item.ai.note.create')),
        findsNothing,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(executed, <String>['ai.cluster']);

      // 清空查询后点击执行。
      await tester.enterText(
        find.byKey(const Key('command_palette.input')),
        '',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('command_palette.item.ai.note.create')),
      );
      await tester.pump();
      expect(executed, <String>['ai.cluster', 'ai.note.create']);
    });
  });

  group('命令面板与模型（unit）', () {
    test('wbFuzzyScore 与 filterCommands 行为', () {
      expect(wbFuzzyScore('note', 'ai.note.create'), isNotNull);
      expect(wbFuzzyScore('xyz', 'ai.note.create'), isNull);
      expect(wbFuzzyScore('', 'anything'), 0);
      expect(wbFuzzyScore('note', ''), isNull);

      expect(filterCommands(WbCommandCatalog.defaults, '').length, 13);
      expect(
        filterCommands(WbCommandCatalog.defaults, '分组').first.id,
        'ai.cluster',
      );
      expect(filterCommands(WbCommandCatalog.defaults, 'qqzzxx'), isEmpty);
      final int builtinCount = WbCommandCatalog.defaults
          .where((WbCommand command) => command.isBuiltin)
          .length;
      expect(builtinCount, 6);
    });

    test('WbToolCallPolicy 确认级别推断与标签', () {
      expect(
        WbToolCallPolicy.inferConfirmLevel('element_delete'),
        AiConfirmLevels.confirm,
      );
      expect(
        WbToolCallPolicy.inferConfirmLevel('board_share'),
        AiConfirmLevels.confirm,
      );
      expect(
        WbToolCallPolicy.inferConfirmLevel('element_create'),
        AiConfirmLevels.preview,
      );
      expect(
        WbToolCallPolicy.inferConfirmLevel('viewport_get'),
        AiConfirmLevels.auto,
      );
      expect(WbToolCallPolicy.inferConfirmLevel(''), AiConfirmLevels.auto);
      expect(WbToolCallPolicy.label(AiConfirmLevels.confirm), '需确认');
      expect(WbToolCallPolicy.label(AiConfirmLevels.preview), '需预览');
      expect(WbToolCallPolicy.label(AiConfirmLevels.auto), '自动');
    });

    test('WbAiState 工具调用链路：预览 / 执行 / 撤销 / 拒绝', () async {
      final _Harness h = _Harness(provider: _ToolCallProvider());
      addTearDown(h.dispose);
      await h.ai.send('开始');

      expect(h.ai.messages.length, 2);
      expect(h.ai.toolCalls.length, 2);
      expect(h.ai.hasPendingToolCalls, isTrue);
      expect(
        h.ai.toolCallById('call_1')!.confirmLevel,
        AiConfirmLevels.preview,
      );
      expect(h.ai.toolCallById('call_2')!.confirmLevel, AiConfirmLevels.confirm);

      h.ai.previewToolCall('call_1');
      expect(h.ai.ghostElements.length, 2);
      expect(h.ai.ghostElements.first.id, 'g1');
      expect(h.ai.ghostElements.first.sourceCallId, 'call_1');

      await h.ai.approveToolCall('call_1');
      final AiToolCall approved = h.ai.toolCallById('call_1')!;
      expect(approved.isSuccess, isTrue);
      expect(approved.result['affected'], 2);
      expect(approved.result['simulated'], isTrue);
      expect(h.ai.ghostElements, isEmpty);
      expect(h.aiService.client!.messages.last.role, AiRoles.tool);

      h.ai.undoToolCall('call_1');
      expect(h.ai.isToolCallReverted('call_1'), isTrue);
      expect(h.ai.messages.last.content, '已撤销：element_create');

      h.ai.rejectToolCall('call_2');
      expect(h.ai.toolCallById('call_2')!.status, AiToolCallStatus.cancelled);
      expect(h.ai.hasPendingToolCalls, isFalse);
    });

    test('WbGhostElement toJson 契约（画布侧消费面）', () async {
      final _Harness h = _Harness(provider: _ToolCallProvider());
      addTearDown(h.dispose);
      await h.ai.send('开始');
      h.ai.previewToolCall('call_1');

      expect(h.ai.ghostElements.length, 2);
      final Map<String, dynamic> json = h.ai.ghostElements.first.toJson();
      expect(json['id'], 'g1');
      expect(json['type'], 'note');
      expect(json['label'], '痛点');
      expect(json['ghost'], isTrue);
      expect(json['opacity'], 0.35);
      expect(json['position'], <String, double>{'x': 10.0, 'y': 20.0});
      expect(json['size'], <String, double>{'width': 120.0, 'height': 80.0});
    });
  });
}
