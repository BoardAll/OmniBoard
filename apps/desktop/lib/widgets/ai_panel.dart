/// AI 助手面板：上下文控制 / 对话流 / 执行卡片 / 幽灵预览 / 语音视觉 / 输入区。
///
/// 对应《AI 助手与 MCP 设计》§4（AI 助手）、§8（交互设计）：
/// - 对话流：气泡 + 流式打字机（走 `ai_service` 流，未配置时降级系统提示）；
/// - 执行卡片：工具调用确认 / 拒绝 / 参数预览与撤销（§8.2）；
/// - 幽灵预览：`ai_state` 中暴露数据，画布侧后续消费（§8.3，不修改画布）；
/// - 上下文：@"元素"、#"页面" 引用芯片与选择器、读取授权开关（§4.4）；
/// - 语音视觉：录音 / 转写 / 播报状态指示（§4.6，不做真实音频）；
/// - 命令面板：`Cmd/Ctrl + K` 唤起（§8.1）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_ai/ai_client.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import '../routes.dart';
import '../state/ai_state.dart';
import '../state/page_state.dart';
import '../state/selection_state.dart';
import 'command_palette.dart';
import 'guide/help_center.dart';
import 'guide/onboarding_overlay.dart';
import 'guide/shortcut_card_dialog.dart';

/// AI 助手面板（保持可无参 `const` 构造）。
class AiPanel extends StatefulWidget {
  const AiPanel({super.key});

  @override
  State<AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<AiPanel> {
  /// 语音转写模拟文本（视觉链路无真实音频）。
  static const String _simulatedTranscript = '帮我把选中的便签按主题分组';

  /// 输入尾部的 @#/ 触发片段（如 `@e1`、`#页面`、`/创建`）。
  static final RegExp _sigilPattern = RegExp(r'([@#/])([^\s@#/]*)$');

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode(debugLabel: 'ai_panel_input');
  WbAiState? _ai;
  List<String> _recentCommands = <String>[];
  bool _paletteOpen = false;
  Timer? _voiceTimer;
  bool _voiceInitiatedTurn = false;
  String _suggestionKind = '';
  String _suggestionQuery = '';

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final WbAiState ai = context.read<WbAiState>();
    if (!identical(_ai, ai)) {
      _ai?.removeListener(_onAiChanged);
      _ai = ai..addListener(_onAiChanged);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _voiceTimer?.cancel();
    _ai?.removeListener(_onAiChanged);
    _controller.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onAiChanged() {
    if (mounted) {
      _scrollToBottom();
    }
  }

  /// 全局硬件键处理：⌘/Ctrl+K 唤起命令面板；Alt+Space 按住说话（§4.1）。
  bool _onKeyEvent(KeyEvent event) {
    if (!mounted) {
      return false;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool primary = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (primary && event.logicalKey == LogicalKeyboardKey.keyK) {
      if (event is KeyDownEvent) {
        // 面板已打开时由命令面板自身处理（再次 ⌘K 关闭）。
        if (_paletteOpen) {
          return false;
        }
        _openCommandPalette();
        return true;
      }
      return false;
    }
    if (event.logicalKey == LogicalKeyboardKey.space && keyboard.isAltPressed) {
      final WbAiState ai = context.read<WbAiState>();
      if (event is KeyDownEvent && !ai.isVoiceActive) {
        _startVoice();
        return true;
      }
      if (event is KeyUpEvent && ai.voice == WbVoicePhases.recording) {
        _stopVoice();
        return true;
      }
    }
    return false;
  }

  // ---- 命令面板（§8.1） ----

  void _openCommandPalette() {
    if (_paletteOpen || !mounted) {
      return;
    }
    _paletteOpen = true;
    unawaited(
      showCommandPalette(
        context,
        recentIds: _recentCommands,
        onCommand: _runCommand,
      ).whenComplete(() {
        _paletteOpen = false;
      }),
    );
  }

  void _runCommand(WbCommand command) {
    final WbAiState ai = context.read<WbAiState>();
    _recentCommands = <String>[
      command.id,
      ..._recentCommands.where((String id) => id != command.id),
    ].take(6).toList(growable: false);
    switch (command.builtin) {
      case WbCommandCatalog.builtinReset:
        ai.reset();
        break;
      case WbCommandCatalog.builtinVoice:
        if (ai.isVoiceActive) {
          _cancelVoice();
        } else {
          _startVoice();
        }
        break;
      case WbCommandCatalog.builtinSettings:
        context.push(WbRoutes.settingsPath);
        break;
      case WbCommandCatalog.builtinHelpCenter:
        unawaited(showHelpCenter(context));
        break;
      case WbCommandCatalog.builtinOnboarding:
        unawaited(showOnboardingOverlay(context));
        break;
      case WbCommandCatalog.builtinShortcuts:
        unawaited(showShortcutCard(context));
        break;
      default:
        break;
    }
    if (command.prompt.isNotEmpty) {
      _insertText(command.prompt);
    }
  }

  // ---- 语音视觉（§4.6，纯视觉模拟） ----

  void _startVoice() {
    final WbAiState ai = context.read<WbAiState>();
    if (ai.isStreaming) {
      return;
    }
    _voiceTimer?.cancel();
    ai.startVoiceRecording();
  }

  void _stopVoice() {
    final WbAiState ai = context.read<WbAiState>();
    if (ai.voice != WbVoicePhases.recording &&
        ai.voice != AiVoiceStates.listening) {
      return;
    }
    ai.stopVoiceRecording();
    _voiceTimer?.cancel();
    _voiceTimer = Timer(const Duration(milliseconds: 650), () {
      if (!mounted) {
        return;
      }
      final WbAiState state = context.read<WbAiState>();
      state.completeVoiceTranscription(_simulatedTranscript);
      _voiceInitiatedTurn = true;
      _insertText(_simulatedTranscript);
    });
  }

  void _cancelVoice() {
    _voiceTimer?.cancel();
    context.read<WbAiState>().cancelVoice();
  }

  void _onMicPressed() {
    final WbAiState ai = context.read<WbAiState>();
    if (ai.voice == WbVoicePhases.recording ||
        ai.voice == AiVoiceStates.listening) {
      _stopVoice();
    } else if (ai.isVoiceActive) {
      _cancelVoice();
    } else {
      _startVoice();
    }
  }

  // ---- 输入与 @#/ 语法提示 ----

  void _setInput(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _onInputChanged(text);
  }

  void _insertText(String text) {
    final String current = _controller.text;
    final String next = current.isEmpty ? text : '$current$text';
    _setInput(next);
    _inputFocus.requestFocus();
  }

  void _onInputChanged(String value) {
    final RegExpMatch? match = _sigilPattern.firstMatch(value);
    setState(() {
      _suggestionKind = match?.group(1) ?? '';
      _suggestionQuery = match?.group(2) ?? '';
    });
  }

  List<_Suggestion> _buildSuggestions(
    WbSelectionState selection,
    WbPageState pages,
  ) {
    if (_suggestionKind.isEmpty) {
      return const <_Suggestion>[];
    }
    final String query = _suggestionQuery.toLowerCase();
    final List<_Suggestion> out = <_Suggestion>[];
    switch (_suggestionKind) {
      case '@':
        for (final String id in selection.ids) {
          if (query.isEmpty || id.toLowerCase().contains(query)) {
            out.add(_Suggestion(
              kind: '@',
              id: id,
              label: id,
              subtitle: '元素引用',
            ));
            if (out.length >= 6) {
              break;
            }
          }
        }
        if (out.isEmpty) {
          out.add(const _Suggestion.hint('暂无选中元素（先在画布中选择）'));
        }
      case '#':
        for (final page in pages.pages) {
          if (query.isEmpty || page.name.toLowerCase().contains(query)) {
            out.add(_Suggestion(
              kind: '#',
              id: page.id,
              label: page.name,
              subtitle: '页面引用',
            ));
            if (out.length >= 6) {
              break;
            }
          }
        }
        if (out.isEmpty) {
          out.add(const _Suggestion.hint('暂无页面可引用'));
        }
      case '/':
        final List<WbCommand> commands =
            filterCommands(WbCommandCatalog.defaults, _suggestionQuery);
        for (final WbCommand command in commands) {
          out.add(_Suggestion(
            kind: '/',
            id: command.id,
            label: command.title,
            subtitle: command.subtitle,
            command: command,
          ));
          if (out.length >= 6) {
            break;
          }
        }
        if (out.isEmpty) {
          out.add(const _Suggestion.hint('无匹配指令'));
        }
      default:
        break;
    }
    return out;
  }

  void _applySuggestion(_Suggestion suggestion) {
    if (!suggestion.enabled) {
      return;
    }
    final WbAiState ai = context.read<WbAiState>();
    final String text = _controller.text;
    final RegExpMatch? match = _sigilPattern.firstMatch(text);
    final String base = match == null ? text : text.substring(0, match.start);
    if (suggestion.kind == '/') {
      final WbCommand? command = suggestion.command;
      if (command == null) {
        return;
      }
      if (command.isBuiltin) {
        _setInput(base);
        _runCommand(command);
        return;
      }
      _setInput('$base${command.prompt}');
      _inputFocus.requestFocus();
      return;
    }
    ai.addContextRef(WbContextRef(
      kind: suggestion.kind == '@'
          ? WbContextRefKinds.element
          : WbContextRefKinds.page,
      id: suggestion.id,
      label: suggestion.label,
    ));
    _setInput('$base${suggestion.kind}${suggestion.label} ');
    _inputFocus.requestFocus();
  }

  void _removeRef(WbContextRef ref) {
    final WbAiState ai = context.read<WbAiState>();
    ai.removeContextRef(ref);
    if (_controller.text.contains(ref.token)) {
      _setInput(_controller.text.replaceFirst(ref.token, ''));
    }
  }

  // ---- 发送与滚动 ----

  Future<void> _send() async {
    final WbAiState ai = context.read<WbAiState>();
    final WbPageState pages = context.read<WbPageState>();
    final WbSelectionState selection = context.read<WbSelectionState>();
    final String text = _controller.text;
    if (text.trim().isEmpty) {
      return;
    }
    _controller.clear();
    _suggestionKind = '';
    _suggestionQuery = '';
    ai.updateSessionContext(
      boardId: pages.boardId,
      pageId: pages.currentPageId,
      selection: selection.ids.toList(),
    );
    final bool voiceTurn = _voiceInitiatedTurn;
    _voiceInitiatedTurn = false;
    final Future<void> turn = ai.send(text);
    if (voiceTurn) {
      ai.startSpeaking();
      await turn;
      if (!mounted) {
        return;
      }
      ai.stopSpeaking();
    } else {
      await turn;
      if (!mounted) {
        return;
      }
    }
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final WbAiState ai = context.watch<WbAiState>();
    final WbSelectionState selection = context.watch<WbSelectionState>();
    final WbPageState pages = context.watch<WbPageState>();
    final List<AiMessage> messages = ai.messages;
    final List<_Suggestion> suggestions = _buildSuggestions(selection, pages);

    final List<Widget> bubbles = <Widget>[
      for (final AiMessage message in messages) ...<Widget>[
        _MessageBubble(message: message),
        if (message.toolCalls.isNotEmpty)
          _ExecutionPlan(ai: ai, calls: message.toolCalls),
      ],
      if (ai.isStreaming)
        _MessageBubble(
          message: AiMessage.assistant(ai.streamingText),
          streaming: true,
        ),
      if (ai.error.isNotEmpty) _ErrorBar(message: ai.error),
    ];

    return ColoredBox(
      color: colors.surface,
      child: Column(
        children: <Widget>[
          _buildHeader(context, ai, colors),
          _buildContextBar(context, ai, selection, pages, colors),
          if (ai.hasGhostPreview)
            _GhostBanner(
              count: ai.ghostElements.length,
              onClear: ai.clearGhostPreview,
            ),
          const SizedBox(height: 8),
          // 消息流。
          Expanded(
            child: bubbles.isEmpty
                ? _EmptyHint(configured: ai.isConfigured)
                : ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: bubbles,
                  ),
          ),
          _buildInputArea(context, ai, colors, suggestions),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    WbAiState ai,
    WbThemeColors colors,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        children: <Widget>[
          Icon(LinearIcons.ai, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: <Widget>[
                Text(
                  'AI 助手',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 6),
                Tooltip(
                  message: ai.isConfigured
                      ? '已配置：${ai.aiService.provider?.id ?? ''}'
                      : '未配置 AI 提供商',
                  child: Container(
                    key: const Key('ai.panel.statusDot'),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ai.isConfigured
                          ? Colors.green
                          : colors.border,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('ai.panel.commands'),
            tooltip: '命令面板（Ctrl+K）',
            icon: Icon(LinearIcons.search, size: 18, color: colors.icon),
            onPressed: _openCommandPalette,
          ),
          IconButton(
            tooltip: '清空对话',
            icon: Icon(LinearIcons.refresh, size: 18, color: colors.icon),
            onPressed: ai.messages.isEmpty &&
                    ai.error.isEmpty &&
                    ai.toolCalls.isEmpty
                ? null
                : ai.reset,
          ),
        ],
      ),
    );
  }

  Widget _buildContextBar(
    BuildContext context,
    WbAiState ai,
    WbSelectionState selection,
    WbPageState pages,
    WbThemeColors colors,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: colors.canvas,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: colors.border),
            ),
            child: Text(
              '上下文：${pages.currentPage?.name ?? '未打开页面'}'
              '${selection.hasSelection ? ' · 已选 ${selection.count} 个元素' : ''}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.icon),
            ),
          ),
          if (ai.contextRefs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: <Widget>[
                  for (final WbContextRef ref in ai.contextRefs)
                    _ContextRefChip(
                      ref: ref,
                      onRemove: () => _removeRef(ref),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: <Widget>[
                _InputAction(
                  label: '@ 元素',
                  tooltip: '引用元素（@）',
                  onTap: () => _insertText('@'),
                ),
                const SizedBox(width: 10),
                _InputAction(
                  label: '# 页面',
                  tooltip: '引用页面（#）',
                  onTap: () => _insertText('#'),
                ),
                const SizedBox(width: 10),
                _InputAction(
                  label: '/ 指令',
                  tooltip: '快捷指令（/）',
                  onTap: () => _insertText('/'),
                ),
                const Spacer(),
                PopupMenuButton<String>(
                  key: const Key('ai.panel.contextPermissions'),
                  tooltip: '上下文读取授权',
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    LinearIcons.permission,
                    size: 16,
                    color: ai.allowComments || ai.allowImageOcr
                        ? colors.primary
                        : colors.icon,
                  ),
                  itemBuilder: (BuildContext context) =>
                      <PopupMenuEntry<String>>[
                    CheckedPopupMenuItem<String>(
                      value: 'comments',
                      checked: ai.allowComments,
                      child: const Text('允许读取评论'),
                    ),
                    CheckedPopupMenuItem<String>(
                      value: 'ocr',
                      checked: ai.allowImageOcr,
                      child: const Text('允许读取图片 OCR'),
                    ),
                  ],
                  onSelected: (String value) {
                    final WbAiState state = context.read<WbAiState>();
                    switch (value) {
                      case 'comments':
                        state.setAllowComments(!state.allowComments);
                      case 'ocr':
                        state.setAllowImageOcr(!state.allowImageOcr);
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea(
    BuildContext context,
    WbAiState ai,
    WbThemeColors colors,
    List<_Suggestion> suggestions,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (ai.isVoiceActive)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _VoiceStrip(
                voice: ai.voice,
                label: ai.voiceLabel,
                onStop: _onMicPressed,
              ),
            ),
          if (suggestions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _SuggestionPanel(
                suggestions: suggestions,
                onSelect: _applySuggestion,
              ),
            ),
          Container(
            decoration: BoxDecoration(
              color: colors.canvas,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.border),
            ),
            padding: const EdgeInsets.fromLTRB(10, 2, 6, 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  key: const Key('ai.panel.input'),
                  controller: _controller,
                  focusNode: _inputFocus,
                  minLines: 1,
                  maxLines: 5,
                  onChanged: _onInputChanged,
                  onSubmitted: (String value) => _send(),
                  decoration: InputDecoration(
                    hintText: ai.isConfigured
                        ? '让 AI 帮你编辑白板…（@ 引用元素、# 引用页面、/ 指令）'
                        : '请先在「设置」中配置 AI 提供商',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Enter 发送 · Shift+Enter 换行',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: colors.icon, fontSize: 10),
                      ),
                    ),
                    IconButton(
                      key: const Key('ai.panel.mic'),
                      tooltip: switch (ai.voice) {
                        WbVoicePhases.recording => '停止录音',
                        WbVoicePhases.transcribing => '取消转写',
                        WbVoicePhases.speaking => '打断播报',
                        _ => '语音输入（视觉模拟）',
                      },
                      onPressed: _onMicPressed,
                      icon: Icon(
                        ai.voice == WbVoicePhases.recording ||
                                ai.voice == AiVoiceStates.listening
                            ? LinearIcons.stop
                            : LinearIcons.mic,
                        color: ai.isVoiceActive ? colors.primary : colors.icon,
                      ),
                    ),
                    IconButton(
                      key: const Key('ai.panel.send'),
                      tooltip: '发送',
                      onPressed: ai.isStreaming ? null : _send,
                      icon: Icon(LinearIcons.send, color: colors.primary),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 消息气泡（用户右对齐 / 助手左对齐 / 系统提示居中 / 工具结果紧凑行）。
///
/// 时间与状态展示：`HH:mm`、流式期间追加 `▍` 光标与「生成中」。
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, this.streaming = false});

  final AiMessage message;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    final bool isUser = message.role == AiRoles.user;

    if (message.role == AiRoles.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(LinearIcons.info, size: 14, color: colors.icon),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                message.content,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.icon),
              ),
            ),
          ],
        ),
      );
    }

    if (message.role == AiRoles.tool) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(LinearIcons.check, size: 12, color: colors.icon),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '工具结果：${message.content}',
                style: theme.textTheme.bodySmall?.copyWith(color: colors.icon),
              ),
            ),
          ],
        ),
      );
    }

    final String text = message.content.isEmpty && streaming
        ? '思考中…'
        : streaming
            ? '${message.content}▍'
            : message.content;
    final String time = _formatClock(message.timestamp);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              constraints: const BoxConstraints(maxWidth: 240),
              decoration: BoxDecoration(
                color: isUser ? colors.primary : colors.cardBackground,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(10),
                  topRight: const Radius.circular(10),
                  bottomLeft: Radius.circular(isUser ? 10 : 2),
                  bottomRight: Radius.circular(isUser ? 2 : 10),
                ),
                border: Border.all(
                  color: isUser ? colors.primary : colors.cardBorder,
                ),
              ),
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isUser ? theme.colorScheme.onPrimary : null,
                ),
              ),
            ),
            if (time.isNotEmpty || streaming)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  streaming
                      ? (time.isEmpty ? '生成中' : '$time · 生成中')
                      : time,
                  key: const Key('ai.panel.bubble.time'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: colors.icon, fontSize: 10),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 执行计划：一组工具调用的卡片集合（§8.2）。
class _ExecutionPlan extends StatelessWidget {
  const _ExecutionPlan({required this.ai, required this.calls});

  final WbAiState ai;
  final List<AiToolCall> calls;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    final List<AiToolCall> pending = <AiToolCall>[];
    for (final AiToolCall call in calls) {
      final AiToolCall resolved = ai.toolCallById(call.id) ?? call;
      if (resolved.isPending) {
        pending.add(resolved);
      }
    }
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(LinearIcons.ai, size: 12, color: colors.primary),
              const SizedBox(width: 4),
              Text(
                '执行计划',
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (pending.length > 1) ...<Widget>[
                const Spacer(),
                TextButton(
                  key: const Key('ai.panel.plan.approveAll'),
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () {
                    for (final AiToolCall call in pending) {
                      unawaited(ai.approveToolCall(call.id));
                    }
                  },
                  child: const Text('全部执行'),
                ),
              ],
            ],
          ),
          for (final AiToolCall call in calls)
            _ToolCallCard(ai: ai, call: ai.toolCallById(call.id) ?? call),
        ],
      ),
    );
  }
}

/// 工具调用执行卡片：标题 / 确认级别 / 状态 / 参数预览 / 动作按钮（§8.2）。
class _ToolCallCard extends StatefulWidget {
  const _ToolCallCard({required this.ai, required this.call});

  final WbAiState ai;
  final AiToolCall call;

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  bool _showArgs = false;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    final WbAiState ai = widget.ai;
    final AiToolCall call = widget.call;
    final bool reverted = ai.isToolCallReverted(call.id);
    final bool previewed = ai.isToolCallPreviewed(call.id);
    final String title = call.name.isNotEmpty
        ? call.name
        : (call.toolId.isNotEmpty ? call.toolId : '工具调用');

    final String statusLabel;
    final Color statusColor;
    if (reverted) {
      statusLabel = '已撤销';
      statusColor = colors.icon;
    } else if (call.isPending) {
      statusLabel = '待确认';
      statusColor = colors.primary;
    } else if (call.isSuccess) {
      statusLabel = '✓ 已执行';
      statusColor = Colors.green;
    } else if (call.isError) {
      statusLabel = '执行失败';
      statusColor = Colors.red;
    } else {
      statusLabel = '已取消';
      statusColor = colors.icon;
    }
    final String summary = call.result['summary'] is String
        ? call.result['summary'] as String
        : '';

    return Container(
      key: Key('ai.panel.toolcall.${call.id}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.cardBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: call.isPending
              ? colors.primary.withValues(alpha: 0.5)
              : colors.cardBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(LinearIcons.shape, size: 14, color: colors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              _StatusBadge(
                label: WbToolCallPolicy.label(call.confirmLevel),
                color: colors.icon,
              ),
              const SizedBox(width: 4),
              _StatusBadge(label: statusLabel, color: statusColor),
            ],
          ),
          const SizedBox(height: 6),
          if (_showArgs)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: colors.canvas,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                const JsonEncoder.withIndent('  ').convert(call.arguments),
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontSize: 10, fontFamily: 'monospace'),
              ),
            )
          else
            Text(
              _compactArgs(call),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colors.icon, fontSize: 11),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: Key('ai.panel.toolcall.${call.id}.args'),
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () {
                setState(() {
                  _showArgs = !_showArgs;
                });
              },
              child: Text(_showArgs ? '收起参数' : '参数预览'),
            ),
          ),
          if (previewed && call.isPending)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '幽灵预览已生成，等待确认',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colors.primary, fontSize: 11),
              ),
            ),
          if (summary.isNotEmpty && call.isSuccess && !reverted)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: <Widget>[
                  const Icon(LinearIcons.check, size: 12, color: Colors.green),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      summary,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colors.icon, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          if (call.isError && call.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                call.error,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.red, fontSize: 11),
              ),
            ),
          const SizedBox(height: 2),
          _buildActions(context, ai, call, reverted),
        ],
      ),
    );
  }

  Widget _buildActions(
    BuildContext context,
    WbAiState ai,
    AiToolCall call,
    bool reverted,
  ) {
    if (call.isPending) {
      return Wrap(
        alignment: WrapAlignment.end,
        spacing: 4,
        children: <Widget>[
          if (call.confirmLevel != AiConfirmLevels.auto)
            TextButton(
              key: Key('ai.panel.toolcall.${call.id}.preview'),
              style: _actionStyle,
              onPressed: () => ai.previewToolCall(call.id),
              child: const Text('预览'),
            ),
          TextButton(
            key: Key('ai.panel.toolcall.${call.id}.approve'),
            style: _actionStyle,
            onPressed: () => unawaited(ai.approveToolCall(call.id)),
            child: Text(
              call.confirmLevel == AiConfirmLevels.confirm ? '确认执行' : '执行',
            ),
          ),
          TextButton(
            key: Key('ai.panel.toolcall.${call.id}.reject'),
            style: _actionStyle,
            onPressed: () => ai.rejectToolCall(call.id),
            child: const Text('取消'),
          ),
        ],
      );
    }
    if (call.isSuccess && !reverted) {
      return Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          key: Key('ai.panel.toolcall.${call.id}.undo'),
          style: _actionStyle,
          onPressed: () => ai.undoToolCall(call.id),
          child: const Text('撤销'),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  static final ButtonStyle _actionStyle = TextButton.styleFrom(
    minimumSize: Size.zero,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
}

/// 幽灵预览横幅（§8.3：数据在 [WbAiState.ghostElements]，画布侧后续渲染）。
class _GhostBanner extends StatelessWidget {
  const _GhostBanner({required this.count, required this.onClear});

  final int count;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        key: const Key('ai.panel.ghostBanner'),
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(
          color: colors.canvas,
          borderRadius: BorderRadius.circular(6),
          border:
              Border.all(color: colors.primary.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: <Widget>[
            Icon(LinearIcons.visible, size: 14, color: colors.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '幽灵预览：$count 个元素（半透明，未落盘）',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: colors.primary, fontSize: 11),
              ),
            ),
            TextButton(
              key: const Key('ai.panel.ghostClear'),
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onClear,
              child: const Text('清除'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 语音状态条（§4.6 状态视觉：录音 / 转写 / 播报，含波形动画）。
class _VoiceStrip extends StatefulWidget {
  const _VoiceStrip({
    required this.voice,
    required this.label,
    required this.onStop,
  });

  final String voice;
  final String label;
  final VoidCallback onStop;

  @override
  State<_VoiceStrip> createState() => _VoiceStripState();
}

class _VoiceStripState extends State<_VoiceStrip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    final Color color = _voiceColor(widget.voice, colors);
    return Container(
      key: const Key('ai.panel.voiceStrip'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: <Widget>[
          if (widget.voice == WbVoicePhases.transcribing)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            _WaveBars(controller: _controller, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '语音：${widget.label}',
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
          if (widget.voice == WbVoicePhases.recording ||
              widget.voice == WbVoicePhases.transcribing ||
              widget.voice == WbVoicePhases.speaking)
            InkWell(
              key: const Key('ai.panel.voiceStop'),
              onTap: widget.onStop,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(LinearIcons.stop, size: 14, color: color),
              ),
            ),
        ],
      ),
    );
  }
}

/// 语音波形条（视觉模拟，无真实音频电平）。
class _WaveBars extends StatelessWidget {
  const _WaveBars({required this.controller, required this.color});

  final AnimationController controller;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Container(
                  width: 3,
                  height: 6 +
                      8 *
                          (0.5 +
                              0.5 *
                                  math.sin(controller.value * 2 * math.pi +
                                      i * 1.2)),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 输入语法提示面板（@元素 / #页面 / /指令 选择器，§4.5）。
class _SuggestionPanel extends StatelessWidget {
  const _SuggestionPanel({required this.suggestions, required this.onSelect});

  final List<_Suggestion> suggestions;
  final ValueChanged<_Suggestion> onSelect;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Container(
      key: const Key('ai.panel.suggestions'),
      decoration: BoxDecoration(
        color: colors.elevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final _Suggestion suggestion in suggestions)
            if (suggestion.enabled)
              InkWell(
                key: Key(
                  'ai.panel.suggestion.${suggestion.kind}${suggestion.id}',
                ),
                onTap: () => onSelect(suggestion),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '${suggestion.kind}${suggestion.label}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        suggestion.subtitle,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: colors.icon, fontSize: 10),
                      ),
                    ],
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Text(
                  suggestion.label,
                  style:
                      theme.textTheme.bodySmall?.copyWith(color: colors.icon),
                ),
              ),
        ],
      ),
    );
  }
}

/// 语法提示候选。
class _Suggestion {
  const _Suggestion({
    required this.kind,
    required this.id,
    required this.label,
    this.subtitle = '',
    this.command,
  }) : enabled = true;

  const _Suggestion.hint(this.label)
      : kind = '',
        id = '',
        subtitle = '',
        command = null,
        enabled = false;

  final String kind;
  final String id;
  final String label;
  final String subtitle;
  final WbCommand? command;
  final bool enabled;
}

/// 上下文引用芯片（可删除，§4.4）。
class _ContextRefChip extends StatelessWidget {
  const _ContextRefChip({required this.ref, required this.onRemove});

  final WbContextRef ref;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      padding: const EdgeInsets.only(left: 8, right: 2, top: 2, bottom: 2),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            ref.token,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colors.primary),
          ),
          const SizedBox(width: 2),
          InkWell(
            key: Key('ai.panel.ref.remove.${ref.kind}.${ref.id}'),
            onTap: onRemove,
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(LinearIcons.close, size: 12, color: colors.icon),
            ),
          ),
        ],
      ),
    );
  }
}

/// 输入区小动作按钮（@ / # / /）。
class _InputAction extends StatelessWidget {
  const _InputAction({
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.icon,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      ),
    );
  }
}

/// 状态徽标（确认级别 / 执行状态）。
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: color, fontSize: 10),
      ),
    );
  }
}

/// 空态提示（未配置时给出去设置入口）。
class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.configured});

  final bool configured;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(LinearIcons.ai, size: 36, color: colors.border),
            const SizedBox(height: 12),
            Text(
              configured ? '描述你的需求，AI 将自动完成白板编辑' : '尚未配置 AI 提供商',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.icon),
            ),
            if (!configured) ...<Widget>[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => context.push(WbRoutes.settingsPath),
                icon: const Icon(LinearIcons.settings, size: 16),
                label: const Text('前往设置'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误条。
class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              LinearIcons.warning,
              size: 14,
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// `HH:mm` 时间格式。
String _formatClock(DateTime? time) {
  if (time == null) {
    return '';
  }
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}';
}

/// 参数摘要（卡片折叠态，最多两行）。
String _compactArgs(AiToolCall call) {
  final Map<String, dynamic> args = call.arguments;
  if (args.isEmpty) {
    return '（无参数）';
  }
  final List<String> parts = <String>[];
  for (final MapEntry<String, dynamic> entry in args.entries) {
    parts.add('${entry.key}: ${_shortJson(entry.value)}');
    if (parts.length >= 2) {
      break;
    }
  }
  final String joined = parts.join('  ·  ');
  return args.length > 2 ? '$joined …' : joined;
}

String _shortJson(Object? value) {
  if (value is String) {
    return value;
  }
  final String encoded = jsonEncode(value);
  return encoded.length <= 60 ? encoded : '${encoded.substring(0, 57)}…';
}

/// 语音状态 → 颜色（§4.6 状态视觉表）。
Color _voiceColor(String voice, WbThemeColors colors) {
  switch (voice) {
    case WbVoicePhases.recording:
      return Colors.red;
    case WbVoicePhases.transcribing:
      return Colors.orange;
    case WbVoicePhases.speaking:
      return colors.primary;
    case AiVoiceStates.listening:
      return Colors.green;
    case AiVoiceStates.done:
      return Colors.green;
    case AiVoiceStates.error:
      return Colors.red;
    case AiVoiceStates.waitingConfirm:
      return Colors.purple;
    default:
      return colors.primary;
  }
}
