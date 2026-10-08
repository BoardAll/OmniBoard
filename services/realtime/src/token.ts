/**
 * 连接认证 / token 解析（M1 完整版 / T1.3；由 M0 `auth.ts` 扩展而来）。
 *
 * 策略（对齐 services/api 的凭据哲学）：
 * 1. 配置 `WB_JWT_SECRET` 且携带 token → HS256 验签；失败拒连（Unauthorized）；
 *    验签成功取 `sub`（优先）/`userId` 为身份，`role` claim 白名单校验（非法/缺失回落 Participant）；
 * 2. 未配置密钥且非 production → 匿名 dev 回落（`anon-<random>`），由调用方警告 + 审计；
 * 3. production 缺密钥 / 缺 token → 拒绝连接（不静默降级）。
 *
 * 凭据仅从环境变量读取；不打印、不进日志与错误详情。
 */

import { randomBytes } from 'node:crypto';
import jwt, { type JwtPayload } from 'jsonwebtoken';
import { BOARD_ROLES, DEFAULT_BOARD_ROLE, type BoardRole } from './types.js';

/** 匿名 dev 回落的触发原因（供警告 / 审计使用）。 */
export type AnonymousFallbackReason = 'no_token' | 'missing_secret';

/** 连接身份解析结果。 */
export type ConnectionIdentity =
  | { kind: 'jwt'; userId: string; role: BoardRole }
  | { kind: 'anonymous'; userId: string; role: BoardRole; fallbackReason: AnonymousFallbackReason }
  | { kind: 'rejected'; reason: string };

function readEnvString(env: NodeJS.ProcessEnv, key: string): string | null {
  const value = env[key];
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function readAuthToken(auth: unknown): string | null {
  if (typeof auth !== 'object' || auth === null) return null;
  const token = (auth as { token?: unknown }).token;
  if (typeof token !== 'string') return null;
  const trimmed = token.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function generateAnonymousUserId(): string {
  return `anon-${randomBytes(4).toString('hex')}`;
}

/** 取 `sub`（优先）或 `userId` 声明。 */
function extractUserId(payload: JwtPayload): string | null {
  const candidates: unknown[] = [payload.sub, payload.userId];
  for (const candidate of candidates) {
    if (typeof candidate === 'string' && candidate.trim().length > 0) {
      return candidate.trim();
    }
  }
  return null;
}

/** 取 `role` 声明（白名单校验；非法 / 缺失回落 `DEFAULT_BOARD_ROLE`）。 */
function extractRole(payload: JwtPayload): BoardRole {
  const raw = payload.role;
  if (typeof raw === 'string' && (BOARD_ROLES as readonly string[]).includes(raw)) {
    return raw as BoardRole;
  }
  return DEFAULT_BOARD_ROLE;
}

/**
 * 解析连接身份（纯函数，便于测试）。
 * `auth` 为客户端 `socket.handshake.auth`（可能为任意值，防御式读取）。
 */
export function resolveConnectionIdentity(
  auth: unknown,
  env: NodeJS.ProcessEnv = process.env,
): ConnectionIdentity {
  const token = readAuthToken(auth);
  const secret = readEnvString(env, 'WB_JWT_SECRET');
  const production = env.NODE_ENV === 'production';

  if (secret) {
    if (token) {
      try {
        const payload = jwt.verify(token, secret, { algorithms: ['HS256'] });
        if (typeof payload === 'string') {
          return { kind: 'rejected', reason: 'token payload is not an object' };
        }
        const userId = extractUserId(payload);
        if (!userId) {
          return { kind: 'rejected', reason: 'token missing sub/userId claim' };
        }
        return { kind: 'jwt', userId, role: extractRole(payload) };
      } catch {
        return { kind: 'rejected', reason: 'invalid or expired token' };
      }
    }
    // 有密钥、无 token：生产拒绝；非生产匿名 dev 回落。
    if (production) {
      return { kind: 'rejected', reason: 'missing token' };
    }
    return { kind: 'anonymous', userId: generateAnonymousUserId(), role: DEFAULT_BOARD_ROLE, fallbackReason: 'no_token' };
  }

  // 无密钥：生产拒绝（无法验签，不静默降级）。
  if (production) {
    return { kind: 'rejected', reason: 'token verification is not configured (WB_JWT_SECRET missing)' };
  }
  // 非生产匿名 dev 回落：无 token / 有 token 但无法验签（调用方负责警告 + 审计）。
  return {
    kind: 'anonymous',
    userId: generateAnonymousUserId(),
    role: DEFAULT_BOARD_ROLE,
    fallbackReason: token ? 'missing_secret' : 'no_token',
  };
}
