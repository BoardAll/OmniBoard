/**
 * 房间与 `/board` namespace 装配（M1 完整版 / T1.3）。
 *
 * 职责：
 * - 房间态（§5.1 / §7）：参与者表（userId/socketId/role/joinedAt）、op 环形日志、版本水位、空房自动清理（§5.14）；
 * - 事件（§6 M1 契约）：board:join / board:joinAck / board:ops / board:fetchOps / board:leave / board:ping
 *   → board:joined / board:ops / board:participants / room:error；
 * - 广播：`board:<boardId>` 房间（`socket.to`，排除发送者）；单播：`socket.emit`（socket.id 定向）
 *   与 `user:<userId>` 房间（跨会话定向，M0 POC 兼容层使用）；
 * - 审计：认证结果、房间生命周期、权限拒绝（经注入的 AuditSink 落盘 / stderr）。
 *
 * 边界（不做，留 M2/M3）：presence:* / lock:* / interactive:*；CRDT 合并（唯一权威在客户端引擎）；
 * Redis adapter；checkpoint；二进制载荷。
 */

import type { Namespace, Server, Socket } from 'socket.io';
import { buildAuditEntry, type AuditSink } from './audit.js';
import { DEFAULT_OPLOG_CAPACITY, OpLog, parseOp } from './oplog.js';
import { resolveConnectionIdentity } from './token.js';
import {
  roleCanWrite,
  type BoardAckFailure,
  type BoardDirectAck,
  type BoardDirectPayload,
  type BoardDirectedPayload,
  type BoardEchoAck,
  type BoardEchoPayload,
  type BoardErrorPayload,
  type BoardFetchOpsPayload,
  type BoardFetchOpsResponse,
  type BoardJoinAck,
  type BoardJoinAckPayload,
  type BoardJoinAckResponse,
  type BoardJoinPayload,
  type BoardJoinedPayload,
  type BoardLeaveAck,
  type BoardLeavePayload,
  type BoardOpsAck,
  type BoardParticipantsPayload,
  type BoardPingAck,
  type BoardPingPayload,
  type BoardSocketData,
  type BoardStateVector,
  type ClientToServerEvents,
  type InterServerEvents,
  type Op,
  type ParticipantInfo,
  type ServerToClientEvents,
} from './types.js';

export type BoardServer = Server<ClientToServerEvents, ServerToClientEvents, InterServerEvents, BoardSocketData>;
export type BoardNamespace = Namespace<ClientToServerEvents, ServerToClientEvents, InterServerEvents, BoardSocketData>;
export type BoardSocket = Socket<ClientToServerEvents, ServerToClientEvents, InterServerEvents, BoardSocketData>;

export const BOARD_NAMESPACE = '/board';

/** 空房保留期（§5.14：最后一人离开后保留 10min，防抖动重连）。 */
export const DEFAULT_ROOM_TTL_MS = 10 * 60 * 1000;

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

export interface BoardRoomStoreOptions {
  /** 环形日志容量（默认 10k，§10）；测试可缩小。 */
  oplogCapacity?: number;
  /** 空房保留期（默认 10min，§5.14）；测试可缩短。 */
  roomTtlMs?: number;
  onDestroy?: (boardId: string, info: RoomDestroyInfo) => void;
}

interface RoomState {
  readonly boardId: string;
  /** socketId → 参与者。 */
  readonly participants: Map<string, ParticipantInfo>;
  readonly oplog: OpLog;
  cleanupTimer: NodeJS.Timeout | null;
}

/** 房间存储：参与者 / op 日志 / 水位 / 空房清理。 */
export class BoardRoomStore {
  private readonly rooms = new Map<string, RoomState>();
  private readonly oplogCapacity: number;
  private readonly roomTtlMs: number;
  private readonly onDestroy: ((boardId: string, info: RoomDestroyInfo) => void) | undefined;

  constructor(options: BoardRoomStoreOptions = {}) {
    this.oplogCapacity = options.oplogCapacity ?? DEFAULT_OPLOG_CAPACITY;
    this.roomTtlMs = options.roomTtlMs ?? DEFAULT_ROOM_TTL_MS;
    this.onDestroy = options.onDestroy;
  }

  /** 当前房间数（测试断言清理用）。 */
  get roomCount(): number {
    return this.rooms.size;
  }

  /** 加入 / 刷新参与者；取消待清理定时器。 */
  join(boardId: string, participant: ParticipantInfo): { isNew: boolean } {
    const room = this.getOrCreate(boardId);
    this.cancelCleanup(room);
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

  /** 版本水位快照。 */
  stateVector(boardId: string): BoardStateVector {
    return this.rooms.get(boardId)?.oplog.stateVector() ?? {};
  }

  /** 房间 op 日志（不存在返回 null）。 */
  oplog(boardId: string): OpLog | null {
    return this.rooms.get(boardId)?.oplog ?? null;
  }

  /** 立即销毁指定房间（返回是否存在）。 */
  destroy(boardId: string): boolean {
    const room = this.rooms.get(boardId);
    if (!room) return false;
    this.cancelCleanup(room);
    this.rooms.delete(boardId);
    return true;
  }

  /** 清空全部房间与待清理定时器（server 关闭时调用）。 */
  dispose(): void {
    for (const room of this.rooms.values()) this.cancelCleanup(room);
    this.rooms.clear();
  }

  private getOrCreate(boardId: string): RoomState {
    const existing = this.rooms.get(boardId);
    if (existing) return existing;
    const room: RoomState = {
      boardId,
      participants: new Map<string, ParticipantInfo>(),
      oplog: new OpLog(this.oplogCapacity),
      cleanupTimer: null,
    };
    this.rooms.set(boardId, room);
    return room;
  }

  private scheduleCleanup(room: RoomState): void {
    this.cancelCleanup(room);
    const timer = setTimeout(() => {
      room.cleanupTimer = null;
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

export interface BoardNamespaceDeps {
  env: NodeJS.ProcessEnv;
  audit: AuditSink;
  rooms: BoardRoomStore;
}

interface HandlerDeps {
  audit: AuditSink;
  rooms: BoardRoomStore;
}

function readNonEmptyString(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function failure(code: string, message: string): BoardAckFailure {
  return { ok: false, error: { code, message } };
}

/** 解析客户端水位向量（`{actor: seq}`；非法值 → null，触发 INVALID_ARGUMENT）。 */
function readSeqVector(value: unknown): BoardStateVector | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null;
  const out: BoardStateVector = {};
  for (const [actor, seq] of Object.entries(value as Record<string, unknown>)) {
    if (typeof seq !== 'number' || !Number.isInteger(seq) || seq < 0) return null;
    out[actor] = seq;
  }
  return out;
}

/** 挂载 `/board` namespace：认证中间件 + M1 事件集（含 M0 POC 兼容层）。 */
export function attachBoardNamespace(io: BoardServer, deps: BoardNamespaceDeps): BoardNamespace {
  const namespace = io.of(BOARD_NAMESPACE);
  const { env, audit, rooms } = deps;

  namespace.use((socket, next) => {
    const identity = resolveConnectionIdentity(socket.handshake.auth, env);
    if (identity.kind === 'rejected') {
      // 拒连：标准 Socket.IO 错误语义（客户端收到 connect_error；§6 Unauthorized）。
      audit.record(buildAuditEntry({ action: 'auth.rejected', result: 'denied', detail: identity.reason }));
      const error = new Error(`Unauthorized: ${identity.reason}`) as Error & { data?: BoardErrorPayload };
      error.data = { code: 'Unauthorized', message: identity.reason };
      next(error);
      return;
    }
    socket.data.userId = identity.userId;
    socket.data.authMode = identity.kind;
    socket.data.role = identity.role;
    if (identity.kind === 'anonymous') {
      if (identity.fallbackReason === 'missing_secret') {
        console.warn('[realtime] auth fallback to anonymous (WB_JWT_SECRET is not configured); dev only');
      }
      audit.record(
        buildAuditEntry({
          userId: identity.userId,
          action: 'auth.anonymous',
          result: 'success',
          detail: `anonymous dev fallback (${identity.fallbackReason})`,
        }),
      );
    } else {
      audit.record(
        buildAuditEntry({ userId: identity.userId, action: 'auth.connect', result: 'success', detail: 'authMode=jwt' }),
      );
    }
    next();
  });

  namespace.on('connection', (socket) => {
    registerBoardHandlers(namespace, socket, { audit, rooms });
  });

  return namespace;
}

function registerBoardHandlers(namespace: BoardNamespace, socket: BoardSocket, deps: HandlerDeps): void {
  const { audit, rooms } = deps;
  const userId = socket.data.userId;

  // 连接建立：加入个人房间（跨会话单播寻址，§6）+ 回执身份（POC 自省）。
  void socket.join(userRoom(userId));
  socket.emit('board:session', { userId, authMode: socket.data.authMode, role: socket.data.role });

  /** 拒绝类回执（Forbidden / NotInRoom 等）：单播 room:error + ack + 审计 authz.denied。 */
  const rejectRequest = (
    ack: ((response: BoardAckFailure) => void) | undefined,
    code: string,
    message: string,
    detail: string,
    boardId?: string,
  ): void => {
    socket.emit('room:error', { code, message });
    ack?.(failure(code, message));
    audit.record(
      buildAuditEntry({
        userId,
        action: 'authz.denied',
        target: boardId === undefined ? { type: 'session', id: null } : { type: 'board', id: boardId },
        result: 'denied',
        boardId,
        detail,
      }),
    );
  };

  // —— board:join：加入 / 切换房间，回 joined 快照（§5.3）——
  socket.on('board:join', (payload, ack) => {
    const boardId = readNonEmptyString(payload?.boardId);
    if (!boardId) {
      ack?.(failure('INVALID_ARGUMENT', 'boardId is required'));
      return;
    }
    let lastSeen: BoardStateVector | null = null;
    if (payload?.lastSeenVersion !== undefined) {
      lastSeen = readSeqVector(payload.lastSeenVersion);
      if (lastSeen === null) {
        ack?.(failure('INVALID_ARGUMENT', 'lastSeenVersion must be an object of actor → seq'));
        return;
      }
    }

    const previous = socket.data.boardId;
    if (previous && previous !== boardId) {
      leaveBoard(namespace, socket, rooms, audit, 'switch');
    }

    const participant: ParticipantInfo = {
      userId,
      socketId: socket.id,
      role: socket.data.role,
      joinedAt: Date.now(),
    };
    const { isNew } = rooms.join(boardId, participant);
    socket.data.boardId = boardId;
    void socket.join(boardRoom(boardId));

    const joined: BoardJoinedPayload = {
      boardId,
      participants: rooms.participants(boardId),
      role: participant.role,
      mode: 'free',
      locks: [],
      stateVector: rooms.stateVector(boardId),
    };
    socket.emit('board:joined', joined);
    if (isNew) {
      socket.to(boardRoom(boardId)).emit('board:participants', { joined: [participant] });
      audit.record(
        buildAuditEntry({
          userId,
          action: 'room.join',
          target: { type: 'board', id: boardId },
          result: 'success',
          boardId,
        }),
      );
    }
    if (lastSeen !== null) {
      // 重连场景（§5.12）：立即回放 `lastSeenVersion` 之后的增量。
      const replay = rooms.oplog(boardId)?.fetchAfter(lastSeen) ?? [];
      if (replay.length > 0) socket.emit('board:ops', replay, { replay: true });
    }
    ack?.({ ok: true, ...joined });
  });

  // —— board:joinAck：客户端上报本地水位，请求裁差分（§5.3 首同步主路径）——
  socket.on('board:joinAck', (payload, ack) => {
    const boardId = socket.data.boardId;
    if (!boardId) {
      rejectRequest(ack, 'NotInRoom', 'Join a board before requesting a sync', 'joinAck before joining a room');
      return;
    }
    let vector: BoardStateVector = {};
    if (payload?.localSeqs !== undefined) {
      const parsed = readSeqVector(payload.localSeqs);
      if (parsed === null) {
        ack?.(failure('INVALID_ARGUMENT', 'localSeqs must be an object of actor → seq'));
        return;
      }
      vector = parsed;
    }
    const replay = rooms.oplog(boardId)?.fetchAfter(vector) ?? [];
    if (replay.length > 0) socket.emit('board:ops', replay, { replay: true });
    ack?.({ ok: true, replayed: replay.length });
  });

  // —— board:ops：去重 / gap 校验 / 落日志 / 广播（§5.4 核心链路）——
  socket.on('board:ops', (payload, ack) => {
    const boardId = socket.data.boardId;
    if (!boardId) {
      rejectRequest(ack, 'NotInRoom', 'Join a board before sending ops', 'ops before joining a room');
      return;
    }
    if (!roleCanWrite(socket.data.role)) {
      rejectRequest(
        ack,
        'Forbidden',
        `Role ${socket.data.role} cannot submit ops`,
        `role ${socket.data.role} cannot submit ops`,
        boardId,
      );
      return;
    }
    if (!Array.isArray(payload) || payload.length === 0) {
      ack?.(failure('INVALID_ARGUMENT', 'board:ops payload must be a non-empty array'));
      return;
    }
    const parsed: Op[] = [];
    for (let index = 0; index < payload.length; index += 1) {
      const op = parseOp(payload[index]);
      if (op === null) {
        ack?.(failure('INVALID_ARGUMENT', `ops[${index}] is not a valid op`));
        return;
      }
      parsed.push(op);
    }
    const oplog = rooms.oplog(boardId);
    if (oplog === null) {
      rejectRequest(ack, 'NotFound', 'Board room not found', 'board room missing on ops', boardId);
      return;
    }

    const accepted: Op[] = [];
    let gapMissing: number[] | null = null;
    for (const op of parsed) {
      if (oplog.isDuplicate(op.actor, op.seq)) continue;
      const missing = oplog.missingSeqsFor(op.actor, op.seq);
      if (missing !== null) {
        // seq 断档：中断本批（已接受的保留），回报缺失区间供发送方补发。
        gapMissing = missing;
        break;
      }
      oplog.append(op);
      accepted.push(op);
    }
    if (accepted.length > 0) {
      // 房间广播，排除发送者（§5.4 第 5 步）。
      socket.to(boardRoom(boardId)).emit('board:ops', accepted, { from: userId });
    }
    if (gapMissing !== null) {
      ack?.({ ok: false, missingSeqs: gapMissing });
      return;
    }
    ack?.(accepted.length === 0 ? { ok: true, dup: true } : { ok: true });
  });

  // —— board:fetchOps：按单 actor 水位裁差分，单播回请求者（§5.4 丢包补洞）——
  socket.on('board:fetchOps', (payload, ack) => {
    const boardId = socket.data.boardId;
    if (!boardId) {
      rejectRequest(ack, 'NotInRoom', 'Join a board before fetching ops', 'fetchOps before joining a room');
      return;
    }
    const actor = readNonEmptyString(payload?.actor);
    const fromSeq = payload?.fromSeq;
    if (actor === null || typeof fromSeq !== 'number' || !Number.isInteger(fromSeq) || fromSeq < 0) {
      ack?.(failure('INVALID_ARGUMENT', 'board:fetchOps requires {actor, fromSeq >= 0}'));
      return;
    }
    const replay = rooms.oplog(boardId)?.fetchSince(actor, fromSeq) ?? [];
    if (replay.length > 0) socket.emit('board:ops', replay, { replay: true });
    ack?.({ ok: true, replayed: replay.length });
  });

  // —— board:leave：退出房间 + 广播 left + 关闭连接（§5.14）——
  socket.on('board:leave', (_payload, ack) => {
    leaveBoard(namespace, socket, rooms, audit, 'leave');
    ack?.({ ok: true });
    socket.disconnect(true);
  });

  socket.on('board:ping', (_payload, ack) => {
    ack?.({ ok: true, serverTime: Date.now() });
  });

  // —— M0 POC 兼容层（非 §6 契约；保留用于链路自检，12-app-web POC 依赖）——
  socket.on('board:echo', (payload, ack) => {
    const echo = payload?.payload;
    ack?.({ ok: true, echo });
    const boardId = socket.data.boardId;
    if (boardId) {
      socket.to(boardRoom(boardId)).emit('board:broadcast', { from: userId, payload: echo });
    }
  });

  socket.on('board:direct', (payload, ack) => {
    const toUserId = readNonEmptyString(payload?.toUserId);
    if (!toUserId) {
      ack?.(failure('INVALID_ARGUMENT', 'toUserId is required'));
      return;
    }
    // 跨会话单播：user:<userId> 房间。
    namespace.to(userRoom(toUserId)).emit('board:directed', {
      from: userId,
      toUserId,
      payload: payload?.payload,
    });
    ack?.({ ok: true });
  });

  socket.on('disconnect', () => {
    leaveBoard(namespace, socket, rooms, audit, 'disconnect');
  });
}

/** 统一离开流程：移出参与者表 / 房间 → 广播 left → 空房启动清理 → 审计。 */
function leaveBoard(
  namespace: BoardNamespace,
  socket: BoardSocket,
  rooms: BoardRoomStore,
  audit: AuditSink,
  reason: 'leave' | 'disconnect' | 'switch',
): void {
  const boardId = socket.data.boardId;
  if (!boardId) return;
  socket.data.boardId = undefined;
  const participant = rooms.leave(boardId, socket.id);
  void socket.leave(boardRoom(boardId));
  if (!participant) return;
  // 此时发送者已不在房间：发给房间剩余成员。
  namespace.to(boardRoom(boardId)).emit('board:participants', { left: [participant] });
  audit.record(
    buildAuditEntry({
      userId: participant.userId,
      action: 'room.leave',
      target: { type: 'board', id: boardId },
      result: 'success',
      boardId,
      detail: reason,
    }),
  );
}
