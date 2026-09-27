/// 导出 API（Open API §5.6）。
library;

import 'api_client.dart';

class WbExportsApi {
  const WbExportsApi(this._client);

  final WbApiClient _client;

  /// `POST /boards/{boardId}/export` — 导出整块白板（异步任务）。
  Future<WbApiExportJob> exportBoard(
    String boardId,
    WbApiExportRequest request, {
    String? idempotencyKey,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/boards/$boardId/export',
      body: request.toJson(),
      idempotencyKey: idempotencyKey,
    );
    return WbApiExportJob.fromJson(data);
  }

  /// `POST /pages/{pageId}/export` — 导出单页（异步任务）。
  Future<WbApiExportJob> exportPage(
    String pageId,
    WbApiExportRequest request, {
    String? idempotencyKey,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/pages/$pageId/export',
      body: request.toJson(),
      idempotencyKey: idempotencyKey,
    );
    return WbApiExportJob.fromJson(data);
  }

  /// `GET /exports/{exportId}` — 查询导出任务状态。
  Future<WbApiExportJob> get(String exportId) async {
    final Map<String, dynamic> data =
        await _client.requestObject('GET', '/exports/$exportId');
    return WbApiExportJob.fromJson(data);
  }

  /// 轮询导出任务直到完成 / 失败。
  ///
  /// [interval] 轮询间隔，[maxAttempts] 最大轮询次数（超出视为超时）。
  Future<WbApiExportJob> waitUntilDone(
    String exportId, {
    Duration interval = const Duration(seconds: 2),
    int maxAttempts = 60,
  }) async {
    WbApiExportJob job = await get(exportId);
    int attempts = 0;
    while (!job.isDone && !job.isFailed && attempts < maxAttempts) {
      await Future<void>.delayed(interval);
      job = await get(exportId);
      attempts++;
    }
    return job;
  }

  /// 构造下载直链（`GET /exports/{exportId}/download`）。
  Uri downloadUri(String exportId, {bool inline = false}) {
    return _client.buildUri(
      '/exports/$exportId/download',
      query: inline ? const <String, String>{'inline': 'true'} : null,
    );
  }
}
