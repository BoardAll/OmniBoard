/// OpenAI（及兼容端点）Provider（《AI 助手与 MCP 设计》§5.2 模型路由）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../ai_client.dart';

/// OpenAI Chat Completions / Whisper / TTS 接入。
class OpenAiProvider extends AiProvider {
  OpenAiProvider({
    this.apiKey = '',
    this.baseUrl = 'https://api.openai.com/v1',
    this.model = 'gpt-4o-mini',
    this.organization = '',
    this.headers = const <String, String>{},
    this.transcriptionModel = 'whisper-1',
    this.speechModel = 'tts-1',
    this.speechVoice = 'alloy',
    http.Client? httpClient,
  })  : _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null;

  final String apiKey;

  /// API 基地址（自托管兼容端点可改，如 `http://localhost:8080/v1`）。
  final String baseUrl;
  final String model;
  final String organization;

  /// 附加请求头（代理 / 网关扩展）。
  final Map<String, String> headers;

  final String transcriptionModel;
  final String speechModel;
  final String speechVoice;

  final http.Client _http;
  final bool _ownsHttp;

  @override
  String get id => 'openai';

  @override
  String get defaultModel => model;

  Map<String, String> _authHeaders() => <String, String>{
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        if (organization.isNotEmpty) 'OpenAI-Organization': organization,
        ...headers,
      };

  Map<String, String> _jsonHeaders() => <String, String>{
        'Content-Type': 'application/json',
        ..._authHeaders(),
      };

  /// 构造 Chat Completions 请求体（公开便于测试与网关复用）。
  Map<String, dynamic> buildChatBody(
    AiChatRequest request, {
    required bool stream,
  }) {
    final List<Map<String, dynamic>> messages = <Map<String, dynamic>>[
      if (request.system.isNotEmpty)
        <String, dynamic>{'role': AiRoles.system, 'content': request.system},
      ...request.messages.map(wireMessage),
    ];
    return <String, dynamic>{
      'model': request.model.isNotEmpty ? request.model : model,
      'messages': messages,
      if (request.tools.isNotEmpty)
        'tools': request.tools
            .map((AiToolDefinition tool) => <String, dynamic>{
                  'type': 'function',
                  'function': <String, dynamic>{
                    'name': tool.name,
                    'description': tool.description,
                    'parameters': tool.parameters,
                  },
                })
            .toList(growable: false),
      if (request.toolChoice.isNotEmpty && request.tools.isNotEmpty)
        'tool_choice': request.toolChoice,
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.maxTokens != null) 'max_tokens': request.maxTokens,
      if (stream) 'stream': true,
      ...request.extra,
    };
  }

  /// 消息 → OpenAI wire 格式。
  static Map<String, dynamic> wireMessage(AiMessage message) {
    return <String, dynamic>{
      'role': message.role,
      'content': message.content,
      if (message.toolCalls.isNotEmpty)
        'tool_calls': message.toolCalls
            .map((AiToolCall call) => <String, dynamic>{
                  'id': call.id,
                  'type': 'function',
                  'function': <String, dynamic>{
                    'name': call.name.isNotEmpty ? call.name : call.toolId,
                    'arguments': call.argsJson,
                  },
                })
            .toList(growable: false),
      if (message.isTool && message.toolCallId.isNotEmpty)
        'tool_call_id': message.toolCallId,
    };
  }

  @override
  Future<AiChatResponse> chat(AiChatRequest request) async {
    final http.Response response = await _http.post(
      Uri.parse('$baseUrl/chat/completions'),
      headers: _jsonHeaders(),
      body: jsonEncode(buildChatBody(request, stream: false)),
    );
    final Map<String, dynamic> json = _decode(response);
    final Map<String, dynamic> choice = _firstChoice(json);
    final Object? message = choice['message'];
    return AiChatResponse(
      message: message is Map
          ? parseAssistantMessage(Map<String, dynamic>.from(message))
          : const AiMessage(role: AiRoles.assistant),
      finishReason: choice['finish_reason'] is String
          ? choice['finish_reason'] as String
          : '',
      usage: json['usage'] is Map
          ? AiUsage.fromJson(Map<String, dynamic>.from(json['usage'] as Map))
          : const AiUsage(),
      raw: json,
    );
  }

  @override
  Stream<AiStreamEvent> chatStream(AiChatRequest request) async* {
    final http.Request httpRequest =
        http.Request('POST', Uri.parse('$baseUrl/chat/completions'));
    httpRequest.headers.addAll(_jsonHeaders());
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

    String finishReason = '';
    AiUsage usage = const AiUsage();
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
      if (payload == '[DONE]') {
        break;
      }
      final Object? decoded = jsonDecode(payload);
      if (decoded is! Map) {
        continue;
      }
      final Map<String, dynamic> json = Map<String, dynamic>.from(decoded);
      if (json['usage'] is Map) {
        usage = AiUsage.fromJson(Map<String, dynamic>.from(json['usage'] as Map));
      }
      final Object? choices = json['choices'];
      if (choices is! List || choices.isEmpty) {
        continue;
      }
      final Object? first = choices.first;
      if (first is! Map) {
        continue;
      }
      final Map<String, dynamic> choice = Map<String, dynamic>.from(first);
      if (choice['finish_reason'] is String) {
        finishReason = choice['finish_reason'] as String;
      }
      final Object? delta = choice['delta'];
      if (delta is! Map) {
        continue;
      }
      final Map<String, dynamic> deltaMap = Map<String, dynamic>.from(delta);
      final Object? content = deltaMap['content'];
      if (content is String && content.isNotEmpty) {
        yield AiTextDelta(content);
      }
      final Object? toolCalls = deltaMap['tool_calls'];
      if (toolCalls is List) {
        for (final Object? item in toolCalls) {
          if (item is! Map) {
            continue;
          }
          final Map<String, dynamic> call = Map<String, dynamic>.from(item);
          final int index =
              call['index'] is num ? (call['index'] as num).toInt() : 0;
          final Object? function = call['function'];
          yield AiToolCallDelta(
            index: index,
            id: call['id'] is String ? call['id'] as String : '',
            name: function is Map && function['name'] is String
                ? function['name'] as String
                : '',
            argumentsDelta: function is Map && function['arguments'] is String
                ? function['arguments'] as String
                : '',
          );
        }
      }
    }
    yield AiStreamDone(finishReason: finishReason, usage: usage);
  }

  /// OpenAI 助手消息（含 tool_calls）解析。
  static AiMessage parseAssistantMessage(Map<String, dynamic> json) {
    final Object? toolCalls = json['tool_calls'];
    return AiMessage(
      role: AiRoles.assistant,
      content: json['content'] is String ? json['content'] as String : '',
      toolCalls: toolCalls is List
          ? toolCalls
              .whereType<Map<dynamic, dynamic>>()
              .map((Map<dynamic, dynamic> call) {
                final Map<String, dynamic> map = Map<String, dynamic>.from(call);
                final Object? function = map['function'];
                final String name =
                    function is Map && function['name'] is String
                        ? function['name'] as String
                        : '';
                Map<String, dynamic> arguments = const <String, dynamic>{};
                if (function is Map && function['arguments'] is String) {
                  try {
                    final Object? decoded =
                        jsonDecode(function['arguments'] as String);
                    if (decoded is Map) {
                      arguments = Map<String, dynamic>.from(decoded);
                    }
                  } on FormatException {
                    // 参数非合法 JSON 时忽略。
                  }
                }
                return AiToolCall(
                  id: map['id'] is String ? map['id'] as String : '',
                  name: name,
                  toolId: name,
                  arguments: arguments,
                );
              })
              .toList(growable: false)
          : const <AiToolCall>[],
      raw: json,
    );
  }

  @override
  Future<AiTranscript> transcribe(
    List<int> audio, {
    String model = '',
    String language = '',
    String mimeType = 'audio/wav',
  }) async {
    final http.MultipartRequest request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/audio/transcriptions'),
    );
    request.headers.addAll(_authHeaders());
    request.fields['model'] =
        model.isNotEmpty ? model : transcriptionModel;
    if (language.isNotEmpty) {
      request.fields['language'] = language;
    }
    request.files.add(
      http.MultipartFile.fromBytes('file', audio, filename: 'audio.wav'),
    );
    // 用注入的客户端发送（MultipartRequest.send() 会自建 Client 绕过注入）。
    final http.StreamedResponse streamed = await _http.send(request);
    final String body = await streamed.stream.bytesToString();
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw AiProviderException(
        provider: id,
        statusCode: streamed.statusCode,
        message: _errorMessage(body, streamed.statusCode),
        body: body,
      );
    }
    final Object? decoded = jsonDecode(body);
    final String text = decoded is Map && decoded['text'] is String
        ? decoded['text'] as String
        : '';
    return AiTranscript(text: text, isFinal: true, language: language);
  }

  @override
  Future<List<int>> synthesize(
    String text, {
    String voice = '',
    String model = '',
    String format = 'mp3',
  }) async {
    final http.Response response = await _http.post(
      Uri.parse('$baseUrl/audio/speech'),
      headers: _jsonHeaders(),
      body: jsonEncode(<String, dynamic>{
        'model': model.isNotEmpty ? model : speechModel,
        'voice': voice.isNotEmpty ? voice : speechVoice,
        'input': text,
        'response_format': format,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiProviderException(
        provider: id,
        statusCode: response.statusCode,
        message: _errorMessage(response.body, response.statusCode),
        body: response.body,
      );
    }
    return response.bodyBytes;
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

  static Map<String, dynamic> _firstChoice(Map<String, dynamic> json) {
    final Object? choices = json['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      return Map<String, dynamic>.from(choices.first as Map);
    }
    return <String, dynamic>{};
  }

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
