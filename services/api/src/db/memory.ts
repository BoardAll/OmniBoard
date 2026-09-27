import type {
  AISession,
  AIMessage,
  AIToolCall,
  Board,
  Collaborator,
  Comment,
  Connector,
  Element,
  ExportJob,
  HistoryEntry,
  Page,
  ShareLink,
  Snapshot,
} from './schema.js';

/**
 * Repository abstraction.
 *
 * Wave 2.8 使用进程内 Map 实现（`createMemoryStore`）；接口保持窄且纯粹，
 * Wave 4 可在 `src/db/migrations/` 中接入 PostgreSQL/Redis 的真实实现，
 * 替换 `app.ts` 的 store 注入即可，无需修改 service/route 层。
 */
export interface DataStore {
  boards: Map<string, Board>;
  pages: Map<string, Page>;
  elements: Map<string, Element>;
  connectors: Map<string, Connector>;
  comments: Map<string, Comment>;
  exportJobs: Map<string, ExportJob>;
  history: Map<string, HistoryEntry>;
  snapshots: Map<string, Snapshot>;
  collaborators: Map<string, Collaborator>;
  shareLinks: Map<string, ShareLink>;
  aiSessions: Map<string, AISession>;
  aiMessages: Map<string, AIMessage>;
  aiToolCalls: Map<string, AIToolCall>;
}

export function createMemoryStore(): DataStore {
  return {
    boards: new Map(),
    pages: new Map(),
    elements: new Map(),
    connectors: new Map(),
    comments: new Map(),
    exportJobs: new Map(),
    history: new Map(),
    snapshots: new Map(),
    collaborators: new Map(),
    shareLinks: new Map(),
    aiSessions: new Map(),
    aiMessages: new Map(),
    aiToolCalls: new Map(),
  };
}

/** 组合键：`${boardId}:${userId}`（协作者/分享链接按白板分组）。 */
export function boardUserKey(boardId: string, userId: string): string {
  return `${boardId}:${userId}`;
}
