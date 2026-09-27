// whiteboard_api_client 单元测试（MockClient 注入，无真实网络）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:whiteboard_api_client/api_client.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

Map<String, dynamic> _success(Object? data, {Map<String, dynamic>? meta}) =>
    <String, dynamic>{
      'ok': true,
      'data': data,
      'meta': <String, dynamic>{'requestId': 'req_test', ...?meta},
    };

void main() {
  group('WbApiClient URI 构建', () {
    test('去除 baseUrl 尾部斜杠并补全 path 前缀', () {
      final WbApiClient client = WbApiClient(
        baseUrl: 'https://api.example.com/v1/',
        httpClient: MockClient((_) async => _json(_success(null))),
      );
      expect(
        client.buildUri('/boards').toString(),
        'https://api.example.com/v1/boards',
      );
      expect(
        client.buildUri('boards').toString(),
        'https://api.example.com/v1/boards',
      );
    });

    test('合并 query 参数', () {
      final WbApiClient client = WbApiClient(
        httpClient: MockClient((_) async => _json(_success(null))),
      );
      final Uri uri =
          client.buildUri('/boards', query: <String, String>{'limit': '20'});
      expect(uri.path, '/v1/boards');
      expect(uri.queryParameters['limit'], '20');
      expect(client.buildUri('/x').host, 'api.whiteboard.example.com');
    });
  });

  group('WbApiClient 信封与错误', () {
    late http.Request captured;

    WbApiClient clientWith(MockClient mock) => WbApiClient(
          baseUrl: 'https://api.example.com/v1',
          httpClient: mock,
        );

    test('解析成功信封并返回 data（UTF-8 中文）', () async {
      final WbApiClient client = clientWith(MockClient((http.Request req) async {
        captured = req;
        return _json(_success(<String, dynamic>{
          'id': 'board_1',
          'name': '需求梳理',
        }));
      }));
      final Map<String, dynamic> data =
          await client.requestObject('GET', '/boards/board_1');
      expect(data['name'], '需求梳理');
      expect(captured.url.path, '/v1/boards/board_1');
    });

    test('ok=false 抛出 WbApiException（含 code/message/detail/requestId）', () async {
      final WbApiClient client = clientWith(MockClient((_) async => _json(
            <String, dynamic>{
              'ok': false,
              'error': <String, dynamic>{
                'code': 'NOT_FOUND',
                'message': 'board not found',
                'detail': 'board_9 does not exist',
              },
              'meta': <String, dynamic>{'requestId': 'req_err'},
            },
          )));
      await expectLater(
        client.requestObject('GET', '/boards/board_9'),
        throwsA(
          isA<WbApiException>()
              .having((WbApiException e) => e.code, 'code', 'NOT_FOUND')
              .having((WbApiException e) => e.message, 'message', 'board not found')
              .having((WbApiException e) => e.detail, 'detail',
                  'board_9 does not exist')
              .having((WbApiException e) => e.requestId, 'requestId', 'req_err')
              .having((WbApiException e) => e.isNotFound, 'isNotFound', true),
        ),
      );
    });

    test('HTTP 4xx/5xx 无信封时按状态码兜底', () async {
      final WbApiClient client404 = clientWith(
          MockClient((_) async => http.Response('not found', 404)));
      await expectLater(
        client404.requestObject('GET', '/boards/x'),
        throwsA(isA<WbApiException>()
            .having((WbApiException e) => e.code, 'code', 'NOT_FOUND')
            .having((WbApiException e) => e.statusCode, 'statusCode', 404)),
      );

      final WbApiClient client500 = clientWith(
          MockClient((_) async => http.Response('boom', 500)));
      await expectLater(
        client500.requestObject('GET', '/boards/x'),
        throwsA(isA<WbApiException>()
            .having((WbApiException e) => e.code, 'code', 'INTERNAL_ERROR')),
      );
    });

    test('网络异常包装为 WbNetworkException', () async {
      final WbApiClient client = clientWith(
          MockClient((_) async => throw const SocketExceptionStub()));
      await expectLater(
        client.requestObject('GET', '/boards'),
        throwsA(isA<WbNetworkException>()),
      );
    });

    test('requestList 宽容提取 Map 列表', () async {
      final WbApiClient client = clientWith(MockClient((_) async => _json(
            _success(<Object>[
              <String, dynamic>{'id': 'a'},
              42,
              <String, dynamic>{'id': 'b'},
            ]),
          )));
      final List<Map<String, dynamic>> list =
          await client.requestList('GET', '/boards');
      expect(list.length, 2);
      expect(list.first['id'], 'a');
      expect(list.last['id'], 'b');
    });
  });

  group('请求头与认证', () {
    test('Bearer 认证 + 版本头 + 幂等键 + JSON 体', () async {
      late http.Request captured;
      final WbApiClient client = WbApiClient(
        baseUrl: 'https://api.example.com/v1',
        auth: const WbAuth.bearer('tok_123'),
        httpClient: MockClient((http.Request req) async {
          captured = req;
          return _json(_success(<String, dynamic>{}));
        }),
      );
      await client.send(
        'POST',
        '/boards',
        body: <String, dynamic>{'name': '新板'},
        idempotencyKey: 'idem_1',
      );
      expect(captured.headers['Authorization'], 'Bearer tok_123');
      expect(captured.headers['X-API-Version'], '1');
      expect(captured.headers['Idempotency-Key'], 'idem_1');
      expect(captured.headers['Content-Type'], contains('application/json'));
      final Map<String, dynamic> body =
          jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['name'], '新板');
    });

    test('API Key 认证头', () {
      expect(
        const WbAuth.apiKey('key_abc').toHeaders(),
        <String, String>{'X-API-Key': 'key_abc'},
      );
      expect(const WbAuth.bearer('t').toHeaders()['Authorization'], 'Bearer t');
    });

    test('过期判断', () {
      final WbAuth expired = WbAuth.bearer(
        't',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      expect(expired.isExpired, isTrue);
      expect(const WbAuth.apiKey('k').isExpired, isFalse);
    });
  });

  group('分页', () {
    test('requestPaged 解析 items 与 meta', () async {
      late http.Request captured;
      final WbApiClient client = WbApiClient(
        baseUrl: 'https://api.example.com/v1',
        httpClient: MockClient((http.Request req) async {
          captured = req;
          return _json(_success(
            <Object>[
              <String, dynamic>{'id': 'board_1', 'name': 'A'},
              <String, dynamic>{'id': 'board_2', 'name': 'B'},
            ],
            meta: <String, dynamic>{
              'nextCursor': 'cursor_2',
              'hasMore': true,
              'total': 5,
            },
          ));
        }),
      );
      final WbPageResult<WbApiBoard> page =
          await WbBoardsApi(client).list(query: const WbListQuery(limit: 2));
      expect(page.items.length, 2);
      expect(page.items.first.name, 'A');
      expect(page.nextCursor, 'cursor_2');
      expect(page.hasMore, isTrue);
      expect(page.total, 5);
      expect(captured.url.queryParameters['limit'], '2');
    });

    test('WbListQuery.toQuery 省略空值并含 sort/filter/cursor', () {
      const WbListQuery query = WbListQuery(
        limit: 50,
        cursor: 'c1',
        sort: 'createdAt:desc',
        filter: 'type:sticky',
      );
      final Map<String, String> params = query.toQuery();
      expect(params['limit'], '50');
      expect(params['cursor'], 'c1');
      expect(params['sort'], 'createdAt:desc');
      expect(params['filter'], 'type:sticky');
      expect(const WbListQuery().toQuery().containsKey('cursor'), isFalse);
    });
  });

  group('模型解析', () {
    test('WbApiBoard.fromJson 与 toJson 优先 raw', () {
      final WbApiBoard board = WbApiBoard.fromJson(<String, dynamic>{
        'id': 'board_1',
        'name': '产品需求',
        'themeId': 'dark-night',
        'createdAt': '2026-09-25T10:00:00Z',
      });
      expect(board.id, 'board_1');
      expect(board.name, '产品需求');
      expect(board.themeId, 'dark-night');
      expect(board.toJson()['themeId'], 'dark-night');
      expect(const WbApiBoard(id: 'b').toJson()['name'], '');
    });

    test('WbApiElement.fromJson 提取 position/size', () {
      final WbApiElement el = WbApiElement.fromJson(<String, dynamic>{
        'id': 'el_1',
        'type': 'sticky',
        'position': <String, dynamic>{'x': 100, 'y': 200},
        'size': <String, dynamic>{'width': 200, 'height': 150},
        'style': <String, dynamic>{'color': '#FFE58F'},
      });
      expect(el.x, 100);
      expect(el.y, 200);
      expect(el.width, 200);
      expect(el.height, 150);
      final Object? style = el['style'];
      expect((style! as Map<dynamic, dynamic>)['color'], '#FFE58F');
    });

    test('WbApiPage 与 WbApiViewport', () {
      final WbApiPage page = WbApiPage.fromJson(<String, dynamic>{
        'id': 'page_1',
        'boardId': 'board_1',
        'name': '用户旅程',
        'index': 2,
      });
      expect(page.name, '用户旅程');
      expect(page.index, 2);
      final WbApiViewport viewport =
          WbApiViewport.fromJson(<String, dynamic>{'x': 1, 'y': 2});
      expect(viewport.zoom, 1);
      expect(viewport.toJson()['x'], 1);
    });

    test('WbApiExportJob 状态判断', () {
      final WbApiExportJob job = WbApiExportJob.fromJson(<String, dynamic>{
        'id': 'exp_1',
        'format': 'pdf',
        'status': 'done',
        'progress': 100,
        'fileUrl': 'https://cdn.example.com/exp_1.pdf',
      });
      expect(job.isDone, isTrue);
      expect(job.isFailed, isFalse);
      expect(job.fileUrl, contains('exp_1.pdf'));
    });

    test('WbApiComment 解析回复列表', () {
      final WbApiComment comment = WbApiComment.fromJson(<String, dynamic>{
        'id': 'cm_1',
        'content': '这里需要补充',
        'resolved': false,
        'replies': <Object>[
          <String, dynamic>{
            'id': 'cm_2',
            'authorId': 'user_2',
            'content': '收到',
          },
        ],
      });
      expect(comment.replies.length, 1);
      expect(comment.replies.first.content, '收到');
    });

    test('WbApiConnectorDraft.toJson 省略空字段', () {
      const WbApiConnectorDraft draft = WbApiConnectorDraft(
        fromElementId: 'e1',
        toElementId: 'e2',
        style: 'orthogonal',
        label: '是',
      );
      final Map<String, dynamic> json = draft.toJson();
      expect(json['style'], 'orthogonal');
      expect(json['label'], '是');
      expect(json.containsKey('fromAnchor'), isFalse);
    });

    test('WbApiMcpTool 解析 inputSchema', () {
      final WbApiMcpTool tool = WbApiMcpTool.fromJson(<String, dynamic>{
        'name': 'create_sticky_note',
        'description': '创建便签',
        'inputSchema': <String, dynamic>{'type': 'object'},
      });
      expect(tool.name, 'create_sticky_note');
      expect(tool.inputSchema['type'], 'object');
    });

    test('WbApiSession / WbApiMessage / WbApiToolCall', () {
      final WbApiSession session = WbApiSession.fromJson(<String, dynamic>{
        'sessionId': 'sess_1',
        'boardId': 'board_1',
        'messageCount': 3,
      });
      expect(session.messageCount, 3);
      final WbApiMessage msg = WbApiMessage.fromJson(<String, dynamic>{
        'id': 'msg_1',
        'role': 'assistant',
        'content': '好的',
        'toolCalls': <Object>[
          <String, dynamic>{
            'id': 'call_1',
            'name': 'create_sticky_note',
            'arguments': <String, dynamic>{'text': '用户痛点'},
            'status': 'pending',
          },
        ],
      });
      expect(msg.isAssistant, isTrue);
      expect(msg.toolCalls.single.isPending, isTrue);
    });
  });

  group('API 服务', () {
    test('WbBoardsApi.create 组装请求', () async {
      late http.Request captured;
      final WbApiClient client = WbApiClient(
        baseUrl: 'https://api.example.com/v1',
        httpClient: MockClient((http.Request req) async {
          captured = req;
          return _json(_success(<String, dynamic>{
            'id': 'board_1',
            'name': '新板',
            'themeId': 'dark-night',
          }));
        }),
      );
      final WbApiBoard board = await WbBoardsApi(client).create(
        name: '新板',
        themeId: 'dark-night',
        idempotencyKey: 'k_1',
      );
      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/boards');
      expect(captured.headers['Idempotency-Key'], 'k_1');
      final Map<String, dynamic> body =
          jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['name'], '新板');
      expect(body['themeId'], 'dark-night');
      expect(body.containsKey('description'), isFalse);
      expect(board.id, 'board_1');
    });

    test('WbElementsApi.list 路径与分页', () async {
      late http.Request captured;
      final WbApiClient client = WbApiClient(
        baseUrl: 'https://api.example.com/v1',
        httpClient: MockClient((http.Request req) async {
          captured = req;
          return _json(_success(<Object>[
            <String, dynamic>{
              'id': 'el_1',
              'type': 'sticky',
              'position': <String, dynamic>{'x': 1, 'y': 2},
            },
          ]));
        }),
      );
      final WbPageResult<WbApiElement> page =
          await WbElementsApi(client).list('page_1');
      expect(captured.url.path, '/v1/pages/page_1/elements');
      expect(page.items.single.type, 'sticky');
    });

    test('WbPagesApi.thumbnailUrl 构造直链', () {
      final WbApiClient client = WbApiClient(
        httpClient: MockClient((_) async => _json(_success(null))),
      );
      final Uri uri = WbPagesApi(client).thumbnailUrl('page_1', width: 320);
      expect(uri.path, '/v1/pages/page_1/thumbnail');
      expect(uri.queryParameters['width'], '320');
    });

    test('WbAiApi.sendMessage 解包 {message:{...}}', () async {
      late http.Request captured;
      final WbApiClient client = WbApiClient(
        baseUrl: 'https://api.example.com/v1',
        httpClient: MockClient((http.Request req) async {
          captured = req;
          return _json(_success(<String, dynamic>{
            'message': <String, dynamic>{
              'id': 'msg_1',
              'role': 'assistant',
              'content': '已创建流程图',
            },
          }));
        }),
      );
      final WbApiMessage msg =
          await WbAiApi(client).sendMessage('sess_1', '画一个流程');
      expect(captured.url.path, '/v1/ai/sessions/sess_1/messages');
      expect(
        (jsonDecode(captured.body) as Map<String, dynamic>)['message'],
        '画一个流程',
      );
      expect(msg.role, 'assistant');
      expect(msg.content, '已创建流程图');
    });

    test('WbHistoryApi.undo 解析结果', () async {
      final WbApiClient client = WbApiClient(
        baseUrl: 'https://api.example.com/v1',
        httpClient: MockClient((_) async => _json(_success(<String, dynamic>{
              'applied': true,
              'affected': <String>['el_1'],
              'canUndo': true,
              'canRedo': false,
            }))),
      );
      final WbApiUndoResult result = await WbHistoryApi(client).undo('board_1');
      expect(result.applied, isTrue);
      expect(result.affected.single, 'el_1');
      expect(result.history.canUndo, isTrue);
    });

    test('WbExportsApi.exportBoard 请求体与下载直链', () async {
      late http.Request captured;
      final WbApiClient client = WbApiClient(
        baseUrl: 'https://api.example.com/v1',
        httpClient: MockClient((http.Request req) async {
          captured = req;
          return _json(_success(<String, dynamic>{
            'id': 'exp_1',
            'format': 'pdf',
            'status': 'pending',
          }));
        }),
      );
      final WbApiExportJob job = await WbExportsApi(client).exportBoard(
        'board_1',
        const WbApiExportRequest(
          format: 'pdf',
          pages: <String>['page_1'],
          quality: 'high',
        ),
      );
      final Map<String, dynamic> body =
          jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['format'], 'pdf');
      expect(body['quality'], 'high');
      expect((body['pages'] as List<Object?>).single, 'page_1');
      expect(job.status, 'pending');
      expect(
        WbExportsApi(client).downloadUri('exp_1').path,
        '/v1/exports/exp_1/download',
      );
    });

    test('WbConnectorsApi.create 使用 Draft 序列化', () async {
      late http.Request captured;
      final WbApiClient client = WbApiClient(
        baseUrl: 'https://api.example.com/v1',
        httpClient: MockClient((http.Request req) async {
          captured = req;
          return _json(_success(<String, dynamic>{
            'id': 'conn_1',
            'fromElementId': 'e1',
            'toElementId': 'e2',
          }));
        }),
      );
      final WbApiConnector connector = await WbConnectorsApi(client).create(
        'page_1',
        draft: const WbApiConnectorDraft(
          fromElementId: 'e1',
          toElementId: 'e2',
          fromAnchor: 'right',
          toAnchor: 'left',
          label: '是',
        ),
      );
      expect(captured.url.path, '/v1/pages/page_1/connectors');
      final Map<String, dynamic> body =
          jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['label'], '是');
      expect(body['fromAnchor'], 'right');
      expect(body['toAnchor'], 'left');
      expect(connector.fromElementId, 'e1');
      expect(connector.toElementId, 'e2');
    });

    test('WbMcpApi.tools 解析列表', () async {
      final WbApiClient client = WbApiClient(
        baseUrl: 'https://api.example.com/v1',
        httpClient: MockClient((_) async => _json(_success(<Object>[
              <String, dynamic>{
                'name': 'create_sticky_note',
                'description': '创建便签',
              },
            ]))),
      );
      final List<WbApiMcpTool> tools = await WbMcpApi(client).tools();
      expect(tools.single.name, 'create_sticky_note');
    });
  });
}

/// 用于模拟网络层异常的小工具类。
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();

  @override
  String toString() => 'SocketException: connection refused';
}
