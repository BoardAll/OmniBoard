import { createServer, type Server } from 'node:http';
import jwt from 'jsonwebtoken';
import { createApp, type AppBundle, type CreateAppOptions } from '../src/app.js';

/**
 * vitest 测试辅助：自起临时服务器（端口 0，不依赖 supertest / 外部服务），
 * 使用 Node 内置 fetch 发起真实 HTTP 请求。
 */

/** 测试专用 JWT 密钥（仅用于 vitest，进程内临时；严禁用于任何真实环境）。 */
export const TEST_JWT_SECRET = 'vitest-only-secret-not-for-real-use';

/** 全部 scope（OpenAPI §3.2）。 */
export const ALL_SCOPES = [
  'board:read',
  'board:write',
  'board:share',
  'page:read',
  'page:write',
  'element:read',
  'element:write',
  'connector:read',
  'connector:write',
  'comment:read',
  'comment:write',
  'export:read',
  'history:read',
  'history:write',
  'ai:invoke',
  'mcp:invoke',
  'admin:read',
  'admin:write',
] as const;

export interface TestServer {
  baseUrl: string;
  bundle: AppBundle;
  close(): Promise<void>;
}

export async function startTestServer(options: CreateAppOptions = {}): Promise<TestServer> {
  const bundle = createApp({ auth: { jwtSecret: TEST_JWT_SECRET }, ...options });
  const server: Server = createServer(bundle.app);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('failed to bind test server');
  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    bundle,
    close: () =>
      new Promise<void>((resolve, reject) => {
        const closer = server as Server & { closeIdleConnections?: () => void };
        server.close((error) => (error ? reject(error) : resolve()));
        // 关闭 keep-alive 空闲连接（Node ≥18.2），避免 close 回调等待客户端连接池释放。
        closer.closeIdleConnections?.();
      }),
  };
}

export function signToken(
  payload: Record<string, unknown> = {},
  secret: string = TEST_JWT_SECRET,
): string {
  return jwt.sign({ sub: 'user_test', scopes: [...ALL_SCOPES], ...payload }, secret, {
    algorithm: 'HS256',
    expiresIn: '1h',
  });
}

export interface ApiOptions {
  token?: string | null;
  apiKey?: string;
  idempotencyKey?: string;
  headers?: Record<string, string>;
  body?: unknown;
  /** 原始请求体（用于刻意构造非法 JSON）。 */
  rawBody?: string;
  /** 覆盖 Content-Type（默认按 body 自动设为 application/json；用于 415 等媒体类型测试）。 */
  contentType?: string;
}

export interface ApiResult<T = Record<string, unknown>> {
  status: number;
  body: T;
  headers: Headers;
}

export async function api<T = Record<string, unknown>>(
  baseUrl: string,
  method: string,
  path: string,
  options: ApiOptions = {},
): Promise<ApiResult<T>> {
  const headers: Record<string, string> = { Accept: 'application/json', ...options.headers };
  if (options.token !== null) headers['Authorization'] = `Bearer ${options.token ?? signToken()}`;
  if (options.apiKey) headers['X-API-Key'] = options.apiKey;
  if (options.idempotencyKey) headers['Idempotency-Key'] = options.idempotencyKey;

  let body: string | undefined;
  if (options.rawBody !== undefined) {
    headers['Content-Type'] = 'application/json';
    body = options.rawBody;
  } else if (options.body !== undefined) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(options.body);
  }
  if (options.contentType !== undefined) headers['Content-Type'] = options.contentType;

  const response = await fetch(`${baseUrl}${path}`, { method, headers, body });
  const text = await response.text();
  const parsed: unknown = text.length > 0 ? JSON.parse(text) : null;
  return { status: response.status, body: parsed as T, headers: response.headers };
}

/** 断言辅助：从信封中取 data（ok=true 时）。 */
export function dataOf<T = Record<string, unknown>>(result: ApiResult<Record<string, unknown>>): T {
  if (result.body['ok'] !== true) {
    throw new Error(`expected ok envelope, got: ${JSON.stringify(result.body)}`);
  }
  return result.body['data'] as T;
}

/** 断言辅助：从信封中取 error。 */
export function errorOf(
  result: ApiResult<Record<string, unknown>>,
): { code: string; message: string; detail?: unknown } {
  return result.body['error'] as { code: string; message: string; detail?: unknown };
}

/** 快捷创建白板（默认走完整 scopes 的测试身份）。 */
export async function createBoard(
  baseUrl: string,
  name: string,
  token?: string,
): Promise<Record<string, unknown>> {
  const result = await api(baseUrl, 'POST', '/v1/boards', {
    body: { name },
    ...(token === undefined ? {} : { token }),
  });
  return dataOf(result);
}

/** 快捷创建页面。 */
export async function createPage(
  baseUrl: string,
  boardId: string,
  name: string,
): Promise<Record<string, unknown>> {
  const result = await api(baseUrl, 'POST', `/v1/boards/${boardId}/pages`, { body: { name } });
  return dataOf(result);
}

/** 快捷创建元素（sticky）。 */
export async function createElement(
  baseUrl: string,
  pageId: string,
): Promise<Record<string, unknown>> {
  const result = await api(baseUrl, 'POST', `/v1/pages/${pageId}/elements`, {
    body: { elements: [{ type: 'sticky', position: { x: 10, y: 20 }, size: { width: 100, height: 80 } }] },
  });
  const data = dataOf<{ elements: Record<string, unknown>[] }>(result);
  const first = data.elements[0];
  if (!first) throw new Error('element creation returned no elements');
  return first;
}
