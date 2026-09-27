import type { NextFunction, Request, RequestHandler, Response } from 'express';

/**
 * 安全响应头与 CORS 配置（《安全与合规设计》§22.1、§8）。
 *
 * - `securityHeaders()`：逐项落地 §22.1 的 9 个安全 Header（HSTS / CSP /
 *   X-Content-Type-Options / X-Frame-Options / Referrer-Policy / Permissions-Policy /
 *   COOP / COEP / CORP）。HSTS 仅在 HTTPS 部署时被浏览器启用，HTTP 下忽略；
 * - `parseCorsOrigins()`：解析 `WB_CORS_ORIGINS`（逗号分隔白名单），
 *   未配置时保持公开 API 默认（`*`，见 app.ts）。
 */

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

export interface SecurityHeadersOptions {
  /** 追加 / 覆盖响应头（特殊部署或测试注入）。 */
  extra?: Record<string, string>;
}

/** 安全头中间件：对所有响应（含 4xx/5xx 与 CORS 预检）生效。 */
export function securityHeaders(options: SecurityHeadersOptions = {}): RequestHandler {
  const headers = { ...SECURITY_HEADERS, ...options.extra };
  return (_req: Request, res: Response, next: NextFunction) => {
    for (const [name, value] of Object.entries(headers)) res.setHeader(name, value);
    next();
  };
}

/**
 * 解析 CORS 白名单（`WB_CORS_ORIGINS="https://a.example.com,https://b.example.com"`）。
 * 返回 undefined 表示未配置 → 交给 cors 库默认行为（`*`）。
 */
export function parseCorsOrigins(raw: string | null | undefined): string | string[] | undefined {
  if (raw === null || raw === undefined) return undefined;
  const list = raw
    .split(',')
    .map((value) => value.trim())
    .filter((value) => value.length > 0);
  if (list.length === 0) return undefined;
  return list.length === 1 ? list[0] : list;
}
