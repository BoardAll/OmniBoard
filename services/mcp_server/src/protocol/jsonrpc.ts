/**
 * JSON-RPC 2.0 编解码与标准错误码（《MCP_Server详细设计》§2/§15）。
 *
 * 自研实现（不依赖 @modelcontextprotocol/sdk）：SDK 仅被隔离用于
 * 可选的兼容性冒烟测试，协议正确性由本模块保证。
 *
 * 支持：请求 / 通知 / 响应 / 批量数组；错误码 -32700 ~ -32603（标准）
 * 与 -32000 ~ -32006（服务端扩展，见 §15）。
 */

export const JSONRPC_VERSION = '2.0' as const;

/** JSON-RPC 错误码（标准 + 服务端扩展，§15）。 */
export const RPC_ERROR_CODES = {
  parseError: -32700,
  invalidRequest: -32600,
  methodNotFound: -32601,
  invalidParams: -32602,
  internalError: -32603,
  serverError: -32000,
  rateLimited: -32001,
  permissionDenied: -32002,
  notFound: -32003,
  conflict: -32004,
  confirmationRequired: -32005,
  cancelled: -32006,
} as const;

export type RpcErrorCode = (typeof RPC_ERROR_CODES)[keyof typeof RPC_ERROR_CODES];

export interface JsonRpcRequest {
  jsonrpc: typeof JSONRPC_VERSION;
  id: string | number;
  method: string;
  params?: unknown;
}

export interface JsonRpcNotification {
  jsonrpc: typeof JSONRPC_VERSION;
  method: string;
  params?: unknown;
}

export interface JsonRpcSuccess {
  jsonrpc: typeof JSONRPC_VERSION;
  id: string | number;
  result: unknown;
}

export interface JsonRpcFailure {
  jsonrpc: typeof JSONRPC_VERSION;
  id: string | number | null;
  error: { code: number; message: string; data?: unknown };
}

export type JsonRpcResponse = JsonRpcSuccess | JsonRpcFailure;
export type JsonRpcMessage = JsonRpcRequest | JsonRpcNotification | JsonRpcResponse;

/** 协议层错误：由 dispatch 捕获并转换为 JSON-RPC 错误响应。 */
export class RpcError extends Error {
  readonly code: number;
  readonly data?: unknown;

  constructor(code: number, message: string, data?: unknown) {
    super(message);
    this.name = 'RpcError';
    this.code = code;
    this.data = data;
  }

  static invalidParams(message: string, data?: unknown): RpcError {
    return new RpcError(RPC_ERROR_CODES.invalidParams, message, data);
  }

  static methodNotFound(method: string): RpcError {
    return new RpcError(RPC_ERROR_CODES.methodNotFound, `Method not found: ${method}`, { method });
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function hasValidId(value: unknown): value is string | number {
  return typeof value === 'string' || (typeof value === 'number' && Number.isFinite(value));
}

/**
 * 解析单条消息（对象形态）。
 * - 非法 JSON 结构 → -32700 parseError（由调用方对 JSON.parse 失败抛出）
 * - 缺少 jsonrpc/method 或 id 类型非法 → -32600 invalidRequest
 */
export function parseMessage(raw: unknown): JsonRpcMessage {
  if (!isRecord(raw)) {
    throw new RpcError(RPC_ERROR_CODES.invalidRequest, 'Invalid Request: message must be an object');
  }
  if (raw['jsonrpc'] !== JSONRPC_VERSION) {
    throw new RpcError(RPC_ERROR_CODES.invalidRequest, 'Invalid Request: jsonrpc must be "2.0"');
  }

  // 响应（含 result 或 error）
  if ('result' in raw || 'error' in raw) {
    const id = raw['id'];
    if (id !== null && !hasValidId(id)) {
      throw new RpcError(RPC_ERROR_CODES.invalidRequest, 'Invalid Request: invalid response id');
    }
    if ('error' in raw) {
      const error = raw['error'];
      if (!isRecord(error) || typeof error['code'] !== 'number' || typeof error['message'] !== 'string') {
        throw new RpcError(RPC_ERROR_CODES.invalidRequest, 'Invalid Request: malformed error object');
      }
      return raw as unknown as JsonRpcFailure;
    }
    return raw as unknown as JsonRpcSuccess;
  }

  // 请求 / 通知
  const method = raw['method'];
  if (typeof method !== 'string' || method.length === 0) {
    throw new RpcError(RPC_ERROR_CODES.invalidRequest, 'Invalid Request: method must be a non-empty string');
  }
  if ('id' in raw) {
    const id = raw['id'];
    if (!hasValidId(id)) {
      throw new RpcError(RPC_ERROR_CODES.invalidRequest, 'Invalid Request: id must be a string or number');
    }
    const request: JsonRpcRequest = { jsonrpc: JSONRPC_VERSION, id, method };
    if ('params' in raw) request.params = raw['params'];
    return request;
  }
  const note: JsonRpcNotification = { jsonrpc: JSONRPC_VERSION, method };
  if ('params' in raw) note.params = raw['params'];
  return note;
}

export function isRequest(message: JsonRpcMessage): message is JsonRpcRequest {
  return 'method' in message && 'id' in message;
}

export function isNotification(message: JsonRpcMessage): message is JsonRpcNotification {
  return 'method' in message && !('id' in message);
}

export function isResponse(message: JsonRpcMessage): message is JsonRpcResponse {
  return !('method' in message);
}

export function success(id: string | number, result: unknown): JsonRpcSuccess {
  return { jsonrpc: JSONRPC_VERSION, id, result };
}

export function failure(
  id: string | number | null,
  code: number,
  message: string,
  data?: unknown,
): JsonRpcFailure {
  return {
    jsonrpc: JSONRPC_VERSION,
    id,
    error: { code, message, ...(data === undefined ? {} : { data }) },
  };
}

export function notification(method: string, params?: unknown): JsonRpcNotification {
  return { jsonrpc: JSONRPC_VERSION, method, ...(params === undefined ? {} : { params }) };
}

/** 便捷：把 RpcError / 未知异常转换为错误响应（不泄漏内部细节）。 */
export function toErrorResponse(id: string | number | null, error: unknown): JsonRpcFailure {
  if (error instanceof RpcError) {
    return failure(id, error.code, error.message, error.data);
  }
  return failure(id, RPC_ERROR_CODES.internalError, 'Internal error');
}
