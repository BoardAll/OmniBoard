/** 跨测试共享的固定数据与认证装配（不含任何真实凭据）。 */

import {
  ApiKeyAuthenticator,
  CompositeAuthenticator,
  KNOWN_SCOPES,
  parseApiKeys,
} from '../src/auth/index.js';

export const TEST_API_KEY = 'wbp_test_transport_key';

export const AUTH_HEADERS: Record<string, string> = { 'x-api-key': TEST_API_KEY };

/** 全 Scope 的 API Key 认证器（覆盖 HTTP 传输所需权限）。 */
export function testApiKeyAuthenticator(): CompositeAuthenticator {
  const { keys } = parseApiKeys(
    JSON.stringify({
      [TEST_API_KEY]: { userId: 'u-transport', scopes: [...KNOWN_SCOPES], boards: null },
    }),
  );
  return new CompositeAuthenticator({ apiKeys: new ApiKeyAuthenticator(keys) });
}

/** 标准 initialize 请求（协议版本默认取本服务最新支持版本）。 */
export function initializeRequest(
  id: string | number = 1,
  protocolVersion = '2025-06-18',
): Record<string, unknown> {
  return {
    jsonrpc: '2.0',
    id,
    method: 'initialize',
    params: {
      protocolVersion,
      capabilities: {},
      clientInfo: { name: 'vitest', version: '1.0.0' },
    },
  };
}
