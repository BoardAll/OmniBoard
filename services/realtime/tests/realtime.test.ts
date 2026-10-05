/**
 * realtime 服务冒烟测试（M0 / T0.3 + M1 快照结构对齐）——全部离线，自起自停随机端口：
 * - healthz / 装配与幂等关闭；
 * - 连接认证：匿名 dev 回落 / JWT 验签 / 验签失败拒连 / 无密钥回落；
 * - /board 最小事件集：join + ping ack / echo ack + 房间广播（排除发送者）/ 单播。
 *
 * 注：M1 完整契约（oplog / 权限 / 回放 / 审计）见 contract.test.ts 与 oplog.test.ts。
 */

import { describe, expect, it, vi } from 'vitest';
import type {
  BoardAckFailure,
  BoardBroadcastPayload,
  BoardDirectAck,
  BoardDirectedPayload,
  BoardEchoAck,
  BoardJoinAck,
  BoardJoinedPayload,
  BoardPingAck,
} from '../src/types.js';
import {
  connectAndWait,
  createTestContext,
  emitAck,
  expectNoEvent,
  signTestToken,
  startTestServer,
  waitForConnectError,
  waitForEvent,
} from './helpers.js';

describe('realtime: healthz 与装配', () => {
  it('GET /healthz → 200 {ok:true}；close 幂等', async () => {
    const server = await startTestServer();
    try {
      const response = await fetch(`http://127.0.0.1:${server.port}/healthz`);
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ ok: true });
    } finally {
      await server.close();
      await server.close(); // 幂等：重复关闭不抛错
    }
  });
});

describe('realtime: 连接认证', () => {
  it('匿名 dev 回落：连接成功，身份为 anon-*', async () => {
    const ctx = await createTestContext();
    try {
      const { session } = await connectAndWait(ctx);
      expect(session.userId).toMatch(/^anon-[0-9a-f]{8}$/);
      expect(session.authMode).toBe('anonymous');
    } finally {
      await ctx.close();
    }
  });

  it('JWT（HS256）验签成功：userId 取 sub', async () => {
    const ctx = await createTestContext({ WB_JWT_SECRET: 'test-secret' });
    try {
      const { session } = await connectAndWait(ctx, { token: signTestToken('user-a') });
      expect(session.userId).toBe('user-a');
      expect(session.authMode).toBe('jwt');
    } finally {
      await ctx.close();
    }
  });

  it('JWT 验签失败 → connect_error（Unauthorized），连接不建立', async () => {
    const ctx = await createTestContext({ WB_JWT_SECRET: 'test-secret' });
    try {
      const client = ctx.connect({ token: signTestToken('user-a', 'another-secret') });
      const error = await waitForConnectError(client);
      expect(error.message).toMatch(/Unauthorized/);
      expect(client.connected).toBe(false);
    } finally {
      await ctx.close();
    }
  });

  it('有 token 但未配置 WB_JWT_SECRET → 警告并匿名回落', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    const ctx = await createTestContext({ WB_JWT_SECRET: undefined });
    try {
      const { session } = await connectAndWait(ctx, { token: 'not-verifiable' });
      expect(session.userId).toMatch(/^anon-/);
      expect(warn).toHaveBeenCalled();
    } finally {
      await ctx.close();
      warn.mockRestore();
    }
  });
});

describe('realtime: /board 最小事件集', () => {
  it('board:join → ack {ok:true,...} + board:joined（M1 快照结构）', async () => {
    const ctx = await createTestContext();
    try {
      const { client, session } = await connectAndWait(ctx);
      const joinedPromise = waitForEvent<BoardJoinedPayload>(client, 'board:joined');
      const ack = await emitAck<BoardJoinAck>(client, 'board:join', { boardId: 'board-1', pageId: 'page-1' });
      if (!ack.ok) throw new Error(`expected join ack success, got ${ack.error.code}`);
      expect(ack.boardId).toBe('board-1');
      // 房主自举：空房首个加入的可写角色自动成为 Host。
      expect(ack.role).toBe('Host');
      expect(ack.mode).toBe('free');
      expect(ack.locks).toEqual({});
      expect(ack.stateVector).toEqual({});
      expect(ack.participants).toEqual([
        expect.objectContaining({ userId: session.userId, socketId: client.id, role: 'Host' }),
      ]);

      const joined = await joinedPromise;
      expect(joined.boardId).toBe('board-1');
      expect(joined.role).toBe('Host');
      expect(joined.mode).toBe('free');
      expect(joined.locks).toEqual({});
      expect(joined.stateVector).toEqual({});
      expect(joined.participants).toEqual([
        expect.objectContaining({ userId: session.userId, socketId: client.id, role: 'Host' }),
      ]);
    } finally {
      await ctx.close();
    }
  });

  it('board:join 缺 boardId → INVALID_ARGUMENT ack', async () => {
    const ctx = await createTestContext();
    try {
      const { client } = await connectAndWait(ctx);
      const ack = await emitAck<BoardAckFailure>(client, 'board:join', {});
      expect(ack.ok).toBe(false);
      expect(ack.error.code).toBe('INVALID_ARGUMENT');
    } finally {
      await ctx.close();
    }
  });

  it('board:ping → ack {ok:true, serverTime}', async () => {
    const ctx = await createTestContext();
    try {
      const { client } = await connectAndWait(ctx);
      const before = Date.now();
      const ack = await emitAck<BoardPingAck>(client, 'board:ping', { clientTime: before });
      expect(ack.ok).toBe(true);
      if (!ack.ok) throw new Error('expected ping ack success');
      expect(ack.serverTime).toBeGreaterThanOrEqual(before);
      expect(ack.serverTime).toBeLessThanOrEqual(Date.now() + 1000);
    } finally {
      await ctx.close();
    }
  });

  it('board:echo → ack {echo}；房间广播排除发送者', async () => {
    const ctx = await createTestContext();
    try {
      const a = await connectAndWait(ctx);
      const b = await connectAndWait(ctx);
      await emitAck<BoardJoinAck>(a.client, 'board:join', { boardId: 'board-echo' });
      await emitAck<BoardJoinAck>(b.client, 'board:join', { boardId: 'board-echo' });

      const broadcastOnB = waitForEvent<BoardBroadcastPayload>(b.client, 'board:broadcast');
      const ack = await emitAck<BoardEchoAck>(a.client, 'board:echo', { payload: { text: 'hello' } });
      expect(ack).toEqual({ ok: true, echo: { text: 'hello' } });

      const broadcast = await broadcastOnB;
      expect(broadcast.from).toBe(a.session.userId);
      expect(broadcast.payload).toEqual({ text: 'hello' });

      // 排除发送者：A 不应收到自己的广播（窗口期内零事件）
      await expectNoEvent(a.client, 'board:broadcast');
    } finally {
      await ctx.close();
    }
  });

  it('board:direct → 目标用户单播 board:directed', async () => {
    const ctx = await createTestContext({ WB_JWT_SECRET: 'test-secret' });
    try {
      const a = await connectAndWait(ctx, { token: signTestToken('user-a') });
      const b = await connectAndWait(ctx, { token: signTestToken('user-b') });
      const c = await connectAndWait(ctx, { token: signTestToken('user-c') });

      const directedOnB = waitForEvent<BoardDirectedPayload>(b.client, 'board:directed');
      const ack = await emitAck<BoardDirectAck>(a.client, 'board:direct', {
        toUserId: 'user-b',
        payload: { note: 'hi-b' },
      });
      expect(ack).toEqual({ ok: true });

      const directed = await directedOnB;
      expect(directed.from).toBe('user-a');
      expect(directed.toUserId).toBe('user-b');
      expect(directed.payload).toEqual({ note: 'hi-b' });

      // 非目标用户 / 发送者均不收到（单播房间语义）
      await expectNoEvent(c.client, 'board:directed');
      await expectNoEvent(a.client, 'board:directed');
    } finally {
      await ctx.close();
    }
  });
});
