/** JSON-RPC 2.0 编解码与错误码（自研协议层）。 */

import { describe, expect, it } from 'vitest';
import {
  failure,
  isNotification,
  isRequest,
  isResponse,
  JSONRPC_VERSION,
  notification,
  parseMessage,
  RPC_ERROR_CODES,
  RpcError,
  success,
  toErrorResponse,
} from '../src/protocol/jsonrpc.js';

describe('jsonrpc：parseMessage', () => {
  it('解析请求（保留 id / method / params）', () => {
    const message = parseMessage({
      jsonrpc: '2.0',
      id: 7,
      method: 'tools/call',
      params: { name: 'board_get' },
    });
    expect(isRequest(message)).toBe(true);
    expect(message).toMatchObject({ jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name: 'board_get' } });
  });

  it('解析通知（无 id）', () => {
    const message = parseMessage({ jsonrpc: '2.0', method: 'notifications/initialized' });
    expect(isNotification(message)).toBe(true);
    expect('id' in message).toBe(false);
  });

  it('解析成功响应与错误响应', () => {
    const ok = parseMessage({ jsonrpc: '2.0', id: 'a', result: { value: 1 } });
    expect(isResponse(ok)).toBe(true);
    expect(isRequest(ok)).toBe(false);

    const bad = parseMessage({ jsonrpc: '2.0', id: 'a', error: { code: -32000, message: 'boom' } });
    expect(isResponse(bad)).toBe(true);
    expect('error' in bad && bad.error.code).toBe(-32000);
  });

  it('非法结构抛 -32600', () => {
    const cases: unknown[] = [
      null,
      42,
      'string',
      [],
      { id: 1, method: 'x' }, // 缺 jsonrpc
      { jsonrpc: '1.0', id: 1, method: 'x' },
      { jsonrpc: '2.0', id: 1 }, // 缺 method
      { jsonrpc: '2.0', id: 1, method: '' },
      { jsonrpc: '2.0', id: {}, method: 'x' }, // id 非法
      { jsonrpc: '2.0', id: 1, method: 'x', error: { code: 'no', message: 'm' } }, // error 形状非法
      { jsonrpc: '2.0', id: 1, method: 'x', error: 'oops' },
    ];
    for (const item of cases) {
      expect(() => parseMessage(item)).toThrowError(
        expect.objectContaining({ name: 'RpcError', code: RPC_ERROR_CODES.invalidRequest }),
      );
    }
  });

  it('响应 id 允许 null（错误响应）', () => {
    const message = parseMessage({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } });
    expect('error' in message && message.error.code).toBe(-32700);
  });
});

describe('jsonrpc：工厂与转换', () => {
  it('success / failure / notification 形状', () => {
    expect(success(1, { ok: true })).toEqual({ jsonrpc: JSONRPC_VERSION, id: 1, result: { ok: true } });
    expect(failure(null, -32700, 'Parse error')).toEqual({
      jsonrpc: JSONRPC_VERSION,
      id: null,
      error: { code: -32700, message: 'Parse error' },
    });
    expect(failure(2, -32602, 'bad', { field: 'x' }).error.data).toEqual({ field: 'x' });
    expect(notification('notifications/message', { level: 'info' })).toEqual({
      jsonrpc: JSONRPC_VERSION,
      method: 'notifications/message',
      params: { level: 'info' },
    });
    expect('params' in notification('x')).toBe(false);
  });

  it('RpcError 便捷构造', () => {
    const invalid = RpcError.invalidParams('bad params', { errors: [] });
    expect(invalid.code).toBe(RPC_ERROR_CODES.invalidParams);
    expect(invalid.data).toEqual({ errors: [] });

    const missing = RpcError.methodNotFound('nope');
    expect(missing.code).toBe(RPC_ERROR_CODES.methodNotFound);
    expect(missing.message).toContain('nope');
  });

  it('toErrorResponse：RpcError 透传 code/message/data', () => {
    const response = toErrorResponse(5, new RpcError(-32005, 'Tool requires confirmation', { id: 'conf_1' }));
    expect(response.id).toBe(5);
    expect(response.error.code).toBe(-32005);
    expect(response.error.data).toEqual({ id: 'conf_1' });
  });

  it('toErrorResponse：未知异常 → -32603 且不泄漏细节', () => {
    const response = toErrorResponse('x', new Error('secret internal detail'));
    expect(response.error.code).toBe(RPC_ERROR_CODES.internalError);
    expect(response.error.message).toBe('Internal error');
    expect(JSON.stringify(response)).not.toContain('secret internal detail');
  });

  it('标准 + 扩展错误码齐全（§15）', () => {
    expect(RPC_ERROR_CODES).toMatchObject({
      parseError: -32700,
      invalidRequest: -32600,
      methodNotFound: -32601,
      invalidParams: -32602,
      internalError: -32603,
      serverError: -32000,
      rateLimited: -32001,
      permissionDenied: -32002,
      notFound: -32003,
      conflict: -32004,
      confirmationRequired: -32005,
      cancelled: -32006,
    });
  });
});
