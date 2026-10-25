/**
 * `/cast` namespace 装配（局域网投屏信令；复用 realtime 服务的鉴权 / 审计 / 生命周期）。
 *
 * 与 `/board` 的关系：
 * - 同一 Socket.IO Server、同一端口、同一 JWT 规则（token.ts），**不新建独立信令服务**；
 * - 事件面完全独立（`cast:*`），白板消息不进入本文件，投屏消息也不进入 rooms.ts；
 * - 房间存储在 castStore.ts（独立四位码空间；关闭投屏房间不可能触达白板房间）。
 *
 * 信令语义：
 * - 接收端：`cast:create` 建房（服务端分配四位码）→ `cast:room` 快照驱动 UI；
 *   接受 / 拒绝用 `cast:decision`；换码 `cast:regenerate`；关闭 `cast:close`。
 * - 发送端：`cast:join` 凭四位码申请 → 收到 `cast:accepted` 后创建 offer；
 *   `cast:offer` / `cast:answer` / `cast:ice` 由服务端按 senderId 精确路由。
 * - 媒体不经服务端：本文件只转发 SDP / ICE 文本。
 *
 * 串线防护：下行事件的 `senderId` 一律由服务端根据 socket 会话回填；
 * 接收端上行必须携带本房间已接受的 senderId，未命中直接丢弃。
 */

import { buildAuditEntry, type AuditSink } from './audit.js';
import {
  CAST_NAMESPACE,
  type CastAckFailure,
  type CastClientToServerEvents,
  type CastCreatePayload,
  type CastDecisionPayload,
  type CastEmptyPayload,
  type CastIcePayload,
  type CastJoinPayload,
  type CastLeavePayload,
  type CastNamespace,
  type CastResumePayload,
  type CastSdpPayload,
  type CastServer,
  type CastSocket,
  type CastStatusPayload,
  type CastUpdatePayload,
} from './castTypes.js';
import {
  CastRoomStore,
  castReceiverRoom,
  castRoomName,
  castSenderRoom,
} from './castStore.js';
import { resolveConnectionIdentity } from './token.js';
import { readNonEmptyString } from './util.js';

export type { CastServer, CastNamespace, CastSocket } from './castTypes.js';
export {
  CastRoomStore,
  castRoomName,
  castReceiverRoom,
  castSenderRoom,
} from './castStore.js';
export {
  DEFAULT_CAST_MAX_SENDERS,
  DEFAULT_CAST_ROOM_TTL_MS,
  DEFAULT_CAST_JOIN_ATTEMPT_LIMIT,
  DEFAULT_CAST_JOIN_ATTEMPT_WINDOW_MS,
  DEFAULT_CAST_JOIN_BLOCK_MS,
  DEFAULT_CAST_RECEIVER_GRACE_MS,
  DEFAULT_CAST_SENDER_GRACE_MS,
  CAST_MAX_SENDERS_LIMIT,
  CAST_ROOM_TTL_MAX_MS,
  CAST_ROOM_TTL_MIN_MS,
  CAST_CODE_PATTERN,
  CAST_NAMESPACE,
} from './castTypes.js';
export type {
  CastRoomRecord,
  CastSenderRecord,
  CastStoreHandlers,
  CastRoomStoreOptions,
  CastCreateOutcome,
  CastJoinOutcome,
  CastJoinFailureCode,
  CastUpdateOutcome,
  CastDecisionOutcome,
  CastLeaveOutcome,
} from './castStore.js';

export interface CastNamespaceDeps {
  env: NodeJS.ProcessEnv;
  audit: AuditSink;
  rooms: CastRoomStore;
}

function failure(code: string, message: string): CastAckFailure {
  return { ok: false, error: { code, message } };
}

/** 审计里对四位码脱敏（只保留前两位，便于定位又不落全码）。 */
function maskCode(code: string): string {
  return `${code.slice(0, 2)}**`;
}

/** 挂载 `/cast` namespace（鉴权中间件 + 事件集 + 存储回调）。 */
export function attachCastNamespace(io: CastServer, deps: CastNamespaceDeps): CastNamespace {
  const namespace = io.of(CAST_NAMESPACE);
  const { env, audit, rooms } = deps;

  // —— 存储回调：房间关闭 / 单路移除 / 快照变化 → 对应房间广播 + 审计 ——
  rooms.setHandlers({
    onRoomClosed: ({ code, reason, senders }) => {
      namespace.to(castReceiverRoom(code)).emit('cast:roomClosed', { code, reason });
      for (const sender of senders) {
        namespace.to(castSenderRoom(code, sender.senderId)).emit('cast:roomClosed', { code, reason });
      }
      audit.record(
        buildAuditEntry({
          userId: 'system',
          action: 'cast.roomClosed',
          target: { type: 'cast-room', id: maskCode(code) },
          result: 'success',
          detail: `reason=${reason}; senders=${senders.length}`,
        }),
      );
    },
    onSenderRemoved: ({ code, senderId, reason }) => {
      namespace.to(castReceiverRoom(code)).emit('cast:peerLeft', { senderId, reason });
    },
    onRoomChanged: (snapshot) => {
      namespace.to(castReceiverRoom(snapshot.code)).emit('cast:room', snapshot);
    },
  });

  // 连接鉴权：与 /board 完全同一套规则（JWT 优先；非生产匿名回落）。
  namespace.use((socket, next) => {
    const identity = resolveConnectionIdentity(socket.handshake.auth, env);
    if (identity.kind === 'rejected') {
      const error = new Error(`Unauthorized: ${identity.reason}`) as Error & { data?: { code: string; message: string } };
      error.data = { code: 'Unauthorized', message: identity.reason };
      audit.record(buildAuditEntry({ action: 'cast.auth.rejected', result: 'denied', detail: identity.reason }));
      next(error);
      return;
    }
    socket.data.userId = identity.userId;
    socket.data.authMode = identity.kind;
    socket.data.role = null;
    next();
  });

  namespace.on('connection', (socket) => {
    registerCastHandlers(namespace, socket, { audit, rooms });
  });

  return namespace;
}

interface HandlerDeps {
  audit: AuditSink;
  rooms: CastRoomStore;
}

function registerCastHandlers(namespace: CastNamespace, socket: CastSocket, deps: HandlerDeps): void {
  const { audit, rooms } = deps;
  const userId = socket.data.userId;

  socket.emit('cast:session', { userId, role: null });

  const reject = (ack: ((response: CastAckFailure) => void) | undefined, code: string, message: string): void => {
    socket.emit('cast:error', { code, message });
    ack?.(failure(code, message));
  };

  const auditDenied = (action: string, detail: string, code?: string): void => {
    audit.record(
      buildAuditEntry({
        userId,
        action,
        target: { type: 'cast-room', id: code === undefined ? null : maskCode(code) },
        result: 'denied',
        detail,
      }),
    );
  };

  // —— 建房：服务端分配四位码；成功后接收端才显示有效投屏码 ——
  socket.on('cast:create', (payload: CastCreatePayload | undefined, ack) => {
    const outcome = rooms.createRoom({
      receiverUserId: userId,
      receiverSocketId: socket.id,
      deviceName: payload?.deviceName,
      maxSenders: payload?.maxSenders,
      autoAccept: payload?.autoAccept,
      ttlMs: payload?.ttlMs,
    });
    if (!outcome.ok) {
      const message =
        outcome.code === 'AlreadyInRoom' ? '当前连接已开启投屏接收' : '房间号已用尽，请稍后重试';
      reject(ack, outcome.code, message);
      return;
    }
    socket.data.role = 'receiver';
    void socket.join(castRoomName(outcome.room.code));
    void socket.join(castReceiverRoom(outcome.room.code));
    socket.emit('cast:room', outcome.snapshot);
    ack?.({ ok: true, room: outcome.snapshot, receiverToken: outcome.receiverToken });
    audit.record(
      buildAuditEntry({
        userId,
        action: 'cast.roomCreated',
        target: { type: 'cast-room', id: maskCode(outcome.room.code) },
        result: 'success',
        detail: `maxSenders=${outcome.room.maxSenders}; autoAccept=${outcome.room.autoAccept ? 1 : 0}`,
      }),
    );
  });

  // —— 断线重连恢复（接收端用 receiverToken；发送端用 senderToken）——
  socket.on('cast:resume', (payload: CastResumePayload | undefined, ack) => {
    const receiverToken = readNonEmptyString(payload?.receiverToken);
    const senderToken = readNonEmptyString(payload?.senderToken);
    const code = CastRoomStore.normalizeCode(payload?.code);
    if (code === null) {
      reject(ack, 'INVALID_ARGUMENT', 'code 必须是四位数字字符串');
      return;
    }
    if (receiverToken !== null) {
      const outcome = rooms.resumeReceiver(
        code,
        receiverToken,
        socket.id,
        userId,
        socket.data.authMode === 'jwt',
      );
      if (!outcome.ok) {
        reject(ack, outcome.code, outcome.message);
        return;
      }
      socket.data.role = 'receiver';
      void socket.join(castRoomName(code));
      void socket.join(castReceiverRoom(code));
      socket.emit('cast:room', outcome.snapshot);
      ack?.({ ok: true, role: 'receiver', room: outcome.snapshot });
      audit.record(
        buildAuditEntry({
          userId,
          action: 'cast.resumed',
          target: { type: 'cast-room', id: maskCode(code) },
          result: 'success',
          detail: 'role=receiver',
        }),
      );
      return;
    }
    if (senderToken !== null) {
      const outcome = rooms.resumeSender(
        code,
        senderToken,
        socket.id,
        userId,
        socket.data.authMode === 'jwt',
      );
      if (!outcome.ok) {
        reject(ack, outcome.code, outcome.message);
        return;
      }
      socket.data.role = 'sender';
      void socket.join(castRoomName(code));
      void socket.join(castSenderRoom(code, outcome.sender.senderId));
      ack?.({
        ok: true,
        role: 'sender',
        code,
        senderId: outcome.sender.senderId,
        state: outcome.sender.state,
        maxSenders: outcome.room.maxSenders,
        autoAccept: outcome.room.autoAccept,
      });
      audit.record(
        buildAuditEntry({
          userId,
          action: 'cast.resumed',
          target: { type: 'cast-room', id: maskCode(code) },
          result: 'success',
          detail: 'role=sender',
        }),
      );
      return;
    }
    reject(ack, 'INVALID_ARGUMENT', '需要 receiverToken 或 senderToken');
  });

  // —— 更新设置（路数 / 自动接受 / 续期）——
  socket.on('cast:update', (payload: CastUpdatePayload | undefined, ack) => {
    const outcome = rooms.updateSettings(socket.id, {
      maxSenders: payload?.maxSenders,
      autoAccept: payload?.autoAccept,
      extendTtlMs: payload?.extendTtlMs,
    });
    if (!outcome.ok || outcome.snapshot === undefined) {
      reject(ack, outcome.code ?? 'NotFound', outcome.message ?? 'update failed');
      return;
    }
    ack?.({ ok: true, room: outcome.snapshot });
  });

  // —— 换码：旧码立即失效，已接受连接保留 ——
  // 注意：store 只换 code，socket.io 的房间成员关系必须由本层迁移，
  // 否则换码后接收端不再在 `cast-rx:<新码>`，收不到 request / room 快照。
  socket.on('cast:regenerate', (_payload: CastEmptyPayload | undefined, ack) => {
    const previous = rooms.receiverRoomOfSocket(socket.id);
    const previousCode = previous?.code ?? null;
    const previousSenders =
      previous === null
        ? []
        : [...previous.senders.values()].map((sender) => ({ senderId: sender.senderId, socketId: sender.socketId }));
    const outcome = rooms.rotateCode(socket.id);
    if (!outcome.ok) {
      reject(ack, outcome.code, outcome.code === 'CodeExhausted' ? '房间号已用尽，请稍后重试' : '未开启投屏接收');
      return;
    }
    const nextCode = outcome.room.code;
    if (previousCode !== null) {
      void socket.leave(castRoomName(previousCode));
      void socket.leave(castReceiverRoom(previousCode));
    }
    void socket.join(castRoomName(nextCode));
    void socket.join(castReceiverRoom(nextCode));
    // 已接受的发送端沿用原 peer 连接，仅迁移房间成员关系并同步新快照（新码 / 有效期）。
    for (const item of previousSenders) {
      const senderSocket = namespace.sockets.get(item.socketId);
      if (senderSocket === undefined) continue;
      if (previousCode !== null) {
        void senderSocket.leave(castRoomName(previousCode));
        void senderSocket.leave(castSenderRoom(previousCode, item.senderId));
      }
      void senderSocket.join(castRoomName(nextCode));
      void senderSocket.join(castSenderRoom(nextCode, item.senderId));
      senderSocket.emit('cast:room', outcome.snapshot);
    }
    socket.emit('cast:room', outcome.snapshot);
    ack?.({ ok: true, room: outcome.snapshot, receiverToken: outcome.room.receiverToken });
    audit.record(
      buildAuditEntry({
        userId,
        action: 'cast.regenerated',
        target: { type: 'cast-room', id: maskCode(nextCode) },
        result: 'success',
      }),
    );
  });

  // —— 关闭投屏房间（通知发送端，释放全部席位）——
  socket.on('cast:close', (_payload: CastEmptyPayload | undefined, ack) => {
    const room = rooms.closeByReceiver(socket.id, 'closed');
    if (!room) {
      ack?.(failure('NotFound', '未开启投屏接收'));
      return;
    }
    // 主动关闭也退出房间成员关系，避免残留单向订阅。
    void socket.leave(castRoomName(room.code));
    void socket.leave(castReceiverRoom(room.code));
    socket.data.role = null;
    ack?.({ ok: true });
  });

  // —— 房间状态（接收端刷新 / 发送端确认）——
  socket.on('cast:status', (payload: CastStatusPayload | undefined, ack) => {
    const receiverRoom = rooms.receiverRoomOfSocket(socket.id);
    if (receiverRoom) {
      ack?.({ ok: true, room: rooms.snapshot(receiverRoom) });
      return;
    }
    const session = rooms.senderOfSocket(socket.id);
    if (session) {
      ack?.({
        ok: true,
        room: rooms.snapshot(session.room),
        senderId: session.sender.senderId,
        state: session.sender.state,
      });
      return;
    }
    const code = CastRoomStore.normalizeCode(payload?.code);
    if (code !== null) {
      const room = rooms.roomOf(code);
      if (room) {
        ack?.({ ok: true, room: rooms.snapshot(room) });
        return;
      }
    }
    reject(ack, 'NotFound', '未加入投屏会话');
  });

  // —— 发送端加入：四位码校验 + 限流 + 容量 + 接收端在线校验 ——
  socket.on('cast:join', (payload: CastJoinPayload | undefined, ack) => {
    const limitKey = `socket:${socket.id}`;
    const userKey = `user:${userId}`;
    if (!rooms.joinAttemptAllowed(limitKey) || !rooms.joinAttemptAllowed(userKey)) {
      auditDenied('cast.joinDenied', 'rate limited', undefined);
      reject(ack, 'TooManyAttempts', '尝试次数过多，请稍后再试');
      return;
    }
    const code = CastRoomStore.normalizeCode(payload?.code);
    if (code === null) {
      rooms.noteJoinFailure(limitKey);
      rooms.noteJoinFailure(userKey);
      auditDenied('cast.joinDenied', 'invalid code format');
      reject(ack, 'InvalidCode', '投屏码必须是四位数字');
      return;
    }
    const outcome = rooms.join({
      code,
      socketId: socket.id,
      userId,
      deviceName: payload?.deviceName,
    });
    if (!outcome.ok) {
      rooms.noteJoinFailure(limitKey);
      rooms.noteJoinFailure(userKey);
      auditDenied('cast.joinDenied', `${outcome.code}`, code);
      reject(ack, outcome.code, outcome.message);
      return;
    }
    rooms.noteJoinSuccess(limitKey);
    rooms.noteJoinSuccess(userKey);
    socket.data.role = 'sender';
    void socket.join(castRoomName(code));
    void socket.join(castSenderRoom(code, outcome.sender.senderId));
    if (outcome.accepted) {
      socket.emit('cast:accepted', { senderId: outcome.sender.senderId, code });
    } else {
      namespace.to(castReceiverRoom(code)).emit('cast:request', {
        senderId: outcome.sender.senderId,
        userId,
        deviceName: outcome.sender.deviceName,
        at: outcome.sender.joinedAt,
      });
    }
    ack?.({
      ok: true,
      accepted: outcome.accepted,
      code,
      senderId: outcome.sender.senderId,
      senderToken: outcome.senderToken,
      maxSenders: outcome.room.maxSenders,
      expiresAt: outcome.room.expiresAt,
    });
    audit.record(
      buildAuditEntry({
        userId,
        action: 'cast.join',
        target: { type: 'cast-room', id: maskCode(code) },
        result: 'success',
        detail: `accepted=${outcome.accepted ? 1 : 0}; device=${outcome.sender.deviceName}`,
      }),
    );
  });

  // —— 接收端接受 / 拒绝某一路 ——
  socket.on('cast:decision', (payload: CastDecisionPayload | undefined, ack) => {
    const senderId = readNonEmptyString(payload?.senderId);
    const accept = payload?.accept;
    if (senderId === null || typeof accept !== 'boolean') {
      ack?.(failure('INVALID_ARGUMENT', 'cast:decision requires {senderId, accept}'));
      return;
    }
    const outcome = rooms.decide(socket.id, senderId, accept, payload?.reason);
    if (!outcome.ok || !outcome.sender) {
      reject(ack, outcome.code ?? 'NotFound', outcome.message ?? 'decision failed');
      return;
    }
    const room = rooms.receiverRoomOfSocket(socket.id);
    if (!room) {
      ack?.(failure('NotFound', 'cast room not found'));
      return;
    }
    if (accept) {
      namespace.to(castSenderRoom(room.code, senderId)).emit('cast:accepted', { senderId, code: room.code });
    } else {
      namespace.to(castSenderRoom(room.code, senderId)).emit('cast:rejected', {
        senderId,
        reason: payload?.reason ?? 'rejected',
      });
    }
    ack?.({ ok: true, room: rooms.snapshot(room) });
    audit.record(
      buildAuditEntry({
        userId,
        action: accept ? 'cast.accept' : 'cast.reject',
        target: { type: 'cast-room', id: maskCode(room.code) },
        result: 'success',
        detail: `sender=${senderId}`,
      }),
    );
  });

  // —— 离开 / 踢出单路 ——
  socket.on('cast:leave', (payload: CastLeavePayload | undefined, ack) => {
    const target = readNonEmptyString(payload?.senderId);
    const outcome = rooms.leave(socket.id, target ?? undefined, payload?.reason);
    if (!outcome.ok) {
      if (socket.data.role === 'sender') {
        // 发送端离开但已不在会话中（重复 leave）→ 幂等成功。
        ack?.({ ok: true });
        return;
      }
      reject(ack, outcome.code ?? 'NotFound', outcome.message ?? 'leave failed');
      return;
    }
    const sender = outcome.sender;
    if (sender) {
      const code = outcome.snapshot?.code;
      if (code !== undefined) {
        namespace.to(castSenderRoom(code, sender.senderId)).emit('cast:peerLeft', {
          senderId: sender.senderId,
          reason: outcome.reason ?? 'left',
        });
      }
    }
    if (socket.data.role === 'receiver') {
      const room = rooms.receiverRoomOfSocket(socket.id);
      ack?.({ ok: true, room: room ? rooms.snapshot(room) : undefined });
    } else {
      socket.data.role = null;
      ack?.({ ok: true });
    }
  });

  // —— SDP / ICE 路由（服务端只校验与转发，不解释内容）——
  const routeSdp = (
    event: 'cast:offer' | 'cast:answer',
    payload: CastSdpPayload | undefined,
  ): void => {
    const sdp = readNonEmptyString(payload?.sdp);
    if (sdp === null) return;
    const session = rooms.senderOfSocket(socket.id);
    if (session) {
      if (session.sender.state !== 'accepted') return;
      namespace.to(castReceiverRoom(session.room.code)).emit(event, {
        senderId: session.sender.senderId,
        sdp,
      });
      return;
    }
    const room = rooms.receiverRoomOfSocket(socket.id);
    if (!room) return;
    const senderId = readNonEmptyString(payload?.senderId);
    if (senderId === null) return;
    const sender = room.senders.get(senderId);
    if (!sender || sender.state !== 'accepted') return;
    namespace.to(castSenderRoom(room.code, senderId)).emit(event, { senderId, sdp });
  };

  socket.on('cast:offer', (payload) => routeSdp('cast:offer', payload));
  socket.on('cast:answer', (payload) => routeSdp('cast:answer', payload));

  socket.on('cast:ice', (payload: CastIcePayload | undefined) => {
    const candidate =
      payload?.candidate === undefined
        ? null
        : payload.candidate === null
          ? null
          : typeof payload.candidate === 'object'
            ? payload.candidate
            : null;
    if (candidate === null && payload?.candidate !== null) return;
    const session = rooms.senderOfSocket(socket.id);
    if (session) {
      if (session.sender.state !== 'accepted') return;
      namespace.to(castReceiverRoom(session.room.code)).emit('cast:ice', {
        senderId: session.sender.senderId,
        candidate,
      });
      return;
    }
    const room = rooms.receiverRoomOfSocket(socket.id);
    if (!room) return;
    const senderId = readNonEmptyString(payload?.senderId);
    if (senderId === null) return;
    const sender = room.senders.get(senderId);
    if (!sender || sender.state !== 'accepted') return;
    namespace.to(castSenderRoom(room.code, senderId)).emit('cast:ice', { senderId, candidate });
  });

  // —— 心跳续期（接收端保活；不落审计）——
  socket.on('cast:heartbeat', (_payload: CastEmptyPayload | undefined, ack) => {
    const expiresAt = rooms.touch(socket.id);
    if (expiresAt === null) {
      ack?.(failure('NotFound', '未开启投屏接收'));
      return;
    }
    ack?.({ ok: true, expiresAt });
  });

  // —— 断连：接收端进入宽限（超时关房）；发送端进入宽限（超时释放席位）——
  socket.on('disconnect', () => {
    const receiverRoom = rooms.receiverDisconnected(socket.id);
    if (receiverRoom) {
      audit.record(
        buildAuditEntry({
          userId,
          action: 'cast.receiverOffline',
          target: { type: 'cast-room', id: maskCode(receiverRoom.code) },
          result: 'success',
          detail: 'grace window started',
        }),
      );
      return;
    }
    const session = rooms.senderDisconnected(socket.id);
    if (session) {
      audit.record(
        buildAuditEntry({
          userId,
          action: 'cast.senderOffline',
          target: { type: 'cast-room', id: maskCode(session.room.code) },
          result: 'success',
          detail: 'grace window started',
        }),
      );
    }
  });
}

/** 类型导出（socket.io 装配别名，避免调用方重复声明）。 */
export type CastEventMap = {
  client: CastClientToServerEvents;
};
