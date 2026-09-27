/**
 * 认证装配入口（《MCP_Server详细设计》§9.1）：
 *
 * | 凭据                    | 通道        | 认证器                    |
 * |-------------------------|-------------|---------------------------|
 * | `X-API-Key`             | SSE / HTTP  | ApiKeyAuthenticator       |
 * | `Bearer wbp_...`（无点）| SSE / HTTP  | ApiKeyAuthenticator（与 services/api 行为一致） |
 * | `Bearer <JWT>`（三点）  | SSE / HTTP  | OAuthAuthenticator（JWT） |
 * | `WB_API_KEY` 环境变量   | stdio       | server.ts 本地信任模式     |
 * | `WB_MCP_API_KEY`        | stdio       | ApiKeyAuthenticator       |
 * | `--allow-anonymous`     | SSE / HTTP  | TrustedLocalAuthenticator（仅显式开启） |
 */

import { ApiKeyAuthenticator, loadApiKeysFromEnv } from './apiKey.js';
import { loadOAuthFromEnv, type OAuthAuthenticator } from './oauth.js';
import { AuthError, KNOWN_SCOPES, type Principal } from './types.js';

export { ApiKeyAuthenticator, loadApiKeysFromEnv, parseApiKeys, apiKeyLimitKey } from './apiKey.js';
export type { ApiKeyRecord } from './apiKey.js';
export { JwtVerifier, OAuthAuthenticator, loadOAuthFromEnv } from './oauth.js';
export type { JwtAlgorithm, JwtVerifierOptions, OAuthIntrospector } from './oauth.js';
export { RateLimiter, DEFAULT_RATE_LIMIT_PER_MINUTE } from './rateLimit.js';
export { AuthError, KNOWN_SCOPES, assertScope, hasScope } from './types.js';
export type { Principal, Scope } from './types.js';

export interface AuthCredentialInput {
  apiKey?: string | null;
  bearer?: string | null;
}

export interface CompositeAuthenticatorOptions {
  apiKeys?: ApiKeyAuthenticator;
  oauth?: OAuthAuthenticator;
}

/**
 * 组合认证器：按凭据形态路由到 API Key / OAuth(JWT)。
 * 无法认证时抛 `AuthError`（消息面向调用方，不含凭据）。
 */
export class CompositeAuthenticator {
  constructor(private readonly options: CompositeAuthenticatorOptions = {}) {}

  get configured(): boolean {
    return Boolean(this.options.apiKeys || this.options.oauth?.configured);
  }

  get apiKeyCount(): number {
    return this.options.apiKeys?.size ?? 0;
  }

  async authenticate(input: AuthCredentialInput): Promise<Principal> {
    const apiKey = input.apiKey?.trim();
    if (apiKey) {
      if (!this.options.apiKeys) throw new AuthError('API key authentication is not configured');
      return this.options.apiKeys.authenticate(apiKey);
    }

    const bearer = input.bearer?.trim();
    if (!bearer) {
      throw new AuthError('Missing credentials: Authorization Bearer or X-API-Key required');
    }

    const jwtLike = bearer.split('.').length === 3;
    if (!jwtLike && this.options.apiKeys) {
      try {
        return this.options.apiKeys.authenticate(bearer);
      } catch (error) {
        // 不是已知 API Key：若配置了 OAuth 则继续尝试，否则保留原始错误。
        if (!this.options.oauth?.configured) throw error;
      }
    }
    if (this.options.oauth?.configured) {
      return this.options.oauth.authenticate(bearer);
    }
    if (this.options.apiKeys) {
      return this.options.apiKeys.authenticate(bearer);
    }
    throw new AuthError('Token verification is not configured');
  }
}

export interface LoadAuthResult {
  authenticator: CompositeAuthenticator;
  warnings: string[];
  errors: string[];
}

/** 从环境变量装配认证链（WB_API_KEYS / WB_JWT_SECRET / WB_JWT_PUBLIC_KEY）。 */
export function loadAuthFromEnv(env: NodeJS.ProcessEnv = process.env): LoadAuthResult {
  const warnings: string[] = [];
  const errors: string[] = [];

  const { keys, errors: keyErrors } = loadApiKeysFromEnv(env);
  errors.push(...keyErrors);
  const apiKeys = keys.size > 0 ? new ApiKeyAuthenticator(keys) : undefined;

  const { authenticator: oauth, warnings: oauthWarnings, errors: oauthErrors } = loadOAuthFromEnv(env);
  warnings.push(...oauthWarnings);
  errors.push(...oauthErrors);

  if (keys.size === 0 && !oauth.configured) {
    warnings.push(
      'No credentials configured (WB_API_KEYS / WB_JWT_SECRET): HTTP transports will reject every request; stdio falls back to local trust',
    );
  }

  return {
    authenticator: new CompositeAuthenticator({ apiKeys, oauth }),
    warnings,
    errors,
  };
}

/* ------------------------------------------------------------------ */
/* 本地信任（stdio 免认证 / 显式匿名模式）                              */
/* ------------------------------------------------------------------ */

/**
 * 本地信任主体：全 Scope、不限白板。
 * 仅用于 stdio 本地进程或显式 `--allow-anonymous`（绝不用于默认 HTTP）。
 */
export function createLocalPrincipal(userId = 'local'): Principal {
  return {
    userId,
    scopes: [...KNOWN_SCOPES],
    boards: null,
    kind: 'local',
    tenantId: null,
    rateLimit: null,
    rateLimitKey: `local:${userId}`,
  };
}

/**
 * 免认证器：忽略凭据、始终返回固定本地主体。
 * 与 `CompositeAuthenticator` 同型（继承），可无缝用于 SSE / HTTP 中间件。
 */
export class TrustedLocalAuthenticator extends CompositeAuthenticator {
  constructor(private readonly principal: Principal = createLocalPrincipal()) {
    super();
  }

  override async authenticate(): Promise<Principal> {
    return this.principal;
  }
}
