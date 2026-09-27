/** 资源：URI 模板匹配、list/read/subscribe、默认读取器。 */

import { describe, expect, it } from 'vitest';
import { RPC_ERROR_CODES } from '../src/protocol/jsonrpc.js';
import {
  createDefaultResourceReader,
  matchResource,
  RESOURCE_TEMPLATES,
  ResourceRegistry,
} from '../src/resources/registry.js';
import { allScopesPrincipal, asFailure, asSuccess, createFixture } from './helpers.js';

describe('resources：URI 模板匹配', () => {
  it('模板共 10 个，覆盖白板/页面/元素/评论/历史等', () => {
    expect(RESOURCE_TEMPLATES).toHaveLength(10);
    const kinds = RESOURCE_TEMPLATES.map((template) => template.kind);
    expect(kinds).toEqual(
      expect.arrayContaining([
        'boards',
        'board',
        'pages',
        'page',
        'elements',
        'page-thumbnail',
        'comments',
        'history',
        'collaborators',
        'templates',
      ]),
    );
  });

  it('匹配根 / 白板 / 页面 / 元素 URI 并解码参数', () => {
    expect(matchResource('whiteboard://boards')).toMatchObject({ template: { kind: 'boards' }, params: {} });
    expect(matchResource('whiteboard://boards/b1')).toMatchObject({
      template: { kind: 'board' },
      params: { boardId: 'b1' },
    });
    expect(matchResource('whiteboard://boards/b1/pages')).toMatchObject({
      template: { kind: 'pages' },
      params: { boardId: 'b1' },
    });
    expect(matchResource('whiteboard://boards/b1/pages/p1/elements')).toMatchObject({
      template: { kind: 'elements' },
      params: { boardId: 'b1', pageId: 'p1' },
    });
    expect(matchResource('whiteboard://boards/b1/pages/p1/thumbnail')).toMatchObject({
      template: { kind: 'page-thumbnail' },
      params: { boardId: 'b1', pageId: 'p1' },
    });
  });

  it('未知 URI → null', () => {
    expect(matchResource('https://example.com/boards')).toBeNull();
    expect(matchResource('whiteboard://unknown/x')).toBeNull();
  });
});

describe('resources：注册表 list', () => {
  it('已配置白板 → root + 每白板 6 类资源', () => {
    const registry = new ResourceRegistry({ boards: ['board-1'] });
    const { resources, nextCursor } = registry.list(allScopesPrincipal());
    expect(nextCursor).toBeNull();
    expect(resources).toHaveLength(7);
    expect(resources[0]?.uri).toBe('whiteboard://boards');
    const boardUris = resources.filter((r) => r.uri.startsWith('whiteboard://boards/board-1'));
    expect(boardUris).toHaveLength(6);
  });

  it('主体白板范围过滤（§9.5）', () => {
    const registry = new ResourceRegistry({ boards: ['board-1', 'board-2'] });
    const { resources } = registry.list(allScopesPrincipal({ boards: ['board-2'] }));
    const ids = resources.filter((r) => r.uri.startsWith('whiteboard://boards/'));
    expect(ids.every((r) => r.uri.includes('board-2'))).toBe(true);
    expect(ids.some((r) => r.uri.includes('board-1'))).toBe(false);
  });

  it('dispatcher resources/list → { resources }（无分页省略 nextCursor）', async () => {
    const fixture = createFixture({ boards: ['board-1'] });
    const result = asSuccess(await fixture.request('resources/list')).result as {
      resources: Array<{ uri: string }>;
      nextCursor?: string;
    };
    expect(result.nextCursor).toBeUndefined();
    expect(result.resources[0]?.uri).toBe('whiteboard://boards');

    const templates = asSuccess(await fixture.request('resources/templates/list')).result as {
      resourceTemplates: Array<{ uriTemplate: string; mimeType: string }>;
    };
    expect(templates.resourceTemplates).toHaveLength(10);
    expect(templates.resourceTemplates[0]).toMatchObject({ mimeType: 'application/json' });
  });
});

describe('resources：read / subscribe', () => {
  it('read 成功 → contents 单条（fake 读取器）', async () => {
    const fixture = createFixture();
    const result = asSuccess(await fixture.request('resources/read', { uri: 'whiteboard://boards/board-1' }))
      .result as { contents: Array<{ uri: string; mimeType: string; text: string }> };
    expect(result.contents).toHaveLength(1);
    const content = result.contents[0];
    expect(content?.mimeType).toBe('application/json');
    expect(JSON.parse(content?.text ?? '{}')).toMatchObject({
      uri: 'whiteboard://boards/board-1',
      kind: 'board',
      params: { boardId: 'board-1' },
    });
  });

  it('read 未知 URI → -32003', async () => {
    const fixture = createFixture();
    const failure = asFailure(await fixture.request('resources/read', { uri: 'whiteboard://nope' }));
    expect(failure.error.code).toBe(RPC_ERROR_CODES.notFound);
  });

  it('read 缺 uri / uri 非字符串 → -32602', async () => {
    const fixture = createFixture();
    expect(asFailure(await fixture.request('resources/read', {})).error.code).toBe(RPC_ERROR_CODES.invalidParams);
    expect(asFailure(await fixture.request('resources/read', { uri: 42 })).error.code).toBe(
      RPC_ERROR_CODES.invalidParams,
    );
  });

  it('subscribe / unsubscribe（会话级登记）', async () => {
    const fixture = createFixture();
    const uri = 'whiteboard://boards/board-1/pages';
    expect(asSuccess(await fixture.request('resources/subscribe', { uri })).result).toEqual({});
    expect(fixture.resources.subscriptionsOf(fixture.ctx.sessionId)).toEqual([uri]);

    expect(asSuccess(await fixture.request('resources/unsubscribe', { uri })).result).toEqual({});
    expect(fixture.resources.subscriptionsOf(fixture.ctx.sessionId)).toEqual([]);

    const failure = asFailure(await fixture.request('resources/subscribe', { uri: 'whiteboard://nope' }));
    expect(failure.error.code).toBe(RPC_ERROR_CODES.notFound);
  });
});

describe('resources：默认读取器', () => {
  it('未配置 WB_API_BASE_URL → 显式占位 JSON（不伪造数据）', async () => {
    const reader = createDefaultResourceReader();
    const content = await reader(
      { uri: 'whiteboard://boards/b1', kind: 'board', params: { boardId: 'b1' } },
      { sessionId: 's', principal: null },
    );
    const payload = JSON.parse(content.text) as { data: null; note: string };
    expect(payload.data).toBeNull();
    expect(payload.note).toContain('WB_API_BASE_URL');
  });

  it('配置 baseUrl → 转发 services/api 并归一化 { ok, data }', async () => {
    const calls: string[] = [];
    const reader = createDefaultResourceReader({
      apiBaseUrl: 'http://api.test',
      apiKey: 'svc-key',
      fetchImpl: async (input: string | URL | Request) => {
        calls.push(String(input));
        return new Response(JSON.stringify({ ok: true, data: { id: 'b1', name: 'Demo' } }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        });
      },
    });
    const content = await reader(
      { uri: 'whiteboard://boards/b1', kind: 'board', params: { boardId: 'b1' } },
      { sessionId: 's', principal: null },
    );
    expect(calls[0]).toBe('http://api.test/v1/boards/b1');
    expect(JSON.parse(content.text)).toEqual({ id: 'b1', name: 'Demo' });
  });

  it('后端 404 → -32003；403 → -32002', async () => {
    const notFound = createDefaultResourceReader({
      apiBaseUrl: 'http://api.test',
      fetchImpl: async () =>
        new Response(JSON.stringify({ ok: false, error: { code: 'NOT_FOUND', message: 'x' } }), { status: 404 }),
    });
    await expect(
      notFound({ uri: 'whiteboard://boards/b1', kind: 'board', params: { boardId: 'b1' } }, { sessionId: 's', principal: null }),
    ).rejects.toMatchObject({ code: RPC_ERROR_CODES.notFound });

    const forbidden = createDefaultResourceReader({
      apiBaseUrl: 'http://api.test',
      fetchImpl: async () =>
        new Response(JSON.stringify({ ok: false, error: { code: 'PERMISSION_DENIED', message: 'x' } }), {
          status: 403,
        }),
    });
    await expect(
      forbidden(
        { uri: 'whiteboard://boards/b1', kind: 'board', params: { boardId: 'b1' } },
        { sessionId: 's', principal: null },
      ),
    ).rejects.toMatchObject({ code: RPC_ERROR_CODES.permissionDenied });
  });
});
