/// Whiteboard MCP 客户端：协议握手、Tools / Resources / Prompts、
/// 通知与错误的统一入口（《MCP Server 详细设计》§5-§8 / §13）。
library;

import 'dart:async';

import 'mcp_prompts.dart';
import 'mcp_protocol.dart';
import 'mcp_resources.dart';
import 'mcp_tools.dart';
import 'mcp_transport.dart';

export 'mcp_http_transport.dart';
export 'mcp_prompts.dart';
export 'mcp_protocol.dart';
export 'mcp_resources.dart';
export 'mcp_sse_transport.dart';
export 'mcp_stdio_transport.dart';
export 'mcp_tools.dart';
export 'mcp_transport.dart';

/// 客户端信息（`initialize` 参数 `clientInfo`）。
class McpClientInfo {
  const McpClientInfo({this.name = 'whiteboard-client', this.version = '1.0.0'});

  final String name;
  final String version;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'name': name, 'version': version};
}

/// 服务端信息（`initialize` 结果 `serverInfo`）。
class McpServerInfo {
  const McpServerInfo({this.name = '', this.version = ''});

  final String name;
  final String version;

  factory McpServerInfo.fromJson(Map<String, dynamic> json) {
    return McpServerInfo(
      name: json['name'] is String ? json['name'] as String : '',
      version: json['version'] is String ? json['version'] as String : '',
    );
  }
}

/// 初始化结果（`initialize` 的 `result`）。
class McpInitializeResult {
  const McpInitializeResult({
    required this.protocolVersion,
    this.capabilities = const <String, dynamic>{},
    this.serverInfo = const McpServerInfo(),
    this.instructions = '',
    this.raw = const <String, dynamic>{},
  });

  final String protocolVersion;
  final Map<String, dynamic> capabilities;
  final McpServerInfo serverInfo;

  /// 服务端提供的使用说明。
  final String instructions;

  final Map<String, dynamic> raw;

  /// 服务端是否声明支持某能力（tools / resources / prompts / logging）。
  bool supports(String capability) => capabilities.containsKey(capability);

  factory McpInitializeResult.fromJson(Map<String, dynamic> json) {
    return McpInitializeResult(
      protocolVersion: json['protocolVersion'] is String
          ? json['protocolVersion'] as String
          : '',
      capabilities: json['capabilities'] is Map
          ? Map<String, dynamic>.from(json['capabilities'] as Map)
          : const <String, dynamic>{},
      serverInfo: json['serverInfo'] is Map
          ? McpServerInfo.fromJson(
              Map<String, dynamic>.from(json['serverInfo'] as Map))
          : const McpServerInfo(),
      instructions:
          json['instructions'] is String ? json['instructions'] as String : '',
      raw: json,
    );
  }
}

/// MCP 客户端。
///
/// ```dart
/// final client = McpClient(
///   transport: McpHttpTransport(
///     endpoint: Uri.parse('https://host/mcp'),
///     headers: {'Authorization': 'Bearer $token'},
///   ),
/// );
/// await client.connect();
/// final tools = await client.listTools();
/// final result = await client.callTool('element_create', {...});
/// await client.shutdown();
/// ```
class McpClient {
  McpClient({
    required this.transport,
    this.clientInfo = const McpClientInfo(),
    this.requestTimeout = const Duration(seconds: 30),
  });

  final McpTransport transport;
  final McpClientInfo clientInfo;

  /// 单请求超时。
  final Duration requestTimeout;

  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  final StreamController<McpNotificationMessage> _notifications =
      StreamController<McpNotificationMessage>.broadcast(sync: true);
  final StreamController<Object> _errors =
      StreamController<Object>.broadcast(sync: true);

  int _nextId = 1;
  bool _initialized = false;
  McpInitializeResult? _initializeResult;
  StreamSubscription<String>? _messageSub;
  StreamSubscription<Object>? _transportErrorSub;

  /// 服务端通知流（工具变更 / 资源更新 / 日志消息等）。
  Stream<McpNotificationMessage> get notifications => _notifications.stream;

  /// 客户端错误流（传输错误 / 消息解析失败 / 超时）。
  Stream<Object> get errors => _errors.stream;

  bool get isInitialized => _initialized;

  /// 初始化结果（未初始化时为 null）。
  McpInitializeResult? get initializeResult => _initializeResult;

  /// 服务端信息（未初始化时为 null）。
  McpServerInfo? get serverInfo => _initializeResult?.serverInfo;

  /// 协商后的协议版本（未初始化时为空串）。
  String get protocolVersion => _initializeResult?.protocolVersion ?? '';

  /// 启动传输并完成初始化握手（`initialize` + `initialized`）。
  Future<McpInitializeResult> connect() async {
    if (!transport.isRunning) {
      await transport.start();
    }
    _listen();
    return initialize();
  }

  void _listen() {
    _messageSub ??= transport.messages.listen(
      _onMessage,
      onError: _errors.add,
    );
    _transportErrorSub ??= transport.errors.listen(_onTransportError);
  }

  /// 初始化握手（§5）。
  Future<McpInitializeResult> initialize() async {
    final Map<String, dynamic> result = await _request(
      McpMethods.initialize,
      <String, dynamic>{
        'protocolVersion': mcpDefaultProtocolVersion,
        'capabilities': <String, dynamic>{
          'roots': <String, dynamic>{'listChanged': true},
          'sampling': <String, dynamic>{},
        },
        'clientInfo': clientInfo.toJson(),
      },
    );
    final McpInitializeResult info = McpInitializeResult.fromJson(result);
    _initializeResult = info;
    // 发送 initialized 通知（无响应）。
    _notify(McpMethods.initialized);
    _initialized = true;
    return info;
  }

  /// 心跳（`ping`）。
  Future<void> ping() => _request(McpMethods.ping);

  /// 优雅关闭：发送 `shutdown` 后停止传输（§18）。
  Future<void> shutdown() async {
    if (transport.isRunning) {
      try {
        await _request(McpMethods.shutdown);
      } on McpException {
        // 服务端可能不支持 shutdown，忽略。
      } on TimeoutException {
        // 忽略超时，继续关闭。
      }
    }
    _initialized = false;
    await _messageSub?.cancel();
    _messageSub = null;
    await _transportErrorSub?.cancel();
    _transportErrorSub = null;
    await transport.stop();
  }

  /// 释放全部资源（含流关闭），对象不可再使用。
  Future<void> dispose() async {
    await shutdown();
    await _notifications.close();
    await _errors.close();
    _failPending(StateError('MCP client disposed'));
  }

  // ---------------------------------------------------------------- Tools

  /// 列出全部工具（自动翻页，§6.1）。
  Future<List<McpTool>> listTools() async {
    final List<McpTool> tools = <McpTool>[];
    String? cursor;
    int guard = 0;
    do {
      final Map<String, dynamic> result = await _request(
        McpMethods.toolsList,
        <String, dynamic>{'cursor': cursor},
      );
      final Object? page = result['tools'];
      if (page is List) {
        tools.addAll(page
            .whereType<Map<dynamic, dynamic>>()
            .map((Map<dynamic, dynamic> m) =>
                McpTool.fromJson(Map<String, dynamic>.from(m))));
      }
      cursor = result['nextCursor'] is String
          ? result['nextCursor'] as String
          : null;
      guard++;
    } while (cursor != null && cursor.isNotEmpty && guard < 50);
    return tools;
  }

  /// 调用工具（`tools/call`，§6.2）。
  Future<McpToolResult> callTool(
    String name, [
    Map<String, dynamic>? arguments,
  ]) async {
    final Map<String, dynamic> result = await _request(
      McpMethods.toolsCall,
      <String, dynamic>{
        'name': name,
        'arguments': arguments ?? const <String, dynamic>{},
      },
    );
    return McpToolResult.fromJson(result);
  }

  /// 确认（或拒绝）高风险操作（§6.5 / §13.2）。
  Future<McpToolResult> confirmOperation(
    String confirmationId, {
    bool approved = true,
  }) async {
    final Map<String, dynamic> result = await _request(
      McpMethods.toolsCall,
      <String, dynamic>{
        'name': McpMethods.confirmOperation,
        'arguments': <String, dynamic>{
          'confirmationId': confirmationId,
          'approved': approved,
        },
      },
    );
    return McpToolResult.fromJson(result);
  }

  // ------------------------------------------------------------ Resources

  /// 列出资源（自动翻页，§7.1）。
  Future<List<McpResource>> listResources() async {
    final List<McpResource> resources = <McpResource>[];
    String? cursor;
    int guard = 0;
    do {
      final Map<String, dynamic> result = await _request(
        McpMethods.resourcesList,
        <String, dynamic>{'cursor': cursor},
      );
      final Object? page = result['resources'];
      if (page is List) {
        resources.addAll(page
            .whereType<Map<dynamic, dynamic>>()
            .map((Map<dynamic, dynamic> m) =>
                McpResource.fromJson(Map<String, dynamic>.from(m))));
      }
      cursor = result['nextCursor'] is String
          ? result['nextCursor'] as String
          : null;
      guard++;
    } while (cursor != null && cursor.isNotEmpty && guard < 50);
    return resources;
  }

  /// 读取资源（`resources/read`，§7.2）。
  Future<List<McpResourceContent>> readResource(String uri) async {
    final Map<String, dynamic> result = await _request(
      McpMethods.resourcesRead,
      <String, dynamic>{'uri': uri},
    );
    final Object? contents = result['contents'];
    if (contents is! List) {
      return const <McpResourceContent>[];
    }
    return contents
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> m) =>
            McpResourceContent.fromJson(Map<String, dynamic>.from(m)))
        .toList(growable: false);
  }

  /// 订阅资源变更（§7.4）。
  Future<void> subscribe(String uri) =>
      _request(McpMethods.resourcesSubscribe, <String, dynamic>{'uri': uri});

  /// 取消资源订阅。
  Future<void> unsubscribe(String uri) =>
      _request(McpMethods.resourcesUnsubscribe, <String, dynamic>{'uri': uri});

  // -------------------------------------------------------------- Prompts

  /// 列出提示模板（自动翻页，§8.1）。
  Future<List<McpPrompt>> listPrompts() async {
    final List<McpPrompt> prompts = <McpPrompt>[];
    String? cursor;
    int guard = 0;
    do {
      final Map<String, dynamic> result = await _request(
        McpMethods.promptsList,
        <String, dynamic>{'cursor': cursor},
      );
      final Object? page = result['prompts'];
      if (page is List) {
        prompts.addAll(page
            .whereType<Map<dynamic, dynamic>>()
            .map((Map<dynamic, dynamic> m) =>
                McpPrompt.fromJson(Map<String, dynamic>.from(m))));
      }
      cursor = result['nextCursor'] is String
          ? result['nextCursor'] as String
          : null;
      guard++;
    } while (cursor != null && cursor.isNotEmpty && guard < 50);
    return prompts;
  }

  /// 获取提示模板内容（`prompts/get`，§8.2）。
  Future<McpPromptResult> getPrompt(
    String name, {
    Map<String, String>? arguments,
  }) async {
    final Map<String, dynamic> result = await _request(
      McpMethods.promptsGet,
      <String, dynamic>{
        'name': name,
        if (arguments != null) 'arguments': arguments,
      },
    );
    return McpPromptResult.fromJson(result);
  }

  /// 参数补全（`completion/complete`，§18）。
  Future<Map<String, dynamic>> complete({
    required String refType,
    required String refName,
    required String argumentName,
    required String argumentValue,
  }) {
    return _request(McpMethods.completionComplete, <String, dynamic>{
      'ref': <String, dynamic>{'type': refType, 'name': refName},
      'argument': <String, dynamic>{'name': argumentName, 'value': argumentValue},
    });
  }

  /// 设置日志级别（`logging/setLevel`）。
  Future<void> setLoggingLevel(String level) =>
      _request(McpMethods.loggingSetLevel, <String, dynamic>{'level': level});

  // -------------------------------------------------------------- Internals

  /// 发送请求并等待响应（超时抛出 [TimeoutException]）。
  Future<Map<String, dynamic>> _request(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    if (!transport.isRunning) {
      throw StateError('MCP transport is not running');
    }
    final int id = _nextId++;
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    transport.send(McpJsonRpc.buildRequest(id, method, params));
    try {
      return await completer.future.timeout(requestTimeout);
    } on TimeoutException {
      _pending.remove(id);
      final McpError error = McpError(
        code: McpErrorCodes.internalError,
        message: 'request "$method" timed out after $requestTimeout',
      );
      _errors.add(McpException(error));
      throw McpException(error);
    }
  }

  void _notify(String method, [Map<String, dynamic>? params]) {
    transport.send(McpJsonRpc.buildNotification(method, params));
  }

  void _onMessage(String raw) {
    McpMessage message;
    try {
      message = McpJsonRpc.parseMessage(raw);
    } on FormatException catch (e) {
      _errors.add(e);
      return;
    }
    switch (message) {
      case McpResponseMessage(:final int id, :final Map<String, dynamic>? result, :final McpError? error):
        final Completer<Map<String, dynamic>>? completer = _pending.remove(id);
        if (completer == null || completer.isCompleted) {
          return;
        }
        if (error != null) {
          completer.completeError(McpException(error));
        } else {
          completer.complete(result ?? const <String, dynamic>{});
        }
      case McpNotificationMessage():
        _notifications.add(message);
    }
  }

  void _onTransportError(Object error) {
    _errors.add(error);
    _failPending(error);
  }

  void _failPending(Object error) {
    final List<Completer<Map<String, dynamic>>> pending =
        _pending.values.toList(growable: false);
    _pending.clear();
    for (final Completer<Map<String, dynamic>> completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
  }
}
