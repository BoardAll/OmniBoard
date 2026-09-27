import type { NextFunction, Request, RequestHandler, Response } from 'express';
import { newRequestId } from '../lib/ids.js';

/**
 * 为每个请求生成 `requestId`（OpenAPI §4.4 meta.requestId）并回写
 * `X-Request-Id` 响应头；`req.requestId` 供审计与错误响应使用。
 */
export function requestId(): RequestHandler {
  return (req: Request, res: Response, next: NextFunction) => {
    const id = req.header('x-request-id')?.trim() || newRequestId();
    req.requestId = id;
    res.setHeader('X-Request-Id', id);
    next();
  };
}
