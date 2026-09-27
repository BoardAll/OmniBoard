/// AI 会话模型（《AI 助手与 MCP 设计》§5.3 会话管理）。
library;

import 'ai_context.dart';
import 'ai_message.dart';

/// 会话状态。
abstract final class AiSessionState {
  static const String active = 'active';
  static const String closed = 'closed';
}

/// 一次 AI 助手会话（绑定白板 / 用户 / 上下文与消息列表）。
class AiSession {
  const AiSession({
    this.id = '',
    this.boardId = '',
    this.userId = '',
    this.pageId = '',
    this.selection = const <String>[],
    this.context = const AiContext(),
    this.messages = const <AiMessage>[],
    this.state = AiSessionState.active,
    this.createdAt,
    this.updatedAt,
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String boardId;
  final String userId;
  final String pageId;
  final List<String> selection;
  final AiContext context;
  final List<AiMessage> messages;

  /// active / closed。
  final String state;

  final DateTime? createdAt;
  final DateTime? updatedAt;
  final Map<String, dynamic> raw;

  int get messageCount => messages.length;

  bool get isClosed => state == AiSessionState.closed;

  /// 最近一条助手消息（用于恢复面板展示）。
  AiMessage? get lastAssistantMessage {
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i].isAssistant) {
        return messages[i];
      }
    }
    return null;
  }

  /// 追加消息（返回新会话，更新时间戳）。
  AiSession appendMessage(AiMessage message) {
    return copyWith(
      messages: <AiMessage>[...messages, message],
      updatedAt: DateTime.now(),
    );
  }

  AiSession copyWith({
    String? id,
    String? boardId,
    String? userId,
    String? pageId,
    List<String>? selection,
    AiContext? context,
    List<AiMessage>? messages,
    String? state,
    DateTime? updatedAt,
  }) {
    return AiSession(
      id: id ?? this.id,
      boardId: boardId ?? this.boardId,
      userId: userId ?? this.userId,
      pageId: pageId ?? this.pageId,
      selection: selection ?? this.selection,
      context: context ?? this.context,
      messages: messages ?? this.messages,
      state: state ?? this.state,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      raw: raw,
    );
  }

  factory AiSession.fromJson(Map<String, dynamic> json) {
    String readStr(String key) =>
        json[key] is String ? json[key] as String : '';
    final Object? rawMessages = json['messages'];
    final Object? rawSelection = json['selection'];
    final Object? rawContext = json['context'];
    return AiSession(
      id: readStr('id').isNotEmpty ? readStr('id') : readStr('sessionId'),
      boardId: readStr('boardId'),
      userId: readStr('userId'),
      pageId: readStr('pageId'),
      selection: rawSelection is List
          ? rawSelection.whereType<String>().toList(growable: false)
          : const <String>[],
      context: rawContext is Map
          ? AiContext.fromJson(Map<String, dynamic>.from(rawContext))
          : const AiContext(),
      messages: rawMessages is List
          ? rawMessages
              .whereType<Map<dynamic, dynamic>>()
              .map((Map<dynamic, dynamic> m) =>
                  AiMessage.fromJson(Map<String, dynamic>.from(m)))
              .toList(growable: false)
          : const <AiMessage>[],
      state: readStr('state').isNotEmpty
          ? readStr('state')
          : AiSessionState.active,
      createdAt: _parseTimestamp(json['createdAt']),
      updatedAt: _parseTimestamp(json['updatedAt']),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'boardId': boardId,
        'userId': userId,
        'pageId': pageId,
        if (selection.isNotEmpty) 'selection': selection,
        'context': context.toJson(),
        'messages': messages.map((AiMessage m) => m.toJson()).toList(),
        'state': state,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
      };

  @override
  String toString() =>
      'AiSession($id, board=$boardId, ${messages.length} messages)';
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
