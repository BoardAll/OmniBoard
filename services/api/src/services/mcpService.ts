import { ApiError } from '../lib/errors.js';
import { hasScope, type PrincipalContext } from './access.js';
import type { AIService } from './aiService.js';
import type { BoardService } from './boardService.js';
import type { CommentService } from './commentService.js';
import type { ConnectorService } from './connectorService.js';
import type { ElementService } from './elementService.js';
import type { ExportService } from './exportService.js';
import type { HistoryService } from './historyService.js';
import type { PageService } from './pageService.js';
import type {
  CreateElementInput,
  Scope,
  UpdateConnectorInput,
  UpdateElementInput,
} from '../db/schema.js';

/**
 * MCP 桥接（《OpenAPI规范.md》§5.10 + §14 工具映射表）。
 *
 * `/mcp/tools` 返回的工具目录与 services/mcp_server 的工具注册表保持同一
 * 命名/Scope/确认级别；`/mcp/tools/{toolName}/call` 直接调用本地服务层，
 * 供服务端集成方在 REST 侧复用 MCP 工具语义。
 *
 * 危险等级：auto / preview / confirm（《AI 助手与 MCP 设计》§3.3）。
 */

export type ConfirmationLevel = 'auto' | 'preview' | 'confirm';

export interface McpToolDefinition {
  /** MCP 工具名（下划线；内部 id 点号，规则见 MCP_Server详细设计 §6.3）。 */
  name: string;
  internalToolId: string;
  description: string;
  scope: Scope;
  confirmation: ConfirmationLevel;
  inputSchema: Record<string, unknown>;
}

export interface McpToolResult {
  content: Array<{ type: 'text'; text: string }>;
  isError: boolean;
  structuredContent: Record<string, unknown>;
}

export interface ToolCallInput {
  arguments: Record<string, unknown>;
  /** 破坏性操作确认标记（对应 MCP 的 confirm_operation 流程）。 */
  confirm?: boolean;
}

const objectSchema = (
  properties: Record<string, unknown>,
  required: string[] = [],
): Record<string, unknown> => ({ type: 'object', properties, required, additionalProperties: false });

const str = (description: string): Record<string, unknown> => ({ type: 'string', description });

/** 工具目录（对齐《OpenAPI规范.md》附录 §14 映射表）。 */
export const MCP_TOOL_CATALOG: readonly McpToolDefinition[] = [
  {
    name: 'board_create',
    internalToolId: 'board.create',
    description: '创建白板',
    scope: 'board:write',
    confirmation: 'auto',
    inputSchema: objectSchema({ name: str('白板名称'), description: str('描述') }, ['name']),
  },
  {
    name: 'board_get',
    internalToolId: 'board.get',
    description: '获取白板',
    scope: 'board:read',
    confirmation: 'auto',
    inputSchema: objectSchema({ boardId: str('白板 ID') }, ['boardId']),
  },
  {
    name: 'board_update',
    internalToolId: 'board.update',
    description: '更新白板',
    scope: 'board:write',
    confirmation: 'auto',
    inputSchema: objectSchema({ boardId: str('白板 ID'), name: str('名称'), description: str('描述') }, ['boardId']),
  },
  {
    name: 'board_delete',
    internalToolId: 'board.delete',
    description: '删除白板（破坏性，需确认）',
    scope: 'board:write',
    confirmation: 'confirm',
    inputSchema: objectSchema({ boardId: str('白板 ID') }, ['boardId']),
  },
  {
    name: 'board_share',
    internalToolId: 'board.share',
    description: '分享白板（需确认）',
    scope: 'board:share',
    confirmation: 'confirm',
    inputSchema: objectSchema(
      { boardId: str('白板 ID'), role: str('角色'), expiresAt: str('过期时间 ISO 8601') },
      ['boardId'],
    ),
  },
  {
    name: 'page_create',
    internalToolId: 'page.create',
    description: '创建页面',
    scope: 'page:write',
    confirmation: 'auto',
    inputSchema: objectSchema({ boardId: str('白板 ID'), name: str('页面名称') }, ['boardId', 'name']),
  },
  {
    name: 'page_duplicate',
    internalToolId: 'page.duplicate',
    description: '复制页面',
    scope: 'page:write',
    confirmation: 'auto',
    inputSchema: objectSchema({ pageId: str('页面 ID') }, ['pageId']),
  },
  {
    name: 'page_delete',
    internalToolId: 'page.delete',
    description: '删除页面（破坏性，需确认）',
    scope: 'page:write',
    confirmation: 'confirm',
    inputSchema: objectSchema({ pageId: str('页面 ID') }, ['pageId']),
  },
  {
    name: 'page_move',
    internalToolId: 'page.move',
    description: '移动页面顺序',
    scope: 'page:write',
    confirmation: 'auto',
    inputSchema: objectSchema(
      { pageId: str('页面 ID'), index: { type: 'integer', description: '目标顺序' } },
      ['pageId', 'index'],
    ),
  },
  {
    name: 'page_split',
    internalToolId: 'page.split',
    description: '拆分页面（预览后执行）',
    scope: 'page:write',
    confirmation: 'preview',
    inputSchema: objectSchema(
      { pageId: str('页面 ID'), splitY: { type: 'number', description: '切分 y 坐标' } },
      ['pageId', 'splitY'],
    ),
  },
  {
    name: 'page_merge',
    internalToolId: 'page.merge',
    description: '合并页面（需确认）',
    scope: 'page:write',
    confirmation: 'confirm',
    inputSchema: objectSchema({ pageIds: { type: 'array', items: { type: 'string' } } }, ['pageIds']),
  },
  {
    name: 'element_list',
    internalToolId: 'element.list',
    description: '列出页面元素',
    scope: 'element:read',
    confirmation: 'auto',
    inputSchema: objectSchema({ pageId: str('页面 ID'), filter: str('过滤表达式，如 type:sticky') }, ['pageId']),
  },
  {
    name: 'element_create',
    internalToolId: 'element.create',
    description: '创建元素（便签/文本/形状等）',
    scope: 'element:write',
    confirmation: 'auto',
    inputSchema: objectSchema(
      {
        pageId: str('页面 ID'),
        elements: { type: 'array', items: { type: 'object' } },
        dryRun: { type: 'boolean', default: false },
      },
      ['pageId', 'elements'],
    ),
  },
  {
    name: 'element_update',
    internalToolId: 'element.update',
    description: '更新元素',
    scope: 'element:write',
    confirmation: 'auto',
    inputSchema: objectSchema({ elementId: str('元素 ID'), patch: { type: 'object' } }, ['elementId', 'patch']),
  },
  {
    name: 'element_delete',
    internalToolId: 'element.delete',
    description: '删除元素（破坏性，需确认）',
    scope: 'element:write',
    confirmation: 'confirm',
    inputSchema: objectSchema({ elementId: str('元素 ID') }, ['elementId']),
  },
  {
    name: 'connector_create',
    internalToolId: 'connector.create',
    description: '创建连线',
    scope: 'connector:write',
    confirmation: 'auto',
    inputSchema: objectSchema(
      { pageId: str('页面 ID'), fromElementId: str('起点元素'), toElementId: str('终点元素'), label: str('标签') },
      ['pageId', 'fromElementId', 'toElementId'],
    ),
  },
  {
    name: 'connector_update',
    internalToolId: 'connector.update',
    description: '更新连线',
    scope: 'connector:write',
    confirmation: 'auto',
    inputSchema: objectSchema({ connectorId: str('连线 ID'), patch: { type: 'object' } }, ['connectorId', 'patch']),
  },
  {
    name: 'connector_delete',
    internalToolId: 'connector.delete',
    description: '删除连线（破坏性，需确认）',
    scope: 'connector:write',
    confirmation: 'confirm',
    inputSchema: objectSchema({ connectorId: str('连线 ID') }, ['connectorId']),
  },
  {
    name: 'comment_create',
    internalToolId: 'comment.create',
    description: '创建评论',
    scope: 'comment:write',
    confirmation: 'auto',
    inputSchema: objectSchema({ boardId: str('白板 ID'), pageId: str('页面 ID'), content: str('内容') }, ['boardId', 'content']),
  },
  {
    name: 'comment_reply',
    internalToolId: 'comment.reply',
    description: '回复评论',
    scope: 'comment:write',
    confirmation: 'auto',
    inputSchema: objectSchema({ commentId: str('评论 ID'), content: str('内容') }, ['commentId', 'content']),
  },
  {
    name: 'comment_resolve',
    internalToolId: 'comment.resolve',
    description: '标记评论已解决',
    scope: 'comment:write',
    confirmation: 'auto',
    inputSchema: objectSchema({ commentId: str('评论 ID') }, ['commentId']),
  },
  {
    name: 'export_create',
    internalToolId: 'export.create',
    description: '导出白板',
    scope: 'export:read',
    confirmation: 'auto',
    inputSchema: objectSchema({ boardId: str('白板 ID'), format: str('pdf/png/svg/json/markdown') }, ['boardId', 'format']),
  },
  {
    name: 'export_download',
    internalToolId: 'export.download',
    description: '获取导出结果',
    scope: 'export:read',
    confirmation: 'auto',
    inputSchema: objectSchema({ exportId: str('导出任务 ID') }, ['exportId']),
  },
  {
    name: 'history_undo',
    internalToolId: 'history.undo',
    description: '撤销',
    scope: 'history:write',
    confirmation: 'auto',
    inputSchema: objectSchema({ boardId: str('白板 ID') }, ['boardId']),
  },
  {
    name: 'history_redo',
    internalToolId: 'history.redo',
    description: '重做',
    scope: 'history:write',
    confirmation: 'auto',
    inputSchema: objectSchema({ boardId: str('白板 ID') }, ['boardId']),
  },
  {
    name: 'history_snapshot',
    internalToolId: 'history.snapshot',
    description: '创建快照',
    scope: 'history:write',
    confirmation: 'auto',
    inputSchema: objectSchema({ boardId: str('白板 ID'), name: str('快照名称') }, ['boardId']),
  },
  {
    name: 'ai_session_create',
    internalToolId: 'ai.session.create',
    description: '创建 AI 会话',
    scope: 'ai:invoke',
    confirmation: 'auto',
    inputSchema: objectSchema({ boardId: str('白板 ID') }, ['boardId']),
  },
  {
    name: 'ai_send_message',
    internalToolId: 'ai.sendMessage',
    description: '发送 AI 消息',
    scope: 'ai:invoke',
    confirmation: 'auto',
    inputSchema: objectSchema({ sessionId: str('会话 ID'), content: str('内容') }, ['sessionId', 'content']),
  },
  {
    name: 'ai_send_audio',
    internalToolId: 'ai.sendAudio',
    description: '发送语音',
    scope: 'ai:invoke',
    confirmation: 'auto',
    inputSchema: objectSchema({ sessionId: str('会话 ID'), audioBase64: str('音频 base64') }, ['sessionId']),
  },
  {
    name: 'ai_execute_tool_call',
    internalToolId: 'ai.executeToolCall',
    description: '执行 AI 工具调用（需确认）',
    scope: 'ai:invoke',
    confirmation: 'confirm',
    inputSchema: objectSchema({ toolCallId: str('工具调用 ID') }, ['toolCallId']),
  },
];

export interface McpServerInfo {
  name: string;
  version: string;
  protocolVersion: string;
  capabilities: Record<string, unknown>;
}

export const MCP_SERVER_INFO: McpServerInfo = {
  name: 'whiteboard-mcp',
  version: '1.0.0',
  protocolVersion: '2025-06-18',
  capabilities: {
    tools: { listChanged: true },
    resources: { subscribe: true, listChanged: true },
    prompts: { listChanged: true },
    logging: {},
  },
};

type ExportFormat = 'pdf' | 'png' | 'svg' | 'json' | 'markdown';
const SHARE_ROLES = ['admin', 'editor', 'commenter', 'viewer', 'guest'] as const;
const EXPORT_FORMATS: readonly ExportFormat[] = ['pdf', 'png', 'svg', 'json', 'markdown'];

export interface McpServiceDeps {
  board: BoardService;
  page: PageService;
  element: ElementService;
  connector: ConnectorService;
  comment: CommentService;
  exportJob: ExportService;
  history: HistoryService;
  ai: AIService;
}

export class McpBridgeService {
  constructor(private readonly deps: McpServiceDeps) {}

  listTools(): McpToolDefinition[] {
    return [...MCP_TOOL_CATALOG];
  }

  getServerInfo(): McpServerInfo {
    return { ...MCP_SERVER_INFO };
  }

  findTool(name: string): McpToolDefinition | undefined {
    return MCP_TOOL_CATALOG.find((t) => t.name === name || t.internalToolId === name);
  }

  async callTool(principal: PrincipalContext, toolName: string, input: ToolCallInput): Promise<McpToolResult> {
    const tool = this.findTool(toolName);
    if (!tool) throw ApiError.notFound('Unknown MCP tool', { toolName });
    if (!hasScope(principal, tool.scope)) {
      throw ApiError.permissionDenied(`No permission: scope ${tool.scope} required`, {
        scope: tool.scope,
        toolId: tool.internalToolId,
      });
    }
    if ((tool.confirmation === 'confirm' || tool.confirmation === 'preview') && input.confirm !== true) {
      throw ApiError.confirmationRequired(`Tool ${tool.name} requires confirmation`, {
        toolId: tool.internalToolId,
        confirmation: tool.confirmation,
        arguments: input.arguments,
      });
    }
    const structured = await this.dispatch(principal, tool, input.arguments);
    return {
      content: [{ type: 'text', text: `${tool.internalToolId} 执行成功` }],
      isError: false,
      structuredContent: structured,
    };
  }

  private async dispatch(
    principal: PrincipalContext,
    tool: McpToolDefinition,
    args: Record<string, unknown>,
  ): Promise<Record<string, unknown>> {
    const s = (key: string): string => {
      const value = args[key];
      if (typeof value !== 'string' || value.length === 0) {
        throw ApiError.invalidArgument(`Missing required argument: ${key}`, { toolId: tool.internalToolId });
      }
      return value;
    };
    const obj = (key: string): Record<string, unknown> => {
      const value = args[key];
      if (typeof value !== 'object' || value === null || Array.isArray(value)) {
        throw ApiError.invalidArgument(`Argument ${key} must be an object`, { toolId: tool.internalToolId });
      }
      return value as Record<string, unknown>;
    };

    switch (tool.internalToolId) {
      case 'board.create':
        return {
          board: this.deps.board.create(principal, {
            name: s('name'),
            ...(typeof args['description'] === 'string' ? { description: args['description'] } : {}),
          }),
        };
      case 'board.get':
        return { board: this.deps.board.get(principal, s('boardId')) };
      case 'board.update': {
        const patch: { name?: string; description?: string } = {};
        if (typeof args['name'] === 'string') patch.name = args['name'];
        if (typeof args['description'] === 'string') patch.description = args['description'];
        return { board: this.deps.board.update(principal, s('boardId'), patch) };
      }
      case 'board.delete': {
        const boardId = s('boardId');
        this.deps.board.remove(principal, boardId);
        return { deleted: true, boardId };
      }
      case 'board.share': {
        const rawRole = typeof args['role'] === 'string' ? args['role'] : 'viewer';
        const role = SHARE_ROLES.find((r) => r === rawRole) ?? 'viewer';
        const result = this.deps.board.share(principal, s('boardId'), { enabled: true, role });
        return { boardId: result.board.id, shareToken: result.shareLink.token };
      }
      case 'page.create':
        return { page: this.deps.page.create(principal, s('boardId'), { name: s('name') }) };
      case 'page.duplicate':
        return { page: this.deps.page.duplicate(principal, s('pageId')) };
      case 'page.delete': {
        const pageId = s('pageId');
        this.deps.page.remove(principal, pageId);
        return { deleted: true, pageId };
      }
      case 'page.move':
        return { page: this.deps.page.move(principal, s('pageId'), Number(args['index'] ?? 0)) };
      case 'page.split':
        return { page: this.deps.page.split(principal, s('pageId'), { splitY: Number(args['splitY'] ?? 0) }) };
      case 'page.merge': {
        const pageIds = Array.isArray(args['pageIds']) ? (args['pageIds'] as string[]) : [];
        return { page: this.deps.page.merge(principal, { pageIds }) };
      }
      case 'element.list': {
        const result = this.deps.element.listByPage(principal, s('pageId'), {
          limit: 100,
          offset: 0,
          sort: { field: 'zIndex', dir: 'asc' },
          filter: typeof args['filter'] === 'string' ? parseSimpleFilter(args['filter']) : {},
        });
        return { elements: result.items, total: result.total };
      }
      case 'element.create': {
        const pageId = s('pageId');
        const rawElements = args['elements'];
        if (!Array.isArray(rawElements) || rawElements.length === 0) {
          throw ApiError.invalidArgument('elements must be a non-empty array');
        }
        const result = this.deps.element.createMany(principal, pageId, {
          elements: rawElements as unknown as CreateElementInput[],
          dryRun: args['dryRun'] === true,
        });
        return { elementIds: result.elements.map((e) => e.id), dryRun: result.dryRun };
      }
      case 'element.update':
        return { element: this.deps.element.update(principal, s('elementId'), obj('patch') as UpdateElementInput) };
      case 'element.delete': {
        const elementId = s('elementId');
        this.deps.element.remove(principal, elementId);
        return { deleted: true, elementId };
      }
      case 'connector.create':
        return {
          connector: this.deps.connector.create(principal, s('pageId'), {
            fromElementId: s('fromElementId'),
            toElementId: s('toElementId'),
            ...(typeof args['label'] === 'string' ? { label: args['label'] } : {}),
          }),
        };
      case 'connector.update':
        return { connector: this.deps.connector.update(principal, s('connectorId'), obj('patch') as UpdateConnectorInput) };
      case 'connector.delete': {
        const connectorId = s('connectorId');
        this.deps.connector.remove(principal, connectorId);
        return { deleted: true, connectorId };
      }
      case 'comment.create':
        return {
          comment: this.deps.comment.create(principal, {
            boardId: s('boardId'),
            content: s('content'),
            ...(typeof args['pageId'] === 'string' ? { pageId: args['pageId'] } : {}),
          }),
        };
      case 'comment.reply':
        return { comment: this.deps.comment.reply(principal, s('commentId'), s('content')) };
      case 'comment.resolve':
        return { comment: this.deps.comment.resolve(principal, s('commentId'), true) };
      case 'export.create': {
        const rawFormat = s('format');
        const format = EXPORT_FORMATS.find((f) => f === rawFormat);
        if (!format) throw ApiError.invalidArgument(`Unsupported export format: ${rawFormat}`);
        return {
          export: this.deps.exportJob.createBoardExport(principal, s('boardId'), {
            format,
            quality: 'high',
            includeAnnotations: true,
          }),
        };
      }
      case 'export.download':
        return { download: this.deps.exportJob.download(principal, s('exportId')) };
      case 'history.undo':
        return { ...this.deps.history.undo(principal, s('boardId')) };
      case 'history.redo':
        return { ...this.deps.history.redo(principal, s('boardId')) };
      case 'history.snapshot':
        return {
          snapshot: this.deps.history.createSnapshot(
            principal,
            s('boardId'),
            typeof args['name'] === 'string' ? args['name'] : undefined,
          ),
        };
      case 'ai.session.create':
        return { session: this.deps.ai.createSession(principal, { boardId: s('boardId') }) };
      case 'ai.sendMessage': {
        const result = await this.deps.ai.sendMessage(principal, s('sessionId'), { content: s('content'), role: 'user' });
        return { message: result.message, reply: result.reply };
      }
      case 'ai.sendAudio': {
        const result = await this.deps.ai.sendAudio(principal, s('sessionId'), {
          ...(typeof args['audioBase64'] === 'string' ? { audioBase64: args['audioBase64'] } : {}),
        });
        return { accepted: result.accepted, recognizedText: result.recognizedText };
      }
      case 'ai.executeToolCall':
        return { toolCall: this.deps.ai.executeToolCall(principal, s('toolCallId')) };
      default:
        throw ApiError.notSupported(`Tool ${tool.internalToolId} is not bridged yet`, { toolId: tool.internalToolId });
    }
  }
}

/** `filter=type:sticky` 简易解析（MCP element_list 便捷参数）。 */
function parseSimpleFilter(raw: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const part of raw.split(',')) {
    const [key, value] = part.split(':', 2);
    if (key && value) out[key.trim()] = value.trim();
  }
  return out;
}
