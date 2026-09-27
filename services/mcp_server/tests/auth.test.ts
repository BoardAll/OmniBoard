/** 认证：API Key / JWT / 组合认证 / 本地信任 / Scope 校验。 */

import { createHmac } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import {
  ApiKeyAuthenticator,
  apiKeyLimitKey,
  CompositeAuthenticator,
  createLocalPrincipal,
  loadAuthFromEnv,
  parseApiKeys,
  TrustedLocalAuthenticator,
} from '../src/auth/index.js';
import { JwtVerifier, OAuthAuthenticator } from '../src/auth/oauth.js';
import { AuthError, assertScope, hasScope, KNOWN_SCOPES } from '../src/auth/types.js';
import { RPC_ERROR_CODES } from '../src/protocol/jsonrpc.js';

const KEY = 'wbp_test_key_123';
const SECRET = 'test-hs256-secret';
const API_KEYS_JSON = JSON.stringify({
  [KEY]: {
    userId: 'u-1',
    scopes: ['board:read', 'element:write'],
    boards: ['board-1'],
    tenantId: 't1',
    rateLimit: 50,
    name: 'ci',
  },
});

function base64url(value: string): string {
  return Buffer.from(value, 'utf8').toString('base64url');
}

/** 测试用 HS256 签发（与 oauth.ts 的校验实现独立）。 */
function signHs256(
  payload: Record<string, unknown>,
  secret = SECRET,
  header: Record<string, unknown> = { alg: 'HS256', typ: 'JWT' },
): string {
  const head = base64url(JSON.stringify(header));
  const body = base64url(JSON.stringify(payload));
  const signature = createHmac('sha256', secret).update(`${head}.${body}`).digest('base64url');
  return `${head}.${body}.${signature}`;
}

describe('auth：API Key', () => {
  it('parseApiKeys：合法 JSON → 记录归一化；非法输入 → errors', () => {
    const { keys, errors } = parseApiKeys(API_KEYS_JSON);
    expect(errors).toEqual([]);
    expect(keys.size).toBe(1);
    expect(keys.get(KEY)).toMatchObject({ userId: 'u-1', boards: ['board-1'], tenantId: 't1', rateLimit: 50 });

    expect(parseApiKeys('not json').errors).toHaveLength(1);
    expect(parseApiKeys('[]').errors).toHaveLength(1);
    expect(parseApiKeys(JSON.stringify({ k1: { scopes: [] } })).errors).toHaveLength(1);
    const unknownScope = parseApiKeys(JSON.stringify({ k2: { userId: 'u', scopes: ['board:read', 'bogus'] } }));
    expect(unknownScope.keys.get('k2')?.scopes).toEqual(['board:read']);
  });

  it('ApiKeyAuthenticator：校验通过 → Principal；未知 Key → AuthError', () => {
    const { keys } = parseApiKeys(API_KEYS_JSON);
    const authenticator = new ApiKeyAuthenticator(keys);

    const principal = authenticator.authenticate(KEY);
    expect(principal).toMatchObject({
      userId: 'u-1',
      kind: 'api-key',
      scopes: ['board:read', 'element:write'],
      boards: ['board-1'],
      tenantId: 't1',
      rateLimit: 50,
    });
    expect(principal.rateLimitKey).toBe(apiKeyLimitKey(KEY));
    expect(principal.rateLimitKey).not.toContain(KEY);
    expect(authenticator.authenticate(`  ${KEY}  `).userId).toBe('u-1');

    expect(() => authenticator.authenticate('wbp_wrong')).toThrowError(
      expect.objectContaining({ name: 'AuthError', message: 'Invalid API key' }),
    );
  });

  it('loadApiKeysFromEnv 集成（WB_API_KEYS 缺失/非法）', () => {
    const empty = loadAuthFromEnv({});
    expect(empty.authenticator.configured).toBe(false);
    expect(empty.warnings.join(' ')).toContain('No credentials');

    const broken = loadAuthFromEnv({ WB_API_KEYS: '{broken' });
    expect(broken.errors).toHaveLength(1);

    const ok = loadAuthFromEnv({ WB_API_KEYS: API_KEYS_JSON });
    expect(ok.authenticator.configured).toBe(true);
    expect(ok.authenticator.apiKeyCount).toBe(1);
  });
});

describe('auth：JWT（HS256）', () => {
  const nowMs = Date.UTC(2026, 0, 1, 0, 0, 0);
  const verifier = new JwtVerifier({ secret: SECRET, now: () => nowMs });

  it('合法 token → Principal（kind=jwt，Scope/白板归一化）', () => {
    const token = signHs256({
      sub: 'user-7',
      scopes: 'board:read element:write',
      boards: ['board-9'],
      tenantId: 'acme',
      exp: Math.floor(nowMs / 1000) + 3600,
    });
    const principal = verifier.verify(token);
    expect(principal).toMatchObject({
      userId: 'user-7',
      kind: 'jwt',
      scopes: ['board:read', 'element:write'],
      boards: ['board-9'],
      tenantId: 'acme',
      rateLimitKey: 'jwt:user-7',
    });
  });

  it('过期 / 签名错误 / 算法不支持 / 缺 sub → AuthError', () => {
    const expired = signHs256({ sub: 'u', exp: Math.floor(nowMs / 1000) - 3600 });
    expect(() => verifier.verify(expired)).toThrowError(/expired/i);

    const wrongSecret = signHs256({ sub: 'u', exp: Math.floor(nowMs / 1000) + 60 }, 'other-secret');
    expect(() => verifier.verify(wrongSecret)).toThrowError(/signature/i);

    const unsupported = signHs256({ sub: 'u' }, SECRET, { alg: 'none', typ: 'JWT' });
    expect(() => verifier.verify(unsupported)).toThrowError(/algorithm/i);

    const noSubject = signHs256({ exp: Math.floor(nowMs / 1000) + 60 });
    expect(() => verifier.verify(noSubject)).toThrowError(AuthError);
  });

  it('OAuthAuthenticator：JWT 形态走本地校验，不透明 token 需内省', async () => {
    const oauth = new OAuthAuthenticator({
      jwt: new JwtVerifier({ secret: SECRET, now: () => nowMs }),
    });
    const token = signHs256({ sub: 'u-9', exp: Math.floor(nowMs / 1000) + 60 });
    await expect(oauth.authenticate(token)).resolves.toMatchObject({ userId: 'u-9', kind: 'jwt' });
    await expect(oauth.authenticate('opaque-token')).rejects.toThrowError(/introspection/i);
  });
});

describe('auth：组合认证与本地信任', () => {
  it('CompositeAuthenticator：X-API-Key / Bearer(api key) / Bearer(jwt) 路由', async () => {
    const { keys } = parseApiKeys(API_KEYS_JSON);
    const nowMs = Date.UTC(2026, 0, 1);
    const composite = new CompositeAuthenticator({
      apiKeys: new ApiKeyAuthenticator(keys),
      oauth: new OAuthAuthenticator({ jwt: new JwtVerifier({ secret: SECRET, now: () => nowMs }) }),
    });
    expect(composite.configured).toBe(true);

    await expect(composite.authenticate({ apiKey: KEY })).resolves.toMatchObject({ userId: 'u-1' });
    await expect(composite.authenticate({ bearer: KEY })).resolves.toMatchObject({ userId: 'u-1' });

    const jwt = signHs256({ sub: 'jwt-user', exp: Math.floor(nowMs / 1000) + 60 });
    await expect(composite.authenticate({ bearer: jwt })).resolves.toMatchObject({ userId: 'jwt-user', kind: 'jwt' });

    await expect(composite.authenticate({})).rejects.toThrowError(/Missing credentials/);
    await expect(composite.authenticate({ bearer: 'unknown-token' })).rejects.toThrowError(AuthError);
  });

  it('TrustedLocalAuthenticator：忽略凭据返回本地主体（全 Scope）', async () => {
    const authenticator = new TrustedLocalAuthenticator(createLocalPrincipal('anonymous'));
    const principal = await authenticator.authenticate();
    expect(principal.kind).toBe('local');
    expect(principal.userId).toBe('anonymous');
    expect(principal.scopes).toHaveLength(KNOWN_SCOPES.length);
    expect(principal.boards).toBeNull();
  });

  it('KNOWN_SCOPES：18 项且与任务约定一致', () => {
    expect(KNOWN_SCOPES).toHaveLength(18);
    expect(KNOWN_SCOPES).toEqual(
      expect.arrayContaining(['board:read', 'element:write', 'mcp:invoke', 'admin:write', 'ai:invoke']),
    );
  });
});

describe('auth：Scope 校验', () => {
  it('hasScope / assertScope：通过时不抛错，缺失时 -32002（data 形状）', () => {
    const principal = createLocalPrincipal('tester');
    expect(hasScope(principal, 'board:read')).toBe(true);
    expect(hasScope(null, 'board:read')).toBe(false);
    expect(() => assertScope(principal, 'board:read', 'board.get')).not.toThrow();

    const limited = { ...principal, scopes: ['board:read'] };
    try {
      assertScope(limited, 'element:write', 'element.create');
      throw new Error('should have thrown');
    } catch (error) {
      expect(error).toMatchObject({
        name: 'RpcError',
        code: RPC_ERROR_CODES.permissionDenied,
        data: { scope: 'element:write', toolId: 'element.create' },
      });
    }

    expect(() => assertScope(null, 'board:read', 'board.get')).toThrowError(
      expect.objectContaining({ code: RPC_ERROR_CODES.permissionDenied }),
    );
  });
});
