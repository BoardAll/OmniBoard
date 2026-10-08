/**
 * realtime M3 契约测试（T3.1 / 契约 E、§5.14）：host 转移窗口。
 *
 * 用注入的短窗口（options.hostTransferMs）+ 真实定时器（socket.io 与 vi.useFakeTimers 不兼容）；
 * 覆盖：
 * - 断连 → 窗口到期 → 移交最早 CoHost：hostChanged 广播 + roleChanged 单播 + participants updated + 审计；
 * - 窗口内同 userId 回归 → 取消（不产生事件 / 审计）；
 * - 双 Host join 冲突：新加入者降 CoHost + 审计 interactive.hostConflict；
 * - 无 CoHost → 移交最早可写角色（Participant）；无候选（仅 Viewer）→ 放弃。
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
  expectNoEvent,
  joinBoard,
  memoryAuditOf,
  signTestToken,
  sleep,
  waitFor,
  waitForEvent,
} from './helpers.js';

const JWT_ENV = { WB_JWT_SECRET: 'test-secret' };

describe('realtime M3: host 转移（契约 E）', () => {
  it('Host 断连 → 窗口到期 → 移交最早 CoHost：hostChanged 广播 + roleChanged 单播 + updated + 审计', async () => {
    const ctx = await createTestContext(JWT_ENV, { hostTransferMs: 200 });
    try {
      const host = await connectAndWait(ctx, { token: signTestToken('user-host', { role: 'Host' }) });
      const coach = await connectAndWait(ctx, { token: signTestToken('user-coach', { role: 'CoHost' }) });
      const member = await connectAndWait(ctx, { token: signTestToken('user-m', { role: 'Participant' }) });
      await joinBoard(host.client, 'board-h1');
      await sleep(5);
      await joinBoard(coach.client, 'board-h1');
      await joinBoard(member.client, 'board-h1');

      const hostChanged = waitForEvent<InteractiveHostChangedPayload>(member.client, 'interactive:hostChanged');
      const coachRole = waitForEvent<InteractiveRoleChangedPayload>(coach.client, 'interactive:roleChanged');
      const updates = collectArgs<[BoardParticipantsPayload]>(member.client, 'board:participants');

      host.client.disconnect();

      // 窗口内不转移
      await expectNoEvent(member.client, 'interactive:hostChanged', 60);
      // 到期：广播 + 单播 + updated + 审计
      expect(await hostChanged).toEqual({ newHostId: 'user-coach' });
      expect(await coachRole).toEqual({ userId: 'user-coach', role: 'Host', grantedWrite: false });
      await waitFor(() =>
        updates.calls.some((c) => c[0].updated?.some((p) => p.userId === 'user-coach' && p.role === 'Host')),
      );
      updates.stop();
      await waitFor(() =>
        memoryAuditOf(ctx.server).entries.some((e) => e.action === 'interactive.hostChanged' && e.target?.id === 'user-coach'),
      );
    } finally {
      await ctx.close();
    }
  });

  it('窗口内同 userId 回归 → 取消转移：无 hostChanged / 无审计；重连角色保持 Host', async () => {
    const ctx = await createTestContext(JWT_ENV, { hostTransferMs: 200 });
    try {
      const host = await connectAndWait(ctx, { token: signTestToken('user-host', { role: 'Host' }) });
      const coach = await connectAndWait(ctx, { token: signTestToken('user-coach', { role: 'CoHost' }) });
      await joinBoard(host.client, 'board-h2');
      await joinBoard(coach.client, 'board-h2');

      // 断开并等待服务端处理完成（left 广播代表转移窗口已启动）
      const leftEvent = waitForEvent<BoardParticipantsPayload>(coach.client, 'board:participants');
      host.client.disconnect();
      await leftEvent;
      await sleep(30);

      // 窗口内同 userId 回归 → 取消
      const back = await connectAndWait(ctx, { token: signTestToken('user-host', { role: 'Host' }) });
      const backAck = await joinBoard(back.client, 'board-h2');
      if (!backAck.ok) throw new Error('rejoin failed');
      expect(backAck.role).toBe('Host');

      // 超过窗口时长：无转移事件 / 无审计
      await expectNoEvent(coach.client, 'interactive:hostChanged', 350);
      expect(memoryAuditOf(ctx.server).entries.some((e) => e.action === 'interactive.hostChanged')).toBe(false);
    } finally {
      await ctx.close();
    }
  });

  it('双 Host join 冲突：已有在线 Host → 新加入者 sessionRole 降 CoHost + 审计 interactive.hostConflict', async () => {
    const ctx = await createTestContext(JWT_ENV, { hostTransferMs: 200 });
    try {
      const h1 = await connectAndWait(ctx, { token: signTestToken('user-h1', { role: 'Host' }) });
      await joinBoard(h1.client, 'board-h3');

      const h2 = await connectAndWait(ctx, { token: signTestToken('user-h2', { role: 'Host' }) });
      const ack = await joinBoard(h2.client, 'board-h3');
      if (!ack.ok) throw new Error('join failed');
      expect(ack.role).toBe('CoHost');
      expect(ack.participants.find((p) => p.userId === 'user-h2')?.role).toBe('CoHost');
      await waitFor(() =>
        memoryAuditOf(ctx.server).entries.some((e) => e.action === 'interactive.hostConflict' && e.userId === 'user-h2'),
      );
    } finally {
      await ctx.close();
    }
  });

  it('无 CoHost → 移交最早可写角色（Participant）；无候选（仅 Viewer）→ 放弃移交', async () => {
    const ctx = await createTestContext(JWT_ENV, { hostTransferMs: 150 });
    try {
      // 场景 1：Host + Participant → Participant 成为 Host
      const host = await connectAndWait(ctx, { token: signTestToken('user-h', { role: 'Host' }) });
      const member = await connectAndWait(ctx, { token: signTestToken('user-m', { role: 'Participant' }) });
      await joinBoard(host.client, 'board-h4');
      await joinBoard(member.client, 'board-h4');
      const hostChanged = waitForEvent<InteractiveHostChangedPayload>(member.client, 'interactive:hostChanged');
      host.client.disconnect();
      expect(await hostChanged).toEqual({ newHostId: 'user-m' });

      // 场景 2：另一房间 Host + Viewer（Viewer 非可写角色）→ 到期放弃
      const host2 = await connectAndWait(ctx, { token: signTestToken('user-h2', { role: 'Host' }) });
      const viewer = await connectAndWait(ctx, { token: signTestToken('user-v', { role: 'Viewer' }) });
      await joinBoard(host2.client, 'board-h5');
      await joinBoard(viewer.client, 'board-h5');
      host2.client.disconnect();
      await expectNoEvent(viewer.client, 'interactive:hostChanged', 350);
      expect(memoryAuditOf(ctx.server).entries.filter((e) => e.action === 'interactive.hostChanged').length).toBe(1);
    } finally {
      await ctx.close();
    }
  });
});
