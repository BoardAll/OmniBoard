/// MCP Resources 能力模型（《MCP Server 详细设计》§7）。
library;

/// 资源定义（`resources/list` 结果项）。
class McpResource {
  const McpResource({
    required this.uri,
    this.name = '',
    this.description = '',
    this.mimeType = '',
    this.raw = const <String, dynamic>{},
  });

  /// 资源 URI（`whiteboard://boards/{boardId}/...`）。
  final String uri;
  final String name;
  final String description;
  final String mimeType;

  final Map<String, dynamic> raw;

  factory McpResource.fromJson(Map<String, dynamic> json) {
    String readStr(String key) => json[key] is String ? json[key] as String : '';
    return McpResource(
      uri: readStr('uri'),
      name: readStr('name'),
      description: readStr('description'),
      mimeType: readStr('mimeType'),
      raw: json,
    );
  }

  @override
  String toString() => 'McpResource($uri)';
}

/// 资源内容（`resources/read` 的 `contents[]` 项）。
class McpResourceContent {
  const McpResourceContent({
    required this.uri,
    this.mimeType = '',
    this.text = '',
    this.blob = '',
  });

  final String uri;
  final String mimeType;

  /// 文本内容（JSON / text 资源）。
  final String text;

  /// base64 内容（二进制资源，如缩略图）。
  final String blob;

  factory McpResourceContent.fromJson(Map<String, dynamic> json) {
    String readStr(String key) => json[key] is String ? json[key] as String : '';
    return McpResourceContent(
      uri: readStr('uri'),
      mimeType: readStr('mimeType'),
      text: readStr('text'),
      blob: readStr('blob'),
    );
  }

  @override
  String toString() =>
      'McpResourceContent($uri, ${text.length} chars, blob=${blob.length})';
}

/// 资源变更通知（`notifications/resources/updated`）。
class McpResourceUpdate {
  const McpResourceUpdate({required this.uri});

  final String uri;
}

/// 白板资源 URI 构建器（§7.3）。
abstract final class McpWhiteboardUris {
  static const String scheme = 'whiteboard';

  /// `whiteboard://boards/{boardId}` — 白板元数据。
  static String board(String boardId) => 'whiteboard://boards/$boardId';

  /// `whiteboard://boards/{boardId}/pages` — 页面列表。
  static String pages(String boardId) =>
      'whiteboard://boards/$boardId/pages';

  /// `whiteboard://boards/{boardId}/pages/{pageId}` — 页面详情。
  static String page(String boardId, String pageId) =>
      'whiteboard://boards/$boardId/pages/$pageId';

  /// `whiteboard://boards/{boardId}/pages/{pageId}/elements` — 页面元素。
  static String elements(String boardId, String pageId) =>
      'whiteboard://boards/$boardId/pages/$pageId/elements';

  /// `whiteboard://boards/{boardId}/pages/{pageId}/thumbnail` — 页面缩略图。
  static String thumbnail(String boardId, String pageId) =>
      'whiteboard://boards/$boardId/pages/$pageId/thumbnail';

  /// `whiteboard://boards/{boardId}/comments` — 评论。
  static String comments(String boardId) =>
      'whiteboard://boards/$boardId/comments';

  /// `whiteboard://boards/{boardId}/history` — 历史。
  static String history(String boardId) =>
      'whiteboard://boards/$boardId/history';

  /// `whiteboard://boards/{boardId}/collaborators` — 协作者。
  static String collaborators(String boardId) =>
      'whiteboard://boards/$boardId/collaborators';

  /// `whiteboard://boards/{boardId}/templates` — 模板。
  static String templates(String boardId) =>
      'whiteboard://boards/$boardId/templates';
}
