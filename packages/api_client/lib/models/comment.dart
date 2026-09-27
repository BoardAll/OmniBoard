/// 评论模型（Open API §5.5）。
class WbApiComment {
  const WbApiComment({
    required this.id,
    this.boardId = '',
    this.pageId = '',
    this.elementId = '',
    this.authorId = '',
    this.content = '',
    this.anchor = const <String, dynamic>{},
    this.resolved = false,
    this.replies = const <WbApiCommentReply>[],
    this.createdAt = '',
    this.updatedAt = '',
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String boardId;
  final String pageId;

  /// 锚定元素（空表示画布坐标评论）。
  final String elementId;

  /// 作者用户 id。
  final String authorId;

  final String content;

  /// 锚点（画布坐标 `{x,y}` 或元素相对锚点）。
  final Map<String, dynamic> anchor;

  final bool resolved;
  final List<WbApiCommentReply> replies;
  final String createdAt;
  final String updatedAt;

  final Map<String, dynamic> raw;

  factory WbApiComment.fromJson(Map<String, dynamic> json) {
    String readStr(String key) => json[key] is String ? json[key] as String : '';
    final Object? replies = json['replies'];
    return WbApiComment(
      id: readStr('id'),
      boardId: readStr('boardId'),
      pageId: readStr('pageId'),
      elementId: readStr('elementId'),
      authorId: json['authorId'] is String
          ? json['authorId'] as String
          : readStr('createdBy'),
      content: readStr('content'),
      anchor: json['anchor'] is Map
          ? Map<String, dynamic>.from(json['anchor'] as Map)
          : const <String, dynamic>{},
      resolved: json['resolved'] is bool ? json['resolved'] as bool : false,
      replies: replies is List
          ? replies
              .whereType<Map<dynamic, dynamic>>()
              .map((Map<dynamic, dynamic> m) =>
                  WbApiCommentReply.fromJson(Map<String, dynamic>.from(m)))
              .toList(growable: false)
          : const <WbApiCommentReply>[],
      createdAt: readStr('createdAt'),
      updatedAt: readStr('updatedAt'),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'id': id,
          'boardId': boardId,
          'pageId': pageId,
          if (elementId.isNotEmpty) 'elementId': elementId,
          'content': content,
          if (anchor.isNotEmpty) 'anchor': anchor,
          'resolved': resolved,
          'createdAt': createdAt,
          'updatedAt': updatedAt,
        };

  @override
  String toString() => 'WbApiComment($id, resolved=$resolved)';
}

/// 评论回复。
class WbApiCommentReply {
  const WbApiCommentReply({
    required this.id,
    this.authorId = '',
    this.content = '',
    this.createdAt = '',
  });

  final String id;
  final String authorId;
  final String content;
  final String createdAt;

  factory WbApiCommentReply.fromJson(Map<String, dynamic> json) {
    String readStr(String key) => json[key] is String ? json[key] as String : '';
    return WbApiCommentReply(
      id: readStr('id'),
      authorId: json['authorId'] is String
          ? json['authorId'] as String
          : readStr('createdBy'),
      content: readStr('content'),
      createdAt: readStr('createdAt'),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'authorId': authorId,
        'content': content,
        'createdAt': createdAt,
      };
}
