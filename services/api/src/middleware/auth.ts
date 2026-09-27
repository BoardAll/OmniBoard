import type { NextFunction, Request, RequestHandler, Response } from 'express';
import jwt from 'jsonwebtoken';
import { ApiError } from '../lib/errors.js';
import { SCOPES, type Scope } from '../db/schema.js';
import { auditContext, summariseArgs } from './audit.js';

/**
 * Authentication & authorisation（《OpenAPI规范.md》§3、《安全与合规设计》§3-4）.
 *
 * 支持：
 *  - `Authorization: Bearer <jwt>`（内部服务 / OAuth 颁发的 JWT）
 *  - `X-API-Key: <key>`（服务端集成；亦接受 `Bearer wbp_...` 形式）
 *
 * 认证成功后挂载 `req.principal`；scope 校验由 `requireScope()` 逐路由执行。
 * 认证失败（`auth.failure`）与授权拒绝（`authz.denied`）写审计（§14.1），
 * 凭据绝不写入日志/审计（仅记录失败原因摘要）。
 */

export const KNOWN_SCOPES: readonly string[] = SCOPES;

export interface ApiKeyRecord {
  userId: string;
  scopes: Scope[];
  /** null = 不限白板范围 */
  boards: string[] | null;
  tenantId?: string;
  rateLimit?: number;
}

export interface AuthConfig {
  /** HS256 共享密钥（内部服务 / 测试）。生产使用 RS256 公钥。 */
  jwtSecret?: string;
  /** RS256 公钥（PEM）。提供时优先使用非对称校验。 */
  jwtPublicKey?: string;
  /** API Key → 主体映射。 */
  apiKeys?: Map<string, ApiKeyRecord>;
  /** 允许的签名算法，默认 ['HS256','RS256','ES256']。 */
  algorithms?: jwt.Algorithm[];
}

export interface AuthResult {
  userId: string;
  scopes: Scope[];
  boards: string[] | null;
  kind: 'jwt' | 'api-key';
  tenantId: string | null;
  rateLimit: number | null;
}

function normaliseScopes(raw: unknown): Scope[] {
  const collect = (values: unknown[]): string[] =>
    values.flatMap((v) => (typeof v === 'string' ? v.split(/\s+/).filter(Boolean) : []));
  let list: string[] = [];
  if (Array.isArray(raw)) list = collect(raw);
  else if (typeof raw === 'string') list = collect([raw]);
  return list.filter((s): s is Scope => KNOWN_SCOPES.includes(s));
}

function normaliseBoards(raw: unknown): string[] | null {
  if (!Array.isArray(raw)) return null;
  const boards = raw.filter((v): v is string => typeof v === 'string' && v.length > 0);
  return boards.length > 0 ? boards : null;
}

function buildPrincipal(decoded: jwt.JwtPayload, config: AuthConfig): AuthResult {
  const subject = decoded.sub ?? decoded.userId;
  if (typeof subject !== 'string' || subject.length === 0) {
    throw ApiError.unauthenticated('Token is missing the subject (sub) claim');
  }
  const scopes = normaliseScopes(decoded.scopes ?? decoded.scope);
  const boards = normaliseBoards(decoded.boards);
  return {
    userId: subject,
    scopes,
    boards,
    kind: 'jwt',
    tenantId: typeof decoded.tenantId === 'string' ? decoded.tenantId : null,
    rateLimit: typeof decoded.rateLimit === 'number' ? decoded.rateLimit : null,
  };
}

/** 解析凭据（不写日志、不回显原始 token）。 */
export function authenticateRequest(req: Request, config: AuthConfig): AuthResult {
  const apiKeyHeader = req.header('x-api-key');
  const authorization = req.header('authorization');
  const bearer = authorization?.match(/^Bearer\s+(.+)$/i)?.[1];

  const apiKey = apiKeyHeader ?? (bearer && !bearer.includes('.') ? bearer : undefined);
  if (apiKey) {
    const record = config.apiKeys?.get(apiKey.trim());
    if (!record) throw ApiError.unauthenticated('Invalid API key');
    return {
      userId: record.userId,
      scopes: [...record.scopes],
      boards: record.boards,
      kind: 'api-key',
      tenantId: record.tenantId ?? null,
      rateLimit: record.rateLimit ?? null,
    };
  }

  if (!bearer) {
    throw ApiError.unauthenticated('Missing credentials: Authorization Bearer or X-API-Key required');
  }
  if (!config.jwtSecret && !config.jwtPublicKey) {
    throw ApiError.unauthenticated('Token verification is not configured');
  }

  try {
    const key = config.jwtPublicKey ?? (config.jwtSecret as string);
    const algorithms: jwt.Algorithm[] = config.jwtPublicKey
      ? config.algorithms?.filter((a) => a !== 'HS256') ?? ['RS256', 'ES256']
      : config.algorithms ?? ['HS256'];
    const decoded = jwt.verify(bearer, key, { algorithms });
    if (typeof decoded === 'string') throw ApiError.unauthenticated('Malformed token payload');
    return buildPrincipal(decoded, config);
  } catch (error) {
    if (error instanceof jwt.TokenExpiredError) {
      throw ApiError.unauthenticated('Token expired', { expired: true });
    }
    if (error instanceof jwt.JsonWebTokenError) {
      throw ApiError.unauthenticated('Invalid token');
    }
    throw error;
  }
}

/** Express middleware: 认证（失败返回 401 UNAUTHENTICATED，并写 `auth.failure` 审计）。 */
export function authenticate(config: AuthConfig): RequestHandler {
  return (req: Request, res: Response, next: NextFunction) => {
    try {
      const principal = authenticateRequest(req, config);
      req.principal = principal;
      next();
    } catch (error) {
      // §14.1 认证失败审计：仅记录原因摘要，绝不记录凭据原文。
      const reason = error instanceof Error ? error.message : 'Authentication failed';
      const detail = error instanceof ApiError ? error.detail : undefined;
      const expired =
        typeof detail === 'object' && detail !== null && (detail as Record<string, unknown>)['expired'] === true;
      auditContext(res, {
        action: 'auth.failure',
        target: { type: 'auth', id: null },
        argsJson: summariseArgs(expired ? { reason, expired } : { reason }),
      });
      next(error);
    }
  };
}

/** Scope 校验（《OpenAPI规范.md》§5 各端点 Scope 列）。拒绝时写 `authz.denied` 审计（§14.1）。 */
export function requireScope(scope: Scope): RequestHandler {
  return (req: Request, res: Response, next: NextFunction) => {
    const principal = req.principal;
    if (!principal) {
      next(ApiError.unauthenticated());
      return;
    }
    if (!principal.scopes.includes(scope)) {
      auditContext(res, {
        action: 'authz.denied',
        target: { type: 'scope', id: scope },
        argsJson: summariseArgs({ scope, method: req.method, path: req.path }),
      });
      next(ApiError.permissionDenied(`No permission: scope ${scope} required`, { scope }));
      return;
    }
    next();
  };
}

export function hasScope(req: Request, scope: Scope): boolean {
  return req.principal?.scopes.includes(scope) ?? false;
}

/** 从环境变量加载认证配置（凭据只经环境变量注入，不落库、不入日志）。 */
export interface AuthEnvResult {
  config: AuthConfig;
  warnings: string[];
  errors: string[];
}

export function loadAuthConfigFromEnv(env: NodeJS.ProcessEnv = process.env): AuthEnvResult {
  const warnings: string[] = [];
  const errors: string[] = [];
  const config: AuthConfig = {};

  const secret = env['WB_JWT_SECRET'];
  const publicKey = env['WB_JWT_PUBLIC_KEY'];
  if (secret) config.jwtSecret = secret;
  if (publicKey) config.jwtPublicKey = publicKey.replace(/\\n/g, '\n');
  if (!secret && !publicKey) {
    if (env['NODE_ENV'] === 'production') {
      errors.push('WB_JWT_SECRET (or WB_JWT_PUBLIC_KEY) is required in production');
    } else {
      warnings.push('WB_JWT_SECRET not set: generating an ephemeral development secret (tokens are not stable across restarts)');
    }
  }

  const rawKeys = env['WB_API_KEYS'];
  const apiKeys = new Map<string, ApiKeyRecord>();
  if (rawKeys) {
    try {
      const parsed: unknown = JSON.parse(rawKeys);
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        throw new Error('WB_API_KEYS must be a JSON object');
      }
      for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
        if (typeof value !== 'object' || value === null) continue;
        const record = value as Record<string, unknown>;
        const userId = typeof record['userId'] === 'string' ? record['userId'] : null;
        if (!userId) continue;
        apiKeys.set(key, {
          userId,
          scopes: normaliseScopes(record['scopes']),
          boards: normaliseBoards(record['boards']),
          tenantId: typeof record['tenantId'] === 'string' ? record['tenantId'] : undefined,
          rateLimit: typeof record['rateLimit'] === 'number' ? record['rateLimit'] : undefined,
        });
      }
    } catch (error) {
      errors.push(`WB_API_KEYS is malformed: ${error instanceof Error ? error.message : 'parse error'}`);
    }
  }
  config.apiKeys = apiKeys;
  return { config, warnings, errors };
}
