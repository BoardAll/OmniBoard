/**
 * MCP 会话管理（《MCP_Server详细设计》§11.3）。
 *
 * - stdio：进程级单会话（固定 id）；
 * - SSE / Streamable HTTP：按 `Mcp-Session-Id` 区分；
 * - 握手元数据复用 protocol/initialize.ts 的 `SessionMeta`。
 */

import { randomUUID } from 'node:crypto';
import { createSession, type SessionMeta } from './protocol/initialize.js';

export interface McpSessionState {
  id: string;
  meta: SessionMeta;
  createdAt: string;
  lastActiveAt: string;
  /** logging/setLevel 设置的会话日志级别。 */
  logLevel: string | null;
  closed: boolean;
}

export class SessionStore {
  private readonly sessions = new Map<string, McpSessionState>();

  /** 创建会话（不传 id 时生成 `sess_<16hex>`）。 */
  create(id?: string): McpSessionState {
    const sessionId = id ?? `sess_${randomUUID().replace(/-/g, '').slice(0, 16)}`;
    const now = new Date().toISOString();
    const state: McpSessionState = {
      id: sessionId,
      meta: createSession(),
      createdAt: now,
      lastActiveAt: now,
      logLevel: null,
      closed: false,
    };
    this.sessions.set(sessionId, state);
    return state;
  }

  get(id: string): McpSessionState | undefined {
    return this.sessions.get(id);
  }

  getOrCreate(id: string): McpSessionState {
    return this.get(id) ?? this.create(id);
  }

  touch(id: string): void {
    const state = this.sessions.get(id);
    if (state) state.lastActiveAt = new Date().toISOString();
  }

  delete(id: string): boolean {
    return this.sessions.delete(id);
  }

  get size(): number {
    return this.sessions.size;
  }
}
