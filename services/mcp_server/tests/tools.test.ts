/** 工具目录、tools/list、tools/call 校验 / Scope / 确认流程。 */

import { describe, expect, it } from 'vitest';
import { RPC_ERROR_CODES } from '../src/protocol/jsonrpc.js';
import { ToolExecutionError } from '../src/tools/executor.js';
import { findTool, listTools, TOOL_CATALOG, toInternalToolId } from '../src/tools/registry.js';
import { allScopesPrincipal, asFailure, asSuccess, createFixture } from './helpers.js';

describe('tools/list', () => {
  it('返回 113 个工具 + 列表形状 { tools }（静态目录不分页）', async () => {
    const fixture = createFixture();
    const result = asSuccess(await fixture.request('tools/list')).result as {
      tools: Array<Record<string, unknown>>;
      nextCursor?: string;
    };
    expect(result.tools).toHaveLength(113);
    expect(result.nextCursor).toBeUndefined();

    const sample = result.tools[0];
    expect(sample).toBeDefined();
    expect(typeof sample?.['name']).toBe('string');
    expect(typeof sample?.['description']).toBe('string');
    expect((sample?.['inputSchema'] as Record<string, unknown>)['type']).toBe('object');
  });

  it('cursor 为字符串 → 仍返回完整目录（静态目录省略 nextCursor）', async () => {
    const fixture = createFixture();
    const result = asSuccess(await fixture.request('tools/list', { cursor: 'opaque-cursor' })).result as {
      tools: unknown[];
      nextCursor?: string;
    };
    expect(result.tools).toHaveLength(113);
    expect(result.nextCursor).toBeUndefined();
  });

  it('cursor 类型非法 → -32602', async () => {
    const fixture = createFixture();
    const failure = asFailure(await fixture.request('tools/list', { cursor: 42 }));
    expect(failure.error.code).toBe(RPC_ERROR_CODES.invalidParams);
  });

  it('registry 层：listTools() 与 TOOL_CATALOG 一致（113 项）', () => {
    expect(TOOL_CATALOG).toHaveLength(113);
    const direct = listTools();
    expect(Array.isArray(direct)).toBe(true);
    expect(direct).toHaveLength(113);
  });
});

describe('tools/call：校验与权限', () => {
  it('未知工具 → -32601', async () => {
    const fixture = createFixture();
    const failure = asFailure(await fixture.request('tools/call', { name: 'element_sparkle' }));
    expect(failure.error.code).toBe(RPC_ERROR_CODES.methodNotFound);
    expect(failure.error.message).toContain('element_sparkle');
  });

  it('缺少 name / name 非法 → -32602', async () => {
    const fixture = createFixture();
    expect(asFailure(await fixture.request('tools/call', {})).error.code).toBe(RPC_ERROR_CODES.invalidParams);
    expect(asFailure(await fixture.request('tools/call', { name: '' })).error.code).toBe(
      RPC_ERROR_CODES.invalidParams,
    );
  });

  it('schema 校验失败（缺必填）→ -32602 且 data.errors 列出问题', async () => {
    const fixture = createFixture();
    const failure = asFailure(await fixture.request('tools/call', { name: 'element_create', arguments: {} }));
    expect(failure.error.code).toBe(RPC_ERROR_CODES.invalidParams);
    const data = failure.error.data as { toolId: string; errors: Array<{ path: string; message: string }> };
    expect(data.toolId).toBe('element.create');
    expect(data.errors.length).toBeGreaterThanOrEqual(2);
    const errorPaths = data.errors.map((issue) => issue.path);
    expect(errorPaths).toContain('$.pageId');
    expect(errorPaths).toContain('$.elements');
  });

  it('arguments 非对象 → -32602', async () => {
    const fixture = createFixture();
    const failure = asFailure(
      await fixture.request('tools/call', { name: 'board_get', arguments: 'not-an-object' }),
    );
    expect(failure.error.code).toBe(RPC_ERROR_CODES.invalidParams);
  });

  it('Scope 缺失 → -32002（data 含 scope/toolId）并写审计 denied', async () => {
    const fixture = createFixture({ principal: allScopesPrincipal({ scopes: ['board:read'] }) });
    const failure = asFailure(
      await fixture.request('tools/call', {
        name: 'element_create',
        arguments: { pageId: 'p1', elements: [{}] },
      }),
    );
    expect(failure.error.code).toBe(RPC_ERROR_CODES.permissionDenied);
    expect(failure.error.data).toEqual({ scope: 'element:write', toolId: 'element.create' });
    expect(fixture.fake.invocations).toHaveLength(0);

    const denied = fixture.audit.entries.find((entry) => entry.action === 'tool.call');
    expect(denied).toMatchObject({ result: 'denied' });
  });

  it('auto 工具直接执行（fake 收到 mode=execute），结果为 MCP 形状', async () => {
    const fixture = createFixture();
    const result = asSuccess(
      await fixture.request('tools/call', { name: 'board_get', arguments: { boardId: 'board-1' } }),
    ).result as {
      content: Array<{ type: string; text: string }>;
      isError: boolean;
      structuredContent: Record<string, unknown>;
    };

    expect(result.isError).toBe(false);
    expect(result.content[0]?.type).toBe('text');
    expect(result.structuredContent).toMatchObject({ ok: true, toolId: 'board.get', mode: 'execute' });
    expect(fixture.fake.invocations).toHaveLength(1);
    expect(fixture.fake.invocations[0]).toMatchObject({ mode: 'execute', sessionId: fixture.ctx.sessionId });
    expect(fixture.audit.entries.at(-1)).toMatchObject({ action: 'tool.call', result: 'success' });
  });

  it('后端错误映射：ToolExecutionError notFound → -32003', async () => {
    const fixture = createFixture();
    fixture.fake.setHandler(async () => {
      throw new ToolExecutionError('notFound', 'Board not found');
    });
    const failure = asFailure(
      await fixture.request('tools/call', { name: 'board_get', arguments: { boardId: 'missing' } }),
    );
    expect(failure.error.code).toBe(RPC_ERROR_CODES.notFound);
    expect(failure.error.message).toContain('Board not found');
    expect(fixture.audit.entries.at(-1)).toMatchObject({ action: 'tool.call', result: 'error' });
  });
});

describe('tools/call：确认流程', () => {
  it('confirm 级别首次调用 → -32005 + confirmationId；二次带 _meta.confirmationId 执行', async () => {
    const fixture = createFixture();
    const first = asFailure(
      await fixture.request('tools/call', { name: 'element_delete', arguments: { elementId: 'e1' } }),
    );
    expect(first.error.code).toBe(RPC_ERROR_CODES.confirmationRequired);
    const data = first.error.data as { toolId: string; confirmation: string; confirmationId: string };
    expect(data.toolId).toBe('element.delete');
    expect(data.confirmation).toBe('confirm');
    expect(data.confirmationId).toMatch(/^conf_/);
    expect(fixture.fake.invocations).toHaveLength(0);

    const second = asSuccess(
      await fixture.request('tools/call', {
        name: 'element_delete',
        arguments: { elementId: 'e1' },
        _meta: { confirmationId: data.confirmationId },
      }),
    );
    expect((second.result as { isError: boolean }).isError).toBe(false);
    expect(fixture.fake.invocations).toHaveLength(1);
    expect(fixture.fake.invocations[0]).toMatchObject({ toolId: 'element.delete', mode: 'execute' });
  });

  it('_meta.confirm: true 直接视为已确认', async () => {
    const fixture = createFixture();
    const result = asSuccess(
      await fixture.request('tools/call', {
        name: 'page_delete',
        arguments: { pageId: 'p1' },
        _meta: { confirm: true },
      }),
    );
    expect((result.result as { isError: boolean }).isError).toBe(false);
    expect(fixture.fake.invocations[0]).toMatchObject({ toolId: 'page.delete', mode: 'execute' });
  });

  it('confirmationId 未知/过期 → 重新发起确认并携带 reason', async () => {
    const fixture = createFixture();
    const failure = asFailure(
      await fixture.request('tools/call', {
        name: 'element_delete',
        arguments: { elementId: 'e1' },
        _meta: { confirmationId: 'conf_missing' },
      }),
    );
    expect(failure.error.code).toBe(RPC_ERROR_CODES.confirmationRequired);
    expect((failure.error.data as { reason?: string }).reason).toContain('unknown');
  });

  it('confirmationId 与工具不匹配 → -32602', async () => {
    const fixture = createFixture();
    const first = asFailure(
      await fixture.request('tools/call', { name: 'element_delete', arguments: { elementId: 'e1' } }),
    );
    const confirmationId = (first.error.data as { confirmationId: string }).confirmationId;

    const mismatched = asFailure(
      await fixture.request('tools/call', {
        name: 'page_delete',
        arguments: { pageId: 'p1' },
        _meta: { confirmationId },
      }),
    );
    expect(mismatched.error.code).toBe(RPC_ERROR_CODES.invalidParams);
  });

  it('confirm_operation：approved=false → -32006；approved=true 执行；未知 id → -32003', async () => {
    const fixture = createFixture();
    const first = asFailure(
      await fixture.request('tools/call', { name: 'element_delete', arguments: { elementId: 'e1' } }),
    );
    const confirmationId = (first.error.data as { confirmationId: string }).confirmationId;

    const cancelled = asFailure(
      await fixture.request('tools/call', {
        name: 'confirm_operation',
        arguments: { confirmationId, approved: false },
      }),
    );
    expect(cancelled.error.code).toBe(RPC_ERROR_CODES.cancelled);

    const unknown = asFailure(
      await fixture.request('tools/call', {
        name: 'confirm_operation',
        arguments: { confirmationId: 'conf_none', approved: true },
      }),
    );
    expect(unknown.error.code).toBe(RPC_ERROR_CODES.notFound);

    const again = asFailure(
      await fixture.request('tools/call', { name: 'element_delete', arguments: { elementId: 'e1' } }),
    );
    const secondId = (again.error.data as { confirmationId: string }).confirmationId;
    const executed = asSuccess(
      await fixture.request('tools/call', {
        name: 'confirm_operation',
        arguments: { confirmationId: secondId, approved: true },
      }),
    );
    expect((executed.result as { isError: boolean }).isError).toBe(false);
    expect(fixture.fake.invocations).toHaveLength(1);
    expect(fixture.fake.invocations[0]?.mode).toBe('execute');
  });

  it('preview 级别（page_split）：首次返回 requiresConfirmation，二次确认后执行', async () => {
    const fixture = createFixture();
    const first = asSuccess(
      await fixture.request('tools/call', { name: 'page_split', arguments: { pageId: 'p1', splitY: 120 } }),
    );
    const structured = (first.result as Record<string, unknown>)['structuredContent'] as {
      requiresConfirmation: boolean;
      confirmationId: string;
      preview: Record<string, unknown>;
    };
    expect(structured.requiresConfirmation).toBe(true);
    expect(structured.confirmationId).toMatch(/^conf_/);
    expect(structured.preview).toMatchObject({ mode: 'preview' });
    expect(fixture.fake.invocations[0]?.mode).toBe('preview');

    const second = asSuccess(
      await fixture.request('tools/call', {
        name: 'page_split',
        arguments: { pageId: 'p1', splitY: 120 },
        _meta: { confirmationId: structured.confirmationId },
      }),
    );
    expect((second.result as { isError: boolean }).isError).toBe(false);
    expect(fixture.fake.invocations[1]?.mode).toBe('execute');
  });
});

describe('确认级别与命名映射（与 services/api 对齐抽查）', () => {
  it('确认级别抽查：删除类 confirm / 结构重排 preview / 查询 auto', () => {
    expect(findTool('element_delete')?.confirmation).toBe('confirm');
    expect(findTool('board_delete')?.confirmation).toBe('confirm');
    expect(findTool('page_merge')?.confirmation).toBe('confirm');
    expect(findTool('page_split')?.confirmation).toBe('preview');
    expect(findTool('element_batch')?.confirmation).toBe('preview');
    expect(findTool('present_start')?.confirmation).toBe('preview');
    expect(findTool('board_get')?.confirmation).toBe('auto');
  });

  it('命名映射：下划线 ↔ 点号（含 render 3d/2d/function 前缀）', () => {
    expect(toInternalToolId('element_create')).toBe('element.create');
    expect(toInternalToolId('render_3d_create')).toBe('render.3d.create');
    expect(toInternalToolId('render_2d_export')).toBe('render.2d.export');
    expect(toInternalToolId('render_function_set_style')).toBe('render.function.set_style');

    expect(findTool('element.create')?.name).toBe('element_create');
    expect(findTool('render.3d.create')?.name).toBe('render_3d_create');
    expect(findTool('element_create')?.scope).toBe('element:write');
    expect(findTool('board_get')?.scope).toBe('board:read');
  });
});
