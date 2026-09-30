/**
 * realtime 服务共享类型（M1 完整版 / T1.3）。
 *
 * 事件契约对齐《互动白板实时协同设计文档》§6（M1 权威契约）与 §7（服务端设计）。
 *
 * M1 实现事件集：
 *   C→S：board:join / board:joinAck / board:ops / board:fetchOps / board:leave / board:ping；
 *   S→C：board:joined / board:ops / board:participants / room:error。
 * 事件名已冻结、留待 M2/M3 实现（本阶段不建类型、不写实现与测试）：
 *   presence:cursor / presence:selection / presence:page / presence:viewport / presence:preview；
 *   lock:acquire / lock:release / lock:renew / lock:changed；
 *   interactive:raiseHand / interactive:lowerHand / interactive:grantControl /
 *   interactive:revokeControl / interactive:modeChanged / interactive:roleChanged /
 *   interactive:hostChanged；room:removed。
 * M0 POC 兼容层（保留，非 §6 契约；12-app-web POC 与既有用例依赖）：
 *   board:session / board:echo / board:broadcast / board:direct / board:directed。
 */

/** 房间角色（§5.1，沿用 InteractiveRole）。 */
export type BoardRole = 'Host' | 'CoHost' | 'Presenter' | 'Participant' | 'Viewer' | 'Guest';

/** 全部合法房间角色（token role claim 白名单）。 */
export const BOARD_ROLES: readonly BoardRole[] = ['Host', 'CoHost', 'Presenter', 'Participant', 'Viewer', 'Guest'];

/** 缺省房间角色（M1：token 未携带合法 role 时回落；匿名 dev 同样使用）。 */
export const DEFAULT_BOARD_ROLE: BoardRole = 'Participant';

/** 可写角色（§5.1：Host/CoHost/Presenter/Participant ≥ Write；Viewer 只读；Guest 按签发，M1 取保守只读）。 */
const WRITE_ROLES: readonly BoardRole[] = ['Host', 'CoHost', 'Presenter', 'Participant'];

export function roleCanWrite(role: BoardRole): boolean {
  return WRITE_ROLES.includes(role);
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
}

/** 版本水位：每 actor 最大连续 seq（§5.3 stateVector / §5.12 lastSeenVersion）。 */
export interface BoardStateVector {
  [actor: string]: number;
}

/** `board:join` 载荷（§6：`{boardId, pageId?, lastSeenVersion?}`）。 */
export interface BoardJoinPayload {
  boardId: string;
  pageId?: string;
  /** 重连场景携带（§5.12）；提供时服务端在 join 后立即回放其后增量。 */
  lastSeenVersion?: BoardStateVector;
}

/** `board:joined` 载荷（§6；snapshot 为 M3+ checkpoint 预留，M1 不产生）。 */
export interface BoardJoinedPayload {
  boardId: string;
  participants: ParticipantInfo[];
  role: BoardRole;
  mode: 'free';
  /** 锁会话态（§5.6；M2 实现，M1 恒为 []）。 */
  locks: unknown[];
  stateVector: BoardStateVector;
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

/** `board:participants` 载荷（§6：`{joined?/left?/updated?}`；updated 供 M3 角色变更使用）。 */
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

/** C→S 事件（M1 全量 + M0 POC 兼容层）。 */
export interface ClientToServerEvents {
  'board:join': (payload: BoardJoinPayload, ack?: (response: BoardJoinAck) => void) => void;
  'board:joinAck': (payload: BoardJoinAckPayload, ack?: (response: BoardJoinAckResponse) => void) => void;
  'board:ops': (payload: Op[], ack?: (response: BoardOpsAck) => void) => void;
  'board:fetchOps': (payload: BoardFetchOpsPayload, ack?: (response: BoardFetchOpsResponse) => void) => void;
  'board:leave': (payload: BoardLeavePayload, ack?: (response: BoardLeaveAck) => void) => void;
  'board:ping': (payload: BoardPingPayload, ack?: (response: BoardPingAck) => void) => void;
  // —— M0 POC 兼容层（非 §6 契约，保留用于链路自检）——
  'board:echo': (payload: BoardEchoPayload, ack?: (response: BoardEchoAck) => void) => void;
  'board:direct': (payload: BoardDirectPayload, ack?: (response: BoardDirectAck) => void) => void;
}

/** S→C 事件（M1 全量 + M0 POC 兼容层）。 */
export interface ServerToClientEvents {
  'board:session': (payload: BoardSessionPayload) => void;
  'board:joined': (payload: BoardJoinedPayload) => void;
  'board:ops': (ops: Op[], meta?: BoardOpsMeta) => void;
  'board:participants': (payload: BoardParticipantsPayload) => void;
  'room:error': (payload: RoomErrorPayload) => void;
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
  role: BoardRole;
  boardId?: string;
}
