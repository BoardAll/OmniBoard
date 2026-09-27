/// 评论 API（Open API §5.5）。
library;

import 'api_client.dart';

class WbCommentsApi {
  const WbCommentsApi(this._client);

  final WbApiClient _client;

  /// `GET /boards/{boardId}/comments` — 列出评论（分页）。
  Future<WbPageResult<WbApiComment>> list(
    String boardId, {
    WbListQuery query = const WbListQuery(),
  }) {
    return _client.requestPaged<WbApiComment>(
      'GET',
      '/boards/$boardId/comments',
      query: query.toQuery(),
      fromJson: WbApiComment.fromJson,
    );
  }

  /// `POST /comments` — 创建评论。
  Future<WbApiComment> create({
    required String boardId,
    required String pageId,
    required String content,
    String elementId = '',
    Map<String, dynamic>? anchor,
    String? idempotencyKey,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/comments',
      body: <String, dynamic>{
        'boardId': boardId,
        'pageId': pageId,
        'content': content,
        if (elementId.isNotEmpty) 'elementId': elementId,
        if (anchor != null) 'anchor': anchor,
      },
      idempotencyKey: idempotencyKey,
    );
    return WbApiComment.fromJson(data);
  }

  /// `GET /comments/{commentId}` — 获取评论。
  Future<WbApiComment> get(String commentId) async {
    final Map<String, dynamic> data =
        await _client.requestObject('GET', '/comments/$commentId');
    return WbApiComment.fromJson(data);
  }

  /// `PATCH /comments/{commentId}` — 更新评论内容。
  Future<WbApiComment> update(
    String commentId, {
    String? content,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'PATCH',
      '/comments/$commentId',
      body: <String, dynamic>{
        if (content != null) 'content': content,
      },
    );
    return WbApiComment.fromJson(data);
  }

  /// `DELETE /comments/{commentId}` — 删除评论。
  Future<void> delete(String commentId) async {
    await _client.send('DELETE', '/comments/$commentId');
  }

  /// `POST /comments/{commentId}/reply` — 回复评论。
  Future<WbApiCommentReply> reply(String commentId, String content) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/comments/$commentId/reply',
      body: <String, dynamic>{'content': content},
    );
    return WbApiCommentReply.fromJson(data);
  }

  /// `POST /comments/{commentId}/resolve` — 标记解决 / 取消解决。
  Future<WbApiComment> resolve(String commentId, {bool resolved = true}) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/comments/$commentId/resolve',
      body: <String, dynamic>{'resolved': resolved},
    );
    return WbApiComment.fromJson(data);
  }
}
