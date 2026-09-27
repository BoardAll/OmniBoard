/// MCP Prompts 能力模型（《MCP Server 详细设计》§8）。
library;

/// 提示模板定义（`prompts/list` 结果项）。
class McpPrompt {
  const McpPrompt({
    required this.name,
    this.description = '',
    this.arguments = const <McpPromptArgument>[],
    this.raw = const <String, dynamic>{},
  });

  final String name;
  final String description;
  final List<McpPromptArgument> arguments;

  final Map<String, dynamic> raw;

  factory McpPrompt.fromJson(Map<String, dynamic> json) {
    final Object? arguments = json['arguments'];
    return McpPrompt(
      name: json['name'] is String ? json['name'] as String : '',
      description:
          json['description'] is String ? json['description'] as String : '',
      arguments: arguments is List
          ? arguments
              .whereType<Map<dynamic, dynamic>>()
              .map((Map<dynamic, dynamic> m) =>
                  McpPromptArgument.fromJson(Map<String, dynamic>.from(m)))
              .toList(growable: false)
          : const <McpPromptArgument>[],
      raw: json,
    );
  }

  @override
  String toString() => 'McpPrompt($name, ${arguments.length} args)';
}

/// 提示参数定义。
class McpPromptArgument {
  const McpPromptArgument({
    required this.name,
    this.description = '',
    this.required = false,
  });

  final String name;
  final String description;
  final bool required;

  factory McpPromptArgument.fromJson(Map<String, dynamic> json) {
    return McpPromptArgument(
      name: json['name'] is String ? json['name'] as String : '',
      description:
          json['description'] is String ? json['description'] as String : '',
      required: json['required'] == true,
    );
  }
}

/// 提示消息内容块。
class McpPromptContent {
  const McpPromptContent({required this.type, this.text = ''});

  /// text（当前仅支持文本）。
  final String type;
  final String text;

  factory McpPromptContent.fromJson(Map<String, dynamic> json) {
    return McpPromptContent(
      type: json['type'] is String ? json['type'] as String : 'text',
      text: json['text'] is String ? json['text'] as String : '',
    );
  }
}

/// 提示消息。
class McpPromptMessage {
  const McpPromptMessage({required this.role, required this.content});

  /// user / assistant。
  final String role;
  final McpPromptContent content;

  factory McpPromptMessage.fromJson(Map<String, dynamic> json) {
    return McpPromptMessage(
      role: json['role'] is String ? json['role'] as String : 'user',
      content: json['content'] is Map
          ? McpPromptContent.fromJson(
              Map<String, dynamic>.from(json['content'] as Map))
          : const McpPromptContent(type: 'text'),
    );
  }
}

/// 提示获取结果（`prompts/get` 的 `result`）。
class McpPromptResult {
  const McpPromptResult({
    this.description = '',
    this.messages = const <McpPromptMessage>[],
    this.raw = const <String, dynamic>{},
  });

  final String description;
  final List<McpPromptMessage> messages;

  final Map<String, dynamic> raw;

  /// 全部消息文本拼接。
  String get text => messages
      .map((McpPromptMessage m) => m.content.text)
      .where((String t) => t.isNotEmpty)
      .join('\n');

  factory McpPromptResult.fromJson(Map<String, dynamic> json) {
    final Object? messages = json['messages'];
    return McpPromptResult(
      description:
          json['description'] is String ? json['description'] as String : '',
      messages: messages is List
          ? messages
              .whereType<Map<dynamic, dynamic>>()
              .map((Map<dynamic, dynamic> m) =>
                  McpPromptMessage.fromJson(Map<String, dynamic>.from(m)))
              .toList(growable: false)
          : const <McpPromptMessage>[],
      raw: json,
    );
  }
}

/// 内置提示模板名（§8.3）。
abstract final class McpBuiltinPrompts {
  static const String brainstorm = 'brainstorm';
  static const String flowchart = 'flowchart';
  static const String mindmap = 'mindmap';
  static const String summarize = 'summarize';
  static const String cluster = 'cluster';
  static const String vote = 'vote';
  static const String userJourney = 'userJourney';
  static const String swot = 'swot';
  static const String retrospective = 'retrospective';
  static const String kanban = 'kanban';
}
