import { ApiError } from '../lib/errors.js';
import { newId } from '../lib/ids.js';
import type { DataStore } from '../db/memory.js';
import type {
  AIMessage,
  AISession,
  AIToolCall,
  CreateAISessionInput,
  SendAIAudioInput,
  SendAIMessageInput,
} from '../db/schema.js';
import type { PrincipalContext } from './access.js';
import type { BoardService } from './boardService.js';

/**
 * AI 会话（《OpenAPI规范.md》§5.8）。
 *
 * Wave 2.8：提供可注入的 `AIProvider`；默认 `StubAIProvider` 返回确定性回复，
 * 保证无外部依赖时测试全绿。真实模型调用由 services/ai_gateway（Wave 3）
 * 实现同一接口并在 app.ts 注入。
 */

export interface AIProviderRequest {
  boardId: string;
  messages: AIMessage[];
  model: string;
}

export interface AIProviderResponse {
  content: string;
}

export interface AIProvider {
  readonly name: string;
  chat(request: AIProviderRequest): Promise<AIProviderResponse>;
}

/** 无外部依赖的确定性占位实现（Wave 3 由 ai_gateway 替换）。 */
export class StubAIProvider implements AIProvider {
  readonly name = 'stub';

  async chat(request: AIProviderRequest): Promise<AIProviderResponse> {
    const last = request.messages[request.messages.length - 1];
    return {
      content: `[stub:${request.model}] 已收到 ${request.messages.length} 条上下文，最后一条：${last?.content ?? ''}`,
    };
  }
}

export class AIService {
  constructor(
    private readonly store: DataStore,
    private readonly boards: BoardService,
    private readonly provider: AIProvider = new StubAIProvider(),
  ) {}

  createSession(principal: PrincipalContext, input: CreateAISessionInput): AISession {
    this.boards.assertAccess(principal, input.boardId, { needWrite: true });
    const now = new Date().toISOString();
    const session: AISession = {
      id: newId('ais'),
      boardId: input.boardId,
      userId: principal.userId,
      provider: input.provider ?? this.provider.name,
      model: input.model ?? 'whiteboard-assistant-v1',
      status: 'active',
      createdAt: now,
      updatedAt: now,
    };
    this.store.aiSessions.set(session.id, session);
    return session;
  }

  getSession(principal: PrincipalContext, sessionId: string): AISession {
    return this.requireSession(principal, sessionId).session;
  }

  async sendMessage(principal: PrincipalContext, sessionId: string, input: SendAIMessageInput): Promise<{
    message: AIMessage;
    reply: AIMessage;
    toolCalls: AIToolCall[];
  }> {
    const { session } = this.requireSession(principal, sessionId, { needWrite: true });
    const now = new Date().toISOString();
    const message: AIMessage = {
      id: newId('aim'),
      sessionId,
      role: input.role,
      content: input.content,
      source: 'text',
      createdAt: now,
    };
    this.store.aiMessages.set(message.id, message);

    const toolCalls: AIToolCall[] = (input.toolCalls ?? []).map((plan) => {
      const call: AIToolCall = {
        id: newId('aitc'),
        sessionId,
        toolId: plan.toolId,
        args: plan.args ?? {},
        status: 'pending',
        preview: null,
        result: null,
        createdAt: now,
        updatedAt: now,
      };
      this.store.aiToolCalls.set(call.id, call);
      return call;
    });

    const history = this.sessionMessages(sessionId);
    const completion = await this.provider.chat({ boardId: session.boardId, messages: history, model: session.model });
    const reply: AIMessage = {
      id: newId('aim'),
      sessionId,
      role: 'assistant',
      content: completion.content,
      source: 'text',
      createdAt: new Date().toISOString(),
    };
    this.store.aiMessages.set(reply.id, reply);
    session.updatedAt = reply.createdAt;
    this.store.aiSessions.set(session.id, session);
    return { message, reply, toolCalls };
  }

  /** 语音入口（Wave 2.8 stub：接收音频，ASR 由 ai_gateway 在 Wave 3 实现）。 */
  async sendAudio(principal: PrincipalContext, sessionId: string, input: SendAIAudioInput): Promise<{
    accepted: boolean;
    message: AIMessage;
    recognizedText: string | null;
  }> {
    const { session } = this.requireSession(principal, sessionId, { needWrite: true });
    const message: AIMessage = {
      id: newId('aim'),
      sessionId,
      role: 'user',
      content: '[audio]',
      source: 'audio',
      createdAt: new Date().toISOString(),
    };
    this.store.aiMessages.set(message.id, message);
    session.updatedAt = message.createdAt;
    this.store.aiSessions.set(session.id, session);
    void input;
    return { accepted: true, message, recognizedText: null };
  }

  listMessages(principal: PrincipalContext, sessionId: string): AIMessage[] {
    this.requireSession(principal, sessionId);
    return this.sessionMessages(sessionId);
  }

  previewToolCall(principal: PrincipalContext, toolCallId: string): AIToolCall {
    const { call } = this.requireToolCall(principal, toolCallId, { needWrite: true });
    if (call.status === 'cancelled') throw ApiError.conflict('Tool call is cancelled', { toolCallId });
    call.status = 'previewed';
    call.preview = {
      toolId: call.toolId,
      args: call.args,
      dryRun: true,
      note: 'Wave 2.8 preview stub — 真实预览由命令层 dryRun 生成',
    };
    call.updatedAt = new Date().toISOString();
    this.store.aiToolCalls.set(call.id, call);
    return call;
  }

  executeToolCall(principal: PrincipalContext, toolCallId: string): AIToolCall {
    const { call } = this.requireToolCall(principal, toolCallId, { needWrite: true });
    if (call.status === 'cancelled') throw ApiError.conflict('Tool call is cancelled', { toolCallId });
    call.status = 'executed';
    call.result = {
      toolId: call.toolId,
      executedAt: new Date().toISOString(),
      note: 'Wave 2.8 execution stub — Wave 4 经命令层/事务执行',
    };
    call.updatedAt = new Date().toISOString();
    this.store.aiToolCalls.set(call.id, call);
    return call;
  }

  cancelToolCall(principal: PrincipalContext, toolCallId: string): AIToolCall {
    const { call } = this.requireToolCall(principal, toolCallId, { needWrite: true });
    // 取消幂等：重复取消返回同一结果。
    if (call.status !== 'cancelled') {
      call.status = 'cancelled';
      call.updatedAt = new Date().toISOString();
      this.store.aiToolCalls.set(call.id, call);
    }
    return call;
  }

  private sessionMessages(sessionId: string): AIMessage[] {
    return [...this.store.aiMessages.values()]
      .filter((m) => m.sessionId === sessionId)
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }

  private requireSession(
    principal: PrincipalContext,
    sessionId: string,
    options: { needWrite?: boolean } = {},
  ): { session: AISession } {
    const session = this.store.aiSessions.get(sessionId);
    if (!session) throw ApiError.notFound('AI session not found', { sessionId });
    this.boards.assertAccess(principal, session.boardId, options);
    return { session };
  }

  private requireToolCall(
    principal: PrincipalContext,
    toolCallId: string,
    options: { needWrite?: boolean } = {},
  ): { call: AIToolCall } {
    const call = this.store.aiToolCalls.get(toolCallId);
    if (!call) throw ApiError.notFound('Tool call not found', { toolCallId });
    this.requireSession(principal, call.sessionId, options);
    return { call };
  }
}
