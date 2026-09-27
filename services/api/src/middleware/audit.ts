import type { NextFunction, Request, RequestHandler, Response } from 'express';
import { newId } from '../lib/ids.js';
import type { AuditEntry } from '../db/schema.js';

/**
 * 审计（《安全与合规设计》§14.2、《OpenAPI规范.md》§10）。
 *
 * 记录结构（who / what / when / target / result + 关联字段）：
 *  - who    = 用户 ID（未认证为 anonymous）
 *  - what   = 动作（路由显式设置，如 board.create；否则退回 `METHOD path`）
 *  - when   = ISO 8601 UTC 时间戳
 *  - target = { type, id }
 *  - result = { ok, status }
 *  - 附加：requestId / ip / userAgent / boardId / tenantId / fromAI / argsJson(脱敏截断)
 *
 * 脱敏（§5.3 / §14.4）：
 *  - 键级：Authorization / X-API-Key / password / token / secret 等敏感键 → `***`；
 *  - 值级（`maskPii`）：邮箱、手机号、身份证、银行卡以掩码形式落盘。
 *
 * 凭据（Authorization / X-API-Key / password / token / secret）绝不进入审计。
 */

export interface AuditTarget {
  type: string;
  id: string | null;
}

export interface AuditStore {
  record(entry: AuditEntry): void;
}

export class InMemoryAuditStore implements AuditStore {
  readonly entries: AuditEntry[] = [];

  record(entry: AuditEntry): void {
    this.entries.push(entry);
  }

  list(filter: Partial<Pick<AuditEntry, 'who' | 'action' | 'requestId'>> = {}): AuditEntry[] {
    return this.entries.filter(
      (e) =>
        (filter.who === undefined || e.who === filter.who) &&
        (filter.action === undefined || e.action === filter.action) &&
        (filter.requestId === undefined || e.requestId === filter.requestId),
    );
  }

  clear(): void {
    this.entries.length = 0;
  }
}

export interface AuditContextInput {
  action?: string;
  target?: AuditTarget;
  boardId?: string | null;
  argsJson?: string | null;
  fromAI?: boolean;
}

interface PendingAudit {
  action?: string;
  target?: AuditTarget;
  boardId?: string | null;
  argsJson?: string | null;
  fromAI?: boolean;
}

function pending(res: Response): PendingAudit {
  const locals = res.locals as Record<string, unknown>;
  if (typeof locals['audit'] !== 'object' || locals['audit'] === null) {
    locals['audit'] = {};
  }
  return locals['audit'] as PendingAudit;
}

/** 路由内调用：声明本请求的审计动作/目标。 */
export function auditContext(res: Response, input: AuditContextInput): void {
  const state = pending(res);
  if (input.action !== undefined) state.action = input.action;
  if (input.target) state.target = input.target;
  if (input.boardId !== undefined) state.boardId = input.boardId;
  if (input.argsJson !== undefined) state.argsJson = input.argsJson;
  if (input.fromAI !== undefined) state.fromAI = input.fromAI;
}

const SENSITIVE_KEY_PATTERN = /(password|secret|token|authorization|api[-_]?key|credential)/i;

/**
 * 值级 PII 掩码（§14.4）：
 *  - 邮箱：`alice@example.com` → `a***@example.com`（保留域名）；
 *  - 身份证：保留前 4 后 4，如 `1101**********1234`；
 *  - 银行卡：保留后 4，如 `************0123`；
 *  - 手机号：`13812345678` → `138****5678`。
 *
 * 数字模式均带 `(?<!\d)` / `(?!\d)` 边界，避免命中更长数字串的片段；
 * 身份证先于银行卡处理（18 位纯数字同时满足两者）。
 */
const EMAIL_PATTERN = /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g;
const ID_CARD_PATTERN = /(?<!\d)\d{17}[\dXx](?!\d)/g;
const BANK_CARD_PATTERN = /(?<!\d)\d{16,19}(?!\d)/g;
const PHONE_CN_PATTERN = /(?<!\d)1[3-9]\d{9}(?!\d)/g;

export function maskPii(value: string): string {
  let out = value;
  out = out.replace(EMAIL_PATTERN, (match) => {
    const at = match.indexOf('@');
    const local = match.slice(0, at);
    return `${local.slice(0, 1)}***${match.slice(at)}`;
  });
  out = out.replace(
    ID_CARD_PATTERN,
    (match) => `${match.slice(0, 4)}${'*'.repeat(match.length - 8)}${match.slice(-4)}`,
  );
  out = out.replace(BANK_CARD_PATTERN, (match) => `${'*'.repeat(match.length - 4)}${match.slice(-4)}`);
  out = out.replace(PHONE_CN_PATTERN, (match) => `${match.slice(0, 3)}****${match.slice(-4)}`);
  return out;
}

/** 深度脱敏：敏感键替换为 `***`（§14.4 密码/Token），字符串值做 PII 掩码，数组/对象递归，截断以控制体积。 */
export function redactSensitive(value: unknown, depth = 0): unknown {
  if (depth > 6) return '[truncated]';
  if (Array.isArray(value)) return value.slice(0, 50).map((v) => redactSensitive(v, depth + 1));
  if (typeof value === 'object' && value !== null) {
    const out: Record<string, unknown> = {};
    for (const [key, v] of Object.entries(value as Record<string, unknown>)) {
      out[key] = SENSITIVE_KEY_PATTERN.test(key) ? '***' : redactSensitive(v, depth + 1);
    }
    return out;
  }
  if (typeof value === 'string') return maskPii(value);
  return value;
}

/** 脱敏后的 JSON 摘要（审计 argsJson 字段），默认截断 2KB。 */
export function summariseArgs(value: unknown, maxLength = 2048): string | null {
  if (value === undefined || value === null) return null;
  try {
    const text = JSON.stringify(redactSensitive(value));
    if (text === undefined) return null;
    return text.length > maxLength ? `${text.slice(0, maxLength)}…(truncated)` : text;
  } catch {
    return null;
  }
}

function targetFromParams(req: Request): AuditTarget | null {
  const candidates: Array<[string, string]> = [
    ['boardId', 'board'],
    ['pageId', 'page'],
    ['elementId', 'element'],
    ['connectorId', 'connector'],
    ['commentId', 'comment'],
    ['exportId', 'export'],
    ['sessionId', 'ai_session'],
    ['toolCallId', 'ai_tool_call'],
    ['toolName', 'mcp_tool'],
    ['userId', 'user'],
  ];
  for (const [param, type] of candidates) {
    const value = req.params[param];
    if (typeof value === 'string' && value.length > 0) return { type, id: value };
  }
  return null;
}

function defaultAction(req: Request): string {
  const routePath = typeof req.route?.path === 'string' ? req.route.path : req.path;
  return `${req.method} ${req.baseUrl}${routePath}`;
}

/** 审计中间件：在响应完成时落一条审计（对 4xx/5xx 同样记录）。 */
export function auditMiddleware(store: AuditStore): RequestHandler {
  return (req: Request, res: Response, next: NextFunction) => {
    res.on('finish', () => {
      const state = pending(res);
      const principal = req.principal;
      const entry: AuditEntry = {
        id: newId('audit'),
        timestamp: new Date().toISOString(),
        who: principal?.userId ?? 'anonymous',
        action: state.action ?? defaultAction(req),
        target: state.target ?? targetFromParams(req) ?? { type: 'unknown', id: null },
        result: { ok: res.statusCode < 400, status: res.statusCode },
        requestId: req.requestId ?? '',
        ip: req.ip ?? '',
        userAgent: req.header('user-agent') ?? '',
        boardId: state.boardId ?? req.params['boardId'] ?? null,
        tenantId: principal?.tenantId ?? null,
        fromAI: state.fromAI ?? false,
        argsJson: state.argsJson ?? null,
      };
      try {
        store.record(entry);
      } catch {
        // 审计失败不影响业务响应。
      }
    });
    next();
  };
}
