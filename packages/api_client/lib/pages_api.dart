/// 页面 API（Open API §5.2）。
library;

import 'api_client.dart';

class WbPagesApi {
  const WbPagesApi(this._client);

  final WbApiClient _client;

  /// `GET /boards/{boardId}/pages` — 列出页面（分页）。
  Future<WbPageResult<WbApiPage>> list(
    String boardId, {
    WbListQuery query = const WbListQuery(),
  }) {
    return _client.requestPaged<WbApiPage>(
      'GET',
      '/boards/$boardId/pages',
      query: query.toQuery(),
      fromJson: WbApiPage.fromJson,
    );
  }

  /// `POST /boards/{boardId}/pages` — 创建页面。
  Future<WbApiPage> create(
    String boardId, {
    required String name,
    String backgroundId = '',
    WbApiViewport? viewport,
    String? idempotencyKey,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/boards/$boardId/pages',
      body: <String, dynamic>{
        'name': name,
        if (backgroundId.isNotEmpty) 'backgroundId': backgroundId,
        if (viewport != null) 'viewport': viewport.toJson(),
      },
      idempotencyKey: idempotencyKey,
    );
    return WbApiPage.fromJson(data);
  }

  /// `GET /pages/{pageId}` — 获取页面。
  Future<WbApiPage> get(String pageId) async {
    final Map<String, dynamic> data =
        await _client.requestObject('GET', '/pages/$pageId');
    return WbApiPage.fromJson(data);
  }

  /// `PATCH /pages/{pageId}` — 更新页面。
  Future<WbApiPage> update(
    String pageId, {
    String? name,
    String? backgroundId,
    bool? locked,
    bool? hidden,
    Map<String, dynamic>? extra,
  }) async {
    final Map<String, dynamic> patch = <String, dynamic>{
      if (name != null) 'name': name,
      if (backgroundId != null) 'backgroundId': backgroundId,
      if (locked != null) 'locked': locked,
      if (hidden != null) 'hidden': hidden,
      ...?extra,
    };
    final Map<String, dynamic> data =
        await _client.requestObject('PATCH', '/pages/$pageId', body: patch);
    return WbApiPage.fromJson(data);
  }

  /// `DELETE /pages/{pageId}` — 删除页面。
  Future<void> delete(String pageId) async {
    await _client.send('DELETE', '/pages/$pageId');
  }

  /// `POST /pages/{pageId}/duplicate` — 复制页面（可指定目标位置）。
  Future<WbApiPage> duplicate(String pageId, {int? targetIndex}) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/pages/$pageId/duplicate',
      body: <String, dynamic>{
        if (targetIndex != null) 'targetIndex': targetIndex,
      },
    );
    return WbApiPage.fromJson(data);
  }

  /// `POST /pages/{pageId}/move` — 移动页面（同板换序或跨板移动）。
  Future<WbApiPage> move(
    String pageId, {
    required int index,
    String? targetBoardId,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/pages/$pageId/move',
      body: <String, dynamic>{
        'index': index,
        if (targetBoardId != null) 'targetBoardId': targetBoardId,
      },
    );
    return WbApiPage.fromJson(data);
  }

  /// `POST /pages/{pageId}/split` — 拆分页面，返回拆出的新页面。
  Future<List<WbApiPage>> split(
    String pageId, {
    Map<String, dynamic>? options,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/pages/$pageId/split',
      body: options ?? const <String, dynamic>{},
    );
    final Object? pages = data['pages'];
    if (pages is List) {
      return pages
          .whereType<Map<dynamic, dynamic>>()
          .map((Map<dynamic, dynamic> m) =>
              WbApiPage.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false);
    }
    return data.isEmpty ? const <WbApiPage>[] : <WbApiPage>[WbApiPage.fromJson(data)];
  }

  /// `POST /pages/merge` — 合并多个页面为一个，返回合并后的页面。
  Future<WbApiPage> merge({
    required List<String> pageIds,
    String? name,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/pages/merge',
      body: <String, dynamic>{
        'pageIds': pageIds,
        if (name != null) 'name': name,
      },
    );
    return WbApiPage.fromJson(data);
  }

  /// `GET /pages/{pageId}/thumbnail` — 获取缩略图信息（如 url / base64）。
  Future<Map<String, dynamic>> thumbnail(
    String pageId, {
    int? width,
    int? height,
  }) {
    return _client.requestObject(
      'GET',
      '/pages/$pageId/thumbnail',
      query: <String, String>{
        if (width != null) 'width': '$width',
        if (height != null) 'height': '$height',
      },
    );
  }

  /// 构造缩略图直链（可直接用于 `Image.network`）。
  Uri thumbnailUrl(String pageId, {int? width, int? height}) {
    return _client.buildUri(
      '/pages/$pageId/thumbnail',
      query: <String, String>{
        if (width != null) 'width': '$width',
        if (height != null) 'height': '$height',
      },
    );
  }
}
