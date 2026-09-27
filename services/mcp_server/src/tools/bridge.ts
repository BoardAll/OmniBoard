/**
 * 工具执行后端（默认实现）：转发到 services/api 的 MCP 桥接
 * （`POST {WB_API_BASE_URL}/v1/mcp/tools/{toolName}/call`，见 services/api/src/routes/mcp.ts）。
 *
 * - 桥接使用服务自身凭据（`WB_API_KEY`），不复用外部客户端 token；
 * - 后端返回的 MCP 形状（content/isError/structuredContent）直通；
 * - 后端错误码映射为 `ToolExecutionError`（executor 再映射为 JSON-RPC 错误码）；
 * - 未配置 `WB_API_BASE_URL` 时使用 `UnavailableToolInvoker`，调用返回 -32000 并提示配置。
 */

import type { ToolDefinition } from './registry.js';
import { ToolExecutionError, type ToolInvoker } from './executor.js';

export interface ApiBridgeOptions {
  baseUrl: string;
  apiKey?: string | null;
  /** 测试注入的 fetch 实现。 */
  fetchImpl?: typeof fetch;
  /** 请求超时（毫秒），默认 30s。 */
  timeoutMs?: number;
}

const API_CODE_TO_TOOL_ERROR: Record<string, ToolExecutionError['code']> = {
  INVALID_ARGUMENT: 'invalidParams',
  UNAUTHENTICATED: 'serverError',
  PERMISSION_DENIED: 'permissionDenied',
  NOT_FOUND: 'notFound',
  CONFLICT: 'conflict',
  RATE_LIMITED: 'rateLimited',
  RESOURCE_EXHAUSTED: 'rateLimited',
  CANCELLED: 'cancelled',
  UNAVAILABLE: 'serverError',
  NOT_SUPPORTED: 'serverError',
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export function createApiBridgeInvoker(options: ApiBridgeOptions): ToolInvoker {
  const fetchImpl = options.fetchImpl ?? fetch;
  const baseUrl = options.baseUrl.replace(/\/+$/, '');

  return async (tool, args, ctx) => {
    const url = `${baseUrl}/v1/mcp/tools/${encodeURIComponent(tool.name)}/call`;
    const headers: Record<string, string> = {
      'content-type': 'application/json',
      accept: 'application/json',
    };
    if (options.apiKey) headers['authorization'] = `Bearer ${options.apiKey}`;

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? 30_000);
    let response: Response;
    try {
      response = await fetchImpl(url, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          arguments: args,
          // execute：MCP 侧已完成确认流程 → 后端按已确认执行；
          // preview：先探测后端的预览/确认要求，不产生副作用。
          confirm: ctx.mode === 'execute',
        }),
        signal: controller.signal,
      });
    } catch (error) {
      throw new ToolExecutionError(
        'serverError',
        `API bridge request failed: ${error instanceof Error ? error.message : 'network error'}`,
        { toolId: tool.internalToolId },
      );
    } finally {
      clearTimeout(timer);
    }

    let payload: unknown;
    try {
      payload = await response.json();
    } catch {
      throw new ToolExecutionError('serverError', 'API bridge returned a non-JSON response', {
        toolId: tool.internalToolId,
        status: response.status,
      });
    }

    const envelope = isRecord(payload) ? payload : {};
    if (!response.ok || envelope['ok'] !== true) {
      const error = isRecord(envelope['error']) ? envelope['error'] : {};
      const apiCode = typeof error['code'] === 'string' ? error['code'] : '';
      const message = typeof error['message'] === 'string' ? error['message'] : `API bridge error (HTTP ${response.status})`;

      // 预览模式：后端要求确认 → 作为预览数据返回（不视为错误）。
      const detail = error['detail'];
      if (ctx.mode === 'preview' && response.status === 422 && isRecord(detail) && detail['confirmationRequired'] === true) {
        return {
          confirmationRequired: true,
          toolId: tool.internalToolId,
          arguments: args,
          note: 'Backend requires user approval before execution.',
        };
      }
      throw new ToolExecutionError(API_CODE_TO_TOOL_ERROR[apiCode] ?? 'serverError', message, {
        toolId: tool.internalToolId,
        status: response.status,
      });
    }

    const data = envelope['data'];
    if (isRecord(data)) {
      // services/api 返回的 McpToolResult（content/isError/structuredContent）直通。
      if (Array.isArray(data['content']) && typeof data['isError'] === 'boolean' && isRecord(data['structuredContent'])) {
        return data;
      }
      return { result: data };
    }
    return { result: data ?? null };
  };
}

/** 未配置后端时的默认执行器：显式报错（-32000），不伪造结果。 */
export function createUnavailableInvoker(reason: string): ToolInvoker {
  return async (tool: ToolDefinition): Promise<Record<string, unknown>> => {
    throw new ToolExecutionError('serverError', reason, { toolId: tool.internalToolId });
  };
}

export interface DefaultInvokerOptions {
  apiBaseUrl?: string | null;
  apiKey?: string | null;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}

/** 默认执行器：配置了 `WB_API_BASE_URL` → services/api 桥接；否则显式不可用。 */
export function createDefaultInvoker(options: DefaultInvokerOptions = {}): ToolInvoker {
  const baseUrl = options.apiBaseUrl?.trim();
  if (baseUrl && baseUrl.length > 0) {
    const bridge: ApiBridgeOptions = { baseUrl };
    if (options.apiKey) bridge.apiKey = options.apiKey;
    if (options.fetchImpl) bridge.fetchImpl = options.fetchImpl;
    if (options.timeoutMs !== undefined) bridge.timeoutMs = options.timeoutMs;
    return createApiBridgeInvoker(bridge);
  }
  return createUnavailableInvoker(
    'Tool execution backend is not configured: set WB_API_BASE_URL to bridge to the Whiteboard API, or inject a ToolInvoker.',
  );
}
