/**
 * Express 传输公共辅助（SSE / Streamable HTTP，§4）。
 *
 * - 安全响应头：`securityHeaders()`（《安全与合规设计》§22.1，9 项头）；
 * - 认证中间件：`X-API-Key` / `Authorization: Bearer` → `CompositeAuthenticator`，
 *   成功/失败均写审计（不含凭据）；失败返回 401 `{ ok: false, error: { code, message } }`；
 * - 统一错误封套与异步包装；
 * - 主体读取 `res.locals.principal`（仅供路由内部使用）。
 */

import type { ErrorRequestHandler, NextFunction, Request, RequestHandler, Response } from 'express';
import type { CompositeAuthenticator } from '../auth/index.js';
import { AuthError, type Principal } from '../auth/types.js';
import { buildAuditEntry, NULL_AUDIT_SINK, type AuditSink, type AuditEntry } from '../audit.js';
import { NULL_LOGGER, type Logger } from '../log.js';

export type HttpTransportKind = 'sse' | 'http';

/** §22.1 安全 Header（响应级，统一由中间件注入）。 */
export const SECURITY_HEADERS: Readonly<Record<string, string>> = {
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains; preload',
  'Content-Security-Policy':
    "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'",
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Permissions-Policy': 'camera=(), microphone=(self), geolocation=()',
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Embedder-Policy': 'require-corp',
  'Cross-Origin-Resource-Policy': 'same-origin',
};

/** 安全头中间件：对所有响应（含 401 / 错误封套）生效。 */
export function securityHeaders(): RequestHandler {
  return (_req: Request, res: Response, next: NextFunction) => {
    for (const [name, value] of Object.entries(SECURITY_HEADERS)) res.setHeader(name, value);
    next();
  };
}

export interface AuthMiddlewareOptions {
  authenticator: CompositeAuthenticator;
  transport: HttpTransportKind;
  audit?: AuditSink;
  logger?: Logger;
}

function headerValue(raw: string | string[] | undefined): string | null {
  if (typeof raw === 'string' && raw.trim().length > 0) return raw.trim();
  if (Array.isArray(raw) && raw.length > 0) {
    const first = raw[0];
    if (typeof first === 'string' && first.trim().length > 0) return first.trim();
  }
  return null;
}

/** 解析 `Authorization: Bearer <token>`（大小写不敏感）；非 Bearer 返回 null。 */
export function parseBearerHeader(raw: string | string[] | undefined): string | null {
  const value = headerValue(raw);
  if (!value) return null;
  const match = /^Bearer\s+(.+)$/i.exec(value);
  return match?.[1]?.trim() ?? null;
}

export function clientIp(req: Request): string | undefined {
  const forwarded = headerValue(req.headers['x-forwarded-for']);
  if (forwarded) return forwarded.split(',')[0]?.trim() || undefined;
  return req.socket.remoteAddress ?? undefined;
}

/** 读取认证后的主体（未认证路由返回 null）。 */
export function principalOf(res: Response): Principal | null {
  const value = res.locals['principal'];
  return (value as Principal | undefined) ?? null;
}

/** 统一错误封套（对齐 command.schema.json error 形状）。 */
export function sendError(
  res: Response,
  status: number,
  code: string,
  message: string,
  details?: Record<string, unknown>,
): void {
  const error: Record<string, unknown> = { code, message };
  if (details !== undefined) error['details'] = details;
  res.status(status).json({ ok: false, error });
}

/** 统一成功封套。 */
export function sendOk(res: Response, status: number, data: unknown): void {
  res.status(status).json({ ok: true, data, error: null });
}

/** 异步路由包装：异常交给 express 错误中间件。 */
export function wrapAsync(handler: (req: Request, res: Response, next: NextFunction) => Promise<void>): RequestHandler {
  return (req, res, next) => {
    handler(req, res, next).catch(next);
  };
}

/**
 * 认证中间件：成功后 `res.locals.principal` 可用（写 'success' 审计）；
 * 失败 401（审计记录 'denied'，日志与响应均不回显凭据）。
 */
export function createAuthMiddleware(options: AuthMiddlewareOptions): RequestHandler {
  const audit = options.audit ?? NULL_AUDIT_SINK;
  const logger = options.logger ?? NULL_LOGGER;

  return (req, res, next) => {
    const apiKey = headerValue(req.headers['x-api-key']);
    const bearer = parseBearerHeader(req.headers['authorization']);
    const ip = clientIp(req);

    options.authenticator
      .authenticate({ apiKey, bearer })
      .then((principal) => {
        res.locals['principal'] = principal;
        // §10 审计：认证成功同样入账（失败已记录）。
        audit.record(
          buildAuditEntry({
            userId: principal.userId,
            action: 'auth.authenticate',
            target: { type: 'http_request', id: req.path },
            result: 'success',
            transport: options.transport,
            ...(ip !== undefined ? { ip } : {}),
          }),
        );
        next();
      })
      .catch((error: unknown) => {
        const message = error instanceof AuthError ? error.message : 'Authentication failed';
        const entry: AuditEntry = buildAuditEntry({
          userId: null,
          action: 'auth.authenticate',
          target: { type: 'http_request', id: req.path },
          result: 'denied',
          transport: options.transport,
          ...(ip !== undefined ? { ip } : {}),
        });
        audit.record(entry);
        logger.debug('Authentication failed', { path: req.path, reason: message });
        sendError(res, 401, 'UNAUTHENTICATED', message);
      });
  };
}

/** 统一错误中间件：JSON 解析失败 → 400；其余 → 500（不泄漏内部细节）。 */
export function createErrorHandler(logger: Logger = NULL_LOGGER): ErrorRequestHandler {
  return (error, req, res, next) => {
    if (res.headersSent) {
      next(error);
      return;
    }
    const type = (error as { type?: string }).type;
    if (type === 'entity.parse.failed') {
      sendError(res, 400, 'INVALID_ARGUMENT', 'Request body is not valid JSON');
      return;
    }
    logger.error('Unhandled transport error', {
      path: req.path,
      message: error instanceof Error ? error.message : 'unknown error',
    });
    sendError(res, 500, 'INTERNAL_ERROR', 'Internal server error');
  };
}
