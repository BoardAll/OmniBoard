import { ApiError } from '../lib/errors.js';
import { newId } from '../lib/ids.js';
import { paginate, type Paginated, type SortSpec } from '../lib/query.js';
import type { DataStore } from '../db/memory.js';
import type { CreatePageInput, Element, Page, UpdatePageInput } from '../db/schema.js';
import type { PrincipalContext } from './access.js';
import type { BoardService } from './boardService.js';
import type { HistoryService } from './historyService.js';

/**
 * Pages 业务逻辑（《OpenAPI规范.md》§5.2）。
 *
 * `/pages/{pageId}/split` 与 `/pages/merge` 的请求体文档未定义，采用
 * RESTful 约定并在本节注释说明（splitY 按 y 轴切分元素；merge 以首个
 * pageId 为目标页）。
 */

export interface ListQuery {
  limit: number;
  offset: number;
  sort: SortSpec;
  filter: Record<string, string>;
}

export interface SplitPageInput {
  splitY: number;
  name?: string;
}

export interface MergePagesInput {
  pageIds: string[];
  name?: string;
}

export class PageService {
  constructor(
    private readonly store: DataStore,
    private readonly boards: BoardService,
    private readonly history: HistoryService,
  ) {}

  listByBoard(principal: PrincipalContext, boardId: string, query: ListQuery): Paginated<Page> {
    this.boards.assertAccess(principal, boardId);
    let items = [...this.store.pages.values()].filter((p) => p.boardId === boardId);
    if (query.filter['locked'] !== undefined) {
      items = items.filter((p) => String(p.locked) === query.filter['locked']);
    }
    if (query.filter['hidden'] !== undefined) {
      items = items.filter((p) => String(p.hidden) === query.filter['hidden']);
    }
    const sign = query.sort.dir === 'desc' ? -1 : 1;
    items = [...items].sort((a, b) => {
      const va = (a as unknown as Record<string, unknown>)[query.sort.field];
      const vb = (b as unknown as Record<string, unknown>)[query.sort.field];
      if (typeof va === 'number' && typeof vb === 'number') return sign * (va - vb);
      return sign * String(va ?? '').localeCompare(String(vb ?? ''));
    });
    return paginate(items, query.limit, query.offset);
  }

  create(principal: PrincipalContext, boardId: string, input: CreatePageInput): Page {
    this.boards.assertAccess(principal, boardId, { needWrite: true });
    const now = new Date().toISOString();
    const page: Page = {
      id: newId('page'),
      boardId,
      name: input.name,
      backgroundId: input.backgroundId ?? null,
      viewport: input.viewport ?? { x: 0, y: 0, zoom: 1 },
      index: this.nextIndex(boardId),
      locked: false,
      hidden: false,
      createdAt: now,
      updatedAt: now,
    };
    this.store.pages.set(page.id, page);
    this.history.record({
      boardId,
      action: 'page.create',
      resourceType: 'page',
      resourceId: page.id,
      params: { name: page.name },
      userId: principal.userId,
    });
    return page;
  }

  get(principal: PrincipalContext, pageId: string): Page {
    return this.requirePage(principal, pageId).page;
  }

  update(principal: PrincipalContext, pageId: string, patch: UpdatePageInput): Page {
    const { page } = this.requirePage(principal, pageId, { needWrite: true });
    if (patch.name !== undefined) page.name = patch.name;
    if (patch.backgroundId !== undefined) page.backgroundId = patch.backgroundId;
    if (patch.viewport !== undefined) page.viewport = patch.viewport;
    if (patch.locked !== undefined) page.locked = patch.locked;
    if (patch.hidden !== undefined) page.hidden = patch.hidden;
    page.updatedAt = new Date().toISOString();
    this.store.pages.set(page.id, page);
    this.history.record({
      boardId: page.boardId,
      action: 'page.update',
      resourceType: 'page',
      resourceId: page.id,
      params: { fields: Object.keys(patch) },
      userId: principal.userId,
    });
    return page;
  }

  remove(principal: PrincipalContext, pageId: string): void {
    const { page } = this.requirePage(principal, pageId, { needWrite: true });
    this.store.pages.delete(page.id);
    for (const element of this.store.elements.values()) {
      if (element.pageId === page.id) this.store.elements.delete(element.id);
    }
    for (const connector of this.store.connectors.values()) {
      if (connector.pageId === page.id) this.store.connectors.delete(connector.id);
    }
    for (const comment of this.store.comments.values()) {
      if (comment.pageId === page.id) this.store.comments.delete(comment.id);
    }
    this.history.record({
      boardId: page.boardId,
      action: 'page.delete',
      resourceType: 'page',
      resourceId: page.id,
      params: { name: page.name },
      userId: principal.userId,
    });
  }

  duplicate(principal: PrincipalContext, pageId: string): Page {
    const { page } = this.requirePage(principal, pageId, { needWrite: true });
    const now = new Date().toISOString();
    const copy: Page = {
      ...page,
      id: newId('page'),
      name: `${page.name} 副本`,
      index: this.nextIndex(page.boardId),
      createdAt: now,
      updatedAt: now,
    };
    this.store.pages.set(copy.id, copy);
    for (const element of [...this.store.elements.values()]) {
      if (element.pageId !== page.id) continue;
      const cloned: Element = { ...element, id: newId('elem'), pageId: copy.id, createdAt: now, updatedAt: now };
      this.store.elements.set(cloned.id, cloned);
    }
    this.history.record({
      boardId: page.boardId,
      action: 'page.duplicate',
      resourceType: 'page',
      resourceId: copy.id,
      params: { sourcePageId: page.id },
      userId: principal.userId,
    });
    return copy;
  }

  move(principal: PrincipalContext, pageId: string, index: number): Page {
    const { page } = this.requirePage(principal, pageId, { needWrite: true });
    const siblings = [...this.store.pages.values()]
      .filter((p) => p.boardId === page.boardId && p.id !== page.id)
      .sort((a, b) => a.index - b.index);
    const clamped = Math.min(index, siblings.length);
    const ordered = [...siblings.slice(0, clamped), page, ...siblings.slice(clamped)];
    ordered.forEach((p, i) => {
      p.index = i;
      p.updatedAt = new Date().toISOString();
      this.store.pages.set(p.id, p);
    });
    this.history.record({
      boardId: page.boardId,
      action: 'page.move',
      resourceType: 'page',
      resourceId: page.id,
      params: { index: clamped },
      userId: principal.userId,
    });
    return ordered[clamped] ?? page;
  }

  /** 拆分：splitY 以上的元素（position.y >= splitY）迁移到新页面。 */
  split(principal: PrincipalContext, pageId: string, input: SplitPageInput): Page {
    const { page } = this.requirePage(principal, pageId, { needWrite: true });
    const now = new Date().toISOString();
    const target: Page = {
      ...page,
      id: newId('page'),
      name: input.name ?? `${page.name} (拆分)`,
      index: this.nextIndex(page.boardId),
      createdAt: now,
      updatedAt: now,
    };
    this.store.pages.set(target.id, target);
    for (const element of [...this.store.elements.values()]) {
      if (element.pageId !== page.id) continue;
      if (element.position.y >= input.splitY) {
        element.pageId = target.id;
        element.updatedAt = now;
        this.store.elements.set(element.id, element);
      }
    }
    this.history.record({
      boardId: page.boardId,
      action: 'page.split',
      resourceType: 'page',
      resourceId: target.id,
      params: { sourcePageId: page.id, splitY: input.splitY },
      userId: principal.userId,
    });
    return target;
  }

  /** 合并：pageIds[0] 为目标页，其余页面元素迁移后删除。 */
  merge(principal: PrincipalContext, input: MergePagesInput): Page {
    const pages = input.pageIds.map((id) => this.requirePage(principal, id, { needWrite: true }).page);
    const target = pages[0];
    const sources = pages.slice(1);
    if (!target) throw ApiError.invalidArgument('pageIds must contain at least two pages');
    const targetBoard = target.boardId;
    if (pages.some((p) => p.boardId !== targetBoard)) {
      throw ApiError.invalidArgument('All pages must belong to the same board');
    }
    const now = new Date().toISOString();
    if (input.name !== undefined) target.name = input.name;
    target.updatedAt = now;
    this.store.pages.set(target.id, target);
    for (const source of sources) {
      for (const element of [...this.store.elements.values()]) {
        if (element.pageId !== source.id) continue;
        element.pageId = target.id;
        element.updatedAt = now;
        this.store.elements.set(element.id, element);
      }
      for (const connector of [...this.store.connectors.values()]) {
        if (connector.pageId !== source.id) continue;
        connector.pageId = target.id;
        connector.updatedAt = now;
        this.store.connectors.set(connector.id, connector);
      }
      this.store.pages.delete(source.id);
    }
    this.history.record({
      boardId: targetBoard,
      action: 'page.merge',
      resourceType: 'page',
      resourceId: target.id,
      params: { mergedPageIds: input.pageIds },
      userId: principal.userId,
    });
    return target;
  }

  /**
   * 缩略图（Wave 2.8）：返回确定性 SVG data-URL 占位；
   * Wave 4 由渲染器生成真实缩略图并经对象存储下发。
   */
  thumbnail(principal: PrincipalContext, pageId: string): { pageId: string; mimeType: string; uri: string } {
    const { page } = this.requirePage(principal, pageId);
    const elements = [...this.store.elements.values()].filter((e) => e.pageId === page.id).length;
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180"><rect width="100%" height="100%" fill="#ffffff"/><text x="16" y="96" font-size="14" fill="#666">${page.name} (${elements} elements)</text></svg>`;
    return {
      pageId: page.id,
      mimeType: 'image/svg+xml',
      uri: `data:image/svg+xml;base64,${Buffer.from(svg, 'utf8').toString('base64')}`,
    };
  }

  /** 解析 pageId → page，并校验其所属白板访问权限。 */
  requirePage(
    principal: PrincipalContext,
    pageId: string,
    options: { needWrite?: boolean } = {},
  ): { page: Page } {
    const page = this.store.pages.get(pageId);
    if (!page) throw ApiError.notFound('Page not found', { pageId });
    this.boards.assertAccess(principal, page.boardId, options);
    return { page };
  }

  private nextIndex(boardId: string): number {
    const siblings = [...this.store.pages.values()].filter((p) => p.boardId === boardId);
    return siblings.length === 0 ? 0 : Math.max(...siblings.map((p) => p.index)) + 1;
  }
}
