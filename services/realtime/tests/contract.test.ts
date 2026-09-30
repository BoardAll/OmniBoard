/**
 * realtime M1 契约测试（T1.3）——对齐《互动白板实时协同设计文档》§6 事件契约（M1 权威）。
 *
 * 覆盖：
 * - 参与者生命周期（board:participants 广播 / joined 快照 / leave + 断连）；
 * - 权限拒绝（Viewer → room:error + 拒绝 ack + 审计）；NotInRoom；INVALID_ARGUMENT；
 * - oplog 流水账：去重 dup / seq gap missingSeqs / 广播排除发送者 / 单播精确送达；
 * - 同步裁差分：joinAck 全量+差分 / join(lastSeenVersion) 重连增量 / fetchOps；
 * - 认证路径：JWT 过期、生产缺密钥收紧、匿名回落与拒连审计；
 * - 审计 JSONL 落盘（房间生命周期）与脱敏（不含 token / op 内容 / 密钥）。
 *
 * 全部离线：随机端口自起自停；默认 MemoryAuditSink（落盘用例显式 WB_REALTIME_AUDIT_LOG）。
 */

import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import type {
  BoardDirectAck,
  BoardDirectedPayload,
  BoardFetchOpsResponse,
  BoardJoinAck,
  BoardJoinAckResponse,
  BoardJoinedPayload,
  BoardLeaveAck,
  BoardOpsAck,
  BoardOpsMeta,
  BoardParticipantsPayload,
  Op,
  RoomErrorPayload,
} from '../src/types.js';
import {
  collectArgs,
  connectAndWait,
  createTestContext,
  emitAck,
  expectNoEvent,
  failureError,
  joinBoard,
  makeOp,
  memoryAuditOf,
  readAuditEntries,
  signTestToken,
  sleep,
  waitFor,
  waitForArgs,
  waitForConnectError,
  waitForDisconnect,
  waitForEvent,
} from './helpers.js';

describe('realtime 契约: 参与者生命周期', () => {
  it('join 快照含全部成员（插入序）；新成员广播 {joined}；leave 广播 {left} 并关闭连接', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      const ackA = await joinBoard(a.client, 'board-p');
      if (!ackA.ok) throw new Error(`join failed: ${failureError(ackA).code}`);
      expect(ackA.participants.map((p) => p.userId)).toEqual([a.session.userId]);
      expect(ackA.participants[0]?.socketId).toBe(a.client.id);
      expect(typeof ackA.participants[0]?.joinedAt).toBe('number');
      expect(ackA.stateVector).toEqual({});

      const joinedOnA = waitForEvent<BoardParticipantsPayload>(a.client, 'board:participants');
      const b = await connectAndWait(ctx);
      const ackB = await joinBoard(b.client, 'board-p');
      if (!ackB.ok) throw new Error('join b failed');
      expect(ackB.participants.map((p) => p.userId)).toEqual([a.session.userId, b.session.userId]);
      expect(ackB.participants.every((p) => p.role === 'Participant')).toBe(true);

      const joinedPayload = await joinedOnA;
      expect(joinedPayload.joined).toHaveLength(1);
      expect(joinedPayload.joined?.[0]?.userId).toBe(b.session.userId);
      expect(joinedPayload.joined?.[0]?.socketId).toBe(b.client.id);

      const leftOnA = waitForEvent<BoardParticipantsPayload>(a.client, 'board:participants');
      const disconnectOnB = waitForDisconnect(b.client);
      const leaveAck = await emitAck<BoardLeaveAck>(b.client, 'board:leave', {});
      expect(leaveAck).toEqual({ ok: true });
      expect(await disconnectOnB).toMatch(/server disconnect/);

      const leftPayload = await leftOnA;
      expect(leftPayload.left).toHaveLength(1);
      expect(leftPayload.left?.[0]?.userId).toBe(b.session.userId);
    } finally {
      await ctx.close();
    }
  });
});

describe('realtime 契约: 权限与防护', () => {
  it('Viewer 提交 ops → 拒绝 ack + room:error(Forbidden) + 审计；只读 fetchOps 放行；不广播', async () => {
    const ctx = await createTestContext({ WB_JWT_SECRET: 'test-secret' });
    try {
      const viewer = await connectAndWait(ctx, { token: signTestToken('user-viewer', { role: 'Viewer' }) });
      expect(viewer.session.role).toBe('Viewer');
      const writer = await connectAndWait(ctx, { token: signTestToken('user-writer', { role: 'Participant' }) });
      await joinBoard(viewer.client, 'board-perm');
      await joinBoard(writer.client, 'board-perm');

      const writerOps = collectArgs<[Op[], BoardOpsMeta?]>(writer.client, 'board:ops');
      const roomErrorOnViewer = waitForEvent<RoomErrorPayload>(viewer.client, 'room:error');
      const ack = await emitAck<BoardOpsAck>(viewer.client, 'board:ops', [makeOp('user-viewer', 1)]);
      expect(ack.ok).toBe(false);
      expect(failureError(ack).code).toBe('Forbidden');
      expect((await roomErrorOnViewer).code).toBe('Forbidden');

      // 只读操作放行（fetchOps 不受写权限限制）
      const fetchAck = await emitAck<BoardFetchOpsResponse>(viewer.client, 'board:fetchOps', {
        actor: 'user-writer',
        fromSeq: 0,
      });
      expect(fetchAck).toEqual({ ok: true, replayed: 0 });

      await sleep(120);
      expect(writerOps.calls.length).toBe(0); // 被拒绝的 op 不落日志、不广播
      writerOps.stop();

      const sink = memoryAuditOf(ctx.server);
      expect(sink.entries).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ action: 'authz.denied', userId: 'user-viewer', boardId: 'board-perm', result: 'denied' }),
        ]),
      );
    } finally {
      await ctx.close();
    }
  });

  it('非法载荷 → INVALID_ARGUMENT（仅 ack，不发 room:error）', async () => {
    const ctx = await createTestContext();
    try {
      const { client } = await connectAndWait(ctx);
      await joinBoard(client, 'board-inv');

      const empty = await emitAck<BoardOpsAck>(client, 'board:ops', []);
      expect(failureError(empty).code).toBe('INVALID_ARGUMENT');

      const badOp = await emitAck<BoardOpsAck>(client, 'board:ops', [{ actor: 'a' }]);
      expect(failureError(badOp).code).toBe('INVALID_ARGUMENT');

      const badFetch = await emitAck<BoardFetchOpsResponse>(client, 'board:fetchOps', { actor: '', fromSeq: -1 });
      expect(failureError(badFetch).code).toBe('INVALID_ARGUMENT');

      const badJoin = await emitAck<BoardJoinAck>(client, 'board:join', { boardId: '' });
      expect(failureError(badJoin).code).toBe('INVALID_ARGUMENT');

      await expectNoEvent(client, 'room:error');
    } finally {
      await ctx.close();
    }
  });

  it('未 join 即提交 ops → NotInRoom（ack + room:error + 审计 authz.denied）', async () => {
    const ctx = await createTestContext();
    try {
      const { client } = await connectAndWait(ctx);
      const roomError = waitForEvent<RoomErrorPayload>(client, 'room:error');
      const ack = await emitAck<BoardOpsAck>(client, 'board:ops', [makeOp('a', 1)]);
      expect(failureError(ack).code).toBe('NotInRoom');
      expect((await roomError).code).toBe('NotInRoom');

      const sink = memoryAuditOf(ctx.server);
      expect(sink.entries.some((e) => e.action === 'authz.denied' && e.result === 'denied')).toBe(true);
    } finally {
      await ctx.close();
    }
  });
});

describe('realtime 契约: oplog 流水账（去重 / gap / 广播）', () => {
  it('同 (actor,seq) 重复提交 → ack {ok:true, dup:true} 且不重复广播；混合批仅广播新增部分', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      const b = await connectAndWait(ctx);
      await joinBoard(a.client, 'board-dup');
      await joinBoard(b.client, 'board-dup');

      const op1 = makeOp('actor-1', 1);
      const op2 = makeOp('actor-1', 2);
      const bOps = collectArgs<[Op[], BoardOpsMeta?]>(b.client, 'board:ops');

      expect(await emitAck<BoardOpsAck>(a.client, 'board:ops', [op1])).toEqual({ ok: true });
      await waitFor(() => bOps.calls.length === 1);

      // 幂等重放：同键同体 → dup
      expect(await emitAck<BoardOpsAck>(a.client, 'board:ops', [op1])).toEqual({ ok: true, dup: true });
      await sleep(80);
      expect(bOps.calls.length).toBe(1); // dup 不重复广播

      // 混合批 [dup, new] → ok（dup 缺省），仅广播新增
      expect(await emitAck<BoardOpsAck>(a.client, 'board:ops', [op1, op2])).toEqual({ ok: true });
      await waitFor(() => bOps.calls.length === 2);
      expect(bOps.calls[1]?.[0]).toEqual([op2]);
      bOps.stop();
    } finally {
      await ctx.close();
    }
  });

  it('seq 断档 → ack {ok:false, missingSeqs}；批内已接受部分保留；补发后接续', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      const b = await connectAndWait(ctx);
      await joinBoard(a.client, 'board-gap');
      await joinBoard(b.client, 'board-gap');

      const bOps = collectArgs<[Op[], BoardOpsMeta?]>(b.client, 'board:ops');

      const gap = await emitAck<BoardOpsAck>(a.client, 'board:ops', [makeOp('actor-g', 2)]);
      expect(gap).toEqual({ ok: false, missingSeqs: [1] });
      await sleep(80);
      expect(bOps.calls.length).toBe(0); // 断档 op 不入日志、不广播

      const partial = await emitAck<BoardOpsAck>(a.client, 'board:ops', [
        makeOp('actor-g', 1),
        makeOp('actor-g', 3),
      ]);
      expect(partial).toEqual({ ok: false, missingSeqs: [2] });
      await waitFor(() => bOps.calls.length === 1);
      expect(bOps.calls[0]?.[0]).toEqual([makeOp('actor-g', 1)]); // 已接受部分保留并广播

      const fill = await emitAck<BoardOpsAck>(a.client, 'board:ops', [
        makeOp('actor-g', 2),
        makeOp('actor-g', 3),
      ]);
      expect(fill).toEqual({ ok: true });
      await waitFor(() => bOps.calls.length === 2);
      expect(bOps.calls[1]?.[0]).toEqual([makeOp('actor-g', 2), makeOp('actor-g', 3)]);
      bOps.stop();
    } finally {
      await ctx.close();
    }
  });

  it('广播（board 房间）排除发送者；fetchOps 响应单播（socket.id）仅达请求者', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      const b = await connectAndWait(ctx);
      await joinBoard(a.client, 'board-bc');
      await joinBoard(b.client, 'board-bc');

      const aOps = collectArgs<[Op[], BoardOpsMeta?]>(a.client, 'board:ops');
      const bOps = collectArgs<[Op[], BoardOpsMeta?]>(b.client, 'board:ops');

      const opA = makeOp('actor-bc', 1);
      expect(await emitAck<BoardOpsAck>(a.client, 'board:ops', [opA])).toEqual({ ok: true });
      await waitFor(() => bOps.calls.length === 1);
      expect(bOps.calls[0]?.[0]).toEqual([opA]);
      expect(bOps.calls[0]?.[1]).toEqual({ from: a.session.userId });
      await sleep(80);
      expect(aOps.calls.length).toBe(0); // 排除发送者

      const fetchAck = await emitAck<BoardFetchOpsResponse>(b.client, 'board:fetchOps', {
        actor: 'actor-bc',
        fromSeq: 0,
      });
      expect(fetchAck).toEqual({ ok: true, replayed: 1 });
      await waitFor(() => bOps.calls.length === 2);
      expect(bOps.calls[1]?.[1]).toEqual({ replay: true });
      await sleep(80);
      expect(aOps.calls.length).toBe(0); // 单播不达其他成员

      aOps.stop();
      bOps.stop();
    } finally {
      await ctx.close();
    }
  });
});

describe('realtime 契约: 同步裁差分（joinAck / lastSeenVersion / fetchOps）', () => {
  it('board:joinAck：空水位 → 全量回放；携带水位 → 差分回放', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      await joinBoard(a.client, 'board-sync');
      const op1 = makeOp('actor-s', 1);
      const op2 = makeOp('actor-s', 2);
      expect(await emitAck<BoardOpsAck>(a.client, 'board:ops', [op1, op2])).toEqual({ ok: true });

      const b = await connectAndWait(ctx);
      await joinBoard(b.client, 'board-sync');

      const onFullReplay = waitForArgs<[Op[], BoardOpsMeta?]>(b.client, 'board:ops');
      const fullAck = await emitAck<BoardJoinAckResponse>(b.client, 'board:joinAck', {});
      expect(fullAck).toEqual({ ok: true, replayed: 2 });
      const [fullOps, fullMeta] = await onFullReplay;
      expect(fullOps).toEqual([op1, op2]);
      expect(fullMeta).toEqual({ replay: true });

      const onDiffReplay = waitForArgs<[Op[], BoardOpsMeta?]>(b.client, 'board:ops');
      const diffAck = await emitAck<BoardJoinAckResponse>(b.client, 'board:joinAck', {
        localSeqs: { 'actor-s': 1 },
      });
      expect(diffAck).toEqual({ ok: true, replayed: 1 });
      const [diffOps] = await onDiffReplay;
      expect(diffOps).toEqual([op2]);
    } finally {
      await ctx.close();
    }
  });

  it('board:join 携带 lastSeenVersion → 立即回放其后增量（§5.12 重连）', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      await joinBoard(a.client, 'board-r');
      const op1 = makeOp('actor-r', 1);
      const op2 = makeOp('actor-r', 2);
      expect(await emitAck<BoardOpsAck>(a.client, 'board:ops', [op1, op2])).toEqual({ ok: true });

      const b = await connectAndWait(ctx);
      const joinedOnB = waitForEvent<BoardJoinedPayload>(b.client, 'board:joined');
      const onReplay = waitForArgs<[Op[], BoardOpsMeta?]>(b.client, 'board:ops');
      const ack = await emitAck<BoardJoinAck>(b.client, 'board:join', {
        boardId: 'board-r',
        lastSeenVersion: { 'actor-r': 1 },
      });
      expect(ack.ok).toBe(true);
      await joinedOnB;
      const [ops, meta] = await onReplay;
      expect(ops).toEqual([op2]);
      expect(meta).toEqual({ replay: true });
    } finally {
      await ctx.close();
    }
  });

  it('board:fetchOps {actor, fromSeq} → 裁差分单播（含空结果 replayed:0）', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      await joinBoard(a.client, 'board-fetch');
      const ops = [makeOp('actor-f', 1), makeOp('actor-f', 2), makeOp('actor-f', 3)];
      expect(await emitAck<BoardOpsAck>(a.client, 'board:ops', ops)).toEqual({ ok: true });

      const b = await connectAndWait(ctx);
      await joinBoard(b.client, 'board-fetch');

      const onReplay = waitForArgs<[Op[], BoardOpsMeta?]>(b.client, 'board:ops');
      const ack = await emitAck<BoardFetchOpsResponse>(b.client, 'board:fetchOps', {
        actor: 'actor-f',
        fromSeq: 1,
      });
      expect(ack).toEqual({ ok: true, replayed: 2 });
      const [replayed] = await onReplay;
      expect(replayed.map((op) => op.seq)).toEqual([2, 3]);

      const emptyAck = await emitAck<BoardFetchOpsResponse>(b.client, 'board:fetchOps', {
        actor: 'actor-f',
        fromSeq: 3,
      });
      expect(emptyAck).toEqual({ ok: true, replayed: 0 });
      await expectNoEvent(b.client, 'board:ops'); // 空结果不发事件
    } finally {
      await ctx.close();
    }
  });
});

describe('realtime 契约: 认证路径（JWT 过期 / 生产收紧 / 匿名审计）', () => {
  it('JWT 过期 → connect_error（Unauthorized），连接不建立', async () => {
    const ctx = await createTestContext({ WB_JWT_SECRET: 'test-secret' });
    try {
      const client = ctx.connect({ token: signTestToken('user-exp', { expired: true }) });
      const error = await waitForConnectError(client);
      expect(error.message).toMatch(/Unauthorized/);
      expect(client.connected).toBe(false);
    } finally {
      await ctx.close();
    }
  });

  it('production 缺密钥 → 拒绝连接（不静默匿名）；带 token 同样拒绝', async () => {
    const ctx = await createTestContext({ NODE_ENV: 'production' });
    try {
      const withoutToken = ctx.connect();
      expect((await waitForConnectError(withoutToken)).message).toMatch(/Unauthorized/);
      const withToken = ctx.connect({ token: 'whatever' });
      expect((await waitForConnectError(withToken)).message).toMatch(/Unauthorized/);
    } finally {
      await ctx.close();
    }
  });

  it('匿名回落（missing_secret）/ 拒连均入审计；不落 token 原文', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    const ctx1 = await createTestContext({ WB_JWT_SECRET: undefined });
    try {
      const token = signTestToken('user-x', 'secret-that-is-not-configured');
      const { session } = await connectAndWait(ctx1, { token });
      const entries = memoryAuditOf(ctx1.server).entries;
      const anon = entries.find((e) => e.action === 'auth.anonymous');
      expect(anon?.userId).toBe(session.userId);
      expect(anon?.detail).toContain('missing_secret');
      expect(JSON.stringify(entries)).not.toContain(token);
    } finally {
      await ctx1.close();
      warn.mockRestore();
    }

    const ctx2 = await createTestContext({ WB_JWT_SECRET: 'test-secret' });
    try {
      const token = signTestToken('user-y', 'wrong-secret');
      const client = ctx2.connect({ token });
      await waitForConnectError(client);
      const entries = memoryAuditOf(ctx2.server).entries;
      expect(entries.some((e) => e.action === 'auth.rejected' && e.result === 'denied')).toBe(true);
      expect(JSON.stringify(entries)).not.toContain(token);
    } finally {
      await ctx2.close();
    }
  });
});

describe('realtime 契约: 审计落盘（JSONL）', () => {
  it('房间生命周期 join/leave/cleanup 落盘；不含 token / op 内容 / 密钥', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'wb-realtime-audit-'));
    const file = join(dir, 'audit.jsonl');
    const ctx = await createTestContext({ WB_JWT_SECRET: 'test-secret', WB_REALTIME_AUDIT_LOG: file }, { roomTtlMs: 60 });
    try {
      const token = signTestToken('user-audit', { role: 'Participant' });
      const { client, session } = await connectAndWait(ctx, { token });
      await joinBoard(client, 'board-audit');
      const opAck = await emitAck<BoardOpsAck>(client, 'board:ops', [
        makeOp('user-audit', 1, { value: { marker: 'OP-CONTENT-MARKER' } }),
      ]);
      expect(opAck).toEqual({ ok: true });

      const disconnectOnClient = waitForDisconnect(client);
      const leaveAck = await emitAck<BoardLeaveAck>(client, 'board:leave', {});
      expect(leaveAck).toEqual({ ok: true });
      expect(await disconnectOnClient).toMatch(/server disconnect/);

      // 空房 TTL 到期 → room.cleanup
      await waitFor(() => ctx.server.rooms.roomCount === 0, 3000);

      const entries = readAuditEntries(file);
      expect(entries).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ action: 'auth.connect', userId: 'user-audit', result: 'success' }),
          expect.objectContaining({ action: 'room.join', boardId: 'board-audit', userId: session.userId }),
          expect.objectContaining({ action: 'room.leave', boardId: 'board-audit', userId: session.userId }),
          expect.objectContaining({ action: 'room.cleanup', boardId: 'board-audit', userId: 'system' }),
        ]),
      );
      expect(entries.find((e) => e.action === 'room.cleanup')?.detail).toContain('opsDropped=1');

      // 脱敏：凭据与 op 内容不落审计
      const raw = readFileSync(file, 'utf8');
      expect(raw).not.toContain(token);
      expect(raw).not.toContain('OP-CONTENT-MARKER');
      expect(raw).not.toContain('test-secret');
    } finally {
      await ctx.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('realtime 契约: 单播 user:<userId> 房间', () => {
  it('同用户跨会话均收到；其他用户不收到', async () => {
    const ctx = await createTestContext({ WB_JWT_SECRET: 'test-secret' });
    try {
      const a1 = await connectAndWait(ctx, { token: signTestToken('user-a') });
      const a2 = await connectAndWait(ctx, { token: signTestToken('user-a') });
      const b = await connectAndWait(ctx, { token: signTestToken('user-b') });

      const onA1 = waitForEvent<BoardDirectedPayload>(a1.client, 'board:directed');
      const onA2 = waitForEvent<BoardDirectedPayload>(a2.client, 'board:directed');
      const ack = await emitAck<BoardDirectAck>(b.client, 'board:direct', {
        toUserId: 'user-a',
        payload: { hi: 1 },
      });
      expect(ack).toEqual({ ok: true });

      const [d1, d2] = await Promise.all([onA1, onA2]);
      expect(d1.toUserId).toBe('user-a');
      expect(d2.toUserId).toBe('user-a');
      expect(d1.from).toBe('user-b');
      await expectNoEvent(b.client, 'board:directed'); // 发送者不在目标用户房间
    } finally {
      await ctx.close();
    }
  });
});
