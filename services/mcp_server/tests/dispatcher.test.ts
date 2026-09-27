/** 请求分发：批量、通知、错误路径、限流与生命周期方法。 */

import { describe, expect, it } from 'vitest';
import { RateLimiter } from '../src/auth/rateLimit.js';
import { McpDispatcher } from '../src/dispatcher.js';
import { RPC_ERROR_CODES } from '../src/protocol/jsonrpc.js';
import { asFailure, asSuccess, createFixture } from './helpers.js';

describe('dispatcher：解析与批量', () => {
  it('非法 JSON → -32700（id: null）', async () => {
    const fixture = createFixture();
    const failure = asFailure(await fixture.raw('{ this is not json'));
    expect(failure.id).toBeNull();
    expect(failure.error.code).toBe(RPC_ERROR_CODES.parseError);
  });

  it('结构非法 → -32600（尽力携带 id）', async () => {
    const fixture = createFixture();
    const withId = asFailure(await fixture.raw(JSON.stringify({ id: 9, method: 'x' })));
    expect(withId.error.code).toBe(RPC_ERROR_CODES.invalidRequest);
    expect(withId.id).toBe(9);

    const primitive = asFailure(await fixture.raw('42'));
    expect(primitive.id).toBeNull();
    expect(primitive.error.code).toBe(RPC_ERROR_CODES.invalidRequest);

    const emptyBatch = asFailure(await fixture.raw('[]'));
    expect(emptyBatch.error.code).toBe(RPC_ERROR_CODES.invalidRequest);
  });

  it('批量：请求 + 通知 → 仅请求产生响应；全通知 → null', async () => {
    const fixture = createFixture();
    const batch = await fixture.raw(
      JSON.stringify([
        { jsonrpc: '2.0', id: 1, method: 'ping' },
        { jsonrpc: '2.0', method: 'notifications/initialized' },
        { jsonrpc: '2.0', id: 2, method: 'tools/list' },
      ]),
    );
    expect(Array.isArray(batch)).toBe(true);
    const responses = batch as Array<{ id: number }>;
    expect(responses.map((r) => r.id)).toEqual([1, 2]);

    const onlyNotifications = await fixture.raw(
      JSON.stringify([{ jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: 1 } }]),
    );
    expect(onlyNotifications).toBeNull();
  });

  it('服务端不接收响应消息 → -32600', async () => {
    const fixture = createFixture();
    const failure = asFailure(await fixture.raw(JSON.stringify({ jsonrpc: '2.0', id: 3, result: {} })));
    expect(failure.error.code).toBe(RPC_ERROR_CODES.invalidRequest);
  });

  it('未知方法 → -32601；未知通知静默忽略', async () => {
    const fixture = createFixture();
    const failure = asFailure(await fixture.request('does/not/exist', {}));
    expect(failure.error.code).toBe(RPC_ERROR_CODES.methodNotFound);
    expect(failure.error.data).toEqual({ method: 'does/not/exist' });

    expect(await fixture.notify('notifications/unknown/thing')).toBeNull();
  });
});

describe('dispatcher：内建方法', () => {
  it('ping → 空对象', async () => {
    const fixture = createFixture();
    expect(asSuccess(await fixture.request('ping')).result).toEqual({});
  });

  it('logging/setLevel 合法与非法', async () => {
    const fixture = createFixture();
    expect(asSuccess(await fixture.request('logging/setLevel', { level: 'debug' })).result).toEqual({});
    expect(fixture.sessions.get(fixture.ctx.sessionId)?.logLevel).toBe('debug');

    const failure = asFailure(await fixture.request('logging/setLevel', { level: 'verbose' }));
    expect(failure.error.code).toBe(RPC_ERROR_CODES.invalidParams);
  });

  it('completion/complete → 空补全集合', async () => {
    const fixture = createFixture();
    const result = asSuccess(await fixture.request('completion/complete', { ref: { type: 'ref/prompt', name: 'x' } }))
      .result as { completion: { values: string[]; total: number; hasMore: boolean } };
    expect(result.completion).toEqual({ values: [], total: 0, hasMore: false });
  });

  it('shutdown → 标记会话已关闭', async () => {
    const fixture = createFixture();
    expect(asSuccess(await fixture.request('shutdown')).result).toEqual({});
    expect(fixture.sessions.get(fixture.ctx.sessionId)?.closed).toBe(true);
  });
});

describe('dispatcher：限流与内部错误', () => {
  it('超过限额 → -32001 且带 retryAfter、写审计', async () => {
    const fixture = createFixture();
    const dispatcher = new McpDispatcher({
      sessions: fixture.sessions,
      executor: fixture.executor,
      resources: fixture.resources,
      prompts: fixture.prompts,
      audit: fixture.audit,
      rateLimiter: new RateLimiter({ limit: 2, windowMs: 60_000, now: () => 1_000_000 }),
    });
    const call = (): Promise<unknown> =>
      dispatcher.handleRaw(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }), fixture.ctx);

    asSuccess((await call()) as Parameters<typeof asSuccess>[0]);
    asSuccess((await call()) as Parameters<typeof asSuccess>[0]);
    const failure = asFailure((await call()) as Parameters<typeof asFailure>[0]);
    expect(failure.error.code).toBe(RPC_ERROR_CODES.rateLimited);
    expect((failure.error.data as { retryAfter: number }).retryAfter).toBeGreaterThan(0);
    expect(fixture.audit.entries.some((entry) => entry.action === 'request.rate_limited')).toBe(true);
  });

  it('非 RpcError 异常 → -32603 且不泄漏内部细节', async () => {
    const fixture = createFixture({
      reader: async () => {
        throw new Error('boom-internal-detail');
      },
    });
    const failure = asFailure(await fixture.request('resources/read', { uri: 'whiteboard://boards/board-1' }));
    expect(failure.error.code).toBe(RPC_ERROR_CODES.internalError);
    expect(JSON.stringify(failure)).not.toContain('boom-internal-detail');
  });

  it('resources/read 成功与失败均写审计（脱敏）', async () => {
    const fixture = createFixture();
    asSuccess(await fixture.request('resources/read', { uri: 'whiteboard://boards/board-1' }));
    const entry = fixture.audit.entries.at(-1);
    expect(entry).toMatchObject({ action: 'resource.read', result: 'success' });
    expect(entry?.target).toEqual({ type: 'mcp_resource', id: 'whiteboard://boards/board-1' });
  });
});
