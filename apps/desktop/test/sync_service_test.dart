/// T1.6 协同服务单元测试：生命周期 / 状态映射 / 出口 op 生成 /
/// 入口 ops 应用 / 防回发（fake 引擎，不依赖 DLL 与网络）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_desktop/services/board_file_codec.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';

import 'support/fake_collab_engine.dart';

/// 服务 + fake 引擎 + 手动定时器装配。
class _Harness {
  _Harness({String? endpoint}) {
    service = WbCollabService(
      engine: engine,
      endpoint: endpoint,
      sleep: (Duration _) async {},
      pollTimerFactory: timers.create,
      actorGenerator: () => 'wb-test-actor',
      clock: () => DateTime(2026, 9, 30, 12),
    );
  }

  final FakeCollabEngine engine = FakeCollabEngine();
  final FakePollTimerFactory timers = FakePollTimerFactory();
  late final WbCollabService service;
}

/// 构造测试元素（note 类型）。
WbCanvasElement _note(String id, {double width = 120, double height = 80}) =>
    WbCanvasElement(
      id: id,
      type: WbElementKind.note,
      x: 10,
      y: 20,
      width: width,
      height: height,
    );

/// 构造 `el:{id}:data` 远端 op。
Map<String, dynamic> _dataOp(WbCanvasElement element) => <String, dynamic>{
      'key': 'el:${element.id}:data',
      'value': WbBoardFileCodec.encodeElement(element),
    };

void main() {
  late _Harness h;

  setUp(() {
    h = _Harness();
    addTearDown(h.service.dispose);
  });

  // ---- 生命周期 -----------------------------------------------------------

  group('WbCollabService 生命周期', () {
    test('start 建链：connect → 等就绪 → create(docId=boardId) → join → 轮询',
        () async {
      final bool ok = await h.service.start(boardId: 'b1');

      expect(ok, isTrue);
      // 首项 disconnect 来自 start → stop 的幂等清理。
      expect(h.engine.calls, <String>[
        'disconnect',
        'connect',
        'status',
        'create',
        'join',
        'status',
      ]);
      expect(h.engine.connectedEndpoints, <String>[
        WbCollabService.defaultEndpoint,
      ]);
      expect(h.engine.createdDocs, <String>['b1']);
      expect(h.engine.lastCreateActor, 'wb-test-actor');
      expect(h.engine.joinedBoards, <String>['b1']);
      expect(h.timers.interval, const Duration(milliseconds: 50));
      expect(h.timers.lastTimer, isNotNull);
      expect(h.service.boardId, 'b1');
      expect(h.service.sessionActor, 'wb-test-actor');
      expect(h.service.status, WbSyncStatus.online);
    });

    test('start 注入 endpoint 生效；空串回落默认端点', () async {
      final _Harness custom = _Harness(endpoint: 'http://10.0.0.8:9000');
      addTearDown(custom.service.dispose);
      await custom.service.start(boardId: 'b1');
      expect(custom.engine.connectedEndpoints.single, 'http://10.0.0.8:9000');
      expect(custom.service.endpoint, 'http://10.0.0.8:9000');

      final _Harness blank = _Harness(endpoint: '   ');
      addTearDown(blank.service.dispose);
      expect(blank.service.endpoint, WbCollabService.defaultEndpoint);
    });

    test('start 容忍 create Conflict（文档已存在，重复进入白板）', () async {
      h.engine.createError = const WbCoreException('Conflict', 'doc exists');
      final bool ok = await h.service.start(boardId: 'b1');

      expect(ok, isTrue);
      expect(h.service.boardId, 'b1');
      expect(h.service.status, WbSyncStatus.online);
      expect(h.engine.joinedBoards, <String>['b1']);
    });

    test('connect() 容忍已连接 Conflict（设置页重连）', () async {
      h.engine.connected = true;
      h.engine.transportState = 'connected';
      h.engine.connectError =
          const WbCoreException('Conflict', 'already connected');

      await h.service.connect('http://127.0.0.1:8791');

      expect(h.service.status, WbSyncStatus.online);
      expect(h.service.endpoint, 'http://127.0.0.1:8791');
    });

    test('start 失败：传输 failed → error + false', () async {
      h.engine.statusOverride =
          const WbSyncStatusData(transportState: 'failed');

      final bool ok = await h.service.start(boardId: 'b1');

      expect(ok, isFalse);
      expect(h.service.status, WbSyncStatus.error);
      expect(h.service.boardId, isNull);
      expect(h.service.lastError, contains('协作服务连接失败'));
    });

    test('start 失败：连接未就绪超时 → error + false', () async {
      h.engine.statusOverride =
          const WbSyncStatusData(transportState: 'connecting');

      final bool ok = await h.service.start(boardId: 'b1');

      expect(ok, isFalse);
      expect(h.service.status, WbSyncStatus.error);
      expect(h.service.lastError, contains('超时'));
    });

    test('start 失败：create 非 Conflict 错 → error + boardId 清空', () async {
      h.engine.createError = const WbCoreException('BadState', 'boom');

      final bool ok = await h.service.start(boardId: 'b1');

      expect(ok, isFalse);
      expect(h.service.status, WbSyncStatus.error);
      expect(h.service.boardId, isNull);
      expect(h.service.sessionActor, '');
      expect(h.service.lastError, contains('BadState'));
    });

    test('start 失败：join 被拒 → error + false', () async {
      h.engine.joinAccepted = false;

      final bool ok = await h.service.start(boardId: 'b1');

      expect(ok, isFalse);
      expect(h.service.status, WbSyncStatus.error);
      expect(h.service.lastError, contains('加入房间失败'));
    });

    test('start 无引擎（演示模式）：安全降级 false，不抛', () async {
      final WbCollabService bare = WbCollabService();
      addTearDown(bare.dispose);

      final bool ok = await bare.start(boardId: 'b1');

      expect(ok, isFalse);
      expect(bare.status, WbSyncStatus.offline);
    });

    test('start 空 boardId：不建链（无 connect）', () async {
      final bool ok = await h.service.start(boardId: '');

      expect(ok, isFalse);
      expect(h.engine.connectedEndpoints, isEmpty);
      expect(h.engine.createdDocs, isEmpty);
    });

    test('stop：停轮询 + disconnect + 清会话状态', () async {
      await h.service.start(boardId: 'b1');
      final FakePollTimer timer = h.timers.lastTimer!;

      await h.service.stop();

      expect(timer.cancelled, isTrue);
      expect(h.engine.disconnectCount, 2); // start 前清理 1 次 + stop 1 次
      expect(h.service.boardId, isNull);
      expect(h.service.sessionActor, '');
      expect(h.service.status, WbSyncStatus.offline);
      expect(h.service.pendingCount, 0);
      expect(h.service.lastStatus.connected, isFalse);
    });

    test('stop 幂等 / 无引擎安全', () async {
      final WbCollabService bare = WbCollabService();
      addTearDown(bare.dispose);

      await bare.stop();
      await bare.stop();

      expect(bare.status, WbSyncStatus.offline);
    });

    test('重复 start：旧会话先停（旧轮询取消，新轮询接管）', () async {
      await h.service.start(boardId: 'b1');
      final FakePollTimer first = h.timers.lastTimer!;

      await h.service.start(boardId: 'b2');

      expect(first.cancelled, isTrue);
      expect(h.timers.created, 2);
      expect(h.service.boardId, 'b2');
      expect(h.engine.createdDocs, <String>['b1', 'b2']);
      expect(h.engine.disconnectCount, 2);
    });

    test('会话 actor：默认随机 uuid 格式（wb- 前缀）', () async {
      final FakeCollabEngine engine = FakeCollabEngine();
      final FakePollTimerFactory timers = FakePollTimerFactory();
      final WbCollabService service = WbCollabService(
        engine: engine,
        sleep: (Duration _) async {},
        pollTimerFactory: timers.create,
      );
      addTearDown(service.dispose);

      await service.start(boardId: 'b1');

      expect(service.sessionActor, startsWith('wb-'));
      expect(service.sessionActor.length, greaterThan(30));
      expect(engine.lastCreateActor, service.sessionActor);
    });
  });

  // ---- 状态映射（轮询驱动） -----------------------------------------------

  group('WbCollabService 状态映射', () {
    test('轮询：reconnecting → connecting；恢复 → online', () async {
      await h.service.start(boardId: 'b1');
      expect(h.service.status, WbSyncStatus.online);

      h.engine.connected = false;
      h.engine.transportState = 'reconnecting';
      h.timers.fire();
      expect(h.service.status, WbSyncStatus.connecting);
      expect(h.service.isOnline, isFalse);

      h.engine.connected = true;
      h.engine.transportState = 'connected';
      h.timers.fire();
      expect(h.service.status, WbSyncStatus.online);
      expect(h.service.isOnline, isTrue);
    });

    test('轮询：pendingCount>0 → syncing（离线积压）', () async {
      await h.service.start(boardId: 'b1');

      h.engine.pendingCount = 3;
      h.timers.fire();

      expect(h.service.status, WbSyncStatus.syncing);
      expect(h.service.pendingCount, 3);
      expect(h.service.isOnline, isTrue); // syncing 属在线域
    });

    test('轮询：disconnected → offline', () async {
      await h.service.start(boardId: 'b1');

      h.engine.connected = false;
      h.engine.transportState = 'disconnected';
      h.timers.fire();

      expect(h.service.status, WbSyncStatus.offline);
    });

    test('轮询：previews 透传记录（M1 不渲染）', () async {
      final List<List<Map<String, dynamic>>> received =
          <List<Map<String, dynamic>>>[];
      h.service.onRemotePreviews = received.add;
      await h.service.start(boardId: 'b1');

      h.engine.nextPreviews = <Map<String, dynamic>>[
        <String, dynamic>{'kind': 'transform', 'id': 'e1'},
        <String, dynamic>{'kind': 'ink', 'id': 'e1'},
      ];
      h.timers.fire();

      expect(h.service.lastPreviewCount, 2);
      expect(received.single.length, 2);
      expect(received.single.first['kind'], 'transform');
    });
  });

  // ---- 画布出口 -----------------------------------------------------------

  group('WbCollabService 画布出口', () {
    test('upsert → el:{id}:data（value=契约 JSON）+ actor/seq', () async {
      await h.service.start(boardId: 'b1');
      final WbCanvasElement element = _note('e9');

      h.service.handleCanvasCommit(
        WbCanvasCommitBatch(upserts: <WbCanvasElement>[element]),
      );

      expect(h.engine.sentOps.length, 1);
      final Map<String, dynamic> op = h.engine.sentOps.single;
      expect(op['key'], 'el:e9:data');
      expect(op['value'], WbBoardFileCodec.encodeElement(element));
      expect(op['actor'], 'fake-actor');
      expect(op['seq'], 1);
      expect(op['origin'], 'local');
    });

    test('删除 → el:{id}:exists=false', () async {
      await h.service.start(boardId: 'b1');

      h.service.handleCanvasCommit(
        const WbCanvasCommitBatch(removedIds: <String>['e8']),
      );

      expect(h.engine.sentOps.single['key'], 'el:e8:exists');
      expect(h.engine.sentOps.single['value'], isFalse);
    });

    test('upsert 携 pageId → value 内嵌 pageId（服务端保留 value 原样）',
        () async {
      await h.service.start(boardId: 'b1');

      h.service.handleCanvasCommit(WbCanvasCommitBatch(
        pageId: 'page-2',
        upserts: <WbCanvasElement>[_note('e9')],
      ));

      final Map<String, dynamic> op = h.engine.sentOps.single;
      expect(op['key'], 'el:e9:data');
      expect((op['value'] as Map)['pageId'], 'page-2');
    });

    test('页结构出口：handlePageOp → pg:{id}:{field}', () async {
      await h.service.start(boardId: 'b1');

      h.service.handlePageOp(
        'page-2',
        'create',
        <String, dynamic>{'name': '页面 2'},
      );
      h.service.handlePageOp('page-2', 'rename', '第二页');
      h.service.handlePageOp('page-2', 'move', 0);
      h.service.handlePageOp('page-2', 'delete', true);

      expect(
        h.engine.sentOps
            .map((Map<String, dynamic> o) => o['key'])
            .toList(),
        <String>[
          'pg:page-2:create',
          'pg:page-2:rename',
          'pg:page-2:move',
          'pg:page-2:delete',
        ],
      );
      expect(h.engine.sentOps.last['value'], isTrue);
    });

    test('页结构出口：未 start / 空参数静默跳过', () {
      h.service.handlePageOp('page-2', 'create', null);
      expect(h.engine.sentOps, isEmpty);

      h.service.handlePageOp('', 'create', true);
      h.service.handlePageOp('page-2', '', true);
      expect(h.engine.sentOps, isEmpty);
    });

    test('大批次：seq 递增 / 顺序 = upserts + removed', () async {
      await h.service.start(boardId: 'b1');

      h.service.handleCanvasCommit(WbCanvasCommitBatch(
        upserts: <WbCanvasElement>[_note('e1'), _note('e2')],
        removedIds: <String>['e3'],
      ));

      expect(h.engine.sentOps.length, 3);
      expect(
        h.engine.sentOps.map((Map<String, dynamic> o) => o['seq']).toList(),
        <int>[1, 2, 3],
      );
      expect(h.engine.sentOps[0]['key'], 'el:e1:data');
      expect(h.engine.sentOps[1]['key'], 'el:e2:data');
      expect(h.engine.sentOps[2]['key'], 'el:e3:exists');
    });

    test('离线积压（queued）→ syncing', () async {
      await h.service.start(boardId: 'b1');
      h.engine.sendQueued = true;

      h.service.handleCanvasCommit(
        WbCanvasCommitBatch(upserts: <WbCanvasElement>[_note('e9')]),
      );

      expect(h.service.status, WbSyncStatus.syncing);
    });

    test('未 start：静默跳过（不发送）', () {
      h.service.handleCanvasCommit(
        WbCanvasCommitBatch(upserts: <WbCanvasElement>[_note('e9')]),
      );

      expect(h.engine.sentOps, isEmpty);
    });

    test('空批次 / 空 id：跳过', () async {
      await h.service.start(boardId: 'b1');

      h.service.handleCanvasCommit(const WbCanvasCommitBatch());
      h.service.handleCanvasCommit(
        WbCanvasCommitBatch(
          upserts: <WbCanvasElement>[_note('')],
          removedIds: <String>[''],
        ),
      );

      expect(h.engine.sentOps, isEmpty);
    });

    test('applyLocal 抛错：记录 lastError，不抛 / 不发送', () async {
      await h.service.start(boardId: 'b1');
      h.engine.applyLocalError = StateError('crdt down');

      h.service.handleCanvasCommit(
        WbCanvasCommitBatch(upserts: <WbCanvasElement>[_note('e9')]),
      );

      expect(h.service.lastError, contains('crdt down'));
      expect(h.engine.sentOps, isEmpty);
    });

    test('applyLocal 空 op（未变更）：不发送', () async {
      await h.service.start(boardId: 'b1');
      h.engine.applyLocalEmptyOp = true;

      h.service.handleCanvasCommit(
        WbCanvasCommitBatch(upserts: <WbCanvasElement>[_note('e9')]),
      );

      expect(h.engine.sentOps, isEmpty);
    });

    test('无引擎：静默跳过', () async {
      final WbCollabService bare = WbCollabService();
      addTearDown(bare.dispose);

      bare.handleCanvasCommit(
        WbCanvasCommitBatch(upserts: <WbCanvasElement>[_note('e9')]),
      );

      expect(bare.lastError, isEmpty);
    });
  });

  // ---- 画布入口（轮询应用） -----------------------------------------------

  group('WbCollabService 画布入口', () {
    test('data op → onRemoteElement + lastSyncedAt + 状态维持', () async {
      final List<WbCanvasElement> received = <WbCanvasElement>[];
      h.service.onRemoteElement =
          (WbCanvasElement element, {String? pageId}) => received.add(element);
      await h.service.start(boardId: 'b1');

      h.engine.nextOps = <Map<String, dynamic>>[_dataOp(_note('r1'))];
      h.timers.fire();

      expect(received.single.id, 'r1');
      expect(h.service.lastSyncedAt, isNotNull);
      expect(h.service.status, WbSyncStatus.online);
    });

    test('data op 携 pageId → 回调透出目标页', () async {
      final List<String> pageIds = <String>[];
      h.service.onRemoteElement =
          (WbCanvasElement element, {String? pageId}) =>
              pageIds.add(pageId ?? '');
      await h.service.start(boardId: 'b1');

      final Map<String, dynamic> value =
          WbBoardFileCodec.encodeElement(_note('r1'));
      value['pageId'] = 'page-3';
      h.engine.nextOps = <Map<String, dynamic>>[
        <String, dynamic>{'key': 'el:r1:data', 'value': value},
      ];
      h.timers.fire();

      expect(pageIds, <String>['page-3']);
    });

    test('pg: op → onRemotePageOp；同批先于元素 op 应用', () async {
      final List<String> order = <String>[];
      h.service.onRemotePageOp =
          (String pageId, String field, Object? value) =>
              order.add('pg:$pageId:$field');
      h.service.onRemoteElement =
          (WbCanvasElement element, {String? pageId}) =>
              order.add('el:${element.id}');
      await h.service.start(boardId: 'b1');

      final Map<String, dynamic> elementValue =
          WbBoardFileCodec.encodeElement(_note('r1'));
      elementValue['pageId'] = 'page-2';
      h.engine.nextOps = <Map<String, dynamic>>[
        <String, dynamic>{'key': 'el:r1:data', 'value': elementValue},
        <String, dynamic>{
          'key': 'pg:page-2:create',
          'value': <String, dynamic>{'name': '页面 2'},
        },
      ];
      h.timers.fire();

      // 同批内 pg 先于 el（目标页先落地），与 op 到达顺序无关。
      expect(order, <String>['pg:page-2:create', 'el:r1']);
    });

    test('pg 坏键 / 未知字段：不中断，好 op 照常应用', () async {
      final List<String> applied = <String>[];
      h.service.onRemotePageOp =
          (String pageId, String field, Object? value) =>
              applied.add('$pageId:$field');
      h.service.onRemoteElement =
          (WbCanvasElement element, {String? pageId}) =>
              applied.add(element.id);
      await h.service.start(boardId: 'b1');

      h.engine.nextOps = <Map<String, dynamic>>[
        <String, dynamic>{'key': 'pg:page-1', 'value': true}, // 缺 field
        <String, dynamic>{'key': 'pg::create', 'value': true}, // 空页 id
        <String, dynamic>{
          'key': 'pg:page-1:settings',
          'value': 1,
        }, // 未知字段：透传给页面状态（状态侧忽略）
        _dataOp(_note('r1')), // 好 op：照常应用
      ];
      h.timers.fire();

      expect(applied, <String>['page-1:settings', 'r1']);
    });

    test('exists=false → onRemoteRemove', () async {
      final List<String> removed = <String>[];
      h.service.onRemoteRemove = removed.add;
      await h.service.start(boardId: 'b1');

      h.engine.nextOps = <Map<String, dynamic>>[
        <String, dynamic>{'key': 'el:r1:exists', 'value': false},
      ];
      h.timers.fire();

      expect(removed, <String>['r1']);
      expect(h.service.lastSyncedAt, isNotNull);
    });

    test('同批多条：upsert 各自回调 + 删除收集', () async {
      final List<WbCanvasElement> received = <WbCanvasElement>[];
      final List<String> removed = <String>[];
      h.service.onRemoteElement =
          (WbCanvasElement element, {String? pageId}) => received.add(element);
      h.service.onRemoteRemove = removed.add;
      await h.service.start(boardId: 'b1');

      h.engine.nextOps = <Map<String, dynamic>>[
        _dataOp(_note('r1')),
        _dataOp(_note('r2')),
        <String, dynamic>{'key': 'el:r3:exists', 'value': false},
      ];
      h.timers.fire();

      expect(received.map((WbCanvasElement e) => e.id).toList(), <String>[
        'r1',
        'r2',
      ]);
      expect(removed, <String>['r3']);
    });

    test('防回发：应用窗口内 isApplyingRemote=true，窗口内出口跳过', () async {
      await h.service.start(boardId: 'b1');
      bool? insideFlag;
      h.service.onRemoteElement = (WbCanvasElement element, {String? pageId}) {
        insideFlag = h.service.isApplyingRemote;
        // 窗口内画布出口（模拟回调链中触发的本地提交）：应被跳过。
        h.service.handleCanvasCommit(
          WbCanvasCommitBatch(upserts: <WbCanvasElement>[element]),
        );
      };

      h.engine.nextOps = <Map<String, dynamic>>[_dataOp(_note('r1'))];
      h.timers.fire();

      expect(insideFlag, isTrue);
      expect(h.service.isApplyingRemote, isFalse); // 窗口已关闭
      expect(h.engine.sentOps, isEmpty); // 未回发
    });

    test('坏载荷 / 未知键 / 字段级 op（M1 忽略）不中断，好 op 照常应用',
        () async {
      final List<WbCanvasElement> received = <WbCanvasElement>[];
      final List<String> removed = <String>[];
      h.service.onRemoteElement =
          (WbCanvasElement element, {String? pageId}) => received.add(element);
      h.service.onRemoteRemove = removed.add;
      await h.service.start(boardId: 'b1');

      h.engine.nextOps = <Map<String, dynamic>>[
        <String, dynamic>{'key': 'lock:e1', 'value': 1}, // 非元素键
        <String, dynamic>{'key': 'el:e1', 'value': <String, dynamic>{}}, // 缺 field
        <String, dynamic>{'key': 'el:e1:data', 'value': 'not-a-map'}, // 坏载荷
        <String, dynamic>{'key': 'el:e1:field', 'value': 42}, // M2 字段级
        <String, dynamic>{'key': 'el:e1:exists', 'value': true}, // 非删除
        _dataOp(_note('r2')), // 好 op：照常应用
      ];
      h.timers.fire();

      expect(received.single.id, 'r2');
      expect(removed, isEmpty);
      expect(h.service.lastSyncedAt, isNotNull);
    });

    test('data op 元素 id 为空：忽略', () async {
      final List<WbCanvasElement> received = <WbCanvasElement>[];
      h.service.onRemoteElement =
          (WbCanvasElement element, {String? pageId}) => received.add(element);
      await h.service.start(boardId: 'b1');

      h.engine.nextOps = <Map<String, dynamic>>[
        <String, dynamic>{
          'key': 'el:x:data',
          'value': <String, dynamic>{
            'id': '',
            'type': 'note',
            'x': 0,
            'y': 0,
            'width': 10,
            'height': 10,
          },
        },
      ];
      h.timers.fire();

      expect(received, isEmpty);
    });

    test('轮询单次失败（status 抛错）：不中断、不降级', () async {
      await h.service.start(boardId: 'b1');

      h.engine.statusThrows = true;
      h.timers.fire(); // events() 内 status() 抛错 → 被 catch

      expect(h.service.status, WbSyncStatus.online); // 维持
    });
  });

  // ---- 其它控制面 ---------------------------------------------------------

  group('WbCollabService 控制面', () {
    test('reportError → error + lastError', () {
      h.service.reportError('链路异常');

      expect(h.service.status, WbSyncStatus.error);
      expect(h.service.lastError, '链路异常');
    });

    test('syncNow：flush 冲刷 + lastSyncedAt 更新', () async {
      await h.service.start(boardId: 'b1');
      h.engine.pendingCount = 2;

      await h.service.syncNow();

      expect(h.engine.calls, contains('flush'));
      expect(h.service.lastSyncedAt, isNotNull);
    });

    test('syncNow 离线：安全空转', () async {
      await h.service.syncNow();

      expect(h.engine.calls, isNot(contains('flush')));
    });
  });

  // ---- 房间参与者（T1.7 UI 读取面） ---------------------------------------

  group('WbCollabService 房间参与者', () {
    test('轮询缓存 room：解析 + 末位标记本人 + int 计数契约不变', () async {
      await h.service.start(boardId: 'b1');
      expect(h.service.participantList, isEmpty);

      h.engine.room = const WbSyncRoomData(
        participants: <dynamic>[
          <String, dynamic>{'userId': 'peer-01', 'role': 'Host'},
          <String, dynamic>{'userId': 'me-02', 'role': 'Participant'},
        ],
        mode: 'free',
      );
      h.timers.fire();

      final List<WbCollabParticipant> list = h.service.participantList;
      expect(list.length, 2);
      expect(list[0].id, 'peer-01');
      expect(list[0].role, 'Host');
      expect(list[0].isSelf, isFalse);
      expect(list[1].id, 'me-02');
      expect(list[1].role, 'Participant');
      expect(list[1].isSelf, isTrue); // M1 末位推断
      expect(h.service.participants, 0); // 既有 int 计数契约（status 快照）
    });

    test('字符串形状载荷：原样为 id、角色为空、末位本人', () async {
      await h.service.start(boardId: 'b1');

      h.engine.room = const WbSyncRoomData(
        participants: <dynamic>['raw-peer', 'me-raw'],
      );
      h.timers.fire();

      final List<WbCollabParticipant> list = h.service.participantList;
      expect(
        list.map((WbCollabParticipant p) => p.id).toList(),
        <String>['raw-peer', 'me-raw'],
      );
      expect(list.every((WbCollabParticipant p) => p.role.isEmpty), isTrue);
      expect(list.last.isSelf, isTrue);
    });

    test('防御解析：缺 id / 非法元素忽略；非 String role → 空串', () async {
      await h.service.start(boardId: 'b1');

      h.engine.room = const WbSyncRoomData(
        participants: <dynamic>[
          <String, dynamic>{'role': 'Host'}, // 缺 id：忽略
          42, // 非 Map / 非 String：忽略
          '', // 空串：忽略
          <String, dynamic>{'userId': 'ok-1', 'role': 7}, // role 非法
        ],
      );
      h.timers.fire();

      final List<WbCollabParticipant> list = h.service.participantList;
      expect(list.length, 1);
      expect(list.single.id, 'ok-1');
      expect(list.single.role, isEmpty);
      expect(list.single.isSelf, isTrue);
    });

    test('room 变化触发通知；同一快照不重复通知', () async {
      await h.service.start(boardId: 'b1');
      int notified = 0;
      void listener() => notified++;
      h.service.addListener(listener);
      addTearDown(() => h.service.removeListener(listener));

      h.engine.room = const WbSyncRoomData(
        participants: <dynamic>[<String, dynamic>{'userId': 'a'}],
      );
      h.timers.fire();
      expect(notified, 1);

      h.timers.fire(); // 同一快照：不通知
      expect(notified, 1);

      h.engine.room = const WbSyncRoomData(
        participants: <dynamic>[
          <String, dynamic>{'userId': 'a'},
          <String, dynamic>{'userId': 'b'},
        ],
      );
      h.timers.fire();
      expect(notified, 2);
    });

    test('stop：清空房间参与者', () async {
      await h.service.start(boardId: 'b1');
      h.engine.room = const WbSyncRoomData(
        participants: <dynamic>[<String, dynamic>{'userId': 'a'}],
      );
      h.timers.fire();
      expect(h.service.participantList, hasLength(1));

      await h.service.stop();

      expect(h.service.participantList, isEmpty);
    });

    test('selfUserId 精确匹配：非末位标记本人，末位不再推断', () async {
      await h.service.start(boardId: 'b1');

      h.engine.room = const WbSyncRoomData(
        participants: <dynamic>[
          <String, dynamic>{'userId': 'me-01', 'role': 'Participant'},
          <String, dynamic>{'userId': 'peer-02', 'role': 'Host'},
        ],
        selfUserId: 'me-01',
      );
      h.timers.fire();

      final List<WbCollabParticipant> list = h.service.participantList;
      expect(list.length, 2);
      expect(list[0].id, 'me-01');
      expect(list[0].isSelf, isTrue); // 首位 = 本人（服务端身份精确匹配）
      expect(list[1].id, 'peer-02');
      expect(list[1].isSelf, isFalse); // 身份已知：末位不再推断
    });

    test('selfUserId 有值但名单缺失：不回退末位推断（无人标记）', () async {
      await h.service.start(boardId: 'b1');

      h.engine.room = const WbSyncRoomData(
        participants: <dynamic>[
          <String, dynamic>{'userId': 'peer-01'},
          <String, dynamic>{'userId': 'peer-02'},
        ],
        selfUserId: 'gone-me',
      );
      h.timers.fire();

      final List<WbCollabParticipant> list = h.service.participantList;
      expect(list.length, 2);
      expect(list.every((WbCollabParticipant p) => !p.isSelf), isTrue);
    });

    test('selfUserId 变化触发通知（身份参与快照去重比较）', () async {
      await h.service.start(boardId: 'b1');
      int notified = 0;
      void listener() => notified++;
      h.service.addListener(listener);
      addTearDown(() => h.service.removeListener(listener));

      h.engine.room = const WbSyncRoomData(
        participants: <dynamic>[<String, dynamic>{'userId': 'me-01'}],
        selfUserId: 'me-01',
      );
      h.timers.fire();
      expect(notified, 1);
      expect(h.service.participantList.single.isSelf, isTrue);

      h.engine.room = const WbSyncRoomData(
        participants: <dynamic>[<String, dynamic>{'userId': 'me-01'}],
        selfUserId: 'me-01-b',
      );
      h.timers.fire();
      expect(notified, 2); // 仅身份变化：仍通知（「我」标记随刷新）
    });

    test('未 start / 无引擎：空列表安全', () {
      expect(h.service.participantList, isEmpty);

      final WbCollabService bare = WbCollabService();
      addTearDown(bare.dispose);
      expect(bare.participantList, isEmpty);
    });
  });
}
