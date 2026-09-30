/// 协同服务：FFI 控制面封装 + 事件轮询 + 画布出口 / 入口协调（M1）。
///
/// 链路（《互动白板实时协同设计文档》§8.3、决策 D6 / D-D）：
/// - 控制面：`connect` / `disconnect` / `status` / `flush`——内部经
///   [WbCollabEngine] 端口转发 `whiteboard_core` 的 `WbSyncService`；
/// - 事件面：[start] 后每 [pollInterval]（默认 50ms）轮询引擎
///   `sync.events`（drain 语义）——生效 op 应用到画布（[onRemoteElement]
///   / [onRemoteRemove]）、预览透传记录（M1 不渲染）、room / status 刷新；
/// - 画布出口：[handleCanvasCommit] 把本地落定提交（与撤销栈同批）转为
///   op——`el:{id}:data`（value = 元素契约 JSON，专业元素整元素）/
///   删除 `el:{id}:exists=false`——经 `crdt.applyLocal` 补齐
///   actor/seq/timestamp 后 `sync.sendOperation` 直发；
/// - 防回发：应用远端 ops 期间 [isApplyingRemote] 为 true，画布出口跳过
///   （结构防护第一层：远端应用走 `applyRemoteElement` /
///   `applyRemoteRemove`，不经过画布提交漏斗）。
///
/// 类名与包内 `whiteboard_core` 的 `WbSyncService`（引擎域封装）区分：
/// 本类为应用侧协调器。引擎不可用（演示模式 / 无 DLL）时全部操作安全
/// 降级（保持 offline，不抛出）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:whiteboard_core/wb_core.dart';

import '../widgets/canvas/canvas_controller.dart';
import '../widgets/canvas/canvas_model.dart';
import 'board_file_codec.dart';
import 'ffi_service.dart';

/// 同步连接状态。
enum WbSyncStatus {
  /// 离线（未配置 / 未连接）。
  offline('离线'),

  /// 连接中。
  connecting('连接中'),

  /// 在线（已连接协作服务）。
  online('已连接'),

  /// 同步中（上传/下行增量）。
  syncing('同步中'),

  /// 出错。
  error('同步错误');

  const WbSyncStatus(this.label);

  /// 中文显示名。
  final String label;
}

/// 房间参与者条目（T1.7 桌面协作 UI 读取面；解析自引擎 room 快照）。
///
/// 快照来源：本端 join 时获得全量名单（`board:joined` 单播 / join ack
/// 回调），此后他人加入 / 离开经 `board:participants` 增量折叠进引擎
/// room 缓存（按 socketId 去重追加 / 移除），列表随之刷新。自身身份优先
/// 按引擎透传的 [WbSyncRoomData.selfUserId]（`board:session`，每连接
/// 唯一）精确匹配；快照缺身份（旧引擎）时回退「末位 = 本人」推断。
@immutable
class WbCollabParticipant {
  /// 创建参与者条目。
  const WbCollabParticipant({
    required this.id,
    this.role = '',
    this.isSelf = false,
  });

  /// 参与者 id（服务端 userId；字符串形状载荷原样保留）。
  final String id;

  /// 角色（`Host` / `CoHost` / `Presenter` / `Participant` / `Viewer` /
  /// `Guest`；未知或缺省为空串）。
  final String role;

  /// 是否本人（selfUserId 精确匹配；快照缺身份时回退末位推断）。
  final bool isSelf;

  /// 复制并覆盖 [isSelf]。
  WbCollabParticipant withSelf(bool value) =>
      WbCollabParticipant(id: id, role: role, isSelf: value);

  @override
  bool operator ==(Object other) =>
      other is WbCollabParticipant &&
      other.id == id &&
      other.role == role &&
      other.isSelf == isSelf;

  @override
  int get hashCode => Object.hash(id, role, isSelf);

  @override
  String toString() =>
      'WbCollabParticipant(id: $id, role: $role, isSelf: $isSelf)';
}

/// 协同引擎端口：`whiteboard_core` 域服务的应用侧抽象（测试注入接缝）。
///
/// 生产实现为 [WbFfiCollabEngine]（真实 FFI 转发）；无 DLL 环境与
/// 单元测试注入内存 fake，使状态机与出口 / 入口逻辑可独立验证。
abstract interface class WbCollabEngine {
  /// 连接协作服务（已连接 → `Conflict`，调用方幂等容忍）。
  WbSyncStatusData connect({required String endpoint, String? token});

  /// 断开连接（pending 队列保留）。
  WbSyncStatusData disconnect();

  /// 当前状态快照。
  WbSyncStatusData status();

  /// 加入协作房间（须传输已 Connected，否则 `Conflict`）。
  WbSyncJoinData join(String boardId, {String? pageId});

  /// 发送完整 op（离线入 pending 队列）。
  WbSyncSendResult sendOperation(Map<String, dynamic> op);

  /// 拉取入站事件（drain 语义）。
  WbSyncEventsData events();

  /// 冲刷离线队列（须在线；`Conflict` 表示不可冲刷）。
  WbSyncFlushData flush();

  /// 创建 CRDT 文档（已存在 → `Conflict`，调用方幂等容忍）。
  WbCrdtCreateData createDocument(String docId, {String? actor});

  /// 应用一条本地操作，响应 `op` 字段供直发。
  WbCrdtApplyData applyLocal(String docId, Map<String, dynamic> op);
}

/// [WbCollabEngine] 的 FFI 实现：转发 `WbFfiService` 聚合的
/// `sync` / `crdt` 域子服务。
///
/// 引擎不可用（未加载 DLL）时子服务 getter 抛 [StateError]，
/// 由 [WbCollabService] 捕获并降级。
class WbFfiCollabEngine implements WbCollabEngine {
  WbFfiCollabEngine(this._ffiService);

  final WbFfiService _ffiService;

  @override
  WbSyncStatusData connect({required String endpoint, String? token}) =>
      _ffiService.sync.connect(endpoint: endpoint, token: token);

  @override
  WbSyncStatusData disconnect() => _ffiService.sync.disconnect();

  @override
  WbSyncStatusData status() => _ffiService.sync.status();

  @override
  WbSyncJoinData join(String boardId, {String? pageId}) =>
      _ffiService.sync.join(boardId, pageId: pageId);

  @override
  WbSyncSendResult sendOperation(Map<String, dynamic> op) =>
      _ffiService.sync.sendOperation(op);

  @override
  WbSyncEventsData events() => _ffiService.sync.events();

  @override
  WbSyncFlushData flush() => _ffiService.sync.flush();

  @override
  WbCrdtCreateData createDocument(String docId, {String? actor}) =>
      _ffiService.crdt.create(docId, actor: actor);

  @override
  WbCrdtApplyData applyLocal(String docId, Map<String, dynamic> op) =>
      _ffiService.crdt.applyLocal(docId, op);
}

/// 协作服务（应用侧协调器）。
///
/// 生命周期：[start]（进入白板：connect → crdt.create(docId=boardId) →
/// join → 轮询）/ [stop]（退出：停轮询 → disconnect）；设置页手动
/// [connect] / [disconnect] 保持兼容（不加入房间）。
class WbCollabService extends ChangeNotifier {
  WbCollabService({
    WbCollabEngine? engine,
    String? endpoint,
    this.pollInterval = defaultPollInterval,
    this.connectTimeout = defaultConnectTimeout,
    Timer Function(Duration interval, void Function() onTick)? pollTimerFactory,
    Future<void> Function(Duration duration)? sleep,
    DateTime Function()? clock,
    String Function()? actorGenerator,
  })  : _engine = engine,
        endpoint = (endpoint == null || endpoint.trim().isEmpty)
            ? defaultEndpoint
            : endpoint.trim(),
        _pollTimerFactory = pollTimerFactory ?? _periodicTimer,
        _sleep = sleep ?? Future<void>.delayed,
        _clock = clock ?? DateTime.now,
        _actorGenerator = actorGenerator ?? _randomActor;

  /// 默认协作服务端点（realtime 服务；决策 D5 定稿端口 8790）。
  static const String defaultEndpoint = 'http://127.0.0.1:8790';

  /// 事件轮询间隔（决策 D6 定稿：50ms；与 presence 节拍匹配）。
  static const Duration defaultPollInterval = Duration(milliseconds: 50);

  /// 连接就绪等待上限（[start] / [connect] 中轮询传输状态）。
  static const Duration defaultConnectTimeout = Duration(seconds: 5);

  /// 连接就绪轮询步长（内部）。
  static const Duration _connectPollStep = Duration(milliseconds: 25);

  final WbCollabEngine? _engine;
  final Timer Function(Duration interval, void Function() onTick)
      _pollTimerFactory;
  final Future<void> Function(Duration duration) _sleep;
  final DateTime Function() _clock;
  final String Function() _actorGenerator;

  /// 协作服务端点（空串回落到 [defaultEndpoint]；可被 [connect] 更新）。
  String endpoint;

  /// 事件轮询间隔。
  final Duration pollInterval;

  /// 连接就绪等待上限。
  final Duration connectTimeout;

  WbSyncStatus _status = WbSyncStatus.offline;
  DateTime? _lastSyncedAt;
  String? _boardId;
  String _sessionActor = '';
  String _lastError = '';
  Timer? _pollTimer;
  bool _applyingRemote = false;
  int _lastPreviewCount = 0;
  WbSyncStatusData _lastStatus = const WbSyncStatusData();
  WbSyncRoomData _room = const WbSyncRoomData();

  /// 远端元素 upsert 回调（注入：画布入口；null 时空转）。
  void Function(WbCanvasElement element)? onRemoteElement;

  /// 远端元素删除回调（注入：画布入口；null 时空转）。
  void Function(String elementId)? onRemoteRemove;

  /// 远端预览透传回调（M1 仅记录，不渲染；载荷 `kind`：transform / ink）。
  void Function(List<Map<String, dynamic>> previews)? onRemotePreviews;

  /// 当前状态。
  WbSyncStatus get status => _status;

  /// 是否在线 / 同步中。
  bool get isOnline =>
      _status == WbSyncStatus.online || _status == WbSyncStatus.syncing;

  /// 最近同步完成时间（从未同步返回 null）。
  DateTime? get lastSyncedAt => _lastSyncedAt;

  /// 当前会话 actor（每连接会话随机 uuid；未 start 为空串）。
  String get sessionActor => _sessionActor;

  /// 是否正在应用远端事件（防回发标志：为 true 时画布出口跳过）。
  bool get isApplyingRemote => _applyingRemote;

  /// 当前已加入的白板 id（未 start 为 null）。
  String? get boardId => _boardId;

  /// 最近一次错误信息（无错误为空串）。
  String get lastError => _lastError;

  /// 最近一次引擎状态快照（含 pendingCount / participants / latencyMs）。
  WbSyncStatusData get lastStatus => _lastStatus;

  /// 未确认 op（pending）数量（最近快照）。
  int get pendingCount => _lastStatus.pendingCount;

  /// 房间参与者数量（最近快照；未连接为 0）。
  int get participants => _lastStatus.participants;

  /// 最近一次 ack RTT（毫秒；0 = 未采样）。
  int get latencyMs => _lastStatus.latencyMs;

  /// 房间参与者列表（T1.7 UI 读取面；未加入 / 引擎不可用为空列表）。
  ///
  /// 条目解析自引擎 `sync.events` 的 room 快照；引擎透传自身身份
  /// （`board:session` → [WbSyncRoomData.selfUserId]）时按 id 精确标记
  /// [WbCollabParticipant.isSelf]，快照缺身份时回退「末位 = 本人」
  /// 推断。他人加入 / 离开的增量（`board:participants`）由引擎折叠进
  /// room 缓存，列表随之刷新。
  List<WbCollabParticipant> get participantList {
    final List<WbCollabParticipant> parsed = <WbCollabParticipant>[];
    for (final Object? item in _room.participants) {
      final WbCollabParticipant? participant = _parseParticipant(item);
      if (participant != null) {
        parsed.add(participant);
      }
    }
    if (parsed.isEmpty) {
      return const <WbCollabParticipant>[];
    }
    // 精确匹配：引擎透传的服务端身份（每连接唯一，可直接对位）。
    final String selfId = _room.selfUserId;
    if (selfId.isNotEmpty) {
      for (int i = 0; i < parsed.length; i++) {
        if (parsed[i].id == selfId) {
          parsed[i] = parsed[i].withSelf(true);
          break;
        }
      }
      return List<WbCollabParticipant>.unmodifiable(parsed);
    }
    // 快照缺身份（旧引擎 / 非对象载荷）：回退「末位 = 本人」推断。
    final int last = parsed.length - 1;
    parsed[last] = parsed[last].withSelf(true);
    return List<WbCollabParticipant>.unmodifiable(parsed);
  }

  /// 解析单条参与者载荷（Map 取 userId/id + role；String 原样为 id；
  /// 其余 / 缺 id 返回 null —— 坏载荷忽略，不阻断其余条目）。
  static WbCollabParticipant? _parseParticipant(Object? item) {
    if (item is Map) {
      Object? id = item['userId'];
      if (id is! String || id.isEmpty) {
        id = item['id'];
      }
      if (id is! String || id.isEmpty) {
        return null;
      }
      final Object? role = item['role'];
      return WbCollabParticipant(id: id, role: role is String ? role : '');
    }
    if (item is String && item.isNotEmpty) {
      return WbCollabParticipant(id: item);
    }
    return null;
  }

  /// 传输重连次数（最近快照）。
  int get reconnectCount => _lastStatus.reconnectCount;

  /// 最近一次轮询收到的预览条数（M1 仅记录，不渲染）。
  int get lastPreviewCount => _lastPreviewCount;

  // ---- 生命周期 -----------------------------------------------------------

  /// 启动协同会话（进入白板）。
  ///
  /// 流程：connect（幂等容忍已连接 `Conflict`）→ 等待传输 Connected
  /// （有界 [connectTimeout]）→ `crdt.create(docId = boardId)`（幂等容忍
  /// `Conflict`）→ `join(boardId)` → 启动 [pollInterval] 事件轮询。
  ///
  /// 引擎不可用（演示模式 / 无 DLL）或参数缺失时保持 offline 返回 false，
  /// 绝不抛出（不阻断本地编辑）。
  Future<bool> start({
    required String boardId,
    String? endpoint,
    String? pageId,
  }) async {
    final String target =
        (endpoint == null || endpoint.trim().isEmpty) ? this.endpoint : endpoint.trim();
    await stop();
    if (boardId.isEmpty || target.isEmpty) {
      return false;
    }
    final WbCollabEngine? engine = _engine;
    if (engine == null) {
      _setStatus(WbSyncStatus.offline);
      return false;
    }

    this.endpoint = target;
    _lastError = '';
    _setStatus(WbSyncStatus.connecting);

    try {
      // 控制面连接（幂等：已连接容忍 Conflict）。
      try {
        engine.connect(endpoint: target);
      } on WbCoreException catch (e) {
        if (e.code != 'Conflict') {
          rethrow;
        }
      }

      // 等待传输就绪（C++ 侧 socket.io 握手为异步）。
      final bool connected = await _awaitConnected(engine);
      if (!connected) {
        _fail('协作服务连接失败或超时（$target）');
        return false;
      }

      // CRDT 文档（docId = boardId；重复进入幂等容忍 Conflict）。
      try {
        _sessionActor = _actorGenerator();
        try {
          engine.createDocument(boardId, actor: _sessionActor);
        } on WbCoreException catch (e) {
          if (e.code != 'Conflict') {
            rethrow;
          }
        }
        _boardId = boardId; // 文档就绪：开放画布出口。
        final WbSyncJoinData joined =
            engine.join(boardId, pageId: pageId);
        if (!joined.joined) {
          throw StateError('加入房间失败（$boardId）');
        }
      } catch (e) {
        _boardId = null;
        _sessionActor = '';
        _fail(e is WbCoreException ? '${e.code}: ${e.message}' : '$e');
        return false;
      }
    } catch (e) {
      _fail(e is WbCoreException ? '${e.code}: ${e.message}' : '$e');
      return false;
    }

    // 事件轮询（drain 语义）。
    _pollTimer = _pollTimerFactory(pollInterval, _pollEvents);
    _applyStatusData(_safeStatus(engine));
    return true;
  }

  /// 停止协同会话（退出白板）：停轮询 → disconnect。
  ///
  /// 幂等；引擎不可用 / 从未 start 时仅清理本地状态。
  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _boardId = null;
    _sessionActor = '';
    _applyingRemote = false;
    final WbCollabEngine? engine = _engine;
    if (engine != null) {
      try {
        engine.disconnect();
      } catch (e) {
        _lastError = '$e';
      }
    }
    _lastStatus = const WbSyncStatusData();
    final bool hadRoom =
        _room.participants.isNotEmpty || _room.locks.isNotEmpty;
    _room = const WbSyncRoomData();
    _setStatus(WbSyncStatus.offline);
    if (hadRoom) {
      notifyListeners();
    }
  }

  // ---- 设置页兼容控制面 ---------------------------------------------------

  /// 连接协作服务（设置页手动连接；不加入房间）。
  ///
  /// 成功后等待传输就绪并刷新状态；[url] 为空时使用当前 [endpoint]。
  Future<void> connect([String? url]) async {
    final String target =
        (url == null || url.trim().isEmpty) ? endpoint : url.trim();
    if (target.isEmpty) {
      _setStatus(WbSyncStatus.offline);
      return;
    }
    endpoint = target;
    final WbCollabEngine? engine = _engine;
    if (engine == null) {
      _setStatus(WbSyncStatus.offline);
      return;
    }
    _lastError = '';
    try {
      try {
        engine.connect(endpoint: target);
      } on WbCoreException catch (e) {
        if (e.code != 'Conflict') {
          rethrow;
        }
      }
      _setStatus(WbSyncStatus.connecting);
      final bool connected = await _awaitConnected(engine);
      if (!connected) {
        _fail('协作服务连接失败或超时（$target）');
        return;
      }
      _applyStatusData(_safeStatus(engine));
    } catch (e) {
      _fail(e is WbCoreException ? '${e.code}: ${e.message}' : '$e');
    }
  }

  /// 断开连接（设置页手动断开；等价于 [stop]）。
  Future<void> disconnect() => stop();

  /// 立即同步：冲刷离线队列（引擎 `sync` op）并刷新状态。
  Future<void> syncNow() async {
    final WbCollabEngine? engine = _engine;
    if (engine == null || !isOnline) {
      return;
    }
    try {
      engine.flush();
    } catch (e) {
      _lastError = e is WbCoreException ? '${e.code}: ${e.message}' : '$e';
    }
    _lastSyncedAt = _clock();
    _applyStatusData(_safeStatus(engine));
  }

  /// 标记同步失败（外部上报；如传输层异常）。
  void reportError([String message = '']) {
    if (message.isNotEmpty) {
      _lastError = message;
    }
    _setStatus(WbSyncStatus.error);
  }

  // ---- 画布出口 -----------------------------------------------------------

  /// 画布出口：本地落定提交（与撤销栈同批的 diff）→ op → 发送。
  ///
  /// 逐元素生成 op：`el:{id}:data`（value = 元素契约 JSON，复用
  /// [WbBoardFileCodec.encodeElement]；专业元素整元素处理）/ 删除
  /// `el:{id}:exists=false`；经 `crdt.applyLocal(docId, op)` 补齐
  /// actor/seq/timestamp（actor = [sessionActor]）后 `sync.sendOperation`
  /// 直发（离线自动入引擎 pending 队列）。
  ///
  /// 未 start（无 docId）/ 引擎不可用 / 防回发窗口内：静默跳过。
  void handleCanvasCommit(WbCanvasCommitBatch batch) {
    if (batch.isEmpty || _applyingRemote) {
      return;
    }
    final WbCollabEngine? engine = _engine;
    final String? docId = _boardId;
    if (engine == null || docId == null) {
      return;
    }
    for (final WbCanvasElement element in batch.upserts) {
      if (element.id.isEmpty) {
        continue;
      }
      _applyLocalAndSend(
        engine,
        docId,
        'el:${element.id}:data',
        WbBoardFileCodec.encodeElement(element),
      );
    }
    for (final String id in batch.removedIds) {
      if (id.isEmpty) {
        continue;
      }
      _applyLocalAndSend(engine, docId, 'el:$id:exists', false);
    }
  }

  void _applyLocalAndSend(
    WbCollabEngine engine,
    String docId,
    String key,
    Object value,
  ) {
    try {
      final WbCrdtApplyData applied = engine.applyLocal(
        docId,
        <String, dynamic>{'key': key, 'value': value},
      );
      final Map<String, dynamic> op = applied.op;
      if (op.isEmpty) {
        return;
      }
      final WbSyncSendResult result = engine.sendOperation(op);
      if (result.queued) {
        // 离线积压：下一次 status 刷新按 pendingCount 精确校正。
        _setStatus(WbSyncStatus.syncing);
      }
    } catch (e) {
      _lastError = e is WbCoreException ? '${e.code}: ${e.message}' : '$e';
    }
  }

  // ---- 事件轮询（入口） ---------------------------------------------------

  void _pollEvents() {
    final WbCollabEngine? engine = _engine;
    if (engine == null) {
      return;
    }
    try {
      final WbSyncEventsData data = engine.events();
      if (data.ops.isNotEmpty) {
        _applyRemoteOps(data.ops);
      }
      if (data.previews.isNotEmpty) {
        _lastPreviewCount = data.previews.length;
        onRemotePreviews?.call(data.previews);
      }
      _applyRoomData(data.room);
      _applyStatusData(data.status);
    } catch (e) {
      // 单次轮询失败不降级状态；由后续 tick / 状态刷新校正。
      _lastError = e is WbCoreException ? '${e.code}: ${e.message}' : '$e';
    }
  }

  /// 应用一批生效远端 op（`events().ops`；引擎已按 LWW 过滤）。
  ///
  /// `el:{id}:data` → [onRemoteElement]（画布 upsert）；
  /// `el:{id}:exists=false` → [onRemoteRemove]（画布删除）；
  /// 未知键（M2 字段级 op 等）M1 忽略。应用期间 [isApplyingRemote] 为
  /// true（画布出口跳过，防回发）；完成后按最近快照重算状态（清掉
  /// 「应用远端」临时 syncing）。
  void _applyRemoteOps(List<Map<String, dynamic>> ops) {
    final List<WbCanvasElement> upserts = <WbCanvasElement>[];
    final List<String> removes = <String>[];
    for (final Map<String, dynamic> op in ops) {
      final Object? rawKey = op['key'];
      if (rawKey is! String) {
        continue;
      }
      final _WbElementOpKey? parsed = _WbElementOpKey.parse(rawKey);
      if (parsed == null) {
        continue;
      }
      switch (parsed.field) {
        case 'data':
          final WbCanvasElement? element = _decodeRemoteElement(op['value']);
          if (element != null) {
            upserts.add(element);
          }
        case 'exists':
          if (op['value'] == false) {
            removes.add(parsed.id);
          }
        default:
          break; // 未知字段（M2 字段级 op）：M1 忽略。
      }
    }
    if (upserts.isEmpty && removes.isEmpty) {
      return;
    }
    _applyingRemote = true;
    if (_status == WbSyncStatus.online) {
      _setStatus(WbSyncStatus.syncing);
    }
    try {
      for (final WbCanvasElement element in upserts) {
        onRemoteElement?.call(element);
      }
      for (final String id in removes) {
        onRemoteRemove?.call(id);
      }
    } finally {
      _applyingRemote = false;
    }
    _lastSyncedAt = _clock();
    // 应用完成：按最近状态快照重算（清 syncing；有 pending 维持）。
    _status = _mapStatus(_lastStatus);
    notifyListeners();
  }

  WbCanvasElement? _decodeRemoteElement(Object? value) {
    if (value is! Map) {
      return null;
    }
    try {
      final WbCanvasElement element =
          WbBoardFileCodec.decodeElement(Map<String, dynamic>.from(value));
      return element.id.isEmpty ? null : element;
    } catch (_) {
      return null; // 坏载荷忽略，不阻断同批其他 op。
    }
  }

  // ---- 状态映射与内部工具 -------------------------------------------------

  /// 等待传输就绪（`connected == true`；`failed` 提前返回 false）。
  Future<bool> _awaitConnected(WbCollabEngine engine) async {
    final int timeoutMs = math.max(0, connectTimeout.inMilliseconds);
    final int stepMs = math.max(1, _connectPollStep.inMilliseconds);
    int waited = 0;
    while (waited <= timeoutMs) {
      final WbSyncStatusData data;
      try {
        data = engine.status();
      } catch (e) {
        _lastError = '$e';
        return false;
      }
      if (data.connected) {
        _applyStatusData(data);
        return true;
      }
      if (data.transportState == 'failed') {
        return false;
      }
      await _sleep(_connectPollStep);
      waited += stepMs;
    }
    return false;
  }

  /// 引擎状态快照 → UI 状态映射。
  ///
  /// - `failed` → [WbSyncStatus.error]；
  /// - 未连接：`connecting` / `reconnecting` → [WbSyncStatus.connecting]，
  ///   其余（`disconnected` 等）→ [WbSyncStatus.offline]；
  /// - 已连接：`pendingCount > 0` → [WbSyncStatus.syncing]，否则
  ///   [WbSyncStatus.online]。
  static WbSyncStatus _mapStatus(WbSyncStatusData data) {
    if (data.transportState == 'failed') {
      return WbSyncStatus.error;
    }
    if (!data.connected) {
      if (data.transportState == 'connecting' ||
          data.transportState == 'reconnecting') {
        return WbSyncStatus.connecting;
      }
      return WbSyncStatus.offline;
    }
    if (data.pendingCount > 0) {
      return WbSyncStatus.syncing;
    }
    return WbSyncStatus.online;
  }

  void _applyStatusData(WbSyncStatusData data) {
    final WbSyncStatus next = _mapStatus(data);
    final bool dataChanged = !_sameStatusData(_lastStatus, data);
    _lastStatus = data;
    if (_status != next) {
      _status = next;
      notifyListeners();
    } else if (dataChanged) {
      notifyListeners();
    }
  }

  /// 合并 room 快照：有实质变化才更新并通知（避免每 tick 重刷 UI）。
  void _applyRoomData(WbSyncRoomData room) {
    if (_sameRoom(_room, room)) {
      return;
    }
    _room = room;
    notifyListeners();
  }

  static bool _sameRoom(WbSyncRoomData a, WbSyncRoomData b) {
    if (a.mode != b.mode ||
        a.selfUserId != b.selfUserId ||
        a.locks.length != b.locks.length ||
        a.participants.length != b.participants.length) {
      return false;
    }
    for (int i = 0; i < a.participants.length; i++) {
      if (_participantIdentity(a.participants[i]) !=
          _participantIdentity(b.participants[i])) {
        return false;
      }
    }
    return true;
  }

  /// 参与者条目身份键（轻量比较用；Map 取 id + role，其余字符串化）。
  static String _participantIdentity(Object? item) {
    if (item is Map) {
      return '${item['userId'] ?? item['id'] ?? ''}/${item['role'] ?? ''}';
    }
    return '$item';
  }

  static bool _sameStatusData(WbSyncStatusData a, WbSyncStatusData b) =>
      a.connected == b.connected &&
      a.offline == b.offline &&
      a.pendingCount == b.pendingCount &&
      a.sentCount == b.sentCount &&
      a.syncedCount == b.syncedCount &&
      a.participants == b.participants &&
      a.latencyMs == b.latencyMs &&
      a.reconnectCount == b.reconnectCount &&
      a.transportState == b.transportState;

  WbSyncStatusData _safeStatus(WbCollabEngine engine) {
    try {
      return engine.status();
    } catch (_) {
      return _lastStatus;
    }
  }

  void _setStatus(WbSyncStatus status) {
    if (_status == status) {
      return;
    }
    _status = status;
    notifyListeners();
  }

  void _fail(String message) {
    _lastError = message;
    _setStatus(WbSyncStatus.error);
  }

  /// 默认轮询定时器工厂（适配 `Timer.periodic` 的回调签名）。
  static Timer _periodicTimer(Duration interval, void Function() onTick) =>
      Timer.periodic(interval, (_) => onTick());

  /// 生成会话 actor（UUID v4 风格；每连接一个——CRDT `(actor, seq)`
  /// 去重依赖其唯一性）。
  static String _randomActor() {
    final math.Random random = math.Random();
    final List<int> bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final String raw = bytes.map(hex).join();
    return 'wb-${raw.substring(0, 8)}-${raw.substring(8, 12)}-'
        '${raw.substring(12, 16)}-${raw.substring(16, 20)}-${raw.substring(20)}';
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }
}

/// 元素 op 键解析（`el:{id}:{field}`；M2 字段级前向兼容）。
class _WbElementOpKey {
  const _WbElementOpKey(this.id, this.field);

  final String id;
  final String field;

  /// 解析 `el:{id}:{field}`；非元素键返回 null（id 按最后一个 `:` 切分）。
  static _WbElementOpKey? parse(String key) {
    if (!key.startsWith('el:')) {
      return null;
    }
    final int sep = key.lastIndexOf(':');
    if (sep <= 2 || sep >= key.length - 1) {
      return null;
    }
    final String id = key.substring(3, sep);
    if (id.isEmpty) {
      return null;
    }
    return _WbElementOpKey(id, key.substring(sep + 1));
  }
}
