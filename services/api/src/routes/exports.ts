import { Router } from 'express';
import { CREATE_EXPORT_SCHEMA } from '../db/schema.js';
import { handle, principalOf, respond } from '../lib/handlers.js';
import { parseBody } from '../lib/validate.js';
import { requireScope } from '../middleware/auth.js';
import { auditContext, summariseArgs } from '../middleware/audit.js';
import type { ExportService } from '../services/exportService.js';

/**
 * Exports 路由（《OpenAPI规范.md》§5.6，挂载于 `/v1`）。
 *
 * | POST /boards/{boardId}/export       | export:read |
 * | POST /pages/{pageId}/export         | export:read |
 * | GET  /exports/{exportId}            | export:read |
 * | GET  /exports/{exportId}/download   | export:read |
 *
 * Wave 2.8：导出在内存中同步完成，`download` 返回 base64 内联内容；
 * Wave 4 由 services/convert 生成真实文件并经对象存储下发（形状不变）。
 */

export interface ExportsRouterDeps {
  exportJob: ExportService;
}

export function createExportsRouter(deps: ExportsRouterDeps): Router {
  const router = Router();

  router.post(
    '/boards/:boardId/export',
    requireScope('export:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      const boardId = req.params['boardId'] ?? '';
      const input = parseBody(CREATE_EXPORT_SCHEMA, req.body);
      auditContext(res, {
        action: 'export.create',
        target: { type: 'board', id: boardId },
        boardId,
        argsJson: summariseArgs(req.body),
      });
      respond(req, res, deps.exportJob.createBoardExport(principal, boardId, input), 201);
    }),
  );

  router.post(
    '/pages/:pageId/export',
    requireScope('export:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      const pageId = req.params['pageId'] ?? '';
      const input = parseBody(CREATE_EXPORT_SCHEMA, req.body);
      auditContext(res, {
        action: 'export.create',
        target: { type: 'page', id: pageId },
        argsJson: summariseArgs(req.body),
      });
      respond(req, res, deps.exportJob.createPageExport(principal, pageId, input), 201);
    }),
  );

  router.get(
    '/exports/:exportId',
    requireScope('export:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      respond(req, res, deps.exportJob.get(principal, req.params['exportId'] ?? ''));
    }),
  );

  router.get(
    '/exports/:exportId/download',
    requireScope('export:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      respond(req, res, deps.exportJob.download(principal, req.params['exportId'] ?? ''));
    }),
  );

  return router;
}
