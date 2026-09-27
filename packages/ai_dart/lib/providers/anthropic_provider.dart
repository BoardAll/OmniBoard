/// Anthropic Claude Provider（《AI 助手与 MCP 设计》§5.2 模型路由）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../ai_client.dart';

/// Anthropic Messages API 接入。
class AnthropicProvider extends AiProvider {
  AnthropicProvider({
    this.apiKey = '',
    this.baseUrl = 'https://api.anthropic.com',
    this.model = 'claude-3-5-sonnet-latest',
    this.anthropicVersion = '2023-06-01',
    this.maxTokensDefault = 4096,
    this.headers = const <String, String>{},
    http.Client? httpClient,
  })  : _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null;

  final String apiKey;
  final String baseUrl;
  final String model;

  /// `anthropic-version` 请求头。
  final String anthropicVersion;

  /// 请求未指定 max_tokens 时的默认值（Anthropic 必填）。
  final int maxTokensDefault;

  final Map<String, String> headers;

  final http.Client _http;
  final bool _ownsHttp;

  @override
  String get id => 'anthropic';

  @override
  String get defaultModel => model;

  Map<String, String> _headers() => <String, String>{
        'Content-Type': 'application/json',
        'anthropic-version': anthropicVersion,
        if (apiKey.isNotEmpty) 'x-api-key': apiKey,
        ...headers,
      };

  /// 构造 Messages 请求体（公开便于测试）。
  Map<String, dynamic> buildChatBody(
    AiChatRequest request, {
    required bool stream,
  }) {
    return <String, dynamic>{
      'model': request.model.isNotEmpty ? request.model : model,
      'max_tokens': request.maxTokens ?? maxTokensDefault,
      if (request.system.isNotEmpty) 'system': request.system,
      'messages': request.messages
          .where((AiMessage message) => !message.isSystem)
          .map(wireMessage)
          .toList(growable: false),
      if (request.tools.isNotEmpty)
        'tools': request.tools
            .map((AiToolDefinition tool) => <String, dynamic>{
                  'name': tool.name,
                  'description': tool.description,
                  'input_schema': tool.parameters,
                })
            .toList(growable: false),
      if (request.toolChoice.isNotEmpty && request.tools.isNotEmpty)
        'tool_choice': <String, dynamic>{'type': request.toolChoice},
      if (request.temperature != null) 'temperature': request.temperature,
      if (stream) 'stream': true,
      ...request.extra,
    };
  }

  /// 消息 → Anthropic content blocks（tool 角色转 user/tool_result）。
  static Map<String, dynamic> wireMessage(AiMessage message) {
    if (message.isTool) {
      return <String, dynamic>{
        'role': 'user',
        'content': <Object?>[
          <String, dynamic>{
            'type': 'tool_result',
            'tool_use_id': message.toolCallId,
            'content': message.content,
          },
        ],
      };
    }
    if (message.isAssistant && message.toolCalls.isNotEmpty) {
      final List<Object?> blocks = <Object?>[];
      if (message.content.isNotEmpty) {
        blocks.add(<String, dynamic>{'type': 'text', 'text': message.content});
      }
      for (final AiToolCall call in message.toolCalls) {
        blocks.add(<String, dynamic>{
          'type': 'tool_use',
          'id': call.id,
          'name': call.name.isNotEmpty ? call.name : call.toolId,
          'input': call.arguments,
        });
      }
      return <String, dynamic>{'role': 'assistant', 'content': blocks};
    }
    return <String, dynamic>{'role': message.role, 'content': message.content};
  }

  @override
  Future<AiChatResponse> chat(AiChatRequest request) async {
    final http.Response response = await _http.post(
      Uri.parse('$baseUrl/v1/messages'),
      headers: _headers(),
      body: jsonEncode(buildChatBody(request, stream: false)),
    );
    final Map<String, dynamic> json = _decode(response);
    final StringBuffer text = StringBuffer();
    final List<AiToolCall> toolCalls = <AiToolCall>[];
    final Object? content = json['content'];
    if (content is List) {
      for (final Object? item in content) {
        if (item is! Map) {
          continue;
        }
        final Map<String, dynamic> block = Map<String, dynamic>.from(item);
        switch (block['type']) {
          case 'text':
            if (block['text'] is String) {
              text.write(block['text'] as String);
            }
          case 'tool_use':
            final String name =
                block['name'] is String ? block['name'] as String : '';
            toolCalls.add(AiToolCall(
              id: block['id'] is String ? block['id'] as String : '',
              name: name,
              toolId: name,
              arguments: block['input'] is Map
                  ? Map<String, dynamic>.from(block['input'] as Map)
                  : const <String, dynamic>{},
            ));
        }
      }
    }
    return AiChatResponse(
      message: AiMessage(
        role: AiRoles.assistant,
        content: text.toString(),
        toolCalls: toolCalls,
      ),
      finishReason: mapStopReason(json['stop_reason']),
      usage: json['usage'] is Map
          ? AiUsage.fromJson(Map<String, dynamic>.from(json['usage'] as Map))
          : const AiUsage(),
      raw: json,
    );
  }

  @override
  Stream<AiStreamEvent> chatStream(AiChatRequest request) async* {
    final http.Request httpRequest =
        http.Request('POST', Uri.parse('$baseUrl/v1/messages'));
    httpRequest.headers.addAll(_headers());
    httpRequest.body = jsonEncode(buildChatBody(request, stream: true));
    final http.StreamedResponse response = await _http.send(httpRequest);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final String body = await response.stream.bytesToString();
      throw AiProviderException(
        provider: id,
        statusCode: response.statusCode,
        message: _errorMessage(body, response.statusCode),
        body: body,
      );
    }

    final Map<int, String> toolNames = <int, String>{};
    int promptTokens = 0;
    int completionTokens = 0;
    String stopReason = '';
    await for (final String line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!line.startsWith('data:')) {
        continue;
      }
      final String payload = line.substring(5).trim();
      if (payload.isEmpty) {
        continue;
      }
      final Object? decoded = jsonDecode(payload);
      if (decoded is! Map) {
        continue;
      }
      final Map<String, dynamic> json = Map<String, dynamic>.from(decoded);
      final int index =
          json['index'] is num ? (json['index'] as num).toInt() : 0;
      switch (json['type']) {
        case 'message_start':
          final Object? message = json['message'];
          if (message is Map && message['usage'] is Map) {
            promptTokens = _readInt(message['usage'] as Map, 'input_tokens');
          }
        case 'content_block_start':
          final Object? block = json['content_block'];
          if (block is Map && block['type'] == 'tool_use') {
            final String name =
                block['name'] is String ? block['name'] as String : '';
            toolNames[index] = name;
            yield AiToolCallDelta(
              index: index,
              id: block['id'] is String ? block['id'] as String : '',
              name: name,
            );
          }
        case 'content_block_delta':
          final Object? delta = json['delta'];
          if (delta is Map) {
            if (delta['type'] == 'text_delta' && delta['text'] is String) {
              yield AiTextDelta(delta['text'] as String);
            } else if (delta['type'] == 'input_json_delta' &&
                delta['partial_json'] is String) {
              yield AiToolCallDelta(
                index: index,
                name: toolNames[index] ?? '',
                argumentsDelta: delta['partial_json'] as String,
              );
            }
          }
        case 'message_delta':
          final Object? delta = json['delta'];
          if (delta is Map && delta['stop_reason'] is String) {
            stopReason = delta['stop_reason'] as String;
          }
          final Object? usage = json['usage'];
          if (usage is Map) {
            completionTokens = _readInt(usage, 'output_tokens');
          }
        case 'message_stop':
          break;
      }
    }
    yield AiStreamDone(
      finishReason: mapStopReason(stopReason),
      usage: AiUsage(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: promptTokens + completionTokens,
      ),
    );
  }

  /// Anthropic stop_reason → 统一结束原因。
  static String mapStopReason(Object? stopReason) {
    switch (stopReason) {
      case 'end_turn':
      case 'stop_sequence':
        return AiFinishReasons.stop;
      case 'tool_use':
        return AiFinishReasons.toolCalls;
      case 'max_tokens':
        return AiFinishReasons.length;
      default:
        return stopReason is String ? stopReason : '';
    }
  }

  /// 释放内部 HTTP 客户端（外部注入的客户端不关闭）。
  void close() {
    if (_ownsHttp) {
      _http.close();
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiProviderException(
        provider: id,
        statusCode: response.statusCode,
        message: _errorMessage(response.body, response.statusCode),
        body: response.body,
      );
    }
    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw FormatException('unexpected $id response body');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static int _readInt(Map<dynamic, dynamic> map, String key) =>
      map[key] is num ? (map[key] as num).toInt() : 0;

  static String _errorMessage(String body, int statusCode) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map) {
        final Object? error = decoded['error'];
        if (error is Map && error['message'] is String) {
          return error['message'] as String;
        }
        if (decoded['message'] is String) {
          return decoded['message'] as String;
        }
      }
    } on FormatException {
      // 非 JSON 错误体，回退状态码描述。
    }
    return 'HTTP $statusCode';
  }
}
