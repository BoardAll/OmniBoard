/// AI 会话模型（Open API §5.8，对齐《AI 助手与 MCP 设计》§AISession/AIMessage）。
class WbApiSession {
  const WbApiSession({
    required this.sessionId,
    this.boardId = '',
    this.userId = '',
    this.pageId = '',
    this.selection = '',
    this.context = const <String, dynamic>{},
    this.messageCount = 0,
    this.createdAt = '',
    this.updatedAt = '',
    this.raw = const <String, dynamic>{},
  });

  final String sessionId;
  final String boardId;
  final String userId;

  /// 当前页面（AI 上下文折叠用）。
  final String pageId;

  /// 当前选中元素 id（可能为空）。
  final String selection;

  /// 会话上下文（板/页/选区等摘要）。
  final Map<String, dynamic> context;

  final int messageCount;
  final String createdAt;
  final String updatedAt;

  final Map<String, dynamic> raw;

  factory WbApiSession.fromJson(Map<String, dynamic> json) {
    String readStr(String key) => json[key] is String ? json[key] as String : '';
    return WbApiSession(
      sessionId: readStr('sessionId'),
      boardId: readStr('boardId'),
      userId: readStr('userId'),
      pageId: readStr('pageId'),
      selection: readStr('selection'),
      context: json['context'] is Map
          ? Map<String, dynamic>.from(json['context'] as Map)
          : const <String, dynamic>{},
      messageCount: json['messageCount'] is num
          ? (json['messageCount'] as num).toInt()
          : 0,
      createdAt: readStr('createdAt'),
      updatedAt: readStr('updatedAt'),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'sessionId': sessionId,
          'boardId': boardId,
          'userId': userId,
          if (pageId.isNotEmpty) 'pageId': pageId,
          if (selection.isNotEmpty) 'selection': selection,
          if (context.isNotEmpty) 'context': context,
          'messageCount': messageCount,
          'createdAt': createdAt,
          'updatedAt': updatedAt,
        };

  @override
  String toString() => 'WbApiSession($sessionId, messages=$messageCount)';
}

/// AI 消息。
class WbApiMessage {
  const WbApiMessage({
    required this.id,
    this.sessionId = '',
    this.role = '',
    this.content = '',
    this.audioUrl = '',
    this.toolCalls = const <WbApiToolCall>[],
    this.timestamp = '',
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String sessionId;

  /// user / assistant / system / tool。
  final String role;
  final String content;

  /// 语音消息音频地址。
  final String audioUrl;
  final List<WbApiToolCall> toolCalls;
  final String timestamp;

  final Map<String, dynamic> raw;

  bool get isUser => role == 'user';

  bool get isAssistant => role == 'assistant';

  factory WbApiMessage.fromJson(Map<String, dynamic> json) {
    String readStr(String key) => json[key] is String ? json[key] as String : '';
    final Object? toolCalls = json['toolCalls'];
    return WbApiMessage(
      id: readStr('id'),
      sessionId: readStr('sessionId'),
      role: readStr('role'),
      content: readStr('content'),
      audioUrl: readStr('audioUrl'),
      toolCalls: toolCalls is List
          ? toolCalls
              .whereType<Map<dynamic, dynamic>>()
              .map((Map<dynamic, dynamic> m) =>
                  WbApiToolCall.fromJson(Map<String, dynamic>.from(m)))
              .toList(growable: false)
          : const <WbApiToolCall>[],
      timestamp: json['timestamp'] is String
          ? json['timestamp'] as String
          : readStr('createdAt'),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'id': id,
          'sessionId': sessionId,
          'role': role,
          'content': content,
          if (audioUrl.isNotEmpty) 'audioUrl': audioUrl,
          'toolCalls':
              toolCalls.map((WbApiToolCall c) => c.toJson()).toList(),
          'timestamp': timestamp,
        };

  @override
  String toString() => 'WbApiMessage($id, $role)';
}

/// AI 工具调用（含预览 / 执行状态）。
class WbApiToolCall {
  const WbApiToolCall({
    required this.id,
    this.name = '',
    this.arguments = const <String, dynamic>{},
    this.status = '',
    this.preview = const <String, dynamic>{},
    this.result = const <String, dynamic>{},
    this.raw = const <String, dynamic>{},
  });

  final String id;

  /// 工具名（如 create_sticky_note）。
  final String name;
  final Map<String, dynamic> arguments;

  /// pending / previewing / executed / cancelled / failed。
  final String status;

  /// 预览结果（影响范围）。
  final Map<String, dynamic> preview;

  /// 执行结果。
  final Map<String, dynamic> result;

  final Map<String, dynamic> raw;

  bool get isPending => status == 'pending';

  factory WbApiToolCall.fromJson(Map<String, dynamic> json) {
    String readStr(String key) => json[key] is String ? json[key] as String : '';
    Map<String, dynamic> readMap(String key) => json[key] is Map
        ? Map<String, dynamic>.from(json[key] as Map)
        : const <String, dynamic>{};
    return WbApiToolCall(
      id: readStr('id'),
      name: readStr('name'),
      arguments: readMap('arguments'),
      status: readStr('status'),
      preview: readMap('preview'),
      result: readMap('result'),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'id': id,
          'name': name,
          'arguments': arguments,
          if (status.isNotEmpty) 'status': status,
          if (preview.isNotEmpty) 'preview': preview,
          if (result.isNotEmpty) 'result': result,
        };

  @override
  String toString() => 'WbApiToolCall($id, $name, $status)';
}
