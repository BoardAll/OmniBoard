import { ApiError } from './errors.js';

/**
 * Query helpers: pagination (§4.5), sort (§4.6) and filter (§4.7) of
 * 《OpenAPI规范.md》. Cursors are opaque to clients (base64url of the offset).
 */

export const DEFAULT_LIMIT = 20;
export const MAX_LIMIT = 100;

export interface Paginated<T> {
  items: T[];
  total: number;
  hasMore: boolean;
  nextCursor: string | null;
}

export type SortDir = 'asc' | 'desc';
export interface SortSpec {
  field: string;
  dir: SortDir;
}

export function parseLimit(raw: unknown, def: number = DEFAULT_LIMIT, max: number = MAX_LIMIT): number {
  if (raw === undefined || raw === null || raw === '') return def;
  const n = typeof raw === 'number' ? raw : Number(String(raw));
  if (!Number.isInteger(n) || n < 1 || n > max) {
    throw ApiError.invalidArgument(`limit must be an integer between 1 and ${max}`, { limit: raw });
  }
  return n;
}

export function encodeCursor(offset: number): string {
  return Buffer.from(`o:${offset}`, 'utf8').toString('base64url');
}

export function parseCursor(raw: unknown): number {
  if (raw === undefined || raw === null || raw === '') return 0;
  if (typeof raw !== 'string') {
    throw ApiError.invalidArgument('cursor must be a string', { cursor: raw });
  }
  try {
    const decoded = Buffer.from(raw, 'base64url').toString('utf8');
    const match = /^o:(\d+)$/.exec(decoded);
    if (!match || match[1] === undefined) throw new Error('bad cursor');
    return Number(match[1]);
  } catch {
    throw ApiError.invalidArgument('Invalid cursor', { cursor: raw });
  }
}

export function paginate<T>(items: T[], limit: number, offset: number): Paginated<T> {
  const slice = items.slice(offset, offset + limit);
  const hasMore = offset + slice.length < items.length;
  return {
    items: slice,
    total: items.length,
    hasMore,
    nextCursor: hasMore ? encodeCursor(offset + slice.length) : null,
  };
}

/**
 * `sort=createdAt:desc` — supported fields must be whitelisted per resource.
 */
export function parseSort(raw: unknown, allowed: readonly string[], fallback: SortSpec): SortSpec {
  if (raw === undefined || raw === null || raw === '') return fallback;
  if (typeof raw !== 'string') throw ApiError.invalidArgument('sort must be a string', { sort: raw });
  const [fieldRaw, dirRaw] = raw.split(':', 2);
  const field = fieldRaw ?? '';
  const dir = (dirRaw ?? 'asc').toLowerCase();
  if (!allowed.includes(field)) {
    throw ApiError.invalidArgument(`Unsupported sort field: ${field}`, { allowed });
  }
  if (dir !== 'asc' && dir !== 'desc') {
    throw ApiError.invalidArgument(`Unsupported sort direction: ${dirRaw}`, { allowed: ['asc', 'desc'] });
  }
  return { field, dir };
}

/** Compare helper used by the in-memory repository (replaceable in Wave 4). */
export function compareValues(a: unknown, b: unknown): number {
  if (typeof a === 'number' && typeof b === 'number') return a - b;
  if (typeof a === 'boolean' && typeof b === 'boolean') return Number(a) - Number(b);
  const sa = a === undefined || a === null ? '' : String(a);
  const sb = b === undefined || b === null ? '' : String(b);
  return sa < sb ? -1 : sa > sb ? 1 : 0;
}

export function applySort<T>(items: T[], spec: SortSpec): T[] {
  const sign = spec.dir === 'desc' ? -1 : 1;
  return [...items].sort((a, b) => {
    const va = (a as Record<string, unknown>)[spec.field];
    const vb = (b as Record<string, unknown>)[spec.field];
    return sign * compareValues(va, vb);
  });
}

/**
 * `filter=type:sticky,color:#FFE58F` — whitelisted keys per resource.
 */
export function parseFilter(raw: unknown, allowed: readonly string[]): Record<string, string> {
  const out: Record<string, string> = {};
  if (raw === undefined || raw === null || raw === '') return out;
  if (typeof raw !== 'string') throw ApiError.invalidArgument('filter must be a string', { filter: raw });
  for (const part of raw.split(',')) {
    const trimmed = part.trim();
    if (trimmed === '') continue;
    const idx = trimmed.indexOf(':');
    if (idx <= 0) {
      throw ApiError.invalidArgument(`Malformed filter term: ${trimmed}`, { expected: 'field:value' });
    }
    const key = trimmed.slice(0, idx).trim();
    const value = trimmed.slice(idx + 1).trim();
    if (!allowed.includes(key)) {
      throw ApiError.invalidArgument(`Unsupported filter field: ${key}`, { allowed });
    }
    out[key] = value;
  }
  return out;
}

/**
 * 模块内部按过滤条件筛选（内存实现）。
 * 过滤值按字符串比较；`color` 检查 element.style.color。
 */
export function matchesFilter(item: Record<string, unknown>, filter: Record<string, string>): boolean {
  for (const [key, expected] of Object.entries(filter)) {
    let actual: unknown = item[key];
    if (key === 'color') {
      const style = item['style'];
      actual = typeof style === 'object' && style !== null ? (style as Record<string, unknown>)['color'] : undefined;
    }
    if (String(actual ?? '') !== expected) return false;
  }
  return true;
}
