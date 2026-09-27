import { ApiError } from '../lib/errors.js';
import { newId } from '../lib/ids.js';
import { paginate, type Paginated, type SortSpec } from '../lib/query.js';
import { boardUserKey, type DataStore } from '../db/memory.js';
import {
  WRITE_ROLES,
  type Board,
  type Collaborator,
  type CreateBoardInput,
  type ShareBoardInput,
  type CollaboratorInput,
  type ShareLink,
  type UpdateBoardInput,
} from '../db/schema.js';
import { assertBoardInRange, type PrincipalContext } from './access.js';
import type { HistoryService } from './historyService.js';

/**
 * Boards 业务逻辑（《OpenAPI规范.md》§5.1）。
 * 白板级 ACL（§3.4）：owner 全权；协作者按角色（viewer/guest 只读）。
 */

export interface ListQuery {
  limit: number;
  offset: number;
  sort: SortSpec;
  filter: Record<string, string>;
}

export interface AccessOptions {
  /** 是否要求写权限（viewer/guest 拒绝）。默认 false（读）。 */
  needWrite?: boolean;
}

export class BoardService {
  constructor(
    private readonly store: DataStore,
    private readonly history: HistoryService,
  ) {}

  list(principal: PrincipalContext, query: ListQuery): Paginated<Board> {
    let items = [...this.store.boards.values()]
      .filter((b) => b.deletedAt === null)
      .filter((b) => this.canRead(principal, b));

    const name = query.filter['name'];
    if (name !== undefined) {
      const needle = name.toLowerCase();
      items = items.filter((b) => b.name.toLowerCase().includes(needle));
    }
    const createdBy = query.filter['createdBy'];
    if (createdBy !== undefined) items = items.filter((b) => b.ownerId === createdBy);

    const sign = query.sort.dir === 'desc' ? -1 : 1;
    items = [...items].sort((a, b) => {
      const va = (a as unknown as Record<string, unknown>)[query.sort.field];
      const vb = (b as unknown as Record<string, unknown>)[query.sort.field];
      if (typeof va === 'number' && typeof vb === 'number') return sign * (va - vb);
      return sign * String(va ?? '').localeCompare(String(vb ?? ''));
    });
    return paginate(items, query.limit, query.offset);
  }

  create(principal: PrincipalContext, input: CreateBoardInput): Board {
    const now = new Date().toISOString();
    const board: Board = {
      id: newId('board'),
      name: input.name,
      description: input.description ?? null,
      ownerId: principal.userId,
      themeId: input.themeId ?? 'clean-professional',
      backgroundId: input.backgroundId ?? 'whiteboard',
      shareLinkEnabled: false,
      createdAt: now,
      updatedAt: now,
      deletedAt: null,
    };
    this.store.boards.set(board.id, board);
    this.history.record({
      boardId: board.id,
      action: 'board.create',
      resourceType: 'board',
      resourceId: board.id,
      params: { name: board.name },
      userId: principal.userId,
    });
    return board;
  }

  get(principal: PrincipalContext, boardId: string): Board {
    return this.assertAccess(principal, boardId);
  }

  update(principal: PrincipalContext, boardId: string, patch: UpdateBoardInput): Board {
    const board = this.assertAccess(principal, boardId, { needWrite: true });
    if (patch.name !== undefined) board.name = patch.name;
    if (patch.description !== undefined) board.description = patch.description;
    if (patch.themeId !== undefined) board.themeId = patch.themeId;
    if (patch.backgroundId !== undefined) board.backgroundId = patch.backgroundId;
    board.updatedAt = new Date().toISOString();
    this.store.boards.set(board.id, board);
    this.history.record({
      boardId,
      action: 'board.update',
      resourceType: 'board',
      resourceId: boardId,
      params: { fields: Object.keys(patch) },
      userId: principal.userId,
    });
    return board;
  }

  /** 删除（破坏性，需显式确认 —— 见 route 层 confirm 语义）。级联清理子资源。 */
  remove(principal: PrincipalContext, boardId: string): void {
    const board = this.assertAccess(principal, boardId, { needWrite: true });
    this.store.boards.delete(board.id);
    for (const page of this.store.pages.values()) {
      if (page.boardId === boardId) this.store.pages.delete(page.id);
    }
    for (const element of this.store.elements.values()) {
      if (element.boardId === boardId) this.store.elements.delete(element.id);
    }
    for (const connector of this.store.connectors.values()) {
      if (connector.boardId === boardId) this.store.connectors.delete(connector.id);
    }
    for (const comment of this.store.comments.values()) {
      if (comment.boardId === boardId) this.store.comments.delete(comment.id);
    }
    for (const [key, collaborator] of this.store.collaborators) {
      if (collaborator.boardId === boardId) this.store.collaborators.delete(key);
    }
    for (const [key, link] of this.store.shareLinks) {
      if (link.boardId === boardId) this.store.shareLinks.delete(key);
    }
    for (const job of this.store.exportJobs.values()) {
      if (job.boardId === boardId) this.store.exportJobs.delete(job.id);
    }
    this.history.purgeBoard(boardId);
  }

  share(
    principal: PrincipalContext,
    boardId: string,
    input: ShareBoardInput,
  ): { board: Board; shareLink: ShareLink } {
    const board = this.assertAccess(principal, boardId, { needWrite: true });
    const link: ShareLink = {
      boardId,
      token: newId('wbs'),
      role: input.role,
      passwordProtected: input.password !== undefined,
      enabled: input.enabled,
      expiresAt: input.expiresAt ?? null,
      createdAt: new Date().toISOString(),
    };
    board.shareLinkEnabled = input.enabled;
    board.updatedAt = link.createdAt;
    this.store.boards.set(board.id, board);
    this.store.shareLinks.set(`${boardId}:${link.token}`, link);
    this.history.record({
      boardId,
      action: 'board.share',
      resourceType: 'board',
      resourceId: boardId,
      params: { role: link.role, enabled: link.enabled, passwordProtected: link.passwordProtected },
      userId: principal.userId,
    });
    return { board, shareLink: link };
  }

  listCollaborators(principal: PrincipalContext, boardId: string): Collaborator[] {
    this.assertAccess(principal, boardId);
    return [...this.store.collaborators.values()]
      .filter((c) => c.boardId === boardId)
      .sort((a, b) => a.addedAt.localeCompare(b.addedAt));
  }

  addCollaborator(principal: PrincipalContext, boardId: string, input: CollaboratorInput): Collaborator {
    this.assertAccess(principal, boardId, { needWrite: true });
    if (input.role === 'owner') {
      throw ApiError.invalidArgument('Cannot add another owner; use role admin/editor/commenter/viewer/guest');
    }
    const collaborator: Collaborator = {
      boardId,
      userId: input.userId,
      role: input.role,
      addedBy: principal.userId,
      addedAt: new Date().toISOString(),
    };
    this.store.collaborators.set(boardUserKey(boardId, input.userId), collaborator);
    this.history.record({
      boardId,
      action: 'board.addCollaborator',
      resourceType: 'collaborator',
      resourceId: input.userId,
      params: { role: input.role },
      userId: principal.userId,
    });
    return collaborator;
  }

  removeCollaborator(principal: PrincipalContext, boardId: string, targetUserId: string): void {
    const board = this.assertAccess(principal, boardId, { needWrite: true });
    if (targetUserId === board.ownerId) {
      throw ApiError.permissionDenied('Cannot remove the board owner');
    }
    const key = boardUserKey(boardId, targetUserId);
    if (!this.store.collaborators.has(key)) {
      throw ApiError.notFound('Collaborator not found', { userId: targetUserId });
    }
    this.store.collaborators.delete(key);
    this.history.record({
      boardId,
      action: 'board.removeCollaborator',
      resourceType: 'collaborator',
      resourceId: targetUserId,
      params: {},
      userId: principal.userId,
    });
  }

  /** 读取权限校验（白板不存在 → 404；无权限 → 403）。 */
  assertAccess(principal: PrincipalContext, boardId: string, options: AccessOptions = {}): Board {
    const board = this.store.boards.get(boardId);
    if (!board || board.deletedAt !== null) {
      throw ApiError.notFound('Board not found', { boardId });
    }
    assertBoardInRange(principal, boardId);
    if (board.ownerId === principal.userId) return board;
    const collaborator = this.store.collaborators.get(boardUserKey(boardId, principal.userId));
    if (!collaborator) {
      throw ApiError.permissionDenied('No access to this board', { boardId });
    }
    if (options.needWrite && !WRITE_ROLES.includes(collaborator.role)) {
      throw ApiError.permissionDenied(`Role ${collaborator.role} is read-only`, { role: collaborator.role });
    }
    return board;
  }

  /** 判断主体对该白板是否有读权限（用于列表过滤，不抛错）。 */
  canRead(principal: PrincipalContext, board: Board): boolean {
    if (principal.boards && !principal.boards.includes(board.id)) return false;
    if (board.ownerId === principal.userId) return true;
    return this.store.collaborators.has(boardUserKey(board.id, principal.userId));
  }
}
