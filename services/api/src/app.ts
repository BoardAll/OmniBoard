import { randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import cors from 'cors';
import express, { type ErrorRequestHandler, type Express, type NextFunction, type Request, type RequestHandler, type Response } from 'express';
import { createMemoryStore, type DataStore } from './db/memory.js';
import { ApiError, toApiErrorShape } from './lib/errors.js';
import { buildMeta, errorBody, okBody } from './lib/response.js';
import {
  authenticate,
  loadAuthConfigFromEnv,
  type AuthConfig,
} from './middleware/auth.js';
import { auditMiddleware, InMemoryAuditStore, type AuditStore } from './middleware/audit.js';
import {
  idempotencyMiddleware,
  InMemoryIdempotencyStore,
  type IdempotencyStore,
} from './middleware/idempotency.js';
import { inputGuard } from './middleware/inputGuard.js';
import {
  DEFAULT_RATE_LIMIT_IP_MAX,
  DEFAULT_RATE_LIMIT_MAX,
  DEFAULT_RATE_LIMIT_WINDOW_MS,
  rateLimit,
  rateLimitCategory,
  rateLimitIp,
  rateLimitOptionsFromEnv,
  SlidingWindowLimiter,
  type RateLimitCategory,
} from './middleware/rateLimit.js';
import { requestId } from './middleware/requestId.js';
import { parseCorsOrigins, securityHeaders } from './middleware/security.js';
import { createAiRouter } from './routes/ai.js';
import { createBoardsRouter } from './routes/boards.js';
import { createCommentsRouter } from './routes/comments.js';
import { createConnectorsRouter } from './routes/connectors.js';
import { createElementsRouter } from './routes/elements.js';
import { createExportsRouter } from './routes/exports.js';
import { createHistoryRouter } from './routes/history.js';
import { createMcpRouter } from './routes/mcp.js';
import { createPagesRouter } from './routes/pages.js';
import { AIService, StubAIProvider, type AIProvider } from './services/aiService.js';
import { BoardService } from './services/boardService.js';
import { CommentService } from './services/commentService.js';
import { ConnectorService } from './services/connectorService.js';
import { ElementService } from './services/elementService.js';
import { ExportService } from './services/exportService.js';
import { HistoryService } from './services/historyService.js';
import { McpBridgeService } from './services/mcpService.js';
import { PageService } from './services/pageService.js';

/**
 * Whiteboard Open API 装配（《OpenAPI规范.md》§4、《安全与合规设计》§8/§22）。
 *
 * 中间件顺序：安全头 → CORS → requestId → X-API-Version → /healthz → 审计 →
 * IP 限流（认证前）→ 认证 → 输入守卫 → 用户限流 →（AI/MCP 类别限流）→
 * 幂等 → 9 个路由（挂载于 `/v1`）→ 404 → 统一错误处理。
 *
 * - 服务层为内存仓库（`DataStore` 接口，Wave 4 可在 db/migrations 接真实 DB）。
 * - 凭据只来自环境变量（`WB_JWT_SECRET` / `WB_JWT_PUBLIC_KEY` / `WB_API_KEYS`）；
 *   生产缺失 → 启动失败；开发缺失 → 临时密钥 + 警告（绝不打印密钥）。
 * - 限流维度（§8.2）：IP 5000/min（认证前）× 用户 1000/min（可被 token/Key 覆盖）
 *   × 可选 AI / MCP 端点类别配额（`WB_RATE_LIMIT_*` 环境变量可配置）。
 */

/** API 主版本（§4.2，`X-API-Version`）。 */
export const API_VERSION = '1';

export interface CreateAppOptions {
  /** 认证配置；缺省时从 `env` 加载（生产缺密钥抛错，开发生成临时密钥）。 */
  auth?: AuthConfig;
  /** 环境变量来源（测试注入用）。 */
  env?: NodeJS.ProcessEnv;
  store?: DataStore;
  auditStore?: AuditStore & { entries?: unknown[] };
  idempotencyStore?: IdempotencyStore;
  limiter?: SlidingWindowLimiter;
  rateLimit?: {
    windowMs?: number;
    max?: number;
    /** IP 维度（认证前）上限，默认 5000（§8.2）。 */
    ipMax?: number;
    /** 端点类别限额（AI / MCP，§8.2「可配置」）。 */
    categories?: Partial<Record<RateLimitCategory, number>>;
  };
  idempotency?: { ttlMs?: number };
  aiProvider?: AIProvider;
  /** CORS 白名单；缺省读 `WB_CORS_ORIGINS`（逗号分隔），均未配置时保持 `*`。 */
  corsOrigins?: string | string[];
}

/** createApp 返回的组合体（测试可断言审计/幂等存储与服务层状态）。 */
export interface AppBundle {
  app: Express;
  authConfig: AuthConfig;
  warnings: string[];
  store: DataStore;
  auditStore: AuditStore;
  idempotencyStore: IdempotencyStore;
  limiter: SlidingWindowLimiter;
  services: {
    board: BoardService;
    page: PageService;
    element: ElementService;
    connector: ConnectorService;
    comment: CommentService;
    exportJob: ExportService;
    history: HistoryService;
    ai: AIService;
    mcp: McpBridgeService;
  };
}

/** `X-API-Version` 响应头（§4.2）。 */
function apiVersionHeader(): RequestHandler {
  return (_req, res, next) => {
    res.setHeader('X-API-Version', API_VERSION);
    next();
  };
}

/** 请求体解析失败（express.json）→ 400/413。 */
function bodyParserError(error: unknown): { status: number; message: string } | null {
  if (!(error instanceof SyntaxError)) return null;
  const candidate = error as SyntaxError & { status?: unknown; type?: unknown };
  if (candidate.type === 'entity.too.large') {
    return { status: 413, message: 'Request body too large' };
  }
  if (candidate.status === 400 || candidate.type === 'entity.parse.failed') {
    return { status: 400, message: 'Malformed JSON body' };
  }
  return null;
}

export function createApp(options: CreateAppOptions = {}): AppBundle {
  const env = options.env ?? process.env;
  const store = options.store ?? createMemoryStore();
  const auditStore = options.auditStore ?? new InMemoryAuditStore();
  const idempotencyStore = options.idempotencyStore ?? new InMemoryIdempotencyStore();

  // —— 限流配置（§8.2）：显式 options > 环境变量 > 默认值 ——
  const envRateLimit = rateLimitOptionsFromEnv(env);
  const rateLimitOptions = {
    windowMs: options.rateLimit?.windowMs ?? envRateLimit.windowMs ?? DEFAULT_RATE_LIMIT_WINDOW_MS,
    max: options.rateLimit?.max ?? envRateLimit.max ?? DEFAULT_RATE_LIMIT_MAX,
    ipMax: options.rateLimit?.ipMax ?? envRateLimit.ipMax ?? DEFAULT_RATE_LIMIT_IP_MAX,
    categories: options.rateLimit?.categories ?? envRateLimit.categories,
  };
  const limiter = options.limiter ?? new SlidingWindowLimiter(rateLimitOptions.windowMs);
  const warnings: string[] = [];

  // —— 认证配置：显式传入 > 环境变量；生产缺密钥 = 拒绝启动 ——
  let authConfig: AuthConfig;
  if (options.auth) {
    authConfig = { ...options.auth };
  } else {
    const loaded = loadAuthConfigFromEnv(env);
    if (loaded.errors.length > 0) {
      throw new Error(`Auth configuration invalid: ${loaded.errors.join('; ')}`);
    }
    warnings.push(...loaded.warnings);
    authConfig = { ...loaded.config };
  }
  if (!authConfig.jwtSecret && !authConfig.jwtPublicKey) {
    // 仅开发/测试路径可达（生产已被 loadAuthConfigFromEnv 拒绝）：临时密钥。
    authConfig.jwtSecret = randomBytes(32).toString('hex');
    warnings.push('Using an ephemeral JWT secret generated at startup (development only)');
  }

  // —— 服务层装配（依赖顺序：history → board → page → element/connector/comment → exports → ai → mcp）——
  const history = new HistoryService(store);
  const board = new BoardService(store, history);
  const page = new PageService(store, board, history);
  const element = new ElementService(store, page, history);
  const connector = new ConnectorService(store, page, history);
  const comment = new CommentService(store, board, page, history);
  const exportJob = new ExportService(store, board, page);
  const ai = new AIService(store, board, options.aiProvider ?? new StubAIProvider());
  const mcp = new McpBridgeService({ board, page, element, connector, comment, exportJob, history, ai });

  const app = express();
  app.disable('x-powered-by');

  // 安全响应头（§22.1；先于 CORS，保证预检与错误响应同样携带）。
  app.use(securityHeaders());

  // CORS：公开 API（凭据经 Authorization 头，不使用 Cookie）；暴露分页/限流/重放相关响应头。
  const corsOrigins = options.corsOrigins ?? parseCorsOrigins(env['WB_CORS_ORIGINS']);
  app.use(
    cors({
      ...(corsOrigins === undefined ? {} : { origin: corsOrigins }),
      exposedHeaders: [
        'X-Request-Id',
        'X-API-Version',
        'X-RateLimit-Limit',
        'X-RateLimit-Remaining',
        'X-RateLimit-Reset',
        'Retry-After',
        'Idempotency-Replay',
      ],
    }),
  );
  app.use(express.json({ limit: '15mb' }));
  app.use(requestId());
  app.use(apiVersionHeader());

  // 健康检查（免认证，不写审计；供负载均衡/容器探针使用）。
  app.get('/healthz', (req: Request, res: Response) => {
    res.json(
      okBody(
        {
          status: 'ok',
          name: 'whiteboard-api',
          version: API_VERSION,
          uptimeSeconds: Math.round(process.uptime()),
        },
        buildMeta(req.requestId ?? ''),
      ),
    );
  });

  // 审计（4xx/5xx 同样记录；凭据绝不入审计，见 middleware/audit.ts）。
  app.use(auditMiddleware(auditStore));
  // IP 维度限流（认证前；§8.2 IP 5000/min，为未认证流量提供缓冲）。
  app.use(rateLimitIp({ ...rateLimitOptions }, limiter));
  // 认证（JWT Bearer / X-API-Key）→ 401（写 auth.failure 审计）。
  app.use(authenticate(authConfig));
  // 输入守卫（§8.5：Content-Type 强制、查询串控制字符/长度；挂在认证后确保未认证先 401）。
  app.use(inputGuard());
  // 用户维度限流（滑动窗口，429 + Retry-After）。
  app.use(rateLimit({ ...rateLimitOptions }, limiter));
  // 端点类别限流（§8.2「AI / MCP 可配置」；仅配置时启用）。
  const aiCategoryMax = rateLimitOptions.categories?.ai;
  if (aiCategoryMax !== undefined) {
    app.use('/v1/ai', rateLimitCategory('ai', { ...rateLimitOptions, max: aiCategoryMax }, limiter));
  }
  const mcpCategoryMax = rateLimitOptions.categories?.mcp;
  if (mcpCategoryMax !== undefined) {
    app.use('/v1/mcp', rateLimitCategory('mcp', { ...rateLimitOptions, max: mcpCategoryMax }, limiter));
  }
  // 幂等（Idempotency-Key：同键同体重放，同键异体 409）。
  app.use(idempotencyMiddleware(idempotencyStore, { ttlMs: options.idempotency?.ttlMs }));

  // —— 路由（全部挂载于 `/v1`；每个 router 内部使用完整路径）——
  app.use('/v1', createBoardsRouter({ board }));
  app.use('/v1', createPagesRouter({ board, page }));
  app.use('/v1', createElementsRouter({ element }));
  app.use('/v1', createConnectorsRouter({ connector }));
  app.use('/v1', createCommentsRouter({ comment }));
  app.use('/v1', createExportsRouter({ exportJob }));
  app.use('/v1', createHistoryRouter({ board, history }));
  app.use('/v1', createAiRouter({ ai }));
  app.use('/v1', createMcpRouter({ mcp }));

  // 404（未知路由，统一错误信封）。
  app.use((req: Request, res: Response) => {
    res.status(404).json(
      errorBody(
        { code: 'NOT_FOUND', message: `No route for ${req.method} ${req.path}` },
        buildMeta(req.requestId ?? ''),
      ),
    );
  });

  // 统一错误处理：ApiError / ZodError / body 解析错误 / 未知异常（不泄漏内部细节）。
  const errorHandler: ErrorRequestHandler = (error, req: Request, res: Response, _next: NextFunction) => {
    const meta = buildMeta(req.requestId ?? '');
    if (res.headersSent) return;

    const parseError = bodyParserError(error);
    if (parseError) {
      res
        .status(parseError.status)
        .json(errorBody({ code: 'INVALID_ARGUMENT', message: parseError.message }, meta));
      return;
    }
    if (error instanceof ApiError) {
      res.status(error.status).json(
        errorBody(
          { code: error.code, message: error.message, ...(error.detail === undefined ? {} : { detail: error.detail }) },
          meta,
        ),
      );
      return;
    }
    // 未知异常：服务端记录摘要（不含请求体/凭据），客户端只得到通用错误。
    const summary = error instanceof Error ? `${error.name}: ${error.message}` : 'non-error thrown';
    console.error(`[api] unhandled error requestId=${req.requestId ?? '-'} ${summary}`);
    res.status(500).json(errorBody(toApiErrorShape(error), meta));
  };
  app.use(errorHandler);

  return {
    app,
    authConfig,
    warnings,
    store,
    auditStore,
    idempotencyStore,
    limiter,
    services: { board, page, element, connector, comment, exportJob, history, ai, mcp },
  };
}

/** 检测是否作为入口直接运行（`node dist/app.js` / `tsx src/app.ts`）。 */
function isMainModule(): boolean {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return import.meta.url === pathToFileURL(entry).href;
  } catch {
    return false;
  }
}

function main(): void {
  const env = process.env;
  const { config, warnings, errors } = loadAuthConfigFromEnv(env);
  if (errors.length > 0) {
    // 生产环境缺凭据 → 拒绝启动（凭据仅经环境变量注入）。
    for (const message of errors) console.error(`[api] ${message}`);
    process.exitCode = 1;
    return;
  }
  for (const message of warnings) console.warn(`[api] ${message}`);
  if (!config.jwtSecret && !config.jwtPublicKey) {
    config.jwtSecret = randomBytes(32).toString('hex');
  }
  const bundle = createApp({ auth: config });
  const port = Number(env['WB_API_PORT'] ?? env['PORT'] ?? 8080);
  bundle.app.listen(port, () => {
    console.log(`[api] Whiteboard Open API listening on http://127.0.0.1:${port} (health: /healthz)`);
  });
}

if (isMainModule()) {
  main();
}
