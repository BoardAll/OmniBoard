/// 白板 API（Open API §5.1）。
library;

import 'api_client.dart';

class WbBoardsApi {
  const WbBoardsApi(this._client);

  final WbApiClient _client;

  /// `GET /boards` — 列出白板（分页）。
  Future<WbPageResult<WbApiBoard>> list({WbListQuery query = const WbListQuery()}) {
    return _client.requestPaged<WbApiBoard>(
      'GET',
      '/boards',
      query: query.toQuery(),
      fromJson: WbApiBoard.fromJson,
    );
  }

  /// `POST /boards` — 创建白板。
  Future<WbApiBoard> create({
    required String name,
    String description = '',
    String themeId = '',
    String backgroundId = '',
    String? idempotencyKey,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/boards',
      body: <String, dynamic>{
        'name': name,
        if (description.isNotEmpty) 'description': description,
        if (themeId.isNotEmpty) 'themeId': themeId,
        if (backgroundId.isNotEmpty) 'backgroundId': backgroundId,
      },
      idempotencyKey: idempotencyKey,
    );
    return WbApiBoard.fromJson(data);
  }

  /// `GET /boards/{boardId}` — 获取白板。
  Future<WbApiBoard> get(String boardId) async {
    final Map<String, dynamic> data =
        await _client.requestObject('GET', '/boards/$boardId');
    return WbApiBoard.fromJson(data);
  }

  /// `PATCH /boards/{boardId}` — 更新白板（仅传递需修改字段）。
  Future<WbApiBoard> update(
    String boardId, {
    String? name,
    String? description,
    String? themeId,
    String? backgroundId,
    Map<String, dynamic>? extra,
  }) async {
    final Map<String, dynamic> patch = <String, dynamic>{
      if (name != null) 'name': name,
      if (description != null) 'description': description,
      if (themeId != null) 'themeId': themeId,
      if (backgroundId != null) 'backgroundId': backgroundId,
      ...?extra,
    };
    final Map<String, dynamic> data =
        await _client.requestObject('PATCH', '/boards/$boardId', body: patch);
    return WbApiBoard.fromJson(data);
  }

  /// `DELETE /boards/{boardId}` — 删除白板。
  Future<void> delete(String boardId) async {
    await _client.send('DELETE', '/boards/$boardId');
  }

  /// `POST /boards/{boardId}/share` — 创建分享链接。
  Future<WbApiShareResult> share(
    String boardId, {
    String permission = 'view',
    int? expiresInSeconds,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/boards/$boardId/share',
      body: <String, dynamic>{
        'permission': permission,
        if (expiresInSeconds != null) 'expiresIn': expiresInSeconds,
      },
    );
    return WbApiShareResult.fromJson(data);
  }

  /// `GET /boards/{boardId}/collaborators` — 列出协作者。
  Future<List<WbApiCollaborator>> collaborators(String boardId) async {
    final List<Map<String, dynamic>> data =
        await _client.requestList('GET', '/boards/$boardId/collaborators');
    return data.map(WbApiCollaborator.fromJson).toList(growable: false);
  }

  /// `POST /boards/{boardId}/collaborators` — 添加协作者。
  Future<WbApiCollaborator> addCollaborator(
    String boardId, {
    required String userId,
    String role = 'viewer',
    List<String>? scopes,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/boards/$boardId/collaborators',
      body: <String, dynamic>{
        'userId': userId,
        'role': role,
        if (scopes != null && scopes.isNotEmpty) 'scopes': scopes,
      },
    );
    return WbApiCollaborator.fromJson(data);
  }

  /// `DELETE /boards/{boardId}/collaborators/{userId}` — 移除协作者。
  Future<void> removeCollaborator(String boardId, String userId) async {
    await _client.send('DELETE', '/boards/$boardId/collaborators/$userId');
  }
}
