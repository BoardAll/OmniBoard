import { z } from 'zod';

/**
 * Entity types + request validation schemas.
 *
 * Field shapes follow:
 *  - 《OpenAPI规范.md》 §5 (Boards/Pages/Elements/Connectors/Comments/Exports/History/AI/MCP)
 *  - `core/tools/schema/element.schema.json`（元素契约）
 *  - `core/tools/schema/command.schema.json`（错误/确认形状）
 *
 * Wave 2.8 采用内存仓库（`src/db/memory.ts`），Wave 4 接入真实 DB（见
 * `src/db/migrations/index.ts` 占位与 `DataStore` 接口）。
 */

/* ------------------------------------------------------------------ */
/* Scopes & roles（《OpenAPI规范.md》§3.3 / 《安全与合规设计》§4.2-4.3）  */
/* ------------------------------------------------------------------ */

export const SCOPES = [
  'board:read',
  'board:write',
  'board:share',
  'page:read',
  'page:write',
  'element:read',
  'element:write',
  'connector:read',
  'connector:write',
  'comment:read',
  'comment:write',
  'export:read',
  'history:read',
  'history:write',
  'ai:invoke',
  'mcp:invoke',
  'admin:read',
  'admin:write',
] as const;
export type Scope = (typeof SCOPES)[number];

export const ROLE_SCHEMA = z.enum(['owner', 'admin', 'editor', 'commenter', 'viewer', 'guest']);
export type Role = z.infer<typeof ROLE_SCHEMA>;

/** 可写角色（Viewer / Guest 只读）。 */
export const WRITE_ROLES: readonly Role[] = ['owner', 'admin', 'editor'];

/* ------------------------------------------------------------------ */
/* Shared primitives                                                    */
/* ------------------------------------------------------------------ */

export const POINT_SCHEMA = z.object({ x: z.number(), y: z.number() }).strict();
export type Point = z.infer<typeof POINT_SCHEMA>;

export const SIZE_SCHEMA = z
  .object({ width: z.number().nonnegative(), height: z.number().nonnegative() })
  .strict();
export type Size = z.infer<typeof SIZE_SCHEMA>;

export const VIEWPORT_SCHEMA = z
  .object({ x: z.number(), y: z.number(), zoom: z.number().positive() })
  .strict();
export type Viewport = z.infer<typeof VIEWPORT_SCHEMA>;

export const ELEMENT_TYPES = [
  'sticky',
  'text',
  'shape',
  'connector',
  'image',
  'frame',
  'mindmap',
  'table',
  'flowchart',
  'function',
  'render3d',
  'render2d',
  'document',
  'annotation',
  'group',
] as const;
export const ELEMENT_TYPE_SCHEMA = z.enum(ELEMENT_TYPES);
export type ElementType = z.infer<typeof ELEMENT_TYPE_SCHEMA>;

const JSON_OBJECT_SCHEMA = z.record(z.unknown());

/* ------------------------------------------------------------------ */
/* Boards                                                              */
/* ------------------------------------------------------------------ */

export interface Board {
  id: string;
  name: string;
  description: string | null;
  ownerId: string;
  themeId: string;
  backgroundId: string;
  shareLinkEnabled: boolean;
  createdAt: string;
  updatedAt: string;
  deletedAt: string | null;
}

export const CREATE_BOARD_SCHEMA = z
  .object({
    name: z.string().min(1).max(200),
    description: z.string().max(2000).optional(),
    themeId: z.string().min(1).max(100).optional(),
    backgroundId: z.string().min(1).max(100).optional(),
  })
  .strict();
export type CreateBoardInput = z.infer<typeof CREATE_BOARD_SCHEMA>;

export const UPDATE_BOARD_SCHEMA = z
  .object({
    name: z.string().min(1).max(200).optional(),
    description: z.string().max(2000).nullable().optional(),
    themeId: z.string().min(1).max(100).optional(),
    backgroundId: z.string().min(1).max(100).optional(),
  })
  .strict();
export type UpdateBoardInput = z.infer<typeof UPDATE_BOARD_SCHEMA>;

export const SHARE_BOARD_SCHEMA = z
  .object({
    enabled: z.boolean().optional().default(true),
    role: ROLE_SCHEMA.exclude(['owner']).optional().default('viewer'),
    expiresAt: z.string().datetime().optional(),
    password: z.string().min(4).max(128).optional(),
  })
  .strict();
export type ShareBoardInput = z.infer<typeof SHARE_BOARD_SCHEMA>;

export const COLLABORATOR_SCHEMA = z
  .object({ userId: z.string().min(1).max(100), role: ROLE_SCHEMA })
  .strict();
export type CollaboratorInput = z.infer<typeof COLLABORATOR_SCHEMA>;

export interface Collaborator {
  boardId: string;
  userId: string;
  role: Role;
  addedBy: string;
  addedAt: string;
}

export interface ShareLink {
  boardId: string;
  token: string;
  role: Role;
  passwordProtected: boolean;
  enabled: boolean;
  expiresAt: string | null;
  createdAt: string;
}

/* ------------------------------------------------------------------ */
/* Pages                                                               */
/* ------------------------------------------------------------------ */

export interface Page {
  id: string;
  boardId: string;
  name: string;
  backgroundId: string | null;
  viewport: Viewport;
  index: number;
  locked: boolean;
  hidden: boolean;
  createdAt: string;
  updatedAt: string;
}

export const CREATE_PAGE_SCHEMA = z
  .object({
    name: z.string().min(1).max(200),
    backgroundId: z.string().min(1).max(100).optional(),
    viewport: VIEWPORT_SCHEMA.optional(),
  })
  .strict();
export type CreatePageInput = z.infer<typeof CREATE_PAGE_SCHEMA>;

export const UPDATE_PAGE_SCHEMA = z
  .object({
    name: z.string().min(1).max(200).optional(),
    backgroundId: z.string().min(1).max(100).nullable().optional(),
    viewport: VIEWPORT_SCHEMA.optional(),
    locked: z.boolean().optional(),
    hidden: z.boolean().optional(),
  })
  .strict();
export type UpdatePageInput = z.infer<typeof UPDATE_PAGE_SCHEMA>;

export const MOVE_PAGE_SCHEMA = z.object({ index: z.number().int().min(0) }).strict();

/** 拆分页面（文档未定义请求体，RESTful 约定：按 y 轴切分元素）。 */
export const SPLIT_PAGE_SCHEMA = z
  .object({ splitY: z.number(), name: z.string().min(1).max(200).optional() })
  .strict();

/** 合并页面（文档未定义请求体，RESTful 约定：pageIds[0] 为目标页）。 */
export const MERGE_PAGES_SCHEMA = z
  .object({ pageIds: z.array(z.string().min(1)).min(2), name: z.string().min(1).max(200).optional() })
  .strict();

/* ------------------------------------------------------------------ */
/* Elements                                                            */
/* ------------------------------------------------------------------ */

export interface Element {
  id: string;
  pageId: string;
  boardId: string;
  type: ElementType;
  name: string | null;
  position: Point;
  size: Size;
  rotation: number;
  opacity: number;
  zIndex: number;
  locked: boolean;
  hidden: boolean;
  groupId: string | null;
  style: Record<string, unknown>;
  data: Record<string, unknown>;
  createdAt: string;
  updatedAt: string;
  createdBy: string;
  updatedBy: string;
}

export const CREATE_ELEMENT_SCHEMA = z
  .object({
    type: ELEMENT_TYPE_SCHEMA,
    name: z.string().max(200).optional(),
    /** `text` 便捷字段（sticky/text 常用），存入 data.text。 */
    text: z.string().max(10000).optional(),
    position: POINT_SCHEMA.optional(),
    size: SIZE_SCHEMA.optional(),
    rotation: z.number().optional(),
    opacity: z.number().min(0).max(1).optional(),
    zIndex: z.number().int().optional(),
    locked: z.boolean().optional(),
    hidden: z.boolean().optional(),
    groupId: z.string().optional(),
    style: JSON_OBJECT_SCHEMA.optional(),
    data: JSON_OBJECT_SCHEMA.optional(),
  })
  .strict();
export type CreateElementInput = z.infer<typeof CREATE_ELEMENT_SCHEMA>;

export const CREATE_ELEMENTS_SCHEMA = z
  .object({
    elements: z.array(CREATE_ELEMENT_SCHEMA).min(1).max(1000),
    dryRun: z.boolean().optional().default(false),
  })
  .strict();
export type CreateElementsInput = z.infer<typeof CREATE_ELEMENTS_SCHEMA>;

export const UPDATE_ELEMENT_SCHEMA = z
  .object({
    name: z.string().max(200).nullable().optional(),
    text: z.string().max(10000).optional(),
    position: POINT_SCHEMA.optional(),
    size: SIZE_SCHEMA.optional(),
    rotation: z.number().optional(),
    opacity: z.number().min(0).max(1).optional(),
    zIndex: z.number().int().optional(),
    locked: z.boolean().optional(),
    hidden: z.boolean().optional(),
    style: JSON_OBJECT_SCHEMA.optional(),
    data: JSON_OBJECT_SCHEMA.optional(),
  })
  .strict();
export type UpdateElementInput = z.infer<typeof UPDATE_ELEMENT_SCHEMA>;

export const ELEMENT_BATCH_SCHEMA = z
  .object({
    operations: z
      .array(
        z.discriminatedUnion('op', [
          z.object({
            op: z.literal('create'),
            pageId: z.string().min(1),
            element: CREATE_ELEMENT_SCHEMA,
          }),
          z.object({ op: z.literal('update'), elementId: z.string().min(1), patch: UPDATE_ELEMENT_SCHEMA }),
          z.object({ op: z.literal('delete'), elementId: z.string().min(1) }),
          z.object({ op: z.literal('move'), elementId: z.string().min(1), position: POINT_SCHEMA }),
        ]),
      )
      .min(1)
      .max(500),
    dryRun: z.boolean().optional().default(false),
    /** 批量操作含删除时为破坏性操作（《安全与合规设计》§9.6），需 confirm=true。 */
    confirm: z.boolean().optional(),
  })
  .strict();
export type ElementBatchInput = z.infer<typeof ELEMENT_BATCH_SCHEMA>;

export const SET_STYLE_SCHEMA = z
  .object({ style: JSON_OBJECT_SCHEMA, merge: z.boolean().optional().default(true) })
  .strict();

export const MOVE_ELEMENT_SCHEMA = z
  .object({ position: POINT_SCHEMA.optional(), dx: z.number().optional(), dy: z.number().optional() })
  .strict();

export const RESIZE_ELEMENT_SCHEMA = z
  .object({
    size: SIZE_SCHEMA.optional(),
    width: z.number().nonnegative().optional(),
    height: z.number().nonnegative().optional(),
  })
  .strict();

export const ALIGN_SCHEMA = z
  .object({
    elementIds: z.array(z.string().min(1)).min(2).max(1000),
    alignment: z.enum(['left', 'right', 'top', 'bottom', 'centerX', 'centerY']),
    relativeTo: z.string().optional(),
  })
  .strict();

export const DISTRIBUTE_SCHEMA = z
  .object({
    elementIds: z.array(z.string().min(1)).min(3).max(1000),
    axis: z.enum(['horizontal', 'vertical']),
  })
  .strict();

export const GROUP_SCHEMA = z.object({ elementIds: z.array(z.string().min(1)).min(2).max(1000) }).strict();
export const UNGROUP_SCHEMA = z.object({ groupId: z.string().min(1) }).strict();

/* ------------------------------------------------------------------ */
/* Connectors                                                          */
/* ------------------------------------------------------------------ */

export const CONNECTOR_STYLES = ['straight', 'orthogonal', 'curved'] as const;
export const ARROW_TYPES = ['none', 'solid', 'hollow', 'open'] as const;

export interface Connector {
  id: string;
  pageId: string;
  boardId: string;
  fromElementId: string;
  toElementId: string;
  fromAnchor: string;
  toAnchor: string;
  style: (typeof CONNECTOR_STYLES)[number];
  arrowStart: (typeof ARROW_TYPES)[number];
  arrowEnd: (typeof ARROW_TYPES)[number];
  label: string | null;
  waypoints: Point[];
  autoRoute: boolean;
  createdAt: string;
  updatedAt: string;
}

export const CREATE_CONNECTOR_SCHEMA = z
  .object({
    fromElementId: z.string().min(1),
    toElementId: z.string().min(1),
    fromAnchor: z.string().max(50).optional(),
    toAnchor: z.string().max(50).optional(),
    style: z.enum(CONNECTOR_STYLES).optional(),
    arrowStart: z.enum(ARROW_TYPES).optional(),
    arrowEnd: z.enum(ARROW_TYPES).optional(),
    label: z.string().max(500).optional(),
    waypoints: z.array(POINT_SCHEMA).max(100).optional(),
    autoRoute: z.boolean().optional(),
  })
  .strict();
export type CreateConnectorInput = z.infer<typeof CREATE_CONNECTOR_SCHEMA>;

export const UPDATE_CONNECTOR_SCHEMA = CREATE_CONNECTOR_SCHEMA.partial().extend({
  label: z.string().max(500).nullable().optional(),
});
export type UpdateConnectorInput = z.infer<typeof UPDATE_CONNECTOR_SCHEMA>;

/* ------------------------------------------------------------------ */
/* Comments                                                            */
/* ------------------------------------------------------------------ */

export interface Comment {
  id: string;
  boardId: string;
  pageId: string | null;
  elementId: string | null;
  authorId: string;
  content: string;
  parentId: string | null;
  resolved: boolean;
  createdAt: string;
  updatedAt: string;
}

export const CREATE_COMMENT_SCHEMA = z
  .object({
    boardId: z.string().min(1),
    pageId: z.string().min(1).optional(),
    elementId: z.string().min(1).optional(),
    content: z.string().min(1).max(5000),
    parentId: z.string().min(1).optional(),
  })
  .strict();
export type CreateCommentInput = z.infer<typeof CREATE_COMMENT_SCHEMA>;

export const COMMENT_CONTENT_SCHEMA = z.object({ content: z.string().min(1).max(5000) }).strict();
export const RESOLVE_COMMENT_SCHEMA = z.object({ resolved: z.boolean().optional().default(true) }).strict();

/* ------------------------------------------------------------------ */
/* Exports                                                             */
/* ------------------------------------------------------------------ */

export const EXPORT_FORMATS = ['pdf', 'png', 'svg', 'json', 'markdown'] as const;
export const EXPORT_QUALITIES = ['low', 'medium', 'high'] as const;
export type ExportStatus = 'pending' | 'processing' | 'completed' | 'failed';

export interface ExportJob {
  id: string;
  boardId: string | null;
  pageId: string | null;
  format: (typeof EXPORT_FORMATS)[number];
  quality: (typeof EXPORT_QUALITIES)[number];
  includeAnnotations: boolean;
  pages: string[] | null;
  status: ExportStatus;
  sizeBytes: number | null;
  downloadUrl: string | null;
  createdAt: string;
  completedAt: string | null;
  requestedBy: string;
}

export const CREATE_EXPORT_SCHEMA = z
  .object({
    format: z.enum(EXPORT_FORMATS),
    pages: z.array(z.string().min(1)).max(500).optional(),
    includeAnnotations: z.boolean().optional().default(true),
    quality: z.enum(EXPORT_QUALITIES).optional().default('high'),
  })
  .strict();
export type CreateExportInput = z.infer<typeof CREATE_EXPORT_SCHEMA>;

/* ------------------------------------------------------------------ */
/* History                                                             */
/* ------------------------------------------------------------------ */

export interface HistoryEntry {
  id: string;
  boardId: string;
  seq: number;
  action: string;
  resourceType: string;
  resourceId: string | null;
  status: 'applied' | 'undone';
  params: Record<string, unknown>;
  userId: string;
  createdAt: string;
}

export interface Snapshot {
  id: string;
  boardId: string;
  name: string;
  seq: number;
  createdBy: string;
  createdAt: string;
}

export const CREATE_SNAPSHOT_SCHEMA = z.object({ name: z.string().min(1).max(200).optional() }).strict();
export const UNDO_REDO_SCHEMA = z.object({ transactionId: z.string().optional() }).strict();

/* ------------------------------------------------------------------ */
/* AI                                                                  */
/* ------------------------------------------------------------------ */

export interface AISession {
  id: string;
  boardId: string;
  userId: string;
  provider: string;
  model: string;
  status: 'active' | 'completed' | 'cancelled';
  createdAt: string;
  updatedAt: string;
}

export interface AIMessage {
  id: string;
  sessionId: string;
  role: 'user' | 'assistant' | 'system' | 'tool';
  content: string;
  source: 'text' | 'audio';
  createdAt: string;
}

export type AIToolCallStatus = 'pending' | 'previewed' | 'executed' | 'cancelled' | 'failed';

export interface AIToolCall {
  id: string;
  sessionId: string;
  toolId: string;
  args: Record<string, unknown>;
  status: AIToolCallStatus;
  preview: Record<string, unknown> | null;
  result: Record<string, unknown> | null;
  createdAt: string;
  updatedAt: string;
}

export const CREATE_AI_SESSION_SCHEMA = z
  .object({
    boardId: z.string().min(1),
    provider: z.string().min(1).max(50).optional(),
    model: z.string().min(1).max(100).optional(),
  })
  .strict();
export type CreateAISessionInput = z.infer<typeof CREATE_AI_SESSION_SCHEMA>;

/**
 * `toolCalls` 为 Wave 2.8 约定字段：客户端（或测试）可随消息提交计划中的
 * 工具调用，之后通过 /ai/toolCalls/{id}/preview|execute|cancel 操作。
 */
export const SEND_AI_MESSAGE_SCHEMA = z
  .object({
    content: z.string().min(1).max(8000),
    role: z.enum(['user', 'system']).optional().default('user'),
    toolCalls: z
      .array(z.object({ toolId: z.string().min(1), args: JSON_OBJECT_SCHEMA.optional() }))
      .max(50)
      .optional(),
  })
  .strict();
export type SendAIMessageInput = z.infer<typeof SEND_AI_MESSAGE_SCHEMA>;

export const SEND_AI_AUDIO_SCHEMA = z
  .object({
    audioBase64: z.string().max(10_000_000).optional(),
    mimeType: z.string().max(100).optional(),
    language: z.string().max(20).optional(),
  })
  .strict();
export type SendAIAudioInput = z.infer<typeof SEND_AI_AUDIO_SCHEMA>;

/* ------------------------------------------------------------------ */
/* Audit & idempotency（《安全与合规设计》§14.2 / §11.3）               */
/* ------------------------------------------------------------------ */

export interface AuditEntry {
  id: string;
  /** when */
  timestamp: string;
  /** who */
  who: string;
  /** what */
  action: string;
  /** target */
  target: { type: string; id: string | null };
  /** result */
  result: { ok: boolean; status: number };
  requestId: string;
  ip: string;
  userAgent: string;
  boardId: string | null;
  tenantId: string | null;
  fromAI: boolean;
  /** 已脱敏的请求参数摘要（截断）。 */
  argsJson: string | null;
}

export interface IdempotencyRecord {
  key: string;
  fingerprint: string;
  status: number;
  body: unknown;
  createdAt: number;
  expiresAt: number;
}
