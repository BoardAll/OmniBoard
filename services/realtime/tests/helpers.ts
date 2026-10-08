/**
 * 测试公共装配（全部离线）：
 * - 自起自停 realtime 服务（随机端口，避免与本地 8790 冲突；默认注入 MemoryAuditSink 避免 stderr 噪音，
 *   设置 `WB_REALTIME_AUDIT_LOG` 时改为服务端 JSONL 落盘，供审计落盘用例）；
 * - socket.io-client 连接辅助（匿名 / JWT）；ack / 事件 / 多参事件 / 反例 / 断连等待辅助；
 * - JWT 签发辅助（role / 过期）；审计文件读取辅助。
 */

import { readFileSync } from 'node:fs';
import { expect } from 'vitest';
import jwt from 'jsonwebtoken';
import { io as createClient, type Socket as ClientSocket } from 'socket.io-client';
import { MemoryAuditSink, type AuditEntry, type AuditSink } from '../src/audit.js';
import { startRealtimeServer, type RealtimeServerOptions, type StartedRealtimeServer } from '../src/server.js';
import type {
  BoardErrorPayload,
  BoardJoinAck,
  BoardJoinPayload,
  BoardRole,
  BoardSessionPayload,
  ClientToServerEvents,
  Op,
  ServerToClientEvents,
} from '../src/types.js';

export type TestClient = ClientSocket<ServerToClientEvents, ClientToServerEvents>;

/** 测试服务句柄：自起（随机端口）自停（幂等）。 */
export type TestServerHandle = StartedRealtimeServer;

/** 测试服务选项（env 由 startTestServer 第一参传入）。 */
export type TestServerOptions = Omit<RealtimeServerOptions, 'env'>;

/** 连接 auth 载荷（透传 socket.handshake.auth）。 */
export interface TestAuth {
  token?: string;
  boardId?: string;
  clientVersion?: string;
}

export interface TestContext {
  server: TestServerHandle;
  connect(auth?: TestAuth): TestClient;
  close(): Promise<void>;
}

/** 默认测试环境：非 production（可覆盖，如置 WB_JWT_SECRET: undefined 模拟未配置密钥）。
 *  默认注入 MemoryAuditSink；仅当显式设置 WB_REALTIME_AUDIT_LOG 且未注入时交给服务端落盘。 */
export async function startTestServer(
  env: NodeJS.ProcessEnv = {},
  options: TestServerOptions = {},
): Promise<TestServerHandle> {
  const fullEnv: NodeJS.ProcessEnv = { NODE_ENV: 'test', ...env };
  const audit: AuditSink | undefined =
    options.audit ?? (fullEnv['WB_REALTIME_AUDIT_LOG'] ? undefined : new MemoryAuditSink());
  return startRealtimeServer(0, { ...options, env: fullEnv, audit });
}

export async function createTestContext(
  env: NodeJS.ProcessEnv = {},
  options: TestServerOptions = {},
): Promise<TestContext> {
  const server = await startTestServer(env, options);
  const clients: TestClient[] = [];
  return {
    server,
    connect: (auth: TestAuth = {}) => {
      const client = createClient(`http://127.0.0.1:${server.port}/board`, {
        transports: ['websocket'],
        forceNew: true,
        reconnection: false,
        auth,
      });
      clients.push(client);
      return client;
    },
    close: async () => {
      for (const client of clients) client.disconnect();
      await server.close();
    },
  };
}

/** 连接并等待身份回执（board:session）。 */
export async function connectAndWait(
  ctx: TestContext,
  auth: TestAuth = {},
): Promise<{ client: TestClient; session: BoardSessionPayload }> {
  const client = ctx.connect(auth);
  const sessionPromise = waitForEvent<BoardSessionPayload>(client, 'board:session');
  await waitForConnect(client);
  return { client, session: await sessionPromise };
}

export function waitForConnect(socket: TestClient, timeoutMs = 5000): Promise<void> {
  if (socket.connected) return Promise.resolve();
  return new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.off('connect', onConnect);
      socket.off('connect_error', onError);
      reject(new Error('timeout waiting for connect'));
    }, timeoutMs);
    const onConnect = (): void => {
      clearTimeout(timer);
      socket.off('connect_error', onError);
      resolve();
    };
    const onError = (error: Error): void => {
      clearTimeout(timer);
      socket.off('connect', onConnect);
      reject(error);
    };
    socket.once('connect', onConnect);
    socket.once('connect_error', onError);
  });
}

export function waitForConnectError(socket: TestClient, timeoutMs = 5000): Promise<Error> {
  return new Promise<Error>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout waiting for connect_error')), timeoutMs);
    socket.once('connect_error', (error) => {
      clearTimeout(timer);
      resolve(error);
    });
  });
}

export function waitForEvent<T>(socket: TestClient, event: string, timeoutMs = 5000): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let timer: ReturnType<typeof setTimeout>;
    const handler = (payload: T): void => {
      clearTimeout(timer);
      resolve(payload);
    };
    timer = setTimeout(() => {
      socket.off(event as never, handler as never);
      reject(new Error(`timeout waiting for "${event}"`));
    }, timeoutMs);
    socket.once(event as never, handler as never);
  });
}

/** 等待多参事件首次触发，返回全部参数（如 board:ops 的 [ops, meta]）。 */
export function waitForArgs<T extends unknown[]>(socket: TestClient, event: string, timeoutMs = 5000): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let timer: ReturnType<typeof setTimeout>;
    const handler = (...args: T): void => {
      clearTimeout(timer);
      resolve(args);
    };
    timer = setTimeout(() => {
      socket.off(event as never, handler as never);
      reject(new Error(`timeout waiting for "${event}" args`));
    }, timeoutMs);
    socket.once(event as never, handler as never);
  });
}

/** 收集某事件在窗口期内的全部触发（配合 sleep / waitFor 做计数断言；记得 stop）。 */
export function collectArgs<T extends unknown[]>(
  socket: TestClient,
  event: string,
): { readonly calls: T[]; stop(): void } {
  const calls: T[] = [];
  const handler = (...args: T): void => {
    calls.push(args);
  };
  socket.on(event as never, handler as never);
  return {
    calls,
    stop: () => socket.off(event as never, handler as never),
  };
}

/** 断言在窗口期内未收到指定事件（用于「排除发送者 / 非目标用户」反例）。 */
export async function expectNoEvent(socket: TestClient, event: string, windowMs = 150): Promise<void> {
  let received = false;
  const handler = (): void => {
    received = true;
  };
  socket.on(event as never, handler as never);
  try {
    await sleep(windowMs);
  } finally {
    socket.off(event as never, handler as never);
  }
  expect(received).toBe(false);
}

/** 等待连接被（服务端）断开，返回 Socket.IO 断开原因。 */
export function waitForDisconnect(socket: TestClient, timeoutMs = 5000): Promise<string> {
  if (socket.disconnected) return Promise.resolve('already-disconnected');
  return new Promise<string>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout waiting for disconnect')), timeoutMs);
    socket.once('disconnect', (reason) => {
      clearTimeout(timer);
      resolve(reason);
    });
  });
}

/** 轮询等待条件成立（默认 5s 超时 / 10ms 间隔）。 */
export async function waitFor(predicate: () => boolean, timeoutMs = 5000, intervalMs = 10): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('timeout waiting for condition');
    await sleep(intervalMs);
  }
}

/** 带 ack 的 emit（ack 超时保护）。 */
export function emitAck<T>(socket: TestClient, event: string, payload: unknown, timeoutMs = 5000): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`ack timeout for "${event}"`)), timeoutMs);
    const driver = socket as unknown as {
      emit: (ev: string, data: unknown, ack: (response: T) => void) => void;
    };
    driver.emit(event, payload, (response: T) => {
      clearTimeout(timer);
      resolve(response);
    });
  });
}

/** 便捷：join 并返回 ack（需要先挂 joined / participants 监听时请自行先监听再 emit）。 */
export function joinBoard(
  client: TestClient,
  boardId: string,
  extra: Omit<BoardJoinPayload, 'boardId'> = {},
): Promise<BoardJoinAck> {
  return emitAck<BoardJoinAck>(client, 'board:join', { boardId, ...extra });
}

/** 构造合法测试 op（value/timestamp/origin 可覆盖）。 */
export function makeOp(actor: string, seq: number, overrides: Partial<Op> = {}): Op {
  return {
    actor,
    seq,
    key: `k-${actor}-${seq}`,
    value: { n: seq },
    timestamp: 1_726_000_000_000 + seq,
    origin: 'test',
    ...overrides,
  };
}

/** 取失败 ack 的 error（非 BoardAckFailure 时抛错；测试便捷 + 运行时断言）。 */
export function failureError(ack: unknown): BoardErrorPayload {
  if (typeof ack === 'object' && ack !== null) {
    const candidate = ack as { ok?: unknown; error?: unknown };
    if (candidate.ok === false && typeof candidate.error === 'object' && candidate.error !== null) {
      return candidate.error as BoardErrorPayload;
    }
  }
  throw new Error(`expected BoardAckFailure ack, got ${JSON.stringify(ack)}`);
}

/** 断言 server 使用 MemoryAuditSink 并取回（默认测试装配）。 */
export function memoryAuditOf(handle: TestServerHandle): MemoryAuditSink {
  const sink = handle.audit;
  if (!(sink instanceof MemoryAuditSink)) throw new Error('expected server audit sink to be MemoryAuditSink');
  return sink;
}

/** 读取 JSONL 审计文件（每行一个 AuditEntry）。 */
export function readAuditEntries(filePath: string): AuditEntry[] {
  const content = readFileSync(filePath, 'utf8');
  return content
    .split('\n')
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line) as AuditEntry);
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export interface SignTestTokenOptions {
  /** role claim（白名单；缺省不携带 → 服务端回落 Participant）。 */
  role?: BoardRole;
  /** 签发已过期 token（expiresIn '-1s'）。 */
  expired?: boolean;
}

/** 签发 HS256 测试 token（sub = userId；可选 role / 过期）。 */
export function signTestToken(
  userId: string,
  secretOrOptions: string | SignTestTokenOptions = 'test-secret',
  maybeOptions: SignTestTokenOptions = {},
): string {
  const secret = typeof secretOrOptions === 'string' ? secretOrOptions : 'test-secret';
  const options = typeof secretOrOptions === 'string' ? maybeOptions : secretOrOptions;
  const claims: Record<string, unknown> = {};
  if (options.role !== undefined) claims['role'] = options.role;
  const signOptions: jwt.SignOptions = { algorithm: 'HS256', subject: userId };
  if (options.expired) signOptions.expiresIn = '-1s';
  return jwt.sign(claims, secret, signOptions);
}
