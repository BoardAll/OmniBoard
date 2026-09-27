/**
 * MCP 资源注册表（《MCP_Server详细设计》§7）。
 *
 * - URI 模板：白板 / 页面 / 元素 / 缩略图 / 评论 / 历史 / 协作者 / 模板（§7.3）；
 * - `list`：返回 root（白板列表）+ 已配置（或主体限定）白板下的可发现资源；
 * - `read`：按模板匹配 URI → 交给 `ResourceReader`（测试可注入 fake；
 *   默认：配置 `WB_API_BASE_URL` 时转发 services/api，否则返回显式的未桥接占位 JSON）；
 * - `subscribe` / `unsubscribe`：记录会话订阅（§7.4）。
 */

import { RpcError, RPC_ERROR_CODES } from '../protocol/jsonrpc.js';
import type { Principal } from '../auth/types.js';

export interface ResourceTemplate {
  uriTemplate: string;
  name: string;
  description: string;
  mimeType: string;
  /** 读取语义种类（匹配后交给 ResourceReader 分派）。 */
  kind: string;
}

/** §7.3 资源 URI 方案。 */
export const RESOURCE_TEMPLATES: readonly ResourceTemplate[] = [
  {
    uriTemplate: 'whiteboard://boards',
    name: '白板列表',
    description: '当前用户可访问的白板列表',
    mimeType: 'application/json',
    kind: 'boards',
  },
  {
    uriTemplate: 'whiteboard://boards/{boardId}',
    name: '白板元数据',
    description: '白板名称、描述、页面数等',
    mimeType: 'application/json',
    kind: 'board',
  },
  {
    uriTemplate: 'whiteboard://boards/{boardId}/pages',
    name: '页面列表',
    description: '白板下的页面列表',
    mimeType: 'application/json',
    kind: 'pages',
  },
  {
    uriTemplate: 'whiteboard://boards/{boardId}/pages/{pageId}',
    name: '页面详情',
    description: '页面属性与背景',
    mimeType: 'application/json',
    kind: 'page',
  },
  {
    uriTemplate: 'whiteboard://boards/{boardId}/pages/{pageId}/elements',
    name: '页面元素',
    description: '页面全部元素',
    mimeType: 'application/json',
    kind: 'elements',
  },
  {
    uriTemplate: 'whiteboard://boards/{boardId}/pages/{pageId}/thumbnail',
    name: '页面缩略图',
    description: '页面缩略图（URL / base64）',
    mimeType: 'application/json',
    kind: 'page-thumbnail',
  },
  {
    uriTemplate: 'whiteboard://boards/{boardId}/comments',
    name: '评论',
    description: '白板评论列表',
    mimeType: 'application/json',
    kind: 'comments',
  },
  {
    uriTemplate: 'whiteboard://boards/{boardId}/history',
    name: '历史',
    description: '白板操作历史 / 快照',
    mimeType: 'application/json',
    kind: 'history',
  },
  {
    uriTemplate: 'whiteboard://boards/{boardId}/collaborators',
    name: '协作者',
    description: '白板协作者列表',
    mimeType: 'application/json',
    kind: 'collaborators',
  },
  {
    uriTemplate: 'whiteboard://boards/{boardId}/templates',
    name: '模板',
    description: '白板可用模板列表',
    mimeType: 'application/json',
    kind: 'templates',
  },
];

interface UriMatcher {
  regex: RegExp;
  template: ResourceTemplate;
  paramNames: string[];
}

function buildMatchers(): UriMatcher[] {
  return RESOURCE_TEMPLATES.map((template) => {
    const paramNames = [...template.uriTemplate.matchAll(/\{(\w+)\}/g)].map((match) => match[1] ?? '');
    const escaped = template.uriTemplate.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const pattern = escaped.replace(/\\\{(\w+)\\\}/g, '([^/?#]+)');
    return { regex: new RegExp(`^${pattern}$`), template, paramNames };
  });
}

const MATCHERS = buildMatchers();

export interface ResourceMatch {
  template: ResourceTemplate;
  params: Record<string, string>;
}

/** 将 URI 与模板匹配；不匹配返回 null。 */
export function matchResource(uri: string): ResourceMatch | null {
  for (const matcher of MATCHERS) {
    const match = matcher.regex.exec(uri);
    if (!match) continue;
    const params: Record<string, string> = {};
    matcher.paramNames.forEach((name, index) => {
      const raw = match[index + 1];
      if (raw !== undefined) {
        try {
          params[name] = decodeURIComponent(raw);
        } catch {
          params[name] = raw;
        }
      }
    });
    return { template: matcher.template, params };
  }
  return null;
}

export interface ResourceDescriptor {
  uri: string;
  name: string;
  description: string;
  mimeType: string;
}

export interface ResourceReadInput {
  uri: string;
  kind: string;
  params: Record<string, string>;
}

export interface ResourceContent {
  uri: string;
  mimeType: string;
  text: string;
}

export interface ResourceReadContext {
  sessionId: string;
  principal: Principal | null;
}

export type ResourceReader = (input: ResourceReadInput, context: ResourceReadContext) => Promise<ResourceContent>;

export interface ResourceRegistryOptions {
  reader?: ResourceReader;
  /** 已配置的白板（来自 WB_BOARD_ID / 启动参数）；用于 list 展开。 */
  boards?: readonly string[] | null;
}

const BOARD_COLLECTIONS: ReadonlyArray<{ suffix: string; name: string; description: string }> = [
  { suffix: '', name: '白板元数据', description: '白板名称、描述、页面数等' },
  { suffix: '/pages', name: '页面列表', description: '白板下的页面列表' },
  { suffix: '/comments', name: '评论', description: '白板评论列表' },
  { suffix: '/history', name: '历史', description: '白板操作历史 / 快照' },
  { suffix: '/collaborators', name: '协作者', description: '白板协作者列表' },
  { suffix: '/templates', name: '模板', description: '白板可用模板列表' },
];

export class ResourceRegistry {
  private readonly reader: ResourceReader;
  private readonly boards: readonly string[];
  private readonly subscriptions = new Map<string, Set<string>>();

  constructor(options: ResourceRegistryOptions = {}) {
    this.reader = options.reader ?? createDefaultResourceReader();
    this.boards = options.boards ? [...options.boards] : [];
  }

  /** §7.3 全部 URI 模板（`resources/templates/list`）。 */
  listTemplates(): ResourceTemplate[] {
    return RESOURCE_TEMPLATES.map((template) => ({ ...template }));
  }

  /** `resources/list`：root + 白板范围展开。 */
  list(principal: Principal | null): { resources: ResourceDescriptor[]; nextCursor: null } {
    const boards = this.resolveBoards(principal);
    const resources: ResourceDescriptor[] = [
      {
        uri: 'whiteboard://boards',
        name: '白板列表',
        description: '当前可访问的白板列表',
        mimeType: 'application/json',
      },
    ];
    for (const boardId of boards) {
      for (const collection of BOARD_COLLECTIONS) {
        resources.push({
          uri: `whiteboard://boards/${boardId}${collection.suffix}`,
          name: collection.suffix === '' ? `白板 ${boardId}` : `${collection.name}（${boardId}）`,
          description: collection.description,
          mimeType: 'application/json',
        });
      }
    }
    return { resources, nextCursor: null };
  }

  /** `resources/read`：匹配模板并读取；未知 URI → -32003。 */
  async read(uri: string, context: ResourceReadContext): Promise<ResourceContent> {
    const match = matchResource(uri);
    if (!match) {
      throw new RpcError(RPC_ERROR_CODES.notFound, `Unknown resource URI: ${uri}`, { uri });
    }
    return this.reader({ uri, kind: match.template.kind, params: match.params }, context);
  }

  /** `resources/subscribe`：校验 URI 合法后登记（会话级）。 */
  subscribe(sessionId: string, uri: string): void {
    if (!matchResource(uri)) {
      throw new RpcError(RPC_ERROR_CODES.notFound, `Unknown resource URI: ${uri}`, { uri });
    }
    let set = this.subscriptions.get(sessionId);
    if (!set) {
      set = new Set();
      this.subscriptions.set(sessionId, set);
    }
    set.add(uri);
  }

  unsubscribe(sessionId: string, uri: string): void {
    const set = this.subscriptions.get(sessionId);
    if (!set) return;
    set.delete(uri);
    if (set.size === 0) this.subscriptions.delete(sessionId);
  }

  subscriptionsOf(sessionId: string): string[] {
    return [...(this.subscriptions.get(sessionId) ?? [])];
  }

  /** 资源变更时找出订阅了该 URI 的会话（§7.4 `notifications/resources/updated`）。 */
  subscribersFor(uri: string): string[] {
    const result: string[] = [];
    for (const [sessionId, set] of this.subscriptions) {
      if (set.has(uri)) result.push(sessionId);
    }
    return result;
  }

  private resolveBoards(principal: Principal | null): string[] {
    const allowed = principal?.boards ?? null;
    const base = this.boards.length > 0 ? this.boards : (allowed ?? []);
    const resolved = allowed ? base.filter((boardId) => allowed.includes(boardId)) : [...base];
    return [...new Set(resolved)];
  }
}

/* ------------------------------------------------------------------ */
/* 默认 ResourceReader                                                  */
/* ------------------------------------------------------------------ */

export interface DefaultResourceReaderOptions {
  apiBaseUrl?: string | null;
  apiKey?: string | null;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

const API_PATHS: Record<string, (params: Record<string, string>) => string> = {
  boards: () => '/v1/boards',
  board: (params) => `/v1/boards/${encodeURIComponent(params['boardId'] ?? '')}`,
  pages: (params) => `/v1/boards/${encodeURIComponent(params['boardId'] ?? '')}/pages`,
  page: (params) => `/v1/pages/${encodeURIComponent(params['pageId'] ?? '')}`,
  elements: (params) => `/v1/pages/${encodeURIComponent(params['pageId'] ?? '')}/elements`,
  comments: (params) => `/v1/boards/${encodeURIComponent(params['boardId'] ?? '')}/comments`,
  history: (params) => `/v1/boards/${encodeURIComponent(params['boardId'] ?? '')}/history`,
  collaborators: (params) => `/v1/boards/${encodeURIComponent(params['boardId'] ?? '')}/collaborators`,
};

/**
 * 默认读取器：
 * - 配置 `WB_API_BASE_URL` → 转发 services/api（GET + 服务凭据），`{ ok, data }` 归一化为 JSON 文本；
 * - 未配置 → 返回显式占位 JSON（`data: null` + note），不伪造数据。
 */
export function createDefaultResourceReader(options: DefaultResourceReaderOptions = {}): ResourceReader {
  const baseUrl = options.apiBaseUrl?.replace(/\/+$/, '') ?? '';
  if (baseUrl.length > 0) {
    const fetchImpl = options.fetchImpl ?? fetch;
    return async (input) => {
      const pathBuilder = API_PATHS[input.kind];
      if (!pathBuilder) {
        throw new RpcError(RPC_ERROR_CODES.notFound, `Resource kind "${input.kind}" is not bridged to the API`, {
          uri: input.uri,
        });
      }
      const url = `${baseUrl}${pathBuilder(input.params)}`;
      const headers: Record<string, string> = { accept: 'application/json' };
      if (options.apiKey) headers['authorization'] = `Bearer ${options.apiKey}`;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? 30_000);
      let response: Response;
      try {
        response = await fetchImpl(url, { headers, signal: controller.signal });
      } catch (error) {
        throw new RpcError(RPC_ERROR_CODES.serverError, 'API bridge request failed', {
          uri: input.uri,
          message: error instanceof Error ? error.message : 'network error',
        });
      } finally {
        clearTimeout(timer);
      }
      const payload: unknown = await response.json().catch(() => null);
      if (!response.ok) {
        const code =
          response.status === 403 ? RPC_ERROR_CODES.permissionDenied : response.status === 404 ? RPC_ERROR_CODES.notFound : RPC_ERROR_CODES.serverError;
        throw new RpcError(code, `API bridge error (HTTP ${response.status})`, { uri: input.uri });
      }
      const data = isRecord(payload) && payload['ok'] === true ? payload['data'] : null;
      return {
        uri: input.uri,
        mimeType: 'application/json',
        text: JSON.stringify(data ?? null),
      };
    };
  }

  return async (input) => ({
    uri: input.uri,
    mimeType: 'application/json',
    text: JSON.stringify({
      uri: input.uri,
      kind: input.kind,
      params: input.params,
      data: null,
      note: 'Backend bridge is not configured: set WB_API_BASE_URL to enable live resource data.',
    }),
  });
}
