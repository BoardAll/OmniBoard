/// MCP 协议基础：JSON-RPC 2.0 消息模型、错误码、方法常量
/// （《MCP Server 详细设计》§2 / §5 / §15 / §18）。
library;

import 'dart:convert';

/// 本客户端支持的 MCP 协议版本（§5.4）。
const List<String> mcpProtocolVersions = <String>[
  '2025-06-18',
  '2024-11-05',
];

/// 默认协议版本（首选协商版本）。
const String mcpDefaultProtocolVersion = '2025-06-18';

/// MCP 方法名常量（§18）。
abstract final class McpMethods {
  static const String initialize = 'initialize';
  static const String initialized = 'notifications/initialized';
  static const String ping = 'ping';
  static const String toolsList = 'tools/list';
  static const String toolsCall = 'tools/call';
  static const String toolsListChanged = 'notifications/tools/list_changed';
  static const String resourcesList = 'resources/list';
  static const String resourcesRead = 'resources/read';
  static const String resourcesSubscribe = 'resources/subscribe';
  static const String resourcesUnsubscribe = 'resources/unsubscribe';
  static const String resourcesUpdated = 'notifications/resources/updated';
  static const String resourcesListChanged =
      'notifications/resources/list_changed';
  static const String promptsList = 'prompts/list';
  static const String promptsGet = 'prompts/get';
  static const String promptsListChanged = 'notifications/prompts/list_changed';
  static const String loggingSetLevel = 'logging/setLevel';
  static const String logMessage = 'notifications/message';
  static const String completionComplete = 'completion/complete';
  static const String shutdown = 'shutdown';
  static const String confirmOperation = 'confirm_operation';
}

/// JSON-RPC / MCP 错误码（§15）。
abstract final class McpErrorCodes {
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;
  static const int serverError = -32000;
  static const int rateLimited = -32001;
  static const int permissionDenied = -32002;
  static const int notFound = -32003;
  static const int conflict = -32004;
  static const int confirmationRequired = -32005;
  static const int cancelled = -32006;

  /// 错误码 → 可读名称。
  static String name(int code) {
    switch (code) {
      case parseError:
        return 'ParseError';
      case invalidRequest:
        return 'InvalidRequest';
      case methodNotFound:
        return 'MethodNotFound';
      case invalidParams:
        return 'InvalidParams';
      case internalError:
        return 'InternalError';
      case serverError:
        return 'ServerError';
      case rateLimited:
        return 'RateLimited';
      case permissionDenied:
        return 'PermissionDenied';
      case notFound:
        return 'NotFound';
      case conflict:
        return 'Conflict';
      case confirmationRequired:
        return 'ConfirmationRequired';
      case cancelled:
        return 'Cancelled';
      default:
        return 'Error($code)';
    }
  }
}

/// JSON-RPC 错误对象。
class McpError {
  const McpError({required this.code, required this.message, this.data});

  final int code;
  final String message;

  /// 附带数据（如 `{scope, toolId}` / `{retryAfter}`）。
  final Object? data;

  factory McpError.fromJson(Map<String, dynamic> json) {
    return McpError(
      code: json['code'] is num ? (json['code'] as num).toInt() : 0,
      message: json['message'] is String ? json['message'] as String : '',
      data: json['data'],
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      };

  /// 附带数据中的字符串字段（如 `scope`）。
  String dataString(String key) {
    final Object? value = data;
    if (value is Map && value[key] is String) {
      return value[key] as String;
    }
    return '';
  }

  @override
  String toString() => 'McpError(${McpErrorCodes.name(code)}): $message';
}

/// 由服务端错误引发的异常。
class McpException implements Exception {
  const McpException(this.error);

  final McpError error;

  int get code => error.code;

  String get message => error.message;

  bool get isRateLimited => error.code == McpErrorCodes.rateLimited;

  bool get isPermissionDenied => error.code == McpErrorCodes.permissionDenied;

  bool get isNotFound => error.code == McpErrorCodes.notFound;

  /// 服务端要求确认（`-32005`），应从 [McpError.data] 读取 confirmationId。
  bool get isConfirmationRequired =>
      error.code == McpErrorCodes.confirmationRequired;

  @override
  String toString() =>
      'McpException(${McpErrorCodes.name(error.code)}): ${error.message}';
}

/// 解析后的入站消息：响应或通知。
sealed class McpMessage {
  const McpMessage();
}

/// JSON-RPC 响应（含 result 或 error）。
class McpResponseMessage extends McpMessage {
  const McpResponseMessage({required this.id, this.result, this.error});

  final int id;
  final Map<String, dynamic>? result;
  final McpError? error;
}

/// JSON-RPC 通知（无 id、无响应）。
class McpNotificationMessage extends McpMessage {
  const McpNotificationMessage({required this.method, this.params});

  final String method;
  final Map<String, dynamic>? params;
}

/// JSON-RPC 编解码工具。
abstract final class McpJsonRpc {
  /// 构造请求 JSON。
  static String buildRequest(int id, String method, [Map<String, dynamic>? params]) {
    return jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    });
  }

  /// 构造通知 JSON。
  static String buildNotification(String method, [Map<String, dynamic>? params]) {
    return jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    });
  }

  /// 解析入站原始消息；解析失败抛出 [FormatException]。
  static McpMessage parseMessage(String raw) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('MCP message must be a JSON object');
    }
    final Map<String, dynamic> map = Map<String, dynamic>.from(decoded);
    final Object? id = map['id'];
    if (id is num) {
      final Object? error = map['error'];
      return McpResponseMessage(
        id: id.toInt(),
        result: map['result'] is Map
            ? Map<String, dynamic>.from(map['result'] as Map)
            : null,
        error: error is Map
            ? McpError.fromJson(Map<String, dynamic>.from(error))
            : null,
      );
    }
    final Object? method = map['method'];
    if (method is String && method.isNotEmpty) {
      return McpNotificationMessage(
        method: method,
        params: map['params'] is Map
            ? Map<String, dynamic>.from(map['params'] as Map)
            : null,
      );
    }
    throw const FormatException('MCP message is neither response nor notification');
  }
}
