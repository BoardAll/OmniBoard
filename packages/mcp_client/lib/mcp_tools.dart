/// MCP Tools 能力模型（《MCP Server 详细设计》§6）。
library;

/// 工具定义（`tools/list` 结果项）。
class McpTool {
  const McpTool({
    required this.name,
    this.description = '',
    this.inputSchema = const <String, dynamic>{},
    this.raw = const <String, dynamic>{},
  });

  /// 工具名（下划线命名，如 `element_create`）。
  final String name;
  final String description;

  /// JSON Schema 入参定义。
  final Map<String, dynamic> inputSchema;

  final Map<String, dynamic> raw;

  factory McpTool.fromJson(Map<String, dynamic> json) {
    return McpTool(
      name: json['name'] is String ? json['name'] as String : '',
      description:
          json['description'] is String ? json['description'] as String : '',
      inputSchema: json['inputSchema'] is Map
          ? Map<String, dynamic>.from(json['inputSchema'] as Map)
          : const <String, dynamic>{},
      raw: json,
    );
  }

  @override
  String toString() => 'McpTool($name)';
}

/// 工具返回的内容块（`content[]` 项）。
class McpToolContent {
  const McpToolContent({
    required this.type,
    this.text = '',
    this.data = '',
    this.mimeType = '',
  });

  /// text / image / resource / audio。
  final String type;

  /// 文本内容（`type == text`）。
  final String text;

  /// base64 数据（`type == image / audio`）。
  final String data;

  final String mimeType;

  factory McpToolContent.fromJson(Map<String, dynamic> json) {
    return McpToolContent(
      type: json['type'] is String ? json['type'] as String : 'text',
      text: json['text'] is String ? json['text'] as String : '',
      data: json['data'] is String ? json['data'] as String : '',
      mimeType: json['mimeType'] is String ? json['mimeType'] as String : '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        if (text.isNotEmpty) 'text': text,
        if (data.isNotEmpty) 'data': data,
        if (mimeType.isNotEmpty) 'mimeType': mimeType,
      };
}

/// 工具调用结果（`tools/call` 的 `result`）。
class McpToolResult {
  const McpToolResult({
    this.content = const <McpToolContent>[],
    this.isError = false,
    this.structuredContent = const <String, dynamic>{},
    this.raw = const <String, dynamic>{},
  });

  final List<McpToolContent> content;

  /// 工具执行是否失败（协议层成功、业务层失败）。
  final bool isError;

  /// 结构化结果（如 `{elementIds, affectedElements}`）。
  final Map<String, dynamic> structuredContent;

  final Map<String, dynamic> raw;

  /// 全部文本内容拼接（便于直接展示）。
  String get text => content
      .where((McpToolContent c) => c.type == 'text')
      .map((McpToolContent c) => c.text)
      .join('\n');

  /// 是否需要客户端确认（Preview / Confirm 级别，§6.5）。
  bool get requiresConfirmation =>
      structuredContent['requiresConfirmation'] == true;

  /// 确认 id（需确认时由服务端下发）。
  String get confirmationId => structuredContent['confirmationId'] is String
      ? structuredContent['confirmationId'] as String
      : '';

  /// 预览内容（受影响范围等）。
  Map<String, dynamic> get preview => structuredContent['preview'] is Map
      ? Map<String, dynamic>.from(structuredContent['preview'] as Map)
      : const <String, dynamic>{};

  /// 受影响元素 id 列表（存在时）。
  List<String> get affectedElements =>
      structuredContent['affectedElements'] is List
          ? (structuredContent['affectedElements'] as List)
              .whereType<String>()
              .toList(growable: false)
          : const <String>[];

  factory McpToolResult.fromJson(Map<String, dynamic> json) {
    final Object? content = json['content'];
    return McpToolResult(
      content: content is List
          ? content
              .whereType<Map<dynamic, dynamic>>()
              .map((Map<dynamic, dynamic> m) =>
                  McpToolContent.fromJson(Map<String, dynamic>.from(m)))
              .toList(growable: false)
          : const <McpToolContent>[],
      isError: json['isError'] == true,
      structuredContent: json['structuredContent'] is Map
          ? Map<String, dynamic>.from(json['structuredContent'] as Map)
          : const <String, dynamic>{},
      raw: json,
    );
  }

  @override
  String toString() =>
      'McpToolResult(isError=$isError, content=${content.length})';
}
