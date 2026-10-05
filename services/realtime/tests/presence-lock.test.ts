/**
 * realtime M2 契约测试（T2a）——presence:preview 泛化转发 + 软锁全生命周期。
 *
 * 全部离线：随机端口自起自停；默认 MemoryAuditSink。
 * 覆盖：
 * - presence 转发（排除发送者 / userId 服务端覆盖 / 未入房静默 / 跨房不达 / 高频流不落审计）；
 * - 锁全生命周期（授予 / 占用单播拒绝 / 只读角色拒绝 / 未入房回执 / 释放 / 续约 /
 *   TTL 超时释放 / 断连释放 / leave 释放 / 过期后他人可获）；
 * - board:joined / joinAck 锁表快照（对象 map：elementId → {userId, expiresAt}，不含 socketId）；
 * - 审计（lock.acquired / lock.denied / lock.released / lock.expired；renew 心跳与 presence 不落）。
 */

import { describe, expect, it } from 'vitest';
import type {
  BoardJoinedPayload,
  BoardLeaveAck,
  LockAcquireAck,
  LockChangedPayload,
  LockReleaseAck,
  LockRenewAck,
  PresencePreviewOutPayload,
} from '../src/types.js';
import {
  collectArgs,
  connectAndWait,
  createTestContext,
  emitAck,
  expectNoEvent,
  joinBoard,
  memoryAuditOf,
  signTestToken,
  sleep,
  waitFor,
  waitForEvent,
} from './helpers.js';

describe('realtime M2 契约: presence:preview 泛化转发', () => {
  it('转发同房其他成员（排除发送者），userId 由服务端覆盖（防伪造）', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      const b = await connectAndWait(ctx);
      await joinBoard(a.client, 'board-pv');
      await joinBoard(b.client, 'board-pv');

      const onB = waitForEvent<PresencePreviewOutPayload>(b.client, 'presence:preview');
      a.client.emit('presence:preview', { kind: 'cursor', x: 12, y: 34, userId: 'spoofed' });
      const received = await onB;
      expect(received).toEqual({ kind: 'cursor', x: 12, y: 34, userId: a.session.userId });

      await expectNoEvent(a.client, 'presence:preview'); // 排除发送者
    } finally {
      await ctx.close();
    }
  });

  it('未入房 / 跨房 → 静默忽略（不广播、不建房间、不落审计）', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      const b = await connectAndWait(ctx);
      await joinBoard(b.client, 'board-pv2');

      // 未入房：静默忽略
      a.client.emit('presence:preview', { kind: 'ink' });
      await expectNoEvent(b.client, 'presence:preview');
      expect(ctx.server.rooms.roomCount).toBe(1);

      // 跨房：不同房间不互达
      await joinBoard(a.client, 'board-other');
      a.client.emit('presence:preview', { kind: 'ink' });
      await expectNoEvent(b.client, 'presence:preview');

      // 高频流不落审计
      const sink = memoryAuditOf(ctx.server);
      expect(sink.entries.some((entry) => entry.action.startsWith('presence'))).toBe(false);
    } finally {
      await ctx.close();
    }
  });
});

describe('realtime M2 契约: 软锁生命周期', () => {
  it('lock:acquire 空闲 → ack 授予 + 广播 lock:changed(acquired)（排除发送者）+ 审计', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      const b = await connectAndWait(ctx);
      await joinBoard(a.client, 'board-lock');
      await joinBoard(b.client, 'board-lock');

      const onB = waitForEvent<LockChangedPayload>(b.client, 'lock:changed');
      const ack = await emitAck<LockAcquireAck>(a.client, 'lock:acquire', { elementId: 'el-1' });
      if (!ack.ok) throw new Error(`expected ok ack, got ${JSON.stringify(ack)}`);
      if (!ack.granted) throw new Error('expected granted:true');
      expect(ack.elementId).toBe('el-1');
      expect(ack.expiresAt).toBeGreaterThan(Date.now());

      const changed = await onB;
      expect(changed).toEqual({
        elementId: 'el-1',
        userId: a.session.userId,
        action: 'acquired',
        expiresAt: ack.expiresAt,
      });
      await expectNoEvent(a.client, 'lock:changed');

      const sink = memoryAuditOf(ctx.server);
      expect(sink.entries).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            action: 'lock.acquired',
            userId: a.session.userId,
            boardId: 'board-lock',
            result: 'success',
          }),
        ]),
      );
    } finally {
      await ctx.close();
    }
  });

  it('lock:acquire 已被他人占用 → ack {granted:false, holderUserId}（单播不广播）+ 审计 lock.denied', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      const b = await connectAndWait(ctx);
      await joinBoard(a.client, 'board-lock2');
      await joinBoard(b.client, 'board-lock2');
      // 2026-11 修订：free 默认 ≥Write 可写——Participant（第二加入者）无需授权即可锁。

      const first = await emitAck<LockAcquireAck>(a.client, 'lock:acquire', { elementId: 'el-busy' });
      expect(first).toMatchObject({ ok: true, granted: true });

      const aChanges = collectArgs<[LockChangedPayload]>(a.client, 'lock:changed');
      try {
        const second = await emitAck<LockAcquireAck>(b.client, 'lock:acquire', { elementId: 'el-busy' });
        expect(second).toEqual({ ok: true, granted: false, holderUserId: a.session.userId });
        await sleep(80);
        expect(aChanges.calls.length).toBe(0); // busy 拒绝：单播不广播
      } finally {
        aChanges.stop();
      }

      const sink = memoryAuditOf(ctx.server);
      expect(sink.entries).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            action: 'lock.denied',
            userId: b.session.userId,
            boardId: 'board-lock2',
            result: 'denied',
          }),
        ]),
      );
    } finally {
      await ctx.close();
    }
  });

  it('lock:acquire 只读角色（Viewer）→ {ok:false, reason:forbidden} + 审计；不广播', async () => {
    const ctx = await createTestContext({ WB_JWT_SECRET: 'test-secret' });
    try {
      const viewer = await connectAndWait(ctx, { token: signTestToken('user-viewer', { role: 'Viewer' }) });
      const writer = await connectAndWait(ctx, { token: signTestToken('user-writer') });
      expect(viewer.session.role).toBe('Viewer');
      await joinBoard(viewer.client, 'board-lock3');
      await joinBoard(writer.client, 'board-lock3');

      const ack = await emitAck<LockAcquireAck>(viewer.client, 'lock:acquire', { elementId: 'el-v' });
      expect(ack).toEqual({ ok: false, reason: 'forbidden' });
      await expectNoEvent(writer.client, 'lock:changed');

      const sink = memoryAuditOf(ctx.server);
      expect(sink.entries).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            action: 'lock.denied',
            userId: 'user-viewer',
            boardId: 'board-lock3',
            result: 'denied',
          }),
        ]),
      );
    } finally {
      await ctx.close();
    }
  });

  it('锁事件未入房 → 轻量失败回执（acquire/release 带 reason；renew 最小形态）', async () => {
    const ctx = await createTestContext();
    try {
      const { client } = await connectAndWait(ctx);
      expect(await emitAck<LockAcquireAck>(client, 'lock:acquire', { elementId: 'e' })).toEqual({
        ok: false,
        reason: 'not-in-room',
      });
      expect(await emitAck<LockReleaseAck>(client, 'lock:release', { elementId: 'e' })).toEqual({
        ok: false,
        reason: 'not-in-room',
      });
      expect(await emitAck<LockRenewAck>(client, 'lock:renew', { elementId: 'e' })).toEqual({ ok: false });
    } finally {
      await ctx.close();
    }
  });

  it('lock:release 持有者释放（广播 released）；非持有者 {reason:not-holder} 且锁保持；释放后可获', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      const b = await connectAndWait(ctx);
      await joinBoard(a.client, 'board-lock4');
      await joinBoard(b.client, 'board-lock4');
      // 2026-11 修订：Participant（第二加入者）free 默认可锁，无需授权。
      const acquire = await emitAck<LockAcquireAck>(a.client, 'lock:acquire', { elementId: 'el-r' });
      expect(acquire).toMatchObject({ ok: true, granted: true });

      // 非持有者释放被拒；锁保持（b 再 acquire 仍 busy）
      const bRelease = await emitAck<LockReleaseAck>(b.client, 'lock:release', { elementId: 'el-r' });
      expect(bRelease).toEqual({ ok: false, reason: 'not-holder' });
      const bRetry = await emitAck<LockAcquireAck>(b.client, 'lock:acquire', { elementId: 'el-r' });
      expect(bRetry).toEqual({ ok: true, granted: false, holderUserId: a.session.userId });

      // 持有者释放：ack + 广播给 b（排除发送者）
      const onB = waitForEvent<LockChangedPayload>(b.client, 'lock:changed');
      const aRelease = await emitAck<LockReleaseAck>(a.client, 'lock:release', { elementId: 'el-r' });
      expect(aRelease).toEqual({ ok: true });
      const changed = await onB;
      expect(changed).toEqual({ elementId: 'el-r', userId: a.session.userId, action: 'released' });
      await expectNoEvent(a.client, 'lock:changed');

      // 释放后 b 可获得
      const bAcquire = await emitAck<LockAcquireAck>(b.client, 'lock:acquire', { elementId: 'el-r' });
      expect(bAcquire).toMatchObject({ ok: true, granted: true });

      const sink = memoryAuditOf(ctx.server);
      expect(sink.entries).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            action: 'lock.released',
            userId: a.session.userId,
            boardId: 'board-lock4',
            detail: 'explicit',
            result: 'success',
          }),
        ]),
      );
    } finally {
      await ctx.close();
    }
  });

  it('lock:renew 持有者续约（TTL 延长）；非持有者 {ok:false}；不落审计', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      const b = await connectAndWait(ctx);
      await joinBoard(a.client, 'board-lock5');
      await joinBoard(b.client, 'board-lock5');
      const acquire = await emitAck<LockAcquireAck>(a.client, 'lock:acquire', { elementId: 'el-n' });
      if (!acquire.ok) throw new Error(`expected ok ack, got ${JSON.stringify(acquire)}`);
      if (!acquire.granted) throw new Error('expected granted:true');

      const bRenew = await emitAck<LockRenewAck>(b.client, 'lock:renew', { elementId: 'el-n' });
      expect(bRenew).toEqual({ ok: false });

      await sleep(5);
      const aRenew = await emitAck<LockRenewAck>(a.client, 'lock:renew', { elementId: 'el-n' });
      if (!aRenew.ok) throw new Error(`expected ok ack, got ${JSON.stringify(aRenew)}`);
      expect(aRenew.expiresAt).toBeGreaterThan(acquire.expiresAt);

      // 续约心跳不落审计
      const sink = memoryAuditOf(ctx.server);
      expect(sink.entries.some((entry) => entry.action.includes('renew'))).toBe(false);
    } finally {
      await ctx.close();
    }
  });

  it('TTL 到期 → 广播 lock:changed(expired) + 审计 lock.expired；过期后他人可获', async () => {
    const ctx = await createTestContext({}, { lockTtlMs: 120, lockSweepIntervalMs: 20 });
    try {
      const a = await connectAndWait(ctx);
      const b = await connectAndWait(ctx);
      await joinBoard(a.client, 'board-lock6');
      await joinBoard(b.client, 'board-lock6');
      // 2026-11 修订：Participant（第二加入者）free 默认可锁，无需授权。

      const bChanges = collectArgs<[LockChangedPayload]>(b.client, 'lock:changed');
      try {
        const acquire = await emitAck<LockAcquireAck>(a.client, 'lock:acquire', { elementId: 'el-ttl' });
        expect(acquire).toMatchObject({ ok: true, granted: true });

        await waitFor(() => bChanges.calls.some(([c]) => c.action === 'expired'), 3000);
        const expiredCall = bChanges.calls.find(([c]) => c.action === 'expired');
        expect(expiredCall?.[0]).toEqual({ elementId: 'el-ttl', userId: a.session.userId, action: 'expired' });
      } finally {
        bChanges.stop();
      }

      const sink = memoryAuditOf(ctx.server);
      expect(sink.entries).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            action: 'lock.expired',
            userId: a.session.userId,
            boardId: 'board-lock6',
            detail: 'ttl elapsed',
          }),
        ]),
      );

      // 过期后他人可获（锁不再被 a 持有）
      const bAcquire = await emitAck<LockAcquireAck>(b.client, 'lock:acquire', { elementId: 'el-ttl' });
      expect(bAcquire).toMatchObject({ ok: true, granted: true });
    } finally {
      await ctx.close();
    }
  });

  it('断连 → 释放该 socket 全部锁：广播 released + 审计 detail=disconnect', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      const b = await connectAndWait(ctx);
      await joinBoard(a.client, 'board-lock7');
      await joinBoard(b.client, 'board-lock7');
      expect(await emitAck<LockAcquireAck>(a.client, 'lock:acquire', { elementId: 'el-d1' })).toMatchObject({
        ok: true,
        granted: true,
      });
      expect(await emitAck<LockAcquireAck>(a.client, 'lock:acquire', { elementId: 'el-d2' })).toMatchObject({
        ok: true,
        granted: true,
      });

      const bChanges = collectArgs<[LockChangedPayload]>(b.client, 'lock:changed');
      try {
        a.client.disconnect();
        await waitFor(() => bChanges.calls.length >= 2, 3000);
        const payloads = bChanges.calls.map(([c]) => c);
        expect(payloads).toEqual(
          expect.arrayContaining([
            { elementId: 'el-d1', userId: a.session.userId, action: 'released' },
            { elementId: 'el-d2', userId: a.session.userId, action: 'released' },
          ]),
        );
      } finally {
        bChanges.stop();
      }

      const released = memoryAuditOf(ctx.server).entries.filter((entry) => entry.action === 'lock.released');
      expect(released).toHaveLength(2);
      expect(released.every((entry) => entry.detail === 'disconnect')).toBe(true);
    } finally {
      await ctx.close();
    }
  });

  it('board:joined 携带真实锁表快照（对象 map，不含 socketId）；board:leave → 释放 + 广播 + 审计 detail=leave', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      const b = await connectAndWait(ctx);
      await joinBoard(a.client, 'board-lock8');
      await joinBoard(b.client, 'board-lock8');
      const acquire = await emitAck<LockAcquireAck>(a.client, 'lock:acquire', { elementId: 'el-s' });
      if (!acquire.ok) throw new Error(`expected ok ack, got ${JSON.stringify(acquire)}`);
      if (!acquire.granted) throw new Error('expected granted:true');

      // c 加入：joined / joinAck 均携带锁表快照
      const c = await connectAndWait(ctx);
      const joinedOnC = waitForEvent<BoardJoinedPayload>(c.client, 'board:joined');
      const cAck = await joinBoard(c.client, 'board-lock8');
      if (!cAck.ok) throw new Error(`expected join ok, got ${JSON.stringify(cAck)}`);
      expect(cAck.locks).toEqual({ 'el-s': { userId: a.session.userId, expiresAt: acquire.expiresAt } });
      const joined = await joinedOnC;
      expect(joined.locks).toEqual({ 'el-s': { userId: a.session.userId, expiresAt: acquire.expiresAt } });

      // a 显式 leave → 释放锁：b / c 收到 released 广播
      const onB = waitForEvent<LockChangedPayload>(b.client, 'lock:changed');
      const onC = waitForEvent<LockChangedPayload>(c.client, 'lock:changed');
      const leaveAck = await emitAck<BoardLeaveAck>(a.client, 'board:leave', {});
      expect(leaveAck).toEqual({ ok: true });
      const [bChanged, cChanged] = await Promise.all([onB, onC]);
      expect(bChanged).toEqual({ elementId: 'el-s', userId: a.session.userId, action: 'released' });
      expect(cChanged).toEqual({ elementId: 'el-s', userId: a.session.userId, action: 'released' });

      const released = memoryAuditOf(ctx.server).entries.filter((entry) => entry.action === 'lock.released');
      expect(released).toEqual([
        expect.objectContaining({ userId: a.session.userId, boardId: 'board-lock8', detail: 'leave' }),
      ]);
    } finally {
      await ctx.close();
    }
  });
});
