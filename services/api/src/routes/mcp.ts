import { Router } from 'express';
import { z } from 'zod';
import { buildMeta, okBody } from '../lib/response.js';
import { handle, principalOf, respond } from '../lib/handlers.js';
import { parseBody } from '../lib/validate.js';
import { requireScope } from '../middleware/auth.js';
import { auditContext, summariseArgs } from '../middleware/audit.js';
import type { McpBridgeService } from '../services/mcpService.js';

/**
 * MCP 桥接路由（《OpenAPI规范.md》§5.10，挂载于 `/v1`）。
 *
 * | GET  /mcp/tools                 | mcp:invoke | 列出 MCP 工具（静态目录）      |
 * | POST /mcp/tools/{toolName}/call | mcp:invoke | 调用 MCP 工具（含确认流程）    |
 * | GET  /mcp/server                | mcp:invoke | MCP Server 信息（协议/能力）   |
 *
 * 说明（RESTful 惯例，文档未细化处）：
 *  - `GET /mcp/tools` 返回 `data` 为数组（dart api_client `requestList` 期望），
 *    meta 附加 total/hasMore=false（工具目录静态、不分页）。
 *  - `POST .../call` 请求体 `{ arguments, confirm? }`；`confirm` 为破坏性工具的
 *    显式确认标记（对齐 MCP `confirm_operation` 流程），缺失时 service 抛
 *    422 `confirmationRequired`。
 *  - 工具级 scope 与确认级别由 `McpBridgeService` 按目录统一校验（§14 映射表）。
 *  - MCP 调用可能来自 AI 客户端，审计 `fromAI: true`。
 */

export interface McpRouterDeps {
  mcp: McpBridgeService;
}

/** POST /mcp/tools/{toolName}/call 请求体（工具入参 + 确认标记）。 */
export const CALL_TOOL_SCHEMA = z
  .object({
    arguments: z.record(z.unknown()).optional().default({}),
    confirm: z.boolean().optional(),
  })
  .strict();

export function createMcpRouter(deps: McpRouterDeps): Router {
  const router = Router();

  router.get(
    '/mcp/tools',
    requireScope('mcp:invoke'),
    handle((req, res) => {
      const tools = deps.mcp.listTools();
      res.json(
        okBody(
          tools,
          buildMeta(req.requestId ?? '', { total: tools.length, hasMore: false, nextCursor: null }),
        ),
      );
    }),
  );

  router.post(
    '/mcp/tools/:toolName/call',
    requireScope('mcp:invoke'),
    handle(async (req, res) => {
      const principal = principalOf(req);
      const toolName = req.params['toolName'] ?? '';
      const input = parseBody(CALL_TOOL_SCHEMA, req.body ?? {});
      auditContext(res, {
        action: 'mcp.callTool',
        target: { type: 'mcp_tool', id: toolName },
        argsJson: summariseArgs(req.body),
        fromAI: true,
      });
      respond(req, res, await deps.mcp.callTool(principal, toolName, input));
    }),
  );

  router.get(
    '/mcp/server',
    requireScope('mcp:invoke'),
    handle((req, res) => {
      respond(req, res, deps.mcp.getServerInfo());
    }),
  );

  return router;
}
