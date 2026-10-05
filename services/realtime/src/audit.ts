/**
 * 审计（M1 完整版 / T1.3 + M2 锁生命周期 + M3 互动模式；《互动白板实时协同设计文档》§7 / D4，对齐 api/mcp 审计模式）。
 *
 * 审计范围：
 * - 认证结果、房间生命周期（join/leave/cleanup）、权限拒绝（authz.denied / lock.denied）；
 * - 锁生命周期（acquire 成功 / 拒绝、release、expired；renew 心跳与 presence 高频流不落审计）；
 * - M3-T3.3 管理操作必落：interactive.grantControl / revokeControl / startPresent / stopPresent /
 *   removeUser / hostChanged / hostConflict；房主自举 hostBootstrapped；checkpoint.requested / stored / denied；
 * - M3-T3.3 ops 采样：每 32 条入站（已接受）op 落 1 条 `ops.sampled`（防审计膨胀）；
 *   举手 / 跟随（raiseHand / lowerHand / follow / unfollow）为低频用户行为，不落审计。
 *
 * 脱敏约束（对齐 services/api §14.4 / services/mcp_server §10）：
 * 仅保留 {时间、用户、动作、目标、结果} 及 boardId / 结果摘要；
 * **不记录** token、凭据、op 内容原文、checkpoint payload 内容等敏感信息
 * （checkpoint 仅记 size 元数据）。
 *
 * Sink 选择：注入（测试 / 嵌入）> `WB_REALTIME_AUDIT_LOG`（JSONL 落盘）> stderr（默认，对齐 mcp）。
 * 审计失败不影响业务（record 内部吞错）。
 */

import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export type AuditResult = 'success' | 'denied' | 'error';

export interface AuditTarget {
  type: string;
  id: string | null;
}

export interface AuditEntry {
  /** ISO-8601 UTC。 */
  timestamp: string;
  /** 认证主体；未认证 / 系统事件为 'anonymous' / 'system'。 */
  userId: string;
  /**
   * 动作：auth.connect / auth.anonymous / auth.rejected / authz.denied /
   * room.join / room.leave / room.cleanup /
   * lock.acquired / lock.denied / lock.released / lock.expired /
   * interactive.grantControl / interactive.revokeControl / interactive.startPresent /
   * interactive.stopPresent / interactive.removeUser / interactive.hostChanged / interactive.hostConflict /
   * interactive.hostBootstrapped /
   * checkpoint.requested / checkpoint.stored / checkpoint.denied / ops.sampled。
   */
  action: string;
  target: AuditTarget | null;
  result: AuditResult;
  boardId?: string;
  /** 固定 'socket'（对齐 mcp 的 transport 字段）。 */
  transport: 'socket';
  /** 结果摘要（失败 / 回落原因；不含凭据、op 原文与 payload 内容）。 */
  detail?: string;
}

export interface AuditSink {
  record(entry: AuditEntry): void;
}

export interface AuditEntryInit {
  userId?: string | null;
  action: string;
  target?: AuditTarget | null;
  result: AuditResult;
  boardId?: string;
  detail?: string;
}

/** 构造审计条目（自动补时间戳 / transport）。 */
export function buildAuditEntry(init: AuditEntryInit): AuditEntry {
  const entry: AuditEntry = {
    timestamp: new Date().toISOString(),
    userId: init.userId && init.userId.length > 0 ? init.userId : 'anonymous',
    action: init.action,
    target: init.target ?? null,
    result: init.result,
    transport: 'socket',
  };
  if (init.boardId !== undefined) entry.boardId = init.boardId;
  if (init.detail !== undefined) entry.detail = init.detail;
  return entry;
}

/** 内存审计收集器（测试 / 集成断言用）。 */
export class MemoryAuditSink implements AuditSink {
  readonly entries: AuditEntry[] = [];

  record(entry: AuditEntry): void {
    this.entries.push(entry);
  }
}

/** 默认审计输出：单行 JSON（JSONL）写 stderr。 */
export class StderrAuditSink implements AuditSink {
  constructor(private readonly write: (line: string) => void = (line) => void process.stderr.write(line)) {}

  record(entry: AuditEntry): void {
    this.write(`[audit] ${JSON.stringify(entry)}\n`);
  }
}

/** JSONL 落盘（每行一个 JSON；`WB_REALTIME_AUDIT_LOG` 配置路径）。 */
export class JsonlFileAuditSink implements AuditSink {
  constructor(private readonly filePath: string) {
    try {
      mkdirSync(dirname(filePath), { recursive: true });
    } catch {
      // 目录创建失败延迟到写入时处理（record 内吞错）。
    }
  }

  record(entry: AuditEntry): void {
    try {
      appendFileSync(this.filePath, `${JSON.stringify(entry)}\n`, 'utf8');
    } catch {
      // 审计失败不影响业务（对齐 api/mcp）；不重试、不回显内容。
    }
  }
}

/** 依据环境变量选择审计输出：`WB_REALTIME_AUDIT_LOG` → JSONL 文件；否则 stderr。 */
export function createAuditSinkFromEnv(env: NodeJS.ProcessEnv = process.env): AuditSink {
  const file = env['WB_REALTIME_AUDIT_LOG'];
  if (typeof file === 'string' && file.trim().length > 0) {
    return new JsonlFileAuditSink(file.trim());
  }
  return new StderrAuditSink();
}
