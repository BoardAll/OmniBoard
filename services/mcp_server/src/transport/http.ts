/**
 * Streamable HTTP 传输（MCP 2025-03-26 / 2025-06-18，§4.4）。
 *
 * 单端点 `/mcp`：
 * - `POST`   客户端消息入口。无 `Mcp-Session-Id` 头时仅接受 `initialize` 请求
 *            （建会话并在响应头返回 `Mcp-Session-Id`）；纯通知返回 202 空体；
 *            请求返回 200 + JSON-RPC 响应；
 * - `GET`    携带 `Mcp-Session-Id` 建立 SSE 流（接收服务端通知）；
 * - `DELETE` 携带 `Mcp-Session-Id` 终止会话（204）。
 *
 * 认证：`X-API-Key` / `Bearer`（§9.3）；安全响应头见 `securityHeaders()`（§22.1）。
 */

import express, { type Express, type Response } from 'express';
import type { McpDispatcher } from '../dispatcher.js';
import type { SessionStore } from '../session.js';
import type { CompositeAuthenticator } from '../auth/index.js';
import {
  clientIp,
  createAuthMiddleware,
  createErrorHandler,
  principalOf,
  securityHeaders,
  sendError,
  sendOk,
  wrapAsync,
} from './shared.js';
import { NULL_AUDIT_SINK, type AuditSink } from '../audit.js';
import { NULL_LOGGER, type Logger } from '../log.js';

export interface StreamableHttpTransportOptions {
  dispatcher: McpDispatcher;
  sessions: SessionStore;
  authenticator: CompositeAuthenticator;
  audit?: AuditSink;
  logger?: Logger;
  /** GET SSE 流保活间隔（毫秒）；0 关闭（测试用）。默认 25s。 */
  keepAliveMs?: number;
}

export interface StreamableHttpApp {
  app: Express;
  /** 关闭会话（结束其 GET 流并删除会话记录）。 */
  closeSession(sessionId: string): void;
  /** 关闭全部会话（优雅停机）。 */
  closeAll(): void;
  /** 当前会话数（诊断 / 测试）。 */
  sessionCount(): number;
}

const SESSION_HEADER = 'mcp-session-id';

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** 无会话头时仅允许 initialize 请求（单条、带 id）。 */
function isInitializeRequest(body: unknown): boolean {
  return isRecord(body) && body['method'] === 'initialize' && 'id' in body;
}

function headerSessionId(raw: string | string[] | undefined): string | null {
  if (typeof raw === 'string' && raw.trim().length > 0) return raw.trim();
  if (Array.isArray(raw) && raw.length > 0 && typeof raw[0] === 'string') return raw[0].trim();
  return null;
}

export function createStreamableHttpApp(options: StreamableHttpTransportOptions): StreamableHttpApp {
  const audit = options.audit ?? NULL_AUDIT_SINK;
  const logger = options.logger ?? NULL_LOGGER;
  const keepAliveMs = options.keepAliveMs ?? 25_000;

  const streams = new Map<string, { res: Response; heartbeat: NodeJS.Timeout | null }>();
  const auth = createAuthMiddleware({ authenticator: options.authenticator, transport: 'http', audit, logger });

  const closeSession = (sessionId: string): void => {
    const stream = streams.get(sessionId);
    if (stream) {
      if (stream.heartbeat) clearInterval(stream.heartbeat);
      streams.delete(sessionId);
      if (!stream.res.writableEnded) stream.res.end();
    }
    options.sessions.delete(sessionId);
  };

  const closeAll = (): void => {
    for (const sessionId of [...streams.keys()]) closeSession(sessionId);
  };

  const app = express();
  app.disable('x-powered-by');
  app.use(securityHeaders());

  app.get('/healthz', (_req, res) => {
    sendOk(res, 200, { status: 'ok', transport: 'http', sessions: options.sessions.size });
  });

  app.post(
    '/mcp',
    auth,
    express.json({ limit: '4mb' }),
    wrapAsync(async (req, res) => {
      const body: unknown = req.body;
      const sessionHeader = headerSessionId(req.headers[SESSION_HEADER]);
      const principal = principalOf(res);
      const ip = clientIp(req);

      let sessionId: string;
      let createdNew = false;
      if (sessionHeader) {
        if (!options.sessions.get(sessionHeader)) {
          sendError(res, 404, 'SESSION_NOT_FOUND', `Unknown or closed session: ${sessionHeader}`);
          return;
        }
        sessionId = sessionHeader;
      } else {
        if (!isInitializeRequest(body)) {
          sendError(
            res,
            400,
            'INVALID_ARGUMENT',
            'Missing Mcp-Session-Id header: only initialize requests may create a new session',
          );
          return;
        }
        sessionId = options.sessions.create().id;
        createdNew = true;
        res.setHeader('Mcp-Session-Id', sessionId);
      }

      const ctx = {
        sessionId,
        transport: 'http' as const,
        principal,
        ...(ip !== undefined ? { ip } : {}),
      };
      options.sessions.touch(sessionId);

      const response = await options.dispatcher.handleValue(body, ctx);
      if (createdNew) {
        logger.info('Streamable HTTP session opened', {
          sessionId,
          userId: principal?.userId ?? 'anonymous',
        });
      }
      if (response === null) {
        // 纯通知：202 + 空体（协议规定）。
        res.status(202).end();
        return;
      }
      res.status(200).json(response);
    }),
  );

  app.get('/mcp', auth, (req, res) => {
    const sessionId = headerSessionId(req.headers[SESSION_HEADER]);
    if (!sessionId) {
      sendError(res, 400, 'INVALID_ARGUMENT', 'Missing Mcp-Session-Id header');
      return;
    }
    if (!options.sessions.get(sessionId)) {
      sendError(res, 404, 'SESSION_NOT_FOUND', `Unknown or closed session: ${sessionId}`);
      return;
    }

    res.status(200);
    res.setHeader('content-type', 'text/event-stream; charset=utf-8');
    res.setHeader('cache-control', 'no-cache, no-transform');
    res.setHeader('connection', 'keep-alive');
    res.flushHeaders();

    const entry = { res, heartbeat: null as NodeJS.Timeout | null };
    streams.set(sessionId, entry);
    if (keepAliveMs > 0) {
      entry.heartbeat = setInterval(() => {
        if (!res.writableEnded) res.write(': keep-alive\n\n');
      }, keepAliveMs);
      entry.heartbeat.unref();
    }
    res.write(': connected\n\n');

    res.on('close', () => {
      if (entry.heartbeat) clearInterval(entry.heartbeat);
      streams.delete(sessionId);
    });
  });

  app.delete('/mcp', auth, (req, res) => {
    const sessionId = headerSessionId(req.headers[SESSION_HEADER]);
    if (!sessionId) {
      sendError(res, 400, 'INVALID_ARGUMENT', 'Missing Mcp-Session-Id header');
      return;
    }
    if (!options.sessions.get(sessionId)) {
      sendError(res, 404, 'SESSION_NOT_FOUND', `Unknown or closed session: ${sessionId}`);
      return;
    }
    closeSession(sessionId);
    logger.info('Streamable HTTP session terminated', { sessionId });
    res.status(204).end();
  });

  app.all('/mcp', (_req, res) => {
    sendError(res, 405, 'NOT_SUPPORTED', 'Method not allowed: use POST / GET / DELETE');
  });
  app.use((_req, res) => {
    sendError(res, 404, 'NOT_FOUND', 'Not found');
  });
  app.use(createErrorHandler(logger));

  return {
    app,
    closeSession,
    closeAll,
    sessionCount: () => options.sessions.size,
  };
}
