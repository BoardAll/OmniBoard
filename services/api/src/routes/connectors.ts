import { Router } from 'express';
import { CREATE_CONNECTOR_SCHEMA, UPDATE_CONNECTOR_SCHEMA } from '../db/schema.js';
import { handle, principalOf, requireConfirm, respond, respondList } from '../lib/handlers.js';
import { parseCursor, parseFilter, parseLimit, parseSort } from '../lib/query.js';
import { parseBody } from '../lib/validate.js';
import { requireScope } from '../middleware/auth.js';
import { auditContext, summariseArgs } from '../middleware/audit.js';
import type { ConnectorService } from '../services/connectorService.js';

/**
 * Connectors 路由（《OpenAPI规范.md》§5.4，挂载于 `/v1`）。
 *
 * | GET    /pages/{pageId}/connectors          | connector:read  |
 * | POST   /pages/{pageId}/connectors          | connector:write |
 * | GET    /connectors/{connectorId}           | connector:read  |
 * | PATCH  /connectors/{connectorId}           | connector:write |
 * | DELETE /connectors/{connectorId}?confirm=true | connector:write |
 *
 * 创建连线要求两端元素存在且位于同一页面（service 层校验，INVALID_ARGUMENT）。
 */

export interface ConnectorsRouterDeps {
  connector: ConnectorService;
}

const SORT_FIELDS = ['createdAt', 'updatedAt'] as const;
const FILTER_FIELDS = ['style', 'fromElementId', 'toElementId'] as const;

export function createConnectorsRouter(deps: ConnectorsRouterDeps): Router {
  const router = Router();

  router.get(
    '/pages/:pageId/connectors',
    requireScope('connector:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      respondList(
        req,
        res,
        deps.connector.listByPage(principal, req.params['pageId'] ?? '', {
          limit: parseLimit(req.query['limit']),
          offset: parseCursor(req.query['cursor']),
          sort: parseSort(req.query['sort'], SORT_FIELDS, { field: 'createdAt', dir: 'asc' }),
          filter: parseFilter(req.query['filter'], FILTER_FIELDS),
        }),
      );
    }),
  );

  router.post(
    '/pages/:pageId/connectors',
    requireScope('connector:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const pageId = req.params['pageId'] ?? '';
      const input = parseBody(CREATE_CONNECTOR_SCHEMA, req.body);
      auditContext(res, {
        action: 'connector.create',
        target: { type: 'page', id: pageId },
        argsJson: summariseArgs(req.body),
      });
      const connector = deps.connector.create(principal, pageId, input);
      auditContext(res, { target: { type: 'connector', id: connector.id } });
      respond(req, res, connector, 201);
    }),
  );

  router.get(
    '/connectors/:connectorId',
    requireScope('connector:read'),
    handle((req, res) => {
      const principal = principalOf(req);
      respond(req, res, deps.connector.get(principal, req.params['connectorId'] ?? ''));
    }),
  );

  router.patch(
    '/connectors/:connectorId',
    requireScope('connector:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const connectorId = req.params['connectorId'] ?? '';
      const input = parseBody(UPDATE_CONNECTOR_SCHEMA, req.body);
      auditContext(res, {
        action: 'connector.update',
        target: { type: 'connector', id: connectorId },
        argsJson: summariseArgs(req.body),
      });
      respond(req, res, deps.connector.update(principal, connectorId, input));
    }),
  );

  router.delete(
    '/connectors/:connectorId',
    requireScope('connector:write'),
    handle((req, res) => {
      const principal = principalOf(req);
      const connectorId = req.params['connectorId'] ?? '';
      auditContext(res, { action: 'connector.delete', target: { type: 'connector', id: connectorId } });
      requireConfirm(req, `Deleting connector ${connectorId}`);
      deps.connector.remove(principal, connectorId);
      res.status(204).end();
    }),
  );

  return router;
}
