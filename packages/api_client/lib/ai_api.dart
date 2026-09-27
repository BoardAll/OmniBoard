/// AI 助手 API（Open API §5.8）。
library;

import 'api_client.dart';

class WbAiApi {
  const WbAiApi(this._client);

  final WbApiClient _client;

  /// `POST /ai/sessions` — 创建 AI 会话。
  Future<WbApiSession> createSession({
    required String boardId,
    String? userId,
    String? idempotencyKey,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/ai/sessions',
      body: <String, dynamic>{
        'boardId': boardId,
        if (userId != null) 'userId': userId,
      },
      idempotencyKey: idempotencyKey,
    );
    return WbApiSession.fromJson(data);
  }

  /// `GET /ai/sessions/{sessionId}` — 获取会话（含上下文与消息数）。
  Future<WbApiSession> getSession(String sessionId) async {
    final Map<String, dynamic> data =
        await _client.requestObject('GET', '/ai/sessions/$sessionId');
    return WbApiSession.fromJson(data);
  }

  /// `POST /ai/sessions/{sessionId}/messages` — 发送文本消息。
  ///
  /// 返回助手应答消息（可能携带待确认的 [WbApiToolCall]）。
  Future<WbApiMessage> sendMessage(String sessionId, String message) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/ai/sessions/$sessionId/messages',
      body: <String, dynamic>{'message': message},
    );
    return _unwrapMessage(data);
  }

  /// `POST /ai/sessions/{sessionId}/audio` — 发送语音（base64 音频）。
  Future<WbApiMessage> sendAudio(String sessionId, String audioData) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/ai/sessions/$sessionId/audio',
      body: <String, dynamic>{'audio': audioData},
    );
    return _unwrapMessage(data);
  }

  /// `GET /ai/sessions/{sessionId}/messages` — 获取会话消息（分页）。
  Future<WbPageResult<WbApiMessage>> listMessages(
    String sessionId, {
    WbListQuery query = const WbListQuery(),
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'GET',
      '/ai/sessions/$sessionId/messages',
      query: query.toQuery(),
    );
    final Object? messages = data['messages'] ?? data['items'];
    final List<WbApiMessage> items = messages is List
        ? messages
            .whereType<Map<dynamic, dynamic>>()
            .map((Map<dynamic, dynamic> m) =>
                WbApiMessage.fromJson(Map<String, dynamic>.from(m)))
            .toList(growable: false)
        : const <WbApiMessage>[];
    return WbPageResult<WbApiMessage>(
      items: items,
      total: data['count'] is num ? (data['count'] as num).toInt() : items.length,
    );
  }

  /// `POST /ai/toolCalls/{toolCallId}/execute` — 执行待确认的工具调用。
  Future<Map<String, dynamic>> executeToolCall(String toolCallId) {
    return _client.requestObject('POST', '/ai/toolCalls/$toolCallId/execute');
  }

  /// `POST /ai/toolCalls/{toolCallId}/preview` — 预览工具调用影响范围。
  Future<Map<String, dynamic>> previewToolCall(String toolCallId) {
    return _client.requestObject('POST', '/ai/toolCalls/$toolCallId/preview');
  }

  /// `POST /ai/toolCalls/{toolCallId}/cancel` — 取消工具调用。
  Future<void> cancelToolCall(String toolCallId) async {
    await _client.send('POST', '/ai/toolCalls/$toolCallId/cancel');
  }

  /// 宽容解包：服务端可能返回裸消息或 `{message: {...}}`。
  static WbApiMessage _unwrapMessage(Map<String, dynamic> data) {
    final Object? message = data['message'];
    if (message is Map) {
      return WbApiMessage.fromJson(Map<String, dynamic>.from(message));
    }
    return WbApiMessage.fromJson(data);
  }
}
