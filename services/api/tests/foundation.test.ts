import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { api, errorOf, startTestServer, type TestServer } from './helpers.js';

/**
 * 基础契约测试：/healthz、404、错误信封、请求体校验（INVALID_ARGUMENT）、
 * 无效 JSON（400）与 CORS/版本响应头。
 */
describe('API foundation', () => {
  let server: TestServer;

  beforeAll(async () => {
    server = await startTestServer();
  });

  afterAll(async () => {
    await server.close();
  });

  it('GET /healthz returns ok envelope without authentication', async () => {
    const result = await api(server.baseUrl, 'GET', '/healthz', { token: null });
    expect(result.status).toBe(200);
    expect(result.body['ok']).toBe(true);
    expect(result.body['error']).toBeNull();
    const data = result.body['data'] as Record<string, unknown>;
    expect(data['status']).toBe('ok');
    expect(typeof result.body['meta']).toBe('object');
  });

  it('sets X-Request-Id / X-API-Version response headers', async () => {
    const result = await api(server.baseUrl, 'GET', '/healthz', { token: null });
    expect(result.headers.get('x-api-version')).toBe('1');
    expect(result.headers.get('x-request-id')).toMatch(/^req_/);
  });

  it('returns 404 NOT_FOUND envelope for unknown routes', async () => {
    const result = await api(server.baseUrl, 'GET', '/v1/does-not-exist');
    expect(result.status).toBe(404);
    expect(result.body['ok']).toBe(false);
    expect(errorOf(result).code).toBe('NOT_FOUND');
  });

  it('rejects unauthenticated requests with 401 UNAUTHENTICATED', async () => {
    const result = await api(server.baseUrl, 'GET', '/v1/boards', { token: null });
    expect(result.status).toBe(401);
    expect(errorOf(result).code).toBe('UNAUTHENTICATED');
  });

  it('validates request bodies with INVALID_ARGUMENT + issues', async () => {
    const result = await api(server.baseUrl, 'POST', '/v1/boards', { body: {} });
    expect(result.status).toBe(400);
    const error = errorOf(result);
    expect(error.code).toBe('INVALID_ARGUMENT');
    const detail = error.detail as { issues: Array<{ path: string }> };
    expect(Array.isArray(detail.issues)).toBe(true);
    expect(detail.issues.some((issue) => issue.path === 'name')).toBe(true);
  });

  it('returns 400 for malformed JSON bodies', async () => {
    const result = await api(server.baseUrl, 'POST', '/v1/boards', { rawBody: '{not json' });
    expect(result.status).toBe(400);
    expect(errorOf(result).code).toBe('INVALID_ARGUMENT');
  });
});
