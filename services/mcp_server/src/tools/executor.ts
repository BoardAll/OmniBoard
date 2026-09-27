/**
 * MCP 工具执行管线（《MCP_Server详细设计》§6.2 / §6.5 / §13.2）。
 *
 * 管线顺序：
 *   1. 查找工具（未知工具 → -32601；`confirm_operation` 为内建确认入口）
 *   2. inputSchema 校验（失败 → -32602，data.errors 列出问题）
 *   3. Scope 校验（缺失 → -32002，data 形状 `{ scope, toolId }`）
 *   4. 确认级别（§6.5，与 services/api 桥接目录保持一致）：
 *        - auto    → 直接执行
 *        - preview → 首次调用返回预览结果（requiresConfirmation: true + confirmationId），
 *                    带确认参数二次调用执行
 *        - confirm → 首次调用返回 -32005 confirmationRequired（携带 confirmationId），
 *                    二次调用带 `_meta.confirmationId`（或 `_meta.confirm: true`）执行
 *   5. 执行（`ToolInvoker` 抽象：测试注入 fake；默认转发 services/api 桥接）
 *
 * 确认参数（二选一）：
 *   - `params._meta.confirmationId`：使用首次响应返回的 confirmationId（推荐）
 *   - `params._meta.confirm: true`：显式确认标记（对齐 services/api `confirm: true`）
 *   - 调用内建工具 `confirm_operation { confirmationId, approved }`（§6.5 流程）
 *
 * 审计（§10）：
 * - scope 拒绝、确认批准/拒绝、执行结果均入账；
 * - 仅保留 {时间、用户、动作、目标、结果} 与客户端标识，不含参数原文。
 */

import { randomUUID } from 'node:crypto';
import { RpcError, RPC_ERROR_CODES } from '../protocol/jsonrpc.js';
import { findTool, type ConfirmationLevel, type ToolDefinition } from './registry.js';
import { validateAgainstSchema } from './jsonschema.js';
import { assertScope, type Principal } from '../auth/types.js';
import { buildAuditEntry, NULL_AUDIT_SINK, type AuditSink } from '../audit.js';
import { NULL_LOGGER, type Logger } from '../log.js';

/** MCP tools/call 结果（§6.2 响应形状）。 */
export interface McpToolResult {
  content: Array<{ type: 'text'; text: string }>;
  isError: boolean;
  structuredContent: Record<string, unknown>;
}

export interface ToolInvocationContext {
  sessionId: string;
  principal: Principal | null;
  /** preview：仅计算预览，不产生副作用（由执行器实现方保证）。 */
  mode: 'execute' | 'preview';
}

/** 工具调用后端抽象：返回 structuredContent 形状（或直通 MCP 形状）。 */
export type ToolInvoker = (
  tool: ToolDefinition,
  args: Record<string, unknown>,
  ctx: ToolInvocationContext,
) => Promise<Record<string, unknown>>;

export interface ToolCallContext {
  sessionId: string;
  principal: Principal | null;
  transport: 'stdio' | 'sse' | 'http';
  clientName?: string | null;
  clientVersion?: string | null;
  ip?: string;
}

export interface ToolCallParams {
  name: string;
  arguments: Record<string, unknown>;
  /** tools/call params 中的 `_meta`（确认参数等）。 */
  meta?: Record<string, unknown>;
}

export type ToolExecutionErrorCode =
  | 'notFound'
  | 'conflict'
  | 'permissionDenied'
  | 'invalidParams'
  | 'rateLimited'
  | 'cancelled'
  | 'serverError'
  | 'unavailable';

const TOOL_ERROR_TO_RPC: Record<ToolExecutionErrorCode, number> = {
  notFound: RPC_ERROR_CODES.notFound,
  conflict: RPC_ERROR_CODES.conflict,
  permissionDenied: RPC_ERROR_CODES.permissionDenied,
  invalidParams: RPC_ERROR_CODES.invalidParams,
  rateLimited: RPC_ERROR_CODES.rateLimited,
  cancelled: RPC_ERROR_CODES.cancelled,
  serverError: RPC_ERROR_CODES.serverError,
  unavailable: RPC_ERROR_CODES.serverError,
};

/** 后端执行错误（由 ToolInvoker 实现抛出，executor 映射为 JSON-RPC 错误码）。 */
export class ToolExecutionError extends Error {
  readonly code: ToolExecutionErrorCode;
  readonly detail?: unknown;

  constructor(code: ToolExecutionErrorCode, message: string, detail?: unknown) {
    super(message);
    this.name = 'ToolExecutionError';
    this.code = code;
    this.detail = detail;
  }
}

interface PendingConfirmation {
  id: string;
  toolName: string;
  internalToolId: string;
  args: Record<string, unknown>;
  level: 'preview' | 'confirm';
  sessionId: string;
  createdAt: number;
  expiresAt: number;
}

export interface ToolExecutorDeps {
  invoke: ToolInvoker;
  audit?: AuditSink;
  logger?: Logger;
  /** 确认请求有效期（毫秒），默认 10 分钟。 */
  confirmationTtlMs?: number;
  /** 可注入时钟（测试用）。 */
  now?: () => number;
}

const DEFAULT_CONFIRMATION_TTL_MS = 10 * 60 * 1000;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** 后端返回归一化：已是 MCP 形状（content/isError/structuredContent）则直通。 */
export function normaliseToolResult(tool: ToolDefinition, raw: Record<string, unknown>): McpToolResult {
  const content = raw['content'];
  const isError = raw['isError'];
  const structured = raw['structuredContent'];
  if (Array.isArray(content) && typeof isError === 'boolean' && isRecord(structured)) {
    return {
      content: content as McpToolResult['content'],
      isError,
      structuredContent: structured,
    };
  }
  const message = raw['message'];
  const text = typeof message === 'string' && message.length > 0 ? message : `${tool.internalToolId} 执行成功`;
  return { content: [{ type: 'text', text }], isError: false, structuredContent: raw };
}

export class ToolExecutor {
  private readonly confirmations = new Map<string, PendingConfirmation>();
  private readonly audit: AuditSink;
  private readonly logger: Logger;
  private readonly ttlMs: number;
  private readonly now: () => number;

  constructor(private readonly deps: ToolExecutorDeps) {
    this.audit = deps.audit ?? NULL_AUDIT_SINK;
    this.logger = deps.logger ?? NULL_LOGGER;
    this.ttlMs = deps.confirmationTtlMs ?? DEFAULT_CONFIRMATION_TTL_MS;
    this.now = deps.now ?? Date.now;
  }

  get pendingConfirmations(): number {
    return this.confirmations.size;
  }

  async callTool(params: ToolCallParams, ctx: ToolCallContext): Promise<McpToolResult> {
    const name = params.name;
    if (name === 'confirm_operation' || name === 'confirm.operation') {
      return this.resolveConfirmOperation(params.arguments, ctx);
    }

    const tool = findTool(name);
    if (!tool) {
      throw new RpcError(RPC_ERROR_CODES.methodNotFound, `Unknown tool: ${name}`, { tool: name });
    }
    const args = this.validateArguments(tool, params.arguments);

    try {
      assertScope(ctx.principal, tool.scope, tool.internalToolId);
    } catch (error) {
      this.auditCall(ctx, tool, 'denied', args);
      throw error;
    }

    const approval = this.checkApproval(tool, params.meta, args, ctx.sessionId);
    if (tool.confirmation === 'auto' || approval.state === 'approved') {
      if (approval.state === 'approved' && approval.pending) {
        // 通过存储的 confirmationId 批准：记录确认操作后执行。
        this.auditConfirm(ctx, approval.pending, 'success');
      }
      return this.execute(tool, args, ctx);
    }

    const pending = this.createConfirmation(tool, args, ctx.sessionId, tool.confirmation);
    if (tool.confirmation === 'confirm') {
      this.auditCall(ctx, tool, 'denied', args);
      const data: Record<string, unknown> = {
        toolId: tool.internalToolId,
        confirmation: 'confirm',
        confirmationId: pending.id,
        arguments: args,
        hint: 'Call tools/call again with _meta.confirmationId (or _meta.confirm: true), or use confirm_operation with approved=true.',
      };
      if (approval.state === 'stale') data['reason'] = approval.reason;
      throw new RpcError(RPC_ERROR_CODES.confirmationRequired, `Tool ${tool.name} requires confirmation`, data);
    }

    // preview：首次调用返回预览，等待客户端确认后执行（§6.5）。
    const preview = await this.invokePreview(tool, args, ctx);
    this.auditCall(ctx, tool, 'denied', args);
    const structured: Record<string, unknown> = {
      requiresConfirmation: true,
      confirmation: 'preview',
      confirmationId: pending.id,
      toolId: tool.internalToolId,
      preview,
    };
    if (approval.state === 'stale') structured['reason'] = approval.reason;
    return {
      content: [{ type: 'text', text: `此操作需要确认：${tool.description}` }],
      isError: false,
      structuredContent: structured,
    };
  }

  /* ---------------------------------------------------------------- */
  /* 内部步骤                                                           */
  /* ---------------------------------------------------------------- */

  private validateArguments(tool: ToolDefinition, args: unknown): Record<string, unknown> {
    if (!isRecord(args)) {
      throw RpcError.invalidParams(`Invalid arguments for ${tool.name}: arguments must be an object`, {
        toolId: tool.internalToolId,
      });
    }
    const issues = validateAgainstSchema(tool.inputSchema, args);
    if (issues.length > 0) {
      throw new RpcError(RPC_ERROR_CODES.invalidParams, `Invalid arguments for ${tool.name}`, {
        toolId: tool.internalToolId,
        errors: issues,
      });
    }
    return args;
  }

  private checkApproval(
    tool: ToolDefinition,
    meta: Record<string, unknown> | undefined,
    args: Record<string, unknown>,
    sessionId: string,
  ):
    | { state: 'approved'; pending: PendingConfirmation | null }
    | { state: 'none' }
    | { state: 'stale'; reason: string } {
    if (meta?.['confirm'] === true) return { state: 'approved', pending: null };

    const rawId = meta?.['confirmationId'];
    if (typeof rawId === 'string' && rawId.length > 0) {
      const pending = this.confirmations.get(rawId);
      if (!pending) {
        return { state: 'stale', reason: 'confirmationId is unknown or was already used' };
      }
      if (pending.expiresAt <= this.now()) {
        this.confirmations.delete(rawId);
        return { state: 'stale', reason: 'confirmationId has expired' };
      }
      if (pending.toolName !== tool.name || pending.sessionId !== sessionId) {
        throw RpcError.invalidParams('confirmationId does not match this tool call', {
          toolId: tool.internalToolId,
        });
      }
      this.confirmations.delete(rawId);
      return { state: 'approved', pending };
    }

    // 工具自身 schema 声明了 `confirm` 参数（如 element_batch）：args.confirm === true 视为确认。
    const properties = tool.inputSchema['properties'];
    const declaresConfirm = isRecord(properties) && 'confirm' in properties;
    if (declaresConfirm && args['confirm'] === true) return { state: 'approved', pending: null };

    return { state: 'none' };
  }

  private async resolveConfirmOperation(args: Record<string, unknown>, ctx: ToolCallContext): Promise<McpToolResult> {
    const confirmationId = args['confirmationId'];
    if (typeof confirmationId !== 'string' || confirmationId.length === 0) {
      throw RpcError.invalidParams('confirm_operation requires confirmationId');
    }
    const approved = args['approved'];
    if (typeof approved !== 'boolean') {
      throw RpcError.invalidParams('confirm_operation requires approved (boolean)');
    }

    const pending = this.confirmations.get(confirmationId);
    if (!pending) {
      throw new RpcError(RPC_ERROR_CODES.notFound, 'Unknown or expired confirmationId', { confirmationId });
    }
    if (pending.expiresAt <= this.now()) {
      this.confirmations.delete(confirmationId);
      throw new RpcError(RPC_ERROR_CODES.notFound, 'Confirmation has expired', { confirmationId });
    }
    if (pending.sessionId !== ctx.sessionId) {
      throw RpcError.invalidParams('confirmationId does not match this session', { confirmationId });
    }

    this.confirmations.delete(confirmationId);
    if (!approved) {
      this.auditConfirm(ctx, pending, 'denied');
      throw new RpcError(RPC_ERROR_CODES.cancelled, 'Operation cancelled by user', {
        toolId: pending.internalToolId,
        confirmationId,
      });
    }

    const tool = findTool(pending.toolName);
    if (!tool) {
      throw new RpcError(RPC_ERROR_CODES.internalError, 'Confirmed tool is no longer registered', {
        toolId: pending.internalToolId,
      });
    }
    // 二次执行前重新校验 Scope（防御主体变更）；不足则记录 denied 并拒绝。
    try {
      assertScope(ctx.principal, tool.scope, tool.internalToolId);
    } catch (error) {
      this.auditConfirm(ctx, pending, 'denied');
      throw error;
    }
    // 先写确认成功审计，再执行（tool.call 审计保持在其后，便于按序回溯）。
    this.auditConfirm(ctx, pending, 'success');
    return this.execute(tool, pending.args, ctx);
  }

  private createConfirmation(
    tool: ToolDefinition,
    args: Record<string, unknown>,
    sessionId: string,
    level: ConfirmationLevel,
  ): PendingConfirmation {
    this.pruneExpired();
    const nowMs = this.now();
    const pending: PendingConfirmation = {
      id: `conf_${randomUUID().replace(/-/g, '').slice(0, 16)}`,
      toolName: tool.name,
      internalToolId: tool.internalToolId,
      args: { ...args },
      level: level === 'preview' ? 'preview' : 'confirm',
      sessionId,
      createdAt: nowMs,
      expiresAt: nowMs + this.ttlMs,
    };
    this.confirmations.set(pending.id, pending);
    return pending;
  }

  private pruneExpired(): void {
    const nowMs = this.now();
    for (const [id, pending] of this.confirmations) {
      if (pending.expiresAt <= nowMs) this.confirmations.delete(id);
    }
  }

  private async invokePreview(
    tool: ToolDefinition,
    args: Record<string, unknown>,
    ctx: ToolCallContext,
  ): Promise<Record<string, unknown>> {
    try {
      return await this.deps.invoke(tool, args, {
        sessionId: ctx.sessionId,
        principal: ctx.principal,
        mode: 'preview',
      });
    } catch (error) {
      throw this.normaliseInvokeError(error, tool);
    }
  }

  private async execute(tool: ToolDefinition, args: Record<string, unknown>, ctx: ToolCallContext): Promise<McpToolResult> {
    try {
      const raw = await this.deps.invoke(tool, args, {
        sessionId: ctx.sessionId,
        principal: ctx.principal,
        mode: 'execute',
      });
      const result = normaliseToolResult(tool, raw);
      this.auditCall(ctx, tool, result.isError ? 'error' : 'success', args);
      return result;
    } catch (error) {
      const normalised = this.normaliseInvokeError(error, tool);
      this.auditCall(
        ctx,
        tool,
        error instanceof RpcError && error.code === RPC_ERROR_CODES.permissionDenied ? 'denied' : 'error',
        args,
      );
      throw normalised;
    }
  }

  private normaliseInvokeError(error: unknown, tool: ToolDefinition): RpcError {
    if (error instanceof RpcError) return error;
    if (error instanceof ToolExecutionError) {
      const data: Record<string, unknown> = { toolId: tool.internalToolId };
      if (error.detail !== undefined) data['detail'] = error.detail;
      return new RpcError(TOOL_ERROR_TO_RPC[error.code], error.message, data);
    }
    this.logger.error('Tool invocation failed unexpectedly', {
      toolId: tool.internalToolId,
      message: error instanceof Error ? error.message : 'unknown error',
    });
    return new RpcError(RPC_ERROR_CODES.serverError, 'Tool execution failed', { toolId: tool.internalToolId });
  }

  private auditCall(
    ctx: ToolCallContext,
    tool: ToolDefinition,
    result: 'success' | 'denied' | 'error',
    args: Record<string, unknown>,
  ): void {
    const boardId = typeof args['boardId'] === 'string' ? args['boardId'] : undefined;
    const entry = buildAuditEntry({
      userId: ctx.principal?.userId ?? null,
      clientName: ctx.clientName ?? null,
      clientVersion: ctx.clientVersion ?? null,
      action: 'tool.call',
      target: { type: 'mcp_tool', id: tool.name },
      result,
      transport: ctx.transport,
    });
    if (boardId !== undefined) entry.boardId = boardId;
    if (ctx.ip !== undefined) entry.ip = ctx.ip;
    this.audit.record(entry);
  }

  /** 确认操作审计（§10「确认操作」）：批准 / 拒绝均入账；不记录参数原文。 */
  private auditConfirm(ctx: ToolCallContext, pending: PendingConfirmation, result: 'success' | 'denied'): void {
    const entry = buildAuditEntry({
      userId: ctx.principal?.userId ?? null,
      clientName: ctx.clientName ?? null,
      clientVersion: ctx.clientVersion ?? null,
      action: 'tool.confirm',
      target: { type: 'mcp_tool', id: pending.toolName },
      result,
      transport: ctx.transport,
    });
    if (ctx.ip !== undefined) entry.ip = ctx.ip;
    this.audit.record(entry);
  }
}
