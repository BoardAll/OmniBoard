import { createHash } from 'node:crypto';
import type { NextFunction, Request, RequestHandler, Response } from 'express';
import { ApiError } from '../lib/errors.js';
import type { IdempotencyRecord } from '../db/schema.js';

/**
 * 幂等性（《OpenAPI规范.md》§4.8、《安全与合规设计》§11.3）。
 *
 * - Header：`Idempotency-Key: <uuid>`
 * - 相同 Key + 相同请求体，24 小时内返回相同结果（重放时响应头
 *   `Idempotency-Replay: true`）
 * - 相同 Key + 不同请求体 → 409 `CONFLICT`
 * - 仅对变更类方法（POST/PATCH/PUT/DELETE）生效
 *
 * 记录按用户隔离（`userId:key`），避免跨用户重放。
 * Wave 4 该存储迁移至 Redis（进度：`InMemoryIdempotencyStore` → `RedisIdempotencyStore`）。
 */

export const IDEMPOTENCY_TTL_MS = 24 * 60 * 60 * 1000;
const IDEMPOTENCY_METHODS = new Set(['POST', 'PATCH', 'PUT', 'DELETE']);

export interface IdempotencyStore {
  get(key: string): IdempotencyRecord | undefined;
  set(key: string, record: IdempotencyRecord): void;
  delete(key: string): void;
}

export class InMemoryIdempotencyStore implements IdempotencyStore {
  private readonly records = new Map<string, IdempotencyRecord>();

  get(key: string): IdempotencyRecord | undefined {
    return this.records.get(key);
  }

  set(key: string, record: IdempotencyRecord): void {
    this.records.set(key, record);
  }

  delete(key: string): void {
    this.records.delete(key);
  }

  prune(now: number = Date.now()): void {
    for (const [key, record] of this.records) {
      if (record.expiresAt <= now) this.records.delete(key);
    }
  }

  size(): number {
    return this.records.size;
  }
}

export interface IdempotencyOptions {
  ttlMs?: number;
}

export function fingerprintOf(req: Request): string {
  const body = (req as Request & { body?: unknown }).body;
  const serialised = body === undefined ? '' : JSON.stringify(body);
  return createHash('sha256').update(`${req.method} ${req.originalUrl} ${serialised}`).digest('hex');
}

export function idempotencyMiddleware(
  store: IdempotencyStore,
  options: IdempotencyOptions = {},
): RequestHandler {
  const ttlMs = options.ttlMs ?? IDEMPOTENCY_TTL_MS;

  return (req: Request, res: Response, next: NextFunction) => {
    if (!IDEMPOTENCY_METHODS.has(req.method)) {
      next();
      return;
    }
    const rawKey = req.header('idempotency-key');
    if (!rawKey || rawKey.trim() === '') {
      next();
      return;
    }
    const key = `${req.principal?.userId ?? 'anonymous'}:${rawKey.trim()}`;
    const fingerprint = fingerprintOf(req);
    const now = Date.now();
    const existing = store.get(key);

    if (existing) {
      if (existing.expiresAt > now) {
        if (existing.fingerprint !== fingerprint) {
          next(
            ApiError.conflict('Idempotency-Key was reused with a different request body', {
              idempotencyKey: rawKey,
            }),
          );
          return;
        }
        res.setHeader('Idempotency-Replay', 'true');
        res.status(existing.status).json(existing.body);
        return;
      }
      store.delete(key);
    }

    const originalJson = res.json.bind(res);
    res.json = ((body: unknown) => {
      const status = res.statusCode;
      // 只缓存确定性结果：5xx（瞬时故障）与 429（限流）不缓存。
      if (status < 500 && status !== 429) {
        store.set(key, {
          key,
          fingerprint,
          status,
          body,
          createdAt: now,
          expiresAt: now + ttlMs,
        });
      }
      return originalJson(body);
    }) as typeof res.json;

    next();
  };
}
