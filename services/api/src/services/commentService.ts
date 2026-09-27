import { ApiError } from '../lib/errors.js';
import { newId } from '../lib/ids.js';
import { paginate, type Paginated, type SortSpec } from '../lib/query.js';
import type { DataStore } from '../db/memory.js';
import type { Comment, CreateCommentInput } from '../db/schema.js';
import type { PrincipalContext } from './access.js';
import type { BoardService } from './boardService.js';
import type { HistoryService } from './historyService.js';
import type { PageService } from './pageService.js';

/**
 * Comments 业务逻辑（《OpenAPI规范.md》§5.5）。
 * 仅作者可编辑内容；删除允许作者或白板所有者（RESTful 惯例，文档未细化）。
 */

export interface ListQuery {
  limit: number;
  offset: number;
  sort: SortSpec;
  filter: Record<string, string>;
}

export class CommentService {
  constructor(
    private readonly store: DataStore,
    private readonly boards: BoardService,
    private readonly pages: PageService,
    private readonly history: HistoryService,
  ) {}

  listByBoard(principal: PrincipalContext, boardId: string, query: ListQuery): Paginated<Comment> {
    this.boards.assertAccess(principal, boardId);
    let items = [...this.store.comments.values()].filter((c) => c.boardId === boardId);
    if (query.filter['pageId'] !== undefined) items = items.filter((c) => c.pageId === query.filter['pageId']);
    if (query.filter['authorId'] !== undefined) items = items.filter((c) => c.authorId === query.filter['authorId']);
    if (query.filter['resolved'] !== undefined) {
      items = items.filter((c) => String(c.resolved) === query.filter['resolved']);
    }
    const sign = query.sort.dir === 'desc' ? -1 : 1;
    items = [...items].sort((a, b) =>
      sign * String((a as unknown as Record<string, unknown>)[query.sort.field] ?? '')
        .localeCompare(String((b as unknown as Record<string, unknown>)[query.sort.field] ?? '')),
    );
    return paginate(items, query.limit, query.offset);
  }

  create(principal: PrincipalContext, input: CreateCommentInput): Comment {
    this.boards.assertAccess(principal, input.boardId, { needWrite: true });
    if (input.pageId !== undefined) {
      const { page } = this.pages.requirePage(principal, input.pageId, { needWrite: true });
      if (page.boardId !== input.boardId) {
        throw ApiError.invalidArgument('pageId does not belong to boardId', { pageId: input.pageId });
      }
    }
    if (input.parentId !== undefined) {
      const parent = this.store.comments.get(input.parentId);
      if (!parent || parent.boardId !== input.boardId) {
        throw ApiError.notFound('Parent comment not found', { parentId: input.parentId });
      }
    }
    const now = new Date().toISOString();
    const comment: Comment = {
      id: newId('cmt'),
      boardId: input.boardId,
      pageId: input.pageId ?? null,
      elementId: input.elementId ?? null,
      authorId: principal.userId,
      content: input.content,
      parentId: input.parentId ?? null,
      resolved: false,
      createdAt: now,
      updatedAt: now,
    };
    this.store.comments.set(comment.id, comment);
    this.history.record({
      boardId: input.boardId,
      action: 'comment.create',
      resourceType: 'comment',
      resourceId: comment.id,
      params: { pageId: comment.pageId, elementId: comment.elementId },
      userId: principal.userId,
    });
    return comment;
  }

  get(principal: PrincipalContext, commentId: string): Comment {
    return this.requireComment(principal, commentId).comment;
  }

  update(principal: PrincipalContext, commentId: string, content: string): Comment {
    const { comment } = this.requireComment(principal, commentId, { needWrite: true });
    if (comment.authorId !== principal.userId) {
      throw ApiError.permissionDenied('Only the author can edit a comment');
    }
    comment.content = content;
    comment.updatedAt = new Date().toISOString();
    this.store.comments.set(comment.id, comment);
    return comment;
  }

  remove(principal: PrincipalContext, commentId: string): void {
    const { comment } = this.requireComment(principal, commentId, { needWrite: true });
    const board = this.boards.assertAccess(principal, comment.boardId, { needWrite: true });
    if (comment.authorId !== principal.userId && board.ownerId !== principal.userId) {
      throw ApiError.permissionDenied('Only the author or the board owner can delete a comment');
    }
    this.store.comments.delete(comment.id);
    for (const reply of [...this.store.comments.values()]) {
      if (reply.parentId === comment.id) this.store.comments.delete(reply.id);
    }
  }

  reply(principal: PrincipalContext, commentId: string, content: string): Comment {
    const { comment } = this.requireComment(principal, commentId, { needWrite: true });
    return this.create(principal, {
      boardId: comment.boardId,
      ...(comment.pageId !== null ? { pageId: comment.pageId } : {}),
      ...(comment.elementId !== null ? { elementId: comment.elementId } : {}),
      content,
      parentId: comment.id,
    });
  }

  resolve(principal: PrincipalContext, commentId: string, resolved: boolean): Comment {
    const { comment } = this.requireComment(principal, commentId, { needWrite: true });
    comment.resolved = resolved;
    comment.updatedAt = new Date().toISOString();
    this.store.comments.set(comment.id, comment);
    this.history.record({
      boardId: comment.boardId,
      action: 'comment.resolve',
      resourceType: 'comment',
      resourceId: comment.id,
      params: { resolved },
      userId: principal.userId,
    });
    return comment;
  }

  private requireComment(
    principal: PrincipalContext,
    commentId: string,
    options: { needWrite?: boolean } = {},
  ): { comment: Comment } {
    const comment = this.store.comments.get(commentId);
    if (!comment) throw ApiError.notFound('Comment not found', { commentId });
    this.boards.assertAccess(principal, comment.boardId, options);
    return { comment };
  }
}
