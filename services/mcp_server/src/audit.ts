/**
 * 审计（《MCP_Server详细设计》§10）。
 *
 * 审计范围：tools/call、resources/read、认证成功/失败、权限拒绝、速率限制、确认操作。
 * 脱敏约束：仅保留 {时间、用户、动作、目标、结果} 及客户端标识；
 * **不记录** 参数原文、token、API Key 等敏感信息。
 */

export type AuditResult = 'success' | 'denied' | 'error';

export interface AuditTarget {
  type: string;
  id?: string;
}

export interface AuditEntry {
  timestamp: string;
  /** 认证主体；未认证场景为 'anonymous'。 */
  userId: string;
  clientName: string | null;
  clientVersion: string | null;
  /** 动作：auth.authenticate / tool.call / resource.read / ... */
  action: string;
  target: AuditTarget | null;
  result: AuditResult;
  /** MCP 调用可能来自 AI 客户端，固定 true（§10.2）。 */
  fromAI: boolean;
  boardId?: string;
  transport: 'stdio' | 'sse' | 'http' | 'internal';
  ip?: string;
}

export interface AuditSink {
  record(entry: AuditEntry): void;
}

/** 默认审计输出：单行 JSON 写 stderr（stdio 下不污染 stdout 协议流）。 */
export class StderrAuditSink implements AuditSink {
  constructor(private readonly write: (line: string) => void = (line) => void process.stderr.write(line)) {}

  record(entry: AuditEntry): void {
    this.write(`[audit] ${JSON.stringify(entry)}\n`);
  }
}

/** 内存审计收集器（测试 / 集成断言用）。 */
export class MemoryAuditSink implements AuditSink {
  readonly entries: AuditEntry[] = [];

  record(entry: AuditEntry): void {
    this.entries.push(entry);
  }
}

/** 空实现（嵌入场景禁用审计时使用）。 */
export const NULL_AUDIT_SINK: AuditSink = { record(): void {} };

export interface AuditEventInit {
  userId?: string | null;
  clientName?: string | null;
  clientVersion?: string | null;
  action: string;
  target?: AuditTarget | null;
  result: AuditResult;
  boardId?: string;
  transport: AuditEntry['transport'];
  ip?: string;
}

/** 构造审计条目（自动补时间戳 / fromAI）。 */
export function buildAuditEntry(init: AuditEventInit): AuditEntry {
  const entry: AuditEntry = {
    timestamp: new Date().toISOString(),
    userId: init.userId && init.userId.length > 0 ? init.userId : 'anonymous',
    clientName: init.clientName ?? null,
    clientVersion: init.clientVersion ?? null,
    action: init.action,
    target: init.target ?? null,
    result: init.result,
    fromAI: true,
    transport: init.transport,
  };
  if (init.boardId !== undefined) entry.boardId = init.boardId;
  if (init.ip !== undefined) entry.ip = init.ip;
  return entry;
}
