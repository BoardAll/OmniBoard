/**
 * realtime 服务共享类型（M1 完整版 / T1.3 + M2 体验完善 + M3 互动模式 / T3.1–T3.5）。
 *
 * 事件契约对齐《互动白板实时协同设计文档》§6（消息契约）与 §7（服务端设计）。
 *
 * 已实现事件集：
 *   C→S：board:join / board:joinAck / board:ops / board:fetchOps / board:leave / board:ping；
 *        presence:preview；lock:acquire / lock:release / lock:renew；
 *        interactive:raiseHand / lowerHand / grantControl / revokeControl / startPresent / stopPresent /
 *        removeUser / follow / unfollow（M3）；board:checkpoint（M3）；
 *   S→C：board:joined / board:ops / board:participants / room:error / room:removed（M3）；
 *        presence:preview；lock:changed；
 *        interactive:modeChanged / roleChanged / hostChanged / follow / unfollow（M3）；
 *        board:checkpointRequest（M3）。
 * 事件名已冻结、留待后续实现（本阶段不建类型、不写实现与测试）：
 *   presence:cursor / presence:selection / presence:page / presence:viewport。
 * M0 POC 兼容层（保留，非 §6 契约；12-app-web POC 与既有用例依赖）：
 *   board:session / board:echo / board:broadcast / board:direct / board:directed。
 */

import type { Namespace, Server, Socket } from 'socket.io';

/** 房间角色（§5.1，沿用 InteractiveRole）。 */
export type BoardRole = 'Host' | 'CoHost' | 'Presenter' | 'Participant' | 'Viewer' | 'Guest';

/** 全部合法房间角色（token role claim 白名单）。 */
export const BOARD_ROLES: readonly BoardRole[] = ['Host', 'CoHost', 'Presenter', 'Participant', 'Viewer', 'Guest'];

/** 缺省房间角色（M1：token 未携带合法 role 时回落；匿名 dev 同样使用）。 */
export const DEFAULT_BOARD_ROLE: BoardRole = 'Participant';

/**
 * §5.1 层级映射中的「≥Write」角色（Host/CoHost/Presenter/Participant；Viewer 只读；
 * Guest 按签发，取保守只读）。free 模式下为写权依据（effectiveCanWrite 回落分支，
 * 2026-11 修订）；同时用于 Host 自举（rooms.ts：无在线 Host 时首个 ≥Write 会话
 * 角色升 Host）与 Host 移交候选筛选（roomStore.ts：无 CoHost 时移交最早的可写角色）。
 */
const WRITE_ROLES: readonly BoardRole[] = ['Host', 'CoHost', 'Presenter', 'Participant'];

export function roleCanWrite(role: BoardRole): boolean {
  return WRITE_ROLES.includes(role);
}

/**
 * 角色级别（§5.1 会话权限层级；M3-T3.1）。
 * Host > CoHost > Presenter > Participant > Viewer > Guest（Guest 为分享链接访客，保守最低级）。
 * 用于 interactive:* 的最低角色校验与 removeUser 的"级别严格大于目标"判定。
 */
const ROLE_RANK: Record<BoardRole, number> = {
  Host: 5,
  CoHost: 4,
  Presenter: 3,
  Participant: 2,
  Viewer: 1,
  Guest: 0,
};

export function roleRank(role: BoardRole): number {
  return ROLE_RANK[role];
}

/** 房间模式（§5.10；M3-T3.1：present 下写权收窄为 Host/CoHost/Presenter/显式授权）。 */
export type BoardMode = 'free' | 'present';

/**
 * effective write 判定（M3-T3.1 / 契约 A；2026-11 修订后语义）：
 * - 显式授权（grantedWrite）与管理角色（Host/CoHost）恒可写；
 * - present（演示）模式收窄：仅 Host/CoHost/Presenter 可写（§5.10「演示中唯一可写」）；
 * - free（默认）模式：≥Write 角色（Host/CoHost/Presenter/Participant）默认可写，
 *   Viewer/Guest 仍只读——默认协作开箱可用（2026-10「默认无权限」修订）。
 * board:ops 与 lock:acquire 的权限校验统一走本函数。
 */
export function effectiveCanWrite(role: BoardRole, grantedWrite: boolean, mode: BoardMode): boolean {
  if (grantedWrite) return true;
  if (role === 'Host' || role === 'CoHost') return true;
  if (mode === 'present') return role === 'Presenter';
  return roleCanWrite(role);
}

/**
 * 会话角色裁剪 seam（设计 §5.11 双层权限：会话权限 ≤ 持久权限；M3-T3.1 / 契约 D）。
 *
 * `tokenRole` 为 token 不可变持久角色（socket.data.tokenRole）；`requested` 为服务端显式授权
 * （join 初始角色 / join 冲突降级 / host 移交）。**当前恒放行显式授权**——角色只由服务端在
 * 上述路径显式产生，客户端任何消息都不得改自身角色；待板级协作者表（13 svc-api）接入后，
 * 在此按 tokenRole 上限裁剪 requested（如持久权限为 Viewer 时禁止 requested=Host）。
 */
export function clampSessionRole(tokenRole: BoardRole, requested: BoardRole): BoardRole {
  void tokenRole;
  return requested;
}

/** 连接 auth 载荷（§7：`{token, boardId, clientVersion}`）。 */
export interface ConnectionAuthPayload {
  token?: string;
  boardId?: string;
  clientVersion?: string;
}

/** `board:session` 载荷：服务端解析出的连接身份（POC 自省，便于客户端做单播寻址）。 */
export interface BoardSessionPayload {
  userId: string;
  authMode: 'jwt' | 'anonymous';
  role: BoardRole;
}

/** 参与者条目（§5.1 / §7：userId/socketId/role/joinedAt；一个 socket 一条）。 */
export interface ParticipantInfo {
  userId: string;
  socketId: string;
  role: BoardRole;
  /** epoch 毫秒。 */
  joinedAt: number;
  /** M3：临时写权（interactive:grantControl 授予 / revokeControl 收回；仅服务端产生）。 */
  grantedWrite?: boolean;
  /** M3：举手状态（interactive:raiseHand / lowerHand；仅服务端产生）。 */
  handRaised?: boolean;
}

/** 版本水位：每 actor 最大连续 seq（§5.3 stateVector / §5.12 lastSeenVersion）。 */
export interface BoardStateVector {
  [actor: string]: number;
}

/** checkpoint 快照（§6 预留字段启用；M3-T3.5，服务端只存不解释）。 */
export interface BoardSnapshot {
  stateVector: BoardStateVector;
  payload: string;
}

/** `board:join` 载荷（§6：`{boardId, pageId?, lastSeenVersion?}`）。 */
export interface BoardJoinPayload {
  boardId: string;
  pageId?: string;
  /** 重连场景携带（§5.12）；提供时服务端在 join 后立即回放其后增量。 */
  lastSeenVersion?: BoardStateVector;
}

/** `board:joined` 载荷（§6；M3 起 snapshot 为 checkpoint 下发字段，mode 可非 free）。 */
export interface BoardJoinedPayload {
  boardId: string;
  participants: ParticipantInfo[];
  role: BoardRole;
  mode: BoardMode;
  /** M3：present 态为当前演示者 userId；free 态为 null（新加入者默认跟随用）。 */
  presenterId?: string | null;
  /** 锁表快照（§5.6；M2 起为 elementId → {userId, expiresAt} 对象 map，空闲 / 已过期为 {}）。 */
  locks: BoardLockSnapshot;
  stateVector: BoardStateVector;
  /** M3：存在 checkpoint 且加入者未携带（或空）lastSeenVersion 时下发（§7 快照策略）。 */
  snapshot?: BoardSnapshot;
}

export type BoardJoinAck = ({ ok: true } & BoardJoinedPayload) | BoardAckFailure;

/** `board:joinAck` 载荷：客户端上报本地水位，请求裁差分（§5.3 / §5.12）。 */
export interface BoardJoinAckPayload {
  /** 每 actor 本地最大 seq；缺省 / 空对象 = 全量回放（新成员首同步）。 */
  localSeqs?: BoardStateVector;
}

export type BoardJoinAckResponse = { ok: true; replayed: number } | BoardAckFailure;

/** CRDT op（§5.4；结构同 crdt 域 `{actor,seq,key,value,timestamp,origin}`，服务端只做流水账）。 */
export interface Op {
  actor: string;
  seq: number;
  key: string;
  value: unknown;
  timestamp?: number;
  origin?: string;
}

/** `board:ops` 事件元信息：实时广播携带 `from`（发送者 userId），补差分回放携带 `replay`。 */
export interface BoardOpsMeta {
  from?: string;
  replay?: boolean;
}

/** `board:ops` ack（任务 ACK 语义 `{ok, dup?, missingSeqs?}`）。 */
export type BoardOpsAck =
  | { ok: true; dup?: boolean }
  | { ok: false; missingSeqs: number[] }
  | BoardAckFailure;

/** `board:fetchOps` 载荷（§6：`{actor, fromSeq}`）。 */
export interface BoardFetchOpsPayload {
  actor: string;
  fromSeq: number;
}

export type BoardFetchOpsResponse = { ok: true; replayed: number } | BoardAckFailure;

/** `board:leave` 载荷（§6：`{}`）。 */
export type BoardLeavePayload = Record<string, never>;
export type BoardLeaveAck = { ok: true } | BoardAckFailure;

/** `board:participants` 载荷（§6：`{joined?/left?/updated?}`；updated 供 M3 角色/授权变更使用）。 */
export interface BoardParticipantsPayload {
  joined?: ParticipantInfo[];
  left?: ParticipantInfo[];
  updated?: ParticipantInfo[];
}

/** `room:error` 载荷（§6：`{code, message, reason?}`）。 */
export interface RoomErrorPayload {
  code: string;
  message: string;
  reason?: string;
}

/** `room:removed` 载荷（§6 / M3：被移出房间；服务端先单播本事件，再断开连接）。 */
export interface RoomRemovedPayload {
  code: string;
  message: string;
  reason?: string;
}

// —— M2：presence 泛化转发（§5.5）——

/** presence:preview 载荷（透传；`kind` 如 ink / transform / cursor / selection，服务端不解释不校验）。 */
export type PresencePreviewPayload = Record<string, unknown>;

/** 服务端转发的 presence:preview：附加发送者 userId（服务端权威，覆盖载荷内同名字段）。 */
export type PresencePreviewOutPayload = PresencePreviewPayload & { userId: string };

// —— M2：软锁（§5.6；会话态，不进 CRDT，仅存服务端内存 + board:joined 下发）——

/** lock:acquire / lock:release / lock:renew 请求载荷（§6：`{elementId}`）。 */
export interface LockTargetPayload {
  elementId: string;
}

/** 锁快照条目（board:joined.locks 值）。 */
export interface LockSnapshotEntry {
  userId: string;
  /** epoch 毫秒（TTL 30s，§5.6）。 */
  expiresAt: number;
}

/** board:joined.locks：elementId → 锁快照（对象 map 形态，与引擎 / 桌面解析对齐）。 */
export type BoardLockSnapshot = Record<string, LockSnapshotEntry>;

/** lock:changed 生命周期动作。 */
export type LockAction = 'acquired' | 'released' | 'expired';

/** lock:changed（S→C 广播）：授予 / 释放 / 超时（超时与断连释放由服务端发起，携带原持有者 userId）。 */
export interface LockChangedPayload {
  elementId: string;
  userId: string;
  action: LockAction;
  /** 仅 action='acquired' 携带（租约到期时间，epoch 毫秒）。 */
  expiresAt?: number;
}

/** 锁轻量失败回执（不复用 BoardAckFailure 错误信封）。 */
export interface LockAckFailure {
  ok: false;
  /** 失败原因：'not-in-room' / 'forbidden' / 'invalid-element' / 'not-holder'。 */
  reason?: string;
}

/** lock:acquire ack：授予 / 他人占用（单播拒绝回执，不广播）/ 轻量拒绝。 */
export type LockAcquireAck =
  | { ok: true; granted: true; elementId: string; expiresAt: number }
  | { ok: true; granted: false; holderUserId: string }
  | LockAckFailure;

/** lock:release ack：持有者 `{ok:true}`；非持有者 `{ok:false, reason}`。 */
export type LockReleaseAck = { ok: true } | LockAckFailure;

/** lock:renew ack：持有者 `{ok:true, expiresAt}`；非持有者 `{ok:false}`。 */
export type LockRenewAck = { ok: true; expiresAt: number } | LockAckFailure;

// —— M3：interactive 事件族（§5.10 / §5.14 / 契约 B–E）——

/** interactive:* 轻量回执（`{ok:true}` / `{ok:false, reason}`；follow/unfollow 无 ack）。 */
export type InteractiveAck = { ok: true } | { ok: false; reason: string };

/** interactive:* 空载荷（raiseHand / lowerHand / startPresent / stopPresent）。 */
export type InteractiveEmptyPayload = Record<string, never>;

/** interactive:grantControl / revokeControl / removeUser 载荷（`{userId}`）。 */
export interface InteractiveTargetPayload {
  userId: string;
}

/** interactive:follow / unfollow 请求载荷（`{targetUserId}`；无 ack）。 */
export interface InteractiveFollowPayload {
  targetUserId: string;
}

/** 服务端转发的 interactive:follow / unfollow（`{followerUserId}`；透传单播，无状态）。 */
export interface InteractiveFollowOutPayload {
  followerUserId: string;
}

/** interactive:modeChanged（S→C 广播）：模式切换；present 携带 presenterId。 */
export interface InteractiveModeChangedPayload {
  mode: BoardMode;
  /** 发起者 userId。 */
  by: string;
  /** 仅 mode='present' 携带（startPresent 发起者）。 */
  presenterId?: string;
}

/** interactive:roleChanged（S→C 单播至目标 user 房间）：会话角色 / 临时写权变更。 */
export interface InteractiveRoleChangedPayload {
  userId: string;
  role: BoardRole;
  grantedWrite: boolean;
}

/** interactive:hostChanged（S→C 广播）：Host 转移后的新 Host。 */
export interface InteractiveHostChangedPayload {
  newHostId: string;
}

/** board:checkpoint 载荷（M3-T3.5；payload 为字符串原样存储，服务端不解析）。 */
export interface BoardCheckpointPayload {
  stateVector: BoardStateVector;
  payload: string;
}

/** board:checkpoint ack（轻量：`{ok:true}` / `{ok:false, reason}`）。 */
export type BoardCheckpointAck = { ok: true } | { ok: false; reason: string };

/** board:checkpointRequest（S→C 单播）：请求候选客户端按当前水位上传 checkpoint。 */
export interface BoardCheckpointRequestPayload {
  stateVector: BoardStateVector;
}

/** 服务端存储的 checkpoint 记录（room.checkpoint；只存不解释）。 */
export interface BoardCheckpointRecord extends BoardSnapshot {
  /** 上传者 userId。 */
  byUserId: string;
  /** epoch 毫秒。 */
  updatedAt: number;
}

export interface BoardPingPayload {
  clientTime: number;
}

export interface BoardEchoPayload {
  payload: unknown;
}

export interface BoardDirectPayload {
  toUserId: string;
  payload: unknown;
}

/** 失败回执（错误码沿用 §6 风格：Unauthorized / Forbidden / NotInRoom / INVALID_ARGUMENT / ...）。 */
export interface BoardErrorPayload {
  code: string;
  message: string;
}

export interface BoardAckFailure {
  ok: false;
  error: BoardErrorPayload;
}

export type BoardPingAck = { ok: true; serverTime: number } | BoardAckFailure;
export type BoardEchoAck = { ok: true; echo: unknown } | BoardAckFailure;
export type BoardDirectAck = { ok: true } | BoardAckFailure;

export interface BoardBroadcastPayload {
  from: string;
  payload: unknown;
}

export interface BoardDirectedPayload {
  from: string;
  toUserId: string;
  payload: unknown;
}

/** C→S 事件（M1 全量 + M2 presence / lock + M3 interactive / checkpoint + M0 POC 兼容层）。 */
export interface ClientToServerEvents {
  'board:join': (payload: BoardJoinPayload, ack?: (response: BoardJoinAck) => void) => void;
  'board:joinAck': (payload: BoardJoinAckPayload, ack?: (response: BoardJoinAckResponse) => void) => void;
  'board:ops': (payload: Op[], ack?: (response: BoardOpsAck) => void) => void;
  'board:fetchOps': (payload: BoardFetchOpsPayload, ack?: (response: BoardFetchOpsResponse) => void) => void;
  'board:leave': (payload: BoardLeavePayload, ack?: (response: BoardLeaveAck) => void) => void;
  'board:ping': (payload: BoardPingPayload, ack?: (response: BoardPingAck) => void) => void;
  // —— M2：presence 预览泛化转发 + 软锁（§5.5 / §5.6）——
  'presence:preview': (payload: PresencePreviewPayload) => void;
  'lock:acquire': (payload: LockTargetPayload, ack?: (response: LockAcquireAck) => void) => void;
  'lock:release': (payload: LockTargetPayload, ack?: (response: LockReleaseAck) => void) => void;
  'lock:renew': (payload: LockTargetPayload, ack?: (response: LockRenewAck) => void) => void;
  // —— M3：interactive 事件族（轻量 ack；follow/unfollow 无 ack）——
  'interactive:raiseHand': (payload: InteractiveEmptyPayload, ack?: (response: InteractiveAck) => void) => void;
  'interactive:lowerHand': (payload: InteractiveEmptyPayload, ack?: (response: InteractiveAck) => void) => void;
  'interactive:grantControl': (payload: InteractiveTargetPayload, ack?: (response: InteractiveAck) => void) => void;
  'interactive:revokeControl': (payload: InteractiveTargetPayload, ack?: (response: InteractiveAck) => void) => void;
  'interactive:startPresent': (payload: InteractiveEmptyPayload, ack?: (response: InteractiveAck) => void) => void;
  'interactive:stopPresent': (payload: InteractiveEmptyPayload, ack?: (response: InteractiveAck) => void) => void;
  'interactive:removeUser': (payload: InteractiveTargetPayload, ack?: (response: InteractiveAck) => void) => void;
  'interactive:follow': (payload: InteractiveFollowPayload) => void;
  'interactive:unfollow': (payload: InteractiveFollowPayload) => void;
  // —— M3：checkpoint 上传（T3.5；服务端只存不解释）——
  'board:checkpoint': (payload: BoardCheckpointPayload, ack?: (response: BoardCheckpointAck) => void) => void;
  // —— M0 POC 兼容层（非 §6 契约，保留用于链路自检）——
  'board:echo': (payload: BoardEchoPayload, ack?: (response: BoardEchoAck) => void) => void;
  'board:direct': (payload: BoardDirectPayload, ack?: (response: BoardDirectAck) => void) => void;
}

/** S→C 事件（M1 全量 + M2 presence / lock + M3 interactive / checkpoint / removed + M0 POC 兼容层）。 */
export interface ServerToClientEvents {
  'board:session': (payload: BoardSessionPayload) => void;
  'board:joined': (payload: BoardJoinedPayload) => void;
  'board:ops': (ops: Op[], meta?: BoardOpsMeta) => void;
  'board:participants': (payload: BoardParticipantsPayload) => void;
  'room:error': (payload: RoomErrorPayload) => void;
  // —— M2：presence 预览转发 + 锁变更广播 ——
  'presence:preview': (payload: PresencePreviewOutPayload) => void;
  'lock:changed': (payload: LockChangedPayload) => void;
  // —— M3：interactive 通知 + 被移除 + checkpoint 请求 ——
  'interactive:modeChanged': (payload: InteractiveModeChangedPayload) => void;
  'interactive:roleChanged': (payload: InteractiveRoleChangedPayload) => void;
  'interactive:hostChanged': (payload: InteractiveHostChangedPayload) => void;
  'interactive:follow': (payload: InteractiveFollowOutPayload) => void;
  'interactive:unfollow': (payload: InteractiveFollowOutPayload) => void;
  'room:removed': (payload: RoomRemovedPayload) => void;
  'board:checkpointRequest': (payload: BoardCheckpointRequestPayload) => void;
  // —— M0 POC 兼容层（非 §6 契约，保留用于链路自检）——
  'board:broadcast': (payload: BoardBroadcastPayload) => void;
  'board:directed': (payload: BoardDirectedPayload) => void;
}

/** serverSideEmit 事件（Redis adapter 预留；M1 单实例未使用）。 */
export interface InterServerEvents {
  // 预留：水平扩展时使用
}

/** 每个连接的会话数据（认证中间件写入）。 */
export interface BoardSocketData {
  userId: string;
  authMode: 'jwt' | 'anonymous';
  /** 当前会话角色（可被服务端显式变更：join 冲突降级 / host 移交）。 */
  role: BoardRole;
  /** token 不可变持久角色（契约 D 自提升防御；clampSessionRole 的上限来源）。 */
  tokenRole: BoardRole;
  boardId?: string;
}

// —— socket.io 装配类型别名（集中定义，rooms / interactive / checkpoint 共用）——

export type BoardServer = Server<ClientToServerEvents, ServerToClientEvents, InterServerEvents, BoardSocketData>;
export type BoardNamespace = Namespace<ClientToServerEvents, ServerToClientEvents, InterServerEvents, BoardSocketData>;
export type BoardSocket = Socket<ClientToServerEvents, ServerToClientEvents, InterServerEvents, BoardSocketData>;
