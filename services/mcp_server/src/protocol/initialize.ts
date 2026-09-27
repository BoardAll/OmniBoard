import { RpcError } from './jsonrpc.js';

/**
 * 初始化握手与版本/能力协商（《MCP_Server详细设计》§5）。
 *
 * - `initialize` 请求携带客户端 `protocolVersion` / `capabilities` / `clientInfo`
 * - 服务端返回自身 `protocolVersion` / `capabilities` / `serverInfo` / `instructions`
 * - 不支持的协议版本 → -32602（§5.4）
 * - `notifications/initialized` 完成握手（由 dispatcher 标记会话状态）
 */

/** 支持的协议版本（§5.4）。 */
export const SUPPORTED_PROTOCOL_VERSIONS = ['2025-06-18', '2024-11-05'] as const;
export type ProtocolVersion = (typeof SUPPORTED_PROTOCOL_VERSIONS)[number];

export const LATEST_PROTOCOL_VERSION: ProtocolVersion = '2025-06-18';

export const SERVER_INFO = {
  name: 'whiteboard-mcp',
  version: '1.0.0',
} as const;

/** 服务端能力（§5.2）。 */
export const SERVER_CAPABILITIES = {
  tools: { listChanged: true },
  resources: { subscribe: true, listChanged: true },
  prompts: { listChanged: true },
  logging: {},
} as const;

export const SERVER_INSTRUCTIONS =
  '白板 MCP Server，支持元素、页面、3D、函数、流程图等操作。';

export interface InitializeClientInfo {
  name: string;
  version: string;
}

export interface InitializeParams {
  protocolVersion?: unknown;
  capabilities?: unknown;
  clientInfo?: unknown;
}

export interface InitializeResult {
  protocolVersion: ProtocolVersion;
  capabilities: typeof SERVER_CAPABILITIES;
  serverInfo: typeof SERVER_INFO;
  instructions: string;
}

/** 会话元数据：握手后由传输层保留（stdio 全局一份；HTTP 按会话头区分）。 */
export interface SessionMeta {
  clientInfo: InitializeClientInfo | null;
  protocolVersion: ProtocolVersion;
  initialized: boolean;
  createdAt: string;
}

export function createSession(): SessionMeta {
  return {
    clientInfo: null,
    protocolVersion: LATEST_PROTOCOL_VERSION,
    initialized: false,
    createdAt: new Date().toISOString(),
  };
}

function parseClientInfo(raw: unknown): InitializeClientInfo | null {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null;
  const record = raw as Record<string, unknown>;
  const name = typeof record['name'] === 'string' ? record['name'] : 'unknown';
  const version = typeof record['version'] === 'string' ? record['version'] : '0.0.0';
  return { name, version };
}

/**
 * 处理 `initialize` 请求：协商版本、生成服务端结果并更新会话元数据。
 * 版本缺失时按最新版本处理（宽松；MCP 客户端通常显式携带）。
 */
export function handleInitialize(
  params: InitializeParams | undefined,
  session: SessionMeta = createSession(),
): { result: InitializeResult; session: SessionMeta } {
  const requested = params?.protocolVersion;
  if (requested !== undefined) {
    if (typeof requested !== 'string') {
      throw RpcError.invalidParams('protocolVersion must be a string');
    }
    if (!(SUPPORTED_PROTOCOL_VERSIONS as readonly string[]).includes(requested)) {
      throw new RpcError(-32602, `Unsupported protocol version: ${requested}`, {
        supported: [...SUPPORTED_PROTOCOL_VERSIONS],
      });
    }
    session.protocolVersion = requested as ProtocolVersion;
  } else {
    session.protocolVersion = LATEST_PROTOCOL_VERSION;
  }
  session.clientInfo = parseClientInfo(params?.clientInfo);
  return {
    result: {
      protocolVersion: session.protocolVersion,
      capabilities: SERVER_CAPABILITIES,
      serverInfo: SERVER_INFO,
      instructions: SERVER_INSTRUCTIONS,
    },
    session,
  };
}
