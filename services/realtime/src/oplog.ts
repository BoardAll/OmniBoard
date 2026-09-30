/**
 * op 环形日志（M1 完整版 / T1.3；《互动白板实时协同设计文档》§5.4 / §7 / §10）。
 *
 * 服务端只记"流水账"：去重 / 水位 / 裁差分 / 转发，**不做 CRDT 合并**
 * （合并语义唯一权威在客户端引擎，避免 Node 侧出现第二套语义）。
 *
 * - 环形容量 `DEFAULT_OPLOG_CAPACITY`（每房间 ≤ 10k 条，§10）；超出淘汰最旧；
 * - 水位 = 每 actor 最大**连续** seq（stateVector 语义，§5.3）；
 * - 去重：`seq ≤ 水位` 即已见（含被环形淘汰的历史，幂等重放直接 ack dup）；
 * - gap 检测：`seq > 水位 + 1` 时回报缺失区间（上限 `MAX_MISSING_SEQS` 防御巨大跳变）。
 */

import type { BoardStateVector, Op } from './types.js';

/** 每房间 op 日志容量（§10：内存目标 ≤ 10k 条）。 */
export const DEFAULT_OPLOG_CAPACITY = 10_000;

/** missingSeqs 回报上限（防恶意 / 异常跳变制造的巨型数组）。 */
export const MAX_MISSING_SEQS = 100;

export class OpLog {
  private readonly capacity: number;
  private readonly ring: Array<Op | undefined>;
  private start = 0;
  private size = 0;
  private readonly watermarks = new Map<string, number>();

  constructor(capacity: number = DEFAULT_OPLOG_CAPACITY) {
    if (!Number.isInteger(capacity) || capacity < 1) {
      throw new Error(`Invalid oplog capacity "${String(capacity)}" (expected integer >= 1)`);
    }
    this.capacity = capacity;
    this.ring = new Array<Op | undefined>(capacity).fill(undefined);
  }

  /** 当前保留的 op 条数（≤ capacity）。 */
  get count(): number {
    return this.size;
  }

  /** 指定 actor 的连续水位（无记录 = 0）。 */
  watermark(actor: string): number {
    return this.watermarks.get(actor) ?? 0;
  }

  /** 版本水位快照（每 actor 最大连续 seq）。 */
  stateVector(): BoardStateVector {
    const out: BoardStateVector = {};
    for (const [actor, seq] of this.watermarks) {
      out[actor] = seq;
    }
    return out;
  }

  /** 已见判定：(actor,seq) 重复 ⇔ seq ≤ 水位。 */
  isDuplicate(actor: string, seq: number): boolean {
    return seq <= this.watermark(actor);
  }

  /**
   * gap 检测：`seq === 水位 + 1` 为接续（返回 null）；
   * `seq > 水位 + 1` 返回缺失 seq 列表（`水位+1 .. seq-1`，上限 `MAX_MISSING_SEQS`）。
   */
  missingSeqsFor(actor: string, seq: number): number[] | null {
    const watermark = this.watermark(actor);
    if (seq <= watermark + 1) return null;
    const missing: number[] = [];
    for (let candidate = watermark + 1; candidate < seq && missing.length < MAX_MISSING_SEQS; candidate += 1) {
      missing.push(candidate);
    }
    return missing;
  }

  /** 追加连续 op（调用方须先保证 `seq === 水位 + 1`）。 */
  append(op: Op): void {
    if (this.size === this.capacity) {
      // 环形淘汰最旧。
      this.ring[this.start] = op;
      this.start = (this.start + 1) % this.capacity;
    } else {
      this.ring[(this.start + this.size) % this.capacity] = op;
      this.size += 1;
    }
    this.watermarks.set(op.actor, op.seq);
  }

  /** 取 actor 的 `seq > fromSeq` 的 op（按日志顺序；fetchOps 裁差分）。 */
  fetchSince(actor: string, fromSeq: number): Op[] {
    return this.toArray().filter((op) => op.actor === actor && op.seq > fromSeq);
  }

  /** 按客户端水位裁差分：每 actor 返回 `seq > vector[actor]` 的 op（join / joinAck 回放）。 */
  fetchAfter(vector: BoardStateVector): Op[] {
    return this.toArray().filter((op) => op.seq > (vector[op.actor] ?? 0));
  }

  /** 当前保留的 op（按日志顺序）。 */
  toArray(): Op[] {
    const out: Op[] = [];
    for (let i = 0; i < this.size; i += 1) {
      const op = this.ring[(this.start + i) % this.capacity];
      if (op !== undefined) out.push(op);
    }
    return out;
  }
}

/**
 * 解析 / 校验入站 op（防御式）：
 * - `actor`：非空字符串；`seq`：正整数；`key`：非空字符串；
 * - `timestamp` / `origin`：出现时须为合法类型（number / string）；
 * - `value`：任意 JSON 值（服务端不解释）。
 */
export function parseOp(raw: unknown): Op | null {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null;
  const candidate = raw as Record<string, unknown>;
  const actor = candidate['actor'];
  const seq = candidate['seq'];
  const key = candidate['key'];
  const timestamp = candidate['timestamp'];
  const origin = candidate['origin'];
  if (typeof actor !== 'string' || actor.trim().length === 0) return null;
  if (typeof seq !== 'number' || !Number.isInteger(seq) || seq < 1) return null;
  if (typeof key !== 'string' || key.trim().length === 0) return null;
  if (timestamp !== undefined && (typeof timestamp !== 'number' || !Number.isFinite(timestamp))) return null;
  if (origin !== undefined && typeof origin !== 'string') return null;
  const op: Op = { actor: actor.trim(), seq, key: key.trim(), value: candidate['value'] };
  if (timestamp !== undefined) op.timestamp = timestamp;
  if (origin !== undefined) op.origin = origin;
  return op;
}
