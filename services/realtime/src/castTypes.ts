/**
 * 局域网投屏（cast）信令契约（T-Cast / 复用 realtime 服务）。
 *
 * 定位：
 * - cast 是**同一 realtime 服务**上的独立 namespace（`/cast`），与白板 `/board` 事件面完全隔离；
 * - 四位投屏码就是房间号（`'0000'`–`'9999'`，字符串、保留前导零）；
 * - 服务端只做房间/成员/信令路由与权限校验，**不转发媒体**（音视频走 WebRTC P2P）。
 *
 * 事件命名与载荷格式沿用 /board 既有风格（`域:动作`、成功 ack `{ok:true,...}`、
 * 失败 ack `{ok:false,error:{code,message}}`、服务端主动通知不带 ack）。
 *
 * 串线防护：发送端标识 `senderId` **只由服务端分配并在下行事件中权威回填**；
 * 客户端在 offer/answer/ice 中携带的 senderId 在发送端方向被忽略，在接收端方向
 * 必须命中本房间已接受的发送端，否则丢弃并回 `cast:error`。
 */

import type { Namespace, Server, Socket } from 'socket.io';

/** cast namespace（与 /board 同进程、同端口、同鉴权）。 */
export const CAST_NAMESPACE = '/cast';

/** 房间业务类型（与白板房间 `board:<id>` 显式区分）。 */
export type CastRoomType = 'cast';

/** 四位房间号正则（字符串，保留前导零）。 */
export const CAST_CODE_PATTERN = /^\d{4}$/;

/** 默认房间有效期：30 分钟（原型「投屏码有效期 30 分钟」）。 */
export const DEFAULT_CAST_ROOM_TTL_MS = 30 * 60 * 1000;

/** 有效期可选范围（客户端可配；服务端裁剪）。 */
export const CAST_ROOM_TTL_MIN_MS = 60 * 1000;
export const CAST_ROOM_TTL_MAX_MS = 2 * 60 * 60 * 1000;

/** 最大并发接收路数（原型：1/2/3/4，默认 4）。 */
export const CAST_MAX_SENDERS_LIMIT = 4;
export const DEFAULT_CAST_MAX_SENDERS = 4;

/** 接收端断线宽限（保留房间与发送端，允许同 token 重连恢复）。 */
export const DEFAULT_CAST_RECEIVER_GRACE_MS = 30_000;

/** 发送端断线宽限（保留席位，允许重连恢复；到期释放席位）。 */
export const DEFAULT_CAST_SENDER_GRACE_MS = 15_000;

/** 错误房间号尝试限流：窗口内失败次数上限。 */
export const DEFAULT_CAST_JOIN_ATTEMPT_LIMIT = 8;
export const DEFAULT_CAST_JOIN_ATTEMPT_WINDOW_MS = 60_000;
export const DEFAULT_CAST_JOIN_BLOCK_MS = 60_000;

/** 发送端连接状态（服务端视角）。 */
export type CastSenderState = 'pending' | 'accepted';

/** 发送端快照（下发给接收端 / 发送端；不含 token）。 */
export interface CastSenderSnapshot {
  senderId: string;
  userId: string;
  deviceName: string;
  state: CastSenderState;
  /** 已接受但 socket 暂时离线（宽限期）。 */
  reconnecting: boolean;
  joinedAt: number;
  acceptedAt: number | null;
}

/** 房间快照（`cast:room` 与 create/update/status 的 ack 共用）。 */
export interface CastRoomSnapshot {
  type: CastRoomType;
  code: string;
  expiresAt: number;
  maxSenders: number;
  autoAccept: boolean;
  senders: CastSenderSnapshot[];
}

/** 失败回执（沿用 /board 错误信封）。 */
export interface CastAckFailure {
  ok: false;
  error: { code: string; message: string };
}

export interface CastCreatePayload {
  maxSenders?: number;
  autoAccept?: boolean;
  /** 有效期（毫秒；服务端裁剪到 [1min, 2h]）。 */
  ttlMs?: number;
  /** 接收端设备名（展示给发送端用，可空）。 */
  deviceName?: string;
}

export type CastCreateAck =
  | {
      ok: true;
      room: CastRoomSnapshot;
      /** 接收端恢复凭据（断线重连续用；仅本次回执下发）。 */
      receiverToken: string;
    }
  | CastAckFailure;

export interface CastResumePayload {
  code?: string;
  receiverToken?: string;
  /** 发送端恢复凭据（与 code 二选一使用）。 */
  senderToken?: string;
}

export type CastResumeAck =
  | {
      ok: true;
      role: 'receiver';
      room: CastRoomSnapshot;
    }
  | {
      ok: true;
      role: 'sender';
      code: string;
      senderId: string;
      state: CastSenderState;
      maxSenders: number;
      autoAccept: boolean;
    }
  | CastAckFailure;

export interface CastUpdatePayload {
  maxSenders?: number;
  autoAccept?: boolean;
  extendTtlMs?: number;
}

export type CastUpdateAck = { ok: true; room: CastRoomSnapshot } | CastAckFailure;

export type CastEmptyPayload = Record<string, never>;

export type CastCloseAck = { ok: true } | CastAckFailure;

export interface CastStatusPayload {
  code?: string;
  senderToken?: string;
}

export type CastStatusAck =
  | { ok: true; room: CastRoomSnapshot; senderId?: string; state?: CastSenderState }
  | CastAckFailure;

export interface CastJoinPayload {
  code?: string;
  deviceName?: string;
}

export type CastJoinAck =
  | {
      ok: true;
      /** accepted=true：已直接纳入（autoAccept）；false：等待接收端确认。 */
      accepted: boolean;
      code: string;
      senderId: string;
      senderToken: string;
      maxSenders: number;
      expiresAt: number;
    }
  | CastAckFailure;

export interface CastDecisionPayload {
  senderId?: string;
  accept?: boolean;
  reason?: string;
}

export type CastDecisionAck = { ok: true; room: CastRoomSnapshot } | CastAckFailure;

export interface CastLeavePayload {
  /** 发送端省略（离开自己）；接收端携带 senderId（踢出该路）。 */
  senderId?: string;
  reason?: string;
}

export type CastLeaveAck = { ok: true; room?: CastRoomSnapshot } | CastAckFailure;

/** SDP 信令（offer / answer 共用）。 */
export interface CastSdpPayload {
  /** 接收端 → 服务端必填；发送端 → 服务端忽略（服务端权威回填）。 */
  senderId?: string;
  sdp?: string;
}

export interface CastIcePayload {
  senderId?: string;
  candidate?: Record<string, unknown> | null;
}

/** 下行 SDP（带服务端回填的 senderId）。 */
export interface CastSdpOutPayload {
  senderId: string;
  sdp: string;
}

/** 下行 ICE（带服务端回填的 senderId；null 表示候选结束）。 */
export interface CastIceOutPayload {
  senderId: string;
  candidate: Record<string, unknown> | null;
}

export type CastHeartbeatAck = { ok: true; expiresAt: number } | CastAckFailure;

export type CastPeerLeftReason = 'left' | 'kicked' | 'disconnected' | 'rejected';
export type CastRoomClosedReason = 'closed' | 'expired' | 'receiver-left' | 'regenerated';

/** C→S 事件。 */
export interface CastClientToServerEvents {
  'cast:create': (payload: CastCreatePayload | undefined, ack?: (response: CastCreateAck) => void) => void;
  'cast:resume': (payload: CastResumePayload | undefined, ack?: (response: CastResumeAck) => void) => void;
  'cast:update': (payload: CastUpdatePayload | undefined, ack?: (response: CastUpdateAck) => void) => void;
  'cast:regenerate': (payload: CastEmptyPayload | undefined, ack?: (response: CastCreateAck) => void) => void;
  'cast:close': (payload: CastEmptyPayload | undefined, ack?: (response: CastCloseAck) => void) => void;
  'cast:status': (payload: CastStatusPayload | undefined, ack?: (response: CastStatusAck) => void) => void;
  'cast:join': (payload: CastJoinPayload | undefined, ack?: (response: CastJoinAck) => void) => void;
  'cast:decision': (payload: CastDecisionPayload | undefined, ack?: (response: CastDecisionAck) => void) => void;
  'cast:leave': (payload: CastLeavePayload | undefined, ack?: (response: CastLeaveAck) => void) => void;
  'cast:offer': (payload: CastSdpPayload | undefined) => void;
  'cast:answer': (payload: CastSdpPayload | undefined) => void;
  'cast:ice': (payload: CastIcePayload | undefined) => void;
  'cast:heartbeat': (payload: CastEmptyPayload | undefined, ack?: (response: CastHeartbeatAck) => void) => void;
}

/** S→C 事件。 */
export interface CastServerToClientEvents {
  'cast:session': (payload: { userId: string; role: 'receiver' | 'sender' | null }) => void;
  'cast:room': (payload: CastRoomSnapshot) => void;
  'cast:request': (payload: { senderId: string; userId: string; deviceName: string; at: number }) => void;
  'cast:accepted': (payload: { senderId: string; code: string }) => void;
  'cast:rejected': (payload: { senderId: string; reason: string }) => void;
  'cast:offer': (payload: CastSdpOutPayload) => void;
  'cast:answer': (payload: CastSdpOutPayload) => void;
  'cast:ice': (payload: CastIceOutPayload) => void;
  'cast:peerLeft': (payload: { senderId: string; reason: CastPeerLeftReason }) => void;
  'cast:roomClosed': (payload: { code: string; reason: CastRoomClosedReason }) => void;
  'cast:error': (payload: { code: string; message: string }) => void;
}

/** 每个连接的 cast 会话数据（鉴权中间件写入）。 */
export interface CastSocketData {
  userId: string;
  authMode: 'jwt' | 'anonymous';
  /** 当前角色（服务端内部标识；不用于权限判定的事实来源）。 */
  role: 'receiver' | 'sender' | null;
}

export interface InterServerEvents {
  // 预留：水平扩展时使用
}

export type CastServer = Server<CastClientToServerEvents, CastServerToClientEvents, InterServerEvents, CastSocketData>;
export type CastNamespace = Namespace<
  CastClientToServerEvents,
  CastServerToClientEvents,
  InterServerEvents,
  CastSocketData
>;
export type CastSocket = Socket<CastClientToServerEvents, CastServerToClientEvents, InterServerEvents, CastSocketData>;
