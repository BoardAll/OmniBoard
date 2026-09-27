/// MCP Streamable HTTP 传输（《MCP Server 详细设计》§4.3）。
///
/// 单端点 POST 发送 JSON-RPC；响应可为 `application/json` 单条消息，
/// 或 `text/event-stream` 流式消息。可选 GET 流接收服务端主动通知。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'mcp_protocol.dart';
import 'mcp_transport.dart';

/// 基于 Streamable HTTP 的单端点传输。
class McpHttpTransport extends McpTransportBase {
  McpHttpTransport({
    required this.endpoint,
    this.headers = const <String, String>{},
    http.Client? httpClient,
    this.protocolVersion = mcpDefaultProtocolVersion,
  }) : _http = httpClient ?? http.Client();

  /// 单端点地址（如 `https://host/mcp`）。
  final Uri endpoint;

  /// 附加请求头（认证等）。
  final Map<String, String> headers;

  /// 协议版本（写入 `MCP-Protocol-Version` 头）。
  final String protocolVersion;

  final http.Client _http;

  /// 服务端分配的会话 id（`Mcp-Session-Id` 响应头）。
  String? sessionId;

  /// 服务端主动消息的 GET 流订阅。
  StreamSubscription<String>? _serverStreamSub;

  Map<String, String> _baseHeaders() => <String, String>{
        'Accept': 'application/json, text/event-stream',
        'MCP-Protocol-Version': protocolVersion,
        if (sessionId != null) 'Mcp-Session-Id': sessionId!,
        ...headers,
      };

  @override
  Future<void> start() async {
    if (isRunning) {
      return;
    }
    setRunning(true);
  }

  /// 打开服务端主动消息流（`GET` + `text/event-stream`）。
  ///
  /// 服务端不支持时返回 false（HTTP 405 等）并保持安静。
  Future<bool> openServerStream() async {
    if (!isRunning) {
      throw StateError('HTTP transport is not running');
    }
    final http.Request request = http.Request('GET', endpoint);
    request.headers.addAll(_baseHeaders());
    final http.StreamedResponse response = await _http.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return false;
    }
    _captureSession(response);
    final McpSseDecoder decoder =
        McpSseDecoder(onEvent: _onServerStreamEvent);
    _serverStreamSub = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(decoder.addLine, onError: emitError);
    return true;
  }

  void _onServerStreamEvent(String event, String data) {
    if (event.isEmpty || event == 'message') {
      emitMessage(data);
    }
  }

  @override
  void send(String message) {
    if (!isRunning) {
      throw StateError('HTTP transport is not running');
    }
    unawaited(_post(message));
  }

  Future<void> _post(String message) async {
    try {
      final http.Request request = http.Request('POST', endpoint);
      request.headers.addAll(_baseHeaders());
      request.headers['Content-Type'] = 'application/json';
      request.body = message;
      final http.StreamedResponse streamed = await _http.send(request);
      _captureSession(streamed);

      final String contentType =
          streamed.headers['content-type'] ?? streamed.headers['Content-Type'] ?? '';
      if (streamed.statusCode == 202) {
        return; // 已接受，响应稍后经服务端流到达。
      }
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        final String body = await streamed.stream.bytesToString();
        emitError(http.ClientException(
          'HTTP transport POST failed with ${streamed.statusCode}: $body',
          endpoint,
        ));
        return;
      }
      if (contentType.contains('text/event-stream')) {
        final McpSseDecoder decoder =
            McpSseDecoder(onEvent: _onServerStreamEvent);
        await streamed.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(decoder.addLine);
        return;
      }
      final String body = await streamed.stream.bytesToString();
      if (body.trim().isNotEmpty) {
        _emitJsonBody(body);
      }
    } catch (e) {
      emitError(e);
    }
  }

  void _emitJsonBody(String body) {
    final Object? decoded = jsonDecode(body);
    if (decoded is List) {
      for (final Object? item in decoded) {
        emitMessage(jsonEncode(item));
      }
    } else {
      emitMessage(body);
    }
  }

  void _captureSession(http.BaseResponse response) {
    final String? id = response.headers['mcp-session-id'] ??
        response.headers['Mcp-Session-Id'];
    if (id != null && id.isNotEmpty) {
      sessionId = id;
    }
  }

  @override
  Future<void> stop() async {
    if (!isRunning) {
      return;
    }
    setRunning(false);
    await _serverStreamSub?.cancel();
    _serverStreamSub = null;
  }
}
