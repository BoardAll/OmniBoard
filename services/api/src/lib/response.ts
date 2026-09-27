import type { ApiErrorShape } from './errors.js';

/**
 * Response envelope per 《OpenAPI规范.md》 §4.4:
 *
 * ```json
 * { "ok": true, "data": {}, "error": null, "meta": { "requestId": "...", "timestamp": "..." } }
 * ```
 */

export interface ResponseMeta {
  requestId: string;
  timestamp: string;
  /** Pagination extras are merged in by list endpoints (§4.5). */
  [key: string]: unknown;
}

export interface OkEnvelope<T> {
  ok: true;
  data: T;
  error: null;
  meta: ResponseMeta;
}

export interface ErrorEnvelope {
  ok: false;
  data: null;
  error: ApiErrorShape;
  meta: ResponseMeta;
}

export function buildMeta(requestId: string, extra?: Record<string, unknown>): ResponseMeta {
  return {
    requestId,
    timestamp: new Date().toISOString(),
    ...(extra ?? {}),
  };
}

export function okBody<T>(data: T, meta: ResponseMeta): OkEnvelope<T> {
  return { ok: true, data, error: null, meta };
}

export function errorBody(error: ApiErrorShape, meta: ResponseMeta): ErrorEnvelope {
  return { ok: false, data: null, error, meta };
}
