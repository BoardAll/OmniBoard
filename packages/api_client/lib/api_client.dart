/// Whiteboard Open API 客户端核心（《OpenAPI 规范》§4）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth.dart';
import 'errors.dart';
import 'pagination.dart';

// ---------------------------------------------------------------------------
// Barrel：统一导出公开 API（模型 / 错误 / 分页 / 认证 / 9 个 API 服务）。
// ---------------------------------------------------------------------------
export 'auth.dart';
export 'errors.dart';
export 'pagination.dart';
export 'models/board.dart';
export 'models/page.dart';
export 'models/element.dart';
export 'models/connector.dart';
export 'models/comment.dart';
export 'models/export_job.dart';
export 'models/history.dart';
export 'models/session.dart';
export 'boards_api.dart';
export 'pages_api.dart';
export 'elements_api.dart';
export 'connectors_api.dart';
export 'comments_api.dart';
export 'exports_api.dart';
export 'history_api.dart';
export 'ai_api.dart';
export 'mcp_api.dart';

/// 响应信封：`{ok, data, error, meta}`（§4.4）。
class WbApiEnvelope {
  const WbApiEnvelope({
    required this.data,
    required this.meta,
    this.statusCode = 200,
    this.requestId = '',
  });

  final Object? data;
  final Map<String, dynamic> meta;
  final int statusCode;
  final String requestId;
}

/// 核心 HTTP 客户端：统一处理认证头 / 版本头 / 幂等键 / 信封解析 / 错误抛出。
///
/// ```dart
/// final WbApiClient client = WbApiClient(
///   baseUrl: 'https://api.whiteboard.example.com/v1',
///   auth: const WbAuth.bearer('eyJ...'),
/// );
/// final WbApiBoard board = await WbBoardsApi(client).create(name: '需求梳理');
/// ```
class WbApiClient {
  WbApiClient({
    this.baseUrl = defaultBaseUrl,
    this.auth,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  }) : _http = httpClient ?? http.Client();

  /// 默认 Base URL（§4.1）。
  static const String defaultBaseUrl = 'https://api.whiteboard.example.com/v1';

  /// API 版本（`X-API-Version`，§4.2）。
  static const String apiVersion = '1';

  final String baseUrl;

  /// 单请求超时。
  final Duration timeout;

  final http.Client _http;

  /// 认证凭据（可在运行时替换，如 token 刷新后）。
  WbAuth? auth;

  /// 发起请求并返回解析后的信封；失败抛出 [WbApiException] / [WbNetworkException]。
  Future<WbApiEnvelope> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    final Uri uri = buildUri(path, query: query);
    final http.Request request = http.Request(method, uri);
    request.headers['Accept'] = 'application/json';
    request.headers['X-API-Version'] = apiVersion;
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    final WbAuth? auth = this.auth;
    if (auth != null) {
      request.headers.addAll(auth.toHeaders());
    }
    if (extraHeaders != null) {
      request.headers.addAll(extraHeaders);
    }

    http.Response response;
    try {
      final http.StreamedResponse streamed =
          await _http.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed);
    } on TimeoutException catch (e) {
      throw WbNetworkException('request timed out after $timeout', e);
    } catch (e) {
      throw WbNetworkException('network failure: $e', e);
    }
    return _decodeEnvelope(response);
  }

  /// 拼接完整 URI（baseUrl 去尾 `/`，path 保证前缀 `/`）。
  Uri buildUri(String path, {Map<String, String>? query}) {
    final String normalizedBase =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final String normalizedPath = path.startsWith('/') ? path : '/$path';
    final Uri uri = Uri.parse('$normalizedBase$normalizedPath');
    if (query == null || query.isEmpty) {
      return uri;
    }
    return uri.replace(queryParameters: <String, String>{
      ...uri.queryParameters,
      ...query,
    });
  }

  /// 请求并返回 `data` 对象（要求是 Map）。
  Future<Map<String, dynamic>> requestObject(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? idempotencyKey,
  }) async {
    final WbApiEnvelope envelope =
        await send(method, path, query: query, body: body, idempotencyKey: idempotencyKey);
    final Object? data = envelope.data;
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return const <String, dynamic>{};
  }

  /// 请求并返回 `data` 列表（元素为 Map）。
  Future<List<Map<String, dynamic>>> requestList(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? idempotencyKey,
  }) async {
    final WbApiEnvelope envelope =
        await send(method, path, query: query, body: body, idempotencyKey: idempotencyKey);
    return _extractList(envelope.data);
  }

  /// 请求分页列表并映射为 [WbPageResult]。
  Future<WbPageResult<T>> requestPaged<T>(
    String method,
    String path, {
    required T Function(Map<String, dynamic>) fromJson,
    Map<String, String>? query,
    Object? body,
    String? idempotencyKey,
  }) async {
    final WbApiEnvelope envelope =
        await send(method, path, query: query, body: body, idempotencyKey: idempotencyKey);
    final List<Map<String, dynamic>> items = _extractList(envelope.data);
    final List<T> mapped = items.map(fromJson).toList(growable: false);
    final Map<String, dynamic> meta = envelope.meta;
    final Object? nextCursor = meta['nextCursor'];
    final Object? hasMore = meta['hasMore'];
    final Object? total = meta['total'];
    return WbPageResult<T>(
      items: mapped,
      nextCursor: nextCursor is String ? nextCursor : '',
      hasMore: hasMore is bool ? hasMore : false,
      total: total is num ? total.toInt() : mapped.length,
      requestId: envelope.requestId,
    );
  }

  /// 关闭底层连接池。
  void close() => _http.close();

  WbApiEnvelope _decodeEnvelope(http.Response response) {
    Map<String, dynamic>? map;
    try {
      final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) {
        map = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      map = null;
    }
    final int status = response.statusCode;
    final bool httpOk = status >= 200 && status < 300;
    final Object? ok = map?['ok'];
    final Object? error = map?['error'];
    final Map<String, dynamic> meta = map?['meta'] is Map
        ? Map<String, dynamic>.from(map!['meta'] as Map)
        : const <String, dynamic>{};
    if (!httpOk || ok == false) {
      String code = WbApiErrorCodes.fromStatus(status);
      String message = 'HTTP $status';
      String? detail;
      if (error is Map) {
        if (error['code'] is String) {
          code = error['code'] as String;
        }
        if (error['message'] is String) {
          message = error['message'] as String;
        }
        if (error['detail'] is String) {
          detail = error['detail'] as String;
        }
      }
      throw WbApiException(
        code: code,
        message: message,
        detail: detail,
        statusCode: status,
        requestId: meta['requestId'] is String ? meta['requestId'] as String : '',
      );
    }
    return WbApiEnvelope(
      data: map?['data'],
      meta: meta,
      statusCode: status,
      requestId: meta['requestId'] is String ? meta['requestId'] as String : '',
    );
  }

  static List<Map<String, dynamic>> _extractList(Object? data) {
    if (data is! List) {
      return const <Map<String, dynamic>>[];
    }
    return data
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> m) => Map<String, dynamic>.from(m))
        .toList(growable: false);
  }
}
