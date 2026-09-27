import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { InMemoryAuditStore } from '../src/middleware/audit.js';
import {
  api,
  createBoard,
  createElement,
  createPage,
  dataOf,
  errorOf,
  signToken,
  startTestServer,
  type TestServer,
} from './helpers.js';

/**
 * MCP 桥接（《OpenAPI规范.md》§5.10 + 《MCP_Server详细设计》）：
 * 工具目录、Server 信息、工具调用（auto）、破坏性工具确认流程、审计 fromAI。
 */
describe('MCP bridge API', () => {
  let server: TestServer;
  const auditStore = new InMemoryAuditStore();

  beforeAll(async () => {
    server = await startTestServer({ auditStore });
  });

  afterAll(async () => {
    await server.close();
  });

  it('GET /v1/mcp/tools lists the full tool catalog (30 tools)', async () => {
    const result = await api(server.baseUrl, 'GET', '/v1/mcp/tools');
    expect(result.status).toBe(200);
    const tools = result.body['data'] as Array<Record<string, unknown>>;
    expect(Array.isArray(tools)).toBe(true);
    expect(tools.length).toBe(30);
    const meta = result.body['meta'] as Record<string, unknown>;
    expect(meta['total']).toBe(30);

    const names = tools.map((tool) => tool['name']);
    expect(names).toContain('board_create');
    expect(names).toContain('element_delete');
    for (const tool of tools) {
      expect(typeof tool['name']).toBe('string');
      expect(typeof tool['description']).toBe('string');
      expect(typeof tool['inputSchema']).toBe('object');
      expect(['auto', 'preview', 'confirm']).toContain(tool['confirmation']);
    }
  });

  it('GET /v1/mcp/server exposes protocol version and capabilities', async () => {
    const result = await api(server.baseUrl, 'GET', '/v1/mcp/server');
    expect(result.status).toBe(200);
    const info = dataOf(result);
    expect(info['name']).toBe('whiteboard-mcp');
    expect(info['protocolVersion']).toBe('2025-06-18');
    const capabilities = info['capabilities'] as Record<string, unknown>;
    expect(capabilities['tools']).toBeDefined();
    expect(capabilities['resources']).toBeDefined();
    expect(capabilities['prompts']).toBeDefined();
  });

  it('calls an auto tool (board_create) and returns structured content', async () => {
    const result = await api(server.baseUrl, 'POST', '/v1/mcp/tools/board_create/call', {
      body: { arguments: { name: 'MCP Board' } },
    });
    expect(result.status).toBe(200);
    const data = dataOf<{
      isError: boolean;
      structuredContent: Record<string, unknown>;
      content: Array<{ type: string; text: string }>;
    }>(result);
    expect(data.isError).toBe(false);
    const board = data.structuredContent['board'] as Record<string, unknown>;
    expect(board['name']).toBe('MCP Board');
    expect(data.content[0]?.type).toBe('text');
  });

  it('rejects a confirm-level tool without confirm flag (422), then executes with confirm', async () => {
    const board = await createBoard(server.baseUrl, 'MCP Confirm Board');
    const page = await createPage(server.baseUrl, board['id'] as string, 'Page');
    const element = await createElement(server.baseUrl, page['id'] as string);
    const elementId = element['id'] as string;

    const denied = await api(server.baseUrl, 'POST', '/v1/mcp/tools/element_delete/call', {
      body: { arguments: { elementId } },
    });
    expect(denied.status).toBe(422);
    const detail = errorOf(denied).detail as Record<string, unknown>;
    expect(detail['confirmationRequired']).toBe(true);
    expect(detail['toolId']).toBe('element.delete');

    const stillThere = await api(server.baseUrl, 'GET', `/v1/elements/${elementId}`);
    expect(stillThere.status).toBe(200);

    const executed = await api(server.baseUrl, 'POST', '/v1/mcp/tools/element_delete/call', {
      body: { arguments: { elementId }, confirm: true },
    });
    expect(executed.status).toBe(200);
    expect((dataOf(executed)['structuredContent'] as Record<string, unknown>)['deleted']).toBe(true);

    const gone = await api(server.baseUrl, 'GET', `/v1/elements/${elementId}`);
    expect(gone.status).toBe(404);
  });

  it('returns 404 for unknown tools and 400 for missing arguments', async () => {
    const unknown = await api(server.baseUrl, 'POST', '/v1/mcp/tools/does_not_exist/call', {
      body: { arguments: {} },
    });
    expect(unknown.status).toBe(404);
    expect(errorOf(unknown).code).toBe('NOT_FOUND');

    const missing = await api(server.baseUrl, 'POST', '/v1/mcp/tools/board_get/call', {
      body: { arguments: {} },
    });
    expect(missing.status).toBe(400);
    expect(errorOf(missing).code).toBe('INVALID_ARGUMENT');
  });

  it('rejects tokens without mcp:invoke scope (403)', async () => {
    const token = signToken({ scopes: ['board:read'] });
    const result = await api(server.baseUrl, 'GET', '/v1/mcp/tools', { token });
    expect(result.status).toBe(403);
    expect(errorOf(result).code).toBe('PERMISSION_DENIED');
  });

  it('audits mcp.callTool with fromAI=true and action mcp.callTool', async () => {
    const entry = auditStore.entries.find((e) => e.action === 'mcp.callTool');
    expect(entry).toBeDefined();
    expect(entry?.fromAI).toBe(true);
    expect(entry?.target).toEqual({ type: 'mcp_tool', id: 'board_create' });
  });
});
