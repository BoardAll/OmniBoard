/**
 * 投屏房间存储（cast 域；与白板 `BoardRoomStore` 并列、互不影响）。
 *
 * 复用面（不新建独立信令服务）：
 * - 同一 realtime 进程 / 端口 / Socket.IO 实例（仅多挂一个 `/cast` namespace）；
 * - 同一连接鉴权（token.ts：JWT HS256 / 非生产匿名回落）与审计 sink；
 * - 同一"房间 + 成员 + 定时清理"设计口径（见 roomStore.ts）。
 *
 * 隔离面（为什么不是 BoardRoomStore 的一个 type 字段）：
 * - BoardRoomStore 的 oplog / 软锁 / checkpoint / host 转移只对白板文档同步有意义，
 *   把投屏房间塞进去会让投屏状态进入白板清理与广播路径，违背「投屏不进入白板内容流程」；
 * - 因此 cast 使用**同构但独立**的存储：独立四位码空间、独立有效期与断线宽限，
 *   关闭投屏房间在物理上不可能触达白板房间（反之亦然）。
 *
 * 房间号规则：
 * - `'0000'`–`'9999'` 字符串（保留前导零，按字符串比较与传输）；
 * - 服务端用加密随机分配，冲突重试；活跃房间之间唯一；
 * - 房间关闭 / 过期 / 换码后旧号立即失效（map 删除 + `cast:roomClosed` 通知）。
 */

import { randomBytes, randomInt } from 'node:crypto';
import {
  CAST_CODE_PATTERN,
  DEFAULT_CAST_MAX_SENDERS,
  DEFAULT_CAST_ROOM_TTL_MS,
  DEFAULT_CAST_SENDER_GRACE_MS,
  DEFAULT_CAST_RECEIVER_GRACE_MS,
  DEFAULT_CAST_JOIN_ATTEMPT_LIMIT,
  DEFAULT_CAST_JOIN_ATTEMPT_WINDOW_MS,
  DEFAULT_CAST_JOIN_BLOCK_MS,
  CAST_MAX_SENDERS_LIMIT,
  CAST_ROOM_TTL_MAX_MS,
  CAST_ROOM_TTL_MIN_MS,
  type CastPeerLeftReason,
  type CastRoomClosedReason,
  type CastRoomSnapshot,
  type CastSenderSnapshot,
  type CastSenderState,
} from './castTypes.js';

/** 房间号随机分配最大重试次数（满 10000 间房时才会耗尽）。 */
const CODE_ALLOCATION_ATTEMPTS = 32;

/** 投屏房间名（房间级广播；与 `board:<id>` 命名空间隔离）。 */
export function castRoomName(code: string): string {
  return `cast:${code}`;
}

/** 接收端单播房间名（跨 socket 重连稳定）。 */
export function castReceiverRoom(code: string): string {
  return `cast-rx:${code}`;
}

/** 发送端单播房间名（按 senderId 稳定，重连后仍可寻址）。 */
export function castSenderRoom(code: string, senderId: string): string {
  return `cast-tx:${code}:${senderId}`;
}

export interface CastSenderRecord {
  senderId: string;
  senderToken: string;
  socketId: string;
  userId: string;
  deviceName: string;
  state: CastSenderState;
  joinedAt: number;
  acceptedAt: number | null;
  /** 已接受但 socket 离线（宽限期内保留席位）。 */
  reconnecting: boolean;
  graceTimer: NodeJS.Timeout | null;
}

export interface CastRoomRecord {
  readonly type: 'cast';
  code: string;
  receiverUserId: string;
  receiverSocketId: string;
  receiverToken: string;
  deviceName: string;
  createdAt: number;
  expiresAt: number;
  maxSenders: number;
  autoAccept: boolean;
  readonly senders: Map<string, CastSenderRecord>;
  expiryTimer: NodeJS.Timeout | null;
  receiverGraceTimer: NodeJS.Timeout | null;
  /** 接收端 socket 暂时离线（宽限期内可 resume）。 */
  receiverOnline: boolean;
}

export type CastCreateOutcome =
  | { ok: true; room: CastRoomRecord; snapshot: CastRoomSnapshot; receiverToken: string }
  | { ok: false; code: 'AlreadyInRoom' | 'CodeExhausted' };

export type CastJoinOutcome =
  | {
      ok: true;
      room: CastRoomRecord;
      sender: CastSenderRecord;
      snapshot: CastRoomSnapshot;
      accepted: boolean;
      senderToken: string;
    }
  | { ok: false; code: CastJoinFailureCode; message: string };

export type CastJoinFailureCode =
  | 'InvalidCode'
  | 'NotFound'
  | 'RoomClosed'
  | 'RoomFull'
  | 'ReceiverOffline'
  | 'TooManyAttempts'
  | 'AlreadyInRoom';

export interface CastUpdateOutcome {
  ok: boolean;
  code?: 'InvalidArgument' | 'ConnectionsExceedLimit' | 'NotFound';
  message?: string;
  snapshot?: CastRoomSnapshot;
}

export interface CastDecisionOutcome {
  ok: boolean;
  code?: 'NotFound' | 'NotReceiver' | 'SenderNotFound' | 'AlreadyDecided';
  message?: string;
  snapshot?: CastRoomSnapshot;
  sender?: CastSenderRecord;
}

export interface CastLeaveOutcome {
  ok: boolean;
  code?: 'NotFound' | 'NotReceiver' | 'SenderNotFound';
  message?: string;
  reason?: CastPeerLeftReason;
  snapshot?: CastRoomSnapshot;
  sender?: CastSenderRecord;
}

export interface CastStoreHandlers {
  /** 房间关闭（主动关闭 / 过期 / 接收端离线超时）：调用方负责通知各发送端。 */
  onRoomClosed?: (info: { code: string; reason: CastRoomClosedReason; senders: CastSenderSnapshot[] }) => void;
  /** 单路发送端移除（主动离开 / 被踢 / 离线超时）。 */
  onSenderRemoved?: (info: { code: string; senderId: string; reason: CastPeerLeftReason }) => void;
  /** 房间快照变化（接受 / 拒绝 / 更新设置 / 断线重连）。 */
  onRoomChanged?: (snapshot: CastRoomSnapshot) => void;
}

export interface CastRoomStoreOptions {
  /** 默认房间有效期（毫秒）。 */
  roomTtlMs?: number;
  /** 有效期裁剪下限（默认 CAST_ROOM_TTL_MIN_MS；私有部署 / 测试可放宽）。 */
  minRoomTtlMs?: number;
  /** 有效期裁剪上限（默认 CAST_ROOM_TTL_MAX_MS）。 */
  maxRoomTtlMs?: number;
  /** 接收端断线宽限（毫秒）。 */
  receiverGraceMs?: number;
  /** 发送端断线宽限（毫秒）。 */
  senderGraceMs?: number;
  /** 单房间最大路数上限（默认 4；UI 可选 1–4）。 */
  maxSendersLimit?: number;
  /** 错误房间号限流：窗口内失败次数上限。 */
  joinAttemptLimit?: number;
  joinAttemptWindowMs?: number;
  joinBlockMs?: number;
  /** 时钟注入（测试用）。 */
  now?: () => number;
}

interface AttemptWindow {
  windowStart: number;
  failures: number;
  blockedUntil: number;
}

/** 四位投屏房间存储（纯内存；无 socket 依赖，便于单测）。 */
export class CastRoomStore {
  private readonly rooms = new Map<string, CastRoomRecord>();
  private readonly receiverSockets = new Map<string, string>();
  private readonly senderSockets = new Map<string, { code: string; senderId: string }>();
  private readonly attempts = new Map<string, AttemptWindow>();
  private readonly roomTtlMs: number;
  private readonly minRoomTtlMs: number;
  private readonly maxRoomTtlMs: number;
  private readonly receiverGraceMs: number;
  private readonly senderGraceMs: number;
  private readonly maxSendersLimit: number;
  private readonly joinAttemptLimit: number;
  private readonly joinAttemptWindowMs: number;
  private readonly joinBlockMs: number;
  private readonly now: () => number;
  private handlers: CastStoreHandlers = {};

  constructor(options: CastRoomStoreOptions = {}) {
    this.roomTtlMs = options.roomTtlMs ?? DEFAULT_CAST_ROOM_TTL_MS;
    this.maxRoomTtlMs = Math.max(1, options.maxRoomTtlMs ?? CAST_ROOM_TTL_MAX_MS);
    this.minRoomTtlMs = clampNumber(options.minRoomTtlMs ?? CAST_ROOM_TTL_MIN_MS, 1, this.maxRoomTtlMs);
    this.receiverGraceMs = options.receiverGraceMs ?? DEFAULT_CAST_RECEIVER_GRACE_MS;
    this.senderGraceMs = options.senderGraceMs ?? DEFAULT_CAST_SENDER_GRACE_MS;
    this.maxSendersLimit = options.maxSendersLimit ?? CAST_MAX_SENDERS_LIMIT;
    this.joinAttemptLimit = options.joinAttemptLimit ?? DEFAULT_CAST_JOIN_ATTEMPT_LIMIT;
    this.joinAttemptWindowMs = options.joinAttemptWindowMs ?? DEFAULT_CAST_JOIN_ATTEMPT_WINDOW_MS;
    this.joinBlockMs = options.joinBlockMs ?? DEFAULT_CAST_JOIN_BLOCK_MS;
    this.now = options.now ?? (() => Date.now());
  }

  setHandlers(handlers: CastStoreHandlers): void {
    this.handlers = handlers;
  }

  /** 活跃房间数（测试 / 指标用）。 */
  get roomCount(): number {
    return this.rooms.size;
  }

  /** 取房间（不存在 → null）。 */
  roomOf(code: string): CastRoomRecord | null {
    return this.rooms.get(code) ?? null;
  }

  /** 校验并归一化四位房间号（`'0000'`–`'9999'`，非字符串 / 非四位数字 → null）。 */
  static normalizeCode(value: unknown): string | null {
    if (typeof value !== 'string') return null;
    const trimmed = value.trim();
    if (!CAST_CODE_PATTERN.test(trimmed)) return null;
    return trimmed;
  }

  /** 按 socketId 解析接收端房间（非接收端 → null）。 */
  receiverRoomOfSocket(socketId: string): CastRoomRecord | null {
    const code = this.receiverSockets.get(socketId);
    return code === undefined ? null : (this.rooms.get(code) ?? null);
  }

  /** 按 socketId 解析发送端会话（非发送端 → null）。 */
  senderOfSocket(socketId: string): { room: CastRoomRecord; sender: CastSenderRecord } | null {
    const entry = this.senderSockets.get(socketId);
    if (entry === undefined) return null;
    const room = this.rooms.get(entry.code);
    const sender = room?.senders.get(entry.senderId);
    if (!room || !sender) return null;
    return { room, sender };
  }

  /** 接收端是否在线（cast:join 前校验）。 */
  isReceiverOnline(code: string): boolean {
    const room = this.rooms.get(code);
    return room !== undefined && room.receiverOnline;
  }

  /** 创建投屏房间（一个 socket 同时只允许一个接收房间）。 */
  createRoom(input: {
    receiverUserId: string;
    receiverSocketId: string;
    deviceName?: string;
    maxSenders?: number;
    autoAccept?: boolean;
    ttlMs?: number;
  }): CastCreateOutcome {
    if (this.receiverSockets.has(input.receiverSocketId)) {
      return { ok: false, code: 'AlreadyInRoom' };
    }
    const code = this.allocateCode();
    if (code === null) return { ok: false, code: 'CodeExhausted' };
    const now = this.now();
    const ttlMs = clampNumber(input.ttlMs ?? this.roomTtlMs, this.minRoomTtlMs, this.maxRoomTtlMs);
    const room: CastRoomRecord = {
      type: 'cast',
      code,
      receiverUserId: input.receiverUserId,
      receiverSocketId: input.receiverSocketId,
      receiverToken: randomBytes(16).toString('hex'),
      deviceName: normalizeDeviceName(input.deviceName),
      createdAt: now,
      expiresAt: now + ttlMs,
      maxSenders: clampNumber(input.maxSenders ?? DEFAULT_CAST_MAX_SENDERS, 1, this.maxSendersLimit),
      autoAccept: input.autoAccept !== false,
      senders: new Map<string, CastSenderRecord>(),
      expiryTimer: null,
      receiverGraceTimer: null,
      receiverOnline: true,
    };
    this.rooms.set(code, room);
    this.receiverSockets.set(room.receiverSocketId, code);
    this.scheduleExpiry(room);
    return { ok: true, room, snapshot: this.snapshot(room), receiverToken: room.receiverToken };
  }

  /** 重新分配房间号（保留已接受的发送端；旧号立即失效）。 */
  rotateCode(receiverSocketId: string): { ok: true; room: CastRoomRecord; snapshot: CastRoomSnapshot } | { ok: false; code: string } {
    const room = this.receiverRoomOfSocket(receiverSocketId);
    if (!room) return { ok: false, code: 'NotFound' };
    const next = this.allocateCode();
    if (next === null) return { ok: false, code: 'CodeExhausted' };
    this.rooms.delete(room.code);
    room.code = next;
    this.rooms.set(next, room);
    this.receiverSockets.set(receiverSocketId, next);
    for (const sender of room.senders.values()) {
      const socketId = sender.socketId;
      if (socketId.length > 0) this.senderSockets.set(socketId, { code: next, senderId: sender.senderId });
    }
    this.rescheduleExpiry(room, this.roomTtlMs);
    return { ok: true, room, snapshot: this.snapshot(room) };
  }

  /** 关闭接收端房间（主动关闭）；返回被通知的发送端快照。 */
  closeByReceiver(receiverSocketId: string, reason: CastRoomClosedReason): CastRoomRecord | null {
    const room = this.receiverRoomOfSocket(receiverSocketId);
    if (!room) return null;
    this.closeRoom(room, reason);
    return room;
  }

  /** 更新房间设置（下调路数低于现有连接数时拒绝，避免静默断流）。 */
  updateSettings(
    receiverSocketId: string,
    patch: { maxSenders?: number; autoAccept?: boolean; extendTtlMs?: number },
  ): CastUpdateOutcome {
    const room = this.receiverRoomOfSocket(receiverSocketId);
    if (!room) return { ok: false, code: 'NotFound', message: 'cast room not found' };
    if (patch.maxSenders !== undefined) {
      if (!Number.isInteger(patch.maxSenders) || patch.maxSenders < 1 || patch.maxSenders > this.maxSendersLimit) {
        return { ok: false, code: 'InvalidArgument', message: `maxSenders must be 1..${this.maxSendersLimit}` };
      }
      const occupied = room.senders.size;
      if (patch.maxSenders < occupied) {
        return {
          ok: false,
          code: 'ConnectionsExceedLimit',
          message: `current connections (${occupied}) exceed new limit (${patch.maxSenders}); disconnect some senders first`,
        };
      }
      room.maxSenders = patch.maxSenders;
    }
    if (patch.autoAccept !== undefined) room.autoAccept = patch.autoAccept;
    if (patch.extendTtlMs !== undefined && Number.isFinite(patch.extendTtlMs)) {
      this.rescheduleExpiry(room, clampNumber(patch.extendTtlMs, this.minRoomTtlMs, this.maxRoomTtlMs));
    }
    const snapshot = this.snapshot(room);
    this.handlers.onRoomChanged?.(snapshot);
    return { ok: true, snapshot };
  }

  /** 续期（心跳）：从当前时刻重新计时。 */
  touch(receiverSocketId: string): number | null {
    const room = this.receiverRoomOfSocket(receiverSocketId);
    if (!room) return null;
    this.rescheduleExpiry(room, this.roomTtlMs);
    return room.expiresAt;
  }

  /** 限流：返回是否允许本次 join 尝试。 */
  joinAttemptAllowed(key: string): boolean {
    const now = this.now();
    const window = this.attempts.get(key);
    if (!window) return true;
    if (now < window.blockedUntil) return false;
    if (now - window.windowStart > this.joinAttemptWindowMs) {
      this.attempts.delete(key);
      return true;
    }
    return window.failures < this.joinAttemptLimit;
  }

  /** 记录一次失败的 join（触发限流）。 */
  noteJoinFailure(key: string): void {
    const now = this.now();
    const window = this.attempts.get(key);
    if (!window || now - window.windowStart > this.joinAttemptWindowMs) {
      this.attempts.set(key, { windowStart: now, failures: 1, blockedUntil: 0 });
      return;
    }
    window.failures += 1;
    if (window.failures >= this.joinAttemptLimit) {
      window.blockedUntil = now + this.joinBlockMs;
    }
  }

  /** 成功的 join 清空该 key 的失败计数。 */
  noteJoinSuccess(key: string): void {
    this.attempts.delete(key);
  }

  /** 发送端申请加入（autoAccept 时直接 accepted）。 */
  join(input: { code: string; socketId: string; userId: string; deviceName?: string }): CastJoinOutcome {
    const room = this.rooms.get(input.code);
    if (!room) return { ok: false, code: 'NotFound', message: '投屏码不存在或已失效' };
    if (!room.receiverOnline) {
      return { ok: false, code: 'ReceiverOffline', message: '接收端暂时离线，请稍后重试' };
    }
    if (this.senderSockets.has(input.socketId)) {
      return { ok: false, code: 'AlreadyInRoom', message: '当前连接已在投屏会话中' };
    }
    if (room.senders.size >= room.maxSenders) {
      return { ok: false, code: 'RoomFull', message: `已达到最大接收路数（${room.maxSenders}）` };
    }
    const now = this.now();
    const sender: CastSenderRecord = {
      senderId: newSenderId(),
      senderToken: randomBytes(16).toString('hex'),
      socketId: input.socketId,
      userId: input.userId,
      deviceName: normalizeDeviceName(input.deviceName),
      state: room.autoAccept ? 'accepted' : 'pending',
      joinedAt: now,
      acceptedAt: room.autoAccept ? now : null,
      reconnecting: false,
      graceTimer: null,
    };
    room.senders.set(sender.senderId, sender);
    this.senderSockets.set(input.socketId, { code: room.code, senderId: sender.senderId });
    const snapshot = this.snapshot(room);
    this.handlers.onRoomChanged?.(snapshot);
    return {
      ok: true,
      room,
      sender,
      snapshot,
      accepted: sender.state === 'accepted',
      senderToken: sender.senderToken,
    };
  }

  /** 接收端接受 / 拒绝某路投屏。 */
  decide(
    receiverSocketId: string,
    senderId: string,
    accept: boolean,
    reason?: string,
  ): CastDecisionOutcome {
    const room = this.receiverRoomOfSocket(receiverSocketId);
    if (!room) return { ok: false, code: 'NotFound', message: 'cast room not found' };
    const sender = room.senders.get(senderId);
    if (!sender) return { ok: false, code: 'SenderNotFound', message: 'sender not found' };
    if (sender.state === 'accepted' && accept) {
      return { ok: false, code: 'AlreadyDecided', message: 'sender already accepted' };
    }
    if (accept) {
      sender.state = 'accepted';
      sender.acceptedAt = this.now();
      const snapshot = this.snapshot(room);
      this.handlers.onRoomChanged?.(snapshot);
      return { ok: true, snapshot, sender };
    }
    // 拒绝：释放席位 + 通知发送端
    this.removeSender(room, sender, 'rejected');
    void reason;
    return { ok: true, snapshot: this.snapshot(room), sender };
  }

  /** 发送端主动离开；接收端可携带 senderId 踢出单路。 */
  leave(socketId: string, targetSenderId?: string, reason?: string): CastLeaveOutcome {
    const receiverRoom = this.receiverRoomOfSocket(socketId);
    if (receiverRoom) {
      if (!targetSenderId) return { ok: false, code: 'SenderNotFound', message: 'senderId is required' };
      const sender = receiverRoom.senders.get(targetSenderId);
      if (!sender) return { ok: false, code: 'SenderNotFound', message: 'sender not found' };
      const removed = this.removeSender(receiverRoom, sender, 'kicked');
      void reason;
      return { ok: true, snapshot: this.snapshot(receiverRoom), sender: removed };
    }
    const session = this.senderOfSocket(socketId);
    if (!session) return { ok: false, code: 'NotFound', message: 'not in a cast session' };
    const removed = this.removeSender(session.room, session.sender, 'left');
    return { ok: true, snapshot: this.snapshot(session.room), sender: removed };
  }

  /** 接收端断线：开启宽限（房间保留，拒绝新发送端加入）。 */
  receiverDisconnected(socketId: string): CastRoomRecord | null {
    const room = this.receiverRoomOfSocket(socketId);
    if (!room) return null;
    this.receiverSockets.delete(socketId);
    room.receiverOnline = false;
    room.receiverSocketId = '';
    if (room.receiverGraceTimer !== null) clearTimeout(room.receiverGraceTimer);
    room.receiverGraceTimer = setTimeout(() => {
      room.receiverGraceTimer = null;
      if (room.receiverOnline) return;
      this.closeRoom(room, 'receiver-left');
    }, this.receiverGraceMs);
    room.receiverGraceTimer.unref();
    this.handlers.onRoomChanged?.(this.snapshot(room));
    return room;
  }

  /** 接收端重连恢复（凭 code + receiverToken）。
   *  `enforceUserMatch`：JWT 身份下要求 userId 一致；匿名 dev 回落每次连接 userId 都会变，
   *  此时以 128-bit receiverToken 作为凭证（与 sender resume 同口径）。 */
  resumeReceiver(
    code: string,
    receiverToken: string,
    socketId: string,
    userId: string,
    enforceUserMatch = true,
  ): { ok: true; room: CastRoomRecord; snapshot: CastRoomSnapshot } | { ok: false; code: string; message: string } {
    const room = this.rooms.get(code);
    if (!room) return { ok: false, code: 'NotFound', message: '投屏码不存在或已失效' };
    if (room.receiverToken !== receiverToken || (enforceUserMatch && room.receiverUserId !== userId)) {
      return { ok: false, code: 'Forbidden', message: 'receiverToken 无效' };
    }
    if (room.receiverGraceTimer !== null) {
      clearTimeout(room.receiverGraceTimer);
      room.receiverGraceTimer = null;
    }
    // 旧 socket 仍登记时先解绑（同一接收端重连）。
    if (room.receiverSocketId.length > 0) this.receiverSockets.delete(room.receiverSocketId);
    room.receiverSocketId = socketId;
    room.receiverOnline = true;
    this.receiverSockets.set(socketId, room.code);
    const snapshot = this.snapshot(room);
    this.handlers.onRoomChanged?.(snapshot);
    return { ok: true, room, snapshot };
  }

  /** 发送端断线：开启宽限（席位保留；到期释放）。 */
  senderDisconnected(socketId: string): { room: CastRoomRecord; sender: CastSenderRecord } | null {
    const session = this.senderOfSocket(socketId);
    if (!session) return null;
    this.senderSockets.delete(socketId);
    session.sender.socketId = '';
    session.sender.reconnecting = true;
    if (session.sender.graceTimer !== null) clearTimeout(session.sender.graceTimer);
    session.sender.graceTimer = setTimeout(() => {
      session.sender.graceTimer = null;
      const room = this.rooms.get(session.room.code);
      const current = room?.senders.get(session.sender.senderId);
      if (!room || !current || !current.reconnecting) return;
      this.removeSender(room, current, 'disconnected');
    }, this.senderGraceMs);
    session.sender.graceTimer.unref();
    this.handlers.onRoomChanged?.(this.snapshot(session.room));
    return session;
  }

  /** 发送端重连恢复（凭 code + senderToken；身份策略同 resumeReceiver）。 */
  resumeSender(
    code: string,
    senderToken: string,
    socketId: string,
    userId: string,
    enforceUserMatch = true,
  ): { ok: true; room: CastRoomRecord; sender: CastSenderRecord } | { ok: false; code: string; message: string } {
    const room = this.rooms.get(code);
    if (!room) return { ok: false, code: 'NotFound', message: '投屏码不存在或已失效' };
    let target: CastSenderRecord | null = null;
    for (const sender of room.senders.values()) {
      if (sender.senderToken === senderToken && (!enforceUserMatch || sender.userId === userId)) {
        target = sender;
        break;
      }
    }
    if (!target) return { ok: false, code: 'Forbidden', message: 'senderToken 无效' };
    if (target.graceTimer !== null) {
      clearTimeout(target.graceTimer);
      target.graceTimer = null;
    }
    if (target.socketId.length > 0) this.senderSockets.delete(target.socketId);
    target.socketId = socketId;
    target.reconnecting = false;
    this.senderSockets.set(socketId, { code: room.code, senderId: target.senderId });
    this.handlers.onRoomChanged?.(this.snapshot(room));
    return { ok: true, room, sender: target };
  }

  /** 房间快照（发送端按加入顺序；token / socketId 不下发）。 */
  snapshot(room: CastRoomRecord): CastRoomSnapshot {
    return {
      type: 'cast',
      code: room.code,
      expiresAt: room.expiresAt,
      maxSenders: room.maxSenders,
      autoAccept: room.autoAccept,
      senders: [...room.senders.values()]
        .sort((a, b) => a.joinedAt - b.joinedAt)
        .map((sender) => this.senderSnapshot(sender)),
    };
  }

  senderSnapshot(sender: CastSenderRecord): CastSenderSnapshot {
    return {
      senderId: sender.senderId,
      userId: sender.userId,
      deviceName: sender.deviceName,
      state: sender.state,
      reconnecting: sender.reconnecting,
      joinedAt: sender.joinedAt,
      acceptedAt: sender.acceptedAt,
    };
  }

  /** 清理全部房间与定时器（服务关闭）。 */
  dispose(): void {
    for (const room of [...this.rooms.values()]) {
      this.clearRoomTimers(room);
    }
    this.rooms.clear();
    this.receiverSockets.clear();
    this.senderSockets.clear();
    this.attempts.clear();
  }

  // —— 内部 ——

  private allocateCode(): string | null {
    for (let attempt = 0; attempt < CODE_ALLOCATION_ATTEMPTS; attempt += 1) {
      const code = randomInt(0, 10_000).toString().padStart(4, '0');
      if (!this.rooms.has(code)) return code;
    }
    return null;
  }

  private removeSender(
    room: CastRoomRecord,
    sender: CastSenderRecord,
    reason: CastPeerLeftReason,
  ): CastSenderRecord {
    if (sender.graceTimer !== null) {
      clearTimeout(sender.graceTimer);
      sender.graceTimer = null;
    }
    if (sender.socketId.length > 0) this.senderSockets.delete(sender.socketId);
    room.senders.delete(sender.senderId);
    this.handlers.onSenderRemoved?.({ code: room.code, senderId: sender.senderId, reason });
    this.handlers.onRoomChanged?.(this.snapshot(room));
    return sender;
  }

  private closeRoom(room: CastRoomRecord, reason: CastRoomClosedReason): void {
    if (this.rooms.get(room.code) !== room) return;
    const senders = [...room.senders.values()].map((sender) => this.senderSnapshot(sender));
    for (const sender of room.senders.values()) {
      if (sender.graceTimer !== null) clearTimeout(sender.graceTimer);
      if (sender.socketId.length > 0) this.senderSockets.delete(sender.socketId);
    }
    room.senders.clear();
    this.clearRoomTimers(room);
    if (room.receiverSocketId.length > 0) this.receiverSockets.delete(room.receiverSocketId);
    this.rooms.delete(room.code);
    this.handlers.onRoomClosed?.({ code: room.code, reason, senders });
  }

  private clearRoomTimers(room: CastRoomRecord): void {
    if (room.expiryTimer !== null) {
      clearTimeout(room.expiryTimer);
      room.expiryTimer = null;
    }
    if (room.receiverGraceTimer !== null) {
      clearTimeout(room.receiverGraceTimer);
      room.receiverGraceTimer = null;
    }
  }

  private scheduleExpiry(room: CastRoomRecord): void {
    if (room.expiryTimer !== null) clearTimeout(room.expiryTimer);
    const delay = Math.max(1, room.expiresAt - this.now());
    room.expiryTimer = setTimeout(() => {
      room.expiryTimer = null;
      if (this.rooms.get(room.code) !== room) return;
      this.closeRoom(room, 'expired');
    }, delay);
    room.expiryTimer.unref();
  }

  private rescheduleExpiry(room: CastRoomRecord, ttlMs: number): void {
    room.expiresAt = this.now() + ttlMs;
    this.scheduleExpiry(room);
  }
}

function clampNumber(value: number, min: number, max: number): number {
  const rounded = Math.round(value);
  if (!Number.isFinite(rounded)) return min;
  return Math.min(max, Math.max(min, rounded));
}

function normalizeDeviceName(value: string | undefined): string {
  const trimmed = typeof value === 'string' ? value.trim() : '';
  if (trimmed.length === 0) return '未知设备';
  return trimmed.slice(0, 64);
}

/** 发送端标识（服务端分配；只用于关联某一路 PeerConnection）。 */
function newSenderId(): string {
  return `tx-${randomBytes(6).toString('hex')}`;
}
