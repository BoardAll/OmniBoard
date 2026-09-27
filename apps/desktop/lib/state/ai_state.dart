/// AI 状态：会话消息 / 流式回复 / 工具调用 / 幽灵预览 / 上下文引用 / 语音状态。
///
/// Wave 3.5 在原有骨架（消息流 + 语音开关）上增量扩展：
/// - 工具调用（执行卡片数据源，§3.3 / §8.2）；
/// - 幽灵预览元素（§8.3，仅存数据，画布侧后续消费 [WbGhostElement.toJson]）；
/// - 上下文引用（@元素 / #页面，§4.4）；
/// - 语音视觉阶段（录音 / 转写 / 播报，§4.6，纯视觉模拟）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:whiteboard_ai/ai_client.dart';

import '../services/ai_canvas_executor.dart';
import '../services/ai_service.dart';

/// 语音视觉阶段（§4.6：录音 / 转写 / 播报；视觉层模拟，不做真实音频）。
///
/// 与 [AiVoiceStates] 并存：历史状态（listening 等）继续可用，
/// 本组常量表示 Wave 3.5 面板新增的录音链路阶段。
abstract final class WbVoicePhases {
  /// 录音中。
  static const String recording = 'recording';

  /// 转写中。
  static const String transcribing = 'transcribing';

  /// 播报中。
  static const String speaking = 'speaking';

  /// 阶段 → 中文标签（未知阶段返回空串，交由 [AiVoiceStates.label] 兜底）。
  static String label(String phase) {
    switch (phase) {
      case recording:
        return '录音中';
      case transcribing:
        return '转写中';
      case speaking:
        return '播报中';
      default:
        return '';
    }
  }
}

/// 上下文引用类型（§4.4：@元素 / #页面 / #Frame）。
abstract final class WbContextRefKinds {
  static const String element = 'element';
  static const String page = 'page';
  static const String frame = 'frame';
}

/// 一条上下文引用（面板芯片展示；发送时并入 [AiContext]）。
class WbContextRef {
  const WbContextRef({
    required this.kind,
    required this.id,
    required this.label,
  });

  /// [WbContextRefKinds] 之一。
  final String kind;

  /// 元素 / 页面 / Frame 的 id。
  final String id;

  /// 显示名（元素缺省用 id）。
  final String label;

  /// 前导符号：元素 `@`，页面 / Frame `#`。
  String get sigil => kind == WbContextRefKinds.element ? '@' : '#';

  /// 输入框插入文本（如 `@e1` / `#封面`）。
  String get token => '$sigil$label';

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'kind': kind, 'id': id, 'label': label};

  @override
  bool operator ==(Object other) =>
      other is WbContextRef &&
      other.kind == kind &&
      other.id == id &&
      other.label == label;

  @override
  int get hashCode => Object.hash(kind, id, label);

  @override
  String toString() => 'WbContextRef($kind, $id)';
}

/// 幽灵预览元素（§8.3：AI 提议的元素先以半透明幽灵形式呈现）。
///
/// 状态层只负责存储与暴露；画布侧在后续 Wave 消费 [toJson] 渲染半透明
/// 预览（当前不修改任何画布文件）。
class WbGhostElement {
  const WbGhostElement({
    required this.id,
    required this.type,
    this.label = '',
    this.x = 0,
    this.y = 0,
    this.width = 160,
    this.height = 90,
    this.opacity = 0.35,
    this.sourceCallId = '',
  });

  /// 幽灵元素 id（由工具调用 id 派生，稳定可追踪）。
  final String id;

  /// 元素类型（note / shape / connector 等，与 [WbElement] 对齐）。
  final String type;

  /// 显示文案（如便签文本）。
  final String label;

  final double x;
  final double y;
  final double width;
  final double height;

  /// 预览透明度（默认 0.35，画布渲染使用）。
  final double opacity;

  /// 来源工具调用 id（执行 / 取消时用于清理）。
  final String sourceCallId;

  /// 元素 JSON（`ghost: true` 标记；形状对齐 core 元素契约）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': type,
        'label': label,
        'ghost': true,
        'opacity': opacity,
        'position': <String, double>{'x': x, 'y': y},
        'size': <String, double>{'width': width, 'height': height},
      };

  @override
  String toString() => 'WbGhostElement($id, $type, ${width}x$height)';
}

/// 工具调用确认策略（§3.3；引擎工具元数据缺失时的本地推断）。
abstract final class WbToolCallPolicy {
  /// 按工具名推断确认级别。
  ///
  /// 引擎下发 [AiToolCall.confirmLevel] 非 auto 时以其为准，本推断仅作兜底：
  /// 删除 / 分享等 → confirm；创建 / 移动 / 布局等 → preview；其余 → auto。
  static String inferConfirmLevel(String toolName) {
    final String name = toolName.toLowerCase();
    if (name.isEmpty) {
      return AiConfirmLevels.auto;
    }
    if (name.contains('delete') ||
        name.contains('remove') ||
        name.contains('share') ||
        name.contains('permission')) {
      return AiConfirmLevels.confirm;
    }
    if (name.contains('create') ||
        name.contains('move') ||
        name.contains('layout') ||
        name.contains('group') ||
        name.contains('update') ||
        name.contains('connector') ||
        name.contains('apply')) {
      return AiConfirmLevels.preview;
    }
    return AiConfirmLevels.auto;
  }

  /// 确认级别 → 中文标签。
  static String label(String level) {
    switch (level) {
      case AiConfirmLevels.preview:
        return '需预览';
      case AiConfirmLevels.confirm:
        return '需确认';
      default:
        return '自动';
    }
  }
}

/// AI 状态。
///
/// 消息采用「用户输入 + 流式累积回复」模式：流式期间展示
/// [streamingText]，结束后落库为助手消息（与 ai_dart 门面行为一致）。
/// 工具调用随流式事件累积，结束后进入执行卡片（§8.2）。
class WbAiState extends ChangeNotifier {
  WbAiState({required this.aiService});

  /// AI 应用服务（组合 Dart SDK 与引擎 AI 域）。
  final WbAiAppService aiService;

  final List<AiMessage> _messages = <AiMessage>[];
  bool _streaming = false;
  String _streamingText = '';
  String _voice = '';
  String _voiceTranscript = '';
  String _error = '';
  final Map<String, AiToolCall> _toolCalls = <String, AiToolCall>{};
  final Set<String> _previewedIds = <String>{};
  final Set<String> _revertedIds = <String>{};
  final List<WbGhostElement> _ghosts = <WbGhostElement>[];
  final List<WbContextRef> _refs = <WbContextRef>[];
  bool _allowComments = false;
  bool _allowImageOcr = false;
  AiContext? _lastContext;
  WbAiToolExecutor? _executor;

  /// 会话消息列表（不可变视图）。
  List<AiMessage> get messages => List<AiMessage>.unmodifiable(_messages);

  /// 是否流式回复中。
  bool get isStreaming => _streaming;

  /// 流式累积文本（非流式期间为空串）。
  String get streamingText => _streamingText;

  /// 语音状态（空串表示空闲，其余见 [AiVoiceStates] / [WbVoicePhases]）。
  String get voice => _voice;

  /// 语音状态中文标签（空闲返回空串）。
  String get voiceLabel {
    if (_voice.isEmpty) {
      return '';
    }
    final String phaseLabel = WbVoicePhases.label(_voice);
    return phaseLabel.isNotEmpty ? phaseLabel : AiVoiceStates.label(_voice);
  }

  /// 语音是否处于活动状态。
  bool get isVoiceActive => _voice.isNotEmpty;

  /// 最近一次语音转写文本（空串表示尚未转写）。
  String get voiceTranscript => _voiceTranscript;

  /// 最近一次错误（空串表示无错误）。
  String get error => _error;

  /// 是否已配置模型提供商。
  bool get isConfigured => aiService.isConfigured;

  // ---- 工具调用（执行卡片，§8.2） ----

  /// 绑定工具执行器（画布就绪时由页面注入；null 解除绑定）。
  ///
  /// 未绑定时的 [approveToolCall] 降级为模拟执行（无画布环境兜底）。
  void bindExecutor(WbAiToolExecutor? executor) {
    _executor = executor;
  }

  /// 当前绑定的工具执行器（未绑定返回 null）。
  WbAiToolExecutor? get executor => _executor;

  /// 全部工具调用（按出现顺序；状态为最新值）。
  List<AiToolCall> get toolCalls => List<AiToolCall>.unmodifiable(_toolCalls.values);

  /// 是否有待确认的工具调用。
  bool get hasPendingToolCalls =>
      _toolCalls.values.any((AiToolCall call) => call.isPending);

  /// 按 id 查询工具调用最新状态（未找到返回 null）。
  AiToolCall? toolCallById(String id) => _toolCalls[id];

  /// 指定工具调用是否已生成幽灵预览。
  bool isToolCallPreviewed(String id) => _previewedIds.contains(id);

  /// 指定工具调用是否已被撤销。
  bool isToolCallReverted(String id) => _revertedIds.contains(id);

  // ---- 幽灵预览（§8.3） ----

  /// 当前幽灵预览元素（不可变视图；画布侧后续消费）。
  List<WbGhostElement> get ghostElements =>
      List<WbGhostElement>.unmodifiable(_ghosts);

  /// 是否有幽灵预览。
  bool get hasGhostPreview => _ghosts.isNotEmpty;

  /// 清除幽灵预览（不影响已执行数据）。
  void clearGhostPreview() {
    if (_ghosts.isEmpty) {
      return;
    }
    _ghosts.clear();
    _previewedIds.clear();
    notifyListeners();
  }

  // ---- 上下文引用与授权（§4.4） ----

  /// 手动引用的上下文对象（@元素 / #页面，不含自动选区）。
  List<WbContextRef> get contextRefs => List<WbContextRef>.unmodifiable(_refs);

  /// 是否允许 AI 读取评论。
  bool get allowComments => _allowComments;

  /// 是否允许 AI 读取图片 OCR。
  bool get allowImageOcr => _allowImageOcr;

  /// 最近一次合并后的会话上下文（未发送过返回 null）。
  AiContext? get lastContext => _lastContext;

  /// 添加上下文引用（重复引用忽略）。
  void addContextRef(WbContextRef ref) {
    if (_refs.contains(ref)) {
      return;
    }
    _refs.add(ref);
    notifyListeners();
  }

  /// 移除上下文引用。
  void removeContextRef(WbContextRef ref) {
    if (_refs.remove(ref)) {
      notifyListeners();
    }
  }

  /// 清空上下文引用。
  void clearContextRefs() {
    if (_refs.isEmpty) {
      return;
    }
    _refs.clear();
    notifyListeners();
  }

  /// 设置是否允许读取评论。
  void setAllowComments(bool value) {
    if (_allowComments == value) {
      return;
    }
    _allowComments = value;
    notifyListeners();
  }

  /// 设置是否允许读取图片 OCR。
  void setAllowImageOcr(bool value) {
    if (_allowImageOcr == value) {
      return;
    }
    _allowImageOcr = value;
    notifyListeners();
  }

  /// 合并面板上下文（页面 / 选区 / 引用 / 授权）后更新会话（§4.4）。
  void updateSessionContext({
    String boardId = '',
    String pageId = '',
    String frameId = '',
    List<String> selection = const <String>[],
  }) {
    final List<String> elementIds = <String>[];
    for (final String id in selection) {
      if (id.isNotEmpty && !elementIds.contains(id)) {
        elementIds.add(id);
      }
    }
    WbContextRef? pageRef;
    WbContextRef? frameRef;
    for (final WbContextRef ref in _refs) {
      if (ref.kind == WbContextRefKinds.element) {
        if (!elementIds.contains(ref.id)) {
          elementIds.add(ref.id);
        }
      } else if (ref.kind == WbContextRefKinds.page) {
        pageRef ??= ref;
      } else if (ref.kind == WbContextRefKinds.frame) {
        frameRef ??= ref;
      }
    }
    final String scope;
    if (elementIds.isNotEmpty) {
      scope = AiContextScope.selection;
    } else if (frameRef != null) {
      scope = AiContextScope.frame;
    } else if (pageRef != null || pageId.isNotEmpty) {
      scope = AiContextScope.page;
    } else {
      scope = AiContextScope.board;
    }
    final AiContext context = AiContext(
      boardId: boardId,
      pageId: pageRef?.id ?? pageId,
      frameId: frameRef?.id ?? frameId,
      selection: elementIds,
      scope: scope,
      allowComments: _allowComments,
      allowImageOcr: _allowImageOcr,
    );
    _lastContext = context;
    aiService.updateContext(context);
    notifyListeners();
  }

  /// 配置模型提供商并清空错误。
  void configure(AiProvider provider) {
    aiService.configure(provider);
    _error = '';
    notifyListeners();
  }

  /// 发送一条用户消息并流式接收回复。
  ///
  /// 未配置提供商时追加一条系统提示消息（不触网）。
  Future<void> send(String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty || _streaming) {
      return;
    }
    if (!isConfigured) {
      _messages.add(AiMessage.system(
        'AI 提供商未配置：请在「设置」中选择模型服务后再试。',
      ));
      notifyListeners();
      return;
    }
    _error = '';
    _messages.add(AiMessage(
      role: AiRoles.user,
      content: trimmed,
      timestamp: DateTime.now(),
    ));
    _streaming = true;
    _streamingText = '';
    final Map<int, _ToolCallDraft> drafts = <int, _ToolCallDraft>{};
    notifyListeners();
    try {
      await for (final AiStreamEvent event in aiService.stream(trimmed)) {
        switch (event) {
          case AiTextDelta(text: final String delta):
            _streamingText += delta;
            notifyListeners();
          case AiToolCallDelta(
              :final int index,
              :final String id,
              :final String name,
              :final String argumentsDelta
            ):
            final _ToolCallDraft draft =
                drafts.putIfAbsent(index, () => _ToolCallDraft());
            if (id.isNotEmpty) {
              draft.id = id;
            }
            if (name.isNotEmpty) {
              draft.name = name;
            }
            draft.arguments.write(argumentsDelta);
            notifyListeners();
          case AiStreamError(message: final String message):
            _error = message;
          case AiStreamDone():
            break;
        }
      }
      final List<AiToolCall> calls = drafts.entries
          .map((MapEntry<int, _ToolCallDraft> entry) =>
              entry.value.toToolCall(entry.key))
          .toList(growable: false);
      if (_streamingText.isNotEmpty || calls.isNotEmpty) {
        for (final AiToolCall call in calls) {
          _toolCalls[call.id] = call;
        }
        _messages.add(AiMessage(
          role: AiRoles.assistant,
          content: _streamingText,
          toolCalls: calls,
          timestamp: DateTime.now(),
        ));
      }
    } catch (e) {
      _error = '$e';
    } finally {
      _streaming = false;
      _streamingText = '';
      notifyListeners();
    }
  }

  // ---- 工具调用动作（执行卡片按钮） ----

  /// 生成幽灵预览：把工具调用的目标元素写入 [ghostElements]（不落盘）。
  void previewToolCall(String toolCallId) {
    final AiToolCall? call = _toolCalls[toolCallId];
    if (call == null) {
      return;
    }
    _ghosts
      ..clear()
      ..addAll(_ghostsFromCall(call));
    _previewedIds.add(toolCallId);
    notifyListeners();
  }

  /// 执行工具调用（确认 / 全部执行）。
  ///
  /// 已绑定 [WbAiToolExecutor]（如画布执行器）时走真实执行并落盘；
  /// 未绑定时降级为模拟执行结果，保证无画布环境不抛异常。
  Future<void> approveToolCall(String toolCallId) async {
    final AiToolCall? current = _toolCalls[toolCallId];
    if (current == null || !current.isPending) {
      return;
    }
    final WbAiToolExecutor? executor = _executor;
    Map<String, dynamic> result;
    if (executor == null) {
      result = _simulateExecution(current);
    } else {
      try {
        result = await executor.execute(current);
      } catch (e) {
        result = <String, dynamic>{'ok': false, 'error': '$e'};
      }
    }
    final bool ok = result['ok'] != false;
    _toolCalls[toolCallId] = current.copyWith(
      status: ok ? AiToolCallStatus.success : AiToolCallStatus.error,
      result: result,
      error: ok ? '' : '${result['error'] ?? '执行失败'}',
    );
    _previewedIds.remove(toolCallId);
    _ghosts.removeWhere(
        (WbGhostElement ghost) => ghost.sourceCallId == toolCallId);
    // 回填工具结果（供后续轮次引用；未配置提供商时为 no-op）。
    aiService.client?.append(
      AiMessage.toolResult(toolCallId, jsonEncode(result)),
    );
    notifyListeners();
  }

  /// 拒绝（取消）工具调用。
  void rejectToolCall(String toolCallId) {
    final AiToolCall? current = _toolCalls[toolCallId];
    if (current == null || !current.isPending) {
      return;
    }
    _toolCalls[toolCallId] =
        current.copyWith(status: AiToolCallStatus.cancelled);
    _previewedIds.remove(toolCallId);
    _ghosts.removeWhere(
        (WbGhostElement ghost) => ghost.sourceCallId == toolCallId);
    notifyListeners();
  }

  /// 撤销已执行的工具调用（事务级撤销，§3.4）。
  void undoToolCall(String toolCallId) {
    final AiToolCall? current = _toolCalls[toolCallId];
    if (current == null || !current.isSuccess || _revertedIds.contains(toolCallId)) {
      return;
    }
    // 已绑执行器时恢复白板实际改动（未绑定 / 模拟执行时为 no-op）。
    _executor?.undo(current);
    _revertedIds.add(toolCallId);
    _messages.add(AiMessage.system('已撤销：${_toolLabel(current)}'));
    notifyListeners();
  }

  /// 切换语音输入态（骨架：仅在待机与聆听间切换；保留旧行为）。
  void toggleVoice() {
    _voice = _voice == AiVoiceStates.listening ? '' : AiVoiceStates.listening;
    notifyListeners();
  }

  /// 开始录音（视觉模拟，§4.6）。
  void startVoiceRecording() {
    _voice = WbVoicePhases.recording;
    notifyListeners();
  }

  /// 结束录音，进入转写（视觉模拟）。
  void stopVoiceRecording() {
    if (_voice != WbVoicePhases.recording &&
        _voice != AiVoiceStates.listening) {
      return;
    }
    _voice = WbVoicePhases.transcribing;
    notifyListeners();
  }

  /// 转写完成：记录文本并回到空闲（面板负责把文本填入输入框）。
  void completeVoiceTranscription(String transcript) {
    _voiceTranscript = transcript.trim();
    _voice = '';
    notifyListeners();
  }

  /// 开始播报（视觉模拟；流式回复期间展示）。
  void startSpeaking() {
    _voice = WbVoicePhases.speaking;
    notifyListeners();
  }

  /// 结束播报（含打断）。
  void stopSpeaking() {
    if (_voice == WbVoicePhases.speaking) {
      _voice = '';
      notifyListeners();
    }
  }

  /// 取消当前语音链路（录音 / 转写 / 播报均回到空闲）。
  void cancelVoice() {
    if (_voice.isEmpty) {
      return;
    }
    _voice = '';
    notifyListeners();
  }

  /// 重置对话（保留提供商配置；清理工具调用与幽灵预览）。
  void reset() {
    if (_messages.isEmpty &&
        _error.isEmpty &&
        _toolCalls.isEmpty &&
        _ghosts.isEmpty) {
      return;
    }
    _messages.clear();
    _error = '';
    _toolCalls.clear();
    _previewedIds.clear();
    _revertedIds.clear();
    _ghosts.clear();
    aiService.reset();
    notifyListeners();
  }

  // ---- 内部实现 ----

  String _toolLabel(AiToolCall call) =>
      call.name.isNotEmpty ? call.name : call.toolId;

  Map<String, dynamic> _simulateExecution(AiToolCall call) {
    final Object? elements = call.arguments['elements'];
    final Object? count = call.arguments['count'];
    final int affected = elements is List
        ? elements.length
        : (count is num ? count.toInt() : 1);
    return <String, dynamic>{
      'ok': true,
      'tool': _toolLabel(call),
      'affected': affected,
      'summary': '已执行 ${_toolLabel(call)}（影响 $affected 个元素）',
      'simulated': true,
    };
  }

  List<WbGhostElement> _ghostsFromCall(AiToolCall call) {
    final Object? previewElements = call.preview['elements'];
    final Object? argumentElements = call.arguments['elements'];
    final Object? source =
        previewElements is List ? previewElements : argumentElements;
    final List<WbGhostElement> ghosts = <WbGhostElement>[];
    if (source is List) {
      for (int i = 0; i < source.length && ghosts.length < 24; i++) {
        final Object? item = source[i];
        if (item is! Map) {
          continue;
        }
        final Map<dynamic, dynamic> map = item;
        final String id = _readString(map, 'id');
        final String type = _readString(map, 'type');
        final String label = _readFirstString(
          map,
          const <String>['label', 'text', 'title', 'name'],
        );
        ghosts.add(WbGhostElement(
          id: id.isNotEmpty ? id : '${call.id}-ghost-$i',
          type: type.isNotEmpty ? type : 'note',
          label: label,
          x: _readNestedDouble(map, 'position', 'x') ?? 0,
          y: _readNestedDouble(map, 'position', 'y') ?? 0,
          width: _readNestedDouble(map, 'size', 'width') ?? 160,
          height: _readNestedDouble(map, 'size', 'height') ?? 90,
          sourceCallId: call.id,
        ));
      }
    }
    if (ghosts.isEmpty) {
      ghosts.add(WbGhostElement(
        id: '${call.id}-ghost-0',
        type: 'note',
        label: _toolLabel(call),
        sourceCallId: call.id,
      ));
    }
    return ghosts;
  }

  static String _readString(Map<dynamic, dynamic> map, String key) =>
      map[key] is String ? map[key] as String : '';

  static String _readFirstString(Map<dynamic, dynamic> map, List<String> keys) {
    for (final String key in keys) {
      final String value = _readString(map, key);
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  static double? _readNestedDouble(
    Map<dynamic, dynamic> map,
    String group,
    String key,
  ) {
    final Object? nested = map[group];
    if (nested is Map && nested[key] is num) {
      return (nested[key] as num).toDouble();
    }
    return map[key] is num ? (map[key] as num).toDouble() : null;
  }
}

/// 流式工具调用累积草稿（参数 JSON 分片拼接）。
class _ToolCallDraft {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();

  AiToolCall toToolCall(int index) {
    final String resolvedName = name.isNotEmpty ? name : 'tool_$index';
    return AiToolCall(
      id: id.isNotEmpty ? id : 'call_$index',
      name: resolvedName,
      toolId: resolvedName,
      arguments: _parseArguments(arguments.toString()),
      confirmLevel: WbToolCallPolicy.inferConfirmLevel(resolvedName),
      timestamp: DateTime.now(),
    );
  }

  static Map<String, dynamic> _parseArguments(String raw) {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      final Object? decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      // 参数未形成合法 JSON 时忽略。
    }
    return const <String, dynamic>{};
  }
}
