/**
 * realtime 房主自举 + 退出立即移交测试（房主自举决策）。
 *
 * 行为契约：
 * - 房间无在线 Host 时，首个加入的可写角色（Host/CoHost/Presenter/Participant）自动升 Host，
 *   落审计 `interactive.hostBootstrapped`（Viewer/Guest 只读声明不参与自举）；
 * - 已有在线 Host → 不自举，按 token 角色加入；
 * - 房主离场：默认立即移交（DEFAULT_HOST_TRANSFER_MS = 0；WB_HOST_TRANSFER_MS 可配防抖窗口），
 *   到期移交给最早候选（interactive.ts）；无人可移交 → 房间无主，下一位进入者自举。
 *
 * 真实定时器（socket.io 与 vi.useFakeTimers 不兼容）；默认窗口 0 即断开后下一 tick 移交。
 */

import { describe, expect, it } from 'vitest';
import type {
  BoardParticipantsPayload,
  InteractiveHostChangedPayload,
  InteractiveRoleChangedPayload,
} from '../src/types.js';
import {
  collectArgs,
  connectAndWait,
  createTestContext,
  joinBoard,
  memoryAuditOf,
  signTestToken,
  sleep,
  waitFor,
  waitForEvent,
} from './helpers.js';

const JWT_ENV = { WB_JWT_SECRET: 'test-secret' };

describe('realtime: 房主自举（首个进房者自动成为 Host）', () => {
  it('空房首个匿名加入者 → Host（joined + participants + 审计 hostBootstrapped）；第二人保持 Participant', async () => {
    const ctx = await createTestContext();
    try {
      const first = await connectAndWait(ctx);
      const ack1 = await joinBoard(first.client, 'board-boot-1');
      if (!ack1.ok) throw new Error('join failed');
      expect(ack1.role).toBe('Host');
      expect(ack1.participants).toEqual([
        expect.objectContaining({ userId: first.session.userId, role: 'Host' }),
      ]);
      await waitFor(() =>
        memoryAuditOf(ctx.server).entries.some(
          (e) => e.action === 'interactive.hostBootstrapped' && e.userId === first.session.userId,
        ),
      );

      // 已有在线 Host：第二人不自举。
      const second = await connectAndWait(ctx);
      const ack2 = await joinBoard(second.client, 'board-boot-1');
      if (!ack2.ok) throw new Error('join failed');
      expect(ack2.role).toBe('Participant');
    } finally {
      await ctx.close();
    }
  });

  it('带 Participant token 的首个加入者同样自举；Viewer 只读声明不参与（后续可写角色仍可自举）', async () => {
    const ctx = await createTestContext(JWT_ENV);
    try {
      const member = await connectAndWait(ctx, { token: signTestToken('user-m', { role: 'Participant' }) });
      const ackMember = await joinBoard(member.client, 'board-boot-2');
      if (!ackMember.ok) throw new Error('join failed');
      expect(ackMember.role).toBe('Host');

      // Viewer 首入不自举 → 房间仍无 Host。
      const viewer = await connectAndWait(ctx, { token: signTestToken('user-v', { role: 'Viewer' }) });
      const ackViewer = await joinBoard(viewer.client, 'board-boot-3');
      if (!ackViewer.ok) throw new Error('join failed');
      expect(ackViewer.role).toBe('Viewer');

      // 后续可写角色加入：仍无在线 Host → 自举。
      const member2 = await connectAndWait(ctx, { token: signTestToken('user-m2', { role: 'Participant' }) });
      const ackMember2 = await joinBoard(member2.client, 'board-boot-3');
      if (!ackMember2.ok) throw new Error('join failed');
      expect(ackMember2.role).toBe('Host');
    } finally {
      await ctx.close();
    }
  });

  it('自举 Host 与真 Host token 冲突：后到者降 CoHost + 审计 hostConflict', async () => {
    const ctx = await createTestContext(JWT_ENV);
    try {
      const boot = await connectAndWait(ctx, { token: signTestToken('user-boot', { role: 'Participant' }) });
      const ackBoot = await joinBoard(boot.client, 'board-boot-4');
      if (!ackBoot.ok) throw new Error('join failed');
      expect(ackBoot.role).toBe('Host');

      const real = await connectAndWait(ctx, { token: signTestToken('user-real', { role: 'Host' }) });
      const ackReal = await joinBoard(real.client, 'board-boot-4');
      if (!ackReal.ok) throw new Error('join failed');
      expect(ackReal.role).toBe('CoHost');
      await waitFor(() =>
        memoryAuditOf(ctx.server).entries.some(
          (e) => e.action === 'interactive.hostConflict' && e.userId === 'user-real',
        ),
      );
    } finally {
      await ctx.close();
    }
  });

  it('房主退出 → 默认立即移交给最早成员（hostChanged + roleChanged + updated + 审计）', async () => {
    const ctx = await createTestContext(JWT_ENV);
    try {
      const boot = await connectAndWait(ctx, { token: signTestToken('user-boot', { role: 'Participant' }) });
      const member = await connectAndWait(ctx, { token: signTestToken('user-m', { role: 'Participant' }) });
      const ackBoot = await joinBoard(boot.client, 'board-boot-5');
      if (!ackBoot.ok) throw new Error('join failed');
      const ackMember = await joinBoard(member.client, 'board-boot-5');
      if (!ackMember.ok) throw new Error('join failed');

      const hostChanged = waitForEvent<InteractiveHostChangedPayload>(member.client, 'interactive:hostChanged');
      const memberRole = waitForEvent<InteractiveRoleChangedPayload>(member.client, 'interactive:roleChanged');
      const updates = collectArgs<[BoardParticipantsPayload]>(member.client, 'board:participants');

      boot.client.disconnect();

      // 默认窗口 0：断开后立即（下一 tick）移交，无 60s 等待。
      expect(await hostChanged).toEqual({ newHostId: 'user-m' });
      expect(await memberRole).toEqual({ userId: 'user-m', role: 'Host', grantedWrite: false });
      await waitFor(() =>
        updates.calls.some((c) => c[0].updated?.some((p) => p.userId === 'user-m' && p.role === 'Host')),
      );
      updates.stop();
      await waitFor(() =>
        memoryAuditOf(ctx.server).entries.some(
          (e) => e.action === 'interactive.hostChanged' && e.target?.id === 'user-m',
        ),
      );
    } finally {
      await ctx.close();
    }
  });

  it('房主退出且房间无人 → 房间无主，下一位进入者自举为 Host', async () => {
    const ctx = await createTestContext();
    try {
      const first = await connectAndWait(ctx);
      const ack1 = await joinBoard(first.client, 'board-boot-6');
      if (!ack1.ok) throw new Error('join failed');
      expect(ack1.role).toBe('Host');

      first.client.disconnect();
      await sleep(50); // 等 leave + 移交判定（无候选 → 放弃，房间无主）。

      const next = await connectAndWait(ctx);
      const ack2 = await joinBoard(next.client, 'board-boot-6');
      if (!ack2.ok) throw new Error('join failed');
      expect(ack2.role).toBe('Host');
    } finally {
      await ctx.close();
    }
  });
});
