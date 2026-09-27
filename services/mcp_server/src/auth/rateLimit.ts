/**
 * 速率限制（《MCP_Server详细设计》§9.6）：默认 1000 请求/分钟/Token，
 * 超限抛 JSON-RPC -32001，data 携带 `retryAfter`（秒）。
 *
 * 固定窗口计数（内存实现，进程内生效；多实例部署由网关层统一限流）。
 */

import { RpcError, RPC_ERROR_CODES } from '../protocol/jsonrpc.js';

export const DEFAULT_RATE_LIMIT_PER_MINUTE = 1000;

export interface RateLimiterOptions {
  /** 每窗口请求上限，默认 1000。 */
  limit?: number;
  /** 窗口长度（毫秒），默认 60_000。 */
  windowMs?: number;
  /** 可注入时钟（测试用）。 */
  now?: () => number;
}

interface WindowEntry {
  start: number;
  count: number;
}

export class RateLimiter {
  private readonly limit: number;
  private readonly windowMs: number;
  private readonly now: () => number;
  private readonly windows = new Map<string, WindowEntry>();

  constructor(options: RateLimiterOptions = {}) {
    this.limit = options.limit ?? DEFAULT_RATE_LIMIT_PER_MINUTE;
    this.windowMs = options.windowMs ?? 60_000;
    this.now = options.now ?? Date.now;
  }

  /**
   * 记录一次请求并检查限额；超限抛 -32001。
   * `limitOverride` 来自 Token 配置（设计 §9.5 `rateLimit` 字段）。
   */
  check(key: string, limitOverride?: number | null): void {
    const limit = limitOverride != null && limitOverride > 0 ? limitOverride : this.limit;
    const nowMs = this.now();
    const entry = this.windows.get(key);
    if (!entry || nowMs - entry.start >= this.windowMs) {
      this.windows.set(key, { start: nowMs, count: 1 });
      return;
    }
    entry.count += 1;
    if (entry.count > limit) {
      const retryAfter = Math.max(1, Math.ceil((entry.start + this.windowMs - nowMs) / 1000));
      throw new RpcError(RPC_ERROR_CODES.rateLimited, 'Rate limited', { retryAfter });
    }
  }

  /** 当前跟踪的键数量（测试 / 诊断用）。 */
  get trackedKeys(): number {
    return this.windows.size;
  }
}
