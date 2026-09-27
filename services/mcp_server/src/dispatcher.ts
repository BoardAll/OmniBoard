/**
 * MCP 请求分发器（《MCP_Server详细设计》§2.4 / §5 / §18）。
 *
 * 职责：把传输层收到的原始 JSON（单条 / 批量）解析为 JSON-RPC 消息，
 * 路由到 initialize / tools / resources / prompts / logging / 生命周期方法，
 * 并统一转换为响应（请求）或静默处理（通知）。
 *
 * 约束：
 * - 协议编解码复用 `protocol/jsonrpc.ts`（自研实现，不依赖 SDK）；
 * - `initialize` 复用 `protocol/initialize.ts` 的握手/版本协商；
 * - 通知永远不产生响应（含未知通知）；
 * - 未知方法 → -32601；内部异常 → -32603 且不泄漏细节；
 * - 请求级速率限制 → -32001（§9.6）。
 */

import {
  failure,
  isNotification,
  isRequest,
  isResponse,
  parseMessage,
  RPC_ERROR_CODES,
  RpcError,
  success,
  toErrorResponse,
  type JsonRpcMessage,
  type JsonRpcRequest,
  type JsonRpcResponse,
} from './protocol/jsonrpc.js';
import { handleInitialize, type InitializeParams } from './protocol/initialize.js';
import { listTools } from './tools/registry.js';
import type { ToolExecutor, ToolCallContext, ToolCallParams } from './tools/executor.js';
import type { ResourceRegistry } from './resources/registry.js';
import type { PromptRegistry } from './prompts/registry.js';
import type { SessionStore } from './session.js';
import type { RateLimiter } from './auth/rateLimit.js';
import type { Principal } from './auth/types.js';
import { buildAuditEntry, NULL_AUDIT_SINK, type AuditSink } from './audit.js';
import { NULL_LOGGER, type Logger } from './log.js';

export type TransportKind = 'stdio' | 'sse' | 'http';

/** 一次请求的调用上下文（由传输层构造）。 */
export interface DispatchContext {
  sessionId: string;
  transport: TransportKind;
  principal: Principal | null;
  clientName?: string | null;
  clientVersion?: string | null;
  ip?: string;
}

export interface McpDispatcherDeps {
  sessions: SessionStore;
  executor: ToolExecutor;
  resources: ResourceRegistry;
  prompts: PromptRegistry;
  audit?: AuditSink;
  logger?: Logger;
  /** 请求级速率限制器（可注入时钟进行测试）。 */
  rateLimiter?: RateLimiter;
}

/** RFC 5424 日志级别（`logging/setLevel`，MCP 规范）。 */
export const LOGGING_LEVELS = [
  'debug',
  'info',
  'notice',
  'warning',
  'error',
  'critical',
  'alert',
  'emergency',
] as const;

export type LoggingLevel = (typeof LOGGING_LEVELS)[number];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** 从解析结果中尽力提取 id（无效时返回 null，用于错误响应对齐）。 */
function extractId(raw: unknown): string | number | null {
  if (!isRecord(raw)) return null;
  const id = raw['id'];
  if (typeof id === 'string') return id;
  if (typeof id === 'number' && Number.isFinite(id)) return id;
  return null;
}

function requireObjectParams(method: string, params: unknown): Record<string, unknown> {
  if (params === undefined || params === null) return {};
  if (!isRecord(params)) {
    throw RpcError.invalidParams(`Invalid params for ${method}: params must be an object`);
  }
  return params;
}

function requireString(params: Record<string, unknown>, field: string, method: string): string {
  const value = params[field];
  if (typeof value !== 'string' || value.length === 0) {
    throw RpcError.invalidParams(`Invalid params for ${method}: "${field}" must be a non-empty string`, {
      field,
    });
  }
  return value;
}

/**
 * 列表响应适配：无下一页时省略 `nextCursor`。
 * MCP 规范中 `nextCursor` 为可选字符串；`null` 会被严格校验的客户端拒绝。
 */
function stripNullCursor<T extends { nextCursor: string | null }>(
  result: T,
): Omit<T, 'nextCursor'> & { nextCursor?: string } {
  const { nextCursor, ...rest } = result;
  if (nextCursor === null) return rest;
  return { ...rest, nextCursor };
}

export class McpDispatcher {
  private readonly sessions: SessionStore;
  private readonly executor: ToolExecutor;
  private readonly resources: ResourceRegistry;
  private readonly prompts: PromptRegistry;
  private readonly audit: AuditSink;
  private readonly logger: Logger;
  private readonly rateLimiter: RateLimiter | undefined;

  constructor(deps: McpDispatcherDeps) {
    this.sessions = deps.sessions;
    this.executor = deps.executor;
    this.resources = deps.resources;
    this.prompts = deps.prompts;
    this.audit = deps.audit ?? NULL_AUDIT_SINK;
    this.logger = deps.logger ?? NULL_LOGGER;
    this.rateLimiter = deps.rateLimiter;
  }

  /**
   * 处理原始文本（stdio 行 / HTTP body）：
   * - JSON 解析失败 → -32700（id: null）；
   * - 批量数组：逐条处理，全为通知时返回 null。
   */
  async handleRaw(raw: string, ctx: DispatchContext): Promise<JsonRpcResponse | JsonRpcResponse[] | null> {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return failure(null, RPC_ERROR_CODES.parseError, 'Parse error');
    }
    return this.handleValue(parsed, ctx);
  }

  /** 处理已解析的 JSON 值（对象或批量数组）。 */
  async handleValue(parsed: unknown, ctx: DispatchContext): Promise<JsonRpcResponse | JsonRpcResponse[] | null> {
    if (Array.isArray(parsed)) {
      if (parsed.length === 0) {
        return failure(null, RPC_ERROR_CODES.invalidRequest, 'Invalid Request: empty batch');
      }
      const responses: JsonRpcResponse[] = [];
      for (const item of parsed) {
        const response = await this.handleItem(item, ctx);
        if (response) responses.push(response);
      }
      return responses.length > 0 ? responses : null;
    }
    return this.handleItem(parsed, ctx);
  }

  /** 处理批量中的单条（parseMessage 失败 → -32600/-32700 形状错误响应）。 */
  private async handleItem(item: unknown, ctx: DispatchContext): Promise<JsonRpcResponse | null> {
    let message: JsonRpcMessage;
    try {
      message = parseMessage(item);
    } catch (error) {
      if (error instanceof RpcError) {
        return failure(extractId(item), error.code, error.message, error.data);
      }
      return failure(extractId(item), RPC_ERROR_CODES.internalError, 'Internal error');
    }
    return this.handleMessage(message, ctx);
  }

  /** 处理单条已解析消息。通知返回 null（协议要求无响应）。 */
  async handleMessage(message: JsonRpcMessage, ctx: DispatchContext): Promise<JsonRpcResponse | null> {
    if (isResponse(message)) {
      // 服务端不消费响应消息（仍以 -32600 明确拒绝，便于诊断）。
      return failure(
        message.id ?? null,
        RPC_ERROR_CODES.invalidRequest,
        'Invalid Request: server does not accept response messages',
      );
    }
    if (isNotification(message)) {
      this.handleNotification(message, ctx);
      return null;
    }
    if (!isRequest(message)) {
      return failure(null, RPC_ERROR_CODES.invalidRequest, 'Invalid Request: unrecognised message shape');
    }

    const { id, method } = message;
    try {
      this.checkRateLimit(ctx);
      const result = await this.handleRequest(message, ctx);
      return success(id, result);
    } catch (error) {
      if (error instanceof RpcError) return toErrorResponse(id, error);
      this.logger.error('Unhandled dispatch error', {
        method,
        message: error instanceof Error ? error.message : 'unknown error',
      });
      return toErrorResponse(id, error);
    }
  }

  /* ---------------------------------------------------------------- */
  /* 请求路由                                                           */
  /* ---------------------------------------------------------------- */

  private async handleRequest(request: JsonRpcRequest, ctx: DispatchContext): Promise<unknown> {
    const { method } = request;
    switch (method) {
      case 'initialize':
        return this.onInitialize(request.params, ctx);
      case 'ping':
        return {};
      case 'tools/list':
        return this.onToolsList(request.params);
      case 'tools/call':
        return this.onToolsCall(request.params, ctx);
      case 'resources/list':
        return this.onResourcesList(request.params, ctx);
      case 'resources/templates/list':
        return this.onResourcesTemplatesList();
      case 'resources/read':
        return this.onResourcesRead(request.params, ctx);
      case 'resources/subscribe':
        return this.onResourcesSubscribe(request.params, ctx);
      case 'resources/unsubscribe':
        return this.onResourcesUnsubscribe(request.params, ctx);
      case 'prompts/list':
        return this.onPromptsList(request.params);
      case 'prompts/get':
        return this.onPromptsGet(request.params);
      case 'logging/setLevel':
        return this.onLoggingSetLevel(request.params, ctx);
      case 'completion/complete':
        return this.onCompletionComplete(request.params);
      case 'shutdown':
        return this.onShutdown(ctx);
      default:
        throw RpcError.methodNotFound(method);
    }
  }

  private onInitialize(params: unknown, ctx: DispatchContext): unknown {
    if (params !== undefined && params !== null && !isRecord(params)) {
      throw RpcError.invalidParams('Invalid params for initialize: params must be an object');
    }
    const state = this.sessions.getOrCreate(ctx.sessionId);
    const { result } = handleInitialize((params ?? undefined) as InitializeParams | undefined, state.meta);
    this.sessions.touch(ctx.sessionId);
    this.logger.info('Session initialised', {
      sessionId: ctx.sessionId,
      protocolVersion: result.protocolVersion,
      clientName: state.meta.clientInfo?.name ?? 'unknown',
      transport: ctx.transport,
    });
    return result;
  }

  private onToolsList(params: unknown): unknown {
    const record = requireObjectParams('tools/list', params);
    const cursor = record['cursor'];
    if (cursor !== undefined && cursor !== null && typeof cursor !== 'string') {
      throw RpcError.invalidParams('Invalid params for tools/list: "cursor" must be a string');
    }
  // 静态目录：无下一页；nextCursor 省略（规范中为可选字符串）。
    const listed = listTools(cursor ?? null);
    return {
      tools: listed.tools.map((tool) => ({
        name: tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema,
      })),
      ...(listed.nextCursor === null ? {} : { nextCursor: listed.nextCursor }),
    };
  }

  private async onToolsCall(params: unknown, ctx: DispatchContext): Promise<unknown> {
    const record = requireObjectParams('tools/call', params);
    const name = requireString(record, 'name', 'tools/call');

    const rawArguments = record['arguments'];
    if (rawArguments !== undefined && rawArguments !== null && !isRecord(rawArguments)) {
      throw RpcError.invalidParams('Invalid params for tools/call: "arguments" must be an object', {
        tool: name,
      });
    }

    const meta: Record<string, unknown> = isRecord(record['_meta']) ? { ...record['_meta'] } : {};
    if (meta['confirmationId'] === undefined && typeof record['confirmationId'] === 'string') {
      meta['confirmationId'] = record['confirmationId'];
    }
    if (meta['confirm'] === undefined && record['confirm'] === true) {
      meta['confirm'] = true;
    }

    const callParams: ToolCallParams = { name, arguments: rawArguments ?? {} };
    if (Object.keys(meta).length > 0) callParams.meta = meta;

    const state = this.sessions.getOrCreate(ctx.sessionId);
    const callCtx: ToolCallContext = {
      sessionId: ctx.sessionId,
      principal: ctx.principal,
      transport: ctx.transport,
      clientName: ctx.clientName ?? state.meta.clientInfo?.name ?? null,
      clientVersion: ctx.clientVersion ?? state.meta.clientInfo?.version ?? null,
    };
    if (ctx.ip !== undefined) callCtx.ip = ctx.ip;
    this.sessions.touch(ctx.sessionId);
    return this.executor.callTool(callParams, callCtx);
  }

  private onResourcesList(params: unknown, ctx: DispatchContext): unknown {
    const record = requireObjectParams('resources/list', params);
    const cursor = record['cursor'];
    if (cursor !== undefined && cursor !== null && typeof cursor !== 'string') {
      throw RpcError.invalidParams('Invalid params for resources/list: "cursor" must be a string');
    }
    return stripNullCursor(this.resources.list(ctx.principal));
  }

  private onResourcesTemplatesList(): unknown {
    return {
      resourceTemplates: this.resources.listTemplates().map((template) => ({
        uriTemplate: template.uriTemplate,
        name: template.name,
        description: template.description,
        mimeType: template.mimeType,
      })),
    };
  }

  private async onResourcesRead(params: unknown, ctx: DispatchContext): Promise<unknown> {
    const record = requireObjectParams('resources/read', params);
    const uri = requireString(record, 'uri', 'resources/read');
    try {
      const content = await this.resources.read(uri, {
        sessionId: ctx.sessionId,
        principal: ctx.principal,
      });
      this.auditResource(ctx, uri, 'success');
      return { contents: [content] };
    } catch (error) {
      const denied = error instanceof RpcError && error.code === RPC_ERROR_CODES.permissionDenied;
      this.auditResource(ctx, uri, denied ? 'denied' : 'error');
      throw error;
    }
  }

  private onResourcesSubscribe(params: unknown, ctx: DispatchContext): unknown {
    const record = requireObjectParams('resources/subscribe', params);
    const uri = requireString(record, 'uri', 'resources/subscribe');
    this.resources.subscribe(ctx.sessionId, uri);
    return {};
  }

  private onResourcesUnsubscribe(params: unknown, ctx: DispatchContext): unknown {
    const record = requireObjectParams('resources/unsubscribe', params);
    const uri = requireString(record, 'uri', 'resources/unsubscribe');
    this.resources.unsubscribe(ctx.sessionId, uri);
    return {};
  }

  private onPromptsList(params: unknown): unknown {
    requireObjectParams('prompts/list', params);
    return stripNullCursor(this.prompts.list());
  }

  private onPromptsGet(params: unknown): unknown {
    const record = requireObjectParams('prompts/get', params);
    const name = requireString(record, 'name', 'prompts/get');
    const rawArguments = record['arguments'];
    if (rawArguments !== undefined && rawArguments !== null && !isRecord(rawArguments)) {
      throw RpcError.invalidParams('Invalid params for prompts/get: "arguments" must be an object', {
        name,
      });
    }
    const args: Record<string, string> = {};
    for (const [key, value] of Object.entries(rawArguments ?? {})) {
      if (typeof value !== 'string') {
        throw RpcError.invalidParams(`Invalid params for prompts/get: argument "${key}" must be a string`, {
          name,
          argument: key,
        });
      }
      args[key] = value;
    }
    return this.prompts.get(name, args);
  }

  private onLoggingSetLevel(params: unknown, ctx: DispatchContext): unknown {
    const record = requireObjectParams('logging/setLevel', params);
    const level = record['level'];
    if (typeof level !== 'string' || !(LOGGING_LEVELS as readonly string[]).includes(level)) {
      throw RpcError.invalidParams('Invalid params for logging/setLevel: unknown level', {
        supported: [...LOGGING_LEVELS],
      });
    }
    const state = this.sessions.getOrCreate(ctx.sessionId);
    state.logLevel = level;
    this.sessions.touch(ctx.sessionId);
    return {};
  }

  private onCompletionComplete(params: unknown): unknown {
    requireObjectParams('completion/complete', params);
    // 当前工具/提示参数均为静态枚举，补全返回空集合（协议形状保持合法）。
    return { completion: { values: [], total: 0, hasMore: false } };
  }

  private onShutdown(ctx: DispatchContext): unknown {
    const state = this.sessions.get(ctx.sessionId);
    if (state) state.closed = true;
    this.logger.info('Session shutdown requested', { sessionId: ctx.sessionId, transport: ctx.transport });
    return {};
  }

  /* ---------------------------------------------------------------- */
  /* 通知处理（永不响应）                                                */
  /* ---------------------------------------------------------------- */

  private handleNotification(message: JsonRpcMessage, ctx: DispatchContext): void {
    if (!isNotification(message)) return;
    switch (message.method) {
      case 'notifications/initialized': {
        const state = this.sessions.getOrCreate(ctx.sessionId);
        state.meta.initialized = true;
        this.sessions.touch(ctx.sessionId);
        this.logger.info('Client initialised', {
          sessionId: ctx.sessionId,
          clientName: state.meta.clientInfo?.name ?? 'unknown',
        });
        return;
      }
      case 'notifications/cancelled':
        this.logger.debug('Client cancelled a request', { sessionId: ctx.sessionId });
        return;
      default:
        // 未知通知一律静默忽略（含 progress / roots 变更等）。
        this.logger.debug('Ignored notification', { method: message.method, sessionId: ctx.sessionId });
    }
  }

  /* ---------------------------------------------------------------- */
  /* 辅助                                                               */
  /* ---------------------------------------------------------------- */

  private checkRateLimit(ctx: DispatchContext): void {
    if (!this.rateLimiter) return;
    const key = ctx.principal?.rateLimitKey ?? `anon:${ctx.ip ?? ctx.sessionId}`;
    try {
      this.rateLimiter.check(key, ctx.principal?.rateLimit ?? undefined);
    } catch (error) {
      this.audit.record(
        buildAuditEntry({
          userId: ctx.principal?.userId ?? null,
          clientName: ctx.clientName ?? null,
          clientVersion: ctx.clientVersion ?? null,
          action: 'request.rate_limited',
          target: { type: 'mcp_request' },
          result: 'denied',
          transport: ctx.transport,
        }),
      );
      throw error;
    }
  }

  private auditResource(ctx: DispatchContext, uri: string, result: 'success' | 'denied' | 'error'): void {
    const init = {
      userId: ctx.principal?.userId ?? null,
      clientName: ctx.clientName ?? null,
      clientVersion: ctx.clientVersion ?? null,
      action: 'resource.read',
      target: { type: 'mcp_resource', id: uri },
      result,
      transport: ctx.transport,
      ...(ctx.ip !== undefined ? { ip: ctx.ip } : {}),
    } as const;
    this.audit.record(buildAuditEntry(init));
  }
}
