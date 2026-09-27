/**
 * MCP Server 主入口（《MCP_Server详细设计》§4.1 / §4.2）。
 *
 * 装配顺序：日志 → 认证（环境变量）→ 会话/审计 → 工具执行器（services/api 桥接）
 * → 资源/提示 → 分发器 → 传输选择（stdio / SSE / Streamable HTTP）。
 *
 * 传输选择：
 * - CLI：`--transport stdio|sse|http`（别名 `streamable-http`）；
 * - 环境变量：`WB_MCP_TRANSPORT`（默认 stdio）。
 *
 * 安全默认：
 * - HTTP 传输未配置任何凭据（WB_API_KEYS / WB_JWT_SECRET）时拒绝启动，
 *   除非显式 `--allow-anonymous`（开发模式）；
 * - stdio 无 `WB_MCP_API_KEY` 时进入本地信任模式（全 Scope，仅本机进程）；
 * - 请求级速率限制默认 1000 请求/分钟（§9.6），可用 `WB_MCP_RATE_LIMIT_PER_MINUTE` 配置；
 * - 凭据仅从环境变量读取，不落盘、不打日志。
 */

import type { Server } from 'node:http';
import { pathToFileURL } from 'node:url';
import { createStderrLogger } from './log.js';
import {
  createLocalPrincipal,
  loadAuthFromEnv,
  TrustedLocalAuthenticator,
  type CompositeAuthenticator,
} from './auth/index.js';
import { AuthError, type Principal } from './auth/types.js';
import { RateLimiter } from './auth/rateLimit.js';
import { SessionStore } from './session.js';
import { StderrAuditSink } from './audit.js';
import { ToolExecutor } from './tools/executor.js';
import { createDefaultInvoker } from './tools/bridge.js';
import { TOOL_CATALOG } from './tools/registry.js';
import { createDefaultResourceReader, ResourceRegistry } from './resources/registry.js';
import { PromptRegistry } from './prompts/registry.js';
import { McpDispatcher } from './dispatcher.js';
import { StdioTransport } from './transport/stdio.js';
import { createSseApp } from './transport/sse.js';
import { createStreamableHttpApp } from './transport/http.js';
import { SERVER_INFO } from './protocol/initialize.js';

export const DEFAULT_PORT = 8788;
export const DEFAULT_HOST = '127.0.0.1';
/** stdio 为进程级单会话，使用固定 id。 */
export const STDIO_SESSION_ID = 'stdio';

export type TransportName = 'stdio' | 'sse' | 'http';

export interface ServerOptions {
  transport: TransportName;
  host: string;
  port: number;
  /** services/api 基础地址（工具桥接 / 资源读取）；null = 未配置。 */
  apiBaseUrl: string | null;
  /** 桥接出站凭据（WB_API_KEY）；null = 未配置。 */
  apiKey: string | null;
  /** stdio 入站客户端身份（WB_MCP_API_KEY）；null = 本地信任。 */
  mcpApiKey: string | null;
  /** 预置白板范围（WB_BOARD_ID / --board，可重复）。 */
  boards: string[];
  logLevel: 'debug' | 'info' | 'warn' | 'error';
  /** 显式允许 HTTP 免认证（开发模式；默认关闭）。 */
  allowAnonymous: boolean;
}

/** 配置错误：进程应以非零码退出（main 负责打印）。 */
export class ServerConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ServerConfigError';
  }
}

export type ParsedInvocation =
  | { kind: 'run'; options: ServerOptions }
  | { kind: 'help' }
  | { kind: 'version' };

const LOG_LEVELS = ['debug', 'info', 'warn', 'error'] as const;

function envValue(env: NodeJS.ProcessEnv, key: string): string | null {
  const value = env[key];
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function parseBoolean(raw: string | null): boolean {
  if (!raw) return false;
  return ['1', 'true', 'yes', 'on'].includes(raw.toLowerCase());
}

/** 解析正整数环境变量；缺省 null；非法抛 ServerConfigError。 */
function parsePositiveInt(env: NodeJS.ProcessEnv, key: string): number | null {
  const raw = envValue(env, key);
  if (raw === null) return null;
  const value = Number(raw);
  if (!Number.isInteger(value) || value <= 0) {
    throw new ServerConfigError(`Invalid ${key} "${raw}" (expected a positive integer)`);
  }
  return value;
}

function splitBoards(raw: string | null): string[] {
  if (!raw) return [];
  return raw.split(/[,\s]+/).filter((value) => value.length > 0);
}

function normaliseTransport(raw: string): TransportName {
  switch (raw.toLowerCase()) {
    case 'stdio':
      return 'stdio';
    case 'sse':
      return 'sse';
    case 'http':
    case 'streamable-http':
    case 'streamable_http':
    case 'streamablehttp':
      return 'http';
    default:
      throw new ServerConfigError(`Unsupported transport "${raw}" (expected: stdio | sse | http)`);
  }
}

function normaliseLogLevel(raw: string): ServerOptions['logLevel'] {
  const level = raw.toLowerCase();
  if (!(LOG_LEVELS as readonly string[]).includes(level)) {
    throw new ServerConfigError(`Unsupported log level "${raw}" (expected: ${LOG_LEVELS.join(' | ')})`);
  }
  return level as ServerOptions['logLevel'];
}

/**
 * 解析 CLI 参数与环境变量（CLI 优先）。
 * 纯函数，便于测试；`--help` / `--version` 返回标记而非抛错。
 */
export function parseServerOptions(
  argv: readonly string[],
  env: NodeJS.ProcessEnv = process.env,
): ParsedInvocation {
  let transportRaw = envValue(env, 'WB_MCP_TRANSPORT') ?? 'stdio';
  let portRaw = envValue(env, 'WB_MCP_PORT') ?? String(DEFAULT_PORT);
  let host = envValue(env, 'WB_MCP_HOST') ?? DEFAULT_HOST;
  let apiBaseUrl = envValue(env, 'WB_API_BASE_URL');
  const apiKey = envValue(env, 'WB_API_KEY');
  const mcpApiKey = envValue(env, 'WB_MCP_API_KEY');
  let boardsRaw = envValue(env, 'WB_BOARD_ID');
  let logLevelRaw = envValue(env, 'WB_MCP_LOG_LEVEL') ?? 'info';
  let allowAnonymous = parseBoolean(envValue(env, 'WB_MCP_ALLOW_ANONYMOUS'));

  const args = [...argv];
  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === undefined || token.length === 0) continue;

    const equalsIndex = token.indexOf('=');
    const flag = equalsIndex === -1 ? token : token.slice(0, equalsIndex);
    const inlineValue = equalsIndex === -1 ? undefined : token.slice(equalsIndex + 1);

    const readValue = (name: string): string => {
      if (inlineValue !== undefined) return inlineValue;
      index += 1;
      const next = args[index];
      if (next === undefined) throw new ServerConfigError(`Missing value for ${name}`);
      return next;
    };

    switch (flag) {
      case '--help':
      case '-h':
        return { kind: 'help' };
      case '--version':
      case '-v':
        return { kind: 'version' };
      case '--transport':
        transportRaw = readValue('--transport');
        break;
      case '--port':
        portRaw = readValue('--port');
        break;
      case '--host':
        host = readValue('--host');
        break;
      case '--api-base-url':
        apiBaseUrl = readValue('--api-base-url');
        break;
      case '--board':
      case '--board-id': {
        const board = readValue('--board');
        boardsRaw = boardsRaw ? `${boardsRaw},${board}` : board;
        break;
      }
      case '--log-level':
        logLevelRaw = readValue('--log-level');
        break;
      case '--allow-anonymous':
        allowAnonymous = true;
        break;
      default:
        throw new ServerConfigError(`Unknown argument: ${flag}`);
    }
  }

  const port = Number(portRaw);
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new ServerConfigError(`Invalid port "${portRaw}" (expected integer 0-65535)`);
  }

  return {
    kind: 'run',
    options: {
      transport: normaliseTransport(transportRaw),
      host,
      port,
      apiBaseUrl,
      apiKey,
      mcpApiKey,
      boards: splitBoards(boardsRaw),
      logLevel: normaliseLogLevel(logLevelRaw),
      allowAnonymous,
    },
  };
}

/** `--help` 输出。 */
export function renderHelp(): string {
  return [
    `${SERVER_INFO.name} ${SERVER_INFO.version} — 白板 MCP Server`,
    '',
    '用法: whiteboard-mcp [--transport stdio|sse|http] [--port <n>] [--host <addr>] [--board <id>]...',
    '                        [--api-base-url <url>] [--log-level debug|info|warn|error]',
    '                        [--allow-anonymous] [--help] [--version]',
    '',
    '环境变量:',
    '  WB_MCP_TRANSPORT       传输（stdio | sse | http，默认 stdio）',
    '  WB_MCP_PORT            HTTP 监听端口（默认 8788）',
    '  WB_MCP_HOST            HTTP 监听地址（默认 127.0.0.1）',
    '  WB_API_BASE_URL        services/api 基础地址（工具执行 / 资源读取桥接）',
    '  WB_API_KEY             桥接出站凭据（不落日志）',
    '  WB_MCP_API_KEY         stdio 客户端身份（缺失 = 本地信任模式）',
    '  WB_API_KEYS            HTTP 入站 API Key 表（JSON）',
    '  WB_JWT_SECRET / WB_JWT_PUBLIC_KEY    OAuth/JWT 校验材料',
    '  WB_BOARD_ID            预置白板范围（逗号分隔）',
    '  WB_MCP_LOG_LEVEL       日志级别（默认 info）',
    '  WB_MCP_RATE_LIMIT_PER_MINUTE  请求级速率限制（默认 1000 请求/分钟）',
    '  WB_MCP_ALLOW_ANONYMOUS 置 1 允许 HTTP 免认证（仅开发）',
    '',
    '示例:',
    '  whiteboard-mcp                                   # stdio（本地信任或 WB_MCP_API_KEY）',
    '  whiteboard-mcp --transport http --port 8788      # Streamable HTTP（需凭据）',
    '  whiteboard-mcp --transport sse --port 8788       # SSE（需凭据）',
  ].join('\n');
}

export interface StartedServer {
  transport: TransportName;
  /** http/sse 实际监听端口（stdio 为 null）。 */
  port: number | null;
  /** 优雅关闭（幂等）。 */
  close(): Promise<void>;
}

async function resolveStdioPrincipal(
  options: ServerOptions,
  authenticator: CompositeAuthenticator,
  logger: ReturnType<typeof createStderrLogger>,
): Promise<Principal> {
  const key = options.mcpApiKey;
  if (key) {
    try {
      const principal = await authenticator.authenticate({ apiKey: key });
      logger.info('stdio 已通过 WB_MCP_API_KEY 认证', { userId: principal.userId });
      return principal;
    } catch (error) {
      throw new ServerConfigError(
        `WB_MCP_API_KEY was rejected: ${error instanceof AuthError ? error.message : 'authentication failed'}`,
      );
    }
  }
  logger.warn('stdio 本地信任模式（未设置 WB_MCP_API_KEY）：本机进程可使用全部工具');
  return createLocalPrincipal();
}

function resolveHttpAuthenticator(
  options: ServerOptions,
  authenticator: CompositeAuthenticator,
  logger: ReturnType<typeof createStderrLogger>,
): CompositeAuthenticator {
  if (authenticator.configured) return authenticator;
  if (options.allowAnonymous) {
    logger.warn('--allow-anonymous 已启用：HTTP 请求免认证（仅限开发环境）');
    return new TrustedLocalAuthenticator(createLocalPrincipal('anonymous'));
  }
  throw new ServerConfigError(
    'HTTP transports require credentials: configure WB_API_KEYS or WB_JWT_SECRET (or pass --allow-anonymous for development only)',
  );
}

async function listen(app: import('express').Express, port: number, host: string): Promise<Server> {
  return new Promise<Server>((resolve, reject) => {
    const server = app.listen(port, host);
    server.once('listening', () => resolve(server));
    server.once('error', (error) => reject(error));
  });
}

/** 启动服务（含装配）；调用方负责关闭返回的句柄。 */
export async function startServer(
  options: ServerOptions,
  env: NodeJS.ProcessEnv = process.env,
): Promise<StartedServer> {
  const logger = createStderrLogger({ level: options.logLevel });

  const authResult = loadAuthFromEnv(env);
  for (const warning of authResult.warnings) logger.warn(warning);
  if (authResult.errors.length > 0) {
    throw new ServerConfigError(`Invalid authentication configuration: ${authResult.errors.join('; ')}`);
  }

  const sessions = new SessionStore();
  const audit = new StderrAuditSink();
  const invoker = createDefaultInvoker({ apiBaseUrl: options.apiBaseUrl, apiKey: options.apiKey });
  const resources = new ResourceRegistry({
    reader: createDefaultResourceReader({ apiBaseUrl: options.apiBaseUrl, apiKey: options.apiKey }),
    boards: options.boards,
  });
  const prompts = new PromptRegistry();
  const executor = new ToolExecutor({ invoke: invoker, audit, logger });
  // 请求级速率限制（§9.6）：默认 1000 请求/分钟，可用环境变量配置。
  const rateLimitPerMinute = parsePositiveInt(env, 'WB_MCP_RATE_LIMIT_PER_MINUTE');
  const rateLimiter = new RateLimiter(
    rateLimitPerMinute === null ? {} : { limit: rateLimitPerMinute },
  );
  const dispatcher = new McpDispatcher({ sessions, executor, resources, prompts, audit, logger, rateLimiter });

  if (options.transport === 'stdio') {
    const principal = await resolveStdioPrincipal(options, authResult.authenticator, logger);
    sessions.create(STDIO_SESSION_ID);
    const transport = new StdioTransport({
      dispatcher,
      context: { sessionId: STDIO_SESSION_ID, transport: 'stdio', principal },
      logger,
    });
    transport.start();
    logger.info('whiteboard-mcp 就绪（stdio）', {
      userId: principal.userId,
      tools: TOOL_CATALOG.length,
    });
    return {
      transport: 'stdio',
      port: null,
      close: async () => {
        transport.stop();
      },
    };
  }

  const authenticator = resolveHttpAuthenticator(options, authResult.authenticator, logger);
  const sseApp =
    options.transport === 'sse' ? createSseApp({ dispatcher, sessions, authenticator, audit, logger }) : null;
  const httpApp =
    options.transport === 'http'
      ? createStreamableHttpApp({ dispatcher, sessions, authenticator, audit, logger })
      : null;
  const transportApp = sseApp ?? httpApp;
  if (!transportApp) {
    throw new ServerConfigError(`Unsupported transport: ${String(options.transport)}`);
  }

  const server = await listen(transportApp.app, options.port, options.host);
  const address = server.address();
  const actualPort = typeof address === 'object' && address !== null ? address.port : options.port;
  logger.info(`whiteboard-mcp 就绪（${options.transport}）`, {
    host: options.host,
    port: actualPort,
    tools: TOOL_CATALOG.length,
  });

  let closing: Promise<void> | null = null;
  return {
    transport: options.transport,
    port: actualPort,
    close: async () => {
      if (closing) return closing;
      closing = new Promise<void>((resolve) => {
        transportApp.closeAll();
        server.close(() => resolve());
      });
      return closing;
    },
  };
}

/** 进程入口：解析参数并启动；返回退出码（0 = 正常）。 */
export async function main(
  argv: readonly string[] = process.argv.slice(2),
  env: NodeJS.ProcessEnv = process.env,
): Promise<number> {
  let invocation: ParsedInvocation;
  try {
    invocation = parseServerOptions(argv, env);
  } catch (error) {
    process.stderr.write(`[mcp] configuration error: ${error instanceof Error ? error.message : 'unknown'}\n`);
    return 1;
  }

  if (invocation.kind === 'help') {
    process.stdout.write(`${renderHelp()}\n`);
    return 0;
  }
  if (invocation.kind === 'version') {
    process.stdout.write(`${SERVER_INFO.name} ${SERVER_INFO.version}\n`);
    return 0;
  }

  try {
    const started = await startServer(invocation.options, env);
    const shutdown = (signal: string): void => {
      process.stderr.write(`[mcp] received ${signal}, shutting down\n`);
      void started.close().then(() => process.exit(0));
    };
    process.once('SIGINT', () => shutdown('SIGINT'));
    process.once('SIGTERM', () => shutdown('SIGTERM'));
    return 0;
  } catch (error) {
    process.stderr.write(`[mcp] fatal: ${error instanceof Error ? error.message : 'unknown error'}\n`);
    return 1;
  }
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
