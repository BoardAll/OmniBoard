/**
 * checkpoint 服务端侧（M3-T3.5；《互动白板实时协同设计文档》§7 快照策略；契约 F）。
 *
 * 原则：**服务端只存不解释** —— payload 为客户端（引擎 encodeState）上传的字符串原样存储，
 * 服务端不解析、不合并、不改写；新成员首同步经 board:joined.snapshot 原样下发（§5.3 / §6 预留字段）。
 *
 * C→S `board:checkpoint {stateVector, payload}`（轻量 ack）：
 * - 仅 Host / CoHost（§7：角色 ≥ CoHost 的在线客户端）可上传；
 * - payload 为字符串；UTF-8 字节数 > 上限（默认 10MB，WB_CHECKPOINT_MAX_PAYLOAD_BYTES 可配）→
 *   ack {ok:false, reason:'payload-too-large'} + 审计 checkpoint.denied；
 * - 存储 room.checkpoint={stateVector, payload, byUserId, updatedAt} + 审计 checkpoint.stored（含 size）。
 *
 * S→C `board:checkpointRequest {stateVector}`（经 user:<userId> 房间单播）：由 maybeRequestCheckpoint
 * 在入站 op 达标（WB_CHECKPOINT_OP_THRESHOLD，默认 500）时触发；候选与去抖/超时语义见 roomStore。
 */

import { buildAuditEntry, type AuditSink } from './audit.js';
import { userRoom, type BoardRoomStore } from './roomStore.js';
import { roleRank, type BoardNamespace, type BoardSocket } from './types.js';
import { readSeqVector } from './util.js';

export interface CheckpointDeps {
  audit: AuditSink;
  rooms: BoardRoomStore;
}

/** 挂载 board:checkpoint 上传处理（每连接调用）。 */
export function registerCheckpointHandlers(namespace: BoardNamespace, socket: BoardSocket, deps: CheckpointDeps): void {
  const { audit, rooms } = deps;
  const userId = socket.data.userId;

  socket.on('board:checkpoint', (payload, ack) => {
    const boardId = socket.data.boardId;
    if (!boardId) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    const participant = rooms.participant(boardId, socket.id);
    if (!participant || roleRank(participant.role) < roleRank('CoHost')) {
      ack?.({ ok: false, reason: 'forbidden' });
      audit.record(
        buildAuditEntry({
          userId,
          action: 'authz.denied',
          target: { type: 'board', id: boardId },
          result: 'denied',
          boardId,
          detail: 'checkpoint upload requires role >= CoHost',
        }),
      );
      return;
    }
    const stateVector = readSeqVector(payload?.stateVector);
    if (stateVector === null) {
      ack?.({ ok: false, reason: 'invalid-argument' });
      return;
    }
    if (typeof payload?.payload !== 'string') {
      ack?.({ ok: false, reason: 'invalid-argument' });
      return;
    }
    const byteLength = Buffer.byteLength(payload.payload, 'utf8');
    if (byteLength > rooms.checkpointPayloadLimit) {
      ack?.({ ok: false, reason: 'payload-too-large' });
      audit.record(
        buildAuditEntry({
          userId,
          action: 'checkpoint.denied',
          target: { type: 'board', id: boardId },
          result: 'denied',
          boardId,
          detail: `payload ${byteLength}B exceeds limit ${rooms.checkpointPayloadLimit}B`,
        }),
      );
      return;
    }
    // 只存不解释：payload 原样入库（字符串），服务端不解析。
    const stored = rooms.storeCheckpoint(boardId, { stateVector, payload: payload.payload, byUserId: userId, updatedAt: Date.now() });
    if (!stored) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    ack?.({ ok: true });
    audit.record(
      buildAuditEntry({
        userId,
        action: 'checkpoint.stored',
        target: { type: 'board', id: boardId },
        result: 'success',
        boardId,
        detail: `size=${byteLength}B; actors=${Object.keys(stateVector).length}`,
      }),
    );
  });
}

/**
 * 入站 op 达标后的 checkpoint 触发（rooms.ts 在 op 批入账后调用）：
 * 经 user:<userId> 房间单播 board:checkpointRequest 给候选客户端（去抖 / 超时见 roomStore），并审计。
 */
export function maybeRequestCheckpoint(namespace: BoardNamespace, deps: CheckpointDeps, boardId: string): void {
  const { audit, rooms } = deps;
  const request = rooms.beginCheckpointRequestIfDue(boardId);
  if (request === null) return;
  namespace.to(userRoom(request.userId)).emit('board:checkpointRequest', { stateVector: request.stateVector });
  audit.record(
    buildAuditEntry({
      userId: 'system',
      action: 'checkpoint.requested',
      target: { type: 'user', id: request.userId },
      result: 'success',
      boardId,
      detail: `threshold=${rooms.checkpointThreshold}; actors=${Object.keys(request.stateVector).length}`,
    }),
  );
}
