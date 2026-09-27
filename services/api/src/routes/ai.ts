import { Router } from 'express';
import {
  CREATE_AI_SESSION_SCHEMA,
  SEND_AI_AUDIO_SCHEMA,
  SEND_AI_MESSAGE_SCHEMA,
} from '../db/schema.js';
import { handle, principalOf, respond } from '../lib/handlers.js';
import { parseBody } from '../lib/validate.js';
import { requireScope } from '../middleware/auth.js';
import { auditContext, summariseArgs } from '../middleware/audit.js';
import type { AIService } from '../services/aiService.js';

/**
 * AI 路由（《OpenAPI规范.md》§5.8，挂载于 `/v1`）。
 *
 * | POST /ai/sessions                        | ai:invoke |
 * | GET  /ai/sessions/{sessionId}            | ai:invoke |
 * | GET  /ai/sessions/{sessionId}/messages   | ai:invoke |
 * | POST /ai/sessions/{sessionId}/messages   | ai:invoke |
 * | POST /ai/sessions/{sessionId}/audio      | ai:invoke |
 * | POST /ai/toolCalls/{toolCallId}/preview  | ai:invoke |
 * | POST /ai/toolCalls/{toolCallId}/execute  | ai:invoke |
 * | POST /ai/toolCalls/{toolCallId}/cancel   | ai:invoke |
 *
 * Wave 2.8：模型调用经可注入的 `AIProvider`（默认 StubAIProvider，确定性回复），
 * 语音为 stub（ASR 由 services/ai_gateway 在 Wave 3 接入）；工具调用
 * preview/execute/cancel 记录状态机（破坏性语义由 MCP confirm 流程对齐）。
 */

export interface AiRouterDeps {
  ai: AIService;
}

export function createAiRouter(deps: AiRouterDeps): Router {
  const router = Router();

  router.post(
    '/ai/sessions',
    requireScope('ai:invoke'),
    handle((req, res) => {
      const principal = principalOf(req);
      const input = parseBody(CREATE_AI_SESSION_SCHEMA, req.body);
      auditContext(res, {
        action: 'ai.session.create',
        target: { type: 'board', id: input.boardId },
        boardId: input.boardId,
        argsJson: summariseArgs(req.body),
      });
      respond(req, res, deps.ai.createSession(principal, input), 201);
    }),
  );

  router.get(
    '/ai/sessions/:sessionId',
    requireScope('ai:invoke'),
    handle((req, res) => {
      const principal = principalOf(req);
      respond(req, res, deps.ai.getSession(principal, req.params['sessionId'] ?? ''));
    }),
  );

  router.get(
    '/ai/sessions/:sessionId/messages',
    requireScope('ai:invoke'),
    handle((req, res) => {
      const principal = principalOf(req);
      respond(req, res, deps.ai.listMessages(principal, req.params['sessionId'] ?? ''));
    }),
  );

  router.post(
    '/ai/sessions/:sessionId/messages',
    requireScope('ai:invoke'),
    handle(async (req, res) => {
      const principal = principalOf(req);
      const sessionId = req.params['sessionId'] ?? '';
      const input = parseBody(SEND_AI_MESSAGE_SCHEMA, req.body);
      auditContext(res, {
        action: 'ai.sendMessage',
        target: { type: 'ai_session', id: sessionId },
        argsJson: summariseArgs(req.body),
      });
      respond(req, res, await deps.ai.sendMessage(principal, sessionId, input));
    }),
  );

  router.post(
    '/ai/sessions/:sessionId/audio',
    requireScope('ai:invoke'),
    handle(async (req, res) => {
      const principal = principalOf(req);
      const sessionId = req.params['sessionId'] ?? '';
      const input = parseBody(SEND_AI_AUDIO_SCHEMA, req.body ?? {});
      auditContext(res, { action: 'ai.sendAudio', target: { type: 'ai_session', id: sessionId } });
      respond(req, res, await deps.ai.sendAudio(principal, sessionId, input));
    }),
  );

  router.post(
    '/ai/toolCalls/:toolCallId/preview',
    requireScope('ai:invoke'),
    handle((req, res) => {
      const principal = principalOf(req);
      const toolCallId = req.params['toolCallId'] ?? '';
      auditContext(res, { action: 'ai.toolCall.preview', target: { type: 'ai_tool_call', id: toolCallId } });
      respond(req, res, deps.ai.previewToolCall(principal, toolCallId));
    }),
  );

  router.post(
    '/ai/toolCalls/:toolCallId/execute',
    requireScope('ai:invoke'),
    handle((req, res) => {
      const principal = principalOf(req);
      const toolCallId = req.params['toolCallId'] ?? '';
      auditContext(res, { action: 'ai.toolCall.execute', target: { type: 'ai_tool_call', id: toolCallId } });
      respond(req, res, deps.ai.executeToolCall(principal, toolCallId));
    }),
  );

  router.post(
    '/ai/toolCalls/:toolCallId/cancel',
    requireScope('ai:invoke'),
    handle((req, res) => {
      const principal = principalOf(req);
      const toolCallId = req.params['toolCallId'] ?? '';
      auditContext(res, { action: 'ai.toolCall.cancel', target: { type: 'ai_tool_call', id: toolCallId } });
      respond(req, res, deps.ai.cancelToolCall(principal, toolCallId));
    }),
  );

  return router;
}
