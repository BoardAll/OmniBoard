import type { NextFunction, Request, RequestHandler, Response } from 'express';
import { ApiError } from './errors.js';
import { buildMeta, okBody } from './response.js';
import type { Paginated } from './query.js';
import type { PrincipalContext } from '../services/access.js';

/**
 * 路由公共工具：异步错误捕获、主体提取、统一响应、破坏性操作确认。
 *
 * Express 4 不会自动捕获 async handler 的 rejection —— 所有路由统一使用
 * `handle()` 包裹，保证错误进入统一错误处理中间件（app.ts）。
 */

/** 行为签名：同步抛错与 async rejection 都会被转发到 error handler。 */
export function handle(
  fn: (req: Request, res: Response, next: NextFunction) => void | Promise<void>,
): RequestHandler {
  return (req, res, next) => {
    try {
      const result = fn(req, res, next);
      if (result instanceof Promise) result.catch(next);
    } catch (error) {
      next(error);
    }
  };
}

/** 提取认证主体（认证中间件先行，缺失即 401）。 */
export function principalOf(req: Request): PrincipalContext {
  const principal = req.principal;
  if (!principal) throw ApiError.unauthenticated();
  return {
    userId: principal.userId,
    scopes: principal.scopes,
    boards: principal.boards,
  };
}

/** 单资源/动作响应：`{ ok, data, error: null, meta }`（§4.4）。 */
export function respond<T>(req: Request, res: Response, data: T, status = 200): void {
  res.status(status).json(okBody(data, buildMeta(req.requestId ?? '')));
}

/** 列表响应：`data` 为数组，`meta` 携带 nextCursor / hasMore / total（§4.5）。 */
export function respondList<T>(req: Request, res: Response, page: Paginated<T>): void {
  res.json(
    okBody(
      page.items,
      buildMeta(req.requestId ?? '', {
        nextCursor: page.nextCursor,
        hasMore: page.hasMore,
        total: page.total,
      }),
    ),
  );
}

/**
 * 破坏性操作（删除类 API）确认（《安全与合规设计》§9.6 语义）。
 * 缺少 `?confirm=true` 时返回 422 `UNPROCESSABLE`
 * （detail.confirmationRequired = true，hint 提示重试方式）。
 */
export function requireConfirm(req: Request, what: string): void {
  if (req.query['confirm'] !== 'true') {
    throw ApiError.confirmationRequired(`${what} requires explicit confirmation`);
  }
}
