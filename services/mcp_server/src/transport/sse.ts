/**
 * SSE 传输（Traditional HTTP+SSE，MCP 2024-11-05，§4.3）。
 *
 * 路由：
 * - `GET  /sse`             建立事件流；首先推送 `event: endpoint`，data 为消息回传地址
 *                           （`/messages?sessionId=...`）；
 * - `POST /messages`        客户端发送 JSON-RPC 消息（单条 / 批量），响应经 SSE 推送；
 * - `GET  /healthz`         健康检查（免认证）。
 *
 * 认证：`X-API-Key` / `Bearer`（§9.3）；未认证一律 401。
 * 安全响应头见 `securityHeaders()`（§22.1）。
 */

import express, { type Express } from 'express';
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

export interface SseTransportOptions {
  dispatcher: McpDispatcher;
  sessions: SessionStore;
  authenticator: CompositeAuthenticator;
  audit?: AuditSink;
  logger?: Logger;
  /** SSE 保活间隔（毫秒）；0 关闭（测试用）。默认 25s。 */
  keepAliveMs?: number;
  /** 端点地址前缀（反向代理场景可覆盖），默认空。 */
  endpointBase?: string;
}

export interface SseApp {
  app: Express;
  /** 关闭指定会话（结束事件流并删除会话）。 */
  closeSession(sessionId: string): void;
  /** 关闭全部会话（优雅停机）。 */
  closeAll(): void;
  /** 当前活跃连接数（诊断 / 测试）。 */
  connectionCount(): number;
}

interface SseConnection {
  sessionId: string;
  res: express.Response;
  heartbeat: NodeJS.Timeout | null;
}

export function createSseApp(options: SseTransportOptions): SseApp {
  const audit = options.audit ?? NULL_AUDIT_SINK;
  const logger = options.logger ?? NULL_LOGGER;
  const keepAliveMs = options.keepAliveMs ?? 25_000;
  const endpointBase = options.endpointBase ?? '';
  const connections = new Map<string, SseConnection>();

  const auth = createAuthMiddleware({ authenticator: options.authenticator, transport: 'sse', audit, logger });

  const closeSession = (sessionId: string): void => {
    const connection = connections.get(sessionId);
    if (!connection) return;
    if (connection.heartbeat) clearInterval(connection.heartbeat);
    connections.delete(sessionId);
    options.sessions.delete(sessionId);
    if (!connection.res.writableEnded) connection.res.end();
  };

  const closeAll = (): void => {
    for (const sessionId of [...connections.keys()]) closeSession(sessionId);
  };

  const app = express();
  app.disable('x-powered-by');
  app.use(securityHeaders());

  app.get('/healthz', (_req, res) => {
    sendOk(res, 200, { status: 'ok', transport: 'sse', connections: connections.size });
  });

  app.get('/sse', auth, (req, res) => {
    const principal = principalOf(res);
    const session = options.sessions.create();

    res.status(200);
    res.setHeader('content-type', 'text/event-stream; charset=utf-8');
    res.setHeader('cache-control', 'no-cache, no-transform');
    res.setHeader('connection', 'keep-alive');
    res.flushHeaders();

    const connection: SseConnection = { sessionId: session.id, res, heartbeat: null };
    connections.set(session.id, connection);

    if (keepAliveMs > 0) {
      connection.heartbeat = setInterval(() => {
        if (!res.writableEnded) res.write(': keep-alive\n\n');
      }, keepAliveMs);
      connection.heartbeat.unref();
    }

    const endpoint = `${endpointBase}/messages?sessionId=${encodeURIComponent(session.id)}`;
    res.write(`event: endpoint\ndata: ${endpoint}\n\n`);
    logger.info('SSE session opened', {
      sessionId: session.id,
      userId: principal?.userId ?? 'anonymous',
    });

    res.on('close', () => {
      if (connection.heartbeat) clearInterval(connection.heartbeat);
      connections.delete(session.id);
      options.sessions.delete(session.id);
      logger.info('SSE session closed', { sessionId: session.id });
    });
  });

  app.post(
    '/messages',
    auth,
    express.json({ limit: '4mb' }),
    wrapAsync(async (req, res) => {
      const rawSessionId = req.query['sessionId'];
      const sessionId = typeof rawSessionId === 'string' ? rawSessionId : '';
      if (sessionId.length === 0) {
        sendError(res, 400, 'INVALID_ARGUMENT', 'Missing sessionId query parameter');
        return;
      }
      const connection = connections.get(sessionId);
      if (!connection) {
        sendError(res, 404, 'SESSION_NOT_FOUND', `Unknown or closed session: ${sessionId}`);
        return;
      }

      const principal = principalOf(res);
      const ip = clientIp(req);
      const ctx = {
        sessionId,
        transport: 'sse' as const,
        principal,
        ...(ip !== undefined ? { ip } : {}),
      };
      options.sessions.touch(sessionId);

      const response = await options.dispatcher.handleValue(req.body, ctx);
      if (response !== null && !connection.res.writableEnded) {
        connection.res.write(`event: message\ndata: ${JSON.stringify(response)}\n\n`);
      }
      sendOk(res, 202, { accepted: true });
    }),
  );

  app.use((_req, res) => {
    sendError(res, 404, 'NOT_FOUND', 'Not found');
  });
  app.use(createErrorHandler(logger));

  return {
    app,
    closeSession,
    closeAll,
    connectionCount: () => connections.size,
  };
}
