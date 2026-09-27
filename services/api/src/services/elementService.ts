import { ApiError } from '../lib/errors.js';
import { newId } from '../lib/ids.js';
import { matchesFilter, paginate, type Paginated, type SortSpec } from '../lib/query.js';
import type { DataStore } from '../db/memory.js';
import type {
  CreateElementInput,
  CreateElementsInput,
  Element,
  ElementBatchInput,
  UpdateElementInput,
} from '../db/schema.js';
import type { PrincipalContext } from './access.js';
import type { HistoryService } from './historyService.js';
import type { PageService } from './pageService.js';

/**
 * Elements 业务逻辑（《OpenAPI规范.md》§5.3 + `core/tools/schema/element.schema.json`）。
 *
 * 过滤字段：`type`、`color`（style.color）、`pageId`、`createdBy`（§4.7）。
 * 排序字段：`createdAt`、`updatedAt`、`name`、`zIndex`（§4.6 的 index 对应 zIndex）。
 */

export interface ListQuery {
  limit: number;
  offset: number;
  sort: SortSpec;
  filter: Record<string, string>;
}

export interface MoveInput {
  position?: { x: number; y: number };
  dx?: number;
  dy?: number;
}

export interface ResizeInput {
  size?: { width: number; height: number };
  width?: number;
  height?: number;
}

export interface AlignInput {
  elementIds: string[];
  alignment: 'left' | 'right' | 'top' | 'bottom' | 'centerX' | 'centerY';
  relativeTo?: string;
}

export interface DistributeInput {
  elementIds: string[];
  axis: 'horizontal' | 'vertical';
}

export interface BatchResultItem {
  op: string;
  ok: boolean;
  id: string | null;
  error: { code: string; message: string } | null;
}

export class ElementService {
  constructor(
    private readonly store: DataStore,
    private readonly pages: PageService,
    private readonly history: HistoryService,
  ) {}

  listByPage(principal: PrincipalContext, pageId: string, query: ListQuery): Paginated<Element> {
    const { page } = this.pages.requirePage(principal, pageId);
    let items = [...this.store.elements.values()].filter((e) => e.pageId === page.id);
    if (Object.keys(query.filter).length > 0) {
      items = items.filter((e) => matchesFilter(e as unknown as Record<string, unknown>, query.filter));
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

  /** 创建（支持 dryRun：仅返回提案，不落库）。 */
  createMany(
    principal: PrincipalContext,
    pageId: string,
    input: CreateElementsInput,
  ): { elements: Element[]; dryRun: boolean } {
    const { page } = this.pages.requirePage(principal, pageId, { needWrite: true });
    const now = new Date().toISOString();
    const created = input.elements.map((elementInput, i) => this.buildElement(principal, page, elementInput, now, i));
    if (input.dryRun) {
      return { elements: created, dryRun: true };
    }
    for (const element of created) this.store.elements.set(element.id, element);
    this.history.record({
      boardId: page.boardId,
      action: 'element.create',
      resourceType: 'element',
      resourceId: created[0]?.id ?? null,
      params: { count: created.length, pageId: page.id },
      userId: principal.userId,
    });
    return { elements: created, dryRun: false };
  }

  get(principal: PrincipalContext, elementId: string): Element {
    return this.requireElement(principal, elementId).element;
  }

  update(principal: PrincipalContext, elementId: string, patch: UpdateElementInput): Element {
    const { element, page } = this.requireElement(principal, elementId, { needWrite: true });
    const updated = this.applyPatch(element, patch);
    this.store.elements.set(updated.id, updated);
    this.history.record({
      boardId: page.boardId,
      action: 'element.update',
      resourceType: 'element',
      resourceId: elementId,
      params: { fields: Object.keys(patch) },
      userId: principal.userId,
    });
    return updated;
  }

  remove(principal: PrincipalContext, elementId: string): void {
    const { element, page } = this.requireElement(principal, elementId, { needWrite: true });
    this.store.elements.delete(element.id);
    for (const connector of this.store.connectors.values()) {
      if (connector.fromElementId === element.id || connector.toElementId === element.id) {
        this.store.connectors.delete(connector.id);
      }
    }
    this.history.record({
      boardId: page.boardId,
      action: 'element.delete',
      resourceType: 'element',
      resourceId: elementId,
      params: { type: element.type },
      userId: principal.userId,
    });
  }

  /**
   * 批量操作（《OpenAPI规范.md》§5.3 `/elements/batch`）。
   * 含删除操作时为破坏性操作（《安全与合规设计》§9.6），需 `confirm=true`。
   */
  batch(principal: PrincipalContext, input: ElementBatchInput): { results: BatchResultItem[]; dryRun: boolean } {
    const hasDelete = input.operations.some((op) => op.op === 'delete');
    if (hasDelete && input.confirm !== true) {
      throw ApiError.confirmationRequired('Batch delete requires confirmation', { operationCount: input.operations.length });
    }
    const results: BatchResultItem[] = [];
    for (const op of input.operations) {
      try {
        switch (op.op) {
          case 'create': {
            const { elements } = this.createMany(principal, op.pageId, { elements: [op.element], dryRun: input.dryRun });
            results.push({ op: 'create', ok: true, id: elements[0]?.id ?? null, error: null });
            break;
          }
          case 'update': {
            const updated = input.dryRun
              ? this.applyPatch(this.requireElement(principal, op.elementId, { needWrite: true }).element, op.patch)
              : this.update(principal, op.elementId, op.patch);
            results.push({ op: 'update', ok: true, id: updated.id, error: null });
            break;
          }
          case 'delete': {
            if (!input.dryRun) this.remove(principal, op.elementId);
            results.push({ op: 'delete', ok: true, id: op.elementId, error: null });
            break;
          }
          case 'move': {
            const moved = input.dryRun
              ? this.applyMove(this.requireElement(principal, op.elementId, { needWrite: true }).element, { position: op.position })
              : this.move(principal, op.elementId, { position: op.position });
            results.push({ op: 'move', ok: true, id: moved.id, error: null });
            break;
          }
        }
      } catch (error) {
        results.push({
          op: op.op,
          ok: false,
          id: null,
          error: {
            code: error instanceof ApiError ? error.code : 'INTERNAL_ERROR',
            message: error instanceof Error ? error.message : 'Operation failed',
          },
        });
      }
    }
    return { results, dryRun: input.dryRun };
  }

  setStyle(
    principal: PrincipalContext,
    elementId: string,
    style: Record<string, unknown>,
    merge: boolean,
  ): Element {
    const { element, page } = this.requireElement(principal, elementId, { needWrite: true });
    element.style = merge ? { ...element.style, ...style } : { ...style };
    element.updatedAt = new Date().toISOString();
    this.store.elements.set(element.id, element);
    this.history.record({
      boardId: page.boardId,
      action: 'element.setStyle',
      resourceType: 'element',
      resourceId: elementId,
      params: { keys: Object.keys(style), merge },
      userId: principal.userId,
    });
    return element;
  }

  move(principal: PrincipalContext, elementId: string, input: MoveInput): Element {
    const { element, page } = this.requireElement(principal, elementId, { needWrite: true });
    const updated = this.applyMove(element, input);
    this.store.elements.set(updated.id, updated);
    this.history.record({
      boardId: page.boardId,
      action: 'element.move',
      resourceType: 'element',
      resourceId: elementId,
      params: { position: updated.position },
      userId: principal.userId,
    });
    return updated;
  }

  resize(principal: PrincipalContext, elementId: string, input: ResizeInput): Element {
    const { element, page } = this.requireElement(principal, elementId, { needWrite: true });
    const width = input.size?.width ?? input.width ?? element.size.width;
    const height = input.size?.height ?? input.height ?? element.size.height;
    element.size = { width, height };
    element.updatedAt = new Date().toISOString();
    this.store.elements.set(element.id, element);
    this.history.record({
      boardId: page.boardId,
      action: 'element.resize',
      resourceType: 'element',
      resourceId: elementId,
      params: { width, height },
      userId: principal.userId,
    });
    return element;
  }

  align(principal: PrincipalContext, input: AlignInput): { elements: Element[] } {
    const resolved = input.elementIds.map((id) => this.requireElement(principal, id, { needWrite: true }));
    const page = resolved[0]?.page;
    if (!page) throw ApiError.invalidArgument('elementIds must not be empty');
    if (resolved.some((r) => r.page.id !== page.id)) {
      throw ApiError.invalidArgument('All elements must belong to the same page');
    }
    const items = resolved.map((r) => r.element);
    const minX = Math.min(...items.map((e) => e.position.x));
    const maxRight = Math.max(...items.map((e) => e.position.x + e.size.width));
    const minY = Math.min(...items.map((e) => e.position.y));
    const maxBottom = Math.max(...items.map((e) => e.position.y + e.size.height));
    const now = new Date().toISOString();
    for (const element of items) {
      switch (input.alignment) {
        case 'left':
          element.position.x = minX;
          break;
        case 'right':
          element.position.x = maxRight - element.size.width;
          break;
        case 'top':
          element.position.y = minY;
          break;
        case 'bottom':
          element.position.y = maxBottom - element.size.height;
          break;
        case 'centerX':
          element.position.x = (minX + maxRight) / 2 - element.size.width / 2;
          break;
        case 'centerY':
          element.position.y = (minY + maxBottom) / 2 - element.size.height / 2;
          break;
      }
      element.updatedAt = now;
      this.store.elements.set(element.id, element);
    }
    this.history.record({
      boardId: page.boardId,
      action: 'element.align',
      resourceType: 'element',
      resourceId: null,
      params: { alignment: input.alignment, count: items.length },
      userId: principal.userId,
    });
    return { elements: items };
  }

  distribute(principal: PrincipalContext, input: DistributeInput): { elements: Element[] } {
    const resolved = input.elementIds.map((id) => this.requireElement(principal, id, { needWrite: true }));
    const page = resolved[0]?.page;
    if (!page) throw ApiError.invalidArgument('elementIds must not be empty');
    if (resolved.some((r) => r.page.id !== page.id)) {
      throw ApiError.invalidArgument('All elements must belong to the same page');
    }
    const horizontal = input.axis === 'horizontal';
    const items = resolved
      .map((r) => r.element)
      .sort((a, b) => (horizontal ? a.position.x - b.position.x : a.position.y - b.position.y));
    const first = items[0];
    const last = items[items.length - 1];
    if (first && last && items.length > 2) {
      const start = horizontal ? first.position.x : first.position.y;
      const end = horizontal ? last.position.x : last.position.y;
      const step = (end - start) / (items.length - 1);
      const now = new Date().toISOString();
      items.forEach((element, i) => {
        if (horizontal) element.position.x = start + step * i;
        else element.position.y = start + step * i;
        element.updatedAt = now;
        this.store.elements.set(element.id, element);
      });
    }
    this.history.record({
      boardId: page.boardId,
      action: 'element.distribute',
      resourceType: 'element',
      resourceId: null,
      params: { axis: input.axis, count: items.length },
      userId: principal.userId,
    });
    return { elements: items };
  }

  group(principal: PrincipalContext, elementIds: string[]): { group: Element; memberIds: string[] } {
    const resolved = elementIds.map((id) => this.requireElement(principal, id, { needWrite: true }));
    const page = resolved[0]?.page;
    if (!page) throw ApiError.invalidArgument('elementIds must not be empty');
    if (resolved.some((r) => r.page.id !== page.id)) {
      throw ApiError.invalidArgument('All elements must belong to the same page');
    }
    const members = resolved.map((r) => r.element);
    const minX = Math.min(...members.map((e) => e.position.x));
    const minY = Math.min(...members.map((e) => e.position.y));
    const maxX = Math.max(...members.map((e) => e.position.x + e.size.width));
    const maxY = Math.max(...members.map((e) => e.position.y + e.size.height));
    const now = new Date().toISOString();
    const group = this.buildElement(
      principal,
      page,
      {
        type: 'group',
        position: { x: minX, y: minY },
        size: { width: Math.max(0, maxX - minX), height: Math.max(0, maxY - minY) },
        data: { memberIds: members.map((e) => e.id) },
        zIndex: Math.max(...members.map((e) => e.zIndex)) + 1,
      },
      now,
      0,
    );
    this.store.elements.set(group.id, group);
    for (const member of members) {
      member.groupId = group.id;
      member.updatedAt = now;
      this.store.elements.set(member.id, member);
    }
    this.history.record({
      boardId: page.boardId,
      action: 'element.group',
      resourceType: 'element',
      resourceId: group.id,
      params: { memberIds: members.map((e) => e.id) },
      userId: principal.userId,
    });
    return { group, memberIds: members.map((e) => e.id) };
  }

  ungroup(principal: PrincipalContext, groupId: string): { groupId: string; releasedIds: string[] } {
    const { element, page } = this.requireElement(principal, groupId, { needWrite: true });
    if (element.type !== 'group') {
      throw ApiError.invalidArgument('Element is not a group', { elementId: groupId, type: element.type });
    }
    const now = new Date().toISOString();
    const released: string[] = [];
    for (const child of this.store.elements.values()) {
      if (child.groupId === element.id) {
        child.groupId = null;
        child.updatedAt = now;
        this.store.elements.set(child.id, child);
        released.push(child.id);
      }
    }
    this.store.elements.delete(element.id);
    this.history.record({
      boardId: page.boardId,
      action: 'element.ungroup',
      resourceType: 'element',
      resourceId: groupId,
      params: { releasedIds: released },
      userId: principal.userId,
    });
    return { groupId, releasedIds: released };
  }

  requireElement(
    principal: PrincipalContext,
    elementId: string,
    options: { needWrite?: boolean } = {},
  ): { element: Element; page: { id: string; boardId: string } } {
    const element = this.store.elements.get(elementId);
    if (!element) throw ApiError.notFound('Element not found', { elementId });
    const { page } = this.pages.requirePage(principal, element.pageId, options);
    return { element, page };
  }

  private buildElement(
    principal: PrincipalContext,
    page: { id: string; boardId: string },
    input: CreateElementInput,
    now: string,
    order: number,
  ): Element {
    const data: Record<string, unknown> = { ...(input.data ?? {}) };
    if (input.text !== undefined) data['text'] = input.text;
    return {
      id: newId('elem'),
      pageId: page.id,
      boardId: page.boardId,
      type: input.type,
      name: input.name ?? null,
      position: input.position ?? { x: 0, y: 0 },
      size: input.size ?? { width: 100, height: 100 },
      rotation: input.rotation ?? 0,
      opacity: input.opacity ?? 1,
      zIndex: input.zIndex ?? order,
      locked: input.locked ?? false,
      hidden: input.hidden ?? false,
      groupId: input.groupId ?? null,
      style: input.style ?? {},
      data,
      createdAt: now,
      updatedAt: now,
      createdBy: principal.userId,
      updatedBy: principal.userId,
    };
  }

  private applyPatch(element: Element, patch: UpdateElementInput): Element {
    const updated: Element = { ...element, updatedAt: new Date().toISOString() };
    if (patch.name !== undefined) updated.name = patch.name;
    if (patch.text !== undefined) updated.data = { ...updated.data, text: patch.text };
    if (patch.position !== undefined) updated.position = patch.position;
    if (patch.size !== undefined) updated.size = patch.size;
    if (patch.rotation !== undefined) updated.rotation = patch.rotation;
    if (patch.opacity !== undefined) updated.opacity = patch.opacity;
    if (patch.zIndex !== undefined) updated.zIndex = patch.zIndex;
    if (patch.locked !== undefined) updated.locked = patch.locked;
    if (patch.hidden !== undefined) updated.hidden = patch.hidden;
    if (patch.style !== undefined) updated.style = { ...updated.style, ...patch.style };
    if (patch.data !== undefined) updated.data = { ...updated.data, ...patch.data };
    return updated;
  }

  private applyMove(element: Element, input: MoveInput): Element {
    if (input.position === undefined && input.dx === undefined && input.dy === undefined) {
      throw ApiError.invalidArgument('move requires position or dx/dy');
    }
    const updated: Element = { ...element, updatedAt: new Date().toISOString() };
    if (input.position) {
      updated.position = input.position;
    } else {
      updated.position = {
        x: element.position.x + (input.dx ?? 0),
        y: element.position.y + (input.dy ?? 0),
      };
    }
    return updated;
  }
}
