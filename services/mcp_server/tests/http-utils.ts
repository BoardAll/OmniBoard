/**
 * HTTP 传输测试辅助（全部离线、随机端口）：
 *
 * - 使用 `node:http` 直连（`agent: false` → `Connection: close`），
 *   避免 undici 连接池使 `server.close()` 挂起；
 * - `listenRandom` 监听 `127.0.0.1:0` 获取随机端口；
 * - `SseStreamClient` 解析 text/event-stream 并支持事件轮询等待。
 */

import { request as httpRequest, type IncomingMessage, type Server } from 'node:http';
import type { Express } from 'express';

export interface HttpResult {
  status: number;
  headers: NodeJS.Dict<string | string[]>;
  text: string;
}

/** 发起一次完整 HTTP 请求（响应结束后 resolve）。 */
export function httpCall(
  port: number,
  method: string,
  path: string,
  options: { headers?: Record<string, string>; body?: string } = {},
): Promise<HttpResult> {
  return new Promise<HttpResult>((resolve, reject) => {
    const headers: Record<string, string> = { ...options.headers };
    const body = options.body;
    if (body !== undefined) {
      headers['content-length'] = String(Buffer.byteLength(body));
      headers['content-type'] = headers['content-type'] ?? 'application/json';
    }
    const req = httpRequest(
      { host: '127.0.0.1', port, method, path, headers, agent: false },
      (res: IncomingMessage) => {
        const chunks: Buffer[] = [];
        res.on('data', (chunk: Buffer) => chunks.push(chunk));
        res.on('end', () =>
          resolve({
            status: res.statusCode ?? 0,
            headers: res.headers,
            text: Buffer.concat(chunks).toString('utf8'),
          }),
        );
      },
    );
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

/** 在 127.0.0.1 上监听随机端口。 */
export function listenRandom(app: Express): Promise<{ server: Server; port: number }> {
  return new Promise((resolve, reject) => {
    const server = app.listen(0, '127.0.0.1');
    server.once('listening', () => {
      const address = server.address();
      const port = typeof address === 'object' && address !== null ? address.port : 0;
      resolve({ server, port });
    });
    server.once('error', reject);
  });
}

/** 强制销毁所有连接后关闭服务器（测试清理，幂等）。 */
export function closeServer(server: Server): Promise<void> {
  server.closeAllConnections();
  return new Promise<void>((resolve) => {
    server.close(() => resolve());
  });
}

export interface SseEvent {
  event: string;
  data: string;
  /** 原始块文本（注释块如 `: connected` 可据此识别）。 */
  raw: string;
}

function parseSseBlock(raw: string): SseEvent {
  let event = 'message';
  const data: string[] = [];
  for (const line of raw.split('\n')) {
    if (line.startsWith('event:')) event = line.slice('event:'.length).trim();
    else if (line.startsWith('data:')) data.push(line.slice('data:'.length).trimStart());
  }
  return { event, data: data.join('\n'), raw };
}

/** 客户端 SSE 流：后台解析事件，`waitForEvent` 轮询等待。 */
export class SseStreamClient {
  private readonly events: SseEvent[] = [];
  private buffer = '';
  private request: ReturnType<typeof httpRequest> | null = null;

  constructor(port: number, path: string, headers: Record<string, string> = {}) {
    const req = httpRequest(
      {
        host: '127.0.0.1',
        port,
        path,
        method: 'GET',
        headers: { ...headers, accept: 'text/event-stream' },
        agent: false,
      },
      (res: IncomingMessage) => {
        res.setEncoding('utf8');
        res.on('data', (chunk: string) => this.ingest(chunk));
      },
    );
    req.on('error', () => undefined);
    req.end();
    this.request = req;
  }

  private ingest(chunk: string): void {
    this.buffer += chunk;
    let index = this.buffer.indexOf('\n\n');
    while (index !== -1) {
      const raw = this.buffer.slice(0, index);
      this.buffer = this.buffer.slice(index + 2);
      this.events.push(parseSseBlock(raw));
      index = this.buffer.indexOf('\n\n');
    }
  }

  async waitForEvent(predicate: (event: SseEvent) => boolean, timeoutMs = 5000): Promise<SseEvent> {
    const start = Date.now();
    for (;;) {
      const found = this.events.find(predicate);
      if (found) return found;
      if (Date.now() - start > timeoutMs) throw new Error('timed out waiting for SSE event');
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }

  /** 已解析事件快照（调试用）。 */
  snapshot(): readonly SseEvent[] {
    return this.events;
  }

  close(): void {
    this.request?.destroy();
    this.request = null;
  }
}
