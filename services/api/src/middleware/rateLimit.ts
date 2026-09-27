import type { NextFunction, Request, RequestHandler, Response } from 'express';
import { ApiError } from '../lib/errors.js';
import { auditContext } from './audit.js';

/**
 * 内存滑动窗口限流（《OpenAPI规范.md》§4.9、《安全与合规设计》§8.2）。
 *
 * 维度（§8.2 对照落地）：
 * - 用户：默认 1000 请求/分钟（Token 可覆盖，见 JWT `rateLimit` / API Key 配置）；
 * - IP：默认 5000 请求/分钟 —— `rateLimitIp()` 挂在认证之前，为未认证流量
 *   提供 DoS 缓冲；认证后的请求同时计入 IP 与用户两个桶；
 * - 端点类别（AI / MCP）：可选，`rateLimitCategory()` 按 `/v1/ai`、`/v1/mcp`
 *   前缀叠加独立配额（§8.2「AI / MCP 可配置」）。
 *
 * 超限返回 429 `RATE_LIMITED`（detail 携带 retryAfter / limit / windowMs），
 * 并写审计 `rate_limit.exceeded`（§14.1 敏感操作审计）。
 * 响应头：`X-RateLimit-Limit` / `X-RateLimit-Remaining` / `X-RateLimit-Reset`。
 *
 * Wave 4 替换为 Redis 实现（多实例共享窗口），接口保持不变。
 */

export type RateLimitCategory = 'ai' | 'mcp';

export interface RateLimitOptions {
  windowMs?: number;
  /** 每窗口最大请求数（用户维度；主体 `rateLimit` 可覆盖）。 */
  max?: number;
  /** 每窗口最大请求数（IP 维度），默认 5000（§8.2）。 */
  ipMax?: number;
  /** 端点类别限额（AI / MCP，§8.2「可配置」）。 */
  categories?: Partial<Record<RateLimitCategory, number>>;
}

export interface RateLimitDecision {
  allowed: boolean;
  limit: number;
  remaining: number;
  /** epoch millis when the current window frees capacity. */
  resetAt: number;
}

export class SlidingWindowLimiter {
  private readonly hits = new Map<string, number[]>();

  constructor(private readonly windowMs: number) {}

  check(key: string, limit: number, now: number = Date.now()): RateLimitDecision {
    const cutoff = now - this.windowMs;
    const existing = this.hits.get(key) ?? [];
    const recent = existing.filter((ts) => ts > cutoff);
    if (recent.length >= limit) {
      const oldest = recent[0] ?? now;
      this.hits.set(key, recent);
      return { allowed: false, limit, remaining: 0, resetAt: oldest + this.windowMs };
    }
    recent.push(now);
    this.hits.set(key, recent);
    return {
      allowed: true,
      limit,
      remaining: Math.max(0, limit - recent.length),
      resetAt: now + this.windowMs,
    };
  }

  reset(key?: string): void {
    if (key === undefined) this.hits.clear();
    else this.hits.delete(key);
  }

  size(): number {
    return this.hits.size;
  }
}

export const DEFAULT_RATE_LIMIT_WINDOW_MS = 60_000;
export const DEFAULT_RATE_LIMIT_MAX = 1000;
export const DEFAULT_RATE_LIMIT_IP_MAX = 5000;

function applyDecisionHeaders(res: Response, decision: RateLimitDecision): void {
  res.setHeader('X-RateLimit-Limit', String(decision.limit));
  res.setHeader('X-RateLimit-Remaining', String(decision.remaining));
  res.setHeader('X-RateLimit-Reset', String(Math.ceil(decision.resetAt / 1000)));
}

function denyRequest(
  res: Response,
  next: NextFunction,
  decision: RateLimitDecision,
  windowMs: number,
  category?: RateLimitCategory,
): void {
  const retryAfterSeconds = Math.max(1, Math.ceil((decision.resetAt - Date.now()) / 1000));
  res.setHeader('Retry-After', String(retryAfterSeconds));
  const detail: Record<string, unknown> = {
    retryAfter: retryAfterSeconds,
    limit: decision.limit,
    windowMs,
  };
  if (category !== undefined) detail['category'] = category;
  next(
    ApiError.rateLimited(
      category === undefined ? 'Rate limit exceeded' : `${category.toUpperCase()} rate limit exceeded`,
      detail,
    ),
  );
}

/**
 * IP 维度限流（挂在认证之前；未认证请求仅受此桶约束）。
 * 认证后的请求同样计入（§8.2「IP 5000 请求/分钟」）。
 */
export function rateLimitIp(
  options: RateLimitOptions = {},
  limiter: SlidingWindowLimiter = new SlidingWindowLimiter(
    options.windowMs ?? DEFAULT_RATE_LIMIT_WINDOW_MS,
  ),
): RequestHandler {
  const windowMs = options.windowMs ?? DEFAULT_RATE_LIMIT_WINDOW_MS;
  const ipMax = options.ipMax ?? DEFAULT_RATE_LIMIT_IP_MAX;

  return (req: Request, res: Response, next: NextFunction) => {
    const ip = req.ip ?? 'unknown';
    const decision = limiter.check(`ip:${ip}`, ipMax);
    applyDecisionHeaders(res, decision);
    if (!decision.allowed) {
      auditContext(res, { action: 'rate_limit.exceeded', target: { type: 'ip', id: ip } });
      denyRequest(res, next, decision, windowMs);
      return;
    }
    next();
  };
}

/**
 * 用户维度限流（挂在认证之后）：`principal.rateLimit` 可覆盖默认值；
 * 未认证时退回 IP 桶（与 `rateLimitIp` 同键，保持兼容）。
 */
export function rateLimit(
  options: RateLimitOptions = {},
  limiter: SlidingWindowLimiter = new SlidingWindowLimiter(
    options.windowMs ?? DEFAULT_RATE_LIMIT_WINDOW_MS,
  ),
): RequestHandler {
  const windowMs = options.windowMs ?? DEFAULT_RATE_LIMIT_WINDOW_MS;
  const defaultMax = options.max ?? DEFAULT_RATE_LIMIT_MAX;

  return (req: Request, res: Response, next: NextFunction) => {
    const principal = req.principal;
    const key = principal ? `user:${principal.userId}` : `ip:${req.ip ?? 'unknown'}`;
    const limit = principal?.rateLimit ?? defaultMax;
    const decision = limiter.check(key, limit);
    applyDecisionHeaders(res, decision);

    if (!decision.allowed) {
      auditContext(
        res,
        principal
          ? { action: 'rate_limit.exceeded', target: { type: 'user', id: principal.userId } }
          : { action: 'rate_limit.exceeded', target: { type: 'ip', id: req.ip ?? 'unknown' } },
      );
      denyRequest(res, next, decision, windowMs);
      return;
    }
    next();
  };
}

/**
 * 端点类别限流（§8.2「AI / MCP 可配置」）：按主体（或 IP）叠加独立配额。
 * 头部反映该类别配额（比用户默认更严格的限额对客户端可见）。
 */
export function rateLimitCategory(
  category: RateLimitCategory,
  options: RateLimitOptions & { max: number },
  limiter: SlidingWindowLimiter,
): RequestHandler {
  const windowMs = options.windowMs ?? DEFAULT_RATE_LIMIT_WINDOW_MS;

  return (req: Request, res: Response, next: NextFunction) => {
    const principal = req.principal;
    const subject = principal ? `user:${principal.userId}` : `ip:${req.ip ?? 'unknown'}`;
    const key = `cat:${category}:${subject}`;
    const decision = limiter.check(key, options.max);
    applyDecisionHeaders(res, decision);

    if (!decision.allowed) {
      auditContext(res, {
        action: 'rate_limit.exceeded',
        target: { type: category, id: principal?.userId ?? req.ip ?? 'unknown' },
      });
      denyRequest(res, next, decision, windowMs, category);
      return;
    }
    next();
  };
}

/** 从环境变量读取限流配置（§8.2 可配置；显式 options 优先）。 */
export function rateLimitOptionsFromEnv(env: NodeJS.ProcessEnv): RateLimitOptions {
  const num = (key: string): number | undefined => {
    const raw = env[key];
    if (typeof raw !== 'string' || raw.trim().length === 0) return undefined;
    const value = Number(raw);
    return Number.isFinite(value) && value > 0 ? Math.floor(value) : undefined;
  };

  const categories: Partial<Record<RateLimitCategory, number>> = {};
  const ai = num('WB_RATE_LIMIT_AI_MAX');
  if (ai !== undefined) categories.ai = ai;
  const mcp = num('WB_RATE_LIMIT_MCP_MAX');
  if (mcp !== undefined) categories.mcp = mcp;

  return {
    windowMs: num('WB_RATE_LIMIT_WINDOW_MS'),
    max: num('WB_RATE_LIMIT_USER_MAX'),
    ipMax: num('WB_RATE_LIMIT_IP_MAX'),
    ...(Object.keys(categories).length > 0 ? { categories } : {}),
  };
}
