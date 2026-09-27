/**
 * 传输层冒烟：stdio / SSE / Streamable HTTP。
 * 全部离线：随机端口 + 显式关闭；不访问任何外部服务。
 */

import type { Server } from 'node:http';
import { PassThrough } from 'node:stream';
import { afterEach, describe, expect, it } from 'vitest';
import type { Express } from 'express';
import { StdioTransport } from '../src/transport/stdio.js';
import { createSseApp } from '../src/transport/sse.js';
import { createStreamableHttpApp } from '../src/transport/http.js';
import { closeServer, httpCall, listenRandom, SseStreamClient } from './http-utils.js';
import { AUTH_HEADERS, initializeRequest, TEST_API_KEY, testApiKeyAuthenticator } from './fixtures.js';
import { createFixture, waitFor } from './helpers.js';

const activeServers: Server[] = [];

afterEach(async () => {
  for (const server of activeServers.splice(0)) {
    await closeServer(server);
  }
});

async function serve(app: Express): Promise<number> {
  const { server, port } = await listenRandom(app);
  activeServers.push(server);
  return port;
}

/* ------------------------------------------------------------------ */
/* stdio                                                               */
/* ------------------------------------------------------------------ */

describe('transport: stdio', () => {
  it('换行分隔 JSON → 逐行响应；通知/空行静默；stdout 无协议外内容', async () => {
    const fixture = createFixture();
    const input = new PassThrough();
    const output = new PassThrough();
    const lines: string[] = [];
    let buffer = '';
    output.on('data', (chunk: Buffer | string) => {
      buffer += typeof chunk === 'string' ? chunk : chunk.toString('utf8');
      let index = buffer.indexOf('\n');
      while (index !== -1) {
        lines.push(buffer.slice(0, index));
        buffer = buffer.slice(index + 1);
        index = buffer.indexOf('\n');
      }
    });

    let closed = false;
    const transport = new StdioTransport({
      dispatcher: fixture.dispatcher,
      context: fixture.ctx,
      input,
      output,
      onClose: () => {
        closed = true;
      },
    });
    transport.start();

    input.write(`${JSON.stringify(initializeRequest(1))}\n`);
    input.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`);
    input.write('\n');
    input.write(`${JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' })}\n`);
    input.write('{ this is not json }\n');

    await waitFor(() => lines.length >= 3);
    input.end();
    await waitFor(() => closed);

    // 恰好 3 行响应：initialize、tools/list、解析错误；通知与空行不产生输出。
    expect(lines).toHaveLength(3);

    const initialize = JSON.parse(lines[0] ?? '{}') as {
      id?: number;
      result?: { protocolVersion?: string; serverInfo?: { name?: string } };
    };
    expect(initialize.id).toBe(1);
    expect(initialize.result?.protocolVersion).toBe('2025-06-18');
    expect(initialize.result?.serverInfo?.name).toBe('whiteboard-mcp');

    const tools = JSON.parse(lines[1] ?? '{}') as { id?: number; result?: { tools?: unknown[] } };
    expect(tools.id).toBe(2);
    expect(tools.result?.tools).toHaveLength(113);

    const parseFailure = JSON.parse(lines[2] ?? '{}') as { id?: unknown; error?: { code?: number } };
    expect(parseFailure.id).toBeNull();
    expect(parseFailure.error?.code).toBe(-32700);
  });
});

/* ------------------------------------------------------------------ */
/* SSE（Traditional HTTP+SSE）                                          */
/* ------------------------------------------------------------------ */

describe('transport: SSE', () => {
  function startSseServer(): Promise<{
    sseApp: ReturnType<typeof createSseApp>;
    port: number;
    sessionCount: () => number;
  }> {
    const fixture = createFixture();
    const sseApp = createSseApp({
      dispatcher: fixture.dispatcher,
      sessions: fixture.sessions,
      authenticator: testApiKeyAuthenticator(),
      keepAliveMs: 0,
    });
    return serve(sseApp.app).then((port) => ({
      sseApp,
      port,
      sessionCount: () => fixture.sessions.size,
    }));
  }

  it('healthz 免认证；/sse 无凭据 → 401', async () => {
    const { port } = await startSseServer();

    const health = await httpCall(port, 'GET', '/healthz');
    expect(health.status).toBe(200);
    expect(JSON.parse(health.text)).toMatchObject({ ok: true, data: { status: 'ok', transport: 'sse' } });

    const denied = await httpCall(port, 'GET', '/sse');
    expect(denied.status).toBe(401);
    expect(JSON.parse(denied.text)).toMatchObject({ ok: false, error: { code: 'UNAUTHENTICATED' } });
    expect(denied.text).not.toContain(TEST_API_KEY);

    const deniedPost = await httpCall(port, 'POST', '/messages?sessionId=x', { body: '{}' });
    expect(deniedPost.status).toBe(401);
  });

  it('endpoint 事件 → POST /messages → SSE 回推 JSON-RPC 响应', async () => {
    const { sseApp, port, sessionCount } = await startSseServer();
    const sessionsBefore = sessionCount();
    const stream = new SseStreamClient(port, '/sse', AUTH_HEADERS);
    try {
      // 1) 建流：首个事件为 endpoint（消息回传地址）。
      const endpointEvent = await stream.waitForEvent((event) => event.event === 'endpoint');
      expect(endpointEvent.data).toContain('/messages?sessionId=');
      const sessionId = decodeURIComponent(endpointEvent.data.split('sessionId=')[1] ?? '');
      expect(sessionId.length).toBeGreaterThan(0);
      expect(sessionCount()).toBe(sessionsBefore + 1);

      // 2) initialize：POST 接受 202，响应经 SSE 推送。
      const posted = await httpCall(port, 'POST', `/messages?sessionId=${encodeURIComponent(sessionId)}`, {
        headers: AUTH_HEADERS,
        body: JSON.stringify(initializeRequest(1)),
      });
      expect(posted.status).toBe(202);
      expect(JSON.parse(posted.text)).toMatchObject({ ok: true, data: { accepted: true } });

      const messageEvent = await stream.waitForEvent(
        (event) => event.event === 'message' && event.data.includes('"id":1'),
      );
      const initializeResponse = JSON.parse(messageEvent.data) as {
        result?: { protocolVersion?: string };
      };
      expect(initializeResponse.result?.protocolVersion).toBe('2025-06-18');

      // 3) tools/list 同样经 SSE 回推。
      const listed = await httpCall(port, 'POST', `/messages?sessionId=${encodeURIComponent(sessionId)}`, {
        headers: AUTH_HEADERS,
        body: JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' }),
      });
      expect(listed.status).toBe(202);
      const listEvent = await stream.waitForEvent(
        (event) => event.event === 'message' && event.data.includes('"id":2'),
      );
      const listResponse = JSON.parse(listEvent.data) as { result?: { tools?: unknown[] } };
      expect(listResponse.result?.tools).toHaveLength(113);

      // 4) 未知 / 缺失会话。
      const unknownSession = await httpCall(port, 'POST', '/messages?sessionId=sess_missing', {
        headers: AUTH_HEADERS,
        body: '{}',
      });
      expect(unknownSession.status).toBe(404);
      expect(JSON.parse(unknownSession.text)).toMatchObject({ ok: false, error: { code: 'SESSION_NOT_FOUND' } });

      const missingSession = await httpCall(port, 'POST', '/messages', { headers: AUTH_HEADERS, body: '{}' });
      expect(missingSession.status).toBe(400);

      // 5) 服务端主动关闭会话 → 连接归零、会话数回落到基线。
      expect(sseApp.connectionCount()).toBe(1);
      sseApp.closeSession(sessionId);
      await waitFor(() => sseApp.connectionCount() === 0 && sessionCount() === sessionsBefore);
    } finally {
      stream.close();
    }
  });
});

/* ------------------------------------------------------------------ */
/* Streamable HTTP                                                     */
/* ------------------------------------------------------------------ */

describe('transport: Streamable HTTP', () => {
  function startHttpServer(): Promise<{
    httpApp: ReturnType<typeof createStreamableHttpApp>;
    port: number;
  }> {
    const fixture = createFixture();
    const httpApp = createStreamableHttpApp({
      dispatcher: fixture.dispatcher,
      sessions: fixture.sessions,
      authenticator: testApiKeyAuthenticator(),
      keepAliveMs: 0,
    });
    return serve(httpApp.app).then((port) => ({ httpApp, port }));
  }

  it('healthz；POST /mcp 无凭据 → 401；PUT → 405', async () => {
    const { port } = await startHttpServer();

    const health = await httpCall(port, 'GET', '/healthz');
    expect(health.status).toBe(200);
    expect(JSON.parse(health.text)).toMatchObject({ ok: true, data: { status: 'ok', transport: 'http' } });

    const denied = await httpCall(port, 'POST', '/mcp', { body: JSON.stringify(initializeRequest(1)) });
    expect(denied.status).toBe(401);
    expect(JSON.parse(denied.text)).toMatchObject({ ok: false, error: { code: 'UNAUTHENTICATED' } });

    const methodNotAllowed = await httpCall(port, 'PUT', '/mcp', { headers: AUTH_HEADERS, body: '{}' });
    expect(methodNotAllowed.status).toBe(405);
    expect(JSON.parse(methodNotAllowed.text)).toMatchObject({ ok: false, error: { code: 'NOT_SUPPORTED' } });
  });

  it('initialize 建会话 → 通知 202 → tools/list 200 → GET 流 → DELETE 终止', async () => {
    const { httpApp, port } = await startHttpServer();
    const sessionsBefore = httpApp.sessionCount();

    // 1) initialize（无会话头）→ 200 + Mcp-Session-Id。
    const init = await httpCall(port, 'POST', '/mcp', {
      headers: AUTH_HEADERS,
      body: JSON.stringify(initializeRequest(1)),
    });
    expect(init.status).toBe(200);
    const sessionId = init.headers['mcp-session-id'];
    expect(typeof sessionId).toBe('string');
    const initBody = JSON.parse(init.text) as { id?: number; result?: { protocolVersion?: string } };
    expect(initBody.id).toBe(1);
    expect(initBody.result?.protocolVersion).toBe('2025-06-18');
    expect(httpApp.sessionCount()).toBe(sessionsBefore + 1);

    const sessionHeaders = { ...AUTH_HEADERS, 'mcp-session-id': sessionId as string };

    // 2) 纯通知 → 202 空体。
    const note = await httpCall(port, 'POST', '/mcp', {
      headers: sessionHeaders,
      body: JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }),
    });
    expect(note.status).toBe(202);
    expect(note.text).toBe('');

    // 3) tools/list → 200。
    const list = await httpCall(port, 'POST', '/mcp', {
      headers: sessionHeaders,
      body: JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' }),
    });
    expect(list.status).toBe(200);
    expect((JSON.parse(list.text) as { result?: { tools?: unknown[] } }).result?.tools).toHaveLength(113);

    // 4) 未带头且非 initialize → 400；未知会话 → 404。
    const noSession = await httpCall(port, 'POST', '/mcp', {
      headers: AUTH_HEADERS,
      body: JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'tools/list' }),
    });
    expect(noSession.status).toBe(400);
    expect(JSON.parse(noSession.text)).toMatchObject({ ok: false, error: { code: 'INVALID_ARGUMENT' } });

    const ghost = await httpCall(port, 'POST', '/mcp', {
      headers: { ...AUTH_HEADERS, 'mcp-session-id': 'sess_ghost' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 4, method: 'ping' }),
    });
    expect(ghost.status).toBe(404);
    expect(JSON.parse(ghost.text)).toMatchObject({ ok: false, error: { code: 'SESSION_NOT_FOUND' } });

    // 5) GET /mcp 建立通知流；无会话头 → 400。
    const streamHeaderless = await httpCall(port, 'GET', '/mcp', { headers: AUTH_HEADERS });
    expect(streamHeaderless.status).toBe(400);

    const stream = new SseStreamClient(port, '/mcp', sessionHeaders);
    try {
      await stream.waitForEvent((event) => event.raw.includes('connected'));

      // 6) DELETE → 204，会话终止；后续请求 404。
      const del = await httpCall(port, 'DELETE', '/mcp', { headers: sessionHeaders });
      expect(del.status).toBe(204);
      await waitFor(() => httpApp.sessionCount() === sessionsBefore);

      const afterDelete = await httpCall(port, 'POST', '/mcp', {
        headers: sessionHeaders,
        body: JSON.stringify({ jsonrpc: '2.0', id: 5, method: 'ping' }),
      });
      expect(afterDelete.status).toBe(404);
    } finally {
      stream.close();
    }
  });
});
