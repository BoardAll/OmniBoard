/**
 * 可选：@modelcontextprotocol/sdk 兼容性冒烟。
 *
 * 仅使用 SDK 的稳定公开 API（Client + 内存桥接传输，不发起真实网络/进程），
 * 验证 initialize → notifications/initialized → tools/list → tools/call 全链路
 * 能被官方 SDK 客户端正确消费。
 *
 * SDK 缺失或版本不兼容时自动跳过（绝不使测试失败）。
 */

import { describe, expect, it } from 'vitest';
import type { DispatchContext, McpDispatcher } from '../src/dispatcher.js';
import { createFixture } from './helpers.js';

interface SdkTool {
  name: string;
  description?: string;
  inputSchema: { type?: string };
}

interface SdkClientLike {
  connect(transport: unknown): Promise<void>;
  listTools(): Promise<{ tools: SdkTool[] }>;
  callTool(input: { name: string; arguments?: Record<string, unknown> }): Promise<{
    content: Array<{ type: string; text?: string }>;
    isError?: boolean;
    structuredContent?: unknown;
  }>;
  close(): Promise<void>;
}

interface SdkModuleLike {
  Client: new (info: { name: string; version: string }) => SdkClientLike;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** SDK 客户端常领先于服务端协议版本：initialize 统一改写为本服务最新支持版本。 */
function rewriteInitializeVersion(message: unknown): unknown {
  if (!isRecord(message) || message['method'] !== 'initialize') return message;
  const params = message['params'];
  if (!isRecord(params)) return message;
  return { ...message, params: { ...params, protocolVersion: '2025-06-18' } };
}

/** 内存桥接：SDK Transport 接口 → 自研 dispatcher（保持协议分离，不依赖 SDK 实现服务端）。 */
class BridgeTransport {
  onmessage?: (message: unknown) => void;
  onerror?: (error: Error) => void;
  onclose?: () => void;

  constructor(
    private readonly dispatcher: McpDispatcher,
    private readonly ctx: DispatchContext,
  ) {}

  async start(): Promise<void> {
    /* 内存传输无需建立资源 */
  }

  async close(): Promise<void> {
    this.onclose?.();
  }

  async send(message: unknown): Promise<void> {
    const outgoing = rewriteInitializeVersion(message);
    const response = await this.dispatcher.handleRaw(JSON.stringify(outgoing), this.ctx);
    if (response === null) return;
    const items = Array.isArray(response) ? response : [response];
    for (const item of items) this.onmessage?.(item);
  }
}

/** 加载官方 SDK 客户端（两种子路径写法都尝试；失败返回 null → 跳过）。 */
async function loadSdkClient(): Promise<SdkModuleLike | null> {
  try {
    const mod = (await import('@modelcontextprotocol/sdk/client')) as unknown as SdkModuleLike;
    if (typeof mod.Client === 'function') return mod;
  } catch {
    /* 继续尝试官方文档推荐写法 */
  }
  try {
    const mod = (await import('@modelcontextprotocol/sdk/client/index.js')) as unknown as SdkModuleLike;
    if (typeof mod.Client === 'function') return mod;
  } catch {
    /* SDK 不可用 → 由调用方跳过 */
  }
  return null;
}

describe('SDK 兼容性冒烟（可选，SDK 不可用则跳过）', () => {
  it('Client.connect / listTools / callTool 经自研 dispatcher 全链路', async (context) => {
    const sdk = await loadSdkClient();
    if (!sdk) {
      console.warn('[sdk-compat] @modelcontextprotocol/sdk 不可用，跳过该冒烟测试');
      context.skip();
      return;
    }

    const fixture = createFixture();
    const transport = new BridgeTransport(fixture.dispatcher, fixture.ctx);
    const client = new sdk.Client({ name: 'vitest-sdk-client', version: '0.0.0' });

    try {
      await client.connect(transport);

      const listed = await client.listTools();
      expect(listed.tools).toHaveLength(113);
      expect(listed.tools.every((tool) => tool.inputSchema.type === 'object')).toBe(true);

      const called = await client.callTool({ name: 'board_get', arguments: { boardId: 'board-1' } });
      expect(called.isError).toBe(false);
      expect(called.content.length).toBeGreaterThan(0);
      expect(called.content[0]?.type).toBe('text');
    } finally {
      await client.close().catch(() => undefined);
    }
  });
});
