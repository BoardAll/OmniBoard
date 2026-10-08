/**
 * interactive 事件族（M3-T3.1；《互动白板实时协同设计文档》§5.10 / §5.14 / §6；契约 B–E）。
 *
 * C→S（轻量 ack `{ok:true}` / `{ok:false, reason}`；除 follow/unfollow 无 ack）：
 * - raiseHand / lowerHand：最低 Viewer；置 / 清 handRaised + 广播 participants updated；不落审计；
 * - grantControl / revokeControl：最低 CoHost；目标在房且 role 不为 Host/CoHost；
 *   grant 置 grantedWrite=true（角色不变）；revoke 清 grantedWrite（角色不变；
 *   2026-11 修订后收权效果随模式：free 下 ≥Write 角色默认仍可写（revoke 仅收回
 *   对 Viewer/Guest 的越级授权），present 下非 Presenter 角色收权即只读）；
 *   单播目标 roleChanged + 广播 participants updated；审计必落；
 * - startPresent（最低 CoHost，presenterId=发起者）/ stopPresent（最低 Presenter，须处于 present）：
 *   置 / 清 mode='present'/'free' 与 presenterId；广播 modeChanged；审计必落；
 * - removeUser：发起者 ≥CoHost 且级别严格大于目标；单播目标全部连接 room:removed 后断开；审计必落；
 * - follow / unfollow：最低 Viewer；无状态透传（单播 target，无 ack、不审计、目标不在房静默忽略）。
 *
 * S→C：interactive:modeChanged（广播）/ roleChanged（user:<userId> 单播）/ hostChanged（广播）。
 *
 * host 转移（§5.14 / 契约 E）：Host 离场由 rooms.ts 启动窗口（roomStore.scheduleHostTransfer），
 * 同 userId 回归取消；窗口到期且房间存续且无 Host 在线 → 移交最早 CoHost（无则最早可写角色），
 * sessionRole=Host（clampSessionRole seam）、广播 hostChanged + participants updated、
 * 单播新 Host roleChanged、审计必落。
 *
 * 拒绝策略（契约 G）：权限拒绝 → 轻量 ack + 审计 authz.denied（interactive 族不发 room:error）；
 * 'not-in-room' 仅 ack 不审计；stopPresent 非 present 态 → {ok:false, reason:'not-presenting'} 不审计。
 */

import { buildAuditEntry, type AuditSink } from './audit.js';
import { boardRoom, userRoom, type BoardRoomStore } from './roomStore.js';
import {
  clampSessionRole,
  roleRank,
  type BoardNamespace,
  type BoardSocket,
  type InteractiveAck,
  type InteractiveFollowPayload,
  type ParticipantInfo,
} from './types.js';
import { readNonEmptyString } from './util.js';

export interface InteractiveDeps {
  audit: AuditSink;
  rooms: BoardRoomStore;
}

/** 挂载 interactive 事件族（每连接调用；host 转移处理器经 installHostTransferHandler 全局安装一次）。 */
export function registerInteractiveHandlers(namespace: BoardNamespace, socket: BoardSocket, deps: InteractiveDeps): void {
  const { audit, rooms } = deps;
  const userId = socket.data.userId;

  /** 当前房间上下文（未入房 / 参与者缺失 → null）。 */
  const roomContext = (): { boardId: string; participant: ParticipantInfo } | null => {
    const boardId = socket.data.boardId;
    if (!boardId) return null;
    const participant = rooms.participant(boardId, socket.id);
    if (!participant) return null;
    return { boardId, participant };
  };

  /** 权限拒绝：轻量 ack + 审计 authz.denied（不广播、不发 room:error）。 */
  const denyForbidden = (
    boardId: string,
    participant: ParticipantInfo,
    event: string,
    detail: string,
  ): InteractiveAck => {
    audit.record(
      buildAuditEntry({
        userId: participant.userId,
        action: 'authz.denied',
        target: { type: 'board', id: boardId },
        result: 'denied',
        boardId,
        detail: `${event} denied: ${detail}`,
      }),
    );
    return { ok: false, reason: 'forbidden' };
  };

  // —— 举手（最低 Viewer；不落审计）——

  socket.on('interactive:raiseHand', (_payload, ack) => {
    const context = roomContext();
    if (!context) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    const { boardId, participant } = context;
    if (roleRank(participant.role) < roleRank('Viewer')) {
      ack?.(denyForbidden(boardId, participant, 'interactive:raiseHand', `role ${participant.role} below Viewer`));
      return;
    }
    const outcome = rooms.setHandRaised(boardId, socket.id, true);
    if (!outcome) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    ack?.({ ok: true });
    socket.to(boardRoom(boardId)).emit('board:participants', { updated: [outcome.participant] });
  });

  socket.on('interactive:lowerHand', (_payload, ack) => {
    const context = roomContext();
    if (!context) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    const { boardId, participant } = context;
    if (roleRank(participant.role) < roleRank('Viewer')) {
      ack?.(denyForbidden(boardId, participant, 'interactive:lowerHand', `role ${participant.role} below Viewer`));
      return;
    }
    const outcome = rooms.setHandRaised(boardId, socket.id, false);
    if (!outcome) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    ack?.({ ok: true });
    socket.to(boardRoom(boardId)).emit('board:participants', { updated: [outcome.participant] });
  });

  // —— 授权 / 收权（最低 CoHost；目标在房且非 Host/CoHost；审计必落）——

  socket.on('interactive:grantControl', (payload, ack) => {
    const context = roomContext();
    if (!context) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    const { boardId, participant } = context;
    if (roleRank(participant.role) < roleRank('CoHost')) {
      ack?.(denyForbidden(boardId, participant, 'interactive:grantControl', `role ${participant.role} below CoHost`));
      return;
    }
    const targetId = readNonEmptyString(payload?.userId);
    if (!targetId) {
      ack?.({ ok: false, reason: 'invalid-argument' });
      return;
    }
    const targets = rooms.participantsForUser(boardId, targetId);
    const target = targets[0];
    if (!target) {
      ack?.({ ok: false, reason: 'user-not-in-room' });
      return;
    }
    if (target.role === 'Host' || target.role === 'CoHost') {
      ack?.({ ok: false, reason: 'invalid-target' });
      return;
    }
    const updated = rooms.setGrantedWrite(boardId, targetId, true);
    ack?.({ ok: true });
    namespace.to(userRoom(targetId)).emit('interactive:roleChanged', {
      userId: targetId,
      role: target.role,
      grantedWrite: true,
    });
    socket.to(boardRoom(boardId)).emit('board:participants', { updated });
    audit.record(
      buildAuditEntry({
        userId,
        action: 'interactive.grantControl',
        target: { type: 'user', id: targetId },
        result: 'success',
        boardId,
        detail: 'granted temporary write',
      }),
    );
  });

  socket.on('interactive:revokeControl', (payload, ack) => {
    const context = roomContext();
    if (!context) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    const { boardId, participant } = context;
    if (roleRank(participant.role) < roleRank('CoHost')) {
      ack?.(denyForbidden(boardId, participant, 'interactive:revokeControl', `role ${participant.role} below CoHost`));
      return;
    }
    const targetId = readNonEmptyString(payload?.userId);
    if (!targetId) {
      ack?.({ ok: false, reason: 'invalid-argument' });
      return;
    }
    const targets = rooms.participantsForUser(boardId, targetId);
    const target = targets[0];
    if (!target) {
      ack?.({ ok: false, reason: 'user-not-in-room' });
      return;
    }
    if (target.role === 'Host' || target.role === 'CoHost') {
      ack?.({ ok: false, reason: 'invalid-target' });
      return;
    }
    // 收权 = 清 grantedWrite（2026-11 修订）：free 下 ≥Write 角色仍默认可写
    // （revoke 仅收回 Viewer/Guest 的越级授权），present 下非 Presenter 收权即只读；
    // 无需降级角色——收权后与「后加入未授权」状态一致。
    const updated = rooms.setGrantedWrite(boardId, targetId, false);
    ack?.({ ok: true });
    namespace.to(userRoom(targetId)).emit('interactive:roleChanged', {
      userId: targetId,
      role: target.role,
      grantedWrite: false,
    });
    socket.to(boardRoom(boardId)).emit('board:participants', { updated });
    audit.record(
      buildAuditEntry({
        userId,
        action: 'interactive.revokeControl',
        target: { type: 'user', id: targetId },
        result: 'success',
        boardId,
        detail: 'revoked temporary write',
      }),
    );
  });

  // —— 演示模式（start 最低 CoHost / stop 最低 Presenter；审计必落）——

  socket.on('interactive:startPresent', (_payload, ack) => {
    const context = roomContext();
    if (!context) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    const { boardId, participant } = context;
    if (roleRank(participant.role) < roleRank('CoHost')) {
      ack?.(denyForbidden(boardId, participant, 'interactive:startPresent', `role ${participant.role} below CoHost`));
      return;
    }
    if (!rooms.setPresenting(boardId, userId)) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    ack?.({ ok: true });
    socket.to(boardRoom(boardId)).emit('interactive:modeChanged', { mode: 'present', by: userId, presenterId: userId });
    audit.record(
      buildAuditEntry({
        userId,
        action: 'interactive.startPresent',
        target: { type: 'board', id: boardId },
        result: 'success',
        boardId,
        detail: `mode=present; presenter=${userId}`,
      }),
    );
  });

  socket.on('interactive:stopPresent', (_payload, ack) => {
    const context = roomContext();
    if (!context) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    const { boardId, participant } = context;
    if (roleRank(participant.role) < roleRank('Presenter')) {
      ack?.(denyForbidden(boardId, participant, 'interactive:stopPresent', `role ${participant.role} below Presenter`));
      return;
    }
    if (rooms.roomMode(boardId) !== 'present') {
      ack?.({ ok: false, reason: 'not-presenting' });
      return;
    }
    if (!rooms.stopPresenting(boardId)) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    ack?.({ ok: true });
    socket.to(boardRoom(boardId)).emit('interactive:modeChanged', { mode: 'free', by: userId });
    audit.record(
      buildAuditEntry({
        userId,
        action: 'interactive.stopPresent',
        target: { type: 'board', id: boardId },
        result: 'success',
        boardId,
        detail: 'mode=free',
      }),
    );
  });

  // —— 移除用户（≥CoHost 且级别严格大于目标；单播 room:removed 后断开；审计必落）——

  socket.on('interactive:removeUser', (payload, ack) => {
    const context = roomContext();
    if (!context) {
      ack?.({ ok: false, reason: 'not-in-room' });
      return;
    }
    const { boardId, participant } = context;
    if (roleRank(participant.role) < roleRank('CoHost')) {
      ack?.(denyForbidden(boardId, participant, 'interactive:removeUser', `role ${participant.role} below CoHost`));
      return;
    }
    const targetId = readNonEmptyString(payload?.userId);
    if (!targetId) {
      ack?.({ ok: false, reason: 'invalid-argument' });
      return;
    }
    const targets = rooms.participantsForUser(boardId, targetId);
    const target = targets[0];
    if (!target) {
      ack?.({ ok: false, reason: 'user-not-in-room' });
      return;
    }
    if (roleRank(participant.role) <= roleRank(target.role)) {
      ack?.(denyForbidden(boardId, participant, 'interactive:removeUser', `rank ${participant.role} not above ${target.role}`));
      return;
    }
    ack?.({ ok: true });
    // 先单播 room:removed 再断开（客户端收后进入只读并提示）；断开触发 leaveBoard 广播 participants left。
    for (const entry of targets) {
      const targetSocket = namespace.sockets.get(entry.socketId);
      if (!targetSocket) continue;
      targetSocket.emit('room:removed', { code: 'Removed', message: 'Removed from the board', reason: 'removed' });
      targetSocket.disconnect(true);
    }
    audit.record(
      buildAuditEntry({
        userId,
        action: 'interactive.removeUser',
        target: { type: 'user', id: targetId },
        result: 'success',
        boardId,
        detail: `disconnected ${targets.length} connection(s)`,
      }),
    );
  });

  // —— 跟随 / 取消跟随（最低 Viewer；无状态透传；无 ack、不审计、目标不在房静默忽略）——

  const resolveFollowTarget = (payload: InteractiveFollowPayload): string | null => {
    const boardId = socket.data.boardId;
    if (!boardId) return null;
    const participant = rooms.participant(boardId, socket.id);
    if (!participant || roleRank(participant.role) < roleRank('Viewer')) return null;
    const targetId = readNonEmptyString(payload?.targetUserId);
    if (!targetId) return null;
    return rooms.participantsForUser(boardId, targetId).length > 0 ? targetId : null;
  };

  socket.on('interactive:follow', (payload) => {
    const targetId = resolveFollowTarget(payload);
    if (targetId === null) return;
    namespace.to(userRoom(targetId)).emit('interactive:follow', { followerUserId: userId });
  });

  socket.on('interactive:unfollow', (payload) => {
    const targetId = resolveFollowTarget(payload);
    if (targetId === null) return;
    namespace.to(userRoom(targetId)).emit('interactive:unfollow', { followerUserId: userId });
  });
}

/**
 * 安装 host 转移到期处理器（attachBoardNamespace 全局调用一次；契约 E）。
 * 到期动作：房间存续且无 Host 在线 → 移交候选 → sessionRole=Host → 广播 + 单播 + 审计。
 */
export function installHostTransferHandler(namespace: BoardNamespace, deps: InteractiveDeps): void {
  const { audit, rooms } = deps;
  rooms.setHostTransferExpiredHandler((boardId, pendingUserId) => {
    if (rooms.hasOnlineHost(boardId)) return; // 期间已有 Host 在线（如新 Host 加入）：放弃移交
    const candidate = rooms.earliestHostCandidate(boardId);
    if (candidate === null) return; // 房间不存在 / 无可移交候选（仅 Viewer/Guest）：放弃
    const updated = rooms.setUserRole(boardId, candidate.userId, 'Host');
    for (const entry of updated) {
      const live = namespace.sockets.get(entry.socketId);
      if (live) live.data.role = clampSessionRole(live.data.tokenRole, 'Host');
    }
    namespace.to(boardRoom(boardId)).emit('interactive:hostChanged', { newHostId: candidate.userId });
    namespace.to(boardRoom(boardId)).emit('board:participants', { updated });
    namespace.to(userRoom(candidate.userId)).emit('interactive:roleChanged', {
      userId: candidate.userId,
      role: 'Host',
      grantedWrite: candidate.grantedWrite === true,
    });
    audit.record(
      buildAuditEntry({
        userId: 'system',
        action: 'interactive.hostChanged',
        target: { type: 'user', id: candidate.userId },
        result: 'success',
        boardId,
        detail: `grace window elapsed (${rooms.hostTransferWindowMs}ms) for ${pendingUserId}; transferred to ${candidate.userId}`,
      }),
    );
  });
}
