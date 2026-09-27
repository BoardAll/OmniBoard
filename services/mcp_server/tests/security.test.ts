/**
 * 安全加固测试（Wave 4.4）：
 * - 传输层安全响应头（《安全与合规设计》§22.1）；
 * - 认证成功/失败审计与凭据脱敏（§10 / §14）；
 * - 未认证主体 / Scope 边界的工具拒绝（§9.4）；
 * - 确认流程二次校验与确认操作审计（§6.5 / §9.6 / §10）；
 * - JWT 校验健壮性（§3 / §10）；
 * - 请求级限流装配（§9.6）。
 *
 * 全部离线：随机端口 + 显式关闭，不访问任何外部服务。
 */

import { createHmac } from 'node:crypto';
import type { Server } from 'node:http';
import type { Express } from 'express';
import { afterEach, describe, expect, it } from 'vitest';
import { JwtVerifier } from '../src/auth/oauth.js';
import { AuthError, KNOWN_SCOPES } from '../src/auth/types.js';
import { RPC_ERROR_CODES } from '../src/protocol/jsonrpc.js';
import { startServer, type ServerOptions } from '../src/server.js';
import { createSseApp } from '../src/transport/sse.js';
import { createStreamableHttpApp } from '../src/transport/http.js';
import { SECURITY_HEADERS } from '../src/transport/shared.js';
import { closeServer, httpCall, listenRandom } from './http-utils.js';
import { AUTH_HEADERS, initializeRequest, TEST_API_KEY, testApiKeyAuthenticator } from './fixtures.js';
import { allScopesPrincipal, asFailure, asSuccess, createFixture } from './helpers.js';

const activeServers: Server[] = [];

afterEach(async () => {
  for (const server of activeServers.splice(0)) {
    await closeServer(server);
  }
});

async function serve(app: Express): Promise<number> {
  const { server, port } = await listenRandom(app);
  activeServers.push(server);
  return port;
}

function expectSecurityHeaders(headers: NodeJS.Dict<string | string[]>): void {
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
    expect(headers[name.toLowerCase()]).toBe(value);
  }
}

/* ------------------------------------------------------------------ */
/* 传输层安全响应头                                                     */
/* ------------------------------------------------------------------ */

describe('安全：传输层安全响应头（§22.1）', () => {
  it('Streamable HTTP：healthz 与 /mcp 401 响应均注入全部安全头', async () => {
    const fixture = createFixture();
    const port = await serve(
      createStreamableHttpApp({
        dispatcher: fixture.dispatcher,
        sessions: fixture.sessions,
        authenticator: testApiKeyAuthenticator(),
        keepAliveMs: 0,
      }).app,
    );

    const health = await httpCall(port, 'GET', '/healthz');
    expect(health.status).toBe(200);
    expectSecurityHeaders(health.headers);
    expect(health.headers['x-powered-by']).toBeUndefined();

    const denied = await httpCall(port, 'POST', '/mcp', { body: JSON.stringify(initializeRequest(1)) });
    expect(denied.status).toBe(401);
    expectSecurityHeaders(denied.headers);
  });

  it('SSE：/sse 401 响应同样注入安全头', async () => {
    const fixture = createFixture();
    const port = await serve(
      createSseApp({
        dispatcher: fixture.dispatcher,
        sessions: fixture.sessions,
        authenticator: testApiKeyAuthenticator(),
        keepAliveMs: 0,
      }).app,
    );

    const denied = await httpCall(port, 'GET', '/sse');
    expect(denied.status).toBe(401);
    expectSecurityHeaders(denied.headers);
  });
});

/* ------------------------------------------------------------------ */
/* 认证审计                                                            */
/* ------------------------------------------------------------------ */

describe('安全：认证审计（§10）', () => {
  it('认证失败与成功均写 auth.authenticate；凭据不出现在响应与审计中', async () => {
    const fixture = createFixture();
    const port = await serve(
      createStreamableHttpApp({
        dispatcher: fixture.dispatcher,
        sessions: fixture.sessions,
        authenticator: testApiKeyAuthenticator(),
        audit: fixture.audit,
        keepAliveMs: 0,
      }).app,
    );

    const badKey = 'wbp_wrong_key_value';
    const denied = await httpCall(port, 'POST', '/mcp', {
      headers: { 'x-api-key': badKey },
      body: JSON.stringify(initializeRequest(1)),
    });
    expect(denied.status).toBe(401);
    expect(denied.text).not.toContain(badKey);
    expect(denied.text).not.toContain(TEST_API_KEY);

    const ok = await httpCall(port, 'POST', '/mcp', {
      headers: AUTH_HEADERS,
      body: JSON.stringify(initializeRequest(1)),
    });
    expect(ok.status).toBe(200);

    const entries = fixture.audit.entries.filter((entry) => entry.action === 'auth.authenticate');
    expect(entries).toHaveLength(2);
    expect(entries[0]).toMatchObject({ result: 'denied', userId: 'anonymous', transport: 'http' });
    expect(entries[1]).toMatchObject({ result: 'success', userId: 'u-transport', transport: 'http' });

    const serialised = JSON.stringify(fixture.audit.entries);
    expect(serialised).not.toContain(badKey);
    expect(serialised).not.toContain(TEST_API_KEY);
  });
});

/* ------------------------------------------------------------------ */
/* 未认证主体 / Scope 边界                                              */
/* ------------------------------------------------------------------ */

describe('安全：未认证主体与 Scope 边界（§9.4）', () => {
  it('principal=null：工具调用 -32002（含 scope/toolId），不执行且写 denied 审计', async () => {
    const fixture = createFixture({ principal: null });
    const failure = asFailure(
      await fixture.request('tools/call', { name: 'board_get', arguments: { boardId: 'board-1' } }),
    );
    expect(failure.error.code).toBe(RPC_ERROR_CODES.permissionDenied);
    expect(failure.error.data).toEqual({ scope: 'board:read', toolId: 'board.get' });
    expect(fixture.fake.invocations).toHaveLength(0);

    const denied = fixture.audit.entries.find((entry) => entry.action === 'tool.call');
    expect(denied).toMatchObject({ result: 'denied', userId: 'anonymous' });
  });
});

/* ------------------------------------------------------------------ */
/* 确认流程：二次校验与确认操作审计                                      */
/* ------------------------------------------------------------------ */

describe('安全：确认流程二次校验与确认操作审计（§6.5 / §10）', () => {
  it('确认后主体降权：批准执行前重新校验 Scope → -32002 且写 tool.confirm denied', async () => {
    const fixture = createFixture();
    const first = asFailure(
      await fixture.request('tools/call', { name: 'element_delete', arguments: { elementId: 'e1' } }),
    );
    expect(first.error.code).toBe(RPC_ERROR_CODES.confirmationRequired);
    const confirmationId = (first.error.data as { confirmationId: string }).confirmationId;

    // 确认前主体降权（防御主体变更 / 越权批准）。
    fixture.ctx.principal = allScopesPrincipal({ scopes: ['board:read'] });
    const denied = asFailure(
      await fixture.request('tools/call', {
        name: 'confirm_operation',
        arguments: { confirmationId, approved: true },
      }),
    );
    expect(denied.error.code).toBe(RPC_ERROR_CODES.permissionDenied);
    expect(denied.error.data).toEqual({ scope: 'element:write', toolId: 'element.delete' });
    expect(fixture.fake.invocations).toHaveLength(0);

    const confirmEntry = fixture.audit.entries.find((entry) => entry.action === 'tool.confirm');
    expect(confirmEntry).toMatchObject({
      result: 'denied',
      target: { type: 'mcp_tool', id: 'element_delete' },
    });
  });

  it('board_share：拒绝与批准均写 tool.confirm；审计不含参数敏感值', async () => {
    const fixture = createFixture();
    const secretValue = 'top-secret-pw';
    const shareArgs = { boardId: 'board-1', role: 'viewer', password: secretValue };

    const first = asFailure(await fixture.request('tools/call', { name: 'board_share', arguments: shareArgs }));
    expect(first.error.code).toBe(RPC_ERROR_CODES.confirmationRequired);
    const firstId = (first.error.data as { confirmationId: string }).confirmationId;

    const rejected = asFailure(
      await fixture.request('tools/call', {
        name: 'confirm_operation',
        arguments: { confirmationId: firstId, approved: false },
      }),
    );
    expect(rejected.error.code).toBe(RPC_ERROR_CODES.cancelled);
    expect(fixture.fake.invocations).toHaveLength(0);

    const again = asFailure(await fixture.request('tools/call', { name: 'board_share', arguments: shareArgs }));
    const secondId = (again.error.data as { confirmationId: string }).confirmationId;
    const approved = asSuccess(
      await fixture.request('tools/call', {
        name: 'confirm_operation',
        arguments: { confirmationId: secondId, approved: true },
      }),
    );
    expect((approved.result as { isError: boolean }).isError).toBe(false);
    expect(fixture.fake.invocations).toHaveLength(1);
    expect(fixture.fake.invocations[0]).toMatchObject({ toolId: 'board.share', mode: 'execute' });

    const confirmEntries = fixture.audit.entries.filter((entry) => entry.action === 'tool.confirm');
    expect(confirmEntries).toHaveLength(2);
    expect(confirmEntries[0]).toMatchObject({ result: 'denied', target: { type: 'mcp_tool', id: 'board_share' } });
    expect(confirmEntries[1]).toMatchObject({ result: 'success' });
    expect(fixture.audit.entries.some((entry) => entry.action === 'tool.call' && entry.result === 'success')).toBe(true);
    expect(JSON.stringify(fixture.audit.entries)).not.toContain(secretValue);
  });

  it('_meta.confirmationId 批准路径写 tool.confirm success，且执行审计保持最后一条', async () => {
    const fixture = createFixture();
    const first = asFailure(
      await fixture.request('tools/call', { name: 'element_delete', arguments: { elementId: 'e1' } }),
    );
    const confirmationId = (first.error.data as { confirmationId: string }).confirmationId;

    const second = asSuccess(
      await fixture.request('tools/call', {
        name: 'element_delete',
        arguments: { elementId: 'e1' },
        _meta: { confirmationId },
      }),
    );
    expect((second.result as { isError: boolean }).isError).toBe(false);

    const confirmEntries = fixture.audit.entries.filter((entry) => entry.action === 'tool.confirm');
    expect(confirmEntries).toHaveLength(1);
    expect(confirmEntries[0]).toMatchObject({ result: 'success' });
    expect(fixture.audit.entries.at(-1)).toMatchObject({ action: 'tool.call', result: 'success' });
  });
});

/* ------------------------------------------------------------------ */
/* JWT 校验加固                                                        */
/* ------------------------------------------------------------------ */

describe('安全：JWT 校验加固（§3 / §10）', () => {
  const SECRET = 'test-hs256-secret';
  const nowMs = Date.UTC(2026, 0, 1);

  function base64url(value: string): string {
    return Buffer.from(value, 'utf8').toString('base64url');
  }

  /** 测试用 HS256 签发（与 oauth.ts 的校验实现独立）。 */
  function signHs256(payload: Record<string, unknown>, secret = SECRET): string {
    const head = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
    const body = base64url(JSON.stringify(payload));
    const signature = createHmac('sha256', secret).update(`${head}.${body}`).digest('base64url');
    return `${head}.${body}.${signature}`;
  }

  it('exp / nbf 类型非法与超长 token → 拒绝', () => {
    const verifier = new JwtVerifier({ secret: SECRET, now: () => nowMs });

    expect(() => verifier.verify(signHs256({ sub: 'u', exp: 'soon' }))).toThrowError(/exp claim must be a number/);
    expect(() => verifier.verify(signHs256({ sub: 'u', nbf: 'later' }))).toThrowError(/nbf claim must be a number/);

    const oversized = `a.${'b'.repeat(9000)}.c`;
    expect(() => verifier.verify(oversized)).toThrowError(/too large/i);
  });

  it('iss / aud 强校验：任一不匹配即拒绝，命中即放行', () => {
    const verifier = new JwtVerifier({
      secret: SECRET,
      issuer: 'https://issuer.example',
      audience: ['whiteboard-api', 'whiteboard-web'],
      now: () => nowMs,
    });
    const exp = Math.floor(nowMs / 1000) + 60;

    const ok = signHs256({ sub: 'u1', exp, iss: 'https://issuer.example', aud: ['whiteboard-web', 'whiteboard-api'] });
    expect(verifier.verify(ok).userId).toBe('u1');

    const wrongIssuer = signHs256({ sub: 'u1', exp, iss: 'https://evil.example', aud: 'whiteboard-api' });
    expect(() => verifier.verify(wrongIssuer)).toThrowError(/issuer/i);

    const missingAud = signHs256({ sub: 'u1', exp, iss: 'https://issuer.example' });
    expect(() => verifier.verify(missingAud)).toThrowError(/audience/i);

    const wrongAud = signHs256({ sub: 'u1', exp, iss: 'https://issuer.example', aud: 'other-api' });
    expect(() => verifier.verify(wrongAud)).toThrowError(/audience/i);
  });

  it('畸形 token（段数 / 编码垃圾 / 签名不匹配）→ AuthError', () => {
    const verifier = new JwtVerifier({ secret: SECRET, now: () => nowMs });
    expect(() => verifier.verify('not-a-jwt')).toThrowError(AuthError);
    expect(() => verifier.verify('a.b.c')).toThrowError(AuthError);
    expect(() =>
      verifier.verify(signHs256({ sub: 'u', exp: Math.floor(nowMs / 1000) + 60 }, 'wrong-secret')),
    ).toThrowError(/signature/i);
  });
});

/* ------------------------------------------------------------------ */
/* 请求级限流装配                                                       */
/* ------------------------------------------------------------------ */

describe('安全：startServer 请求级限流装配（§9.6）', () => {
  const baseOptions: ServerOptions = {
    transport: 'http',
    host: '127.0.0.1',
    port: 0,
    apiBaseUrl: null,
    apiKey: null,
    mcpApiKey: null,
    boards: [],
    logLevel: 'error',
    allowAnonymous: false,
  };

  it('WB_MCP_RATE_LIMIT_PER_MINUTE=2：第 3 个请求 → -32001（带 retryAfter）', async () => {
    const env = {
      WB_API_KEYS: JSON.stringify({ 'k-sec': { userId: 'u-sec', scopes: [...KNOWN_SCOPES] } }),
      WB_MCP_RATE_LIMIT_PER_MINUTE: '2',
    };
    const started = await startServer({ ...baseOptions }, env);
    try {
      const port = started.port ?? 0;
      const init = await httpCall(port, 'POST', '/mcp', {
        headers: { 'x-api-key': 'k-sec' },
        body: JSON.stringify(initializeRequest(1)),
      });
      expect(init.status).toBe(200);
      const sessionId = init.headers['mcp-session-id'] as string;

      const headers = { 'x-api-key': 'k-sec', 'mcp-session-id': sessionId };
      const ping1 = await httpCall(port, 'POST', '/mcp', {
        headers,
        body: JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'ping' }),
      });
      expect(ping1.status).toBe(200);

      const ping2 = await httpCall(port, 'POST', '/mcp', {
        headers,
        body: JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'ping' }),
      });
      expect(ping2.status).toBe(200);
      const limited = JSON.parse(ping2.text) as { error?: { code?: number; data?: { retryAfter?: number } } };
      expect(limited.error?.code).toBe(RPC_ERROR_CODES.rateLimited);
      expect(limited.error?.data?.retryAfter).toBeGreaterThan(0);
    } finally {
      await started.close();
    }
  });

  it('限流配置非法 → 拒绝启动（ServerConfigError）', async () => {
    await expect(
      startServer({ ...baseOptions, allowAnonymous: true }, { WB_MCP_RATE_LIMIT_PER_MINUTE: 'abc' }),
    ).rejects.toThrowError(/WB_MCP_RATE_LIMIT_PER_MINUTE/);
  });
});
