import { ApiError } from '../lib/errors.js';
import { newId } from '../lib/ids.js';
import { paginate, type Paginated, type SortSpec } from '../lib/query.js';
import type { DataStore } from '../db/memory.js';
import type { HistoryEntry, Snapshot } from '../db/schema.js';
import type { PrincipalContext } from './access.js';
import { assertBoardInRange } from './access.js';

/**
 * 历史/撤销/重做/快照（《OpenAPI规范.md》§5.7）。
 *
 * Wave 2.8：命令栈以内存条目记录（applied/undone 状态机）；
 * 逆向执行（真实数据回滚）随 C++ 核心命令层在 Wave 4 接入——
 * 届时 undo/redo 调用 `wb_execute_command` 的事务回滚。
 */

export interface ListQuery {
  limit: number;
  offset: number;
  sort: SortSpec;
  filter: Record<string, string>;
}

export interface RecordInput {
  boardId: string;
  action: string;
  resourceType: string;
  resourceId?: string | null;
  params?: Record<string, unknown>;
  userId: string;
}

export interface HistoryMutationResult {
  undone?: number;
  redone?: number;
  entries: HistoryEntry[];
}

export class HistoryService {
  constructor(private readonly store: DataStore) {}

  record(input: RecordInput): HistoryEntry {
    const entries = this.forBoard(input.boardId);
    const seq = entries.length === 0 ? 1 : Math.max(...entries.map((e) => e.seq)) + 1;
    const entry: HistoryEntry = {
      id: newId('hist'),
      boardId: input.boardId,
      seq,
      action: input.action,
      resourceType: input.resourceType,
      resourceId: input.resourceId ?? null,
      status: 'applied',
      params: input.params ?? {},
      userId: input.userId,
      createdAt: new Date().toISOString(),
    };
    this.store.history.set(entry.id, entry);
    // 新的变更会截断 redo 分支（与命令栈语义一致）。
    for (const existing of this.forBoard(input.boardId)) {
      if (existing.status === 'undone' && existing.seq > entry.seq) {
        this.store.history.delete(existing.id);
      }
    }
    return entry;
  }

  list(
    principal: PrincipalContext,
    boardId: string,
    query: ListQuery,
  ): Paginated<HistoryEntry> {
    assertBoardInRange(principal, boardId);
    const filter = query.filter;
    let items = this.forBoard(boardId);
    if (filter['action'] !== undefined) items = items.filter((e) => e.action === filter['action']);
    if (filter['status'] !== undefined) items = items.filter((e) => e.status === filter['status']);
    const sign = query.sort.dir === 'desc' ? -1 : 1;
    items = [...items].sort((a, b) => sign * (a.seq - b.seq));
    return paginate(items, query.limit, query.offset);
  }

  undo(principal: PrincipalContext, boardId: string, transactionId?: string): HistoryMutationResult {
    assertBoardInRange(principal, boardId);
    const candidates = this.forBoard(boardId)
      .filter((e) => e.status === 'applied' && (transactionId === undefined || e.id === transactionId))
      .sort((a, b) => b.seq - a.seq);
    const target = candidates[0];
    if (!target) return { undone: 0, entries: [] };
    target.status = 'undone';
    this.store.history.set(target.id, target);
    return { undone: 1, entries: [target] };
  }

  redo(principal: PrincipalContext, boardId: string, transactionId?: string): HistoryMutationResult {
    assertBoardInRange(principal, boardId);
    const candidates = this.forBoard(boardId)
      .filter((e) => e.status === 'undone' && (transactionId === undefined || e.id === transactionId))
      .sort((a, b) => a.seq - b.seq);
    const target = candidates[0];
    if (!target) return { redone: 0, entries: [] };
    target.status = 'applied';
    this.store.history.set(target.id, target);
    return { redone: 1, entries: [target] };
  }

  createSnapshot(principal: PrincipalContext, boardId: string, name?: string): Snapshot {
    assertBoardInRange(principal, boardId);
    const entries = this.forBoard(boardId);
    const seq = entries.length === 0 ? 1 : Math.max(...entries.map((e) => e.seq)) + 1;
    const snapshot: Snapshot = {
      id: newId('snap'),
      boardId,
      name: name ?? `snapshot_${new Date().toISOString()}`,
      seq,
      createdBy: principal.userId,
      createdAt: new Date().toISOString(),
    };
    this.store.snapshots.set(snapshot.id, snapshot);
    return snapshot;
  }

  listSnapshots(boardId: string): Snapshot[] {
    return [...this.store.snapshots.values()]
      .filter((s) => s.boardId === boardId)
      .sort((a, b) => b.seq - a.seq);
  }

  /** 白板删除时级联清理（幂等）。 */
  purgeBoard(boardId: string): void {
    for (const entry of this.forBoard(boardId)) this.store.history.delete(entry.id);
    for (const snapshot of this.store.snapshots.values()) {
      if (snapshot.boardId === boardId) this.store.snapshots.delete(snapshot.id);
    }
  }

  getByBoard(boardId: string): HistoryEntry[] {
    return this.forBoard(boardId);
  }

  private forBoard(boardId: string): HistoryEntry[] {
    return [...this.store.history.values()].filter((e) => e.boardId === boardId);
  }

  /** 供 undo/redo 路由校验：事务条目必须属于该白板。 */
  assertEntryBelongsToBoard(entryId: string, boardId: string): void {
    const entry = this.store.history.get(entryId);
    if (!entry || entry.boardId !== boardId) {
      throw ApiError.notFound('History entry not found', { entryId });
    }
  }
}
