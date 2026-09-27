// mcp_client 包测试：协议编解码 / SSE 解码 / 客户端全流程（FakeTransport）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_mcp_client/mcp_client.dart';

/// 可编程 Fake 传输：记录出站消息，按 [onRequest] 回调生成响应。
class FakeTransport extends McpTransportBase {
  /// 收到请求时生成响应 JSON（返回 null 表示不应答）。
  String? Function(Map<String, dynamic> request)? onRequest;

  /// 出站原始消息。
  final List<String> sent = <String>[];

  /// 出站消息解析结果（含通知）。
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];

  @override
  Future<void> start() async {
    setRunning(true);
  }

  @override
  void send(String message) {
    if (!isRunning) {
      throw StateError('fake transport is not running');
    }
    sent.add(message);
    final Map<String, dynamic> request =
        jsonDecode(message) as Map<String, dynamic>;
    requests.add(request);
    if (!request.containsKey('id')) {
      return; // 通知无需响应。
    }
    final String? response = onRequest?.call(request);
    if (response != null) {
      scheduleMicrotask(() => emitMessage(response));
    }
  }

  /// 最近一次指定方法的出站请求。
  Map<String, dynamic> requestOf(String method) => requests.lastWhere(
      (Map<String, dynamic> r) => r['method'] == method,
      orElse: () => <String, dynamic>{});

  /// 是否发送过指定方法。
  bool hasMethod(String method) => requests
      .any((Map<String, dynamic> r) => r['method'] == method);
}

/// 构造成功响应 JSON。
String ok(Map<String, dynamic> request, {Object? result}) =>
    jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': request['id'],
      'result': result ?? const <String, dynamic>{},
    });

/// 构造错误响应 JSON。
String err(
  Map<String, dynamic> request, {
  required int code,
  required String message,
  Object? data,
}) =>
    jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': request['id'],
      'error': <String, dynamic>{
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      },
    });

/// `initialize` 的标准应答结果。
Map<String, dynamic> initServerResult() => <String, dynamic>{
      'protocolVersion': '2025-06-18',
      'capabilities': <String, dynamic>{
        'tools': <String, dynamic>{},
        'resources': <String, dynamic>{},
        'prompts': <String, dynamic>{},
      },
      'serverInfo': <String, dynamic>{
        'name': 'whiteboard-mcp',
        'version': '1.0.0',
      },
      'instructions': 'Use whiteboard tools.',
    };

typedef RequestHandler = String Function(Map<String, dynamic> request);

/// 构造标准 responder：`initialize` 固定应答；其余方法按 [overrides] 查找，
/// 值为 [RequestHandler] 时动态生成，否则作为 result（null 即空结果）。
RequestHandler makeResponder({Map<String, Object?>? overrides}) {
  final Map<String, Object?> map = overrides ?? <String, Object?>{};
  return (Map<String, dynamic> request) {
    final String method = request['method'] as String? ?? '';
    if (method == 'initialize') {
      return ok(request, result: initServerResult());
    }
    final Object? override = map[method];
    if (override is RequestHandler) {
      return override(request);
    }
    return ok(request, result: override);
  };
}

Map<String, dynamic> paramsOf(Map<String, dynamic> request) =>
    request['params'] is Map
        ? Map<String, dynamic>.from(request['params'] as Map)
        : <String, dynamic>{};

Future<McpClient> connectedClient(
  FakeTransport transport, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final McpClient client =
      McpClient(transport: transport, requestTimeout: timeout);
  await client.connect();
  return client;
}

void main() {
  group('McpJsonRpc', () {
    test('buildRequest 编码 jsonrpc/id/method/params', () {
      final String raw =
          McpJsonRpc.buildRequest(7, 'tools/list', <String, dynamic>{'cursor': 'c1'});
      final Map<String, dynamic> map = jsonDecode(raw) as Map<String, dynamic>;
      expect(map['jsonrpc'], '2.0');
      expect(map['id'], 7);
      expect(map['method'], 'tools/list');
      expect(map['params'], <String, dynamic>{'cursor': 'c1'});
    });

    test('buildRequest 无 params 时省略字段', () {
      final Map<String, dynamic> map =
          jsonDecode(McpJsonRpc.buildRequest(1, 'ping')) as Map<String, dynamic>;
      expect(map.containsKey('params'), isFalse);
    });

    test('buildNotification 不含 id', () {
      final Map<String, dynamic> map = jsonDecode(
          McpJsonRpc.buildNotification(McpMethods.initialized)) as Map<String, dynamic>;
      expect(map['method'], 'notifications/initialized');
      expect(map.containsKey('id'), isFalse);
    });

    test('parseMessage 解析带 result 的响应', () {
      final McpMessage message = McpJsonRpc.parseMessage(
          '{"jsonrpc":"2.0","id":3,"result":{"ok":true}}');
      expect(message, isA<McpResponseMessage>());
      final McpResponseMessage response = message as McpResponseMessage;
      expect(response.id, 3);
      expect(response.result, <String, dynamic>{'ok': true});
      expect(response.error, isNull);
    });

    test('parseMessage 解析带 error 的响应', () {
      final McpMessage message = McpJsonRpc.parseMessage(
          '{"jsonrpc":"2.0","id":4,"error":{"code":-32002,"message":"denied",'
          '"data":{"scope":"board.write"}}}');
      final McpResponseMessage response = message as McpResponseMessage;
      expect(response.error?.code, -32002);
      expect(response.error?.dataString('scope'), 'board.write');
    });

    test('parseMessage 解析通知', () {
      final McpMessage message = McpJsonRpc.parseMessage(
          '{"jsonrpc":"2.0","method":"notifications/resources/updated",'
          '"params":{"uri":"whiteboard://boards/b1"}}');
      expect(message, isA<McpNotificationMessage>());
      final McpNotificationMessage notification =
          message as McpNotificationMessage;
      expect(notification.method, McpMethods.resourcesUpdated);
      expect(notification.params?['uri'], 'whiteboard://boards/b1');
    });

    test('parseMessage 对非法消息抛 FormatException', () {
      expect(() => McpJsonRpc.parseMessage('[]'), throwsFormatException);
      expect(() => McpJsonRpc.parseMessage('{"jsonrpc":"2.0"}'),
          throwsFormatException);
      expect(() => McpJsonRpc.parseMessage('no json'), throwsFormatException);
    });
  });

  group('错误码与异常', () {
    test('McpErrorCodes.name 映射全部标准码', () {
      expect(McpErrorCodes.name(McpErrorCodes.parseError), 'ParseError');
      expect(McpErrorCodes.name(McpErrorCodes.invalidRequest), 'InvalidRequest');
      expect(
          McpErrorCodes.name(McpErrorCodes.methodNotFound), 'MethodNotFound');
      expect(McpErrorCodes.name(McpErrorCodes.invalidParams), 'InvalidParams');
      expect(McpErrorCodes.name(McpErrorCodes.internalError), 'InternalError');
      expect(McpErrorCodes.name(McpErrorCodes.serverError), 'ServerError');
      expect(McpErrorCodes.name(McpErrorCodes.rateLimited), 'RateLimited');
      expect(
          McpErrorCodes.name(McpErrorCodes.permissionDenied), 'PermissionDenied');
      expect(McpErrorCodes.name(McpErrorCodes.notFound), 'NotFound');
      expect(McpErrorCodes.name(McpErrorCodes.conflict), 'Conflict');
      expect(McpErrorCodes.name(McpErrorCodes.confirmationRequired),
          'ConfirmationRequired');
      expect(McpErrorCodes.name(McpErrorCodes.cancelled), 'Cancelled');
      expect(McpErrorCodes.name(-99999), 'Error(-99999)');
    });

    test('McpError 往返编解码与 dataString', () {
      final McpError error = McpError.fromJson(<String, dynamic>{
        'code': -32001,
        'message': 'slow down',
        'data': <String, dynamic>{'retryAfter': 5, 'scope': 'ai.generate'},
      });
      expect(error.code, -32001);
      expect(error.message, 'slow down');
      expect(error.dataString('scope'), 'ai.generate');
      expect(error.dataString('retryAfter'), ''); // 非字符串返回空串。
      expect(error.toJson()['code'], -32001);
      expect(McpError.fromJson(<String, dynamic>{}).code, 0);
    });

    test('McpException 语义化标志', () {
      const McpException rate =
          McpException(McpError(code: McpErrorCodes.rateLimited, message: 'r'));
      const McpException denied = McpException(
          McpError(code: McpErrorCodes.permissionDenied, message: 'd'));
      const McpException notFound =
          McpException(McpError(code: McpErrorCodes.notFound, message: 'n'));
      const McpException confirm = McpException(
          McpError(code: McpErrorCodes.confirmationRequired, message: 'c'));
      expect(rate.isRateLimited, isTrue);
      expect(denied.isPermissionDenied, isTrue);
      expect(notFound.isNotFound, isTrue);
      expect(confirm.isConfirmationRequired, isTrue);
      expect(rate.isPermissionDenied, isFalse);
      expect(rate.toString(), contains('RateLimited'));
    });
  });

  group('McpSseDecoder', () {
    test('解析 endpoint 事件', () {
      final List<(String, String)> events = <(String, String)>[];
      final McpSseDecoder decoder = McpSseDecoder(
          onEvent: (String event, String data) => events.add((event, data)));
      decoder.addLine('event: endpoint');
      decoder.addLine('data: /mcp?session=abc');
      decoder.addLine('');
      expect(events, <(String, String)>[('endpoint', '/mcp?session=abc')]);
    });

    test('message 事件多行 data 以换行合并', () {
      final List<(String, String)> events = <(String, String)>[];
      final McpSseDecoder decoder = McpSseDecoder(
          onEvent: (String event, String data) => events.add((event, data)));
      decoder.addLine('event: message');
      decoder.addLine('data: line1');
      decoder.addLine('data: line2');
      decoder.addLine('');
      expect(events.length, 1);
      expect(events.first.$1, 'message');
      expect(events.first.$2, 'line1\nline2');
    });

    test('注释行忽略、空 data 不派发、事件名跨事件重置', () {
      final List<(String, String)> events = <(String, String)>[];
      final McpSseDecoder decoder = McpSseDecoder(
          onEvent: (String event, String data) => events.add((event, data)));
      decoder.addLine(': keep-alive');
      decoder.addLine('');
      decoder.addLine('event: endpoint');
      decoder.addLine('');
      decoder.addLine('data: payload');
      decoder.addLine('');
      expect(events, <(String, String)>[('', 'payload')]);
    });
  });

  group('McpClient 初始化', () {
    test('connect 完成握手并发送 initialized 通知', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder();
      final McpClient client = await connectedClient(transport);

      final Map<String, dynamic> init = transport.requests.first;
      expect(init['method'], 'initialize');
      final Map<String, dynamic> params = paramsOf(init);
      expect(params['protocolVersion'], mcpDefaultProtocolVersion);
      expect((params['clientInfo'] as Map)['name'], 'whiteboard-client');

      final Map<String, dynamic> initialized =
          transport.requestOf(McpMethods.initialized);
      expect(initialized.containsKey('id'), isFalse);

      expect(client.isInitialized, isTrue);
      expect(client.protocolVersion, '2025-06-18');
      expect(client.serverInfo?.name, 'whiteboard-mcp');
      expect(client.initializeResult?.supports('tools'), isTrue);
      expect(client.initializeResult?.supports('sampling'), isFalse);
      expect(client.initializeResult?.instructions, 'Use whiteboard tools.');

      await client.dispose();
    });

    test('initialize 失败时抛出 McpException 且状态未初始化', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = (Map<String, dynamic> request) => err(
              request,
              code: McpErrorCodes.invalidRequest,
              message: 'bad initialize',
            );
      final McpClient client = McpClient(transport: transport);
      await expectLater(client.connect(), throwsA(isA<McpException>()));
      expect(client.isInitialized, isFalse);
      await client.shutdown();
    });
  });

  group('McpClient Tools', () {
    test('listTools 单页返回工具列表', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder(overrides: <String, Object?>{
          McpMethods.toolsList: <String, dynamic>{
            'tools': <Object?>[
              <String, dynamic>{
                'name': 'element_create',
                'description': '创建元素',
                'inputSchema': <String, dynamic>{'type': 'object'},
              },
              <String, dynamic>{'name': 'page_delete'},
            ],
          },
        });
      final McpClient client = await connectedClient(transport);
      final List<McpTool> tools = await client.listTools();
      expect(tools.length, 2);
      expect(tools.first.name, 'element_create');
      expect(tools.first.description, '创建元素');
      expect(tools.first.inputSchema['type'], 'object');
      expect(paramsOf(transport.requestOf(McpMethods.toolsList))['cursor'],
          isNull);
      await client.dispose();
    });

    test('listTools 按 nextCursor 自动翻页', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder(overrides: <String, Object?>{
          McpMethods.toolsList: (Map<String, dynamic> request) {
            final Object? cursor = paramsOf(request)['cursor'];
            if (cursor == null || cursor == '') {
              return ok(request, result: <String, dynamic>{
                'tools': <Object?>[
                  <String, dynamic>{'name': 'a'},
                ],
                'nextCursor': 'c2',
              });
            }
            return ok(request, result: <String, dynamic>{
              'tools': <Object?>[
                <String, dynamic>{'name': 'b'},
              ],
            });
          },
        });
      final McpClient client = await connectedClient(transport);
      final List<McpTool> tools = await client.listTools();
      expect(tools.map((McpTool t) => t.name), <String>['a', 'b']);
      final List<Map<String, dynamic>> calls = transport.requests
          .where((Map<String, dynamic> r) => r['method'] == McpMethods.toolsList)
          .toList(growable: false);
      expect(calls.length, 2);
      expect(paramsOf(calls.last)['cursor'], 'c2');
      await client.dispose();
    });

    test('callTool 传参与结果解析（确认/预览/受影响元素）', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder(overrides: <String, Object?>{
          McpMethods.toolsCall: <String, dynamic>{
            'content': <Object?>[
              <String, dynamic>{'type': 'text', 'text': '预览已生成'},
              <String, dynamic>{
                'type': 'image',
                'data': 'aGk=',
                'mimeType': 'image/png',
              },
            ],
            'isError': false,
            'structuredContent': <String, dynamic>{
              'requiresConfirmation': true,
              'confirmationId': 'cfm_123',
              'preview': <String, dynamic>{'affectedCount': 3},
              'affectedElements': <Object?>['el_1', 'el_2'],
            },
          },
        });
      final McpClient client = await connectedClient(transport);
      final McpToolResult result = await client
          .callTool('element_move', <String, dynamic>{'dx': 10});
      final Map<String, dynamic> callParams =
          paramsOf(transport.requestOf(McpMethods.toolsCall));
      expect(callParams['name'], 'element_move');
      expect(callParams['arguments'], <String, dynamic>{'dx': 10});
      expect(result.requiresConfirmation, isTrue);
      expect(result.confirmationId, 'cfm_123');
      expect(result.preview['affectedCount'], 3);
      expect(result.affectedElements, <String>['el_1', 'el_2']);
      expect(result.text, '预览已生成');
      expect(result.isError, isFalse);
      expect(result.content.length, 2);
      await client.dispose();
    });

    test('confirmOperation 以 confirm_operation 工具提交确认', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder(overrides: <String, Object?>{
          McpMethods.toolsCall: <String, dynamic>{
            'content': <Object?>[
              <String, dynamic>{'type': 'text', 'text': '已执行'},
            ],
          },
        });
      final McpClient client = await connectedClient(transport);
      final McpToolResult result =
          await client.confirmOperation('cfm_123', approved: true);
      final Map<String, dynamic> callParams =
          paramsOf(transport.requestOf(McpMethods.toolsCall));
      expect(callParams['name'], McpMethods.confirmOperation);
      final Map<String, dynamic> arguments =
          Map<String, dynamic>.from(callParams['arguments'] as Map);
      expect(arguments['confirmationId'], 'cfm_123');
      expect(arguments['approved'], isTrue);
      expect(result.text, '已执行');
      await client.dispose();
    });
  });

  group('McpClient Resources', () {
    test('listResources 返回资源并支持翻页', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder(overrides: <String, Object?>{
          McpMethods.resourcesList: (Map<String, dynamic> request) {
            if (paramsOf(request)['cursor'] == null) {
              return ok(request, result: <String, dynamic>{
                'resources': <Object?>[
                  <String, dynamic>{
                    'uri': 'whiteboard://boards/b1',
                    'name': 'board',
                  },
                ],
                'nextCursor': 'n1',
              });
            }
            return ok(request, result: <String, dynamic>{
              'resources': <Object?>[
                <String, dynamic>{
                  'uri': 'whiteboard://boards/b1/pages',
                  'name': 'pages',
                  'mimeType': 'application/json',
                },
              ],
            });
          },
        });
      final McpClient client = await connectedClient(transport);
      final List<McpResource> resources = await client.listResources();
      expect(resources.length, 2);
      expect(resources.first.uri, 'whiteboard://boards/b1');
      expect(resources.last.mimeType, 'application/json');
      await client.dispose();
    });

    test('readResource 解析 contents 列表', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder(overrides: <String, Object?>{
          McpMethods.resourcesRead: <String, dynamic>{
            'contents': <Object?>[
              <String, dynamic>{
                'uri': 'whiteboard://boards/b1',
                'mimeType': 'application/json',
                'text': '{"id":"b1","title":"演示"}',
              },
            ],
          },
        });
      final McpClient client = await connectedClient(transport);
      final List<McpResourceContent> contents =
          await client.readResource('whiteboard://boards/b1');
      expect(contents.length, 1);
      expect(contents.first.text, contains('b1'));
      expect(
          paramsOf(transport.requestOf(McpMethods.resourcesRead))['uri'],
          'whiteboard://boards/b1');
      await client.dispose();
    });

    test('subscribe/unsubscribe 传 uri；URI 构建器符合方案', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder();
      final McpClient client = await connectedClient(transport);
      const String uri = 'whiteboard://boards/b1/pages/p1';
      await client.subscribe(uri);
      await client.unsubscribe(uri);
      expect(paramsOf(transport.requestOf(McpMethods.resourcesSubscribe))['uri'],
          uri);
      expect(
          paramsOf(transport.requestOf(McpMethods.resourcesUnsubscribe))['uri'],
          uri);
      expect(McpWhiteboardUris.board('b1'), 'whiteboard://boards/b1');
      expect(McpWhiteboardUris.pages('b1'), 'whiteboard://boards/b1/pages');
      expect(McpWhiteboardUris.page('b1', 'p1'),
          'whiteboard://boards/b1/pages/p1');
      expect(McpWhiteboardUris.elements('b1', 'p1'),
          'whiteboard://boards/b1/pages/p1/elements');
      expect(McpWhiteboardUris.thumbnail('b1', 'p1'),
          'whiteboard://boards/b1/pages/p1/thumbnail');
      await client.dispose();
    });
  });

  group('McpClient Prompts', () {
    test('listPrompts 解析参数定义', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder(overrides: <String, Object?>{
          McpMethods.promptsList: <String, dynamic>{
            'prompts': <Object?>[
              <String, dynamic>{
                'name': McpBuiltinPrompts.brainstorm,
                'description': '脑暴',
                'arguments': <Object?>[
                  <String, dynamic>{'name': 'topic', 'required': true},
                ],
              },
            ],
          },
        });
      final McpClient client = await connectedClient(transport);
      final List<McpPrompt> prompts = await client.listPrompts();
      expect(prompts.single.name, 'brainstorm');
      expect(prompts.single.arguments.single.required, isTrue);
      await client.dispose();
    });

    test('getPrompt 传参并拼接文本', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder(overrides: <String, Object?>{
          McpMethods.promptsGet: <String, dynamic>{
            'description': '脑暴模板',
            'messages': <Object?>[
              <String, dynamic>{
                'role': 'user',
                'content': <String, dynamic>{'type': 'text', 'text': 'hello'},
              },
              <String, dynamic>{
                'role': 'assistant',
                'content': <String, dynamic>{'type': 'text', 'text': 'world'},
              },
            ],
          },
        });
      final McpClient client = await connectedClient(transport);
      final McpPromptResult result = await client.getPrompt(
          McpBuiltinPrompts.brainstorm, arguments: <String, String>{'topic': 'AI'});
      expect(result.text, 'hello\nworld');
      final Map<String, dynamic> params =
          paramsOf(transport.requestOf(McpMethods.promptsGet));
      expect(params['name'], 'brainstorm');
      expect(Map<String, dynamic>.from(params['arguments'] as Map)['topic'],
          'AI');
      await client.dispose();
    });
  });

  group('McpClient 其他方法', () {
    test('complete / setLoggingLevel 参数编码', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder();
      final McpClient client = await connectedClient(transport);

      await client.setLoggingLevel('debug');
      expect(
          paramsOf(transport.requestOf(McpMethods.loggingSetLevel))['level'],
          'debug');

      final Map<String, dynamic> result = await client.complete(
        refType: 'ref/prompt',
        refName: 'brainstorm',
        argumentName: 'topic',
        argumentValue: 'AI',
      );
      expect(result, isEmpty);
      final Map<String, dynamic> params =
          paramsOf(transport.requestOf(McpMethods.completionComplete));
      expect(Map<String, dynamic>.from(params['ref'] as Map)['type'],
          'ref/prompt');
      expect(Map<String, dynamic>.from(params['argument'] as Map)['value'],
          'AI');
      await client.dispose();
    });
  });

  group('McpClient 错误与生命周期', () {
    test('服务端错误响应转为 McpException', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = (Map<String, dynamic> request) {
          if (request['method'] == 'initialize') {
            return ok(request, result: initServerResult());
          }
          return err(
            request,
            code: McpErrorCodes.permissionDenied,
            message: 'denied',
            data: <String, dynamic>{'scope': 'board.write'},
          );
        };
      final McpClient client = await connectedClient(transport);
      await expectLater(
        client.callTool('page_delete', <String, dynamic>{'pageId': 'p1'}),
        throwsA(isA<McpException>()
            .having((McpException e) => e.isPermissionDenied,
                'isPermissionDenied', isTrue)
            .having((McpException e) => e.error.dataString('scope'), 'scope',
                'board.write')),
      );
      await client.dispose();
    });

    test('传输错误使 pending 请求失败并广播到 errors 流', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder();
      final McpClient client = await connectedClient(transport);
      final List<Object> clientErrors = <Object>[];
      client.errors.listen(clientErrors.add);

      transport.onRequest = null; // 不再应答 ping。
      final Future<void> ping = client.ping();
      transport.emitError(StateError('connection lost'));
      await expectLater(ping, throwsA(isA<StateError>()));
      expect(
        clientErrors
            .whereType<StateError>()
            .map((StateError e) => e.message),
        contains('connection lost'),
      );
      await client.dispose();
    });

    test('请求超时抛出 McpException（internalError）', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder();
      final McpClient client = await connectedClient(transport,
          timeout: const Duration(milliseconds: 40));
      transport.onRequest = null;
      await expectLater(
        client.ping(),
        throwsA(isA<McpException>().having(
            (McpException e) => e.code, 'code', McpErrorCodes.internalError)),
      );
      transport.onRequest = makeResponder();
      await client.dispose();
    });

    test('非法入站消息广播 FormatException 且不影响后续请求', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder();
      final McpClient client = await connectedClient(transport);
      final List<Object> clientErrors = <Object>[];
      client.errors.listen(clientErrors.add);

      transport.emitMessage('{broken');
      transport.emitMessage('[]');
      transport.emitMessage('{"jsonrpc":"2.0","foo":1}');
      expect(clientErrors.whereType<FormatException>().length, 3);

      await client.ping(); // 客户端仍可用。
      await client.dispose();
    });

    test('服务端通知进入 notifications 流', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder();
      final McpClient client = await connectedClient(transport);
      final List<McpNotificationMessage> notifications =
          <McpNotificationMessage>[];
      client.notifications.listen(notifications.add);
      transport.emitMessage(
          '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}');
      expect(notifications.single.method, McpMethods.toolsListChanged);
      await client.dispose();
    });

    test('shutdown 发送 shutdown 请求并停止传输', () async {
      final FakeTransport transport = FakeTransport()
        ..onRequest = makeResponder();
      final McpClient client = await connectedClient(transport);
      expect(transport.isRunning, isTrue);
      await client.shutdown();
      expect(transport.hasMethod(McpMethods.shutdown), isTrue);
      expect(transport.isRunning, isFalse);
      expect(client.isInitialized, isFalse);
    });

    test('传输未运行时发送请求抛 StateError', () async {
      final FakeTransport transport = FakeTransport(); // 未 start。
      final McpClient client = McpClient(transport: transport);
      await expectLater(client.ping(), throwsA(isA<StateError>()));
    });
  });
}
