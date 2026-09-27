// ai_dart 包测试：模型编解码 / Provider 请求构造与解析 / 客户端全流程。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whiteboard_ai/ai_client.dart';

/// 可编程 Fake Provider。
class FakeProvider extends AiProvider {
  FakeProvider({
    this.response = const AiChatResponse(
      message: AiMessage(role: AiRoles.assistant, content: '好的'),
    ),
    this.streamEvents = const <AiStreamEvent>[],
  });

  AiChatResponse response;
  List<AiStreamEvent> streamEvents;
  final List<AiChatRequest> requests = <AiChatRequest>[];

  @override
  String get id => 'fake';

  @override
  String get defaultModel => 'fake-1';

  @override
  Future<AiChatResponse> chat(AiChatRequest request) async {
    requests.add(request);
    return response;
  }

  @override
  Stream<AiStreamEvent> chatStream(AiChatRequest request) async* {
    requests.add(request);
    for (final AiStreamEvent event in streamEvents) {
      yield event;
    }
  }
}

/// SSE 报文组装（OpenAI 风格 `data:` 行）。
String sseBody(List<Map<String, dynamic>> events) {
  final StringBuffer buffer = StringBuffer();
  for (final Map<String, dynamic> event in events) {
    buffer.writeln('data: ${jsonEncode(event)}');
    buffer.writeln();
  }
  return buffer.toString();
}

/// 让 http.Response 以 UTF-8 解码 body（默认 Latin1 无法承载中文）。
const Map<String, String> utf8JsonHeaders = <String, String>{
  'content-type': 'application/json; charset=utf-8',
};

void main() {
  group('模型层', () {
    test('AiMessage.fromJson 解析工具调用与时间戳', () {
      final AiMessage message = AiMessage.fromJson(<String, dynamic>{
        'id': 'm1',
        'role': 'assistant',
        'content': '开始执行',
        'toolCalls': <Object?>[
          <String, dynamic>{
            'id': 'call_1',
            'name': 'element_create',
            'arguments': <String, dynamic>{'count': 5},
            'status': 'pending',
          },
        ],
        'timestamp': 1700000000000,
      });
      expect(message.isAssistant, isTrue);
      expect(message.content, '开始执行');
      expect(message.toolCalls.single.name, 'element_create');
      expect(message.toolCalls.single.arguments['count'], 5);
      expect(message.timestamp?.millisecondsSinceEpoch, 1700000000000);

      final Map<String, dynamic> json = message.toJson();
      expect(json['role'], 'assistant');
      expect((json['toolCalls'] as List<dynamic>).length, 1);
      final AiMessage reparsed = AiMessage.fromJson(json);
      expect(reparsed.toolCalls.single.id, 'call_1');
    });

    test('AiMessage 工厂与角色判断', () {
      expect(AiMessage.user('hi').isUser, isTrue);
      expect(AiMessage.system('s').isSystem, isTrue);
      final AiMessage result = AiMessage.toolResult('call_1', '{"ok":true}');
      expect(result.isTool, isTrue);
      expect(result.toolCallId, 'call_1');
      expect(result.toJson()['toolCallId'], 'call_1');
      expect(AiMessage.user('').isEmpty, isTrue);
      final AiMessage assistant = AiMessage.assistant(
        '',
        toolCalls: const <AiToolCall>[
          AiToolCall(id: 'c', name: 'n'),
        ],
      );
      expect(assistant.isEmpty, isFalse);
    });

    test('AiToolCall 兼容 argsJson/resultJson 与确认态', () {
      final AiToolCall call = AiToolCall.fromJson(<String, dynamic>{
        'id': 'c1',
        'toolId': 'element.create',
        'argsJson': '{"x":1}',
        'status': 'pending',
        'confirmLevel': 'confirm',
      });
      expect(call.arguments['x'], 1);
      expect(call.isPending, isTrue);
      expect(call.requiresConfirmation, isTrue);
      expect(call.argsJson, '{"x":1}');

      final AiToolCall done = call.copyWith(
        status: AiToolCallStatus.success,
        result: <String, dynamic>{'elementIds': <String>['e1']},
      );
      expect(done.isSuccess, isTrue);
      expect(done.requiresConfirmation, isFalse);
      expect(done.resultJson, contains('e1'));

      final AiToolCall failed = call.copyWith(
        status: AiToolCallStatus.error,
        error: 'boom',
      );
      expect(failed.isError, isTrue);
      expect(failed.toJson()['error'], 'boom');
    });

    test('AiContext 摘要 / merge / 往返', () {
      const AiContext context = AiContext(
        boardId: 'b1',
        pageId: 'p1',
        selection: <String>['e1', 'e2'],
        scope: AiContextScope.selection,
      );
      expect(context.summary, '选中 2 个对象');
      expect(const AiContext().summary, '当前页面');
      expect(
        const AiContext(scope: AiContextScope.board).summary,
        '整个白板',
      );

      final AiContext merged = context.merge(const AiContext(
        boardId: 'b2',
        allowComments: true,
        extra: <String, dynamic>{'viewport': 'v1'},
      ));
      expect(merged.boardId, 'b2');
      expect(merged.pageId, 'p1');
      expect(merged.allowComments, isTrue);
      expect(merged.selection.length, 2);
      expect(merged.extra['viewport'], 'v1');

      final AiContext parsed = AiContext.fromJson(context.toJson());
      expect(parsed.selection, <String>['e1', 'e2']);
      expect(parsed.scope, AiContextScope.selection);
    });

    test('AiSession 追加消息与往返', () {
      AiSession session = const AiSession(id: 's1', boardId: 'b1');
      session = session.appendMessage(AiMessage.user('hi'));
      session = session.appendMessage(AiMessage.assistant('hello'));
      expect(session.messageCount, 2);
      expect(session.lastAssistantMessage?.content, 'hello');
      expect(session.isClosed, isFalse);

      final AiSession parsed = AiSession.fromJson(session.toJson());
      expect(parsed.id, 's1');
      expect(parsed.boardId, 'b1');
      expect(parsed.messages.length, 2);
      expect(parsed.messages.first.isUser, isTrue);
    });

    test('AiTranscript / AiAudioChunk / 语音状态 / 未连接发送抛错', () {
      final AiTranscript transcript = AiTranscript.fromJson(<String, dynamic>{
        'text': '你好',
        'isFinal': true,
        'confidence': 0.9,
      });
      expect(transcript.text, '你好');
      expect(transcript.isFinal, isTrue);
      expect(transcript.confidence, 0.9);
      expect(AiVoiceStates.label(AiVoiceStates.listening), '聆听中');
      expect(AiVoiceStates.label(AiVoiceStates.waitingConfirm), '等待确认');

      const AiAudioChunk chunk =
          AiAudioChunk(bytes: <int>[1, 2, 3], sequence: 2, isFinal: true);
      expect(chunk.length, 3);
      expect(chunk.isFinal, isTrue);

      final AiAudioSocket socket =
          AiAudioSocket(Uri.parse('ws://localhost/realtime'));
      expect(socket.isConnected, isFalse);
      expect(
        () => socket.sendJson(<String, dynamic>{'type': 'ping'}),
        throwsStateError,
      );
      expect(
        () => socket.sendAudio(chunk),
        throwsStateError,
      );
    });
  });

  group('AiClient 门面', () {
    test('send 写入用户与助手消息并携带系统提示', () async {
      final FakeProvider provider = FakeProvider();
      final AiClient client =
          AiClient(provider: provider, systemPrompt: '你是白板助手');
      final AiMessage reply = await client.send('创建 5 个便签');
      expect(reply.content, '好的');
      expect(client.messages.length, 2);
      expect(client.messages.first.isUser, isTrue);
      expect(client.messages.last.isAssistant, isTrue);

      final AiChatRequest request = provider.requests.single;
      expect(request.system, '你是白板助手');
      expect(request.messages.length, 1);
      expect(request.messages.single.content, '创建 5 个便签');
    });

    test('stream 透传事件并把累积助手消息写入会话', () async {
      final FakeProvider provider = FakeProvider(streamEvents: <AiStreamEvent>[
        const AiTextDelta('开始'),
        const AiTextDelta('执行'),
        const AiToolCallDelta(
          index: 0,
          id: 'call_9',
          name: 'element_create',
          argumentsDelta: '{"count":',
        ),
        const AiToolCallDelta(index: 0, argumentsDelta: '5}'),
        const AiStreamDone(finishReason: AiFinishReasons.toolCalls),
      ]);
      final AiClient client = AiClient(provider: provider);
      final List<AiStreamEvent> events =
          await client.stream('创建便签').toList();
      expect(events.length, 5);
      expect(events.first, isA<AiTextDelta>());

      final AiMessage assistant = client.messages.last;
      expect(assistant.isAssistant, isTrue);
      expect(assistant.content, '开始执行');
      expect(assistant.toolCalls.single.id, 'call_9');
      expect(assistant.toolCalls.single.name, 'element_create');
      expect(assistant.toolCalls.single.arguments['count'], 5);
    });

    test('updateContext / append / reset 与会话状态', () {
      final AiClient client = AiClient(provider: FakeProvider());
      client.updateContext(const AiContext(
        boardId: 'b1',
        pageId: 'p1',
        selection: <String>['e1'],
        scope: AiContextScope.selection,
      ));
      expect(client.session.boardId, 'b1');
      expect(client.session.pageId, 'p1');
      expect(client.session.selection, <String>['e1']);
      expect(client.session.context.scope, AiContextScope.selection);

      client.append(AiMessage.user('hi'));
      expect(client.messages.length, 1);
      client.reset();
      expect(client.messages, isEmpty);
      expect(client.session.boardId, 'b1'); // 上下文保留。
    });
  });

  group('OpenAiProvider', () {
    test('buildChatBody 组装系统提示 / 工具 / 采样参数', () {
      final OpenAiProvider provider = OpenAiProvider(apiKey: 'sk-test');
      final Map<String, dynamic> body = provider.buildChatBody(
        AiChatRequest(
          messages: <AiMessage>[AiMessage.user('你好')],
          system: '系统',
          model: 'gpt-4o',
          tools: const <AiToolDefinition>[
            AiToolDefinition(
              name: 'element_create',
              description: '创建元素',
              parameters: <String, dynamic>{'type': 'object'},
            ),
          ],
          temperature: 0.5,
          maxTokens: 100,
          extra: <String, dynamic>{'top_p': 0.9},
        ),
        stream: true,
      );
      expect(body['model'], 'gpt-4o');
      expect(body['stream'], true);
      expect(body['temperature'], 0.5);
      expect(body['max_tokens'], 100);
      expect(body['top_p'], 0.9);
      final List<dynamic> messages = body['messages'] as List<dynamic>;
      expect(messages.length, 2);
      expect((messages.first as Map<dynamic, dynamic>)['role'], 'system');
      final List<dynamic> tools = body['tools'] as List<dynamic>;
      final Map<dynamic, dynamic> function =
          (tools.single as Map<dynamic, dynamic>)['function'] as Map<dynamic, dynamic>;
      expect(function['name'], 'element_create');
      expect(function['parameters'], <String, dynamic>{'type': 'object'});
    });

    test('chat 发送认证头并解析 tool_calls / usage', () async {
      late http.Request captured;
      final MockClient mock = MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Object?>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': '好的',
                  'tool_calls': <Object?>[
                    <String, dynamic>{
                      'id': 'call_1',
                      'type': 'function',
                      'function': <String, dynamic>{
                        'name': 'element_create',
                        'arguments': '{"count":5}',
                      },
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
            'usage': <String, dynamic>{
              'prompt_tokens': 10,
              'completion_tokens': 5,
              'total_tokens': 15,
            },
          }),
          200,
          headers: utf8JsonHeaders,
        );
      });
      final OpenAiProvider provider = OpenAiProvider(
        apiKey: 'sk-test',
        httpClient: mock,
      );
      final AiChatResponse response = await provider
          .chat(AiChatRequest(messages: <AiMessage>[AiMessage.user('hi')]));
      expect(captured.url.path, '/v1/chat/completions');
      expect(captured.headers['Authorization'], 'Bearer sk-test');
      expect(response.message.content, '好的');
      expect(response.message.toolCalls.single.name, 'element_create');
      expect(response.message.toolCalls.single.arguments['count'], 5);
      expect(response.finishReason, AiFinishReasons.toolCalls);
      expect(response.usage.totalTokens, 15);
    });

    test('chat 非 2xx 抛 AiProviderException（含错误消息）', () async {
      final MockClient mock = MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{'message': 'invalid api key'},
          }),
          401,
        );
      });
      final OpenAiProvider provider =
          OpenAiProvider(apiKey: 'bad', httpClient: mock);
      await expectLater(
        provider.chat(AiChatRequest(messages: <AiMessage>[AiMessage.user('hi')])),
        throwsA(isA<AiProviderException>()
            .having((AiProviderException e) => e.statusCode, 'statusCode', 401)
            .having((AiProviderException e) => e.message, 'message',
                'invalid api key')),
      );
    });

    test('chatStream 解析 SSE 文本增量 / 工具调用 / [DONE]', () async {
      late http.Request captured;
      final MockClient mock = MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          '${sseBody(<Map<String, dynamic>>[
            <String, dynamic>{
              'choices': <Object?>[
                <String, dynamic>{
                  'delta': <String, dynamic>{'content': '你'},
                },
              ],
            },
            <String, dynamic>{
              'choices': <Object?>[
                <String, dynamic>{
                  'delta': <String, dynamic>{'content': '好'},
                },
              ],
            },
            <String, dynamic>{
              'choices': <Object?>[
                <String, dynamic>{
                  'delta': <String, dynamic>{
                    'tool_calls': <Object?>[
                      <String, dynamic>{
                        'index': 0,
                        'id': 'call_x',
                        'function': <String, dynamic>{
                          'name': 'element_create',
                          'arguments': '{"count":5}',
                        },
                      },
                    ],
                  },
                },
              ],
            },
            <String, dynamic>{
              'choices': <Object?>[
                <String, dynamic>{
                  'delta': <String, dynamic>{},
                  'finish_reason': 'tool_calls',
                },
              ],
              'usage': <String, dynamic>{
                'prompt_tokens': 3,
                'completion_tokens': 2,
                'total_tokens': 5,
              },
            },
          ])}data: [DONE]\n\n',
          200,
          headers: utf8JsonHeaders,
        );
      });
      final OpenAiProvider provider = OpenAiProvider(httpClient: mock);
      final List<AiStreamEvent> events = await provider
          .chatStream(AiChatRequest(messages: <AiMessage>[AiMessage.user('hi')]))
          .toList();
      expect(
        events
            .whereType<AiTextDelta>()
            .map((AiTextDelta e) => e.text)
            .toList(),
        <String>['你', '好'],
      );
      final AiToolCallDelta callDelta =
          events.whereType<AiToolCallDelta>().single;
      expect(callDelta.id, 'call_x');
      expect(callDelta.name, 'element_create');
      expect(callDelta.argumentsDelta, '{"count":5}');
      final AiStreamDone done = events.whereType<AiStreamDone>().single;
      expect(done.finishReason, AiFinishReasons.toolCalls);
      expect(done.usage.totalTokens, 5);
      expect(
        (jsonDecode(captured.body) as Map<String, dynamic>)['stream'],
        true,
      );
    });

    test('chatStream 非 2xx 抛 AiProviderException', () async {
      final MockClient mock = MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{'message': 'boom'},
          }),
          500,
        );
      });
      final OpenAiProvider provider = OpenAiProvider(httpClient: mock);
      await expectLater(
        provider
            .chatStream(
                AiChatRequest(messages: <AiMessage>[AiMessage.user('hi')]))
            .toList(),
        throwsA(isA<AiProviderException>()
            .having((AiProviderException e) => e.statusCode, 'statusCode', 500)),
      );
    });

    test('transcribe 上传 multipart 并解析文本', () async {
      late http.Request captured;
      final MockClient mock = MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{'text': '你好世界'}),
          200,
          headers: utf8JsonHeaders,
        );
      });
      final OpenAiProvider provider =
          OpenAiProvider(apiKey: 'sk', httpClient: mock);
      final AiTranscript transcript =
          await provider.transcribe(<int>[1, 2, 3]);
      expect(captured.url.path, '/v1/audio/transcriptions');
      expect(captured.body, contains('whisper-1'));
      expect(captured.headers['Authorization'], 'Bearer sk');
      expect(transcript.text, '你好世界');
      expect(transcript.isFinal, isTrue);
    });

    test('synthesize 返回音频字节并传 voice/model', () async {
      late http.Request captured;
      final MockClient mock = MockClient((http.Request request) async {
        captured = request;
        return http.Response.bytes(<int>[0xFF, 0xFB, 0x90], 200);
      });
      final OpenAiProvider provider = OpenAiProvider(httpClient: mock);
      final List<int> audio = await provider.synthesize('你好');
      expect(captured.url.path, '/v1/audio/speech');
      final Map<String, dynamic> body =
          jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['voice'], 'alloy');
      expect(body['model'], 'tts-1');
      expect(body['input'], '你好');
      expect(audio, <int>[0xFF, 0xFB, 0x90]);
    });
  });

  group('AnthropicProvider', () {
    test('buildChatBody 组装 system / max_tokens / content blocks', () {
      final AnthropicProvider provider = AnthropicProvider();
      final Map<String, dynamic> body = provider.buildChatBody(
        AiChatRequest(
          messages: <AiMessage>[
            AiMessage.user('hi'),
            AiMessage.assistant(
              '',
              toolCalls: const <AiToolCall>[
                AiToolCall(id: 'call_1', name: 'element_create'),
              ],
            ),
            AiMessage.toolResult('call_1', '{"ok":true}'),
          ],
          system: '系统提示',
          tools: const <AiToolDefinition>[
            AiToolDefinition(name: 'element_create'),
          ],
        ),
        stream: false,
      );
      expect(body['max_tokens'], 4096);
      expect(body['system'], '系统提示');
      final List<dynamic> messages = body['messages'] as List<dynamic>;
      expect(messages.length, 3);
      final Map<dynamic, dynamic> assistant =
          messages[1] as Map<dynamic, dynamic>;
      final List<dynamic> blocks = assistant['content'] as List<dynamic>;
      expect((blocks.single as Map<dynamic, dynamic>)['type'], 'tool_use');
      final Map<dynamic, dynamic> toolMessage =
          messages[2] as Map<dynamic, dynamic>;
      expect(toolMessage['role'], 'user');
      expect(
        ((toolMessage['content'] as List<dynamic>).single
            as Map<dynamic, dynamic>)['type'],
        'tool_result',
      );
      final Map<dynamic, dynamic> tool =
          (body['tools'] as List<dynamic>).single as Map<dynamic, dynamic>;
      expect(tool['input_schema'], isNotNull);
    });

    test('chat 解析 content blocks 与 stop_reason / usage', () async {
      late http.Request captured;
      final MockClient mock = MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'content': <Object?>[
              <String, dynamic>{'type': 'text', 'text': '好的，计划如下'},
              <String, dynamic>{
                'type': 'tool_use',
                'id': 'toolu_1',
                'name': 'element_create',
                'input': <String, dynamic>{'count': 5},
              },
            ],
            'stop_reason': 'tool_use',
            'usage': <String, dynamic>{
              'input_tokens': 12,
              'output_tokens': 8,
            },
          }),
          200,
          headers: utf8JsonHeaders,
        );
      });
      final AnthropicProvider provider =
          AnthropicProvider(apiKey: 'ak', httpClient: mock);
      final AiChatResponse response = await provider
          .chat(AiChatRequest(messages: <AiMessage>[AiMessage.user('hi')]));
      expect(captured.url.path, '/v1/messages');
      expect(captured.headers['x-api-key'], 'ak');
      expect(captured.headers['anthropic-version'], '2023-06-01');
      expect(response.message.content, '好的，计划如下');
      expect(response.message.toolCalls.single.id, 'toolu_1');
      expect(response.message.toolCalls.single.arguments['count'], 5);
      expect(response.finishReason, AiFinishReasons.toolCalls);
      expect(response.usage.promptTokens, 12);
      expect(response.usage.completionTokens, 8);
      expect(response.usage.totalTokens, 20);
    });

    test('chatStream 解析 text_delta / input_json_delta / 用量', () async {
      final StringBuffer sse = StringBuffer();
      void emit(Map<String, dynamic> json) {
        sse.writeln('event: ${json['type']}');
        sse.writeln('data: ${jsonEncode(json)}');
        sse.writeln();
      }

      emit(<String, dynamic>{
        'type': 'message_start',
        'message': <String, dynamic>{
          'usage': <String, dynamic>{'input_tokens': 10},
        },
      });
      emit(<String, dynamic>{
        'type': 'content_block_delta',
        'index': 0,
        'delta': <String, dynamic>{'type': 'text_delta', 'text': '你好'},
      });
      emit(<String, dynamic>{
        'type': 'content_block_start',
        'index': 1,
        'content_block': <String, dynamic>{
          'type': 'tool_use',
          'id': 'toolu_2',
          'name': 'element_create',
        },
      });
      emit(<String, dynamic>{
        'type': 'content_block_delta',
        'index': 1,
        'delta': <String, dynamic>{
          'type': 'input_json_delta',
          'partial_json': '{"count":5}',
        },
      });
      emit(<String, dynamic>{
        'type': 'message_delta',
        'delta': <String, dynamic>{'stop_reason': 'tool_use'},
        'usage': <String, dynamic>{'output_tokens': 7},
      });
      emit(<String, dynamic>{'type': 'message_stop'});

      final MockClient mock = MockClient((http.Request request) async {
        return http.Response(sse.toString(), 200, headers: utf8JsonHeaders);
      });
      final AnthropicProvider provider = AnthropicProvider(httpClient: mock);
      final List<AiStreamEvent> events = await provider
          .chatStream(AiChatRequest(messages: <AiMessage>[AiMessage.user('hi')]))
          .toList();
      expect(events.whereType<AiTextDelta>().single.text, '你好');
      final List<AiToolCallDelta> callDeltas =
          events.whereType<AiToolCallDelta>().toList();
      expect(callDeltas.first.id, 'toolu_2');
      expect(callDeltas.first.name, 'element_create');
      expect(callDeltas.last.argumentsDelta, '{"count":5}');
      final AiStreamDone done = events.whereType<AiStreamDone>().single;
      expect(done.finishReason, AiFinishReasons.toolCalls);
      expect(done.usage.promptTokens, 10);
      expect(done.usage.completionTokens, 7);
      expect(done.usage.totalTokens, 17);
    });

    test('stop_reason 映射与不支持 ASR', () async {
      expect(AnthropicProvider.mapStopReason('end_turn'),
          AiFinishReasons.stop);
      expect(AnthropicProvider.mapStopReason('max_tokens'),
          AiFinishReasons.length);
      expect(AnthropicProvider.mapStopReason('tool_use'),
          AiFinishReasons.toolCalls);
      final AnthropicProvider provider = AnthropicProvider();
      await expectLater(
        provider.transcribe(<int>[1]),
        throwsUnsupportedError,
      );
    });
  });

  group('CustomProvider', () {
    test('自定义 id / 基地址 / 附加头 / 默认模型', () async {
      late http.Request captured;
      final MockClient mock = MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Object?>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': '网关应答',
                },
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: utf8JsonHeaders,
        );
      });
      final CustomProvider provider = CustomProvider(
        baseUrl: 'http://localhost:8080/v1',
        id: 'wb-gateway',
        model: 'internal-large',
        headers: <String, String>{'X-WB-Token': 'token-1'},
        httpClient: mock,
      );
      expect(provider.id, 'wb-gateway');
      expect(provider.defaultModel, 'internal-large');
      final AiChatResponse response = await provider
          .chat(AiChatRequest(messages: <AiMessage>[AiMessage.user('hi')]));
      expect(
        captured.url.toString(),
        'http://localhost:8080/v1/chat/completions',
      );
      expect(captured.headers['X-WB-Token'], 'token-1');
      expect(
        (jsonDecode(captured.body) as Map<String, dynamic>)['model'],
        'internal-large',
      );
      expect(response.message.content, '网关应答');
    });
  });
}
