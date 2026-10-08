/**
 * realtime M3 契约测试（T3.5 checkpoint 服务端侧 / 契约 F/G；《互动白板实时协同设计文档》§7）。
 *
 * 覆盖：
 * - 上传权限与形状校验（未入房 / <CoHost 拒绝 + authz.denied / stateVector、payload 非法）；
 * - payload 上限（UTF-8 字节口径）→ payload-too-large + checkpoint.denied，且不覆盖既有存储；
 * - 存储成功（checkpoint.stored 含 size）与「只存不解释」字节原样；
 * - join 快照下发三路径（无 / 空 lastSeenVersion 下发；非空不下发）；
 * - 阈值触发：单播最早 Host/CoHost 的 board:checkpointRequest（含当前水位）；自举 Host 同样可承接；
 * - inflight 去抖 + 超时放弃后按当前水位重试；候选回传后计数重置；
 * - ops 采样审计：每 32 条已接受 op 落 1 条 ops.sampled（重复入账不计）。
 *
 * 全部离线：随机端口自起自停；阈值 / 超时 / 上限经 options 注入短值。
 */

import { describe, expect, it } from 'vitest';
import type { BoardCheckpointAck, BoardCheckpointRequestPayload, BoardJoinAck, BoardOpsAck } from '../src/types.js';
import {
  collectArgs,
  connectAndWait,
  createTestContext,
  emitAck,
  expectNoEvent,
  joinBoard,
  makeOp,
  memoryAuditOf,
  signTestToken,
  sleep,
  waitFor,
  waitForEvent,
} from './helpers.js';

const JWT_ENV = { WB_JWT_SECRET: 'test-secret' };

describe('realtime M3: checkpoint 服务端侧（契约 F/G）', () => {
  it('上传权限与形状校验：未入房 not-in-room；<CoHost forbidden（+authz.denied）；非法载荷 invalid-argument', async () => {
    const ctx = await createTestContext(JWT_ENV);
    try {
      const host = await connectAndWait(ctx, { token: signTestToken('user-h', { role: 'Host' }) });
      const part = await connectAndWait(ctx, { token: signTestToken('user-p', { role: 'Participant' }) });
      await joinBoard(host.client, 'board-c1');
      await joinBoard(part.client, 'board-c1');

      // 未入房（即使 token 角色够高）
      const stranger = await connectAndWait(ctx, { token: signTestToken('user-s', { role: 'CoHost' }) });
      expect(
        await emitAck<BoardCheckpointAck>(stranger.client, 'board:checkpoint', { stateVector: { s: 1 }, payload: 'x' }),
      ).toEqual({ ok: false, reason: 'not-in-room' });

      // 角色不足：Participant → forbidden + 审计
      expect(
        await emitAck<BoardCheckpointAck>(part.client, 'board:checkpoint', { stateVector: { p: 1 }, payload: 'x' }),
      ).toEqual({ ok: false, reason: 'forbidden' });
      await waitFor(() =>
        memoryAuditOf(ctx.server).entries.some((e) => e.action === 'authz.denied' && e.userId === 'user-p'),
      );

      // 形状非法：stateVector 值非法 / payload 非字符串
      expect(
        await emitAck<BoardCheckpointAck>(host.client, 'board:checkpoint', { stateVector: { h: 'x' }, payload: 'x' }),
      ).toEqual({ ok: false, reason: 'invalid-argument' });
      expect(
        await emitAck<BoardCheckpointAck>(host.client, 'board:checkpoint', { stateVector: { h: -1 }, payload: 'x' }),
      ).toEqual({ ok: false, reason: 'invalid-argument' });
      expect(
        await emitAck<BoardCheckpointAck>(host.client, 'board:checkpoint', { stateVector: { h: 1 }, payload: 42 }),
      ).toEqual({ ok: false, reason: 'invalid-argument' });
    } finally {
      await ctx.close();
    }
  });

  it('payload 超限（UTF-8 字节口径）→ payload-too-large + checkpoint.denied；不覆盖既有存储', async () => {
    const ctx = await createTestContext(JWT_ENV, { checkpointMaxPayloadBytes: 10 });
    try {
      const host = await connectAndWait(ctx, { token: signTestToken('user-h', { role: 'Host' }) });
      await joinBoard(host.client, 'board-c2');

      // '中文😀' = 3 + 3 + 4 = 10 字节 → 恰好通过
      expect(
        await emitAck<BoardCheckpointAck>(host.client, 'board:checkpoint', { stateVector: { h: 1 }, payload: '中文😀' }),
      ).toEqual({ ok: true });

      // 追加 1 字节 → 11 > 10 拒绝 + 审计
      const over = await emitAck<BoardCheckpointAck>(host.client, 'board:checkpoint', {
        stateVector: { h: 2 },
        payload: '中文😀x',
      });
      expect(over).toEqual({ ok: false, reason: 'payload-too-large' });
      await waitFor(() =>
        memoryAuditOf(ctx.server).entries.some((e) => e.action === 'checkpoint.denied' && e.userId === 'user-h'),
      );

      // 存储仍是第一次的（被拒上传未覆盖）
      const late = await connectAndWait(ctx, { token: signTestToken('user-l', { role: 'Viewer' }) });
      const ack = await joinBoard(late.client, 'board-c2');
      if (!ack.ok) throw new Error('join failed');
      expect(ack.snapshot).toEqual({ stateVector: { h: 1 }, payload: '中文😀' });
    } finally {
      await ctx.close();
    }
  });

  it('存储成功（只存不解释）+ join.snapshot 三路径：无/空 lastSeenVersion 下发；非空不下发', async () => {
    const ctx = await createTestContext(JWT_ENV);
    try {
      const host = await connectAndWait(ctx, { token: signTestToken('user-h', { role: 'Host' }) });
      await joinBoard(host.client, 'board-c3');
      const payload = '<<not-json>>\n😀 "中文" {}';
      expect(
        await emitAck<BoardCheckpointAck>(host.client, 'board:checkpoint', { stateVector: { h: 7 }, payload }),
      ).toEqual({ ok: true });
      await waitFor(() => {
        const stored = memoryAuditOf(ctx.server).entries.find((e) => e.action === 'checkpoint.stored');
        return stored !== undefined && (stored.detail ?? '').includes('size=');
      });

      // 路径 1：无 lastSeenVersion → 下发 snapshot（payload 字节原样）
      const n1 = await connectAndWait(ctx, { token: signTestToken('user-n1', { role: 'Viewer' }) });
      const ack1 = await joinBoard(n1.client, 'board-c3');
      if (!ack1.ok) throw new Error('join failed');
      expect(ack1.snapshot).toEqual({ stateVector: { h: 7 }, payload });

      // 路径 2：空 lastSeenVersion（{}）→ 视为新成员，仍然下发
      const n2 = await connectAndWait(ctx, { token: signTestToken('user-n2', { role: 'Viewer' }) });
      const ack2 = await joinBoard(n2.client, 'board-c3', { lastSeenVersion: {} });
      if (!ack2.ok) throw new Error('join failed');
      expect(ack2.snapshot).toEqual({ stateVector: { h: 7 }, payload });

      // 路径 3：非空 lastSeenVersion → 走增量回放，不下发 snapshot
      const n3 = await connectAndWait(ctx, { token: signTestToken('user-n3', { role: 'Viewer' }) });
      const ack3 = await joinBoard(n3.client, 'board-c3', { lastSeenVersion: { h: 7 } });
      if (!ack3.ok) throw new Error('join failed');
      expect(ack3.snapshot).toBeUndefined();
    } finally {
      await ctx.close();
    }
  });

  it('阈值触发：单播最早 Host/CoHost 的 board:checkpointRequest（含当前水位）；自举 Host 同样可承接', async () => {
    const ctx = await createTestContext(JWT_ENV, { checkpointOpThreshold: 3 });
    try {
      // 房间 1：co1（最早）→ co2 → host；候选应为 co1
      const co1 = await connectAndWait(ctx, { token: signTestToken('user-co1', { role: 'CoHost' }) });
      const co2 = await connectAndWait(ctx, { token: signTestToken('user-co2', { role: 'CoHost' }) });
      const host = await connectAndWait(ctx, { token: signTestToken('user-h', { role: 'Host' }) });
      await joinBoard(co1.client, 'board-t1');
      await sleep(5);
      await joinBoard(co2.client, 'board-t1');
      await sleep(5);
      await joinBoard(host.client, 'board-t1');

      // 未达阈值：不触发
      await emitAck<BoardOpsAck>(host.client, 'board:ops', [makeOp('h', 1), makeOp('h', 2)]);
      await expectNoEvent(co1.client, 'board:checkpointRequest', 100);

      // 第 3 条 → 触发：co1 收到；co2 / host 不收到
      const request = waitForEvent<BoardCheckpointRequestPayload>(co1.client, 'board:checkpointRequest');
      const co2Window = expectNoEvent(co2.client, 'board:checkpointRequest', 120);
      const hostWindow = expectNoEvent(host.client, 'board:checkpointRequest', 120);
      await emitAck<BoardOpsAck>(host.client, 'board:ops', [makeOp('h', 3)]);
      expect(await request).toEqual({ stateVector: { h: 3 } });
      await co2Window;
      await hostWindow;
      await waitFor(() =>
        memoryAuditOf(ctx.server).entries.some(
          (e) => e.action === 'checkpoint.requested' && e.userId === 'system' && e.target?.id === 'user-co1',
        ),
      );

      // 房间 2：Participant 首入自举 Host → 达标触发，单播给（自举）Host
      const solo = await connectAndWait(ctx, { token: signTestToken('user-solo', { role: 'Participant' }) });
      const soloJoined = await joinBoard(solo.client, 'board-t2');
      if (!soloJoined.ok) throw new Error('join failed');
      expect(soloJoined.role).toBe('Host');
      const soloRequest = waitForEvent<BoardCheckpointRequestPayload>(solo.client, 'board:checkpointRequest');
      await emitAck<BoardOpsAck>(solo.client, 'board:ops', [makeOp('solo', 1), makeOp('solo', 2), makeOp('solo', 3)]);
      expect(await soloRequest).toEqual({ stateVector: { solo: 3 } });
      await waitFor(
        () => memoryAuditOf(ctx.server).entries.filter((e) => e.action === 'checkpoint.requested').length === 2,
      );
    } finally {
      await ctx.close();
    }
  });

  it('inflight 去抖：请求期间不重复触发；超时放弃后按当前水位重试', async () => {
    const ctx = await createTestContext(JWT_ENV, { checkpointOpThreshold: 2, checkpointTimeoutMs: 500 });
    try {
      const co = await connectAndWait(ctx, { token: signTestToken('user-co', { role: 'CoHost' }) });
      const host = await connectAndWait(ctx, { token: signTestToken('user-h', { role: 'Host' }) });
      await joinBoard(co.client, 'board-t3');
      await joinBoard(host.client, 'board-t3');

      const requests = collectArgs<[BoardCheckpointRequestPayload]>(co.client, 'board:checkpointRequest');
      await emitAck<BoardOpsAck>(host.client, 'board:ops', [makeOp('h', 1), makeOp('h', 2)]);
      await waitFor(() => requests.calls.length === 1);

      // inflight 期间继续入账（水位 2 → 4）不重申
      await emitAck<BoardOpsAck>(host.client, 'board:ops', [makeOp('h', 3), makeOp('h', 4)]);
      await sleep(100);
      expect(requests.calls.length).toBe(1);

      // 超时放弃（未上传）→ 下次 op 批按当前水位再次触发
      await sleep(500);
      await emitAck<BoardOpsAck>(host.client, 'board:ops', [makeOp('h', 5)]);
      await waitFor(() => requests.calls.length === 2);
      expect(requests.calls.map((call) => call[0].stateVector)).toEqual([{ h: 2 }, { h: 5 }]);
      requests.stop();
    } finally {
      await ctx.close();
    }
  });

  it('候选回传存储：ack + checkpoint.stored；计数重置（需重新累计）；inflight 清除后再次触发', async () => {
    const ctx = await createTestContext(JWT_ENV, { checkpointOpThreshold: 2, checkpointTimeoutMs: 2000 });
    try {
      const co = await connectAndWait(ctx, { token: signTestToken('user-co', { role: 'CoHost' }) });
      const host = await connectAndWait(ctx, { token: signTestToken('user-h', { role: 'Host' }) });
      await joinBoard(co.client, 'board-t4');
      await joinBoard(host.client, 'board-t4');

      const requests = collectArgs<[BoardCheckpointRequestPayload]>(co.client, 'board:checkpointRequest');
      await emitAck<BoardOpsAck>(host.client, 'board:ops', [makeOp('h', 1), makeOp('h', 2)]);
      await waitFor(() => requests.calls.length === 1);

      // 候选照抄请求水位回传
      const first = requests.calls[0];
      if (!first) throw new Error('no checkpoint request');
      expect(
        await emitAck<BoardCheckpointAck>(co.client, 'board:checkpoint', { stateVector: first[0].stateVector, payload: 'state-blob' }),
      ).toEqual({ ok: true });
      await waitFor(() => memoryAuditOf(ctx.server).entries.filter((e) => e.action === 'checkpoint.stored').length === 1);

      // 计数重置：再入账 1 条不触发
      await emitAck<BoardOpsAck>(host.client, 'board:ops', [makeOp('h', 3)]);
      await sleep(80);
      expect(requests.calls.length).toBe(1);

      // 重新累计到阈值 → 第二次触发（inflight 已被上传清除）
      await emitAck<BoardOpsAck>(host.client, 'board:ops', [makeOp('h', 4)]);
      await waitFor(() => requests.calls.length === 2);
      requests.stop();

      // 存储可复用：后续 join 收到该 checkpoint
      const late = await connectAndWait(ctx, { token: signTestToken('user-late', { role: 'Viewer' }) });
      const lateAck: BoardJoinAck = await joinBoard(late.client, 'board-t4');
      if (!lateAck.ok) throw new Error('join failed');
      expect(lateAck.snapshot?.payload).toBe('state-blob');
    } finally {
      await ctx.close();
    }
  });

  it('ops 采样审计：每 32 条已接受 op 落 1 条 ops.sampled；重复入账不计', async () => {
    const ctx = await createTestContext(JWT_ENV, { checkpointOpThreshold: 5000 });
    try {
      const host = await connectAndWait(ctx, { token: signTestToken('user-h', { role: 'Host' }) });
      await joinBoard(host.client, 'board-s1');
      const sampledCount = (): number =>
        memoryAuditOf(ctx.server).entries.filter((e) => e.action === 'ops.sampled').length;

      // 32 条 → 1 条采样
      const batch1 = Array.from({ length: 32 }, (_, index) => makeOp('h', index + 1));
      await emitAck<BoardOpsAck>(host.client, 'board:ops', batch1);
      await waitFor(() => sampledCount() === 1);

      // 31 条 + 全量重复（dup 不入账）→ 不新增
      const batch2 = Array.from({ length: 31 }, (_, index) => makeOp('h', index + 33));
      await emitAck<BoardOpsAck>(host.client, 'board:ops', batch2);
      await emitAck<BoardOpsAck>(host.client, 'board:ops', batch1);
      await sleep(80);
      expect(sampledCount()).toBe(1);

      // 第 64 条 → 第 2 条采样
      await emitAck<BoardOpsAck>(host.client, 'board:ops', [makeOp('h', 64)]);
      await waitFor(() => sampledCount() === 2);
    } finally {
      await ctx.close();
    }
  });
});
