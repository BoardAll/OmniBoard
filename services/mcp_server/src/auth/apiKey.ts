/**
 * API Key 认证（《MCP_Server详细设计》§9.1 / §9.2）。
 *
 * - HTTP / SSE：`X-API-Key: <key>` 或 `Authorization: Bearer wbp_xxx`；
 * - stdio：经环境变量 `WB_API_KEY` 注入（见 server.ts 的本地信任模式）；
 * - Key → 主体映射与 services/api `loadAuthConfigFromEnv` 的 `WB_API_KEYS`
 *   JSON 形状保持一致：`{ "<key>": { userId, scopes, boards, tenantId, rateLimit } }`。
 *
 * 安全：凭据不落日志；速率限制键使用 key 的 SHA-256 摘要前缀，不保存原文。
 */

import { createHash } from 'node:crypto';
import { AuthError, normaliseBoards, normaliseScopes, type Principal } from './types.js';

export interface ApiKeyRecord {
  userId: string;
  scopes: string[];
  /** null = 不限白板范围。 */
  boards: string[] | null;
  tenantId?: string;
  /** 每分钟请求上限。 */
  rateLimit?: number;
  /** 可读名（仅用于运维展示，不参与鉴权）。 */
  name?: string;
}

/** 速率限制键：只输出摘要前缀，避免在内存索引 / 日志中暴露原始 Key。 */
export function apiKeyLimitKey(apiKey: string): string {
  const digest = createHash('sha256').update(apiKey).digest('hex');
  return `apikey:${digest.slice(0, 16)}`;
}

/** 解析 `WB_API_KEYS` JSON（形状与 services/api 相同）。 */
export function parseApiKeys(raw: string): { keys: Map<string, ApiKeyRecord>; errors: string[] } {
  const keys = new Map<string, ApiKeyRecord>();
  const errors: string[] = [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    errors.push(`WB_API_KEYS is not valid JSON: ${error instanceof Error ? error.message : 'parse error'}`);
    return { keys, errors };
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    errors.push('WB_API_KEYS must be a JSON object keyed by API key');
    return { keys, errors };
  }
  for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
    if (key.trim().length === 0) {
      errors.push('WB_API_KEYS contains an empty API key');
      continue;
    }
    if (typeof value !== 'object' || value === null || Array.isArray(value)) {
      errors.push(`WB_API_KEYS entry "${key.slice(0, 8)}…" must be an object`);
      continue;
    }
    const record = value as Record<string, unknown>;
    const userId = typeof record['userId'] === 'string' ? record['userId'] : null;
    if (!userId) {
      errors.push(`WB_API_KEYS entry "${key.slice(0, 8)}…" is missing userId`);
      continue;
    }
    const parsedRecord: ApiKeyRecord = {
      userId,
      scopes: normaliseScopes(record['scopes']),
      boards: normaliseBoards(record['boards']),
    };
    if (typeof record['tenantId'] === 'string') parsedRecord.tenantId = record['tenantId'];
    if (typeof record['rateLimit'] === 'number' && Number.isFinite(record['rateLimit'])) {
      parsedRecord.rateLimit = record['rateLimit'];
    }
    if (typeof record['name'] === 'string') parsedRecord.name = record['name'];
    keys.set(key, parsedRecord);
  }
  return { keys, errors };
}

export interface LoadApiKeysResult {
  keys: Map<string, ApiKeyRecord>;
  warnings: string[];
  errors: string[];
}

export function loadApiKeysFromEnv(env: NodeJS.ProcessEnv = process.env): LoadApiKeysResult {
  const raw = env['WB_API_KEYS'];
  if (!raw || raw.trim().length === 0) {
    return { keys: new Map(), warnings: [], errors: [] };
  }
  const { keys, errors } = parseApiKeys(raw);
  return { keys, warnings: [], errors };
}

/** API Key 认证器：key → Principal。 */
export class ApiKeyAuthenticator {
  constructor(private readonly keys: Map<string, ApiKeyRecord>) {}

  get size(): number {
    return this.keys.size;
  }

  /** 校验 API Key；失败统一抛 `AuthError('Invalid API key')`（不区分原因）。 */
  authenticate(apiKey: string): Principal {
    const trimmed = apiKey.trim();
    const record = this.keys.get(trimmed);
    if (!record) throw new AuthError('Invalid API key');
    return {
      userId: record.userId,
      scopes: [...record.scopes],
      boards: record.boards,
      kind: 'api-key',
      tenantId: record.tenantId ?? null,
      rateLimit: record.rateLimit ?? null,
      rateLimitKey: apiKeyLimitKey(trimmed),
    };
  }
}
