/// Whiteboard AI SDK 门面：Provider 抽象、请求 / 响应模型与
/// 会话驱动客户端（《AI 助手与 MCP 设计》§4-§5、《工程结构》§4.6）。
library;

import 'dart:convert';

import 'ai_audio.dart';
import 'ai_context.dart';
import 'ai_message.dart';
import 'ai_session.dart';
import 'ai_tool_call.dart';

export 'ai_audio.dart';
export 'ai_context.dart';
export 'ai_message.dart';
export 'ai_session.dart';
export 'ai_tool_call.dart';
export 'providers/anthropic_provider.dart';
export 'providers/custom_provider.dart';
export 'providers/openai_provider.dart';

/// Provider 调用异常（网络 / 鉴权 / 服务端错误）。
class AiProviderException implements Exception {
  const AiProviderException({
    required this.provider,
    required this.message,
    this.statusCode = 0,
    this.body = '',
  });

  /// Provider id（如 `openai`）。
  final String provider;

  final String message;

  /// HTTP 状态码（0 表示非 HTTP 错误）。
  final int statusCode;

  /// 原始响应体（便于诊断）。
  final String body;

  @override
  String toString() =>
      'AiProviderException($provider${statusCode > 0 ? ' $statusCode' : ''}): $message';
}

/// 结束原因常量。
abstract final class AiFinishReasons {
  static const String stop = 'stop';
  static const String toolCalls = 'tool_calls';
  static const String length = 'length';
  static const String contentFilter = 'content_filter';
}

/// 工具定义（以 JSON Schema 描述入参，提供给模型）。
class AiToolDefinition {
  const AiToolDefinition({
    required this.name,
    this.description = '',
    this.parameters = const <String, dynamic>{},
  });

  /// 工具名（MCP 命名，如 `element_create`）。
  final String name;
  final String description;

  /// JSON Schema（object）。
  final Map<String, dynamic> parameters;

  factory AiToolDefinition.fromJson(Map<String, dynamic> json) {
    return AiToolDefinition(
      name: json['name'] is String ? json['name'] as String : '',
      description:
          json['description'] is String ? json['description'] as String : '',
      parameters: json['parameters'] is Map
          ? Map<String, dynamic>.from(json['parameters'] as Map)
          : const <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'description': description,
        'parameters': parameters,
      };
}

/// 用量统计（OpenAI / Anthropic 字段统一）。
class AiUsage {
  const AiUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
  });

  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  factory AiUsage.fromJson(Map<String, dynamic> json) {
    int readInt(String key) =>
        json[key] is num ? (json[key] as num).toInt() : 0;
    final int prompt = readInt('prompt_tokens') + readInt('input_tokens');
    final int completion =
        readInt('completion_tokens') + readInt('output_tokens');
    final int total = readInt('total_tokens');
    return AiUsage(
      promptTokens: prompt,
      completionTokens: completion,
      totalTokens: total > 0 ? total : prompt + completion,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'total_tokens': totalTokens,
      };
}

/// 一次对话请求。
class AiChatRequest {
  const AiChatRequest({
    required this.messages,
    this.model = '',
    this.system = '',
    this.tools = const <AiToolDefinition>[],
    this.temperature,
    this.maxTokens,
    this.toolChoice = '',
    this.extra = const <String, dynamic>{},
  });

  final List<AiMessage> messages;

  /// 模型名（空则用 provider 默认）。
  final String model;

  /// 系统提示（provider 负责按自家协议编码）。
  final String system;

  final List<AiToolDefinition> tools;
  final double? temperature;
  final int? maxTokens;

  /// auto / none / required / 指定工具名（空则不传）。
  final String toolChoice;

  /// 透传字段（合并进请求体）。
  final Map<String, dynamic> extra;

  AiChatRequest copyWith({
    List<AiMessage>? messages,
    String? model,
    String? system,
    List<AiToolDefinition>? tools,
    double? temperature,
    int? maxTokens,
    String? toolChoice,
    Map<String, dynamic>? extra,
  }) {
    return AiChatRequest(
      messages: messages ?? this.messages,
      model: model ?? this.model,
      system: system ?? this.system,
      tools: tools ?? this.tools,
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      toolChoice: toolChoice ?? this.toolChoice,
      extra: extra ?? this.extra,
    );
  }
}

/// 一次对话响应。
class AiChatResponse {
  const AiChatResponse({
    required this.message,
    this.finishReason = '',
    this.usage = const AiUsage(),
    this.raw = const <String, dynamic>{},
  });

  final AiMessage message;
  final String finishReason;
  final AiUsage usage;
  final Map<String, dynamic> raw;
}

/// 流式事件（`chatStream` 产出）。
sealed class AiStreamEvent {
  const AiStreamEvent();
}

/// 文本增量。
class AiTextDelta extends AiStreamEvent {
  const AiTextDelta(this.text);

  final String text;
}

/// 工具调用增量（按 `index` 累积）。
class AiToolCallDelta extends AiStreamEvent {
  const AiToolCallDelta({
    this.index = 0,
    this.id = '',
    this.name = '',
    this.argumentsDelta = '',
  });

  final int index;
  final String id;
  final String name;
  final String argumentsDelta;
}

/// 流结束（携带结束原因与用量）。
class AiStreamDone extends AiStreamEvent {
  const AiStreamDone({
    this.finishReason = '',
    this.usage = const AiUsage(),
  });

  final String finishReason;
  final AiUsage usage;
}

/// 流内错误（连接中断 / 解析失败等）。
class AiStreamError extends AiStreamEvent {
  const AiStreamError(this.message, {this.error});

  final String message;
  final Object? error;
}

/// AI 模型接入抽象（OpenAI / Anthropic / 自定义兼容端点）。
abstract class AiProvider {
  const AiProvider();

  /// Provider id（如 `openai` / `anthropic` / `custom`）。
  String get id;

  /// 默认模型名。
  String get defaultModel;

  /// 非流式对话。
  Future<AiChatResponse> chat(AiChatRequest request);

  /// 流式对话。
  Stream<AiStreamEvent> chatStream(AiChatRequest request);

  /// 语音转文字（ASR）。默认不支持。
  Future<AiTranscript> transcribe(
    List<int> audio, {
    String model = '',
    String language = '',
    String mimeType = 'audio/wav',
  }) async {
    throw UnsupportedError('$id does not support transcription');
  }

  /// 文字转语音（TTS）。默认不支持。
  Future<List<int>> synthesize(
    String text, {
    String voice = '',
    String model = '',
    String format = 'mp3',
  }) async {
    throw UnsupportedError('$id does not support speech synthesis');
  }
}

/// 流式工具调用累积草稿。
class _ToolCallDraft {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();

  Map<String, dynamic> get argumentsMap {
    final String raw = arguments.toString().trim();
    if (raw.isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      // 参数未形成合法 JSON 时返回空。
    }
    return const <String, dynamic>{};
  }
}

/// 高层 AI 客户端：维护会话消息、组装请求、流式结果落库。
///
/// ```dart
/// final client = AiClient(
///   provider: OpenAiProvider(apiKey: 'sk-...'),
///   systemPrompt: '你是白板助手',
/// );
/// final reply = await client.send('创建 5 个便签');
/// ```
class AiClient {
  AiClient({
    required this.provider,
    this.systemPrompt = '',
    this.tools = const <AiToolDefinition>[],
    this.temperature,
    this.maxTokens,
    this.model = '',
    AiSession? session,
  }) : _session = session ?? const AiSession(id: 'local');

  final AiProvider provider;

  /// 系统提示。
  final String systemPrompt;

  /// 可调用的白板工具定义。
  final List<AiToolDefinition> tools;

  final double? temperature;
  final int? maxTokens;

  /// 模型名（空则用 provider 默认）。
  final String model;

  AiSession _session;

  /// 当前会话（不可变快照）。
  AiSession get session => _session;

  List<AiMessage> get messages => _session.messages;

  /// 更新上下文（选区 / 页面 / Frame 等，§4.4）。
  void updateContext(AiContext context) {
    _session = _session.copyWith(
      context: _session.context.merge(context),
      boardId: context.boardId.isNotEmpty ? context.boardId : null,
      pageId: context.pageId.isNotEmpty ? context.pageId : null,
      selection: context.selection,
    );
  }

  /// 追加外部消息（如工具执行结果）。
  void append(AiMessage message) {
    _session = _session.appendMessage(message);
  }

  /// 清空对话消息（保留上下文）。
  void reset() {
    _session = _session.copyWith(messages: const <AiMessage>[]);
  }

  /// 组装下一次请求。
  AiChatRequest buildRequest() => AiChatRequest(
        messages: messages,
        model: model,
        system: systemPrompt,
        tools: tools,
        temperature: temperature,
        maxTokens: maxTokens,
      );

  /// 非流式发送：写入用户消息，返回并记录助手消息。
  Future<AiMessage> send(String text) async {
    _session = _session.appendMessage(AiMessage.user(text));
    final AiChatResponse response = await provider.chat(buildRequest());
    _session = _session.appendMessage(response.message);
    return response.message;
  }

  /// 流式发送：实时产出事件；结束后把累积的助手消息（文本 + 工具调用）写入会话。
  Stream<AiStreamEvent> stream(String text) async* {
    _session = _session.appendMessage(AiMessage.user(text));
    final StringBuffer buffer = StringBuffer();
    final Map<int, _ToolCallDraft> drafts = <int, _ToolCallDraft>{};
    try {
      await for (final AiStreamEvent event in provider.chatStream(buildRequest())) {
        switch (event) {
          case AiTextDelta(:final String text):
            buffer.write(text);
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
          case AiStreamDone():
          case AiStreamError():
            break;
        }
        yield event;
      }
    } finally {
      final List<AiToolCall> toolCalls = drafts.entries
          .map((MapEntry<int, _ToolCallDraft> entry) => AiToolCall(
                id: entry.value.id,
                name: entry.value.name,
                toolId: entry.value.name,
                arguments: entry.value.argumentsMap,
              ))
          .toList(growable: false);
      if (buffer.isNotEmpty || toolCalls.isNotEmpty) {
        _session = _session
            .appendMessage(AiMessage.assistant(buffer.toString(), toolCalls: toolCalls));
      }
    }
  }
}
