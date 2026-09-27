/**
 * 测试公共装配（全部离线）：
 * - 内存会话 / 审计；
 * - fake ToolInvoker（记录调用、可切换返回）；
 * - fake ResourceReader；
 * - McpDispatcher 与便捷 request/notify/raw 调用；
 * - 断言与轮询辅助。
 */

import { expect } from 'vitest';
import { MemoryAuditSink } from '../src/audit.js';
import { createLocalPrincipal } from '../src/auth/index.js';
import type { Principal } from '../src/auth/types.js';
import { McpDispatcher, type DispatchContext } from '../src/dispatcher.js';
import { PromptRegistry } from '../src/prompts/registry.js';
import type { JsonRpcFailure, JsonRpcResponse, JsonRpcSuccess } from '../src/protocol/jsonrpc.js';
import { ResourceRegistry, type ResourceReader } from '../src/resources/registry.js';
import { SessionStore } from '../src/session.js';
import {
  ToolExecutor,
  type ToolInvocationContext,
  type ToolInvoker,
} from '../src/tools/executor.js';
import type { ToolDefinition } from '../src/tools/registry.js';

export const SESSION_ID = 'test-session';

/** 全 Scope 主体（可覆盖任意字段）。 */
export function allScopesPrincipal(overrides: Partial<Principal> = {}): Principal {
  return { ...createLocalPrincipal('tester'), ...overrides };
}

export interface FakeInvocation {
  toolId: string;
  toolName: string;
  args: Record<string, unknown>;
  mode: 'execute' | 'preview';
  sessionId: string;
}

export type FakeHandler = (
  tool: ToolDefinition,
  args: Record<string, unknown>,
  ctx: ToolInvocationContext,
) => Promise<Record<string, unknown>>;

export interface FakeBackend {
  invocations: FakeInvocation[];
  invoker: ToolInvoker;
  setHandler(next: FakeHandler): void;
}

/** 记录调用的 fake 工具后端；默认回显 toolId/mode。 */
export function createFakeInvoker(): FakeBackend {
  const invocations: FakeInvocation[] = [];
  let handler: FakeHandler = async (tool, _args, ctx) => ({
    ok: true,
    toolId: tool.internalToolId,
    mode: ctx.mode,
  });
  const invoker: ToolInvoker = async (tool, args, ctx) => {
    invocations.push({
      toolId: tool.internalToolId,
      toolName: tool.name,
      args,
      mode: ctx.mode,
      sessionId: ctx.sessionId,
    });
    return handler(tool, args, ctx);
  };
  return {
    invocations,
    invoker,
    setHandler: (next) => {
      handler = next;
    },
  };
}

export interface FixtureOptions {
  principal?: Principal | null;
  transport?: DispatchContext['transport'];
  invoker?: ToolInvoker;
  reader?: ResourceReader;
  boards?: readonly string[];
}

export type RawResult = JsonRpcResponse | JsonRpcResponse[] | null;

export interface Fixture {
  sessions: SessionStore;
  audit: MemoryAuditSink;
  executor: ToolExecutor;
  resources: ResourceRegistry;
  prompts: PromptRegistry;
  dispatcher: McpDispatcher;
  ctx: DispatchContext;
  fake: FakeBackend;
  request(method: string, params?: unknown, id?: number): Promise<RawResult>;
  notify(method: string, params?: unknown): Promise<RawResult>;
  raw(text: string): Promise<RawResult>;
}

let idCounter = 100;

export function createFixture(options: FixtureOptions = {}): Fixture {
  const sessions = new SessionStore();
  sessions.create(SESSION_ID);
  const audit = new MemoryAuditSink();
  const fake = createFakeInvoker();
  const executor = new ToolExecutor({ invoke: options.invoker ?? fake.invoker, audit });
  const resources = new ResourceRegistry({
    boards: options.boards ?? ['board-1'],
    reader:
      options.reader ??
      (async (input) => ({
        uri: input.uri,
        mimeType: 'application/json',
        text: JSON.stringify({ uri: input.uri, kind: input.kind, params: input.params }),
      })),
  });
  const prompts = new PromptRegistry();
  const dispatcher = new McpDispatcher({ sessions, executor, resources, prompts, audit });
  const ctx: DispatchContext = {
    sessionId: SESSION_ID,
    transport: options.transport ?? 'stdio',
    principal: options.principal === undefined ? allScopesPrincipal() : options.principal,
  };

  return {
    sessions,
    audit,
    executor,
    resources,
    prompts,
    dispatcher,
    ctx,
    fake,
    request: (method, params, id) =>
      dispatcher.handleRaw(JSON.stringify({ jsonrpc: '2.0', id: id ?? (idCounter += 1), method, params }), ctx),
    notify: (method, params) => dispatcher.handleRaw(JSON.stringify({ jsonrpc: '2.0', method, params }), ctx),
    raw: (text) => dispatcher.handleRaw(text, ctx),
  };
}

/** 断言为成功响应并返回。 */
export function asSuccess(response: RawResult): JsonRpcSuccess {
  expect(response).not.toBeNull();
  expect(Array.isArray(response)).toBe(false);
  const single = response as JsonRpcResponse;
  if ('error' in single) {
    throw new Error(`expected success but got error ${single.error.code}: ${single.error.message}`);
  }
  return single;
}

/** 断言为错误响应并返回。 */
export function asFailure(response: RawResult): JsonRpcFailure {
  expect(response).not.toBeNull();
  expect(Array.isArray(response)).toBe(false);
  const single = response as JsonRpcResponse;
  if (!('error' in single)) throw new Error('expected error response but got success');
  return single;
}

/** 轮询等待条件成立（避免固定 sleep 造成抖动）。 */
export async function waitFor(predicate: () => boolean, timeoutMs = 5000, intervalMs = 10): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
  throw new Error('waitFor timed out');
}
