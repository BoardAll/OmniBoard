import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_core/wb_core.dart';

void main() {
  group('WbJsonCodec', () {
    test('encode/decode 往返', () {
      const Map<String, dynamic> data = <String, dynamic>{
        'a': 1,
        'b': 'x',
        'c': <int>[1, 2],
      };
      expect(WbJsonCodec.decode(WbJsonCodec.encode(data)), data);
    });

    test('decode 非对象抛 WbCoreException', () {
      expect(
        () => WbJsonCodec.decode('[1,2]'),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'InvalidJson')),
      );
    });

    test('tryDecode 宽容非法输入', () {
      expect(WbJsonCodec.tryDecode('not json'), isNull);
      expect(WbJsonCodec.tryDecode(''), isNull);
      expect(WbJsonCodec.tryDecode(null), isNull);
      expect(WbJsonCodec.tryDecode('{"k":1}'), <String, dynamic>{'k': 1});
    });

    test('extractList 宽容非列表', () {
      expect(WbJsonCodec.extractList(null), isEmpty);
      expect(WbJsonCodec.extractList('x'), isEmpty);
      expect(
        WbJsonCodec.extractList(<dynamic>[
          <String, dynamic>{'id': 'a'},
          'skip',
        ]),
        hasLength(1),
      );
    });

    test('unwrap 解包外包对象', () {
      final Map<String, dynamic> wrapped = <String, dynamic>{
        'page': <String, dynamic>{'id': 'p1'},
      };
      expect(WbJsonCodec.unwrap(wrapped, 'page')['id'], 'p1');
      expect(WbJsonCodec.unwrap(<String, dynamic>{'x': 1}, 'page')['x'], 1);
    });
  });

  group('WbResponse', () {
    test('解析成功信封', () {
      final WbResponse response =
          WbResponse.parse('{"ok":true,"result":{"handle":7}}');
      expect(response.ok, isTrue);
      expect(response.requireResult()['handle'], 7);
    });

    test('解析错误信封并抛出', () {
      final WbResponse response = WbResponse.parse(
        '{"ok":false,"error":{"code":"NotFound","message":"unknown board"}}',
      );
      expect(response.ok, isFalse);
      expect(response.code, 'NotFound');
      expect(
        response.requireResult,
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'NotFound')
            .having((WbCoreException e) => e.message, 'message', 'unknown board')),
      );
    });

    test('非信封结构按成功对象处理', () {
      final WbResponse response =
          WbResponse.parse('{"id":"board-1","name":"n"}');
      expect(response.ok, isTrue);
      expect(response.requireResult()['id'], 'board-1');
    });

    test('非法 JSON 信封返回 InvalidJson', () {
      final WbResponse response = WbResponse.parse('<<bad>>');
      expect(response.ok, isFalse);
      expect(response.code, 'InvalidJson');
    });

    test('listAt 提取列表', () {
      final WbResponse response = WbResponse.parse(
        '{"ok":true,"result":{"pages":[{"id":"p1"},{"id":"p2"}]}}',
      );
      expect(response.listAt('pages'), hasLength(2));
      expect(response.listAt('missing'), isEmpty);
    });
  });

  group('WbBinaryCodec', () {
    test('协议头编码/解码往返', () {
      final Uint8List bytes = WbBinaryCodec.encodeHeader(
        magic: WbBinaryCodec.defaultMagic,
        version: 3,
        type: 5,
        size: 128,
        flags: 1,
      );
      expect(bytes.length, WbBinaryCodec.headerSize);
      final WbBinaryHeader header = WbBinaryCodec.decodeHeader(bytes);
      expect(header.magic, WbBinaryCodec.defaultMagic);
      expect(header.version, 3);
      expect(header.type, 5);
      expect(header.size, 128);
      expect(header.flags, 1);
    });

    test('魔数不匹配抛 FormatException', () {
      final Uint8List bytes = WbBinaryCodec.encodeHeader(
        magic: 0xDEADBEEF,
        version: 1,
        type: 0,
        size: 0,
        flags: 0,
      );
      expect(() => WbBinaryCodec.decodeHeader(bytes), throwsFormatException);
    });

    test('字节不足抛 FormatException', () {
      expect(
        () => WbBinaryCodec.decodeHeader(Uint8List(8)),
        throwsFormatException,
      );
    });

    test('整帧编码/解码往返', () {
      final Uint8List payload = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
      final Uint8List frame = WbBinaryCodec.encodeFrame(
        type: 2,
        payload: payload,
      );
      expect(frame.length, WbBinaryCodec.headerSize + payload.length);
      final (WbBinaryHeader header, Uint8List body) =
          WbBinaryCodec.decodeFrame(frame);
      expect(header.type, 2);
      expect(header.size, payload.length);
      expect(body, payload);
    });
  });

  group('WbHandleManager', () {
    test('注册 / 取回 / 注销', () {
      final WbHandleManager manager = WbHandleManager();
      final WbHandle handle = manager.register('ctx');
      expect(handle.isValid, isTrue);
      expect(manager.get<String>(handle), 'ctx');
      expect(manager.contains(handle), isTrue);
      expect(manager.length, 1);
      expect(manager.unregister(handle), isTrue);
      expect(manager.contains(handle), isFalse);
      expect(manager.unregister(handle), isFalse);
    });

    test('invalid 句柄与类型不匹配', () {
      expect(WbHandle.invalid.isValid, isFalse);
      final WbHandleManager manager = WbHandleManager();
      final WbHandle handle = manager.register(42);
      expect(manager.get<String>(handle), isNull);
      expect(manager.get<int>(handle), 42);
      manager.clear();
      expect(manager.length, 0);
    });
  });

  group('models', () {
    test('WbPage 宽容解析', () {
      final WbPage page = WbPage.fromJson(<String, dynamic>{
        'id': 'page-1',
        'name': '页面 1',
        'locked': true,
        'background': <String, dynamic>{'preset': 'dot'},
        'elementCount': 3,
      });
      expect(page.id, 'page-1');
      expect(page.locked, isTrue);
      expect(page.hidden, isFalse);
      expect(page.background['preset'], 'dot');
      expect(page.elementCount, 3);
      expect(WbPage.fromJson(<String, dynamic>{}).id, '');
    });

    test('WbElement 解析 position/size 与 raw 透传', () {
      final WbElement element = WbElement.fromJson(<String, dynamic>{
        'id': 'el-1',
        'type': 'note',
        'position': <String, dynamic>{'x': 10.5, 'y': 20},
        'size': <String, dynamic>{'width': 200, 'height': 120},
        'zIndex': 2,
        'content': 'hi',
      });
      expect(element.x, 10.5);
      expect(element.y, 20);
      expect(element.width, 200);
      expect(element.height, 120);
      expect(element['content'], 'hi');
      expect(element.zIndex, 2);
      expect(element.visible, isTrue);
    });

    test('WbBoard 解析 pages', () {
      final WbBoard board = WbBoard.fromJson(<String, dynamic>{
        'id': 'board-1',
        'handle': 1,
        'name': '未命名白板',
        'pages': <dynamic>[
          <String, dynamic>{'id': 'page-1', 'name': '页面 1'},
        ],
      });
      expect(board.handle, 1);
      expect(board.pages, hasLength(1));
      expect(board.pageCount, 1);
      expect(board.pages.first.id, 'page-1');
    });

    test('WbTool.listFromJson 与 WbToolSchema', () {
      final List<WbTool> tools = WbTool.listFromJson(<dynamic>[
        <String, dynamic>{'id': 'edit.pen', 'name': '画笔', 'category': 'edit'},
      ]);
      expect(tools, hasLength(1));
      expect(tools.first.id, 'edit.pen');
      final WbToolSchema schema = WbToolSchema.fromJson(<String, dynamic>{
        'id': 'edit.pen',
        'name': '画笔',
        'argsSchema': <String, dynamic>{'type': 'object'},
      });
      expect(schema.tool.id, 'edit.pen');
      expect(schema.argsSchema['type'], 'object');
      expect(schema.encodeSchema(), contains('object'));
    });

    test('WbThemeSpec colorOf', () {
      final WbThemeSpec spec = WbThemeSpec.fromJson(<String, dynamic>{
        'id': 'dark-night',
        'name': '暗夜',
        'dark': true,
        'colors': <String, dynamic>{'primary': '#4C88FF'},
      });
      expect(spec.dark, isTrue);
      expect(spec.colorOf('primary'), '#4C88FF');
      expect(spec.colorOf('missing'), isNull);
    });
  });

  group('background presets', () {
    test('11 个内置预设且 id 唯一', () {
      const List<WbBackgroundPreset> presets =
          WbBackgroundService.builtinPresets;
      expect(presets, hasLength(11));
      expect(
        presets.map((WbBackgroundPreset p) => p.id).toSet(),
        hasLength(11),
      );
      expect(presets.first.id, 'whiteboard');
      expect(
        presets.where((WbBackgroundPreset p) => p.dark).map(
              (WbBackgroundPreset p) => p.id,
            ),
        unorderedEquals(<String>['blackboard', 'greenboard', 'dark-dot', 'dark-grid']),
      );
    });

    test('presetById 查找与 toBackgroundJson 形状', () {
      final WbBackgroundPreset dot =
          WbBackgroundService.presetById('dot')!;
      expect(dot.spacing, 20);
      expect(dot.lineColor, '#D0D5DD');
      final Map<String, dynamic> json = dot.toBackgroundJson();
      expect(json['id'], 'dot');
      expect(json['pattern'], 'dot');
      expect(json['baseColor'], '#FFFFFF');
      expect(json['patternColor'], '#D0D5DD');
      expect(json['preset'], 'dot');
      expect(WbBackgroundService.presetById('nope'), isNull);
    });
  });

  group('sync/crdt 响应类型（纯解析）', () {
    test('WbSyncStatusData 解析与宽容缺省', () {
      final WbSyncStatusData full = WbSyncStatusData.fromJson(<String, dynamic>{
        'connected': true,
        'endpoint': 'wss://sync.example/board',
        'offline': false,
        'participants': 2,
        'pendingCount': 3,
        'sentCount': 4,
        'syncedCount': 5,
        'latencyMs': 42,
        'reconnectCount': 1,
        'transport': 'socketio',
        'transportState': 'connected',
      });
      expect(full.connected, isTrue);
      expect(full.endpoint, 'wss://sync.example/board');
      expect(full.participants, 2);
      expect(full.pendingCount, 3);
      expect(full.sentCount, 4);
      expect(full.syncedCount, 5);
      expect(full.latencyMs, 42);
      expect(full.reconnectCount, 1);
      expect(full.transport, 'socketio');
      expect(full.transportState, 'connected');

      final WbSyncStatusData blank =
          WbSyncStatusData.fromJson(<String, dynamic>{});
      expect(blank.connected, isFalse);
      expect(blank.offline, isFalse);
      expect(blank.participants, 0);
      expect(blank.transport, '');
      expect(blank.transportState, 'disconnected');
    });

    test('WbSyncEventsData 解析 ops/previews/room/status', () {
      final WbSyncEventsData data = WbSyncEventsData.fromJson(<String, dynamic>{
        'ops': <dynamic>[
          <String, dynamic>{
            'actor': 'u2',
            'seq': 2,
            'key': 'a',
            'value': 1,
            'origin': 'remote',
          },
          <String, dynamic>{
            'actor': 'u3',
            'seq': 3,
            'key': 'b',
            'value': 2,
            'origin': 'remote',
          },
        ],
        'previews': <dynamic>[
          <String, dynamic>{'kind': 'transform', 'x': 1.5},
        ],
        'room': <String, dynamic>{
          'participants': <dynamic>['u1', 'u2'],
          'mode': 'free',
          'locks': <String, dynamic>{
            'el-1': <String, dynamic>{'userId': 'u1', 'expiresAt': 111},
          },
          'lockAcks': <dynamic>[
            <String, dynamic>{
              'elementId': 'el-1',
              'action': 'acquire',
              'granted': true,
              'holderUserId': 'u1',
              'expiresAt': 111,
              'ok': true,
            },
          ],
        },
        'status': <String, dynamic>{'connected': true, 'pendingCount': 1},
      });
      expect(data.ops, hasLength(2));
      expect(data.ops.first['actor'], 'u2');
      expect(data.ops.first['origin'], 'remote');
      expect(data.previews, hasLength(1));
      expect(data.previews.first['kind'], 'transform');
      expect(data.room.participants, <dynamic>['u1', 'u2']);
      expect(data.room.mode, 'free');
      expect(data.room.locks, hasLength(1));
      expect(data.room.locks['el-1']['userId'], 'u1');
      expect(data.room.locks['el-1']['expiresAt'], 111);
      expect(data.room.lockAcks, hasLength(1));
      expect(data.room.lockAcks.first['elementId'], 'el-1');
      expect(data.room.lockAcks.first['action'], 'acquire');
      expect(data.room.lockAcks.first['granted'], isTrue);
      expect(data.room.lockAcks.first['ok'], isTrue);
      expect(data.status.connected, isTrue);
      expect(data.status.pendingCount, 1);

      final WbSyncEventsData empty =
          WbSyncEventsData.fromJson(<String, dynamic>{});
      expect(empty.ops, isEmpty);
      expect(empty.previews, isEmpty);
      expect(empty.room.mode, '');
      expect(empty.room.participants, isEmpty);
      expect(empty.room.locks, isEmpty);
      expect(empty.room.lockAcks, isEmpty);
      expect(empty.status.connected, isFalse);
    });

    test('WbSyncRoomData locks 对象 map / lockAcks 形状与缺省', () {
      final WbSyncRoomData room = WbSyncRoomData.fromJson(<String, dynamic>{
        'locks': <String, dynamic>{
          'el-1': <String, dynamic>{'userId': 'u1', 'expiresAt': 1000},
          'el-2': <String, dynamic>{'userId': 'u2', 'expiresAt': 2000},
        },
        'lockAcks': <dynamic>[
          <String, dynamic>{
            'elementId': 'el-1',
            'action': 'acquire',
            'granted': true,
            'holderUserId': 'u1',
            'expiresAt': 1000,
            'ok': true,
          },
          <String, dynamic>{
            'elementId': 'el-2',
            'action': 'renew',
            'granted': false,
            'ok': false,
          },
        ],
      });
      expect(room.locks, hasLength(2));
      expect(room.locks['el-1'], <String, dynamic>{
        'userId': 'u1',
        'expiresAt': 1000,
      });
      expect(room.locks['el-2']['expiresAt'], 2000);
      expect(room.lockAcks, hasLength(2));
      expect(room.lockAcks.first['holderUserId'], 'u1');
      expect(room.lockAcks.last['action'], 'renew');
      expect(room.lockAcks.last.containsKey('holderUserId'), isFalse);

      final WbSyncRoomData blank = WbSyncRoomData.fromJson(<String, dynamic>{});
      expect(blank.locks, isEmpty);
      expect(blank.lockAcks, isEmpty);
    });

    test('WbSyncRoomData 旧数组 locks 宽容降级为空 map', () {
      final WbSyncRoomData legacy = WbSyncRoomData.fromJson(<String, dynamic>{
        'locks': <dynamic>[
          <String, dynamic>{'elementId': 'el-1', 'userId': 'u1'},
        ],
      });
      expect(legacy.locks, isEmpty);

      final WbSyncRoomData malformed = WbSyncRoomData.fromJson(<String, dynamic>{
        'locks': 'not-a-map',
        'lockAcks': 'not-a-list',
      });
      expect(malformed.locks, isEmpty);
      expect(malformed.lockAcks, isEmpty);
    });

    test('join / sendOperation / flush / sendPreview 响应解析', () {
      final WbSyncJoinData joined = WbSyncJoinData.fromJson(<String, dynamic>{
        'boardId': 'board-1',
        'joined': true,
        'pageId': 'page-2',
      });
      expect(joined.boardId, 'board-1');
      expect(joined.joined, isTrue);
      expect(joined.pageId, 'page-2');
      expect(
        WbSyncJoinData.fromJson(<String, dynamic>{'boardId': 'board-2'}).pageId,
        isNull,
      );

      final WbSyncSendResult queued = WbSyncSendResult.fromJson(<String, dynamic>{
        'queued': true,
        'sent': false,
        'pendingCount': 2,
        'syncedCount': 4,
      });
      expect(queued.sent, isFalse);
      expect(queued.queued, isTrue);
      expect(queued.pendingCount, 2);
      expect(queued.syncedCount, 4);

      final WbSyncFlushData flushed = WbSyncFlushData.fromJson(<String, dynamic>{
        'synced': 3,
        'pendingCount': 0,
        'syncedCount': 7,
      });
      expect(flushed.synced, 3);
      expect(flushed.pendingCount, 0);
      expect(flushed.syncedCount, 7);

      final WbSyncPreviewResult sent =
          WbSyncPreviewResult.fromJson(<String, dynamic>{'sent': true});
      expect(sent.sent, isTrue);
      expect(sent.dropped, isFalse);
      final WbSyncPreviewResult dropped =
          WbSyncPreviewResult.fromJson(<String, dynamic>{'dropped': true});
      expect(dropped.sent, isFalse);
      expect(dropped.dropped, isTrue);
    });

    test('WbSyncLockResult 解析 requested', () {
      final WbSyncLockResult accepted =
          WbSyncLockResult.fromJson(<String, dynamic>{'requested': true});
      expect(accepted.requested, isTrue);
      final WbSyncLockResult rejected =
          WbSyncLockResult.fromJson(<String, dynamic>{'requested': false});
      expect(rejected.requested, isFalse);
      expect(
        WbSyncLockResult.fromJson(<String, dynamic>{}).requested,
        isFalse,
      );
    });

    test('WbCrdtCreateData / WbCrdtApplyData 解析（含 op 字段）', () {
      final WbCrdtCreateData created = WbCrdtCreateData.fromJson(<String, dynamic>{
        'docId': 'board-1',
        'actor': 'm1',
        'version': 0,
      });
      expect(created.docId, 'board-1');
      expect(created.actor, 'm1');
      expect(created.version, 0);

      final WbCrdtApplyData applied = WbCrdtApplyData.fromJson(<String, dynamic>{
        'applied': true,
        'docId': 'board-1',
        'key': 'title',
        'origin': 'local',
        'seq': 1,
        'version': 1,
        'op': <String, dynamic>{
          'actor': 'm1',
          'seq': 1,
          'key': 'title',
          'value': 'hello',
          'origin': 'local',
          'timestamp': 123456,
        },
      });
      expect(applied.applied, isTrue);
      expect(applied.docId, 'board-1');
      expect(applied.key, 'title');
      expect(applied.origin, 'local');
      expect(applied.seq, 1);
      expect(applied.version, 1);
      expect(applied.op['actor'], 'm1');
      expect(applied.op['seq'], 1);
      expect(applied.op['key'], 'title');
      expect(applied.op['value'], 'hello');
      expect(applied.op['origin'], 'local');
      expect(applied.op['timestamp'], 123456);

      final WbCrdtApplyData blank =
          WbCrdtApplyData.fromJson(<String, dynamic>{});
      expect(blank.applied, isFalse);
      expect(blank.origin, 'local');
      expect(blank.op, isEmpty);
    });

    test('sync 信封 ok / error 两路径', () {
      final WbResponse success = WbResponse.parse(
        '{"ok":true,"result":{"connected":false,"transport":"socketio"}}',
      );
      expect(success.ok, isTrue);
      final WbSyncStatusData data =
          WbSyncStatusData.fromJson(success.requireResult());
      expect(data.connected, isFalse);
      expect(data.transport, 'socketio');

      final WbResponse failure = WbResponse.parse(
        '{"ok":false,"error":{"code":"Conflict",'
        '"message":"sync transport is not connected"}}',
      );
      expect(failure.ok, isFalse);
      expect(failure.code, 'Conflict');
      expect(
        failure.requireResult,
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'Conflict')
            .having((WbCoreException e) => e.message, 'message',
                'sync transport is not connected')),
      );
    });

    test('WbSyncInteractiveResult 解析 requested', () {
      final WbSyncInteractiveResult accepted = WbSyncInteractiveResult.fromJson(
        <String, dynamic>{'requested': true},
      );
      expect(accepted.requested, isTrue);
      final WbSyncInteractiveResult rejected = WbSyncInteractiveResult.fromJson(
        <String, dynamic>{'requested': false},
      );
      expect(rejected.requested, isFalse);
      expect(
        WbSyncInteractiveResult.fromJson(<String, dynamic>{}).requested,
        isFalse,
      );
    });

    test('WbSyncRoomData M3 快照字段解析与宽容', () {
      final WbSyncRoomData room = WbSyncRoomData.fromJson(<String, dynamic>{
        'mode': 'present',
        'selfRole': 'Presenter',
        'presenterId': 'u1',
        'hostUserId': 'u9',
        'grantedWrite': true,
        'checkpointStatus': 'requested',
        'recovered': true,
      });
      expect(room.mode, 'present');
      expect(room.selfRole, 'Presenter');
      expect(room.presenterId, 'u1');
      expect(room.hostUserId, 'u9');
      expect(room.grantedWrite, isTrue);
      expect(room.checkpointStatus, 'requested');
      expect(room.recovered, isTrue);

      final WbSyncRoomData blank = WbSyncRoomData.fromJson(<String, dynamic>{});
      expect(blank.selfRole, '');
      expect(blank.presenterId, '');
      expect(blank.hostUserId, '');
      expect(blank.grantedWrite, isFalse);
      expect(blank.checkpointStatus, 'idle');
      expect(blank.recovered, isFalse);

      final WbSyncRoomData malformed = WbSyncRoomData.fromJson(<String, dynamic>{
        'selfRole': 42,
        'presenterId': <String, dynamic>{},
        'hostUserId': false,
        'grantedWrite': 'yes',
        'checkpointStatus': 3,
        'recovered': 'true',
      });
      expect(malformed.selfRole, '');
      expect(malformed.presenterId, '');
      expect(malformed.hostUserId, '');
      expect(malformed.grantedWrite, isFalse);
      expect(malformed.checkpointStatus, 'idle');
      expect(malformed.recovered, isFalse);
    });

    test('WbSyncEventsData M3 drain 批次解析（acks / follows / removed）', () {
      final WbSyncEventsData data = WbSyncEventsData.fromJson(<String, dynamic>{
        'interactiveAcks': <dynamic>[
          <String, dynamic>{'action': 'raiseHand', 'ok': true},
          <String, dynamic>{
            'action': 'grantControl',
            'ok': false,
            'reason': 'permission denied',
          },
        ],
        'incomingFollows': <dynamic>[
          <String, dynamic>{'followerUserId': 'u3', 'action': 'follow'},
          <String, dynamic>{'followerUserId': 'u4', 'action': 'unfollow'},
        ],
        'removed': <String, dynamic>{'reason': 'kicked by host'},
      });
      expect(data.interactiveAcks, hasLength(2));
      expect(data.interactiveAcks.first['action'], 'raiseHand');
      expect(data.interactiveAcks.first['ok'], isTrue);
      expect(data.interactiveAcks.first.containsKey('reason'), isFalse);
      expect(data.interactiveAcks.last['reason'], 'permission denied');
      expect(data.incomingFollows, hasLength(2));
      expect(data.incomingFollows.first['followerUserId'], 'u3');
      expect(data.incomingFollows.first['action'], 'follow');
      expect(data.incomingFollows.last['action'], 'unfollow');
      expect(data.removed['reason'], 'kicked by host');

      final WbSyncEventsData blank =
          WbSyncEventsData.fromJson(<String, dynamic>{});
      expect(blank.interactiveAcks, isEmpty);
      expect(blank.incomingFollows, isEmpty);
      expect(blank.removed, isEmpty);

      final WbSyncEventsData malformed =
          WbSyncEventsData.fromJson(<String, dynamic>{
        'interactiveAcks': 'not-a-list',
        'incomingFollows': <String, dynamic>{'x': 1},
        'removed': 'not-a-map',
      });
      expect(malformed.interactiveAcks, isEmpty);
      expect(malformed.incomingFollows, isEmpty);
      expect(malformed.removed, isEmpty);
    });
  });

  group('native smoke (wb_core.dll)', () {
    final String dllPath = _findWbCoreDll();
    final bool available = dllPath.isNotEmpty;

    test('init / version / board / theme 冒烟', () {
      final WbCoreFfi ffi = WbCoreFfi.load(overridePath: dllPath);
      expect(ffi.init(), 0);
      expect(ffi.versionString(), '1.0.0');

      // 白板生命周期。
      final WbBoardService boards = WbBoardService(ffi);
      final int handle = boards.create(name: 'FFI 冒烟画板');
      expect(handle, greaterThan(0));
      final WbBoard board = boards.get(handle);
      expect(board.name, 'FFI 冒烟画板');
      expect(board.pages, isNotEmpty);

      // 页面列表。
      final WbPageService pages = WbPageService(ffi);
      final List<WbPage> pageList = pages.list(board.id);
      expect(pageList, isNotEmpty);

      // 背景预设（客户端解析 → page 域写入）。
      final WbBackgroundService backgrounds = WbBackgroundService(ffi, pages);
      final Map<String, dynamic> applied =
          backgrounds.setPreset(pageList.first.id, 'dot');
      final Map<String, dynamic> background =
          Map<String, dynamic>.from(applied['background'] as Map);
      expect(background['preset'], 'dot');
      expect(background['pattern'], 'dot');

      // 主题域。
      final WbThemeService themes = WbThemeService(ffi);
      expect(themes.list(), hasLength(9));
      final WbThemeSpec dark = themes.applyById('dark-night');
      expect(dark.id, 'dark-night');
      expect(dark.dark, isTrue);
      expect(dark.colorOf('primary'), '#4C88FF');
      expect(themes.current().id, 'dark-night');

      // 工具域。
      final WbToolService tools = WbToolService(ffi);
      expect(tools.list(), isNotEmpty);

      boards.destroy(handle);
      ffi.shutdown();
    }, skip: available ? false : 'wb_core.dll 不存在，跳过原生冒烟');
  });

  group('sync/crdt native (wb_core.dll)', () {
    final String dllPath = _findWbCoreDll();
    final bool available = dllPath.isNotEmpty;

    test('绑定表暴露 13 个协同符号', () {
      final WbCoreFfi ffi = WbCoreFfi.load(overridePath: dllPath);
      final WbCoreBindings bindings = ffi.bindings;
      // 控制面（既有 4）。
      expect(bindings.wbSyncConnect, isNotNull);
      expect(bindings.wbSyncDisconnect, isNotNull);
      expect(bindings.wbSyncStatus, isNotNull);
      expect(bindings.wbSyncSetOffline, isNotNull);
      // 数据面（M1 新增 5）。
      expect(bindings.wbSyncJoin, isNotNull);
      expect(bindings.wbSyncSendOperation, isNotNull);
      expect(bindings.wbSyncFlush, isNotNull);
      expect(bindings.wbSyncEvents, isNotNull);
      expect(bindings.wbSyncSendPreview, isNotNull);
      // M2 锁转发（+1）。
      expect(bindings.wbSyncLock, isNotNull);
      // M3 交互转发（+1）。
      expect(bindings.wbSyncInteractive, isNotNull);
      // CRDT（M1 新增 2）。
      expect(bindings.wbCrdtCreate, isNotNull);
      expect(bindings.wbCrdtApplyLocal, isNotNull);
    }, skip: available ? false : 'wb_core.dll 不存在，跳过 sync/crdt 原生回归');

    test('connect 空 endpoint → InvalidArgument', () {
      final WbSyncService sync =
          WbSyncService(WbCoreFfi.load(overridePath: dllPath));
      expect(
        () => sync.connect(endpoint: ''),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'InvalidArgument')),
      );
    }, skip: available ? false : 'wb_core.dll 不存在，跳过 sync/crdt 原生回归');

    test('status / setOffline 状态快照', () {
      final WbSyncService sync =
          WbSyncService(WbCoreFfi.load(overridePath: dllPath));
      final WbSyncStatusData offline = sync.setOffline(false);
      expect(offline.offline, isFalse);
      final WbSyncStatusData snapshot = sync.status();
      expect(snapshot.connected, isFalse);
      expect(snapshot.endpoint, '');
      expect(snapshot.transport, 'socketio');
      expect(snapshot.transportState, 'disconnected');
      expect(snapshot.participants, 0);
    }, skip: available ? false : 'wb_core.dll 不存在，跳过 sync/crdt 原生回归');

    test('join 参数校验与未连接 Conflict', () {
      final WbSyncService sync =
          WbSyncService(WbCoreFfi.load(overridePath: dllPath));
      expect(
        () => sync.join(''),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'InvalidArgument')),
      );
      expect(
        () => sync.join('board-m1-dart'),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'Conflict')),
      );
    }, skip: available ? false : 'wb_core.dll 不存在，跳过 sync/crdt 原生回归');

    test('sendOperation 未连接入队 / flush Conflict / events drain', () {
      final WbSyncService sync =
          WbSyncService(WbCoreFfi.load(overridePath: dllPath));
      sync.setOffline(false); // 归一化，保证断言确定性。

      expect(
        () => sync.sendOperation(const <String, dynamic>{}),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'InvalidArgument')),
      );

      final WbSyncSendResult first = sync.sendOperation(
        const <String, dynamic>{'key': 'm1-k1', 'value': 'v1'},
      );
      expect(first.sent, isFalse);
      expect(first.queued, isTrue);
      expect(first.pendingCount, greaterThanOrEqualTo(1));

      final WbSyncSendResult second = sync.sendOperation(
        const <String, dynamic>{'key': 'm1-k2', 'value': 'v2'},
      );
      expect(second.pendingCount, first.pendingCount + 1);

      expect(
        () => sync.flush(),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'Conflict')),
      );

      final WbSyncEventsData events = sync.events();
      expect(events.ops, isEmpty);
      expect(events.previews, isEmpty);
      expect(events.room.mode, '');
      expect(events.room.participants, isEmpty);
      expect(events.room.locks, isEmpty);
      expect(events.room.lockAcks, isEmpty);
      expect(events.status.pendingCount, greaterThanOrEqualTo(second.pendingCount));
    }, skip: available ? false : 'wb_core.dll 不存在，跳过 sync/crdt 原生回归');

    test('sendPreview 参数校验与未连接 dropped', () {
      final WbSyncService sync =
          WbSyncService(WbCoreFfi.load(overridePath: dllPath));
      expect(
        () => sync.sendPreview(const <String, dynamic>{}),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'InvalidArgument')),
      );
      final WbSyncPreviewResult result = sync.sendPreview(
        const <String, dynamic>{'kind': 'transform', 'x': 1.0},
      );
      expect(result.dropped, isTrue);
      expect(result.sent, isFalse);
    }, skip: available ? false : 'wb_core.dll 不存在，跳过 sync/crdt 原生回归');

    test('lock 参数校验与离线 requested:false', () {
      final WbSyncService sync =
          WbSyncService(WbCoreFfi.load(overridePath: dllPath));
      sync.setOffline(false); // 归一化，保证断言确定性。

      expect(
        () => sync.lock(action: '', elementId: 'm2-dart-el'),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'InvalidArgument')),
      );
      expect(
        () => sync.lock(action: 'acquire', elementId: ''),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'InvalidArgument')),
      );
      expect(
        () => sync.lock(action: 'bogus', elementId: 'm2-dart-el'),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'InvalidArgument')),
      );

      // 未连接 → 静默降级 requested:false（恒 ok，不抛 Conflict）；
      // 异步授予结果经 events 的 room.lockAcks。
      final WbSyncLockResult offline =
          sync.lock(action: 'acquire', elementId: 'm2-dart-el');
      expect(offline.requested, isFalse);
    }, skip: available ? false : 'wb_core.dll 不存在，跳过 sync/crdt 原生回归');

    test('interactive 参数校验与离线 requested:false', () {
      final WbSyncService sync =
          WbSyncService(WbCoreFfi.load(overridePath: dllPath));
      sync.setOffline(false); // 归一化，保证断言确定性。

      expect(
        () => sync.interactive(action: ''),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'InvalidArgument')),
      );
      expect(
        () => sync.interactive(action: 'bogus'),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'InvalidArgument')),
      );
      expect(
        () => sync.interactive(action: 'grantControl'),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'InvalidArgument')),
      );
      expect(
        () => sync.interactive(action: 'follow'),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'InvalidArgument')),
      );

      // 未连接 → 静默降级 requested:false（恒 ok，不抛 Conflict）；
      // 异步结果经 events 的 interactiveAcks。
      final WbSyncInteractiveResult offline =
          sync.interactive(action: 'raiseHand');
      expect(offline.requested, isFalse);
      final WbSyncInteractiveResult followRequest =
          sync.interactive(action: 'follow', targetUserId: 'u-peer');
      expect(followRequest.requested, isFalse);
    }, skip: available ? false : 'wb_core.dll 不存在，跳过 sync/crdt 原生回归');

    test('crdt create / applyLocal / op 直发 / NotFound', () {
      final WbCoreFfi ffi = WbCoreFfi.load(overridePath: dllPath);
      final WbCrdtService crdt = WbCrdtService(ffi);
      final WbSyncService sync = WbSyncService(ffi);

      final WbCrdtCreateData created =
          crdt.create('board-m1-dart', actor: 'm1-dart');
      expect(created.docId, 'board-m1-dart');
      expect(created.actor, 'm1-dart');
      expect(created.version, 0);

      expect(
        () => crdt.create('board-m1-dart'),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'Conflict')),
      );

      final WbCrdtApplyData applied = crdt.applyLocal(
        'board-m1-dart',
        const <String, dynamic>{'key': 'title', 'value': 'hello'},
      );
      expect(applied.applied, isTrue);
      expect(applied.docId, 'board-m1-dart');
      expect(applied.key, 'title');
      expect(applied.origin, 'local');
      expect(applied.seq, 1);
      expect(applied.version, 1);
      expect(applied.op['actor'], 'm1-dart');
      expect(applied.op['seq'], 1);
      expect(applied.op['key'], 'title');
      expect(applied.op['value'], 'hello');
      expect(applied.op['origin'], 'local');
      expect(applied.op['timestamp'], isA<int>());

      // 响应 op 为完整规范化对象，可直接走 sendOperation（未连接 → 入队）。
      final WbSyncSendResult forwarded = sync.sendOperation(applied.op);
      expect(forwarded.queued, isTrue);
      expect(forwarded.sent, isFalse);

      expect(
        () => crdt.applyLocal(
          'missing-m1-doc',
          const <String, dynamic>{'key': 'k', 'value': 1},
        ),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'NotFound')),
      );
    }, skip: available ? false : 'wb_core.dll 不存在，跳过 sync/crdt 原生回归');

    test('crdt create 空 docId 自动生成 / applyLocal 缺 key', () {
      final WbCrdtService crdt =
          WbCrdtService(WbCoreFfi.load(overridePath: dllPath));
      final WbCrdtCreateData auto = crdt.create('');
      expect(auto.docId, startsWith('crdt-'));
      expect(auto.actor, 'local');

      expect(
        () => crdt.applyLocal(auto.docId, const <String, dynamic>{}),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'InvalidArgument')),
      );
    }, skip: available ? false : 'wb_core.dll 不存在，跳过 sync/crdt 原生回归');
  });
}

/// 在构建产物目录中寻找 wb_core.dll（找不到返回空串，触发测试跳过）。
String _findWbCoreDll() {
  if (!Platform.isWindows) {
    return '';
  }
  const List<String> candidates = <String>[
    r'e:\code\whiteboard\build\windows-x64\bin\Release\wb_core.dll',
    r'e:\code\whiteboard\build\windows-x64\bin\Debug\wb_core.dll',
  ];
  for (final String path in candidates) {
    if (File(path).existsSync()) {
      return path;
    }
  }
  return '';
}
