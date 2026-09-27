import { Router } from 'express';
import {
  COLLABORATOR_SCHEMA,
  CREATE_BOARD_SCHEMA,
  SHARE_BOARD_SCHEMA,
  UPDATE_BOARD_SCHEMA,
} from '../db/schema.js';
import { handle, principalOf, requireConfirm, respond, respondList } from '../lib/handlers.js';
import { parseCursor, parseFilter, parseLimit, parseSort } from '../lib/query.js';
import { parseBody } from '../lib/validate.js';
import { requireScope } from '../middleware/auth.js';
import { auditContext, summariseArgs } from '../middleware/audit.js';
import type { BoardService } from '../services/boardService.js';

/**
 * Boards 路由（《OpenAPI规范.md》§5.1，挂载于 `/v1`）。
 *
 * | GET    /boards                              | board:read  |
 * | POST   /boards                              | board:write |
 * | GET    /boards/{boardId}                    | board:read  |
 * | PATCH  /boards/{boardId}                    | board:write |
 * | DELETE /boards/{boardId}?confirm=true       | board:write |
 * | POST   /boards/{boardId}/share              | board:share |
 * | GET    /boards/{boardId}/collaborators      | board:read  |
 * | POST   /boards/{boardId}/collaborators      | board:share |
 * | DELETE /boards/{boardId}/collaborators/{userId}?confirm=true | board:share |
 *
 * DELETE 为破坏性操作：缺少 `?confirm=true` → 422（detail.confirmationRequired）。
 * POST/PATCH/DELETE 携带 `Idempotency-Key` 时由全局幂等中间件处理（§4.8）。
 */

export interface BoardsRouterDeps {
  board: BoardService;
}

const SORT_FIELDS = ['createdAt', 'updatedAt', 'name'] as const;
const FILTER_FIELDS = ['name', 'createdBy'] as const;

export function createBoardsRouter(deps: BoardsRouterDeps): Router {
  const router = Router();

  router.get(
    '/boards',
    requireScope('board:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      respondList(
        req,
        res,
        deps.board.list(principal, {
          limit: parseLimit(req.query['limit']),
          offset: parseCursor(req.query['cursor']),
          sort: parseSort(req.query['sort'], SORT_FIELDS, { field: 'createdAt', dir: 'desc' }),
          filter: parseFilter(req.query['filter'], FILTER_FIELDS),
        }),
      );
    }),
  );

  router.post(
    '/boards',
    requireScope('board:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const input = parseBody(CREATE_BOARD_SCHEMA, req.body);
      auditContext(res, { action: 'board.create', argsJson: summariseArgs(req.body) });
      const board = deps.board.create(principal, input);
      auditContext(res, { target: { type: 'board', id: board.id }, boardId: board.id });
      respond(req, res, board, 201);
    }),
  );

  router.get(
    '/boards/:boardId',
    requireScope('board:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      respond(req, res, deps.board.get(principal, req.params['boardId'] ?? ''));
    }),
  );

  router.patch(
    '/boards/:boardId',
    requireScope('board:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const boardId = req.params['boardId'] ?? '';
      const input = parseBody(UPDATE_BOARD_SCHEMA, req.body);
      auditContext(res, {
        action: 'board.update',
        target: { type: 'board', id: boardId },
        boardId,
        argsJson: summariseArgs(req.body),
      });
      respond(req, res, deps.board.update(principal, boardId, input));
    }),
  );

  router.delete(
    '/boards/:boardId',
    requireScope('board:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const boardId = req.params['boardId'] ?? '';
      auditContext(res, { action: 'board.delete', target: { type: 'board', id: boardId }, boardId });
      requireConfirm(req, `Deleting board ${boardId}`);
      deps.board.remove(principal, boardId);
      res.status(204).end();
    }),
  );

  router.post(
    '/boards/:boardId/share',
    requireScope('board:share'),
    handle((req, res) => {
      const principal = principalOf(req);
      const boardId = req.params['boardId'] ?? '';
      const input = parseBody(SHARE_BOARD_SCHEMA, req.body ?? {});
      auditContext(res, {
        action: 'board.share',
        target: { type: 'board', id: boardId },
        boardId,
        argsJson: summariseArgs(req.body),
      });
      respond(req, res, deps.board.share(principal, boardId, input));
    }),
  );

  router.get(
    '/boards/:boardId/collaborators',
    requireScope('board:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      respond(req, res, deps.board.listCollaborators(principal, req.params['boardId'] ?? ''));
    }),
  );

  router.post(
    '/boards/:boardId/collaborators',
    requireScope('board:share'),
    handle((req, res) => {
      const principal = principalOf(req);
      const boardId = req.params['boardId'] ?? '';
      const input = parseBody(COLLABORATOR_SCHEMA, req.body);
      auditContext(res, {
        action: 'board.addCollaborator',
        target: { type: 'board', id: boardId },
        boardId,
        argsJson: summariseArgs(req.body),
      });
      respond(req, res, deps.board.addCollaborator(principal, boardId, input), 201);
    }),
  );

  router.delete(
    '/boards/:boardId/collaborators/:userId',
    requireScope('board:share'),
    handle((req, res) => {
      const principal = principalOf(req);
      const boardId = req.params['boardId'] ?? '';
      const userId = req.params['userId'] ?? '';
      auditContext(res, {
        action: 'board.removeCollaborator',
        target: { type: 'user', id: userId },
        boardId,
      });
      requireConfirm(req, `Removing collaborator ${userId}`);
      deps.board.removeCollaborator(principal, boardId, userId);
      res.status(204).end();
    }),
  );

  return router;
}
