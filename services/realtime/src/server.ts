/**
 * realtime 服务主入口（《互动白板实时协同设计文档》§7，M1 完整版 / T1.3 + M2 体验完善 + M3 互动模式）。
 *
 * - express：`GET /healthz` → `{ok:true}`；
 * - Socket.IO：namespace `/board`（连接认证 + M1/M2/M3 事件集，见 rooms.ts / interactive.ts / checkpoint.ts）；
 * - op 环形日志 / 去重 / 水位 / 权限 / 软锁 / 审计：见 oplog.ts / token.ts / audit.ts / roomStore.ts；
 * - 端口：`PORT || 8790`（§7 / D5）。
 *
 * M3 可调参数（options 优先于环境变量，环境变量优先于默认值）：
 * - WB_HOST_TRANSFER_MS：host 转移窗口（默认 0=退出立即移交，§5.14）；
 * - WB_CHECKPOINT_OP_THRESHOLD：checkpoint 触发阈值（默认 500，契约 F）；
 * - WB_CHECKPOINT_TIMEOUT_MS：checkpoint 请求超时（默认 15000，契约 F）；
 * - WB_CHECKPOINT_MAX_PAYLOAD_BYTES：checkpoint payload 上限字节数（默认 10MB，契约 F）。
 *
 * 审计输出（对齐 mcp 模式）：注入（测试 / 嵌入）> `WB_REALTIME_AUDIT_LOG`（JSONL 落盘）> stderr。
 */

import { createServer as createHttpServer } from 'node:http';
import type { Server as HttpServer } from 'node:http';
import { pathToFileURL } from 'node:url';
import express, { type Express } from 'express';
import { Server } from 'socket.io';
import { buildAuditEntry, createAuditSinkFromEnv, type AuditSink } from './audit.js';
import { DEFAULT_OPLOG_CAPACITY } from './oplog.js';
import { attachBoardNamespace } from './rooms.js';
import {
  BoardRoomStore,
  DEFAULT_CHECKPOINT_MAX_PAYLOAD_BYTES,
  DEFAULT_CHECKPOINT_OP_THRESHOLD,
  DEFAULT_CHECKPOINT_TIMEOUT_MS,
  DEFAULT_HOST_TRANSFER_MS,
  DEFAULT_LOCK_SWEEP_INTERVAL_MS,
  DEFAULT_LOCK_TTL_MS,
  DEFAULT_ROOM_TTL_MS,
} from './roomStore.js';
import type { BoardSocketData, ClientToServerEvents, InterServerEvents, ServerToClientEvents } from './types.js';
import { readPositiveIntEnv } from './util.js';

export const DEFAULT_PORT = 8790;

export interface RealtimeServerOptions {
  /** 认证 / 环境变量（默认 process.env；测试注入）。 */
  env?: NodeJS.ProcessEnv;
  /** 审计输出（默认：`WB_REALTIME_AUDIT_LOG` → JSONL 文件；否则 stderr）。 */
  audit?: AuditSink;
  /** 环形日志容量（默认 10k，§10；测试可缩小）。 */
  oplogCapacity?: number;
  /** 空房保留期（默认 10min，§5.14；测试可缩短）。 */
  roomTtlMs?: number;
  /** 软锁 TTL（默认 30s，§5.6 / D2-C；测试可缩短）。 */
  lockTtlMs?: number;
  /** 超时锁扫描间隔（默认 1s；测试可缩短）。 */
  lockSweepIntervalMs?: number;
  /** M3：host 转移窗口（默认 0=立即移交 / WB_HOST_TRANSFER_MS 可配防抖；测试可缩短）。 */
  hostTransferMs?: number;
  /** M3：checkpoint 触发阈值（默认 500 / WB_CHECKPOINT_OP_THRESHOLD；测试可缩小）。 */
  checkpointOpThreshold?: number;
  /** M3：checkpoint 请求超时（默认 15s / WB_CHECKPOINT_TIMEOUT_MS；测试可缩短）。 */
  checkpointTimeoutMs?: number;
  /** M3：checkpoint payload 上限（默认 10MB / WB_CHECKPOINT_MAX_PAYLOAD_BYTES；测试可缩小）。 */
  checkpointMaxPayloadBytes?: number;
}

export interface RealtimeServer {
  app: Express;
  httpServer: HttpServer;
  io: Server<ClientToServerEvents, ServerToClientEvents, InterServerEvents, BoardSocketData>;
  /** 房间存储（参与者 / op 日志 / 软锁 / 模式 / checkpoint / host 转移 / 清理定时器）。 */
  rooms: BoardRoomStore;
  /** 审计 sink（实际使用的那一个）。 */
  audit: AuditSink;
}

export interface StartedRealtimeServer extends RealtimeServer {
  /** 实际监听端口（port 0 → 系统随机分配）。 */
  port: number;
  /** 优雅关闭（幂等）：断开连接 + 清空房间与清理 / 扫描定时器。 */
  close(): Promise<void>;
}

/** 装配 express + Socket.IO（不 listen；供测试与 startRealtimeServer 复用）。 */
export function createRealtimeApp(options: RealtimeServerOptions = {}): RealtimeServer {
  const env = options.env ?? process.env;
  const app = express();
  app.disable('x-powered-by');
  app.get('/healthz', (_req, res) => {
    res.json({ ok: true });
  });

  const audit = options.audit ?? createAuditSinkFromEnv(env);
  const rooms = new BoardRoomStore({
    oplogCapacity: options.oplogCapacity ?? DEFAULT_OPLOG_CAPACITY,
    roomTtlMs: options.roomTtlMs ?? DEFAULT_ROOM_TTL_MS,
    lockTtlMs: options.lockTtlMs ?? DEFAULT_LOCK_TTL_MS,
    lockSweepIntervalMs: options.lockSweepIntervalMs ?? DEFAULT_LOCK_SWEEP_INTERVAL_MS,
    // M3：options > 环境变量 > 默认值。
    hostTransferMs:
      options.hostTransferMs ?? readPositiveIntEnv(env, 'WB_HOST_TRANSFER_MS') ?? DEFAULT_HOST_TRANSFER_MS,
    checkpointOpThreshold:
      options.checkpointOpThreshold ??
      readPositiveIntEnv(env, 'WB_CHECKPOINT_OP_THRESHOLD') ??
      DEFAULT_CHECKPOINT_OP_THRESHOLD,
    checkpointTimeoutMs:
      options.checkpointTimeoutMs ??
      readPositiveIntEnv(env, 'WB_CHECKPOINT_TIMEOUT_MS') ??
      DEFAULT_CHECKPOINT_TIMEOUT_MS,
    checkpointMaxPayloadBytes:
      options.checkpointMaxPayloadBytes ??
      readPositiveIntEnv(env, 'WB_CHECKPOINT_MAX_PAYLOAD_BYTES') ??
      DEFAULT_CHECKPOINT_MAX_PAYLOAD_BYTES,
    onDestroy: (boardId, info) => {
      audit.record(
        buildAuditEntry({
          userId: 'system',
          action: 'room.cleanup',
          target: { type: 'board', id: boardId },
          result: 'success',
          boardId,
          detail: `empty room ttl elapsed; opsDropped=${info.opsDropped}`,
        }),
      );
    },
  });

  const httpServer = createHttpServer(app);
  const io = new Server<ClientToServerEvents, ServerToClientEvents, InterServerEvents, BoardSocketData>(httpServer, {
    // POC：跨源放开，便于 Web 端（T0.2）本地联调；M1 按部署环境收紧。
    cors: { origin: '*' },
  });
  attachBoardNamespace(io, { env, audit, rooms });
  return { app, httpServer, io, rooms, audit };
}

/** 解析监听端口（`PORT || 8790`）；显式配置非法时抛错。 */
export function resolvePort(env: NodeJS.ProcessEnv = process.env): number {
  const raw = env.PORT?.trim();
  if (!raw) return DEFAULT_PORT;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 0 || value > 65535) {
    throw new Error(`Invalid PORT "${raw}" (expected integer 0-65535)`);
  }
  return value;
}

/** 启动监听；port 传 0 时由系统分配随机端口（测试用）。 */
export async function startRealtimeServer(
  port: number = resolvePort(),
  options: RealtimeServerOptions = {},
): Promise<StartedRealtimeServer> {
  const instance = createRealtimeApp(options);
  await new Promise<void>((resolve, reject) => {
    instance.httpServer.once('error', reject);
    instance.httpServer.listen(port, () => resolve());
  });
  const address = instance.httpServer.address();
  const actualPort = typeof address === 'object' && address !== null ? address.port : port;
  console.log(`[realtime] listening on :${actualPort}`);

  let closing: Promise<void> | null = null;
  return {
    ...instance,
    port: actualPort,
    close: () => {
      if (closing) return closing;
      closing = new Promise<void>((resolve) => {
        // socket.io 的 close() 会顺带关闭底层 HTTP server；但 httpServer.close() 会等待残留连接
        // （如客户端 keep-alive）——主动断开全部连接，保证关闭及时（Node >= 18.2）。
        instance.rooms.dispose();
        instance.io.close(() => resolve());
        instance.httpServer.closeAllConnections();
      });
      return closing;
    },
  };
}

/** 进程入口；返回退出码（0 = 正常启动）。 */
export async function main(env: NodeJS.ProcessEnv = process.env): Promise<number> {
  let started: StartedRealtimeServer;
  try {
    started = await startRealtimeServer(resolvePort(env), { env });
  } catch (error) {
    process.stderr.write(`[realtime] fatal: ${error instanceof Error ? error.message : 'unknown error'}\n`);
    return 1;
  }
  const shutdown = (signal: string): void => {
    process.stderr.write(`[realtime] received ${signal}, shutting down\n`);
    void started.close().then(() => process.exit(0));
  };
  process.once('SIGINT', () => shutdown('SIGINT'));
  process.once('SIGTERM', () => shutdown('SIGTERM'));
  return 0;
}

/** 判断是否作为主模块运行（兼容 Windows 盘符大小写差异）。 */
function isMainModule(): boolean {
  const entry = process.argv[1];
  if (entry === undefined || entry.length === 0) return false;
  try {
    return import.meta.url.toLowerCase() === pathToFileURL(entry).href.toLowerCase();
  } catch {
    return false;
  }
}

if (isMainModule()) {
  void main().then((code) => {
    if (code !== 0) process.exit(code);
  });
}
