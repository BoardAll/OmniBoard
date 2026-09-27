/// 连线 API（Open API §5.4）。
library;

import 'api_client.dart';

class WbConnectorsApi {
  const WbConnectorsApi(this._client);

  final WbApiClient _client;

  /// `GET /pages/{pageId}/connectors` — 列出连线（分页）。
  Future<WbPageResult<WbApiConnector>> list(
    String pageId, {
    WbListQuery query = const WbListQuery(),
  }) {
    return _client.requestPaged<WbApiConnector>(
      'GET',
      '/pages/$pageId/connectors',
      query: query.toQuery(),
      fromJson: WbApiConnector.fromJson,
    );
  }

  /// `POST /pages/{pageId}/connectors` — 创建连线。
  Future<WbApiConnector> create(
    String pageId, {
    required WbApiConnectorDraft draft,
    String? idempotencyKey,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/pages/$pageId/connectors',
      body: draft.toJson(),
      idempotencyKey: idempotencyKey,
    );
    return WbApiConnector.fromJson(data);
  }

  /// `GET /connectors/{connectorId}` — 获取连线。
  Future<WbApiConnector> get(String connectorId) async {
    final Map<String, dynamic> data =
        await _client.requestObject('GET', '/connectors/$connectorId');
    return WbApiConnector.fromJson(data);
  }

  /// `PATCH /connectors/{connectorId}` — 更新连线。
  Future<WbApiConnector> update(
    String connectorId,
    Map<String, dynamic> patch,
  ) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'PATCH',
      '/connectors/$connectorId',
      body: patch,
    );
    return WbApiConnector.fromJson(data);
  }

  /// `DELETE /connectors/{connectorId}` — 删除连线。
  Future<void> delete(String connectorId) async {
    await _client.send('DELETE', '/connectors/$connectorId');
  }
}
