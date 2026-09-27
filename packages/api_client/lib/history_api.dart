/// 历史 API（Open API §5.7）。
library;

import 'api_client.dart';

class WbHistoryApi {
  const WbHistoryApi(this._client);

  final WbApiClient _client;

  /// `GET /boards/{boardId}/history` — 获取历史（撤销 / 重做栈概览）。
  Future<WbApiHistory> get(String boardId) async {
    final Map<String, dynamic> data =
        await _client.requestObject('GET', '/boards/$boardId/history');
    return WbApiHistory.fromJson(data);
  }

  /// `POST /boards/{boardId}/undo` — 撤销一步。
  Future<WbApiUndoResult> undo(String boardId) async {
    final Map<String, dynamic> data =
        await _client.requestObject('POST', '/boards/$boardId/undo');
    return WbApiUndoResult.fromJson(data);
  }

  /// `POST /boards/{boardId}/redo` — 重做一步。
  Future<WbApiUndoResult> redo(String boardId) async {
    final Map<String, dynamic> data =
        await _client.requestObject('POST', '/boards/$boardId/redo');
    return WbApiUndoResult.fromJson(data);
  }

  /// `POST /boards/{boardId}/snapshot` — 创建快照（用于版本回滚 / 存档）。
  Future<Map<String, dynamic>> snapshot(
    String boardId, {
    String? name,
    String? description,
  }) {
    return _client.requestObject(
      'POST',
      '/boards/$boardId/snapshot',
      body: <String, dynamic>{
        if (name != null) 'name': name,
        if (description != null) 'description': description,
      },
    );
  }
}
