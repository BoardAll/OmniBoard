/// Web 协作会话测试（P4）：画布提交 ⇄ CRDT ⇄ realtime 全链路。
///
/// 注入可编程引擎调用器（[WbEngineCaller] fake：按 toolId 返回信封）与
/// [FakeSocketIoBridge]，覆盖：
/// - 本地出口：upsert → `el:{id}:data`（内嵌 pageId）/ 删除 →
///   `el:{id}:exists=false` → `crdt.applyLocal` → `board:ops` 透传、
///   水印推进、ack `missingSeqs` 从有界缓存补发一次；
/// - 远端入口：`crdt.applyRemote` applied 三态（true 路由 / false 与
///   duplicate 不路由）、水印推进、key 前缀路由（`el:*` / `pg:*`）、
///   NotFound → 惰性 `crdt.create` 重试；
/// - 快照恢复：`encodeState` 探测（NotFound → create + decodeState +
///   state 回放画布 + 水印 = stateVector；成功 = 跳过）；
/// - checkpoint：`board:checkpointRequest` → `encodeState` →
///   `board:checkpoint` 上报；
/// - 页结构出口：`handlePageOp` → `pg:{pageId}:{field}`（value 缺省 true、
///   空参数 / 释放 / 防回发守卫；与 `WbPageState.onPageOp` 装配口径一致）；
/// - 装配与释放：start 注册 / dispose 回收（identical 判定）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_canvas/canvas/canvas_controller.dart';
import 'package:whiteboard_canvas/canvas/canvas_model.dart';
import 'package:whiteboard_canvas/services/board_file_codec.dart';
import 'package:whiteboard_canvas/state/page_state.dart';
import 'package:whiteboard_core/wb_core_common.dart';
import 'package:whiteboard_web/services/realtime_service.dart';
import 'package:whiteboard_web/services/wb_collab_session.dart';

import 'support/fake_socketio_bridge.dart';

/// 测试用服务地址。
const String _endpoint = 'http://127.0.0.1:8790';

/// 测试用会话 actor（固定值便于断言缓存键 `actor:seq`）。
const String _actor = 'a1';

/// 本地提交样本元素。
const WbCanvasElement _element = WbCanvasElement(
  id: 'e1',
  type: 'note',
  x: 10,
  y: 20,
  width: 100,
  height: 60,
);

void main() {
  group('本地出口（画布提交 → op → board:ops）', () {
    test('upsert → el:{id}:data（内嵌 pageId）→ applyLocal → ops 透传 + 水印', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);
      await h.connect();

      final Map<String, Object?> op = <String, Object?>{
        'key': 'el:e1:data',
        'value': <String, Object?>{'id': 'e1', 'pageId': 'p1'},
        'actor': _actor,
        'seq': 1,
        'timestamp': 11,
      };
      h.caller.responses['crdt.applyLocal'] = jsonEncode(<String, Object?>{
        'ok': true,
        'result': <String, Object?>{'applied': true, 'op': op},
      });

      h.session.handleLocalCommit(
        const WbCanvasCommitBatch(pageId: 'p1', upserts: <WbCanvasElement>[_element]),
      );

      // 引擎侧：applyLocal 的 op 形状（key 分节 + value 内嵌 pageId）。
      final ({String toolId, Map<String, dynamic> args}) call =
          h.caller.toolCalls.single;
      expect(call.toolId, 'crdt.applyLocal');
      expect(call.args['docId'], 'board-1');
      final Map<String, dynamic> operation =
          Map<String, dynamic>.from(call.args['operation'] as Map);
      expect(operation['key'], 'el:e1:data');
      final Map<String, dynamic> value =
          Map<String, dynamic>.from(operation['value'] as Map);
      expect(value['id'], 'e1');
      expect(value['pageId'], 'p1');

      // 网络侧：规范化 op 原样透传；水印推进。
      final FakeAckCall opsCall = h.bridge.ackCalls.single;
      expect(opsCall.event, 'board:ops');
      final List<Object?> sent = (opsCall.payload! as List<Object?>);
      expect(sent, hasLength(1));
      expect((sent.single! as Map<String, Object?>)['actor'], _actor);
      expect((sent.single! as Map<String, Object?>)['seq'], 1);
      expect(h.session.watermarks, <String, Object?>{_actor: 1});
    });

    test('removedIds → el:{id}:exists = false；空批不下发', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);
      await h.connect();

      h.caller.responses['crdt.applyLocal'] = jsonEncode(<String, Object?>{
        'ok': true,
        'result': <String, Object?>{
          'applied': true,
          'op': <String, Object?>{
            'key': 'el:e2:exists',
            'value': false,
            'actor': _actor,
            'seq': 1,
            'timestamp': 12,
          },
        },
      });

      h.session.handleLocalCommit(
        const WbCanvasCommitBatch(pageId: 'p1', removedIds: <String>['e2']),
      );
      h.session.handleLocalCommit(const WbCanvasCommitBatch()); // 空批忽略

      final ({String toolId, Map<String, dynamic> args}) call =
          h.caller.toolCalls.single;
      final Map<String, dynamic> operation =
          Map<String, dynamic>.from(call.args['operation'] as Map);
      expect(operation['key'], 'el:e2:exists');
      expect(operation['value'], isFalse);
      expect(h.bridge.ackCalls, hasLength(1));
    });

    test('页结构出口：handlePageOp → pg:{pageId}:{field}（value 缺省 true；空参数 / 释放后忽略）',
        () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);
      await h.connect();

      h.caller.responses['crdt.applyLocal'] = jsonEncode(<String, Object?>{
        'ok': true,
        'result': <String, Object?>{
          'applied': true,
          'op': <String, Object?>{
            'key': 'pg:page-2:create',
            'value': <String, Object?>{'name': '页面 2'},
            'actor': _actor,
            'seq': 1,
            'timestamp': 12,
          },
        },
      });

      h.session
          .handlePageOp('page-2', 'create', <String, Object?>{'name': '页面 2'});
      h.session.handlePageOp('page-2', 'delete', null); // value 缺省 true 口径。

      // 空 pageId / field：静默忽略（不触达引擎）。
      h.session.handlePageOp('', 'create', null);
      h.session.handlePageOp('page-2', '', null);
      expect(h.caller.toolCalls, hasLength(2));

      final Map<String, dynamic> createOp = Map<String, dynamic>.from(
          h.caller.toolCalls.first.args['operation'] as Map);
      expect(createOp['key'], 'pg:page-2:create');
      expect(createOp['value'], <String, Object?>{'name': '页面 2'});
      final Map<String, dynamic> deleteOp = Map<String, dynamic>.from(
          h.caller.toolCalls.last.args['operation'] as Map);
      expect(deleteOp['key'], 'pg:page-2:delete');
      expect(deleteOp['value'], isTrue);

      // 释放后忽略（回调仍挂在页面状态上的晚到触发）。
      h.session.dispose();
      h.session.handlePageOp('page-2', 'rename', '新名');
      expect(h.caller.toolCalls, hasLength(2));
    });

    test('防回发：远端页 op 应用窗口内的本地出口静默跳过', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);
      await h.connect();

      // 回调内再触发本地出口，模拟回声路径。
      h.session.onRemotePageOp = (String pageId, String field, Object? value) {
        h.session.handlePageOp(pageId, field, value);
      };
      h.caller.handler = (String toolId, Map<String, dynamic> args) {
        if (toolId != 'crdt.applyRemote') {
          return null;
        }
        return jsonEncode(<String, Object?>{
          'ok': true,
          'result': <String, Object?>{'applied': true},
        });
      };

      h.session.handleRemoteOps(<Object?>[
        _remoteOp('pg:p9:create', <String, Object?>{'name': '远端页'}, seq: 1),
      ]);

      // 仅 applyRemote 一次调用，无 applyLocal（窗口内出口被守卫拦截）。
      expect(h.caller.toolIds, <String>['crdt.applyRemote']);
      expect(h.bridge.ackCalls, isEmpty);
    });

    test('ack missingSeqs → 从有界缓存补发一次', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);
      await h.connect();

      h.caller.responses['crdt.applyLocal'] = jsonEncode(<String, Object?>{
        'ok': true,
        'result': <String, Object?>{
          'applied': true,
          'op': <String, Object?>{
            'key': 'el:e1:data',
            'value': <String, Object?>{'id': 'e1'},
            'actor': _actor,
            'seq': 1,
            'timestamp': 11,
          },
        },
      });

      int opsSends = 0;
      h.bridge.ackHandler = (String event, Object? payload) {
        if (event != 'board:ops') {
          return Future<Object?>.value(const <String, Object?>{'ok': true});
        }
        opsSends += 1;
        if (opsSends == 1) {
          // 首次 ack：缺口 [1]（本地缓存命中 `a1:1`）。
          return Future<Object?>.value(const <String, Object?>{
            'ok': false,
            'missingSeqs': <Object?>[1],
          });
        }
        return Future<Object?>.value(const <String, Object?>{'ok': true});
      };

      h.session.handleLocalCommit(
        const WbCanvasCommitBatch(pageId: 'p1', upserts: <WbCanvasElement>[_element]),
      );
      await _flush();

      final List<FakeAckCall> opsCalls = h.bridge.ackCalls
          .where((FakeAckCall c) => c.event == 'board:ops')
          .toList();
      expect(opsCalls, hasLength(2));
      // 补发内容 = 缓存中的原 op（不递归补发）。
      final List<Object?> resent = opsCalls.last.payload! as List<Object?>;
      expect(resent, hasLength(1));
      expect((resent.single! as Map<String, Object?>)['seq'], 1);
    });
  });

  group('远端入口（board:ops → applyRemote → 画布）', () {
    test('applied 三态：仅 applied=true 路由画布；水印全量推进', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);

      h.caller.handler = (String toolId, Map<String, dynamic> args) {
        if (toolId != 'crdt.applyRemote') {
          return null;
        }
        final Map<String, dynamic> operation =
            Map<String, dynamic>.from(args['operation'] as Map);
        return jsonEncode(<String, Object?>{
          'ok': true,
          'result': <String, Object?>{
            'applied': operation['key'] == 'el:e1:data',
          },
        });
      };

      h.session.handleRemoteOps(<Object?>[
        _remoteOp('el:e1:data', _remoteElementValue('e1'), seq: 1),
        _remoteOp('el:e2:data', _remoteElementValue('e2'), seq: 2),
        _remoteOp('el:e3:data', _remoteElementValue('e3'), seq: 3),
      ]);

      // 只路由 applied=true 的一条；LWW 败者 / duplicate 不上画布。
      expect(h.remoteElements, hasLength(1));
      expect(h.remoteElements.single.element.id, 'e1');
      expect(h.remoteElements.single.pageId, 'p1');
      // 水印按 actor 全量推进（应用成功即推进，与 applied 无关）。
      expect(h.session.watermarks, <String, Object?>{'a2': 3});
      // 防回发窗口：投递期间 isApplyingRemote=true，窗口结束复位。
      expect(h.applyingDuringDispatch, isTrue);
      expect(h.session.isApplyingRemote, isFalse);
    });

    test('key 路由：el:{id}:exists=false → onRemoteRemove；pg:{pageId}:{field} → onRemotePageOp', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);

      h.caller.handler = (String toolId, Map<String, dynamic> args) {
        if (toolId != 'crdt.applyRemote') {
          return null;
        }
        return jsonEncode(<String, Object?>{
          'ok': true,
          'result': <String, Object?>{'applied': true},
        });
      };

      h.session.handleRemoteOps(<Object?>[
        _remoteOp('el:e2:exists', false, seq: 1),
        _remoteOp('pg:p9:create', <String, Object?>{'action': 'create'}, seq: 2),
        _remoteOp('unknown:key', true, seq: 3), // 未知键忽略
      ]);

      expect(h.remoteRemoves, <String>['e2']);
      expect(h.remotePageOps, hasLength(1));
      expect(h.remotePageOps.single.pageId, 'p9');
      expect(h.remotePageOps.single.field, 'create');
      expect(h.remoteElements, isEmpty);
    });

    test('NotFound → 惰性 crdt.create（docId + actor）→ 重试一次', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);

      bool created = false;
      h.caller.handler = (String toolId, Map<String, dynamic> args) {
        if (toolId == 'crdt.create') {
          created = true;
          return null; // 缺省成功空结果
        }
        if (toolId == 'crdt.applyRemote' && !created) {
          return '{"ok":false,"error":{"code":"NotFound","message":"document not found"}}';
        }
        if (toolId == 'crdt.applyRemote') {
          return jsonEncode(<String, Object?>{
            'ok': true,
            'result': <String, Object?>{'applied': true},
          });
        }
        return null;
      };

      h.session.handleRemoteOps(<Object?>[
        _remoteOp('el:e1:data', _remoteElementValue('e1'), seq: 1),
      ]);

      expect(h.caller.toolIds,
          <String>['crdt.applyRemote', 'crdt.create', 'crdt.applyRemote']);
      final ({String toolId, Map<String, dynamic> args}) createCall = h
          .caller.toolCalls
          .firstWhere((({String toolId, Map<String, dynamic> args}) c) =>
              c.toolId == 'crdt.create');
      expect(createCall.args['docId'], 'board-1');
      expect(createCall.args['actor'], _actor);
      expect(h.remoteElements, hasLength(1));
      expect(h.session.lastError, isNull);
    });
  });

  group('快照恢复与 checkpoint', () {
    test('joined.snapshot：探测 NotFound → create + decodeState + state 回放画布 + 水印', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);

      // 探测：本端 doc 不存在（NotFound）。
      h.caller.responses['crdt.encodeState'] =
          '{"ok":false,"error":{"code":"NotFound","message":"document not found"}}';

      final String stateJson = jsonEncode(<String, Object?>{
        'el:e1:data': <String, Object?>{
          'value': _remoteElementValue('e1'),
          'timestamp': 5,
          'actor': 'a2',
        },
        'pg:p1:create': <String, Object?>{
          'value': <String, Object?>{'action': 'create'},
          'timestamp': 5,
          'actor': 'a2',
        },
      });

      h.session.handleJoined(<String, Object?>{
        'snapshot': <String, Object?>{
          'stateVector': <String, Object?>{'a2': 3},
          'payload': stateJson,
        },
      });

      expect(h.caller.toolIds,
          <String>['crdt.encodeState', 'crdt.create', 'crdt.decodeState']);
      final ({String toolId, Map<String, dynamic> args}) decodeCall = h
          .caller.toolCalls
          .firstWhere((({String toolId, Map<String, dynamic> args}) c) =>
              c.toolId == 'crdt.decodeState');
      expect(decodeCall.args['docId'], 'board-1');
      expect(decodeCall.args['state'], stateJson);

      // state 回放：el:* 键上画布（pg:* 忽略——页结构由 op 回放重建）。
      expect(h.remoteElements, hasLength(1));
      expect(h.remoteElements.single.element.id, 'e1');
      expect(h.remoteElements.single.pageId, 'p1');
      expect(h.remotePageOps, isEmpty);
      // 水印 = snapshot.stateVector。
      expect(h.session.watermarks, <String, Object?>{'a2': 3});
    });

    test('joined.snapshot：encodeState 成功（doc 已存在）→ 跳过恢复', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);

      h.caller.responses['crdt.encodeState'] =
          '{"ok":true,"result":{"state":"{}"}}';

      h.session.handleJoined(<String, Object?>{
        'snapshot': <String, Object?>{
          'stateVector': <String, Object?>{'a2': 3},
          'payload': '{...}',
        },
      });

      expect(h.caller.toolIds, <String>['crdt.encodeState']);
      expect(h.remoteElements, isEmpty);
      expect(h.session.watermarks, isEmpty);
    });

    test('board:checkpointRequest → encodeState → board:checkpoint 上报（含水印）', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);
      await h.connect();
      h.session.start();

      // 先制造水印（本地 op a1:2）。
      h.caller.responses['crdt.applyLocal'] = jsonEncode(<String, Object?>{
        'ok': true,
        'result': <String, Object?>{
          'applied': true,
          'op': <String, Object?>{
            'key': 'el:e1:data',
            'value': <String, Object?>{'id': 'e1'},
            'actor': _actor,
            'seq': 2,
            'timestamp': 12,
          },
        },
      });
      h.session.handleLocalCommit(
        const WbCanvasCommitBatch(pageId: 'p1', upserts: <WbCanvasElement>[_element]),
      );
      await _flush();

      const String state = '{"el:e1:data":{}}';
      h.caller.responses['crdt.encodeState'] = jsonEncode(<String, Object?>{
        'ok': true,
        'result': <String, Object?>{'state': state},
      });

      h.bridge.fireEvent('board:checkpointRequest', const <String, Object?>{});
      await _flush();

      final FakeAckCall checkpointCall = h.bridge.ackCalls
          .firstWhere((FakeAckCall c) => c.event == 'board:checkpoint');
      expect(checkpointCall.payload, <String, Object?>{
        'stateVector': <String, Object?>{_actor: 2},
        'payload': state,
      });
    });
  });

  group('初始自举推送（首个加入者全量同步）', () {
    test('Host + 空 stateVector + 本端首建 doc → 本地内容逐批上行', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);
      await h.connect();

      int provided = 0;
      h.session.initialContentProvider = () {
        provided += 1;
        return <WbCanvasCommitBatch>[
          const WbCanvasCommitBatch(
            pageId: 'p1',
            upserts: <WbCanvasElement>[_element],
          ),
        ];
      };
      h.caller.handler = (String toolId, Map<String, dynamic> args) {
        switch (toolId) {
          case 'crdt.encodeState':
            // 探测：本会话首建文档（NotFound）。
            return '{"ok":false,"error":{"code":"NotFound","message":"document not found"}}';
          case 'crdt.create':
            return null; // 缺省成功空结果
          case 'crdt.applyLocal':
            final Map<String, dynamic> operation =
                Map<String, dynamic>.from(args['operation'] as Map);
            return jsonEncode(<String, Object?>{
              'ok': true,
              'result': <String, Object?>{
                'applied': true,
                'op': <String, Object?>{
                  'key': operation['key'],
                  'value': operation['value'],
                  'actor': _actor,
                  'seq': 1,
                  'timestamp': 11,
                },
              },
            });
          default:
            return null;
        }
      };

      h.session.handleJoined(<String, Object?>{
        'role': 'Host',
        'stateVector': <String, Object?>{},
      });
      await _flush();

      // 探测 → 建文档 → 复用本地提交链路（编码 → applyLocal → board:ops）。
      expect(h.caller.toolIds,
          <String>['crdt.encodeState', 'crdt.create', 'crdt.applyLocal']);
      final ({String toolId, Map<String, dynamic> args}) applyCall =
          h.caller.toolCalls.last;
      final Map<String, dynamic> operation =
          Map<String, dynamic>.from(applyCall.args['operation'] as Map);
      expect(operation['key'], 'el:e1:data');
      expect((operation['value']! as Map)['pageId'], 'p1');

      final FakeAckCall opsCall = h.bridge.ackCalls.single;
      expect(opsCall.event, 'board:ops');
      final Map<String, Object?> sent =
          (opsCall.payload! as List<Object?>).single! as Map<String, Object?>;
      expect(sent['actor'], _actor);
      expect(sent['seq'], 1);
      expect(h.session.watermarks, <String, Object?>{_actor: 1});
      expect(h.session.lastError, isNull);

      // 重入（再次 joined）：防重入不再推送。
      h.session.handleJoined(<String, Object?>{
        'role': 'Host',
        'stateVector': <String, Object?>{},
      });
      await _flush();
      expect(provided, 1);
      expect(h.caller.toolIds, hasLength(3));
    });

    test('非自举条件跳过：stateVector 非空 / 非 Host / doc 已存在', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);
      await h.connect();

      int provided = 0;
      h.session.initialContentProvider = () {
        provided += 1;
        return <WbCanvasCommitBatch>[
          const WbCanvasCommitBatch(
            pageId: 'p1',
            upserts: <WbCanvasElement>[_element],
          ),
        ];
      };

      // 1) stateVector 非空（房间已有 op 历史）。
      h.session.handleJoined(<String, Object?>{
        'role': 'Host',
        'stateVector': <String, Object?>{'a2': 3},
      });
      // 2) 非 Host 角色（第二加入者 / 观众）。
      h.session.handleJoined(<String, Object?>{
        'role': 'Participant',
        'stateVector': <String, Object?>{},
      });
      expect(provided, 0);
      expect(h.caller.toolIds, isEmpty);

      // 3) doc 已存在（探测成功）→ 跳过推送（避免 seq 断档）。
      h.caller.responses['crdt.encodeState'] =
          '{"ok":true,"result":{"state":"{}"}}';
      h.session.handleJoined(<String, Object?>{
        'role': 'Host',
        'stateVector': <String, Object?>{},
      });
      expect(h.caller.toolIds, <String>['crdt.encodeState']);
      expect(provided, 0);
      expect(h.bridge.ackCalls, isEmpty);
    });
  });

  group('装配与释放', () {
    test('start 注册 4 回调；dispose 回收并清状态；dispose 幂等', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.realtime.dispose);
      await h.connect();

      h.session.start();
      expect(h.realtime.onBoardJoined, isNotNull);
      expect(h.realtime.onRemoteOps, isNotNull);
      expect(h.realtime.lastSeenVersionProvider, isNotNull);
      expect(h.realtime.onCheckpointRequest, isNotNull);
      expect(h.realtime.lastSeenVersionProvider!(), isEmpty);

      h.session.dispose();
      expect(h.realtime.onBoardJoined, isNull);
      expect(h.realtime.onRemoteOps, isNull);
      expect(h.realtime.lastSeenVersionProvider, isNull);
      expect(h.realtime.onCheckpointRequest, isNull);
      expect(h.session.watermarks, isEmpty);
      h.session.dispose(); // 幂等
    });

    test('join 载荷携带水印（重组 join 增量语义）', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);
      await h.connect();

      // 本地 op 推进水印后再 join：载荷应携带非空 lastSeenVersion。
      h.caller.responses['crdt.applyLocal'] = jsonEncode(<String, Object?>{
        'ok': true,
        'result': <String, Object?>{
          'applied': true,
          'op': <String, Object?>{
            'key': 'el:e1:data',
            'value': <String, Object?>{'id': 'e1'},
            'actor': _actor,
            'seq': 7,
            'timestamp': 21,
          },
        },
      });
      h.session.handleLocalCommit(
        const WbCanvasCommitBatch(pageId: 'p1', upserts: <WbCanvasElement>[_element]),
      );
      await _flush();

      h.session.start();
      await h.realtime.joinBoard('board-1');
      await _flush();

      final FakeAckCall joinCall = h.bridge.ackCalls
          .firstWhere((FakeAckCall c) => c.event == 'board:join');
      expect(joinCall.payload, <String, Object?>{
        'boardId': 'board-1',
        'lastSeenVersion': <String, Object?>{_actor: 7},
      });
    });
  });

  group('页结构链路（WbPageState 出口 → 会话 → board:ops）', () {
    test('addPage / rename → pg op 形状与线上载荷一致（装配口径 = 编辑页）', () async {
      final _SessionHarness h = _SessionHarness();
      addTearDown(h.disposeAll);
      await h.connect();

      int seq = 0;
      h.caller.handler = (String toolId, Map<String, dynamic> args) {
        if (toolId != 'crdt.applyLocal') {
          return null;
        }
        final Map<String, dynamic> operation =
            Map<String, dynamic>.from(args['operation'] as Map);
        seq += 1;
        return jsonEncode(<String, Object?>{
          'ok': true,
          'result': <String, Object?>{
            'applied': true,
            'op': <String, Object?>{
              'key': operation['key'],
              'value': operation['value'],
              'actor': _actor,
              'seq': seq,
              'timestamp': 20 + seq,
            },
          },
        });
      };

      final WbPageState pages = WbPageState(ops: const WbDemoPageOps())
        ..restore(boardId: 'board-1', pages: const <WbPage>[]);
      addTearDown(pages.dispose);
      // 装配口径 = 编辑页 `_startCollabSession`（出口 → 会话 handlePageOp）。
      pages.onPageOp = h.session.handlePageOp;

      pages.addPage(); // → board-1-page-2 / 页面 2
      pages.rename('board-1-page-2', '需求页');

      final List<Map<String, dynamic>> operations = <Map<String, dynamic>>[
        for (final ({String toolId, Map<String, dynamic> args}) call
            in h.caller.toolCalls)
          Map<String, dynamic>.from(call.args['operation'] as Map),
      ];
      expect(operations, hasLength(2));
      expect(operations[0]['key'], 'pg:board-1-page-2:create');
      expect(operations[0]['value'], <String, Object?>{'name': '页面 2'});
      expect(operations[1]['key'], 'pg:board-1-page-2:rename');
      expect(operations[1]['value'], '需求页');

      // 线上：op 经 board:ops 透传（可靠通道 → op log 回放供迟到者重建页结构）。
      await _flush();
      final List<Object?> sent =
          h.bridge.ackCalls.last.payload! as List<Object?>;
      expect(sent, hasLength(1));
      expect(
        (sent.single! as Map<String, Object?>)['key'],
        'pg:board-1-page-2:rename',
      );
    });
  });
}

/// 构造远端 op（模拟服务端广播载荷：key/value/actor/seq/timestamp）。
Map<String, Object?> _remoteOp(String key, Object? value, {required int seq}) =>
    <String, Object?>{
      'key': key,
      'value': value,
      'actor': 'a2',
      'seq': seq,
      'timestamp': 100 + seq,
    };

/// 远端元素 value：元素契约 JSON + 内嵌 pageId（对齐本地出口口径）。
Map<String, Object?> _remoteElementValue(String id, {String pageId = 'p1'}) {
  final Map<String, dynamic> value = WbBoardFileCodec.encodeElement(
    WbCanvasElement(id: id, type: 'note', x: 0, y: 0, width: 40, height: 30),
  );
  value['pageId'] = pageId;
  return value;
}

/// 冲刷微任务链（网络发送 / ack 处理为异步）。
Future<void> _flush() async {
  for (int i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 会话测试装配：可编程 caller + 假桥 realtime + 固定 actor 会话。
class _SessionHarness {
  _SessionHarness() {
    session.onRemoteElement = (WbCanvasElement element, {String? pageId}) {
      remoteElements.add((element: element, pageId: pageId));
      applyingDuringDispatch = session.isApplyingRemote;
    };
    session.onRemoteRemove = (String id) => remoteRemoves.add(id);
    session.onRemotePageOp = (String pageId, String field, Object? value) {
      remotePageOps.add((pageId: pageId, field: field, value: value));
    };
  }

  final _ProgrammableCaller caller = _ProgrammableCaller();
  final List<FakeSocketIoBridge> bridges = <FakeSocketIoBridge>[];

  late final WbRealtimeService realtime = WbRealtimeService(
    clientLoader: (String endpoint) => Future<void>.value(),
    bridgeFactory: () {
      final FakeSocketIoBridge created = FakeSocketIoBridge();
      bridges.add(created);
      return created;
    },
  );

  late final WbCollabSession session = WbCollabSession.withTools(
    tools: WbToolService(caller),
    realtime: realtime,
    boardId: 'board-1',
    actor: _actor,
  );

  final List<({WbCanvasElement element, String? pageId})> remoteElements =
      <({WbCanvasElement element, String? pageId})>[];
  final List<String> remoteRemoves = <String>[];
  final List<({String pageId, String field, Object? value})> remotePageOps =
      <({String pageId, String field, Object? value})>[];

  /// 元素回调投递时刻的 `isApplyingRemote`（防回发窗口观测）。
  bool? applyingDuringDispatch;

  FakeSocketIoBridge get bridge => bridges.last;

  Future<void> connect() async {
    await realtime.connect(_endpoint);
    bridge.fireConnected(socketId: 'sock-1');
  }

  void disposeAll() {
    session.dispose();
    realtime.dispose();
  }
}

/// 可编程引擎调用器：记录 `wb_execute_tool` 的 (toolId, args) 并返回信封。
///
/// 响应优先级：[handler]（动态，返回 null 时回退）→ [responses]（静态
/// 按 toolId）→ 缺省成功空结果 `{"ok":true,"result":{}}`。
class _ProgrammableCaller implements WbEngineCaller {
  static const String _emptyOk = '{"ok":true,"result":{}}';

  /// `wb_execute_tool` 调用记录（按顺序）。
  final List<({String toolId, Map<String, dynamic> args})> toolCalls =
      <({String toolId, Map<String, dynamic> args})>[];

  /// 静态响应表（toolId → 信封 JSON 字符串）。
  final Map<String, String> responses = <String, String>{};

  /// 动态响应（优先于 [responses]；返回 null 回退）。
  String? Function(String toolId, Map<String, dynamic> args)? handler;

  /// 全部调用过的 toolId 序列。
  List<String> get toolIds =>
      toolCalls.map((({String toolId, Map<String, dynamic> args}) c) => c.toolId)
          .toList(growable: false);

  @override
  String call2(String fn, String a, String b) {
    if (fn != 'wb_execute_tool') {
      return _emptyOk;
    }
    final Map<String, dynamic> args =
        Map<String, dynamic>.from(jsonDecode(b) as Map);
    toolCalls.add((toolId: a, args: args));
    return handler?.call(a, args) ?? responses[a] ?? _emptyOk;
  }

  @override
  int init([String configJson = '']) => 0;

  @override
  void shutdown() {}

  @override
  String versionString() => 'test';

  @override
  String call0(String fn) => _emptyOk;

  @override
  String call1(String fn, String a) => _emptyOk;

  @override
  String call3(String fn, String a, String b, String c) => _emptyOk;

  @override
  String callInt(String fn, int value) => _emptyOk;

  @override
  String call1Int(String fn, String a, int value) => _emptyOk;

  @override
  String call1Int2(String fn, String a, int x, int y) => _emptyOk;

  @override
  String call1Int1(String fn, String a, int value, String b) => _emptyOk;

  @override
  String call1Float2(String fn, String a, double x, double y) => _emptyOk;

  @override
  String callFloat3(String fn, double x, double y, double z) => _emptyOk;

  @override
  String callHandle(String fn, int handle) => _emptyOk;

  @override
  String callHandle1(String fn, int handle, String a) => _emptyOk;

  @override
  String callHandleInt(String fn, int handle, int value) => _emptyOk;

  @override
  String callHandle1Int2(
    String fn,
    int handle,
    String a,
    int x,
    int y,
  ) =>
      _emptyOk;

  @override
  int callU64(String fn, String a) => 0;

  @override
  void callVoidHandle(String fn, int handle) {}
}
