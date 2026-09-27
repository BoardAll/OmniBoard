import { ApiError } from '../lib/errors.js';
import { newId } from '../lib/ids.js';
import { matchesFilter, paginate, type Paginated, type SortSpec } from '../lib/query.js';
import type { DataStore } from '../db/memory.js';
import type { Connector, CreateConnectorInput, UpdateConnectorInput } from '../db/schema.js';
import type { PrincipalContext } from './access.js';
import type { HistoryService } from './historyService.js';
import type { PageService } from './pageService.js';

/**
 * Connectors 业务逻辑（《OpenAPI规范.md》§5.4 + element.schema.json 的
 * `$defs.Connector`）。连线要求两端元素存在且位于同一页面。
 */

export interface ListQuery {
  limit: number;
  offset: number;
  sort: SortSpec;
  filter: Record<string, string>;
}

export class ConnectorService {
  constructor(
    private readonly store: DataStore,
    private readonly pages: PageService,
    private readonly history: HistoryService,
  ) {}

  listByPage(principal: PrincipalContext, pageId: string, query: ListQuery): Paginated<Connector> {
    const { page } = this.pages.requirePage(principal, pageId);
    let items = [...this.store.connectors.values()].filter((c) => c.pageId === page.id);
    if (Object.keys(query.filter).length > 0) {
      items = items.filter((c) => matchesFilter(c as unknown as Record<string, unknown>, query.filter));
    }
    const sign = query.sort.dir === 'desc' ? -1 : 1;
    items = [...items].sort((a, b) =>
      sign * String((a as unknown as Record<string, unknown>)[query.sort.field] ?? '')
        .localeCompare(String((b as unknown as Record<string, unknown>)[query.sort.field] ?? '')),
    );
    return paginate(items, query.limit, query.offset);
  }

  create(principal: PrincipalContext, pageId: string, input: CreateConnectorInput): Connector {
    const { page } = this.pages.requirePage(principal, pageId, { needWrite: true });
    this.assertElements(page.id, input.fromElementId, input.toElementId);
    const now = new Date().toISOString();
    const connector: Connector = {
      id: newId('conn'),
      pageId: page.id,
      boardId: page.boardId,
      fromElementId: input.fromElementId,
      toElementId: input.toElementId,
      fromAnchor: input.fromAnchor ?? 'right',
      toAnchor: input.toAnchor ?? 'left',
      style: input.style ?? 'orthogonal',
      arrowStart: input.arrowStart ?? 'none',
      arrowEnd: input.arrowEnd ?? 'solid',
      label: input.label ?? null,
      waypoints: input.waypoints ?? [],
      autoRoute: input.autoRoute ?? true,
      createdAt: now,
      updatedAt: now,
    };
    this.store.connectors.set(connector.id, connector);
    this.history.record({
      boardId: page.boardId,
      action: 'connector.create',
      resourceType: 'connector',
      resourceId: connector.id,
      params: { from: connector.fromElementId, to: connector.toElementId },
      userId: principal.userId,
    });
    return connector;
  }

  get(principal: PrincipalContext, connectorId: string): Connector {
    return this.requireConnector(principal, connectorId).connector;
  }

  update(principal: PrincipalContext, connectorId: string, patch: UpdateConnectorInput): Connector {
    const { connector } = this.requireConnector(principal, connectorId, { needWrite: true });
    const updated: Connector = { ...connector, updatedAt: new Date().toISOString() };
    if (patch.fromElementId !== undefined) updated.fromElementId = patch.fromElementId;
    if (patch.toElementId !== undefined) updated.toElementId = patch.toElementId;
    if (patch.fromAnchor !== undefined) updated.fromAnchor = patch.fromAnchor;
    if (patch.toAnchor !== undefined) updated.toAnchor = patch.toAnchor;
    if (patch.style !== undefined) updated.style = patch.style;
    if (patch.arrowStart !== undefined) updated.arrowStart = patch.arrowStart;
    if (patch.arrowEnd !== undefined) updated.arrowEnd = patch.arrowEnd;
    if (patch.label !== undefined) updated.label = patch.label;
    if (patch.waypoints !== undefined) updated.waypoints = patch.waypoints;
    if (patch.autoRoute !== undefined) updated.autoRoute = patch.autoRoute;
    this.assertElements(updated.pageId, updated.fromElementId, updated.toElementId);
    this.store.connectors.set(updated.id, updated);
    this.history.record({
      boardId: updated.boardId,
      action: 'connector.update',
      resourceType: 'connector',
      resourceId: updated.id,
      params: { fields: Object.keys(patch) },
      userId: principal.userId,
    });
    return updated;
  }

  remove(principal: PrincipalContext, connectorId: string): void {
    const { connector } = this.requireConnector(principal, connectorId, { needWrite: true });
    this.store.connectors.delete(connector.id);
    this.history.record({
      boardId: connector.boardId,
      action: 'connector.delete',
      resourceType: 'connector',
      resourceId: connector.id,
      params: {},
      userId: principal.userId,
    });
  }

  private requireConnector(
    principal: PrincipalContext,
    connectorId: string,
    options: { needWrite?: boolean } = {},
  ): { connector: Connector } {
    const connector = this.store.connectors.get(connectorId);
    if (!connector) throw ApiError.notFound('Connector not found', { connectorId });
    this.pages.requirePage(principal, connector.pageId, options);
    return { connector };
  }

  private assertElements(pageId: string, fromElementId: string, toElementId: string): void {
    for (const [label, elementId] of [
      ['fromElementId', fromElementId],
      ['toElementId', toElementId],
    ] as const) {
      const element = this.store.elements.get(elementId);
      if (!element || element.pageId !== pageId) {
        throw ApiError.invalidArgument(`${label} does not reference an element on this page`, { elementId });
      }
    }
  }
}
