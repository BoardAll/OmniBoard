import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import jwt from 'jsonwebtoken';
import { createMemoryStore, type DataStore } from '../src/db/memory.js';
import { InMemoryAuditStore, maskPii } from '../src/middleware/audit.js';
import { SECURITY_HEADERS } from '../src/middleware/security.js';
import {
  api,
  errorOf,
  signToken,
  startTestServer,
  TEST_JWT_SECRET,
  type TestServer,
} from './helpers.js';

/**
 * Wave 4.4 安全合规补齐（《安全与合规设计》）：
 * - §22.1 安全响应头（9 项）
 * - §8 CORS 白名单
 * - §8.5/§8.7 输入守卫（415 / 400 / 414）
 * - §8.2 多层限流（IP / 用户 / AI-MCP 类别）与超限审计
 * - §14.1 认证失败 / 授权拒绝 / 限流超限审计
 * - §14.4 PII 值级脱敏（邮箱 / 手机号 / 身份证 / 银行卡）
 * - §8.6/§11 错误响应不泄漏内部细节
 */

describe('Security headers (§22.1)', () => {
  let server: TestServer;

  beforeAll(async () => {
    server = await startTestServer({ env: {} });
  });

  afterAll(async () => {
    await server.close();
  });

  it('sets all nine §22.1 headers on success responses', async () => {
    const result = await api(server.baseUrl, 'GET', '/healthz', { token: null });
    expect(result.status).toBe(200);
    expect(Object.keys(SECURITY_HEADERS)).toHaveLength(9);
    for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
      expect(result.headers.get(name), `header ${name}`).toBe(value);
    }
  });

  it('sets the headers on error responses too (401)', async () => {
    const result = await api(server.baseUrl, 'GET', '/v1/boards', { token: null });
    expect(result.status).toBe(401);
    expect(result.headers.get('x-content-type-options')).toBe('nosniff');
    expect(result.headers.get('x-frame-options')).toBe('DENY');
    expect(result.headers.get('referrer-policy')).toBe('strict-origin-when-cross-origin');
  });
});

describe('CORS whitelist (§8)', () => {
  let server: TestServer;
  let openServer: TestServer;

  beforeAll(async () => {
    server = await startTestServer({
      env: {},
      corsOrigins: ['https://app.example.com', 'https://admin.example.com'],
    });
    openServer = await startTestServer({ env: {} });
  });

  afterAll(async () => {
    await server.close();
    await openServer.close();
  });

  it('echoes the origin when it is on the whitelist', async () => {
    const result = await api(server.baseUrl, 'GET', '/healthz', {
      token: null,
      headers: { Origin: 'https://app.example.com' },
    });
    expect(result.headers.get('access-control-allow-origin')).toBe('https://app.example.com');
  });

  it('omits Access-Control-Allow-Origin for origins outside the whitelist', async () => {
    const result = await api(server.baseUrl, 'GET', '/healthz', {
      token: null,
      headers: { Origin: 'https://evil.example.com' },
    });
    expect(result.headers.get('access-control-allow-origin')).toBeNull();
  });

  it('handles the preflight request for whitelisted origins', async () => {
    const preflight = await fetch(`${server.baseUrl}/v1/boards`, {
      method: 'OPTIONS',
      headers: {
        Origin: 'https://admin.example.com',
        'Access-Control-Request-Method': 'GET',
        'Access-Control-Request-Headers': 'authorization',
      },
    });
    expect(preflight.status).toBe(204);
    expect(preflight.headers.get('access-control-allow-origin')).toBe('https://admin.example.com');
    expect(preflight.headers.get('access-control-allow-methods')).toContain('GET');
  });

  it('defaults to * when no whitelist is configured', async () => {
    const result = await api(openServer.baseUrl, 'GET', '/healthz', {
      token: null,
      headers: { Origin: 'https://anywhere.example.com' },
    });
    expect(result.headers.get('access-control-allow-origin')).toBe('*');
  });
});

describe('Input guard (§8.5/§8.7)', () => {
  let server: TestServer;

  beforeAll(async () => {
    server = await startTestServer({ env: {} });
  });

  afterAll(async () => {
    await server.close();
  });

  it('rejects non-JSON bodies with 415', async () => {
    const result = await api(server.baseUrl, 'POST', '/v1/boards', {
      rawBody: 'plain text payload',
      contentType: 'text/plain',
    });
    expect(result.status).toBe(415);
    expect(errorOf(result).code).toBe('INVALID_ARGUMENT');
    expect(errorOf(result).message).toContain('Unsupported Media Type');
  });

  it('rejects control characters in the query string with 400', async () => {
    const result = await api(server.baseUrl, 'GET', '/v1/boards?q=%00&name=ok');
    expect(result.status).toBe(400);
    expect(errorOf(result).code).toBe('INVALID_ARGUMENT');
    expect(errorOf(result).message).toContain('control characters');
  });

  it('rejects overly long query strings with 414', async () => {
    const result = await api(server.baseUrl, 'GET', `/v1/boards?x=${'a'.repeat(5000)}`);
    expect(result.status).toBe(414);
    expect(errorOf(result).code).toBe('INVALID_ARGUMENT');
    expect(errorOf(result).message).toContain('too long');
  });

  it('keeps well-formed requests working (JSON body + normal query)', async () => {
    const created = await api(server.baseUrl, 'POST', '/v1/boards', {
      body: { name: 'Input Guard Board' },
    });
    expect(created.status).toBe(201);

    const list = await api(server.baseUrl, 'GET', '/v1/boards?limit=5&name=Input');
    expect(list.status).toBe(200);
  });
});

describe('Rate limiting · IP bucket (§8.2)', () => {
  let server: TestServer;
  const auditStore = new InMemoryAuditStore();

  beforeAll(async () => {
    server = await startTestServer({
      env: {},
      auditStore,
      rateLimit: { max: 100, ipMax: 2 },
    });
  });

  afterAll(async () => {
    await server.close();
  });

  it('applies the IP bucket before authentication and audits the denial', async () => {
    const first = await api(server.baseUrl, 'GET', '/v1/boards');
    expect(first.status).toBe(200);
    const second = await api(server.baseUrl, 'GET', '/v1/boards');
    expect(second.status).toBe(200);

    const limited = await api(server.baseUrl, 'GET', '/v1/boards');
    expect(limited.status).toBe(429);
    const error = errorOf(limited);
    expect(error.code).toBe('RATE_LIMITED');
    expect((error.detail as Record<string, unknown>)['limit']).toBe(2);
    expect(limited.headers.get('x-ratelimit-limit')).toBe('2');

    const entry = auditStore.entries.find((e) => e.action === 'rate_limit.exceeded');
    expect(entry).toBeDefined();
    expect(entry?.target.type).toBe('ip');
    expect(entry?.result.status).toBe(429);
  });
});

describe('Rate limiting · MCP category bucket (§8.2)', () => {
  let server: TestServer;

  beforeAll(async () => {
    server = await startTestServer({ env: {}, rateLimit: { categories: { mcp: 1 } } });
  });

  afterAll(async () => {
    await server.close();
  });

  it('applies the MCP category bucket only under /v1/mcp', async () => {
    const first = await api(server.baseUrl, 'GET', '/v1/mcp/tools');
    expect(first.status).toBe(200);

    const limited = await api(server.baseUrl, 'GET', '/v1/mcp/tools');
    expect(limited.status).toBe(429);
    const error = errorOf(limited);
    expect(error.code).toBe('RATE_LIMITED');
    const detail = error.detail as Record<string, unknown>;
    expect(detail['category']).toBe('mcp');
    expect(detail['limit']).toBe(1);
    expect(limited.headers.get('x-ratelimit-limit')).toBe('1');

    // 其他端点不受 MCP 类别配额影响。
    const boards = await api(server.baseUrl, 'GET', '/v1/boards');
    expect(boards.status).toBe(200);
  });
});

describe('Audit for security events (§14.1)', () => {
  let server: TestServer;
  const auditStore = new InMemoryAuditStore();

  beforeAll(async () => {
    server = await startTestServer({ env: {}, auditStore });
  });

  afterAll(async () => {
    await server.close();
  });

  it('records auth.failure for malformed and expired tokens without credentials', async () => {
    const malformed = await api(server.baseUrl, 'GET', '/v1/boards', { token: 'aa.bb.cc' });
    expect(malformed.status).toBe(401);

    const expired = jwt.sign({ sub: 'user_test', scopes: ['board:read'] }, TEST_JWT_SECRET, {
      algorithm: 'HS256',
      expiresIn: '-10s',
    });
    const expiredResult = await api(server.baseUrl, 'GET', '/v1/boards', { token: expired });
    expect(expiredResult.status).toBe(401);

    const failures = auditStore.entries.filter((e) => e.action === 'auth.failure');
    expect(failures.length).toBeGreaterThanOrEqual(2);
    for (const entry of failures) {
      expect(entry.who).toBe('anonymous');
      expect(entry.result.status).toBe(401);
      expect(entry.target).toEqual({ type: 'auth', id: null });
    }
    expect(failures.some((e) => e.argsJson?.includes('expired'))).toBe(true);

    // 凭据绝不出现在审计中。
    const serialised = JSON.stringify(auditStore.entries);
    expect(serialised).not.toContain('aa.bb.cc');
    expect(serialised).not.toContain(expired);
  });

  it('records authz.denied when the scope is missing', async () => {
    const token = signToken({ sub: 'limited_user', scopes: ['board:read'] });
    const result = await api(server.baseUrl, 'POST', '/v1/boards', {
      token,
      body: { name: 'Denied Board' },
    });
    expect(result.status).toBe(403);
    expect(errorOf(result).code).toBe('PERMISSION_DENIED');

    const entry = auditStore.entries.find(
      (e) => e.action === 'authz.denied' && e.who === 'limited_user',
    );
    expect(entry).toBeDefined();
    expect(entry?.target).toEqual({ type: 'scope', id: 'board:write' });
    expect(entry?.result.status).toBe(403);
  });
});

describe('PII masking (§14.4)', () => {
  let server: TestServer;
  const auditStore = new InMemoryAuditStore();

  beforeAll(async () => {
    server = await startTestServer({ env: {}, auditStore });
  });

  afterAll(async () => {
    await server.close();
  });

  it('masks emails, phones, id cards and bank cards', () => {
    expect(maskPii('contact alice@example.com now')).toBe('contact a***@example.com now');
    expect(maskPii('13812345678')).toBe('138****5678');
    expect(maskPii('110101199003071234')).toBe('1101**********1234');
    expect(maskPii('6222021234567890123')).toBe('***************0123');
    expect(maskPii('no pii here')).toBe('no pii here');
  });

  it('masks PII inside audit argsJson end-to-end', async () => {
    const created = await api(server.baseUrl, 'POST', '/v1/boards', {
      body: { name: 'PII Board' },
    });
    const boardId = (created.body['data'] as Record<string, unknown>)['id'] as string;

    const email = await api(server.baseUrl, 'POST', `/v1/boards/${boardId}/collaborators`, {
      body: { userId: 'alice@example.com', role: 'editor' },
    });
    expect(email.status).toBe(201);
    const phone = await api(server.baseUrl, 'POST', `/v1/boards/${boardId}/collaborators`, {
      body: { userId: '13812345678', role: 'viewer' },
    });
    expect(phone.status).toBe(201);

    const entries = auditStore.entries.filter((e) => e.action === 'board.addCollaborator');
    expect(entries.some((e) => e.argsJson?.includes('a***@example.com'))).toBe(true);
    expect(entries.some((e) => e.argsJson?.includes('138****5678'))).toBe(true);

    const serialised = JSON.stringify(auditStore.entries);
    expect(serialised).not.toContain('alice@example.com');
    expect(serialised).not.toContain('13812345678');
  });
});

describe('Error responses do not leak internals (§8.6/§11)', () => {
  let server: TestServer;

  beforeAll(async () => {
    const store = createMemoryStore();
    const boards = new Proxy(store.boards, {
      get(target, property, receiver) {
        if (property === 'values') {
          return (): never => {
            throw new Error('internal-db-detail: connection pool exhausted');
          };
        }
        return Reflect.get(target, property, receiver);
      },
    });
    const brokenStore: DataStore = { ...store, boards };
    server = await startTestServer({ env: {}, store: brokenStore });
  });

  afterAll(async () => {
    await server.close();
  });

  it('returns a generic 500 without internal details', async () => {
    const result = await api(server.baseUrl, 'GET', '/v1/boards');
    expect(result.status).toBe(500);
    const error = errorOf(result);
    expect(error.code).toBe('INTERNAL_ERROR');
    expect(error.message).toBe('Internal error');
    const serialised = JSON.stringify(result.body);
    expect(serialised).not.toContain('internal-db-detail');
    expect(serialised).not.toContain('connection pool');
  });
});
