import { Router } from 'express';
import { CREATE_SNAPSHOT_SCHEMA, UNDO_REDO_SCHEMA } from '../db/schema.js';
import { handle, principalOf, respond, respondList } from '../lib/handlers.js';
import { parseCursor, parseFilter, parseLimit, parseSort } from '../lib/query.js';
import { parseBody } from '../lib/validate.js';
import { requireScope } from '../middleware/auth.js';
import { auditContext, summariseArgs } from '../middleware/audit.js';
import type { BoardService } from '../services/boardService.js';
import type { HistoryService } from '../services/historyService.js';

/**
 * History 路由（《OpenAPI规范.md》§5.7，挂载于 `/v1`）。
 *
 * | GET  /boards/{boardId}/history      | history:read  |
 * | POST /boards/{boardId}/undo         | history:write |
 * | POST /boards/{boardId}/redo         | history:write |
 * | POST /boards/{boardId}/snapshot     | history:write |
 *
 * Wave 2.8：undo/redo 更新内存命令栈状态（见 historyService 注释）；
 * Wave 4 接入命令层事务回滚，接口形状不变。
 */

export interface HistoryRouterDeps {
  board: BoardService;
  history: HistoryService;
}

const SORT_FIELDS = ['seq', 'createdAt'] as const;
const FILTER_FIELDS = ['action', 'status'] as const;

export function createHistoryRouter(deps: HistoryRouterDeps): Router {
  const router = Router();

  router.get(
    '/boards/:boardId/history',
    requireScope('history:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      const boardId = req.params['boardId'] ?? '';
      deps.board.assertAccess(principal, boardId);
      respondList(
        req,
        res,
        deps.history.list(principal, boardId, {
          limit: parseLimit(req.query['limit']),
          offset: parseCursor(req.query['cursor']),
          sort: parseSort(req.query['sort'], SORT_FIELDS, { field: 'seq', dir: 'desc' }),
          filter: parseFilter(req.query['filter'], FILTER_FIELDS),
        }),
      );
    }),
  );

  router.post(
    '/boards/:boardId/undo',
    requireScope('history:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const boardId = req.params['boardId'] ?? '';
      const input = parseBody(UNDO_REDO_SCHEMA, req.body ?? {});
      deps.board.assertAccess(principal, boardId, { needWrite: true });
      auditContext(res, {
        action: 'history.undo',
        target: { type: 'board', id: boardId },
        boardId,
        argsJson: summariseArgs(req.body),
      });
      respond(req, res, deps.history.undo(principal, boardId, input.transactionId));
    }),
  );

  router.post(
    '/boards/:boardId/redo',
    requireScope('history:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const boardId = req.params['boardId'] ?? '';
      const input = parseBody(UNDO_REDO_SCHEMA, req.body ?? {});
      deps.board.assertAccess(principal, boardId, { needWrite: true });
      auditContext(res, {
        action: 'history.redo',
        target: { type: 'board', id: boardId },
        boardId,
        argsJson: summariseArgs(req.body),
      });
      respond(req, res, deps.history.redo(principal, boardId, input.transactionId));
    }),
  );

  router.post(
    '/boards/:boardId/snapshot',
    requireScope('history:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const boardId = req.params['boardId'] ?? '';
      const input = parseBody(CREATE_SNAPSHOT_SCHEMA, req.body ?? {});
      deps.board.assertAccess(principal, boardId, { needWrite: true });
      auditContext(res, {
        action: 'history.snapshot',
        target: { type: 'board', id: boardId },
        boardId,
        argsJson: summariseArgs(req.body),
      });
      respond(req, res, deps.history.createSnapshot(principal, boardId, input.name), 201);
    }),
  );

  return router;
}
