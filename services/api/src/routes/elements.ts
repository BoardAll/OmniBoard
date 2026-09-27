import { Router } from 'express';
import {
  ALIGN_SCHEMA,
  CREATE_ELEMENTS_SCHEMA,
  DISTRIBUTE_SCHEMA,
  ELEMENT_BATCH_SCHEMA,
  GROUP_SCHEMA,
  MOVE_ELEMENT_SCHEMA,
  RESIZE_ELEMENT_SCHEMA,
  SET_STYLE_SCHEMA,
  UNGROUP_SCHEMA,
  UPDATE_ELEMENT_SCHEMA,
} from '../db/schema.js';
import { handle, principalOf, requireConfirm, respond, respondList } from '../lib/handlers.js';
import { parseCursor, parseFilter, parseLimit, parseSort } from '../lib/query.js';
import { parseBody } from '../lib/validate.js';
import { requireScope } from '../middleware/auth.js';
import { auditContext, summariseArgs } from '../middleware/audit.js';
import type { ElementService } from '../services/elementService.js';

/**
 * Elements 路由（《OpenAPI规范.md》§5.3，挂载于 `/v1`）。
 *
 * | GET    /pages/{pageId}/elements        | element:read  |
 * | POST   /pages/{pageId}/elements        | element:write |
 * | POST   /elements/batch                 | element:write |
 * | POST   /elements/align                 | element:write |
 * | POST   /elements/distribute            | element:write |
 * | POST   /elements/group                 | element:write |
 * | POST   /elements/ungroup               | element:write |
 * | GET    /elements/{elementId}           | element:read  |
 * | PATCH  /elements/{elementId}           | element:write |
 * | DELETE /elements/{elementId}?confirm=true | element:write |
 * | POST   /elements/{elementId}/style     | element:write |
 * | POST   /elements/{elementId}/move      | element:write |
 * | POST   /elements/{elementId}/resize    | element:write |
 *
 * - 排序字段：`createdAt` / `updatedAt` / `name` / `zIndex`（§4.6 的 `index` 映射到
 *   `zIndex`，兼容传入 `sort=index:asc`）。
 * - 过滤字段：`type` / `color` / `pageId` / `createdBy`（§4.7）。
 * - `/elements/batch` 含删除操作时为破坏性操作：请求体需 `confirm: true`（422 兜底）。
 * - DELETE `?confirm=true` → 204。创建类 POST → 201（dryRun 提案 → 200）。
 */

export interface ElementsRouterDeps {
  element: ElementService;
}

const SORT_FIELDS = ['createdAt', 'updatedAt', 'name', 'zIndex', 'index'] as const;
const FILTER_FIELDS = ['type', 'color', 'pageId', 'createdBy'] as const;

export function createElementsRouter(deps: ElementsRouterDeps): Router {
  const router = Router();

  router.get(
    '/pages/:pageId/elements',
    requireScope('element:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      const sort = parseSort(req.query['sort'], SORT_FIELDS, { field: 'zIndex', dir: 'asc' });
      respondList(
        req,
        res,
        deps.element.listByPage(principal, req.params['pageId'] ?? '', {
          limit: parseLimit(req.query['limit']),
          offset: parseCursor(req.query['cursor']),
          sort: sort.field === 'index' ? { field: 'zIndex', dir: sort.dir } : sort,
          filter: parseFilter(req.query['filter'], FILTER_FIELDS),
        }),
      );
    }),
  );

  router.post(
    '/pages/:pageId/elements',
    requireScope('element:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const pageId = req.params['pageId'] ?? '';
      const input = parseBody(CREATE_ELEMENTS_SCHEMA, req.body);
      auditContext(res, {
        action: 'element.create',
        target: { type: 'page', id: pageId },
        argsJson: summariseArgs(req.body),
      });
      const result = deps.element.createMany(principal, pageId, input);
      auditContext(res, { target: { type: 'element', id: result.elements[0]?.id ?? null } });
      // dryRun（提案）不产生资源：200；真实创建：201。
      respond(req, res, result, result.dryRun ? 200 : 201);
    }),
  );

  // 静态路径注册在参数路由之前。
  router.post(
    '/elements/batch',
    requireScope('element:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const input = parseBody(ELEMENT_BATCH_SCHEMA, req.body);
      auditContext(res, { action: 'element.batch', argsJson: summariseArgs(req.body) });
      respond(req, res, deps.element.batch(principal, input));
    }),
  );

  router.post(
    '/elements/align',
    requireScope('element:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const input = parseBody(ALIGN_SCHEMA, req.body);
      auditContext(res, { action: 'element.align', argsJson: summariseArgs(req.body) });
      respond(req, res, deps.element.align(principal, input));
    }),
  );

  router.post(
    '/elements/distribute',
    requireScope('element:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const input = parseBody(DISTRIBUTE_SCHEMA, req.body);
      auditContext(res, { action: 'element.distribute', argsJson: summariseArgs(req.body) });
      respond(req, res, deps.element.distribute(principal, input));
    }),
  );

  router.post(
    '/elements/group',
    requireScope('element:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const input = parseBody(GROUP_SCHEMA, req.body);
      auditContext(res, { action: 'element.group', argsJson: summariseArgs(req.body) });
      respond(req, res, deps.element.group(principal, input.elementIds));
    }),
  );

  router.post(
    '/elements/ungroup',
    requireScope('element:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const input = parseBody(UNGROUP_SCHEMA, req.body);
      auditContext(res, { action: 'element.ungroup', argsJson: summariseArgs(req.body) });
      respond(req, res, deps.element.ungroup(principal, input.groupId));
    }),
  );

  router.get(
    '/elements/:elementId',
    requireScope('element:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      respond(req, res, deps.element.get(principal, req.params['elementId'] ?? ''));
    }),
  );

  router.patch(
    '/elements/:elementId',
    requireScope('element:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const elementId = req.params['elementId'] ?? '';
      const input = parseBody(UPDATE_ELEMENT_SCHEMA, req.body);
      auditContext(res, { action: 'element.update', target: { type: 'element', id: elementId }, argsJson: summariseArgs(req.body) });
      respond(req, res, deps.element.update(principal, elementId, input));
    }),
  );

  router.delete(
    '/elements/:elementId',
    requireScope('element:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const elementId = req.params['elementId'] ?? '';
      auditContext(res, { action: 'element.delete', target: { type: 'element', id: elementId } });
      requireConfirm(req, `Deleting element ${elementId}`);
      deps.element.remove(principal, elementId);
      res.status(204).end();
    }),
  );

  router.post(
    '/elements/:elementId/style',
    requireScope('element:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const elementId = req.params['elementId'] ?? '';
      const input = parseBody(SET_STYLE_SCHEMA, req.body);
      auditContext(res, { action: 'element.setStyle', target: { type: 'element', id: elementId }, argsJson: summariseArgs(req.body) });
      respond(req, res, deps.element.setStyle(principal, elementId, input.style, input.merge));
    }),
  );

  router.post(
    '/elements/:elementId/move',
    requireScope('element:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const elementId = req.params['elementId'] ?? '';
      const input = parseBody(MOVE_ELEMENT_SCHEMA, req.body);
      auditContext(res, { action: 'element.move', target: { type: 'element', id: elementId }, argsJson: summariseArgs(req.body) });
      respond(req, res, deps.element.move(principal, elementId, input));
    }),
  );

  router.post(
    '/elements/:elementId/resize',
    requireScope('element:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const elementId = req.params['elementId'] ?? '';
      const input = parseBody(RESIZE_ELEMENT_SCHEMA, req.body);
      auditContext(res, { action: 'element.resize', target: { type: 'element', id: elementId }, argsJson: summariseArgs(req.body) });
      respond(req, res, deps.element.resize(principal, elementId, input));
    }),
  );

  return router;
}
