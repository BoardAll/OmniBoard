import { Router } from 'express';
import {
  CREATE_PAGE_SCHEMA,
  MERGE_PAGES_SCHEMA,
  MOVE_PAGE_SCHEMA,
  SPLIT_PAGE_SCHEMA,
  UPDATE_PAGE_SCHEMA,
} from '../db/schema.js';
import { handle, principalOf, requireConfirm, respond, respondList } from '../lib/handlers.js';
import { parseCursor, parseFilter, parseLimit, parseSort } from '../lib/query.js';
import { parseBody } from '../lib/validate.js';
import { requireScope } from '../middleware/auth.js';
import { auditContext, summariseArgs } from '../middleware/audit.js';
import type { BoardService } from '../services/boardService.js';
import type { PageService } from '../services/pageService.js';

/**
 * Pages 路由（《OpenAPI规范.md》§5.2，挂载于 `/v1`）。
 *
 * | GET    /boards/{boardId}/pages       | page:read  |
 * | POST   /boards/{boardId}/pages       | page:write |
 * | GET    /pages/{pageId}               | page:read  |
 * | PATCH  /pages/{pageId}               | page:write |
 * | DELETE /pages/{pageId}?confirm=true  | page:write |
 * | POST   /pages/{pageId}/duplicate     | page:write |
 * | POST   /pages/{pageId}/move          | page:write |
 * | POST   /pages/{pageId}/split         | page:write |
 * | POST   /pages/merge                  | page:write |
 * | GET    /pages/{pageId}/thumbnail     | page:read  |
 *
 * 文档未定义 split/merge 的请求体 —— RESTful 约定：split 按 `splitY`（y 轴）
 * 切分元素到新页；merge 以 `pageIds[0]` 为目标页（见 pageService 注释）。
 * 创建类 POST 返回 201；动作类 POST 返回 200；DELETE `?confirm=true` → 204。
 */

export interface PagesRouterDeps {
  board: BoardService;
  page: PageService;
}

const SORT_FIELDS = ['createdAt', 'updatedAt', 'name', 'index'] as const;
const FILTER_FIELDS = ['locked', 'hidden'] as const;

export function createPagesRouter(deps: PagesRouterDeps): Router {
  const router = Router();

  router.get(
    '/boards/:boardId/pages',
    requireScope('page:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      respondList(
        req,
        res,
        deps.page.listByBoard(principal, req.params['boardId'] ?? '', {
          limit: parseLimit(req.query['limit']),
          offset: parseCursor(req.query['cursor']),
          sort: parseSort(req.query['sort'], SORT_FIELDS, { field: 'index', dir: 'asc' }),
          filter: parseFilter(req.query['filter'], FILTER_FIELDS),
        }),
      );
    }),
  );

  router.post(
    '/boards/:boardId/pages',
    requireScope('page:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const boardId = req.params['boardId'] ?? '';
      const input = parseBody(CREATE_PAGE_SCHEMA, req.body);
      auditContext(res, {
        action: 'page.create',
        target: { type: 'board', id: boardId },
        boardId,
        argsJson: summariseArgs(req.body),
      });
      const page = deps.page.create(principal, boardId, input);
      auditContext(res, { target: { type: 'page', id: page.id } });
      respond(req, res, page, 201);
    }),
  );

  // 注意：静态路径 `/pages/merge` 必须注册在参数路由 `/pages/:pageId` 之前。
  router.post(
    '/pages/merge',
    requireScope('page:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const input = parseBody(MERGE_PAGES_SCHEMA, req.body);
      auditContext(res, { action: 'page.merge', argsJson: summariseArgs(req.body) });
      const page = deps.page.merge(principal, input);
      auditContext(res, { target: { type: 'page', id: page.id }, boardId: page.boardId });
      respond(req, res, page);
    }),
  );

  router.get(
    '/pages/:pageId',
    requireScope('page:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      respond(req, res, deps.page.get(principal, req.params['pageId'] ?? ''));
    }),
  );

  router.patch(
    '/pages/:pageId',
    requireScope('page:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const pageId = req.params['pageId'] ?? '';
      const input = parseBody(UPDATE_PAGE_SCHEMA, req.body);
      auditContext(res, { action: 'page.update', target: { type: 'page', id: pageId }, argsJson: summariseArgs(req.body) });
      respond(req, res, deps.page.update(principal, pageId, input));
    }),
  );

  router.delete(
    '/pages/:pageId',
    requireScope('page:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const pageId = req.params['pageId'] ?? '';
      auditContext(res, { action: 'page.delete', target: { type: 'page', id: pageId } });
      requireConfirm(req, `Deleting page ${pageId}`);
      deps.page.remove(principal, pageId);
      res.status(204).end();
    }),
  );

  router.post(
    '/pages/:pageId/duplicate',
    requireScope('page:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const pageId = req.params['pageId'] ?? '';
      auditContext(res, { action: 'page.duplicate', target: { type: 'page', id: pageId } });
      respond(req, res, deps.page.duplicate(principal, pageId), 201);
    }),
  );

  router.post(
    '/pages/:pageId/move',
    requireScope('page:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const pageId = req.params['pageId'] ?? '';
      const input = parseBody(MOVE_PAGE_SCHEMA, req.body);
      auditContext(res, { action: 'page.move', target: { type: 'page', id: pageId }, argsJson: summariseArgs(req.body) });
      respond(req, res, deps.page.move(principal, pageId, input.index));
    }),
  );

  router.post(
    '/pages/:pageId/split',
    requireScope('page:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const pageId = req.params['pageId'] ?? '';
      const input = parseBody(SPLIT_PAGE_SCHEMA, req.body);
      auditContext(res, { action: 'page.split', target: { type: 'page', id: pageId }, argsJson: summariseArgs(req.body) });
      const page = deps.page.split(principal, pageId, input);
      auditContext(res, { target: { type: 'page', id: page.id }, boardId: page.boardId });
      respond(req, res, page, 201);
    }),
  );

  router.get(
    '/pages/:pageId/thumbnail',
    requireScope('page:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      respond(req, res, deps.page.thumbnail(principal, req.params['pageId'] ?? ''));
    }),
  );

  return router;
}
