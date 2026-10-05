/// 协同服务：FFI 控制面封装 + 事件轮询 + 画布出口 / 入口协调（M1）。
///
/// 链路（《互动白板实时协同设计文档》§8.3、决策 D6 / D-D）：
/// - 控制面：`connect` / `disconnect` / `status` / `flush`——内部经
///   [WbCollabEngine] 端口转发 `whiteboard_core` 的 `WbSyncService`；
/// - 事件面：[start] 后每 [pollInterval]（默认 50ms）轮询引擎
///   `sync.events`（drain 语义）——生效 op 应用到画布（[onRemoteElement]
///   / [onRemoteRemove]）、预览透传（M2：画布鬼影 / 光标层消费）、锁回执
///   消费（[acquireLock] / [releaseLock] / [renewLock]）、room / status
///   刷新；
/// - 画布出口：[handleCanvasCommit] 把本地落定提交（与撤销栈同批）转为
///   op——`el:{id}:data`（value = 元素契约 JSON，内嵌 `pageId` 供接收端
///   按页路由；专业元素整元素）/ 删除 `el:{id}:exists=false`——经
///   `crdt.applyLocal` 补齐 actor/seq/timestamp 后 `sync.sendOperation` 直发；
///   页结构出口：[handlePageOp] → `pg:{pageId}:{field}`（create / delete /
///   rename / move），同一可靠通道（op log 回放供迟到入房者重建页结构）；
/// - 防回发：应用远端 ops 期间 [isApplyingRemote] 为 true，画布出口跳过
///   （结构防护第一层：远端应用走 `applyRemoteElement` /
///   `applyRemoteRemove`，不经过画布提交漏斗）。
///
/// M3 扩展：互动请求（举手 / 授权 / 演示 / 移除 / 跟随）经 [interactive]
/// 转发引擎 `sync.interactive`；事件轮询新增 interactiveAcks（拒绝原因
/// 经 [onInteractiveError] 轻提示）/ incomingFollows（[followers]）/
/// removed（服务端移除通知 → [isRemoved] 只读态）三个 drain 批次；room
/// 快照新增 selfRole / mode / presenterId / grantedWrite / hostUserId /
/// checkpointStatus / recovered（[canEdit] 权限收窄数据源；present 前缀
/// 与 isDemoMode（无 DLL 本地降级）无关）。
///
/// 发起端本地确定性更新（M3 修复）：服务端互动广播排除发起者自身
/// （`socket.to`），若仅依赖回包，本端举手 / 授权 / 演示状态将永远停滞
/// （表现为「举手后按钮无法收手」）。故 [raiseHand] / [lowerHand] /
/// [grantControl] / [revokeControl] / [startPresent] / [stopPresent]
/// 走「转发受理 → 入队补丁 → ack 成功应用 / 失败丢弃」
/// （[_pendingInteractivePatches] 按 action FIFO 结算，ack 载荷
/// `{action, ok, reason?}` 无 userId）；读取面（[participantList] /
/// [presentMode] / [presenterId] / [selfHandRaised]）合并补丁；stop /
/// 传输重连 / 名单裁剪时清理。与 Web 端 T3f 口径一致；跨管理端冲突后
/// 的短暂滞留由下次交互（回执失败即清）或全量快照自愈。
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
    this.handRaised = false,
    this.grantedWrite = false,
  });

  /// 参与者 id（服务端 userId；字符串形状载荷原样保留）。
  final String id;

  /// 角色（`Host` / `CoHost` / `Presenter` / `Participant` / `Viewer` /
  /// `Guest`；未知或缺省为空串）。
  final String role;

  /// 是否本人（selfUserId 精确匹配；快照缺身份时回退末位推断）。
  final bool isSelf;

  /// 是否举手（M3；服务端 `board:participants` 扩展字段）。
  final bool handRaised;

  /// 是否持有临时写权（M3；grantedWrite 镜像）。
  final bool grantedWrite;

  /// 复制并覆盖 [isSelf]。
  WbCollabParticipant withSelf(bool value) => copyWith(isSelf: value);

  /// 复制并覆盖指定字段（null 保持原值）。
  WbCollabParticipant copyWith({
    String? role,
    bool? isSelf,
    bool? handRaised,
    bool? grantedWrite,
  }) =>
      WbCollabParticipant(
        id: id,
        role: role ?? this.role,
        isSelf: isSelf ?? this.isSelf,
        handRaised: handRaised ?? this.handRaised,
        grantedWrite: grantedWrite ?? this.grantedWrite,
      );

  @override
  bool operator ==(Object other) =>
      other is WbCollabParticipant &&
      other.id == id &&
      other.role == role &&
      other.isSelf == isSelf &&
      other.handRaised == handRaised &&
      other.grantedWrite == grantedWrite;

  @override
  int get hashCode =>
      Object.hash(id, role, isSelf, handRaised, grantedWrite);

  @override
  String toString() => 'WbCollabParticipant(id: $id, role: $role, '
      'isSelf: $isSelf, handRaised: $handRaised, '
      'grantedWrite: $grantedWrite)';
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

  /// 发送高频预览（M2 笔迹 / 变换 / 光标 / 选区；可丢，须含 `kind`）。
  WbSyncPreviewResult sendPreview(Map<String, dynamic> preview);

  /// 请求软锁变更（M2 D2-C；异步授予经 `events().room.lockAcks` 回执）。
  WbSyncLockResult lock({required String action, required String elementId});

  /// 发送互动请求（M3）：raiseHand / lowerHand / grantControl /
  /// revokeControl / startPresent / stopPresent / removeUser / follow /
  /// unfollow；[userId] 为目标用户（grantControl / revokeControl /
  /// removeUser），[targetUserId] 为跟随目标（follow / unfollow）。
  /// 未连接 / 离线恒定 requested:false；异步结果经
  /// `events().interactiveAcks` 回执。
  WbSyncInteractiveResult interactive({
    required String action,
    String? userId,
    String? targetUserId,
  });
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

  @override
  WbSyncPreviewResult sendPreview(Map<String, dynamic> preview) =>
      _ffiService.sync.sendPreview(preview);

  @override
  WbSyncLockResult lock({required String action, required String elementId}) =>
      _ffiService.sync.lock(action: action, elementId: elementId);

  @override
  WbSyncInteractiveResult interactive({
    required String action,
    String? userId,
    String? targetUserId,
  }) =>
      _ffiService.sync.interactive(
        action: action,
        userId: userId,
        targetUserId: targetUserId,
      );
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
    Timer Function(Duration interval, void Function() onTick)? renewTimerFactory,
    Future<void> Function(Duration duration)? sleep,
    DateTime Function()? clock,
    String Function()? actorGenerator,
  })  : _engine = engine,
        endpoint = (endpoint == null || endpoint.trim().isEmpty)
            ? defaultEndpoint
            : endpoint.trim(),
        _pollTimerFactory = pollTimerFactory ?? _periodicTimer,
        _renewTimerFactory = renewTimerFactory ?? _periodicTimer,
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

  /// 软锁续约周期（持有锁期间周期续约；服务端 TTL 30s，留重试余量）。
  static const Duration lockRenewInterval = Duration(seconds: 10);

  /// 重连预算（`reconnectCount` 达到该值后提示手动「重新连接」）。
  static const int reconnectBudget = 5;

  final WbCollabEngine? _engine;
  final Timer Function(Duration interval, void Function() onTick)
      _pollTimerFactory;
  final Timer Function(Duration interval, void Function() onTick)
      _renewTimerFactory;
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
  final Set<String> _heldLocks = <String>{};
  Timer? _renewTimer;
  final Set<String> _followers = <String>{};
  bool _removed = false;
  String _removedReason = '';
  bool _recoveredNotified = false;
  // M3 发起端本地确定性更新（服务端广播排除发起者；ack 确认后生效）。
  final List<_WbPendingInteractivePatch> _pendingInteractivePatches =
      <_WbPendingInteractivePatch>[];
  bool? _patchHandRaised;
  bool? _patchPresentMode;
  String? _patchPresenterId;
  final Map<String, bool> _patchGrantedWrite = <String, bool>{};

  /// 远端元素 upsert 回调（注入：画布入口；null 时空转）。
  ///
  /// [pageId] 为 op 携带的目标页（旧发送端 / 未分页帧为空串，接收端
  /// 回退当前页）。
  void Function(WbCanvasElement element, {String? pageId})? onRemoteElement;

  /// 远端元素删除回调（注入：画布入口；null 时空转）。
  void Function(String elementId)? onRemoteRemove;

  /// 远端页结构 op 回调（注入：页面状态；null 时空转）。
  ///
  /// [field] ∈ `create`（value `{'name': ...}`）/ `delete`（true）/
  /// `rename`（新名）/ `move`（目标索引）。
  void Function(String pageId, String field, Object? value)? onRemotePageOp;

  /// 远端预览透传回调（M2：画布鬼影 / 光标层消费；null 时空转）。
  void Function(List<Map<String, dynamic>> previews)? onRemotePreviews;

  /// 本端软锁请求被拒回调（elementId + 当前持有者 userId，可能为空）。
  void Function(String elementId, String? holderUserId)? onLockDenied;

  /// 交互请求被拒回调（M3；action 原码 + reason 原码，UI 经
  /// [wbInteractiveReasonLabel] 映射提示；null 时空转）。
  void Function(String action, String reason)? onInteractiveError;

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
    } else {
      // 快照缺身份（旧引擎 / 非对象载荷）：回退「末位 = 本人」推断。
      final int last = parsed.length - 1;
      parsed[last] = parsed[last].withSelf(true);
    }
    // M3 发起端本地确定性更新：合并本端互动补丁（服务端广播排除发起者）。
    for (int i = 0; i < parsed.length; i++) {
      parsed[i] = _mergeInteractivePatch(parsed[i]);
    }
    return List<WbCollabParticipant>.unmodifiable(parsed);
  }

  /// 合并单条参与者的本端互动补丁（无补丁原样返回）。
  WbCollabParticipant _mergeInteractivePatch(WbCollabParticipant participant) {
    final bool? handRaised = participant.isSelf ? _patchHandRaised : null;
    final bool? grantedWrite = _patchGrantedWrite[participant.id];
    if (handRaised == null && grantedWrite == null) {
      return participant;
    }
    return participant.copyWith(
      handRaised: handRaised,
      grantedWrite: grantedWrite,
    );
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
      return WbCollabParticipant(
        id: id,
        role: role is String ? role : '',
        handRaised: item['handRaised'] == true,
        grantedWrite: item['grantedWrite'] == true,
      );
    }
    if (item is String && item.isNotEmpty) {
      return WbCollabParticipant(id: item);
    }
    return null;
  }

  /// 传输重连次数（最近快照）。
  int get reconnectCount => _lastStatus.reconnectCount;

  /// 最近一次轮询收到的预览条数（M2 渲染入口观测）。
  int get lastPreviewCount => _lastPreviewCount;

  /// 房间锁快照（elementId → `{userId, expiresAt}`；含本端持有）。
  Map<String, dynamic> get locks => _room.locks;

  /// 本端会话身份（`board:session`；未连接 / 旧引擎为空串）。
  String get selfUserId => _room.selfUserId;

  /// 他人持有的锁（elementId → 持有者 userId；排除本端）。
  ///
  /// 本端身份未知（空串）时保守视为全部他人持有（不误判为本人）。
  Map<String, String> get remoteLocks {
    final Map<String, String> result = <String, String>{};
    final String self = _room.selfUserId;
    for (final MapEntry<String, dynamic> entry in _room.locks.entries) {
      final String? holder = _lockHolderOf(entry.value);
      if (holder == null || holder == self) {
        continue;
      }
      result[entry.key] = holder;
    }
    return result;
  }

  /// 指定元素的锁持有者（排除本端）；无锁 / 本端持有返回 null。
  String? lockHolderOf(String elementId) => remoteLocks[elementId];

  /// 本端是否持有指定元素的软锁（acquire 回执确认后为 true）。
  bool isHoldingLock(String elementId) => _heldLocks.contains(elementId);

  /// 是否应提示手动重连（重连预算耗尽：失败态且轮次达 [reconnectBudget]）。
  bool get shouldOfferReconnect {
    final bool failed =
        _status == WbSyncStatus.error || _status == WbSyncStatus.offline;
    return failed && reconnectCount >= reconnectBudget;
  }

  // ---- M3 房间角色 / 模式 / 跟随状态 --------------------------------------

  /// 本端角色（`Host` / `CoHost` / `Presenter` / `Participant` /
  /// `Viewer` / `Guest`；未同步 / 旧引擎为空串）。
  String get selfRole => _room.selfRole;

  /// 是否演示模式（本端发起补丁优先，其次服务端 mode == `present`；与
  /// isDemoMode（无 DLL 本地降级）无关，命名以 present 前缀区分）。
  bool get presentMode => _patchPresentMode ?? (_room.mode == 'present');

  /// 当前演示者 userId（startPresent 时由发起者署名；无演示 / 已退出为
  /// 空串；本端发起补丁优先）。
  String get presenterId => _patchPresenterId ?? _room.presenterId;

  /// 是否持有房间级临时写权（grantedWrite 镜像）。
  bool get grantedWrite => _room.grantedWrite;

  /// 当前主持人 userId（hostChanged 折叠；未同步为空串）。
  String get hostUserId => _room.hostUserId;

  /// 本端 checkpoint 状态（`idle` / `requested` / `uploaded` / `failed`；
  /// T3.5 引擎内自动响应，这里仅透出观测）。
  String get checkpointStatus => _room.checkpointStatus;

  /// 是否发生过 join 快照恢复（「已从存档恢复」提示数据源）。
  bool get recovered => _room.recovered;

  /// 是否应弹出「已从存档恢复」提示（一次性：展示后调
  /// [markRecoveredNotified] 抑制重复）。
  bool get shouldNotifyRecovered => _room.recovered && !_recoveredNotified;

  /// 标记「已从存档恢复」提示已展示（幂等）。
  void markRecoveredNotified() {
    _recoveredNotified = true;
  }

  /// 本端是否已被移出房间（`room:removed` 单播 → 只读态）。
  bool get isRemoved => _removed;

  /// 被移出的服务端原因原码（未移除为空串；UI 展示用 [removedMessage]）。
  String get removedReason => _removedReason;

  /// 被移出的只读提示文案（横幅）。
  String get removedMessage => '你已被移出此白板，当前为只读';

  /// 正在跟随本端的用户集合（incomingFollows 折叠；跟随者离开时求交
  /// 清理）。
  Set<String> get followers => Set<String>.unmodifiable(_followers);

  /// 是否 Host。
  bool get isHost => selfRole == roleHost;

  /// 是否 CoHost 及以上（Host / CoHost）。
  bool get isCoHostOrHigher => roleRank(selfRole) >= roleRank(roleCoHost);

  /// 是否 Presenter 及以上（Host / CoHost / Presenter）。
  bool get isPresenterOrHigher => roleRank(selfRole) >= roleRank(rolePresenter);

  /// 是否可管理互动（授权 / 移除 / 演示开关；在线 && 未被移除 && CoHost+）。
  bool get canManageInteractions =>
      isOnline && !_removed && isCoHostOrHigher;

  /// 是否可举手 / 收手（在线 && 未被移除 && Viewer 及以上 && 非 CoHost+）。
  bool get canRaiseHand =>
      isOnline &&
      !_removed &&
      selfRole.isNotEmpty &&
      roleRank(selfRole) >= roleRank(roleViewer) &&
      !isCoHostOrHigher;

  /// 本端是否已举手（本端发起补丁优先，其次参与者快照 handRaised）。
  bool get selfHandRaised {
    final bool? patched = _patchHandRaised;
    if (patched != null) {
      return patched;
    }
    for (final WbCollabParticipant participant in participantList) {
      if (participant.isSelf) {
        return participant.handRaised;
      }
    }
    return false;
  }

  /// 是否可编辑白板（M3 权限收窄；只控白板元素编辑，不控透明批注）。
  ///
  /// 判定顺序与服务端 `effectiveCanWrite` 对齐（2026-10「默认无权限」语义：
  /// 后加入者默认只读，需主持人授权；free / present 一致）：
  /// 1. 已被移除 → false（只读）；
  /// 2. 角色未同步（空串；单机 / 旧引擎）→ true（本地放行）；
  /// 3. grantedWrite → true（临时写权优先）；
  /// 4. Host / CoHost → true（管理角色恒可写）；
  /// 5. present 模式下的 Presenter → true（演示中唯一可写）；
  /// 6. 其余（Participant / Viewer / Guest）→ false（默认只读）。
  bool get canEdit {
    if (_removed) {
      return false;
    }
    if (selfRole.isEmpty) {
      return true;
    }
    if (_room.grantedWrite) {
      return true;
    }
    if (roleRank(selfRole) >= roleRank(roleCoHost)) {
      return true;
    }
    if (presentMode && roleRank(selfRole) >= roleRank(rolePresenter)) {
      return true;
    }
    return false;
  }

  /// 是否需要广播本端视口（M3 跟随）：有跟随者，或本端为演示者。
  bool get needsViewportBroadcast =>
      _followers.isNotEmpty ||
      (presentMode && presenterId.isNotEmpty && presenterId == selfUserId);

  /// 是否可对目标参与者授权 / 收回控制（CoHost+ 且目标低于 CoHost、
  /// 非本人；服务端 invalid-target 规则的前置收窄）。
  bool canGrantControlParticipant(String targetId, String targetRole) =>
      canManageInteractions &&
      targetId.isNotEmpty &&
      targetId != selfUserId &&
      roleRank(targetRole) < roleRank(roleCoHost);

  /// 是否可移除目标参与者（CoHost+ 且层级严格高于目标；非本人）。
  bool canRemoveParticipant(String targetId, String targetRole) =>
      canManageInteractions &&
      targetId.isNotEmpty &&
      targetId != selfUserId &&
      roleRank(selfRole) > roleRank(targetRole);

  /// 角色层级（与服务端 `ROLE_RANK` 对齐：Host 5 > CoHost 4 > Presenter 3
  /// > Participant 2 > Viewer 1 > Guest 0；未知角色 0）。
  static int roleRank(String role) {
    switch (role) {
      case roleHost:
        return 5;
      case roleCoHost:
        return 4;
      case rolePresenter:
        return 3;
      case roleParticipant:
        return 2;
      case roleViewer:
        return 1;
      case roleGuest:
        return 0;
      default:
        return 0;
    }
  }

  /// 角色是否具备基础写权限（Host / CoHost / Presenter / Participant）。
  static bool roleCanWrite(String role) =>
      roleRank(role) >= roleRank(roleParticipant);

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
    _heldLocks.clear();
    _renewTimer?.cancel();
    _renewTimer = null;
    _followers.clear();
    _resetInteractivePatches();
    _removed = false;
    _removedReason = '';
    _recoveredNotified = false;
    final WbCollabEngine? engine = _engine;
    if (engine != null) {
      try {
        engine.disconnect();
      } catch (e) {
        _lastError = '$e';
      }
    }
    _lastStatus = const WbSyncStatusData();
    final bool hadRoom = _room.participants.isNotEmpty ||
        _room.locks.isNotEmpty ||
        _room.mode.isNotEmpty ||
        _followers.isNotEmpty ||
        _removed;
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

  // ---- M2 高频预览与软锁 --------------------------------------------------

  /// 发送高频预览（光标 / 选区 / 笔迹 / 变换；可丢语义）。
  ///
  /// 转发引擎 `sync.sendPreview`；未 start / 引擎不可用 / 载荷缺 `kind`
  /// 时返回 dropped（不抛出，不阻断本地交互）。
  WbSyncPreviewResult sendPreview(Map<String, dynamic> preview) {
    final WbCollabEngine? engine = _engine;
    if (engine == null || _boardId == null) {
      return const WbSyncPreviewResult(dropped: true);
    }
    try {
      return engine.sendPreview(preview);
    } catch (e) {
      _lastError = e is WbCoreException ? '${e.code}: ${e.message}' : '$e';
      return const WbSyncPreviewResult(dropped: true);
    }
  }

  /// 请求元素软锁（acquire；授予 / 拒绝结果异步经锁回执）。
  ///
  /// 授予后 [isHoldingLock] 为 true 并自动续约；被拒触发 [onLockDenied]。
  WbSyncLockResult acquireLock(String elementId) =>
      _sendLock('acquire', elementId);

  /// 释放元素软锁（release；同时停止对应续约）。
  WbSyncLockResult releaseLock(String elementId) {
    _heldLocks.remove(elementId);
    _stopRenewTimerIfIdle();
    return _sendLock('release', elementId);
  }

  /// 续约元素软锁（renew；持有期间由续约定时器自动调用）。
  WbSyncLockResult renewLock(String elementId) => _sendLock('renew', elementId);

  /// 手动重连当前房间（重连预算耗尽后的恢复入口）。
  ///
  /// 语义 = stop（disconnect，保留 boardId）+ start（同 boardId）：
  /// connect → crdt.create → join → 轮询；未在房返回 false。
  Future<bool> reconnect() async {
    final String? boardId = _boardId;
    if (boardId == null || boardId.isEmpty) {
      return false;
    }
    await stop();
    return start(boardId: boardId);
  }

  WbSyncLockResult _sendLock(String action, String elementId) {
    final WbCollabEngine? engine = _engine;
    if (engine == null || _boardId == null || elementId.isEmpty) {
      return const WbSyncLockResult();
    }
    try {
      return engine.lock(action: action, elementId: elementId);
    } catch (e) {
      _lastError = e is WbCoreException ? '${e.code}: ${e.message}' : '$e';
      return const WbSyncLockResult();
    }
  }

  /// 消费锁回执（drain 批次）：acquire 授予 → 记录持有并确保续约；
  /// 被拒 → [onLockDenied]；release → 清除；renew 失败 → 视为丢失。
  void _consumeLockAcks(List<dynamic> acks) {
    for (final Object? item in acks) {
      if (item is! Map) {
        continue;
      }
      final Object? rawId = item['elementId'];
      if (rawId is! String || rawId.isEmpty) {
        continue;
      }
      final Object? rawAction = item['action'];
      final String action = rawAction is String ? rawAction : '';
      final bool ok = item['ok'] == true;
      final bool granted = item['granted'] == true;
      switch (action) {
        case 'acquire':
          if (ok && granted) {
            _heldLocks.add(rawId);
            _ensureRenewTimer();
          } else {
            _heldLocks.remove(rawId);
            final Object? holder = item['holderUserId'];
            onLockDenied?.call(
              rawId,
              holder is String && holder.isNotEmpty ? holder : null,
            );
          }
        case 'release':
          _heldLocks.remove(rawId);
          _stopRenewTimerIfIdle();
        case 'renew':
          if (!(ok && granted)) {
            _heldLocks.remove(rawId);
            _stopRenewTimerIfIdle();
          }
        default:
          break;
      }
    }
  }

  /// 启动续约定时器（幂等；持有锁期间每 [lockRenewInterval] 续约一轮）。
  void _ensureRenewTimer() {
    if (_renewTimer != null || _heldLocks.isEmpty) {
      return;
    }
    _renewTimer = _renewTimerFactory(lockRenewInterval, _renewHeldLocks);
  }

  /// 续约全部持有锁（周期回调）。
  void _renewHeldLocks() {
    for (final String elementId in _heldLocks.toList()) {
      renewLock(elementId);
    }
  }

  /// 无持有锁时停止续约定时器。
  void _stopRenewTimerIfIdle() {
    if (_heldLocks.isNotEmpty) {
      return;
    }
    _renewTimer?.cancel();
    _renewTimer = null;
  }

  // ---- M3 互动请求（举手 / 授权 / 演示 / 移除 / 跟随） --------------------

  /// 发送互动请求（M3；转发引擎 `sync.interactive`）。
  ///
  /// [action] 白名单 9 个：`raiseHand` / `lowerHand` / `grantControl` /
  /// `revokeControl` / `startPresent` / `stopPresent` / `removeUser` /
  /// `follow` / `unfollow`；[userId] 为目标用户（grantControl /
  /// revokeControl / removeUser），[targetUserId] 为跟随目标（follow /
  /// unfollow）。未 start / 引擎不可用 / 转发异常 → `requested:false`
  /// （不抛出）；服务端受理结果异步经 `events().interactiveAcks` 回执，
  /// 拒绝触发 [onInteractiveError]。
  WbSyncInteractiveResult interactive({
    required String action,
    String? userId,
    String? targetUserId,
  }) {
    final WbCollabEngine? engine = _engine;
    if (engine == null || _boardId == null) {
      return const WbSyncInteractiveResult();
    }
    try {
      return engine.interactive(
        action: action,
        userId: userId,
        targetUserId: targetUserId,
      );
    } catch (e) {
      _lastError = e is WbCoreException ? '${e.code}: ${e.message}' : '$e';
      return const WbSyncInteractiveResult();
    }
  }

  /// 发起互动请求并入队本地补丁（ack 形状 `{action, ok, reason?}` 无
  /// userId，按 action FIFO 结算；转发未受理不入队）。
  WbSyncInteractiveResult _requestInteractiveWithPatch({
    required String action,
    String? userId,
    required void Function() apply,
  }) {
    final WbSyncInteractiveResult result =
        interactive(action: action, userId: userId);
    if (result.requested) {
      _pendingInteractivePatches.add(
        _WbPendingInteractivePatch(action: action, apply: apply),
      );
    }
    return result;
  }

  /// 举手（`interactive:raiseHand`；ack 确认后本地先行生效）。
  WbSyncInteractiveResult raiseHand() => _requestInteractiveWithPatch(
        action: 'raiseHand',
        apply: () => _patchHandRaised = true,
      );

  /// 收手（`interactive:lowerHand`；ack 确认后本地先行生效）。
  WbSyncInteractiveResult lowerHand() => _requestInteractiveWithPatch(
        action: 'lowerHand',
        apply: () => _patchHandRaised = false,
      );

  /// 授权临时写权（`interactive:grantControl`；ack 确认后本地先行生效）。
  WbSyncInteractiveResult grantControl(String userId) =>
      _requestInteractiveWithPatch(
        action: 'grantControl',
        userId: userId,
        apply: () => _patchGrantedWrite[userId] = true,
      );

  /// 收回临时写权（`interactive:revokeControl`；ack 确认后本地先行生效）。
  WbSyncInteractiveResult revokeControl(String userId) =>
      _requestInteractiveWithPatch(
        action: 'revokeControl',
        userId: userId,
        apply: () => _patchGrantedWrite[userId] = false,
      );

  /// 开始演示（`interactive:startPresent`；presenterId = 发起者；
  /// ack 确认后本地先行生效）。
  WbSyncInteractiveResult startPresent() => _requestInteractiveWithPatch(
        action: 'startPresent',
        apply: () {
          _patchPresentMode = true;
          _patchPresenterId = selfUserId;
        },
      );

  /// 结束演示（`interactive:stopPresent`；ack 确认后本地先行生效）。
  WbSyncInteractiveResult stopPresent() => _requestInteractiveWithPatch(
        action: 'stopPresent',
        apply: () {
          _patchPresentMode = false;
          _patchPresenterId = '';
        },
      );

  /// 移除成员（`interactive:removeUser`）。
  WbSyncInteractiveResult removeUser(String userId) =>
      interactive(action: 'removeUser', userId: userId);

  /// 跟随用户（`interactive:follow`；跟随帧消费见跟随控制器）。
  WbSyncInteractiveResult follow(String targetUserId) =>
      interactive(action: 'follow', targetUserId: targetUserId);

  /// 停止跟随（`interactive:unfollow`）。
  WbSyncInteractiveResult unfollow(String targetUserId) =>
      interactive(action: 'unfollow', targetUserId: targetUserId);

  /// 消费互动回执（drain 批次）：成功 → 结算最早的同类待定补丁并应用
  /// （发起端本地确定性更新）；失败 → 丢弃同类待定补丁 + 触发
  /// [onInteractiveError] 轻提示；坏载荷忽略。
  void _consumeInteractiveAcks(List<dynamic> acks) {
    for (final Object? item in acks) {
      if (item is! Map) {
        continue;
      }
      final Object? rawAction = item['action'];
      final String action = rawAction is String ? rawAction : '';
      if (item['ok'] == true) {
        _settlePendingInteractive(action);
        continue;
      }
      final Object? rawReason = item['reason'];
      _dropPendingInteractive(action);
      onInteractiveError?.call(action, rawReason is String ? rawReason : '');
    }
  }

  /// 结算最早的同 action 待定补丁：应用并通知（无匹配时忽略）。
  void _settlePendingInteractive(String action) {
    for (int i = 0; i < _pendingInteractivePatches.length; i++) {
      final _WbPendingInteractivePatch pending = _pendingInteractivePatches[i];
      if (pending.action != action) {
        continue;
      }
      _pendingInteractivePatches.removeAt(i);
      pending.apply();
      notifyListeners();
      return;
    }
  }

  /// 丢弃最早的同 action 待定补丁（ack 拒绝；无匹配时忽略）。
  void _dropPendingInteractive(String action) {
    for (int i = 0; i < _pendingInteractivePatches.length; i++) {
      if (_pendingInteractivePatches[i].action == action) {
        _pendingInteractivePatches.removeAt(i);
        return;
      }
    }
  }

  /// 清空全部互动补丁（stop / 传输重连：旧连接状态已失效）。
  void _resetInteractivePatches() {
    _pendingInteractivePatches.clear();
    _patchHandRaised = null;
    _patchPresentMode = null;
    _patchPresenterId = null;
    _patchGrantedWrite.clear();
  }

  /// 消费投给本端的跟随事件（`incomingFollows`）：follow 增集合 /
  /// unfollow 减集合；有变化才通知。
  void _consumeIncomingFollows(List<dynamic> follows) {
    bool changed = false;
    for (final Object? item in follows) {
      if (item is! Map) {
        continue;
      }
      final Object? rawFollower = item['followerUserId'];
      if (rawFollower is! String || rawFollower.isEmpty) {
        continue;
      }
      switch (item['action']) {
        case 'follow':
          changed = _followers.add(rawFollower) || changed;
        case 'unfollow':
          changed = _followers.remove(rawFollower) || changed;
        default:
          break;
      }
    }
    if (changed) {
      notifyListeners();
    }
  }

  /// 消费 `room:removed`（一次性）：进入只读态、停止引擎重连并通知。
  void _consumeRemoved(Map<String, dynamic> removed) {
    if (removed.isEmpty || _removed) {
      return;
    }
    final Object? rawReason = removed['reason'];
    _removed = true;
    _removedReason = rawReason is String ? rawReason : '';
    // 被移除后停止重连：主动断开引擎（socket.io 自动重连 / 被动重连恢复都会
    // 重新 join 已拒绝的房间，导致「被踢仍在线」）。不走 stop()——stop 会清空
    // removed 只读横幅；重新入场由下一次 start() 重建连接。
    final WbCollabEngine? engine = _engine;
    if (engine != null) {
      try {
        engine.disconnect();
      } catch (e) {
        _lastError = e is WbCoreException ? '${e.code}: ${e.message}' : '$e';
      }
    }
    _setStatus(WbSyncStatus.offline);
    notifyListeners();
  }

  // ---- 画布出口 -----------------------------------------------------------

  /// 画布出口：本地落定提交（与撤销栈同批的 diff）→ op → 发送。
  ///
  /// 逐元素生成 op：`el:{id}:data`（value = 元素契约 JSON 内嵌
  /// `pageId`，复用 [WbBoardFileCodec.encodeElement]；专业元素整元素
  /// 处理——服务端 parseOp 只保留 6 字段且不解释 value，故路由信息
  /// 必须内嵌 value）/ 删除 `el:{id}:exists=false`（线格式不变，接收端
  /// 按元素 id 跨页查找路由）；经 `crdt.applyLocal(docId, op)` 补齐
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
      final Map<String, dynamic> value =
          WbBoardFileCodec.encodeElement(element);
      if (batch.pageId.isNotEmpty) {
        value['pageId'] = batch.pageId;
      }
      _applyLocalAndSend(engine, docId, 'el:${element.id}:data', value);
    }
    for (final String id in batch.removedIds) {
      if (id.isEmpty) {
        continue;
      }
      _applyLocalAndSend(engine, docId, 'el:$id:exists', false);
    }
  }

  /// 页结构出口：本地页新建 / 删除 / 重命名 / 排序 → `pg:{pageId}:{field}`。
  ///
  /// 与元素 op 同一可靠通道（board:ops → op log 回放供迟到入房者重建
  /// 页结构）；字段语义见 [onRemotePageOp]。未 start / 防回发窗口内
  /// 静默跳过。
  void handlePageOp(String pageId, String field, Object? value) {
    if (pageId.isEmpty || field.isEmpty || _applyingRemote) {
      return;
    }
    final WbCollabEngine? engine = _engine;
    final String? docId = _boardId;
    if (engine == null || docId == null) {
      return;
    }
    _applyLocalAndSend(engine, docId, 'pg:$pageId:$field', value ?? true);
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
      if (data.room.lockAcks.isNotEmpty) {
        _consumeLockAcks(data.room.lockAcks);
      }
      if (data.interactiveAcks.isNotEmpty) {
        _consumeInteractiveAcks(data.interactiveAcks);
      }
      if (data.incomingFollows.isNotEmpty) {
        _consumeIncomingFollows(data.incomingFollows);
      }
      _applyRoomData(data.room);
      _applyStatusData(data.status);
      if (data.removed.isNotEmpty) {
        // 终态：进入只读并断开引擎；置于状态应用之后，offline 不被同批旧状态覆盖。
        _consumeRemoved(data.removed);
      }
    } catch (e) {
      // 单次轮询失败不降级状态；由后续 tick / 状态刷新校正。
      _lastError = e is WbCoreException ? '${e.code}: ${e.message}' : '$e';
    }
  }

  /// 应用一批生效远端 op（`events().ops`；引擎已按 LWW 过滤）。
  ///
  /// `pg:{pageId}:{field}` → [onRemotePageOp]（先于同批元素 op 应用，
  /// 保证目标页先落地）；`el:{id}:data` → [onRemoteElement]（画布按
  /// value 内嵌 `pageId` 路由 upsert）；`el:{id}:exists=false` →
  /// [onRemoteRemove]（画布按元素 id 跨页查找删除）；未知键（M2 字段级
  /// op 等）忽略。应用期间 [isApplyingRemote] 为 true（画布出口跳过，
  /// 防回发）；完成后按最近快照重算状态（清掉「应用远端」临时 syncing）。
  void _applyRemoteOps(List<Map<String, dynamic>> ops) {
    final List<_WbRemoteUpsert> upserts = <_WbRemoteUpsert>[];
    final List<String> removes = <String>[];
    for (final Map<String, dynamic> op in ops) {
      final Object? rawKey = op['key'];
      if (rawKey is! String) {
        continue;
      }
      final _WbPageOpKey? pageOp = _WbPageOpKey.parse(rawKey);
      if (pageOp != null) {
        onRemotePageOp?.call(pageOp.pageId, pageOp.field, op['value']);
        continue;
      }
      final _WbElementOpKey? parsed = _WbElementOpKey.parse(rawKey);
      if (parsed == null) {
        continue;
      }
      switch (parsed.field) {
        case 'data':
          final _WbRemoteUpsert? upsert = _decodeRemoteElement(op['value']);
          if (upsert != null) {
            upserts.add(upsert);
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
      for (final _WbRemoteUpsert upsert in upserts) {
        onRemoteElement?.call(upsert.element, pageId: upsert.pageId);
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

  _WbRemoteUpsert? _decodeRemoteElement(Object? value) {
    if (value is! Map) {
      return null;
    }
    try {
      final Map<String, dynamic> json = Map<String, dynamic>.from(value);
      final WbCanvasElement element = WbBoardFileCodec.decodeElement(json);
      if (element.id.isEmpty) {
        return null;
      }
      final Object? rawPageId = json['pageId'];
      return _WbRemoteUpsert(
        element,
        rawPageId is String ? rawPageId : '',
      );
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
    final bool reconnected = data.reconnectCount > _lastStatus.reconnectCount;
    _lastStatus = data;
    if (reconnected) {
      // 传输重连：旧连接的互动补丁已无回执可结算，清空等待新快照。
      _resetInteractivePatches();
    }
    if (_status != next) {
      _status = next;
      notifyListeners();
    } else if (dataChanged) {
      notifyListeners();
    }
  }

  /// 合并 room 快照：有实质变化才更新并通知（避免每 tick 重刷 UI）；
  /// 先按新名单对 [followers] 求交清理（跟随者离开即剔除；名单为空时
  /// 保守不清理，等待后续快照），并对 grantedWrite 补丁裁剪已离开目标。
  void _applyRoomData(WbSyncRoomData room) {
    final bool prunedFollowers = _pruneFollowers(room);
    final bool prunedPatches = _pruneGrantedWritePatches(room);
    if (_sameRoom(_room, room)) {
      if (prunedFollowers || prunedPatches) {
        notifyListeners();
      }
      return;
    }
    _room = room;
    notifyListeners();
  }

  /// 与给定快照的参与者名单求交：剔除已不在名单中的跟随者；返回是否
  /// 发生剔除（名单为空返回 false，避免误清）。
  bool _pruneFollowers(WbSyncRoomData room) {
    if (_followers.isEmpty) {
      return false;
    }
    final Set<String> online = <String>{};
    for (final Object? item in room.participants) {
      final WbCollabParticipant? participant = _parseParticipant(item);
      if (participant != null) {
        online.add(participant.id);
      }
    }
    if (online.isEmpty) {
      return false;
    }
    final int before = _followers.length;
    _followers.removeWhere((String id) => !online.contains(id));
    return _followers.length != before;
  }

  /// 对 grantedWrite 补丁裁剪：剔除已不在名单中的目标；返回是否发生
  /// 裁剪（无补丁 / 名单为空返回 false，避免误清）。
  bool _pruneGrantedWritePatches(WbSyncRoomData room) {
    if (_patchGrantedWrite.isEmpty) {
      return false;
    }
    final Set<String> online = <String>{};
    for (final Object? item in room.participants) {
      final WbCollabParticipant? participant = _parseParticipant(item);
      if (participant != null) {
        online.add(participant.id);
      }
    }
    if (online.isEmpty) {
      return false;
    }
    final int before = _patchGrantedWrite.length;
    _patchGrantedWrite.removeWhere((String id, bool value) => !online.contains(id));
    return _patchGrantedWrite.length != before;
  }

  static bool _sameRoom(WbSyncRoomData a, WbSyncRoomData b) {
    if (a.mode != b.mode ||
        a.selfRole != b.selfRole ||
        a.presenterId != b.presenterId ||
        a.hostUserId != b.hostUserId ||
        a.grantedWrite != b.grantedWrite ||
        a.checkpointStatus != b.checkpointStatus ||
        a.recovered != b.recovered ||
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
    return _sameLocks(a.locks, b.locks);
  }

  /// 锁表深度比较（锁授予 / 释放 / TTL 过期时触发刷新）。
  static bool _sameLocks(Map<String, dynamic> a, Map<String, dynamic> b) {
    for (final MapEntry<String, dynamic> entry in a.entries) {
      final Object? mine = entry.value;
      final Object? theirs = b[entry.key];
      if (mine is Map && theirs is Map) {
        if (mine['userId'] != theirs['userId'] ||
            mine['expiresAt'] != theirs['expiresAt']) {
          return false;
        }
        continue;
      }
      if (mine != theirs) {
        return false;
      }
    }
    return true;
  }

  /// 参与者条目身份键（轻量比较用；Map 取 id + role + M3 标记，
  /// 其余字符串化）。
  static String _participantIdentity(Object? item) {
    if (item is Map) {
      return '${item['userId'] ?? item['id'] ?? ''}/${item['role'] ?? ''}'
          '/${item['handRaised'] == true ? 'H' : ''}'
          '${item['grantedWrite'] == true ? 'G' : ''}';
    }
    return '$item';
  }

  /// 锁条目持有者解析（`{userId, ...}` 对象；旧形态 / 坏载荷返回 null）。
  static String? _lockHolderOf(Object? entry) {
    if (entry is Map) {
      final Object? userId = entry['userId'];
      return userId is String && userId.isNotEmpty ? userId : null;
    }
    return null;
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
    _renewTimer?.cancel();
    _renewTimer = null;
    super.dispose();
  }
}

/// 待结算的互动补丁（ack 载荷 `{action, ok, reason?}` 无 userId；按
/// action FIFO 配对，成功应用 / 失败丢弃）。
class _WbPendingInteractivePatch {
  const _WbPendingInteractivePatch({required this.action, required this.apply});

  final String action;
  final void Function() apply;
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

/// 页结构 op 键解析（`pg:{pageId}:{field}`；field ∈ create / delete /
/// rename / move）。
class _WbPageOpKey {
  const _WbPageOpKey(this.pageId, this.field);

  final String pageId;
  final String field;

  /// 解析 `pg:{pageId}:{field}`；非页键返回 null（pageId 按最后一个
  /// `:` 切分）。
  static _WbPageOpKey? parse(String key) {
    if (!key.startsWith('pg:')) {
      return null;
    }
    final int sep = key.lastIndexOf(':');
    if (sep <= 2 || sep >= key.length - 1) {
      return null;
    }
    final String pageId = key.substring(3, sep);
    if (pageId.isEmpty) {
      return null;
    }
    return _WbPageOpKey(pageId, key.substring(sep + 1));
  }
}

/// 远端元素 upsert 载荷（元素 + 目标页 id；页 id 空串 = 未携带）。
class _WbRemoteUpsert {
  const _WbRemoteUpsert(this.element, this.pageId);

  final WbCanvasElement element;
  final String pageId;
}

/// 角色名常量（与服务端 `ROLE_RANK` 键对齐；中文字面量见参与者面板）。
const String roleGuest = 'Guest';
const String roleViewer = 'Viewer';
const String roleParticipant = 'Participant';
const String rolePresenter = 'Presenter';
const String roleCoHost = 'CoHost';
const String roleHost = 'Host';

/// 交互请求拒绝原因原码 → 中文提示（M3；未知码回退通用文案）。
String wbInteractiveReasonLabel(String reason) {
  switch (reason) {
    case 'not-in-room':
      return '不在房间中';
    case 'forbidden':
      return '权限不足';
    case 'invalid-argument':
      return '请求参数无效';
    case 'user-not-in-room':
      return '目标用户不在房间';
    case 'invalid-target':
      return '目标用户不支持该操作';
    case 'not-presenting':
      return '当前未处于演示状态';
    case 'payload-too-large':
      return '请求载荷过大';
    case 'notAllowed':
      return '操作不被允许';
    default:
      return '操作失败';
  }
}
