/**
 * OAuth 2.0 / JWT 认证（《MCP_Server详细设计》§9.1 / §9.3）。
 *
 * - SSE / HTTP：`Authorization: Bearer <token>`；
 * - JWT（HS256 / RS256 / ES256）使用 Node `crypto` 校验签名，不引入额外依赖；
 * - 不透明 OAuth access token 通过注入的 `OAuthIntrospector`（内省端点）校验，
 *   未配置内省端点时明确拒绝（不做猜测性放行）。
 *
 * 安全（《安全与合规设计》§3 / §10）：
 * - token 长度上限（`MAX_TOKEN_LENGTH`）防解析型 DoS；
 * - 可选强校验 `iss` / `aud`（`WB_JWT_ISSUER` / `WB_JWT_AUDIENCE`）；
 * - `exp` / `nbf` 存在但类型非法 → 直接拒绝；
 * - 只透出必要声明；不记录 token 原文。
 */

import { createHmac, createPublicKey, timingSafeEqual, verify as cryptoVerify } from 'node:crypto';
import { AuthError, normaliseBoards, normaliseScopes, type Principal } from './types.js';

export type JwtAlgorithm = 'HS256' | 'RS256' | 'ES256';

/** token 长度上限（字符）；超长直接拒绝，避免无界解析开销。 */
export const MAX_TOKEN_LENGTH = 8192;

export interface JwtVerifierOptions {
  /** HS256 共享密钥。 */
  secret?: string;
  /** RS256 / ES256 公钥（PEM）。 */
  publicKey?: string;
  /** 允许的算法（缺省：secret → HS256；publicKey → RS256/ES256；两者皆有 → 全部）。 */
  algorithms?: readonly JwtAlgorithm[];
  /** 时钟容差（秒），默认 30。 */
  clockToleranceSec?: number;
  /** 强校验签发者（配置后 `iss` 必须匹配）。 */
  issuer?: string;
  /** 强校验受众（配置后 `aud` 任一命中即可）。 */
  audience?: string | readonly string[];
  /** 可注入时钟（测试用）。 */
  now?: () => number;
}

interface JwtHeader {
  alg?: unknown;
  typ?: unknown;
}

interface JwtClaims {
  sub?: unknown;
  userId?: unknown;
  scopes?: unknown;
  scope?: unknown;
  boards?: unknown;
  tenantId?: unknown;
  rateLimit?: unknown;
  iss?: unknown;
  aud?: unknown;
  exp?: unknown;
  nbf?: unknown;
}

function base64UrlDecode(input: string): Buffer {
  const normalised = input.replace(/-/g, '+').replace(/_/g, '/');
  const padLength = (4 - (normalised.length % 4)) % 4;
  return Buffer.from(normalised + '='.repeat(padLength), 'base64');
}

function looksLikeJwt(token: string): boolean {
  const parts = token.split('.');
  return parts.length === 3 && parts.every((part) => part.length > 0);
}

/** HS256 / RS256 / ES256 JWT 校验器（node:crypto 实现）。 */
export class JwtVerifier {
  private readonly algorithms: readonly JwtAlgorithm[];

  constructor(private readonly options: JwtVerifierOptions = {}) {
    if (options.algorithms && options.algorithms.length > 0) {
      this.algorithms = options.algorithms;
    } else {
      const defaults: JwtAlgorithm[] = [];
      if (options.secret) defaults.push('HS256');
      if (options.publicKey) defaults.push('RS256', 'ES256');
      this.algorithms = defaults;
    }
  }

  get configured(): boolean {
    return this.algorithms.length > 0;
  }

  verify(token: string): Principal {
    if (token.length > MAX_TOKEN_LENGTH) throw new AuthError('Token too large');
    if (!this.configured) throw new AuthError('Token verification is not configured');
    const parts = token.split('.');
    if (parts.length !== 3) throw new AuthError('Malformed token');
    const [headerPart, payloadPart, signaturePart] = parts;
    if (!headerPart || !payloadPart || !signaturePart) throw new AuthError('Malformed token');

    let header: JwtHeader;
    let claims: JwtClaims;
    try {
      header = JSON.parse(base64UrlDecode(headerPart).toString('utf8')) as JwtHeader;
      claims = JSON.parse(base64UrlDecode(payloadPart).toString('utf8')) as JwtClaims;
    } catch {
      throw new AuthError('Malformed token');
    }

    const alg = header.alg;
    if (typeof alg !== 'string' || !(this.algorithms as readonly string[]).includes(alg)) {
      throw new AuthError(`Unsupported token algorithm: ${String(alg)}`, {
        supported: [...this.algorithms],
      });
    }

    const data = Buffer.from(`${headerPart}.${payloadPart}`, 'utf8');
    const signature = base64UrlDecode(signaturePart);
    this.verifySignature(alg as JwtAlgorithm, data, signature);
    this.verifyClaims(claims);
    return this.toPrincipal(claims);
  }

  private verifySignature(algorithm: JwtAlgorithm, data: Buffer, signature: Buffer): void {
    let valid = false;
    switch (algorithm) {
      case 'HS256': {
        if (!this.options.secret) throw new AuthError('HS256 token rejected: no shared secret configured');
        const expected = createHmac('sha256', this.options.secret).update(data).digest();
        valid = expected.length === signature.length && timingSafeEqual(expected, signature);
        break;
      }
      case 'RS256': {
        if (!this.options.publicKey) throw new AuthError('RS256 token rejected: no public key configured');
        valid = cryptoVerify('sha256', data, createPublicKey(this.options.publicKey), signature);
        break;
      }
      case 'ES256': {
        if (!this.options.publicKey) throw new AuthError('ES256 token rejected: no public key configured');
        // JWT 的 ES256 签名为 R||S（ieee-p1363），与 Node 默认 DER 编码不同。
        valid = cryptoVerify(
          'sha256',
          data,
          { key: createPublicKey(this.options.publicKey), dsaEncoding: 'ieee-p1363' },
          signature,
        );
        break;
      }
    }
    if (!valid) throw new AuthError('Invalid token signature');
  }

  private verifyClaims(claims: JwtClaims): void {
    const nowSec = Math.floor((this.options.now ?? Date.now)() / 1000);
    const tolerance = this.options.clockToleranceSec ?? 30;

    if (claims.exp !== undefined) {
      if (typeof claims.exp !== 'number' || !Number.isFinite(claims.exp)) {
        throw new AuthError('Invalid token: exp claim must be a number');
      }
      if (nowSec - tolerance >= claims.exp) throw new AuthError('Token expired', { expired: true });
    }
    if (claims.nbf !== undefined) {
      if (typeof claims.nbf !== 'number' || !Number.isFinite(claims.nbf)) {
        throw new AuthError('Invalid token: nbf claim must be a number');
      }
      if (nowSec + tolerance < claims.nbf) throw new AuthError('Token not yet valid');
    }

    if (this.options.issuer !== undefined) {
      if (typeof claims.iss !== 'string' || claims.iss !== this.options.issuer) {
        throw new AuthError('Token issuer mismatch');
      }
    }
    if (this.options.audience !== undefined) {
      const configured = this.options.audience;
      const expected: readonly string[] = typeof configured === 'string' ? [configured] : configured;
      const aud = claims.aud;
      const actual: string[] =
        typeof aud === 'string'
          ? [aud]
          : Array.isArray(aud)
            ? aud.filter((value): value is string => typeof value === 'string')
            : [];
      if (!actual.some((value) => expected.includes(value))) {
        throw new AuthError('Token audience mismatch');
      }
    }
  }

  private toPrincipal(claims: JwtClaims): Principal {
    const subject = typeof claims.sub === 'string' ? claims.sub : claims.userId;
    if (typeof subject !== 'string' || subject.length === 0) {
      throw new AuthError('Token is missing the subject (sub) claim');
    }
    return {
      userId: subject,
      scopes: normaliseScopes(claims.scopes ?? claims.scope),
      boards: normaliseBoards(claims.boards),
      kind: 'jwt',
      tenantId: typeof claims.tenantId === 'string' ? claims.tenantId : null,
      rateLimit: typeof claims.rateLimit === 'number' && Number.isFinite(claims.rateLimit) ? claims.rateLimit : null,
      rateLimitKey: `jwt:${subject}`,
    };
  }
}

/** 不透明 token 内省接口（真实部署注入 OAuth 内省端点调用）。 */
export interface OAuthIntrospector {
  introspect(token: string): Promise<Principal | null>;
}

export interface OAuthAuthenticatorOptions {
  jwt?: JwtVerifier;
  introspector?: OAuthIntrospector;
}

/** OAuth / JWT 组合认证器：JWT 形态走本地校验，其余走内省。 */
export class OAuthAuthenticator {
  constructor(private readonly options: OAuthAuthenticatorOptions = {}) {}

  get configured(): boolean {
    return Boolean(this.options.jwt?.configured || this.options.introspector);
  }

  async authenticate(bearer: string): Promise<Principal> {
    const token = bearer.trim();
    if (token.length > MAX_TOKEN_LENGTH) throw new AuthError('Token too large');
    if (looksLikeJwt(token)) {
      if (!this.options.jwt?.configured) throw new AuthError('Token verification is not configured');
      return this.options.jwt.verify(token);
    }
    if (this.options.introspector) {
      const principal = await this.options.introspector.introspect(token);
      if (!principal) throw new AuthError('Invalid token');
      return principal;
    }
    throw new AuthError('Opaque bearer tokens require an OAuth introspection endpoint (not configured)');
  }
}

export interface LoadOAuthResult {
  authenticator: OAuthAuthenticator;
  warnings: string[];
  errors: string[];
}

/** 从环境变量装配 OAuth 认证（WB_JWT_SECRET / WB_JWT_PUBLIC_KEY / WB_JWT_ISSUER / WB_JWT_AUDIENCE）。 */
export function loadOAuthFromEnv(env: NodeJS.ProcessEnv = process.env): LoadOAuthResult {
  const warnings: string[] = [];
  const errors: string[] = [];
  const secret = env['WB_JWT_SECRET'];
  const publicKeyRaw = env['WB_JWT_PUBLIC_KEY'];
  const publicKey = publicKeyRaw ? publicKeyRaw.replace(/\\n/g, '\n') : undefined;

  const jwtOptions: JwtVerifierOptions = {};
  if (secret) jwtOptions.secret = secret;
  if (publicKey) jwtOptions.publicKey = publicKey;

  const issuer = env['WB_JWT_ISSUER'];
  if (issuer && issuer.trim().length > 0) jwtOptions.issuer = issuer.trim();
  const audienceRaw = env['WB_JWT_AUDIENCE'];
  if (audienceRaw) {
    const list = audienceRaw
      .split(',')
      .map((value) => value.trim())
      .filter((value) => value.length > 0);
    if (list.length === 1) jwtOptions.audience = list[0];
    else if (list.length > 1) jwtOptions.audience = list;
  }

  const jwt = new JwtVerifier(jwtOptions);
  if (!jwt.configured) {
    warnings.push('WB_JWT_SECRET / WB_JWT_PUBLIC_KEY not set: JWT bearer tokens will be rejected');
  }
  return { authenticator: new OAuthAuthenticator({ jwt }), warnings, errors };
}
