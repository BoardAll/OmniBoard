/**
 * 认证 / 授权的公共类型（《MCP_Server详细设计》§9）。
 *
 * - `Principal`：一次认证后的调用主体（用户、Scope、白板范围、速率限制）；
 * - `AuthError`：认证失败（由传输层转换为 HTTP 401 / 启动错误）；
 * - `assertScope`：工具级 Scope 校验（§9.4），失败抛 JSON-RPC -32002。
 */

import { RpcError, RPC_ERROR_CODES } from '../protocol/jsonrpc.js';

/**
 * 已知 Scope 清单（与 services/api `src/db/schema.ts` 的 SCOPES 逐项一致，
 * 与 Open API / C++ ToolRegistry 共用同一套权限体系）。
 */
export const KNOWN_SCOPES = [
  'board:read',
  'board:write',
  'board:share',
  'page:read',
  'page:write',
  'element:read',
  'element:write',
  'connector:read',
  'connector:write',
  'comment:read',
  'comment:write',
  'export:read',
  'history:read',
  'history:write',
  'ai:invoke',
  'mcp:invoke',
  'admin:read',
  'admin:write',
] as const;

export type Scope = (typeof KNOWN_SCOPES)[number];

export interface Principal {
  userId: string;
  scopes: readonly string[];
  /** null = 不限白板范围（§9.5）。 */
  boards: readonly string[] | null;
  kind: 'api-key' | 'jwt' | 'oauth' | 'local';
  tenantId: string | null;
  /** 每分钟请求上限（null = 使用服务端默认值）。 */
  rateLimit: number | null;
  /** 速率限制键：不含原始凭据（apiKey 走哈希、JWT 走 sub）。 */
  rateLimitKey: string;
}

/** 认证失败（不是权限不足；权限不足是 RpcError -32002）。 */
export class AuthError extends Error {
  readonly detail?: unknown;

  constructor(message: string, detail?: unknown) {
    super(message);
    this.name = 'AuthError';
    this.detail = detail;
  }
}

export function hasScope(principal: Principal | null | undefined, scope: string): boolean {
  return principal != null && principal.scopes.includes(scope);
}

/**
 * Scope 校验（§9.4）：主体缺少工具所需 Scope 时抛 -32002，
 * data 形状与设计文档 §15 示例一致（`{ scope, toolId }`）。
 */
export function assertScope(principal: Principal | null | undefined, scope: string, toolId: string): void {
  if (!hasScope(principal, scope)) {
    throw new RpcError(RPC_ERROR_CODES.permissionDenied, `No permission: scope ${scope} required`, {
      scope,
      toolId,
    });
  }
}

/** 归一化 scopes（数组或空格分隔字符串），并过滤未知 Scope（与 services/api 一致）。 */
export function normaliseScopes(raw: unknown): string[] {
  const collect = (values: readonly unknown[]): string[] =>
    values.flatMap((value) => (typeof value === 'string' ? value.split(/\s+/).filter(Boolean) : []));
  let list: string[] = [];
  if (Array.isArray(raw)) list = collect(raw);
  else if (typeof raw === 'string') list = collect([raw]);
  return list.filter((scope): scope is Scope => (KNOWN_SCOPES as readonly string[]).includes(scope));
}

/** 归一化白板范围：非空数组 → 列表；否则 null（不限）。 */
export function normaliseBoards(raw: unknown): string[] | null {
  if (!Array.isArray(raw)) return null;
  const boards = raw.filter((value): value is string => typeof value === 'string' && value.length > 0);
  return boards.length > 0 ? boards : null;
}
