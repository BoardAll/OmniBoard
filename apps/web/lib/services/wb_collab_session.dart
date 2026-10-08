/// Web 页面级协作会话（P4）：画布提交 ⇄ CRDT ⇄ realtime 全链路协调。
///
/// 链路（对齐桌面 `WbSyncService` 语义，传输改为 realtime `board:ops`）：
/// - 本地出口：[handleLocalCommit] 把落定提交（与撤销栈同批）转为 op——
///   `el:{id}:data`（value = 元素契约 JSON，内嵌 `pageId` 供接收端按页
///   路由）/ 删除 `el:{id}:exists=false`——经 `crdt.applyLocal`（tool 域
///   点分路由；WASM 未导出 `wb_crdt_*`，不走 FFI 直调）补齐
///   actor/seq/timestamp 后 `board:ops` 直发，ack `missingSeqs` 从有界
///   缓存补发一次；
/// - 页结构出口：[handlePageOp] 把本地页新建 / 删除 / 重命名 / 排序转为
///   `pg:{pageId}:{field}`（value 语义见 [WbPageState.onPageOp]；同一
///   board:ops 可靠通道，op log 回放供迟到入房者重建页结构）；
/// - 远端入口：[handleRemoteOps] 逐条 `crdt.applyRemote`（NotFound →
///   惰性 `crdt.create` 重试）→ 水印推进 → `applied==true` 才路由画布
///   （key 前缀路由：`el:*:data` → 解码 → onRemoteElement；`el:*:exists`
///   = false → onRemoteRemove；`pg:*` → onRemotePageOp）；
/// - 快照恢复：[handleJoined] 收到 `joined.snapshot` 且本端 doc 不存在
///   （`crdt.encodeState` 探测 NotFound）→ `crdt.create` +
///   `crdt.decodeState(payload)` + 水印 = snapshot.stateVector，再解析
///   state 内的 `el:*` 键回放画布（补齐桌面缺口：drain 只下发
///   applied=true 的 op，快照内 key 的重放因 LWW 平局不上画布）；
/// - 初始自举推送：[handleJoined] 在「自举 Host + 服务端空房间
///   （stateVector 空）+ 本会话首建文档（探测 NotFound）」时经
///   [initialContentProvider] 收集本地内容一次性上行（补齐「先画后
///   进房」的初始同步缺口；重入 / 非首个加入者跳过，交由 replay /
///   快照收敛）；
/// - checkpoint：`board:checkpointRequest` → `crdt.encodeState` →
///   `board:checkpoint {stateVector: 水印, payload: state}`。
///
/// 并发口径：WASM 引擎调用同步（ccall），所有状态变更在事件回调内同步
/// 完成，天然保序（joined 先于 replay 帧到达）；仅网络发送异步（unawaited）。
/// [isApplyingRemote] 供画布出口防回发（远端应用期间跳过本地提交外发）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:whiteboard_canvas/canvas/canvas_controller.dart';
import 'package:whiteboard_canvas/canvas/canvas_model.dart';
import 'package:whiteboard_canvas/services/board_file_codec.dart';
import 'package:whiteboard_core/wb_core_common.dart';

import 'realtime_service.dart';
// 条件导入（Web → 实实现；VM / 分析 → 桩）：WbWebEngine 类型在两目标
// 下一致，避免与调用方（经同一条件导入）的类型不匹配。
import 'wb_core_engine.dart';

/// 页面级协作会话：注册到 [WbRealtimeService]，把画布提交与远端 op 经
/// crdt 域（`WbWebEngine.tools`）双向搬运。
///
/// 用法（编辑页）：
/// ```dart
/// _collab = WbCollabSession(engine: engine, realtime: rt, boardId: room)
///   ..onRemoteElement = ...   // 画布入口装配
///   ..start();                // 必须先于 joinBoard（join 载荷取水印）
/// unawaited(rt.joinBoard(room));
/// // 退出：_collab.dispose();
/// ```
class WbCollabSession {
  /// 创建会话（应用路径：从引擎聚合取工具域服务）。
  ///
  /// [docId] 取 [boardId]（与桌面同口径：一板一 CRDT 文档）；
  /// [actor] 缺省生成本会话随机 actor（Web 会话全新，不与历史
  /// (actor, seq) 冲突）。
  WbCollabSession({
    required WbWebEngine engine,
    required WbRealtimeService realtime,
    required String boardId,
    String? actor,
  }) : this.withTools(
          tools: engine.tools,
          realtime: realtime,
          boardId: boardId,
          actor: actor,
        );

  /// 工具域直连构造（测试 / 高级装配：注入 [WbToolService]）。
  WbCollabSession.withTools({
    required WbToolService tools,
    required WbRealtimeService realtime,
    required String boardId,
    String? actor,
  })  : _tools = tools,
        _realtime = realtime,
        _boardId = boardId,
        _actor = actor == null || actor.isEmpty ? _generateActor() : actor {
    _joinedHandler = _handleJoinedCallback;
    _opsHandler = _handleOpsCallback;
    _watermarksProvider = _watermarksSnapshot;
    _checkpointHandler = _handleCheckpointRequest;
  }

  final WbToolService _tools;
  final WbRealtimeService _realtime;
  final String _boardId;
  final String _actor;

  late final void Function(Map<String, Object?> payload) _joinedHandler;
  late final void Function(List<Object?> ops, {bool replay}) _opsHandler;
  late final Map<String, Object?> Function() _watermarksProvider;
  late final void Function() _checkpointHandler;

  /// 远端元素 upsert（含来源页 id；画布按页路由写入）。
  void Function(WbCanvasElement element, {String? pageId})? onRemoteElement;

  /// 远端元素删除（画布按元素 id 跨页查找删除）。
  void Function(String elementId)? onRemoteRemove;

  /// 远端页结构 op（create / delete / rename / move；页面域应用）。
  void Function(String pageId, String field, Object? value)? onRemotePageOp;

  /// 初始全量内容提供者（首个加入者自举推送用；页面装配时注入）。
  ///
  /// 返回本地各页的提交批（空页不产批；画布未就绪时返回空列表）；
  /// 仅在自举条件满足时调用一次。
  List<WbCanvasCommitBatch> Function()? initialContentProvider;

  /// 版本水位（actor → 最大连续 seq；join / checkpoint 上报）。
  final Map<String, Object?> _watermarks = <String, Object?>{};

  /// 本地已发 op 有界缓存（key `actor:seq`；`missingSeqs` 补发来源）。
  final Map<String, Object?> _sentBySeq = <String, Object?>{};

  /// 缓存上限（超出淘汰最旧；服务端缺口为瞬态，无需长缓存）。
  static const int _maxSentCacheEntries = 256;

  bool _docCreated = false;
  bool _applyingRemote = false;
  bool _disposed = false;
  bool _initialPushDone = false;
  String? _lastError;

  /// 是否正在应用远端变更（画布提交出口据此跳过外发，防回发）。
  bool get isApplyingRemote => _applyingRemote;

  /// 最近一次引擎 / 链路错误（诊断用；null = 无）。
  String? get lastError => _lastError;

  /// 当前版本水位（不可变快照）。
  Map<String, Object?> get watermarks =>
      Map<String, Object?>.unmodifiable(_watermarks);

  /// 装配 realtime 回调（[WbRealtimeService.joinBoard] 之前调用，
  /// 避免 join 载荷取水印时提供者尚未就绪）。
  void start() {
    _realtime.onBoardJoined = _joinedHandler;
    _realtime.onRemoteOps = _opsHandler;
    _realtime.lastSeenVersionProvider = _watermarksProvider;
    _realtime.onCheckpointRequest = _checkpointHandler;
  }

  /// 解除装配并清理状态（幂等；仅回收仍指向本会话的回调）。
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final WbRealtimeService rt = _realtime;
    if (identical(rt.onBoardJoined, _joinedHandler)) {
      rt.onBoardJoined = null;
    }
    if (identical(rt.onRemoteOps, _opsHandler)) {
      rt.onRemoteOps = null;
    }
    if (identical(rt.lastSeenVersionProvider, _watermarksProvider)) {
      rt.lastSeenVersionProvider = null;
    }
    if (identical(rt.onCheckpointRequest, _checkpointHandler)) {
      rt.onCheckpointRequest = null;
    }
    _sentBySeq.clear();
    _watermarks.clear();
  }

  // ---------------------------------------------------------------------------
  // 本地出口（画布 → op → board:ops）
  // ---------------------------------------------------------------------------

  /// 本地落定提交出口（与撤销栈同批）：upserts → `el:{id}:data`
  /// （value 内嵌 pageId）、removedIds → `el:{id}:exists=false`。
  ///
  /// 远端应用期间（[isApplyingRemote]）静默跳过（防回发；画布已由
  /// `isRemoteApplying` 谓词收窄，此处兜底）。
  void handleLocalCommit(WbCanvasCommitBatch batch) {
    if (_disposed || batch.isEmpty || _applyingRemote) {
      return;
    }
    for (final WbCanvasElement element in batch.upserts) {
      if (element.id.isEmpty) {
        continue;
      }
      final Map<String, dynamic> value = WbBoardFileCodec.encodeElement(element);
      if (batch.pageId.isNotEmpty) {
        value['pageId'] = batch.pageId;
      }
      _applyLocalAndSend('el:${element.id}:data', value);
    }
    for (final String id in batch.removedIds) {
      if (id.isEmpty) {
        continue;
      }
      _applyLocalAndSend('el:$id:exists', false);
    }
  }

  /// 页结构出口：本地页新建 / 删除 / 重命名 / 排序 → `pg:{pageId}:{field}`。
  ///
  /// 与元素 op 同一可靠通道（board:ops → op log 回放供迟到入房者重建
  /// 页结构）；已释放 / 防回发窗口内静默跳过（对齐桌面
  /// `WbSyncService.handlePageOp`：value 缺省 true）。
  void handlePageOp(String pageId, String field, Object? value) {
    if (_disposed || pageId.isEmpty || field.isEmpty || _applyingRemote) {
      return;
    }
    _applyLocalAndSend('pg:$pageId:$field', value ?? true);
  }

  void _applyLocalAndSend(String key, Object? value) {
    final Map<String, dynamic>? result =
        _executeCrdt('crdt.applyLocal', <String, dynamic>{
      'docId': _boardId,
      'operation': <String, dynamic>{'key': key, 'value': value},
    });
    if (result == null) {
      return;
    }
    // 引擎补齐 actor/seq/timestamp 后的规范化 op（透传发送，服务端
    // 只记流水账；actor 同一会话内恒定）。
    final Map<String, Object?>? op = _asStringMap(result['op']);
    if (op == null || op.isEmpty) {
      return;
    }
    _recordWatermark(op['actor'], op['seq']);
    _cacheSentOp(op);
    unawaited(_sendOpsWithAck(<Object?>[op]));
  }

  /// 发送 op 批并按 ack 处理：`missingSeqs` → 从缓存补发一次（不递归）。
  Future<void> _sendOpsWithAck(List<Object?> ops) async {
    final Map<String, Object?>? ack = await _realtime.sendOps(ops);
    if (ack == null || _disposed) {
      return;
    }
    if (ack['ok'] == true) {
      return;
    }
    final Object? missing = ack['missingSeqs'];
    if (missing is! List) {
      return;
    }
    final List<Object?> resend = <Object?>[];
    for (final Object? seq in missing) {
      if (seq is! num) {
        continue;
      }
      final Object? op = _sentBySeq['$_actor:${seq.toInt()}'];
      if (op != null) {
        resend.add(op);
      }
    }
    if (resend.isEmpty) {
      return;
    }
    await _realtime.sendOps(resend);
  }

  void _cacheSentOp(Map<String, Object?> op) {
    final Object? actor = op['actor'];
    final Object? seq = op['seq'];
    if (actor is! String || actor.isEmpty || seq is! num) {
      return;
    }
    _sentBySeq['$actor:${seq.toInt()}'] = op;
    while (_sentBySeq.length > _maxSentCacheEntries) {
      _sentBySeq.remove(_sentBySeq.keys.first);
    }
  }

  // ---------------------------------------------------------------------------
  // 远端入口（board:ops → crdt.applyRemote → 画布）
  // ---------------------------------------------------------------------------

  void _handleOpsCallback(List<Object?> ops, {bool replay = false}) =>
      handleRemoteOps(ops, replay: replay);

  /// 应用远端 op 批：逐条 `crdt.applyRemote`（duplicate / LWW 败者
  /// `applied=false` 不上画布）→ 水印推进 → 批量路由画布回调。
  void handleRemoteOps(List<Object?> ops, {bool replay = false}) {
    if (_disposed || ops.isEmpty) {
      return;
    }
    final _WbRemoteBatch batch = _WbRemoteBatch();
    for (final Object? raw in ops) {
      final Map<String, Object?>? op = _asStringMap(raw);
      if (op == null) {
        continue;
      }
      final Object? rawKey = op['key'];
      if (rawKey is! String || rawKey.isEmpty) {
        continue;
      }
      final Map<String, dynamic>? result =
          _executeCrdt('crdt.applyRemote', <String, dynamic>{
        'docId': _boardId,
        'operation': <String, dynamic>{
          'key': rawKey,
          'value': op['value'],
          if (op['actor'] is String) 'actor': op['actor'],
          if (op['seq'] is num) 'seq': (op['seq'] as num).toInt(),
          if (op['timestamp'] is num) 'timestamp': (op['timestamp'] as num).toInt(),
        },
      });
      if (result == null) {
        continue;
      }
      _recordWatermark(op['actor'], op['seq']);
      if (result['applied'] != true) {
        continue;
      }
      _routeKey(rawKey, op['value'], batch);
    }
    _dispatch(batch);
  }

  /// key 前缀路由（`el:{id}:data|exists` / `pg:{pageId}:{field}`）；
  /// 未知键（M2 字段级 op 等）忽略。
  void _routeKey(String key, Object? value, _WbRemoteBatch batch) {
    if (key.startsWith('el:')) {
      final String rest = key.substring(3);
      final int sep = rest.lastIndexOf(':');
      if (sep <= 0 || sep >= rest.length - 1) {
        return;
      }
      final String id = rest.substring(0, sep);
      final String field = rest.substring(sep + 1);
      switch (field) {
        case 'data':
          final Map<String, Object?>? json = _asStringMap(value);
          if (json == null) {
            return;
          }
          try {
            final WbCanvasElement element = WbBoardFileCodec.decodeElement(json);
            if (element.id.isEmpty) {
              return;
            }
            final Object? rawPageId = json['pageId'];
            batch.upserts.add((
              element: element,
              pageId: rawPageId is String ? rawPageId : '',
            ));
          } catch (_) {
            // 坏载荷忽略，不阻断同批其他 op。
          }
        case 'exists':
          if (value == false && id.isNotEmpty) {
            batch.removes.add(id);
          }
        default:
          break;
      }
      return;
    }
    if (key.startsWith('pg:')) {
      final String rest = key.substring(3);
      final int sep = rest.indexOf(':');
      if (sep <= 0 || sep >= rest.length - 1) {
        return;
      }
      final String pageId = rest.substring(0, sep);
      final String field = rest.substring(sep + 1);
      batch.pageOps.add((pageId: pageId, field: field, value: value));
    }
  }

  /// 批量投递画布回调（页结构先于元素；包裹在防回发窗口内）。
  void _dispatch(_WbRemoteBatch batch) {
    if (batch.isEmpty) {
      return;
    }
    final bool wasApplying = _applyingRemote;
    _applyingRemote = true;
    try {
      for (final ({String pageId, String field, Object? value}) op
          in batch.pageOps) {
        onRemotePageOp?.call(op.pageId, op.field, op.value);
      }
      for (final ({WbCanvasElement element, String pageId}) upsert
          in batch.upserts) {
        onRemoteElement?.call(upsert.element, pageId: upsert.pageId);
      }
      for (final String id in batch.removes) {
        onRemoteRemove?.call(id);
      }
    } finally {
      _applyingRemote = wasApplying;
    }
  }

  // ---------------------------------------------------------------------------
  // 快照恢复（joined.snapshot）/ checkpoint
  // ---------------------------------------------------------------------------

  void _handleJoinedCallback(Map<String, Object?> payload) =>
      handleJoined(payload);

  /// 处理 `board:joined` 全量载荷：`snapshot` 存在且本端 crdt doc 不存在
  /// （探测 NotFound）时恢复快照（create → decodeState → 水印 → 画布回放）。
  ///
  /// 优先尝试初始自举推送（[_maybePushInitialContent]）；doc 已存在
  /// （同会话重入房间）时跳过快照——增量 replay 帧负责收敛。
  void handleJoined(Map<String, Object?> payload) {
    if (_disposed) {
      return;
    }
    // 首个加入者自举推送（服务端空房间 + Host + 本会话首建文档）：
    // 完成即不再走快照恢复（空房间必然无快照）。
    if (_maybePushInitialContent(payload)) {
      return;
    }
    final Map<String, Object?>? snapshot = _asStringMap(payload['snapshot']);
    if (snapshot == null) {
      return;
    }
    try {
      _tools.execute('crdt.encodeState', <String, dynamic>{'docId': _boardId});
      return;
    } on WbCoreException catch (e) {
      if (e.code != 'NotFound') {
        _lastError = '${e.code}: ${e.message}';
        return;
      }
    } catch (e) {
      _lastError = '$e';
      return;
    }
    if (!_ensureDocument()) {
      return;
    }
    final Object? state = snapshot['payload'];
    if (state is String && state.isNotEmpty) {
      try {
        _tools.execute('crdt.decodeState', <String, dynamic>{
          'docId': _boardId,
          'state': state,
        });
      } on WbCoreException catch (e) {
        _lastError = '${e.code}: ${e.message}';
        return;
      } catch (e) {
        _lastError = '$e';
        return;
      }
      _replayStateToCanvas(state);
    }
    final Map<String, Object?>? vector = _asStringMap(snapshot['stateVector']);
    if (vector != null) {
      for (final MapEntry<String, Object?> entry in vector.entries) {
        _recordWatermark(entry.key, entry.value);
      }
    }
  }

  /// 首个加入者自举推送：全部条件满足时把本地画布内容一次性上行——
  /// 1. `payload['stateVector']` 空（服务端房间无任何 op 历史）；
  /// 2. `payload['role'] == 'Host'`（首个加入者自举）；
  /// 3. `crdt.encodeState` 探测 NotFound（本会话首建文档，seq 自 1 起与
  ///    服务端空 oplog 连续；doc 已存在时推送会产生 seq 断档）。
  ///
  /// 经 [initialContentProvider] 收集各页提交批，逐批复用
  /// [handleLocalCommit]（编码 / 发送 / 水位链路）。返回 true 表示已执行
  /// 推送（空内容也视为完成，防重入）。
  bool _maybePushInitialContent(Map<String, Object?> payload) {
    if (_initialPushDone || payload['role'] != 'Host') {
      return false;
    }
    final Map<String, Object?>? vector = _asStringMap(payload['stateVector']);
    if (vector == null || vector.isNotEmpty) {
      return false;
    }
    final List<WbCanvasCommitBatch> Function()? provider =
        initialContentProvider;
    if (provider == null) {
      return false;
    }
    try {
      _tools.execute('crdt.encodeState', <String, dynamic>{'docId': _boardId});
      // doc 已存在：跳过推送，交由 replay / 快照收敛（避免 seq 断档）。
      return false;
    } on WbCoreException catch (e) {
      if (e.code != 'NotFound') {
        _lastError = '${e.code}: ${e.message}';
        return false;
      }
    } catch (e) {
      _lastError = '$e';
      return false;
    }
    _initialPushDone = true;
    if (!_ensureDocument()) {
      return true;
    }
    for (final WbCanvasCommitBatch batch in provider()) {
      if (batch.isEmpty) {
        continue;
      }
      handleLocalCommit(batch);
    }
    return true;
  }

  /// 解析快照 state JSON（`{key: {value, timestamp, actor}}`）并把
  /// `el:*` 键回放画布（包在防回发窗口内；`pg:*` 键忽略——快照为
  /// 元素级恢复，页结构由 op log 回放重建）。
  void _replayStateToCanvas(String stateJson) {
    final Object? decoded;
    try {
      decoded = jsonDecode(stateJson);
    } on FormatException {
      return;
    }
    if (decoded is! Map) {
      return;
    }
    final _WbRemoteBatch batch = _WbRemoteBatch();
    for (final MapEntry<Object?, Object?> entry in decoded.entries) {
      final Object? key = entry.key;
      if (key is! String || !key.startsWith('el:')) {
        continue;
      }
      final Object? register = entry.value;
      final Object? value = register is Map ? register['value'] : null;
      _routeKey(key, value, batch);
    }
    _dispatch(batch);
  }

  void _handleCheckpointRequest() {
    if (_disposed) {
      return;
    }
    final Map<String, dynamic>? result;
    try {
      result = _tools.execute('crdt.encodeState', <String, dynamic>{
        'docId': _boardId,
      });
    } on WbCoreException {
      // NotFound（无本地 doc）等：静默跳过（下次阈值触发重新请求）。
      return;
    } catch (e) {
      _lastError = '$e';
      return;
    }
    final Object? state = result['state'];
    if (state is! String || state.isEmpty) {
      return;
    }
    unawaited(_realtime.sendCheckpoint(
      stateVector: _watermarksSnapshot(),
      payload: state,
    ));
  }

  // ---------------------------------------------------------------------------
  // 引擎调用（tool 域点分路由；惰性建 doc）
  // ---------------------------------------------------------------------------

  /// 执行 crdt 工具；`NotFound`（doc 不存在）→ 惰性 create → 重试一次。
  Map<String, dynamic>? _executeCrdt(String toolId, Map<String, dynamic> args) {
    try {
      return _tools.execute(toolId, args);
    } on WbCoreException catch (e) {
      if (e.code != 'NotFound') {
        _lastError = '${e.code}: ${e.message}';
        return null;
      }
      if (!_ensureDocument()) {
        return null;
      }
      try {
        return _tools.execute(toolId, args);
      } on WbCoreException catch (retry) {
        _lastError = '${retry.code}: ${retry.message}';
        return null;
      } catch (retry) {
        _lastError = '$retry';
        return null;
      }
    } catch (e) {
      _lastError = '$e';
      return null;
    }
  }

  /// 惰性创建 crdt 文档（幂等；Conflict = 已存在，视为就绪）。
  bool _ensureDocument() {
    if (_docCreated) {
      return true;
    }
    try {
      _tools.execute('crdt.create', <String, dynamic>{
        'docId': _boardId,
        'actor': _actor,
      });
    } on WbCoreException catch (e) {
      if (e.code != 'Conflict') {
        _lastError = '${e.code}: ${e.message}';
        return false;
      }
    } catch (e) {
      _lastError = '$e';
      return false;
    }
    _docCreated = true;
    return true;
  }

  void _recordWatermark(Object? actor, Object? seq) {
    if (actor is! String || actor.isEmpty || seq is! num) {
      return;
    }
    final int value = seq.toInt();
    final Object? current = _watermarks[actor];
    final int currentSeq = current is num ? current.toInt() : 0;
    if (value > currentSeq) {
      _watermarks[actor] = value;
    }
  }

  Map<String, Object?> _watermarksSnapshot() =>
      Map<String, Object?>.from(_watermarks);

  /// 生成会话 actor（`web-<时间36>-<随机36>`；仅会话内有效）。
  static String _generateActor() {
    final String stamp =
        DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final String nonce = Random().nextInt(0x7fffffff).toRadixString(36);
    return 'web-$stamp-$nonce';
  }
}

/// 远端批（先收集后投递，统一包裹防回发窗口）。
class _WbRemoteBatch {
  final List<({WbCanvasElement element, String pageId})> upserts =
      <({WbCanvasElement element, String pageId})>[];
  final List<String> removes = <String>[];
  final List<({String pageId, String field, Object? value})> pageOps =
      <({String pageId, String field, Object? value})>[];

  bool get isEmpty => upserts.isEmpty && removes.isEmpty && pageOps.isEmpty;
}

/// `dartify` 载荷兼容转换：键必须为 String，否则返回 null。
Map<String, Object?>? _asStringMap(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map<Object?, Object?>) {
    final Map<String, Object?> out = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final Object? key = entry.key;
      if (key is! String) {
        return null;
      }
      out[key] = entry.value;
    }
    return out;
  }
  return null;
}
