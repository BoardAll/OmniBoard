/// AI 消息模型（《AI 助手与 MCP 设计》§5.3）。
library;

import 'ai_tool_call.dart';

/// 消息角色（与 C++ `ai_message` 契约一致）。
abstract final class AiRoles {
  static const String system = 'system';
  static const String user = 'user';
  static const String assistant = 'assistant';
  static const String tool = 'tool';
}

/// 一条 AI 会话消息。
class AiMessage {
  const AiMessage({
    this.id = '',
    this.role = AiRoles.user,
    this.content = '',
    this.toolCalls = const <AiToolCall>[],
    this.toolCallId = '',
    this.name = '',
    this.audioUrl = '',
    this.timestamp,
    this.raw = const <String, dynamic>{},
  });

  final String id;

  /// system / user / assistant / tool。
  final String role;
  final String content;

  /// 助手消息携带的工具调用。
  final List<AiToolCall> toolCalls;

  /// `role == tool` 时引用的工具调用 id。
  final String toolCallId;

  /// 可选名称（如工具名）。
  final String name;

  /// 语音消息的音频地址。
  final String audioUrl;

  final DateTime? timestamp;
  final Map<String, dynamic> raw;

  bool get isUser => role == AiRoles.user;

  bool get isAssistant => role == AiRoles.assistant;

  bool get isSystem => role == AiRoles.system;

  bool get isTool => role == AiRoles.tool;

  /// 无文本且无工具调用。
  bool get isEmpty => content.isEmpty && toolCalls.isEmpty;

  factory AiMessage.user(String content) =>
      AiMessage(role: AiRoles.user, content: content);

  factory AiMessage.system(String content) =>
      AiMessage(role: AiRoles.system, content: content);

  factory AiMessage.assistant(
    String content, {
    List<AiToolCall> toolCalls = const <AiToolCall>[],
  }) =>
      AiMessage(role: AiRoles.assistant, content: content, toolCalls: toolCalls);

  /// 工具执行结果消息（回填给模型）。
  factory AiMessage.toolResult(String toolCallId, String content) => AiMessage(
        role: AiRoles.tool,
        content: content,
        toolCallId: toolCallId,
      );

  AiMessage copyWith({String? content, List<AiToolCall>? toolCalls}) {
    return AiMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      toolCalls: toolCalls ?? this.toolCalls,
      toolCallId: toolCallId,
      name: name,
      audioUrl: audioUrl,
      timestamp: timestamp,
      raw: raw,
    );
  }

  factory AiMessage.fromJson(Map<String, dynamic> json) {
    String readStr(String key) =>
        json[key] is String ? json[key] as String : '';
    final Object? calls = json['toolCalls'] ?? json['tool_calls'];
    final String toolCallId =
        readStr('toolCallId').isNotEmpty ? readStr('toolCallId') : readStr('tool_call_id');
    return AiMessage(
      id: readStr('id'),
      role: readStr('role').isNotEmpty ? readStr('role') : AiRoles.user,
      content: readStr('content'),
      toolCalls: calls is List
          ? calls
              .whereType<Map<dynamic, dynamic>>()
              .map((Map<dynamic, dynamic> m) =>
                  AiToolCall.fromJson(Map<String, dynamic>.from(m)))
              .toList(growable: false)
          : const <AiToolCall>[],
      toolCallId: toolCallId,
      name: readStr('name'),
      audioUrl: readStr('audioUrl'),
      timestamp: _parseTimestamp(json['timestamp'] ?? json['createdAt']),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'role': role,
        'content': content,
        if (toolCalls.isNotEmpty)
          'toolCalls': toolCalls.map((AiToolCall c) => c.toJson()).toList(),
        if (toolCallId.isNotEmpty) 'toolCallId': toolCallId,
        if (name.isNotEmpty) 'name': name,
        if (audioUrl.isNotEmpty) 'audioUrl': audioUrl,
        if (timestamp != null) 'timestamp': timestamp!.toIso8601String(),
      };

  @override
  String toString() =>
      'AiMessage($role, ${content.length} chars, ${toolCalls.length} toolCalls)';
}

DateTime? _parseTimestamp(Object? value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value);
  }
  return null;
}
