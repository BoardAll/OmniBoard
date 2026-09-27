import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { api, createBoard, dataOf, errorOf, signToken, startTestServer, type TestServer } from './helpers.js';

/**
 * Boards CRUD + 分页 + 过滤 + 破坏性操作确认 + 权限（《OpenAPI规范.md》§5.1）。
 */
describe('Boards API', () => {
  let server: TestServer;

  beforeAll(async () => {
    server = await startTestServer();
  });

  afterAll(async () => {
    await server.close();
  });

  it('creates a board (POST /v1/boards → 201) owned by the caller', async () => {
    const result = await api(server.baseUrl, 'POST', '/v1/boards', {
      body: { name: 'Sprint Board', description: 'demo' },
    });
    expect(result.status).toBe(201);
    const board = dataOf(result);
    expect(board['name']).toBe('Sprint Board');
    expect(board['description']).toBe('demo');
    expect(board['ownerId']).toBe('user_test');
    expect(typeof board['id']).toBe('string');
  });

  it('gets a board by id (GET /v1/boards/{id} → 200)', async () => {
    const created = await createBoard(server.baseUrl, 'Fetch Me');
    const result = await api(server.baseUrl, 'GET', `/v1/boards/${created['id'] as string}`);
    expect(result.status).toBe(200);
    expect(dataOf(result)['name']).toBe('Fetch Me');
  });

  it('updates a board (PATCH → 200) and persists the change', async () => {
    const created = await createBoard(server.baseUrl, 'Before');
    const patched = await api(server.baseUrl, 'PATCH', `/v1/boards/${created['id'] as string}`, {
      body: { name: 'After' },
    });
    expect(patched.status).toBe(200);
    expect(dataOf(patched)['name']).toBe('After');
    const fetched = await api(server.baseUrl, 'GET', `/v1/boards/${created['id'] as string}`);
    expect(dataOf(fetched)['name']).toBe('After');
  });

  it('paginates with limit + nextCursor and reports meta.total', async () => {
    await createBoard(server.baseUrl, 'Page-A');
    await createBoard(server.baseUrl, 'Page-B');
    await createBoard(server.baseUrl, 'Page-C');

    const first = await api(server.baseUrl, 'GET', '/v1/boards?limit=2&sort=name:asc');
    expect(first.status).toBe(200);
    const data = first.body['data'] as unknown[];
    const meta = first.body['meta'] as Record<string, unknown>;
    expect(data.length).toBe(2);
    expect(meta['hasMore']).toBe(true);
    expect(typeof meta['nextCursor']).toBe('string');
    expect(meta['total']).toBeGreaterThanOrEqual(3);

    const second = await api(
      server.baseUrl,
      'GET',
      `/v1/boards?limit=2&cursor=${encodeURIComponent(meta['nextCursor'] as string)}`,
    );
    const secondMeta = second.body['meta'] as Record<string, unknown>;
    expect((second.body['data'] as unknown[]).length).toBeGreaterThanOrEqual(1);
    expect(typeof secondMeta['hasMore']).toBe('boolean');
  });

  it('filters by name (contains, case-insensitive)', async () => {
    await createBoard(server.baseUrl, 'UniqueFilterTarget');
    const result = await api(server.baseUrl, 'GET', '/v1/boards?filter=name%3Auniquefilter');
    expect(result.status).toBe(200);
    const items = result.body['data'] as Array<Record<string, unknown>>;
    expect(items.length).toBe(1);
    expect(items[0]?.['name']).toBe('UniqueFilterTarget');
  });

  it('requires explicit confirmation to delete (422 without ?confirm=true)', async () => {
    const created = await createBoard(server.baseUrl, 'To Delete');
    const denied = await api(server.baseUrl, 'DELETE', `/v1/boards/${created['id'] as string}`);
    expect(denied.status).toBe(422);
    const error = errorOf(denied);
    expect(error.code).toBe('UNPROCESSABLE');
    expect((error.detail as Record<string, unknown>)['confirmationRequired']).toBe(true);

    const stillThere = await api(server.baseUrl, 'GET', `/v1/boards/${created['id'] as string}`);
    expect(stillThere.status).toBe(200);

    const deleted = await api(
      server.baseUrl,
      'DELETE',
      `/v1/boards/${created['id'] as string}?confirm=true`,
    );
    expect(deleted.status).toBe(204);

    const gone = await api(server.baseUrl, 'GET', `/v1/boards/${created['id'] as string}`);
    expect(gone.status).toBe(404);
    expect(errorOf(gone).code).toBe('NOT_FOUND');
  });

  it('rejects insufficient scope with 403 PERMISSION_DENIED', async () => {
    const readOnly = signToken({ sub: 'reader_user', scopes: ['board:read'] });
    const result = await api(server.baseUrl, 'POST', '/v1/boards', {
      token: readOnly,
      body: { name: 'Nope' },
    });
    expect(result.status).toBe(403);
    const error = errorOf(result);
    expect(error.code).toBe('PERMISSION_DENIED');
    expect((error.detail as Record<string, unknown>)['scope']).toBe('board:write');
  });

  it('restricts board-scoped tokens to their whitelist (403 on foreign board)', async () => {
    const mine = await createBoard(server.baseUrl, 'Scoped');
    const scoped = signToken({ sub: 'scoped_user', scopes: ['board:read', 'board:write'], boards: ['board_someone_else'] });
    const result = await api(server.baseUrl, 'GET', `/v1/boards/${mine['id'] as string}`, {
      token: scoped,
    });
    expect(result.status).toBe(403);
    expect(errorOf(result).code).toBe('PERMISSION_DENIED');
  });
});
