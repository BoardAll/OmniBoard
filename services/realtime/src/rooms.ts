/**
 * 房间与 `/board` namespace 装配（M1 完整版 / T1.3 + M2 体验完善 + M3 互动模式 / T3.1–T3.5）。
 *
 * 职责：
 * - 装配 namespace：连接认证（token role → socket.data.tokenRole / role）+ M1/M2/M3 事件注册；
 * - 房间态见 roomStore.ts（参与者 / op 日志 / 水位 / 软锁 / 模式 / checkpoint / host 转移 / 空房清理）；
 * - 事件（§6）：M1 board:join / board:joinAck / board:ops / board:fetchOps / board:leave / board:ping；
 *   M2 presence:preview（泛化中间态转发）与 lock:acquire / lock:release / lock:renew（软锁）；
 *   M3 interactive:* 见 interactive.ts、board:checkpoint 见 checkpoint.ts（本文件负责注册与 op 触发钩子）；
 * - 广播：`board:<boardId>` 房间（`socket.to`，排除发送者；服务端主动事件用 `namespace.to`）；
 *   单播：`socket.emit`（socket.id 定向）与 `user:<userId>` 房间（跨会话定向）；
 * - 审计：认证结果、房间生命周期、权限拒绝、锁生命周期；M3 管理操作 / checkpoint / ops 采样
 *   （经注入的 AuditSink 落盘 / stderr）。
 *
 * M3 关键接线：
 * - 契约 A：board:ops 与 lock:acquire 的写权校验切换为 `effectiveCanWrite(role, grantedWrite, mode)`
 *   （free 默认 ≥Write 可写 / present 收窄；事实来源为房间参与者表，而非 socket.data.role）；
 * - 契约 D/E：join 时 token role 冲突降级（已有在线 Host → 降 CoHost + 审计）；
 *   房主自举：房间无在线 Host 时首个加入的可写角色自动成为 Host（免 token 的房主体验）；
 *   Host 离场启动转移窗口（roomStore，默认立即），到期移交见 interactive.ts；
 * - 契约 F：op 批入账后 → ops 采样审计（每 32 条 1 条）+ checkpoint 阈值触发；
 *   join 未携带（或空）lastSeenVersion 且存在 checkpoint → board:joined.snapshot 下发。
 *
 * 边界（不做，留后续）：presence:cursor / selection / page / viewport、分组 / 投票 / 计时；
 * CRDT 合并（唯一权威在客户端引擎）；Redis adapter；二进制载荷。
 */

import { buildAuditEntry, type AuditSink } from './audit.js';
import { maybeRequestCheckpoint, registerCheckpointHandlers } from './checkpoint.js';
import { installHostTransferHandler, registerInteractiveHandlers } from './interactive.js';
import { parseOp } from './oplog.js';
import { boardRoom, userRoom, OPS_AUDIT_SAMPLE_INTERVAL, type BoardRoomStore } from './roomStore.js';
import { resolveConnectionIdentity } from './token.js';
import {
  clampSessionRole,
  effectiveCanWrite,
  roleCanWrite,
  type BoardAckFailure,
  type BoardErrorPayload,
  type BoardJoinedPayload,
  type BoardNamespace,
  type BoardRole,
  type BoardServer,
  type BoardSocket,
  type BoardStateVector,
  type Op,
  type ParticipantInfo,
  type PresencePreviewOutPayload,
} from './types.js';
import { readNonEmptyString, readSeqVector } from './util.js';

export type { BoardServer, BoardNamespace, BoardSocket } from './types.js';
export {
  BoardRoomStore,
  boardRoom,
  userRoom,
  DEFAULT_ROOM_TTL_MS,
  DEFAULT_LOCK_TTL_MS,
  DEFAULT_LOCK_SWEEP_INTERVAL_MS,
  DEFAULT_HOST_TRANSFER_MS,
  DEFAULT_CHECKPOINT_OP_THRESHOLD,
  DEFAULT_CHECKPOINT_TIMEOUT_MS,
  DEFAULT_CHECKPOINT_MAX_PAYLOAD_BYTES,
  OPS_AUDIT_SAMPLE_INTERVAL,
} from './roomStore.js';
export type {
  RoomDestroyInfo,
  LockRecord,
  AcquireLockOutcome,
  ReleaseLockOutcome,
  RenewLockOutcome,
  BoardRoomStoreOptions,
} from './roomStore.js';

export const BOARD_NAMESPACE = '/board';

export interface BoardNamespaceDeps {
  env: NodeJS.ProcessEnv;
  audit: AuditSink;
  rooms: BoardRoomStore;
}

interface HandlerDeps {
  audit: AuditSink;
  rooms: BoardRoomStore;
}

function failure(code: string, message: string): BoardAckFailure {
  return { ok: false, error: { code, message } };
}

/** 挂载 `/board` namespace：认证中间件 + M1/M2/M3 事件集（含 M0 POC 兼容层）。 */
export function attachBoardNamespace(io: BoardServer, deps: BoardNamespaceDeps): BoardNamespace {
  const namespace = io.of(BOARD_NAMESPACE);
  const { env, audit, rooms } = deps;

  // M2：超时锁释放（定时扫描 / 惰性检查共用）→ 房间广播 lock:changed('expired') + 审计。
  rooms.setLockExpiredHandler((boardId, elementId, lock) => {
    namespace.to(boardRoom(boardId)).emit('lock:changed', { elementId, userId: lock.userId, action: 'expired' });
    audit.record(
      buildAuditEntry({
        userId: lock.userId,
        action: 'lock.expired',
        target: { type: 'element', id: elementId },
        result: 'success',
        boardId,
        detail: 'ttl elapsed',
      }),
    );
  });

  // M3（契约 E）：host 转移窗口到期 → 移交候选 + 广播 + 审计（处理器内部再做存续 / 在线 Host 判定）。
  installHostTransferHandler(namespace, { audit, rooms });

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
    // 契约 D：token role 不可变持久角色（clampSessionRole 上限来源）；会话角色初始 = token role。
    socket.data.tokenRole = identity.role;
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
    registerInteractiveHandlers(namespace, socket, { audit, rooms });
    registerCheckpointHandlers(namespace, socket, { audit, rooms });
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

  // —— board:join：加入 / 切换房间，回 joined 快照（§5.3；M3：冲突降级 + presenterId + snapshot）——
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

    // M3（契约 D/E）：同板重连沿用会话角色；首次 / 切房回到 token 角色；Host 冲突降级 CoHost；
    // 房主自举：房间无在线 Host 时首入的可写角色升 Host（Viewer/Guest 只读声明不参与）。
    let sessionRole: BoardRole = previous === boardId ? socket.data.role : socket.data.tokenRole;
    if (sessionRole === 'Host' && rooms.hasOnlineHost(boardId, userId)) {
      sessionRole = clampSessionRole(socket.data.tokenRole, 'CoHost');
      audit.record(
        buildAuditEntry({
          userId,
          action: 'interactive.hostConflict',
          target: { type: 'board', id: boardId },
          result: 'denied',
          boardId,
          detail: 'host already online; session role downgraded to CoHost',
        }),
      );
    } else if (sessionRole !== 'Host' && !rooms.hasOnlineHost(boardId) && roleCanWrite(sessionRole)) {
      sessionRole = clampSessionRole(socket.data.tokenRole, 'Host');
      audit.record(
        buildAuditEntry({
          userId,
          action: 'interactive.hostBootstrapped',
          target: { type: 'board', id: boardId },
          result: 'success',
          boardId,
          detail: 'no online host; session role bootstrapped to Host',
        }),
      );
    }
    socket.data.role = sessionRole;

    const participant: ParticipantInfo = {
      userId,
      socketId: socket.id,
      role: sessionRole,
      joinedAt: Date.now(),
    };
    const { isNew } = rooms.join(boardId, participant);
    socket.data.boardId = boardId;
    void socket.join(boardRoom(boardId));

    const joined: BoardJoinedPayload = {
      boardId,
      participants: rooms.participants(boardId),
      role: participant.role,
      mode: rooms.roomMode(boardId) ?? 'free',
      presenterId: rooms.presenterIdOf(boardId),
      locks: rooms.lockSnapshot(boardId),
      stateVector: rooms.stateVector(boardId),
    };
    // M3（契约 F）：新成员（未携带 lastSeenVersion 或空）且存在 checkpoint → snapshot 下发（§7 快照策略）。
    const checkpoint = rooms.checkpointOf(boardId);
    if (checkpoint !== null && (lastSeen === null || Object.keys(lastSeen).length === 0)) {
      joined.snapshot = { stateVector: checkpoint.stateVector, payload: checkpoint.payload };
    }
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

  // —— board:ops：去重 / gap 校验 / 落日志 / 广播（§5.4 核心链路）；M3：effective 写权 + 采样 + checkpoint ——
  socket.on('board:ops', (payload, ack) => {
    const boardId = socket.data.boardId;
    if (!boardId) {
      rejectRequest(ack, 'NotInRoom', 'Join a board before sending ops', 'ops before joining a room');
      return;
    }
    // M3（契约 A；2026-11 修订）：写权统一走 effectiveCanWrite——Host/CoHost 恒可写、
    // free 默认 ≥Write（含 Participant）可写、present 收窄为 Host/CoHost/Presenter
    // （事实来源为参与者表）。
    const participant = rooms.participant(boardId, socket.id);
    const mode = rooms.roomMode(boardId) ?? 'free';
    const canWrite =
      participant !== null && effectiveCanWrite(participant.role, participant.grantedWrite === true, mode);
    if (!canWrite) {
      const role = participant?.role ?? socket.data.role;
      rejectRequest(ack, 'Forbidden', `Role ${role} cannot submit ops`, `role ${role} cannot submit ops`, boardId);
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
      // M3（契约 G）：ops 采样审计（每 32 条入站 op 落 1 条，防膨胀）。
      const { samples, checkpointDue } = rooms.noteAcceptedOps(boardId, accepted.length);
      for (let index = 0; index < samples; index += 1) {
        audit.record(
          buildAuditEntry({
            userId,
            action: 'ops.sampled',
            target: { type: 'board', id: boardId },
            result: 'success',
            boardId,
            detail: `interval=${OPS_AUDIT_SAMPLE_INTERVAL}`,
          }),
        );
      }
      // M3（契约 F）：达到阈值 → 单播 board:checkpointRequest 给候选客户端（去抖 / 超时见 roomStore）。
      if (checkpointDue) maybeRequestCheckpoint(namespace, { audit, rooms }, boardId);
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

  // —— board:leave：退出房间 + 释放锁 + 广播 left + 关闭连接（§5.14）——
  socket.on('board:leave', (_payload, ack) => {
    leaveBoard(namespace, socket, rooms, audit, 'leave');
    ack?.({ ok: true });
    socket.disconnect(true);
  });

  socket.on('board:ping', (_payload, ack) => {
    ack?.({ ok: true, serverTime: Date.now() });
  });

  // —— M2: presence:preview —— 泛化中间态转发（§5.5 / D2-B）：仅做在房校验，透传载荷 + 服务端权威 userId。
  // 无 ack；未入房静默忽略；服务端不解释不校验 kind；广播排除发送者；高频流不落审计。
  socket.on('presence:preview', (payload) => {
    const boardId = socket.data.boardId;
    if (!boardId) return;
    if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) return;
    const forwarded: PresencePreviewOutPayload = { ...payload, userId };
    socket.to(boardRoom(boardId)).emit('presence:preview', forwarded);
  });

  // —— M2: lock:acquire / lock:release / lock:renew —— 软锁（§5.6 / D2-C）。
  // 轻量回执（不复用 BoardAckFailure 错误信封）；TTL 30s，客户端 10s 心跳 renew；锁表仅存服务端内存。
  // M3（契约 A）：acquire 写权切换为 effective 判定（participant.grantedWrite / present 收窄均生效）。
  socket.on('lock:acquire', (payload, ack) => {
    const boardId = socket.data.boardId;
    if (!boardId) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    const participant = rooms.participant(boardId, socket.id);
    const mode = rooms.roomMode(boardId) ?? 'free';
    const canWrite =
      participant !== null && effectiveCanWrite(participant.role, participant.grantedWrite === true, mode);
    if (!canWrite) {
      ack?.({ ok: false, reason: 'forbidden' });
      audit.record(
        buildAuditEntry({
          userId,
          action: 'lock.denied',
          target: { type: 'element', id: readNonEmptyString(payload?.elementId) },
          result: 'denied',
          boardId,
          detail: `acquire denied: role ${participant?.role ?? socket.data.role} cannot lock elements`,
        }),
      );
      return;
    }
    const elementId = readNonEmptyString(payload?.elementId);
    if (!elementId) {
      ack?.({ ok: false, reason: 'invalid-element' });
      audit.record(
        buildAuditEntry({
          userId,
          action: 'lock.denied',
          target: { type: 'element', id: null },
          result: 'denied',
          boardId,
          detail: 'acquire denied: elementId is required',
        }),
      );
      return;
    }
    const outcome = rooms.acquireLock(boardId, elementId, userId, socket.id);
    if (outcome.result === 'no-room') {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    if (outcome.result === 'busy') {
      // 已被他人占用：单播拒绝回执（不广播）。
      ack?.({ ok: true, granted: false, holderUserId: outcome.holderUserId });
      audit.record(
        buildAuditEntry({
          userId,
          action: 'lock.denied',
          target: { type: 'element', id: elementId },
          result: 'denied',
          boardId,
          detail: `acquire denied: held by ${outcome.holderUserId}`,
        }),
      );
      return;
    }
    ack?.({ ok: true, granted: true, elementId, expiresAt: outcome.expiresAt });
    socket.to(boardRoom(boardId)).emit('lock:changed', {
      elementId,
      userId,
      action: 'acquired',
      expiresAt: outcome.expiresAt,
    });
    audit.record(
      buildAuditEntry({
        userId,
        action: 'lock.acquired',
        target: { type: 'element', id: elementId },
        result: 'success',
        boardId,
        detail: outcome.refreshed ? 're-acquire refreshed ttl' : 'granted',
      }),
    );
  });

  socket.on('lock:release', (payload, ack) => {
    const boardId = socket.data.boardId;
    if (!boardId) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    const elementId = readNonEmptyString(payload?.elementId);
    if (!elementId) {
      ack?.({ ok: false, reason: 'invalid-element' });
      return;
    }
    const outcome = rooms.releaseLock(boardId, elementId, userId);
    if (outcome.result === 'not-holder') {
      ack?.({ ok: false, reason: 'not-holder' });
      return;
    }
    ack?.({ ok: true });
    socket.to(boardRoom(boardId)).emit('lock:changed', {
      elementId,
      userId: outcome.lock.userId,
      action: 'released',
    });
    audit.record(
      buildAuditEntry({
        userId,
        action: 'lock.released',
        target: { type: 'element', id: elementId },
        result: 'success',
        boardId,
        detail: 'explicit',
      }),
    );
  });

  socket.on('lock:renew', (payload, ack) => {
    const boardId = socket.data.boardId;
    if (!boardId) {
      ack?.({ ok: false });
      return;
    }
    const elementId = readNonEmptyString(payload?.elementId);
    if (!elementId) {
      ack?.({ ok: false });
      return;
    }
    const outcome = rooms.renewLock(boardId, elementId, userId);
    if (outcome.result !== 'renewed') {
      ack?.({ ok: false });
      return;
    }
    // 续约不广播、不审计（10s 心跳高频；§D2-C）。
    ack?.({ ok: true, expiresAt: outcome.expiresAt });
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

/**
 * 统一离开流程：释放该 socket 持有的全部锁（广播 lock:changed('released') + 审计）
 * → 移出参与者表 / 房间 → 广播 left → 空房启动清理 → 审计
 * → M3（契约 E）：Host 离场启动转移窗口（同 userId 60s 内回归由 roomStore.join 取消）。
 * 断连 / 显式 leave / 切房（switch）共用；释放广播 action 固定 'released'，审计 detail = reason。
 */
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
  const releasedLocks = rooms.releaseLocksBySocket(boardId, socket.id);
  const participant = rooms.leave(boardId, socket.id);
  void socket.leave(boardRoom(boardId));
  // 锁释放广播：此时发送者已不在房间，发给房间剩余成员（与 participants.left 同语义）。
  for (const { elementId, lock } of releasedLocks) {
    namespace.to(boardRoom(boardId)).emit('lock:changed', {
      elementId,
      userId: lock.userId,
      action: 'released',
    });
    audit.record(
      buildAuditEntry({
        userId: lock.userId,
        action: 'lock.released',
        target: { type: 'element', id: elementId },
        result: 'success',
        boardId,
        detail: reason,
      }),
    );
  }
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
  // M3（契约 E）：Host 离场 → 启动转移窗口（无人可移交 / 已回归 / 已有在线 Host 时到期自动放弃）。
  if (participant.role === 'Host') {
    rooms.scheduleHostTransfer(boardId, participant.userId);
  }
}
