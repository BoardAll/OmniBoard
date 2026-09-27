import { Router } from 'express';
import {
  COMMENT_CONTENT_SCHEMA,
  CREATE_COMMENT_SCHEMA,
  RESOLVE_COMMENT_SCHEMA,
} from '../db/schema.js';
import { handle, principalOf, requireConfirm, respond, respondList } from '../lib/handlers.js';
import { parseCursor, parseFilter, parseLimit, parseSort } from '../lib/query.js';
import { parseBody } from '../lib/validate.js';
import { requireScope } from '../middleware/auth.js';
import { auditContext, summariseArgs } from '../middleware/audit.js';
import type { CommentService } from '../services/commentService.js';

/**
 * Comments 路由（《OpenAPI规范.md》§5.5，挂载于 `/v1`）。
 *
 * | GET    /boards/{boardId}/comments          | comment:read  |
 * | POST   /comments                           | comment:write |
 * | GET    /comments/{commentId}               | comment:read  |
 * | PATCH  /comments/{commentId}               | comment:write |
 * | DELETE /comments/{commentId}?confirm=true  | comment:write |
 * | POST   /comments/{commentId}/reply         | comment:write |
 * | POST   /comments/{commentId}/resolve       | comment:write |
 *
 * 编辑仅作者本人；删除允许作者或白板所有者（RESTful 惯例，文档未细化）。
 */

export interface CommentsRouterDeps {
  comment: CommentService;
}

const SORT_FIELDS = ['createdAt', 'updatedAt'] as const;
const FILTER_FIELDS = ['pageId', 'authorId', 'resolved'] as const;

export function createCommentsRouter(deps: CommentsRouterDeps): Router {
  const router = Router();

  router.get(
    '/boards/:boardId/comments',
    requireScope('comment:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      respondList(
        req,
        res,
        deps.comment.listByBoard(principal, req.params['boardId'] ?? '', {
          limit: parseLimit(req.query['limit']),
          offset: parseCursor(req.query['cursor']),
          sort: parseSort(req.query['sort'], SORT_FIELDS, { field: 'createdAt', dir: 'asc' }),
          filter: parseFilter(req.query['filter'], FILTER_FIELDS),
        }),
      );
    }),
  );

  router.post(
    '/comments',
    requireScope('comment:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const input = parseBody(CREATE_COMMENT_SCHEMA, req.body);
      auditContext(res, {
        action: 'comment.create',
        target: { type: 'board', id: input.boardId },
        boardId: input.boardId,
        argsJson: summariseArgs(req.body),
      });
      respond(req, res, deps.comment.create(principal, input), 201);
    }),
  );

  router.get(
    '/comments/:commentId',
    requireScope('comment:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      respond(req, res, deps.comment.get(principal, req.params['commentId'] ?? ''));
    }),
  );

  router.patch(
    '/comments/:commentId',
    requireScope('comment:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const commentId = req.params['commentId'] ?? '';
      const input = parseBody(COMMENT_CONTENT_SCHEMA, req.body);
      auditContext(res, {
        action: 'comment.update',
        target: { type: 'comment', id: commentId },
        argsJson: summariseArgs(req.body),
      });
      respond(req, res, deps.comment.update(principal, commentId, input.content));
    }),
  );

  router.delete(
    '/comments/:commentId',
    requireScope('comment:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const commentId = req.params['commentId'] ?? '';
      auditContext(res, { action: 'comment.delete', target: { type: 'comment', id: commentId } });
      requireConfirm(req, `Deleting comment ${commentId}`);
      deps.comment.remove(principal, commentId);
      res.status(204).end();
    }),
  );

  router.post(
    '/comments/:commentId/reply',
    requireScope('comment:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const commentId = req.params['commentId'] ?? '';
      const input = parseBody(COMMENT_CONTENT_SCHEMA, req.body);
      auditContext(res, {
        action: 'comment.reply',
        target: { type: 'comment', id: commentId },
        argsJson: summariseArgs(req.body),
      });
      respond(req, res, deps.comment.reply(principal, commentId, input.content), 201);
    }),
  );

  router.post(
    '/comments/:commentId/resolve',
    requireScope('comment:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const commentId = req.params['commentId'] ?? '';
      const input = parseBody(RESOLVE_COMMENT_SCHEMA, req.body ?? {});
      auditContext(res, { action: 'comment.resolve', target: { type: 'comment', id: commentId } });
      respond(req, res, deps.comment.resolve(principal, commentId, input.resolved));
    }),
  );

  return router;
}
