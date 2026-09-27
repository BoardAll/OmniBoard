import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  api,
  createBoard,
  createElement,
  createPage,
  dataOf,
  errorOf,
  startTestServer,
  type TestServer,
} from './helpers.js';

/**
 * Pages + Elements 流程（《OpenAPI规范.md》§5.2/§5.3）：
 * 创建/列表/dryRun 提案/更新/删除确认（422 → 204）。
 */
describe('Pages & Elements API', () => {
  let server: TestServer;
  let boardId: string;
  let pageId: string;

  beforeAll(async () => {
    server = await startTestServer();
    const board = await createBoard(server.baseUrl, 'Elements Board');
    boardId = board['id'] as string;
    const page = await createPage(server.baseUrl, boardId, 'Page 1');
    pageId = page['id'] as string;
  });

  afterAll(async () => {
    await server.close();
  });

  it('creates a sticky element (POST /v1/pages/{id}/elements → 201)', async () => {
    const result = await api(server.baseUrl, 'POST', `/v1/pages/${pageId}/elements`, {
      body: {
        elements: [
          { type: 'sticky', position: { x: 10, y: 20 }, size: { width: 100, height: 80 }, text: 'note' },
        ],
      },
    });
    expect(result.status).toBe(201);
    const data = dataOf<{ elements: Array<Record<string, unknown>>; dryRun: boolean }>(result);
    expect(data.dryRun).toBe(false);
    expect(data.elements).toHaveLength(1);
    expect(data.elements[0]?.['type']).toBe('sticky');
    expect(data.elements[0]?.['pageId']).toBe(pageId);
  });

  it('lists page elements with pagination meta', async () => {
    const result = await api(server.baseUrl, 'GET', `/v1/pages/${pageId}/elements`);
    expect(result.status).toBe(200);
    const items = result.body['data'] as Array<Record<string, unknown>>;
    const meta = result.body['meta'] as Record<string, unknown>;
    expect(items.length).toBeGreaterThanOrEqual(1);
    expect(meta['total']).toBeGreaterThanOrEqual(1);
  });

  it('dryRun returns a 200 proposal without persisting elements', async () => {
    const listBefore = await api(server.baseUrl, 'GET', `/v1/pages/${pageId}/elements`);
    const before = (listBefore.body['meta'] as Record<string, unknown>)['total'] as number;

    const dry = await api(server.baseUrl, 'POST', `/v1/pages/${pageId}/elements`, {
      body: { elements: [{ type: 'text', position: { x: 1, y: 1 } }], dryRun: true },
    });
    expect(dry.status).toBe(200);
    expect(dataOf<{ dryRun: boolean }>(dry).dryRun).toBe(true);

    const listAfter = await api(server.baseUrl, 'GET', `/v1/pages/${pageId}/elements`);
    expect((listAfter.body['meta'] as Record<string, unknown>)['total']).toBe(before);
  });

  it('updates an element (PATCH → 200)', async () => {
    const element = await createElement(server.baseUrl, pageId);
    const patched = await api(server.baseUrl, 'PATCH', `/v1/elements/${element['id'] as string}`, {
      body: { name: 'Renamed' },
    });
    expect(patched.status).toBe(200);
    expect(dataOf(patched)['name']).toBe('Renamed');
  });

  it('requires confirmation to delete an element (422 → 204 → 404)', async () => {
    const element = await createElement(server.baseUrl, pageId);
    const elementId = element['id'] as string;

    const denied = await api(server.baseUrl, 'DELETE', `/v1/elements/${elementId}`);
    expect(denied.status).toBe(422);
    expect((errorOf(denied).detail as Record<string, unknown>)['confirmationRequired']).toBe(true);

    const deleted = await api(server.baseUrl, 'DELETE', `/v1/elements/${elementId}?confirm=true`);
    expect(deleted.status).toBe(204);

    const gone = await api(server.baseUrl, 'GET', `/v1/elements/${elementId}`);
    expect(gone.status).toBe(404);
  });

  it('merges pages and splits a page (static route before :pageId)', async () => {
    const second = await createPage(server.baseUrl, boardId, 'Page 2');
    const merged = await api(server.baseUrl, 'POST', '/v1/pages/merge', {
      body: { pageIds: [pageId, second['id'] as string], name: 'Merged' },
    });
    expect(merged.status).toBe(200);
    expect(dataOf(merged)['name']).toBe('Merged');

    const split = await api(server.baseUrl, 'POST', `/v1/pages/${dataOf(merged)['id'] as string}/split`, {
      body: { splitY: 50 },
    });
    expect(split.status).toBe(201);
  });
});
