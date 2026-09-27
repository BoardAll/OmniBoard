import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import jwt from 'jsonwebtoken';
import { InMemoryAuditStore } from '../src/middleware/audit.js';
import {
  ALL_SCOPES,
  api,
  createBoard,
  dataOf,
  errorOf,
  signToken,
  startTestServer,
  TEST_JWT_SECRET,
  type TestServer,
} from './helpers.js';

/**
 * 安全与合规（《安全与合规设计》§3/§8/§11/§14）：
 * 认证异常路径、API Key、限流 429、幂等重放/冲突、审计写入与脱敏。
 */
describe('Authentication edge cases', () => {
  let server: TestServer;

  beforeAll(async () => {
    server = await startTestServer({
      auth: {
        jwtSecret: TEST_JWT_SECRET,
        apiKeys: new Map([
          ['wbp_test_key', { userId: 'key_user', scopes: [...ALL_SCOPES], boards: null }],
        ]),
      },
    });
  });

  afterAll(async () => {
    await server.close();
  });

  it('rejects malformed tokens with 401 UNAUTHENTICATED', async () => {
    const result = await api(server.baseUrl, 'GET', '/v1/boards', { token: 'aa.bb.cc' });
    expect(result.status).toBe(401);
    expect(errorOf(result).code).toBe('UNAUTHENTICATED');
  });

  it('rejects expired tokens with 401 + detail.expired', async () => {
    const expired = jwt.sign({ sub: 'user_test', scopes: ['board:read'] }, TEST_JWT_SECRET, {
      algorithm: 'HS256',
      expiresIn: '-10s',
    });
    const result = await api(server.baseUrl, 'GET', '/v1/boards', { token: expired });
    expect(result.status).toBe(401);
    const error = errorOf(result);
    expect(error.code).toBe('UNAUTHENTICATED');
    expect((error.detail as Record<string, unknown>)['expired']).toBe(true);
  });

  it('authenticates with X-API-Key and rejects unknown keys', async () => {
    const ok = await api(server.baseUrl, 'POST', '/v1/boards', {
      token: null,
      apiKey: 'wbp_test_key',
      body: { name: 'Key Board' },
    });
    expect(ok.status).toBe(201);
    expect(dataOf(ok)['ownerId']).toBe('key_user');

    const denied = await api(server.baseUrl, 'GET', '/v1/boards', {
      token: null,
      apiKey: 'wbp_wrong_key',
    });
    expect(denied.status).toBe(401);
    expect(errorOf(denied).code).toBe('UNAUTHENTICATED');
  });
});

describe('Rate limiting', () => {
  let server: TestServer;

  beforeAll(async () => {
    server = await startTestServer({ rateLimit: { max: 3, windowMs: 60_000 } });
  });

  afterAll(async () => {
    await server.close();
  });

  it('returns 429 + Retry-After after exceeding the sliding window', async () => {
    const token = signToken({ sub: 'rl_user' });
    const first = await api(server.baseUrl, 'GET', '/v1/boards', { token });
    expect(first.status).toBe(200);
    expect(first.headers.get('x-ratelimit-limit')).toBe('3');

    await api(server.baseUrl, 'GET', '/v1/boards', { token });
    await api(server.baseUrl, 'GET', '/v1/boards', { token });

    const limited = await api(server.baseUrl, 'GET', '/v1/boards', { token });
    expect(limited.status).toBe(429);
    expect(errorOf(limited).code).toBe('RATE_LIMITED');
    expect(limited.headers.get('x-ratelimit-remaining')).toBe('0');
    expect(Number(limited.headers.get('retry-after'))).toBeGreaterThanOrEqual(1);
  });
});

describe('Idempotency', () => {
  let server: TestServer;

  beforeAll(async () => {
    server = await startTestServer();
  });

  afterAll(async () => {
    await server.close();
  });

  it('replays the stored response for the same key + body (Idempotency-Replay: true)', async () => {
    const first = await api(server.baseUrl, 'POST', '/v1/boards', {
      idempotencyKey: 'idem-001',
      body: { name: 'Idempotent Board' },
    });
    expect(first.status).toBe(201);
    const boardId = dataOf(first)['id'];

    const replay = await api(server.baseUrl, 'POST', '/v1/boards', {
      idempotencyKey: 'idem-001',
      body: { name: 'Idempotent Board' },
    });
    expect(replay.status).toBe(201);
    expect(replay.headers.get('idempotency-replay')).toBe('true');
    expect(dataOf(replay)['id']).toBe(boardId);
  });

  it('rejects the same key with a different body (409 CONFLICT)', async () => {
    await api(server.baseUrl, 'POST', '/v1/boards', {
      idempotencyKey: 'idem-002',
      body: { name: 'First Body' },
    });
    const conflict = await api(server.baseUrl, 'POST', '/v1/boards', {
      idempotencyKey: 'idem-002',
      body: { name: 'Different Body' },
    });
    expect(conflict.status).toBe(409);
    expect(errorOf(conflict).code).toBe('CONFLICT');
  });
});

describe('Audit trail', () => {
  let server: TestServer;
  const auditStore = new InMemoryAuditStore();

  beforeAll(async () => {
    server = await startTestServer({ auditStore });
  });

  afterAll(async () => {
    await server.close();
  });

  it('records who/what/when/target/result and redacts secrets', async () => {
    const created = await createBoard(server.baseUrl, 'Audited Board');
    const boardId = created['id'] as string;

    // 覆盖失败路径（401 无凭据）也被审计。
    await api(server.baseUrl, 'GET', '/v1/boards', { token: null });

    // share 携带 password（敏感），审计必须脱敏。
    const token = signToken();
    const share = await api(server.baseUrl, 'POST', `/v1/boards/${boardId}/share`, {
      token,
      body: { role: 'editor', password: 'top-secret-pw' },
    });
    expect(share.status).toBe(200);

    const entries = auditStore.entries;
    const createEntry = entries.find((e) => e.action === 'board.create' && e.who === 'user_test');
    expect(createEntry).toBeDefined();
    expect(createEntry?.target).toEqual({ type: 'board', id: boardId });
    expect(createEntry?.result).toEqual({ ok: true, status: 201 });
    expect(createEntry?.timestamp).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(createEntry?.requestId).toMatch(/^req_/);

    const anonymousEntry = entries.find((e) => e.result.status === 401);
    expect(anonymousEntry?.who).toBe('anonymous');

    const shareEntry = entries.find((e) => e.action === 'board.share');
    expect(shareEntry?.argsJson).toContain('"password":"***"');
    expect(shareEntry?.argsJson).not.toContain('top-secret-pw');

    // 任何审计记录都不允许出现凭据（Authorization / API Key / 密码原文）。
    const serialised = JSON.stringify(entries);
    expect(serialised).not.toContain(token);
    expect(serialised).not.toContain('top-secret-pw');
  });
});
