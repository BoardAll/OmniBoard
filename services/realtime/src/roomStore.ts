/**
 * 房间存储（M3-T3.1/T3.5 拆分自 rooms.ts 的存储层；《互动白板实时协同设计文档》§5.1 / §5.6 / §5.14 / §7）。
 *
 * 职责（纯内存态，无 socket 依赖）：
 * - 参与者表（userId/socketId/role/joinedAt；M3 扩展 grantedWrite/handRaised）；
 * - op 环形日志与版本水位；软锁表；空房自动清理（§5.14）；
 * - M3 模式与权限（§5.10：mode/presenterId；grantedWrite/handRaised；session role 变更）；
 * - M3 checkpoint 存储（§7：只存不解释）与触发计数（阈值 / inflight 去抖 / 超时放弃）；
 * - M3 host 转移窗口（§5.14：Host 断连记录 + 定时器；同 userId 回归取消）。
 *
 * 回调（由 namespace 层注入，store 不直接发事件 / 落审计）：
 * - onDestroy：空房 TTL 到期销毁（审计 room.cleanup 由 server 装配注入）；
 * - onLockExpired：软锁超时（广播 lock:changed + 审计由 rooms.ts 注入）；
 * - onHostTransferExpired：host 转移窗口到期（事件与审计由 interactive.ts 注入）。
 *
 * 入站 op 计数口径（M3 契约 F/G）：仅统计**被接受并入日志**的 op（重复 / 断档 / 非法不入账），
 * 用于 checkpoint 触发与 ops 采样审计。
 */

import { DEFAULT_OPLOG_CAPACITY, OpLog } from './oplog.js';
import {
  roleCanWrite,
  type BoardCheckpointRecord,
  type BoardLockSnapshot,
  type BoardMode,
  type BoardRole,
  type BoardStateVector,
  type ParticipantInfo,
} from './types.js';

/** 空房保留期（§5.14：最后一人离开后保留 10min，防抖动重连）。 */
export const DEFAULT_ROOM_TTL_MS = 10 * 60 * 1000;

/** 软锁 TTL（§5.6 / M2 决策 D2-C：30s；客户端每 10s 心跳 lock:renew 续约）。 */
export const DEFAULT_LOCK_TTL_MS = 30_000;

/** 超时锁扫描间隔（惰性检查之外的第二道兜底；测试可缩短）。 */
export const DEFAULT_LOCK_SWEEP_INTERVAL_MS = 1_000;

/** host 转移窗口（§5.14）：默认 0 = 退出立即移交（房主自举）；WB_HOST_TRANSFER_MS 可配正数做防抖。 */
export const DEFAULT_HOST_TRANSFER_MS = 0;

/** checkpoint 触发阈值（M3 契约 F：自上次 checkpoint 起累计入站 op ≥ 阈值触发；WB_CHECKPOINT_OP_THRESHOLD 可配）。 */
export const DEFAULT_CHECKPOINT_OP_THRESHOLD = 500;

/** checkpoint 请求超时（M3 契约 F：15s 超时放弃，等下次 op 批再次触发；WB_CHECKPOINT_TIMEOUT_MS 可配）。 */
export const DEFAULT_CHECKPOINT_TIMEOUT_MS = 15_000;

/** checkpoint payload 上限（M3 契约 F：10MB；WB_CHECKPOINT_MAX_PAYLOAD_BYTES 可配）。 */
export const DEFAULT_CHECKPOINT_MAX_PAYLOAD_BYTES = 10 * 1024 * 1024;

/** ops 采样审计间隔（M3 契约 G：每 32 条入站 op 落 1 条 ops.sampled）。 */
export const OPS_AUDIT_SAMPLE_INTERVAL = 32;

/** 白板房间名（一个白板一个房间，§5.1）。 */
export function boardRoom(boardId: string): string {
  return `board:${boardId}`;
}

/** 跨会话单播房间名（socket.id 重连会变，§6）。 */
export function userRoom(userId: string): string {
  return `user:${userId}`;
}

export interface RoomDestroyInfo {
  opsDropped: number;
}

/** 锁记录（§5.6；软锁仅存服务端内存，board:joined / lock:changed 仅暴露 userId 与 expiresAt）。 */
export interface LockRecord {
  userId: string;
  socketId: string;
  /** epoch 毫秒。 */
  expiresAt: number;
}

/** `acquireLock` 结果：授予（含 TTL 与是否刷新）/ 他人占用（单播拒绝回执）/ 房间不存在。 */
export type AcquireLockOutcome =
  | { result: 'granted'; expiresAt: number; refreshed: boolean }
  | { result: 'busy'; holderUserId: string }
  | { result: 'no-room' };

/** `releaseLock` 结果。 */
export type ReleaseLockOutcome = { result: 'released'; lock: LockRecord } | { result: 'not-holder' };

/** `renewLock` 结果。 */
export type RenewLockOutcome = { result: 'renewed'; expiresAt: number } | { result: 'not-holder' };

export interface BoardRoomStoreOptions {
  /** 环形日志容量（默认 10k，§10）；测试可缩小。 */
  oplogCapacity?: number;
  /** 空房保留期（默认 10min，§5.14）；测试可缩短。 */
  roomTtlMs?: number;
  /** 软锁 TTL（默认 30s，§5.6 / D2-C）；测试可缩短。 */
  lockTtlMs?: number;
  /** 超时锁扫描间隔（默认 1s）；测试可缩短。 */
  lockSweepIntervalMs?: number;
  /** host 转移窗口（默认 0=退出立即移交，§5.14）；测试可配。 */
  hostTransferMs?: number;
  /** checkpoint 触发阈值（默认 500）；测试可缩小。 */
  checkpointOpThreshold?: number;
  /** checkpoint 请求超时（默认 15s）；测试可缩短。 */
  checkpointTimeoutMs?: number;
  /** checkpoint payload 上限（默认 10MB）；测试可缩小。 */
  checkpointMaxPayloadBytes?: number;
  onDestroy?: (boardId: string, info: RoomDestroyInfo) => void;
}

interface RoomState {
  readonly boardId: string;
  /** socketId → 参与者。 */
  readonly participants: Map<string, ParticipantInfo>;
  /** elementId → 软锁（§5.6）。 */
  readonly locks: Map<string, LockRecord>;
  readonly oplog: OpLog;
  cleanupTimer: NodeJS.Timeout | null;
  /** M3：房间模式（§5.10）。 */
  mode: BoardMode;
  /** M3：present 态演示者 userId（free 态 null）。 */
  presenterId: string | null;
  /** M3：checkpoint（§7：只存不解释；payload 为客户端上传字符串原文）。 */
  checkpoint: BoardCheckpointRecord | null;
  /** M3：自上次 checkpoint 起累计入站（已接受）op 数。 */
  opsSinceCheckpoint: number;
  /** M3：checkpoint 请求 inflight（去抖；超时清空，等待下次 op 批重试）。 */
  checkpointInflight: { userId: string; timer: NodeJS.Timeout } | null;
  /** M3：ops 采样审计计数（每 32 条入站 op 落 1 条）。 */
  opsSinceSample: number;
  /** M3：host 转移窗口（Host 断连记录 + 定时器；同 userId 回归取消）。 */
  hostTransfer: { userId: string; timer: NodeJS.Timeout } | null;
}

/** 房间存储：参与者 / op 日志 / 水位 / 软锁 / 模式 / checkpoint / host 转移 / 空房清理。 */
export class BoardRoomStore {
  private readonly rooms = new Map<string, RoomState>();
  private readonly oplogCapacity: number;
  private readonly roomTtlMs: number;
  private readonly lockTtlMs: number;
  private readonly hostTransferMs: number;
  private readonly checkpointOpThreshold: number;
  private readonly checkpointTimeoutMs: number;
  private readonly checkpointMaxPayloadBytes: number;
  private readonly lockSweepTimer: NodeJS.Timeout;
  private readonly onDestroy: ((boardId: string, info: RoomDestroyInfo) => void) | undefined;
  private onLockExpired: ((boardId: string, elementId: string, lock: LockRecord) => void) | undefined;
  private onHostTransferExpired: ((boardId: string, pendingUserId: string) => void) | undefined;

  constructor(options: BoardRoomStoreOptions = {}) {
    this.oplogCapacity = options.oplogCapacity ?? DEFAULT_OPLOG_CAPACITY;
    this.roomTtlMs = options.roomTtlMs ?? DEFAULT_ROOM_TTL_MS;
    this.lockTtlMs = options.lockTtlMs ?? DEFAULT_LOCK_TTL_MS;
    this.hostTransferMs = options.hostTransferMs ?? DEFAULT_HOST_TRANSFER_MS;
    this.checkpointOpThreshold = options.checkpointOpThreshold ?? DEFAULT_CHECKPOINT_OP_THRESHOLD;
    this.checkpointTimeoutMs = options.checkpointTimeoutMs ?? DEFAULT_CHECKPOINT_TIMEOUT_MS;
    this.checkpointMaxPayloadBytes = options.checkpointMaxPayloadBytes ?? DEFAULT_CHECKPOINT_MAX_PAYLOAD_BYTES;
    this.onDestroy = options.onDestroy;
    // 超时锁兜底扫描（unref：不阻塞进程退出）；惰性检查见 expireStaleLock。
    this.lockSweepTimer = setInterval(
      () => this.sweepExpiredLocks(Date.now()),
      options.lockSweepIntervalMs ?? DEFAULT_LOCK_SWEEP_INTERVAL_MS,
    );
    this.lockSweepTimer.unref();
  }

  /** 当前房间数（测试断言清理用）。 */
  get roomCount(): number {
    return this.rooms.size;
  }

  /** checkpoint 触发阈值（审计 detail 元数据用）。 */
  get checkpointThreshold(): number {
    return this.checkpointOpThreshold;
  }

  /** checkpoint payload 上限（字节；上传校验用）。 */
  get checkpointPayloadLimit(): number {
    return this.checkpointMaxPayloadBytes;
  }

  /** host 转移窗口（毫秒；审计 detail 元数据用）。 */
  get hostTransferWindowMs(): number {
    return this.hostTransferMs;
  }

  /** 加入 / 刷新参与者；取消待清理定时器与同用户 host 转移窗口（§5.14：同 userId 回归取消）。 */
  join(boardId: string, participant: ParticipantInfo): { isNew: boolean } {
    const room = this.getOrCreate(boardId);
    this.cancelCleanup(room);
    this.cancelHostTransfer(boardId, participant.userId);
    const isNew = !room.participants.has(participant.socketId);
    room.participants.set(participant.socketId, participant);
    return { isNew };
  }

  /** 移除参与者；空房启动清理倒计时；返回被移除的参与者。 */
  leave(boardId: string, socketId: string): ParticipantInfo | null {
    const room = this.rooms.get(boardId);
    if (!room) return null;
    const participant = room.participants.get(socketId) ?? null;
    if (participant) room.participants.delete(socketId);
    if (room.participants.size === 0) this.scheduleCleanup(room);
    return participant;
  }

  /** 参与者快照（插入序）。 */
  participants(boardId: string): ParticipantInfo[] {
    const room = this.rooms.get(boardId);
    return room ? [...room.participants.values()] : [];
  }

  /** 按 socketId 取参与者（权限判定事实来源）。 */
  participant(boardId: string, socketId: string): ParticipantInfo | null {
    return this.rooms.get(boardId)?.participants.get(socketId) ?? null;
  }

  /** 按 userId 取全部连接（M3：目标定位 / 单播前校验「在房」）。 */
  participantsForUser(boardId: string, userId: string): ParticipantInfo[] {
    const room = this.rooms.get(boardId);
    if (!room) return [];
    const out: ParticipantInfo[] = [];
    for (const participant of room.participants.values()) {
      if (participant.userId === userId) out.push(participant);
    }
    return out;
  }

  /** 版本水位快照。 */
  stateVector(boardId: string): BoardStateVector {
    return this.rooms.get(boardId)?.oplog.stateVector() ?? {};
  }

  /** 房间 op 日志（不存在返回 null）。 */
  oplog(boardId: string): OpLog | null {
    return this.rooms.get(boardId)?.oplog ?? null;
  }

  // —— M3：模式与权限（§5.10 / T3.1）——

  /** 房间模式（不存在返回 null）。 */
  roomMode(boardId: string): BoardMode | null {
    return this.rooms.get(boardId)?.mode ?? null;
  }

  /** present 态演示者 userId；free / 房间不存在 → null（board:joined.presenterId 用）。 */
  presenterIdOf(boardId: string): string | null {
    const room = this.rooms.get(boardId);
    if (!room || room.mode !== 'present') return null;
    return room.presenterId;
  }

  /** 房间是否存在在线 Host（§5.14；exceptUserId 用于同用户多端豁免）。 */
  hasOnlineHost(boardId: string, exceptUserId?: string): boolean {
    const room = this.rooms.get(boardId);
    if (!room) return false;
    for (const participant of room.participants.values()) {
      if (participant.role === 'Host' && participant.userId !== exceptUserId) return true;
    }
    return false;
  }

  /** 进入 present 模式（presenterId 为发起者，§5.10）。 */
  setPresenting(boardId: string, presenterId: string): boolean {
    const room = this.rooms.get(boardId);
    if (!room) return false;
    room.mode = 'present';
    room.presenterId = presenterId;
    return true;
  }

  /** 退出 present 模式（恢复 free，§5.10）。 */
  stopPresenting(boardId: string): boolean {
    const room = this.rooms.get(boardId);
    if (!room) return false;
    room.mode = 'free';
    room.presenterId = null;
    return true;
  }

  /** 置 / 清举手状态；返回更新后的参与者与是否发生变更（房间 / 参与者不存在 → null）。 */
  setHandRaised(
    boardId: string,
    socketId: string,
    raised: boolean,
  ): { participant: ParticipantInfo; changed: boolean } | null {
    const room = this.rooms.get(boardId);
    const participant = room?.participants.get(socketId);
    if (!room || !participant) return null;
    const changed = participant.handRaised !== raised;
    participant.handRaised = raised;
    return { participant, changed };
  }

  /** 置 / 清临时写权（同一 userId 的全部连接）；返回更新后的参与者列表（无匹配 → []）。 */
  setGrantedWrite(boardId: string, userId: string, granted: boolean): ParticipantInfo[] {
    const room = this.rooms.get(boardId);
    if (!room) return [];
    const updated: ParticipantInfo[] = [];
    for (const participant of room.participants.values()) {
      if (participant.userId !== userId) continue;
      participant.grantedWrite = granted;
      updated.push(participant);
    }
    return updated;
  }

  /** 变更会话角色（同一 userId 的全部连接；host 移交 / join 冲突降级用）；返回更新后的参与者列表。 */
  setUserRole(boardId: string, userId: string, role: BoardRole): ParticipantInfo[] {
    const room = this.rooms.get(boardId);
    if (!room) return [];
    const updated: ParticipantInfo[] = [];
    for (const participant of room.participants.values()) {
      if (participant.userId !== userId) continue;
      participant.role = role;
      updated.push(participant);
    }
    return updated;
  }

  /**
   * host 移交候选（§5.14）：最早加入的 CoHost；无则最早加入的可写角色（Presenter/Participant）。
   * 无房 / 无候选（仅 Viewer/Guest）→ null。
   */
  earliestHostCandidate(boardId: string): ParticipantInfo | null {
    const room = this.rooms.get(boardId);
    if (!room) return null;
    let coHost: ParticipantInfo | null = null;
    let writable: ParticipantInfo | null = null;
    for (const participant of room.participants.values()) {
      if (participant.role === 'CoHost' && isEarlierThan(participant, coHost)) coHost = participant;
      if (roleCanWrite(participant.role) && isEarlierThan(participant, writable)) writable = participant;
    }
    return coHost ?? writable;
  }

  // —— M3：checkpoint（§7 / T3.5）——

  /**
   * 入站（已接受）op 计账：累计 checkpoint 触发计数 + ops 采样计数。
   * 返回本次应落的采样审计条数与是否达到 checkpoint 阈值。
   */
  noteAcceptedOps(boardId: string, count: number): { samples: number; checkpointDue: boolean } {
    const room = this.rooms.get(boardId);
    if (!room || count <= 0) return { samples: 0, checkpointDue: false };
    room.opsSinceCheckpoint += count;
    room.opsSinceSample += count;
    const samples = Math.floor(room.opsSinceSample / OPS_AUDIT_SAMPLE_INTERVAL);
    if (samples > 0) room.opsSinceSample -= samples * OPS_AUDIT_SAMPLE_INTERVAL;
    return { samples, checkpointDue: room.opsSinceCheckpoint >= this.checkpointOpThreshold };
  }

  /**
   * 触发 checkpoint 请求（inflight 去抖；阈值未达 / 无候选 → null）。
   *
   * 候选选择（契约 F）：在房 role ∈ {Host, CoHost} 且 joinedAt 最早者。
   * ⚠ 偏差登记：§7 原文为「水位最高且角色 ≥ CoHost 的在线客户端」；服务端不跟踪每客户端水位，
   * 以「最早加入的 Host/CoHost」近似（长会话中通常即水位领先者）。待客户端上报递增水位后收窄。
   *
   * 超时（默认 15s）仅清除 inflight，不清计数 —— 后续 op 批到达时按当前水位再次触发（重试语义）。
   */
  beginCheckpointRequestIfDue(boardId: string): { userId: string; stateVector: BoardStateVector } | null {
    const room = this.rooms.get(boardId);
    if (!room) return null;
    if (room.checkpointInflight !== null) return null;
    if (room.opsSinceCheckpoint < this.checkpointOpThreshold) return null;
    let candidate: ParticipantInfo | null = null;
    for (const participant of room.participants.values()) {
      if (participant.role !== 'Host' && participant.role !== 'CoHost') continue;
      if (candidate === null || participant.joinedAt < candidate.joinedAt) candidate = participant;
    }
    if (candidate === null) return null;
    const timer = setTimeout(() => {
      if (room.checkpointInflight?.timer === timer) room.checkpointInflight = null;
    }, this.checkpointTimeoutMs);
    timer.unref();
    room.checkpointInflight = { userId: candidate.userId, timer };
    return { userId: candidate.userId, stateVector: room.oplog.stateVector() };
  }

  /** 存储 checkpoint（只存不解释；重置触发计数并清除 inflight）。房间不存在 → false。 */
  storeCheckpoint(boardId: string, record: BoardCheckpointRecord): boolean {
    const room = this.rooms.get(boardId);
    if (!room) return false;
    room.checkpoint = record;
    room.opsSinceCheckpoint = 0;
    this.clearCheckpointInflight(room);
    return true;
  }

  /** 读取 checkpoint（不存在返回 null；调用方自行决定是否下发）。 */
  checkpointOf(boardId: string): BoardCheckpointRecord | null {
    return this.rooms.get(boardId)?.checkpoint ?? null;
  }

  // —— M3：host 转移窗口（§5.14）——

  /** 注册 host 转移到期回调（interactive.ts 注入：事件广播 + 审计）。 */
  setHostTransferExpiredHandler(handler: (boardId: string, pendingUserId: string) => void): void {
    this.onHostTransferExpired = handler;
  }

  /**
   * 记录 Host 断连（或离开）并启动转移窗口（§5.14）。
   * 已有待转移窗口时保留最早的（keep-first：多个 Host 先后离线按最早窗口判定）。
   */
  scheduleHostTransfer(boardId: string, userId: string): void {
    const room = this.rooms.get(boardId);
    if (!room) return;
    if (room.hostTransfer !== null) return;
    const timer = setTimeout(() => {
      if (room.hostTransfer?.timer === timer) room.hostTransfer = null;
      this.onHostTransferExpired?.(boardId, userId);
    }, this.hostTransferMs);
    timer.unref();
    room.hostTransfer = { userId, timer };
  }

  /** 取消同 userId 的待转移窗口（join 回归）；无待转移 / 非该用户 → false。 */
  cancelHostTransfer(boardId: string, userId: string): boolean {
    const room = this.rooms.get(boardId);
    const pending = room?.hostTransfer;
    if (!room || !pending || pending.userId !== userId) return false;
    clearTimeout(pending.timer);
    room.hostTransfer = null;
    return true;
  }

  // —— M2：软锁（§5.6 / D2-C）——

  /** 注册超时锁回调（namespace 层用于广播 lock:changed('expired') + 审计；惰性 / 定时清理共用）。 */
  setLockExpiredHandler(handler: (boardId: string, elementId: string, lock: LockRecord) => void): void {
    this.onLockExpired = handler;
  }

  /** 锁表快照（§5.6：elementId → {userId, expiresAt}；过滤逻辑过期条目，纯读不触发回调）。 */
  lockSnapshot(boardId: string, now: number = Date.now()): BoardLockSnapshot {
    const room = this.rooms.get(boardId);
    if (!room) return {};
    const snapshot: BoardLockSnapshot = {};
    for (const [elementId, lock] of room.locks) {
      if (lock.expiresAt <= now) continue;
      snapshot[elementId] = { userId: lock.userId, expiresAt: lock.expiresAt };
    }
    return snapshot;
  }

  /** 获取锁：空闲授予 / 同用户刷新 TTL / 他人占用拒绝（先惰性清理该元素的超时锁）。 */
  acquireLock(
    boardId: string,
    elementId: string,
    userId: string,
    socketId: string,
    now: number = Date.now(),
  ): AcquireLockOutcome {
    const room = this.rooms.get(boardId);
    if (!room) return { result: 'no-room' };
    this.expireStaleLock(room, elementId, now);
    const existing = room.locks.get(elementId);
    if (existing && existing.userId !== userId) {
      return { result: 'busy', holderUserId: existing.userId };
    }
    const expiresAt = now + this.lockTtlMs;
    room.locks.set(elementId, { userId, socketId, expiresAt });
    return { result: 'granted', expiresAt, refreshed: existing !== undefined };
  }

  /** 释放锁（仅持有者，按 userId 判定；同用户多连接视为同一持有者）。 */
  releaseLock(boardId: string, elementId: string, userId: string, now: number = Date.now()): ReleaseLockOutcome {
    const room = this.rooms.get(boardId);
    if (!room) return { result: 'not-holder' };
    this.expireStaleLock(room, elementId, now);
    const lock = room.locks.get(elementId);
    if (!lock || lock.userId !== userId) return { result: 'not-holder' };
    room.locks.delete(elementId);
    return { result: 'released', lock };
  }

  /** 续约锁（仅持有者）：刷新 TTL 并返回新到期时间。 */
  renewLock(boardId: string, elementId: string, userId: string, now: number = Date.now()): RenewLockOutcome {
    const room = this.rooms.get(boardId);
    if (!room) return { result: 'not-holder' };
    this.expireStaleLock(room, elementId, now);
    const lock = room.locks.get(elementId);
    if (!lock || lock.userId !== userId) return { result: 'not-holder' };
    lock.expiresAt = now + this.lockTtlMs;
    return { result: 'renewed', expiresAt: lock.expiresAt };
  }

  /** 释放某 socket 持有的全部锁（断连 / 离开 / 切房统一路径）；不触发超时回调（由调用方广播）。 */
  releaseLocksBySocket(boardId: string, socketId: string): Array<{ elementId: string; lock: LockRecord }> {
    const room = this.rooms.get(boardId);
    if (!room) return [];
    const released: Array<{ elementId: string; lock: LockRecord }> = [];
    for (const [elementId, lock] of room.locks) {
      if (lock.socketId !== socketId) continue;
      room.locks.delete(elementId);
      released.push({ elementId, lock });
    }
    return released;
  }

  /** 立即销毁指定房间（返回是否存在）。 */
  destroy(boardId: string): boolean {
    const room = this.rooms.get(boardId);
    if (!room) return false;
    this.cancelCleanup(room);
    this.clearAuxTimers(room);
    this.rooms.delete(boardId);
    return true;
  }

  /** 清空全部房间与待清理定时器（server 关闭时调用）。 */
  dispose(): void {
    clearInterval(this.lockSweepTimer);
    for (const room of this.rooms.values()) {
      this.cancelCleanup(room);
      this.clearAuxTimers(room);
    }
    this.rooms.clear();
  }

  /** 惰性过期：单元素检查（acquire / release / renew 前调用）。 */
  private expireStaleLock(room: RoomState, elementId: string, now: number): void {
    const lock = room.locks.get(elementId);
    if (!lock || lock.expiresAt > now) return;
    room.locks.delete(elementId);
    this.onLockExpired?.(room.boardId, elementId, lock);
  }

  /** 兜底扫描：全房间清理超时锁（定时触发；与惰性检查共用回调）。 */
  private sweepExpiredLocks(now: number): void {
    for (const room of this.rooms.values()) {
      for (const [elementId, lock] of [...room.locks]) {
        if (lock.expiresAt > now) continue;
        room.locks.delete(elementId);
        this.onLockExpired?.(room.boardId, elementId, lock);
      }
    }
  }

  private clearCheckpointInflight(room: RoomState): void {
    if (room.checkpointInflight === null) return;
    clearTimeout(room.checkpointInflight.timer);
    room.checkpointInflight = null;
  }

  /** 清理房间的辅助定时器（host 转移 / checkpoint inflight）。 */
  private clearAuxTimers(room: RoomState): void {
    if (room.hostTransfer !== null) {
      clearTimeout(room.hostTransfer.timer);
      room.hostTransfer = null;
    }
    this.clearCheckpointInflight(room);
  }

  private getOrCreate(boardId: string): RoomState {
    const existing = this.rooms.get(boardId);
    if (existing) return existing;
    const room: RoomState = {
      boardId,
      participants: new Map<string, ParticipantInfo>(),
      locks: new Map<string, LockRecord>(),
      oplog: new OpLog(this.oplogCapacity),
      cleanupTimer: null,
      mode: 'free',
      presenterId: null,
      checkpoint: null,
      opsSinceCheckpoint: 0,
      checkpointInflight: null,
      opsSinceSample: 0,
      hostTransfer: null,
    };
    this.rooms.set(boardId, room);
    return room;
  }

  private scheduleCleanup(room: RoomState): void {
    this.cancelCleanup(room);
    const timer = setTimeout(() => {
      room.cleanupTimer = null;
      this.clearAuxTimers(room);
      this.rooms.delete(room.boardId);
      this.onDestroy?.(room.boardId, { opsDropped: room.oplog.count });
    }, this.roomTtlMs);
    timer.unref();
    room.cleanupTimer = timer;
  }

  private cancelCleanup(room: RoomState): void {
    if (room.cleanupTimer !== null) {
      clearTimeout(room.cleanupTimer);
      room.cleanupTimer = null;
    }
  }
}

/** 候选比较：current 为 null（尚无候选）或 candidate 更早加入（joinedAt 严格更小）→ 优先。 */
function isEarlierThan(candidate: ParticipantInfo, current: ParticipantInfo | null): boolean {
  return current === null || candidate.joinedAt < current.joinedAt;
}
