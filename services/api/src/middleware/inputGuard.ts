import type { NextFunction, Request, RequestHandler, Response } from 'express';
import { buildMeta, errorBody } from '../lib/response.js';

/**
 * 输入守卫（《安全与合规设计》§8.5 / §8.7：输入校验、大小限制）。
 *
 * - 带请求体的 POST/PUT/PATCH 必须使用 `application/json`（或其 `+json` 变体），
 *   否则 415（防止跨类型解析歧义 / 内容嗅探）；
 * - 查询串拒绝控制字符（NUL、CR/LF 等，防日志注入与解析歧义）→ 400；
 * - 查询串长度上限（默认 4096 字符）→ 414。
 *
 * 响应沿用统一错误信封 `{ ok: false, error: { code, message }, meta }`。
 * 中间件需挂在 requestId 之后（meta.requestId 依赖）。
 */

export const DEFAULT_MAX_QUERY_LENGTH = 4096;

/** 全部 ASCII 控制字符（含 NUL / CR / LF / DEL）。 */
const CONTROL_CHARS = /[\u0000-\u001f\u007f]/;

function collectStrings(value: unknown, out: string[], depth = 0): void {
  if (depth > 5) return;
  if (typeof value === 'string') {
    out.push(value);
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) collectStrings(item, out, depth + 1);
    return;
  }
  if (typeof value === 'object' && value !== null) {
    for (const item of Object.values(value as Record<string, unknown>)) collectStrings(item, out, depth + 1);
  }
}

/** `application/json` 或 `application/*+json`（忽略 charset 等参数）。 */
function isJsonContentType(raw: string): boolean {
  const value = (raw.split(';')[0] ?? '').trim().toLowerCase();
  return value === 'application/json' || value.endsWith('+json');
}

/** 请求是否携带请求体（按 Transfer-Encoding / Content-Length 判定）。 */
function hasBody(req: Request): boolean {
  if (req.headers['transfer-encoding'] !== undefined) return true;
  const length = Number(req.headers['content-length'] ?? '0');
  return Number.isFinite(length) && length > 0;
}

export interface InputGuardOptions {
  /** 查询串最大长度（字符），默认 4096。 */
  maxQueryLength?: number;
}

export function inputGuard(options: InputGuardOptions = {}): RequestHandler {
  const maxQueryLength = options.maxQueryLength ?? DEFAULT_MAX_QUERY_LENGTH;

  return (req: Request, res: Response, next: NextFunction) => {
    const meta = buildMeta(req.requestId ?? '');

    // 1) 查询串：长度与控制字符。
    const queryIndex = req.originalUrl.indexOf('?');
    if (queryIndex !== -1) {
      const rawQuery = req.originalUrl.slice(queryIndex + 1);
      if (rawQuery.length > maxQueryLength) {
        res
          .status(414)
          .json(errorBody({ code: 'INVALID_ARGUMENT', message: 'Query string too long' }, meta));
        return;
      }
      const values: string[] = [];
      try {
        collectStrings(req.query, values);
      } catch {
        res
          .status(400)
          .json(errorBody({ code: 'INVALID_ARGUMENT', message: 'Malformed query string' }, meta));
        return;
      }
      if (values.some((value) => CONTROL_CHARS.test(value))) {
        res
          .status(400)
          .json(
            errorBody(
              { code: 'INVALID_ARGUMENT', message: 'Query string contains control characters' },
              meta,
            ),
          );
        return;
      }
    }

    // 2) 写请求的 Content-Type 强制（§8.5）。
    if ((req.method === 'POST' || req.method === 'PUT' || req.method === 'PATCH') && hasBody(req)) {
      const contentType = req.header('content-type') ?? '';
      if (!isJsonContentType(contentType)) {
        res
          .status(415)
          .json(
            errorBody(
              {
                code: 'INVALID_ARGUMENT',
                message: 'Unsupported Media Type: expected application/json',
              },
              meta,
            ),
          );
        return;
      }
    }

    next();
  };
}
