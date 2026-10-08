/**
 * realtime 服务共享小工具（M3 拆分自 rooms.ts；rooms / interactive / checkpoint 共用）。
 *
 * 仅放无状态纯函数：载荷读取（防御式）、水位向量解析、环境变量读取。
 * 不依赖任何业务模块（保持依赖方向：util ← roomStore / interactive / checkpoint / rooms / server）。
 */

import type { BoardStateVector } from './types.js';

/** 读取非空字符串（trim 后为空 / 非字符串 → null）。 */
export function readNonEmptyString(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

/** 解析客户端水位向量（`{actor: seq}`；非法值 → null，触发 INVALID_ARGUMENT）。 */
export function readSeqVector(value: unknown): BoardStateVector | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null;
  const out: BoardStateVector = {};
  for (const [actor, seq] of Object.entries(value as Record<string, unknown>)) {
    if (typeof seq !== 'number' || !Number.isInteger(seq) || seq < 0) return null;
    out[actor] = seq;
  }
  return out;
}

/**
 * 读取正整数环境变量（M3：WB_HOST_TRANSFER_MS / WB_CHECKPOINT_OP_THRESHOLD 等）。
 * 未配置 / 空串 / 非正整数 → null（调用方回落默认值）。
 */
export function readPositiveIntEnv(env: NodeJS.ProcessEnv, key: string): number | null {
  const raw = env[key];
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  if (trimmed.length === 0) return null;
  const value = Number(trimmed);
  if (!Number.isInteger(value) || value < 1) return null;
  return value;
}
