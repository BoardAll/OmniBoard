/// MCP API（Open API §5.10）。
library;

import 'api_client.dart';

/// MCP 工具定义（`GET /mcp/tools`）。
class WbApiMcpTool {
  const WbApiMcpTool({
    required this.name,
    this.description = '',
    this.inputSchema = const <String, dynamic>{},
    this.raw = const <String, dynamic>{},
  });

  final String name;
  final String description;

  /// JSON Schema 入参定义。
  final Map<String, dynamic> inputSchema;

  final Map<String, dynamic> raw;

  factory WbApiMcpTool.fromJson(Map<String, dynamic> json) {
    return WbApiMcpTool(
      name: json['name'] is String ? json['name'] as String : '',
      description:
          json['description'] is String ? json['description'] as String : '',
      inputSchema: json['inputSchema'] is Map
          ? Map<String, dynamic>.from(json['inputSchema'] as Map)
          : json['input_schema'] is Map
              ? Map<String, dynamic>.from(json['input_schema'] as Map)
              : const <String, dynamic>{},
      raw: json,
    );
  }
}

class WbMcpApi {
  const WbMcpApi(this._client);

  final WbApiClient _client;

  /// `GET /mcp/tools` — 列出 MCP 工具。
  Future<List<WbApiMcpTool>> tools() async {
    final List<Map<String, dynamic>> data =
        await _client.requestList('GET', '/mcp/tools');
    return data.map(WbApiMcpTool.fromJson).toList(growable: false);
  }

  /// `POST /mcp/tools/{toolName}/call` — 调用 MCP 工具。
  Future<Map<String, dynamic>> callTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) {
    return _client.requestObject(
      'POST',
      '/mcp/tools/$toolName/call',
      body: <String, dynamic>{'arguments': arguments},
    );
  }

  /// `GET /mcp/server` — MCP Server 信息（协议版本 / 能力）。
  Future<Map<String, dynamic>> serverInfo() {
    return _client.requestObject('GET', '/mcp/server');
  }
}
