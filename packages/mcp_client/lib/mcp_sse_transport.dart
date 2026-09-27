/// MCP SSE 传输（《MCP Server 详细设计》§4.2）。
///
/// 客户端 GET 事件流获取 `endpoint`，后续以 HTTP POST 发送 JSON-RPC，
/// 服务端通过事件流推送响应与通知。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'mcp_transport.dart';

/// 基于 Server-Sent Events 的传输。
class McpSseTransport extends McpTransportBase {
  McpSseTransport({
    required this.sseUri,
    this.headers = const <String, String>{},
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// SSE 事件流地址（如 `https://host/mcp/sse`）。
  final Uri sseUri;

  /// 附加请求头（认证等）。
  final Map<String, String> headers;

  final http.Client _http;

  /// 服务端下发的事件流连接。
  StreamSubscription<String>? _sseSub;

  /// 服务端告知的 POST 端点（`endpoint` 事件）。
  Uri? _messageEndpoint;

  /// POST 端点是否已就绪。
  bool get isEndpointReady => _messageEndpoint != null;

  /// 当前 POST 端点。
  Uri? get messageEndpoint => _messageEndpoint;

  @override
  Future<void> start() async {
    if (isRunning) {
      return;
    }
    final http.Request request = http.Request('GET', sseUri);
    request.headers['Accept'] = 'text/event-stream';
    request.headers.addAll(headers);
    final http.StreamedResponse response = await _http.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException(
        'SSE handshake failed with HTTP ${response.statusCode}',
        sseUri,
      );
    }
    setRunning(true);
    _sseSub = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _onLine,
          onError: emitError,
          onDone: () {
            if (isRunning) {
              setRunning(false);
              emitError(StateError('SSE stream closed by server'));
            }
          },
        );
  }

  // ---- SSE 行解析（McpSseDecoder） ----
  late final McpSseDecoder _decoder = McpSseDecoder(onEvent: _onEvent);

  void _onLine(String line) => _decoder.addLine(line);

  void _onEvent(String event, String data) {
    if (event == 'endpoint') {
      _messageEndpoint = sseUri.resolve(data);
      return;
    }
    // `message` 事件或服务端省略 event 字段时均为 JSON-RPC 消息。
    if (event.isEmpty || event == 'message') {
      emitMessage(data);
    }
  }

  @override
  void send(String message) {
    final Uri? endpoint = _messageEndpoint;
    if (endpoint == null) {
      throw StateError('SSE message endpoint is not ready');
    }
    unawaited(_post(endpoint, message));
  }

  Future<void> _post(Uri endpoint, String message) async {
    try {
      final http.Response response = await _http.post(
        endpoint,
        headers: <String, String>{
          'Content-Type': 'application/json',
          ...headers,
        },
        body: message,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        emitError(http.ClientException(
          'SSE POST failed with HTTP ${response.statusCode}: ${response.body}',
          endpoint,
        ));
      }
    } catch (e) {
      emitError(e);
    }
  }

  @override
  Future<void> stop() async {
    if (!isRunning) {
      return;
    }
    setRunning(false);
    await _sseSub?.cancel();
    _sseSub = null;
    _messageEndpoint = null;
  }
}
