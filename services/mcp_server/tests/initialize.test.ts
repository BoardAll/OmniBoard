/** 初始化握手与版本协商（protocol/initialize.ts + dispatcher 集成）。 */

import { describe, expect, it } from 'vitest';
import {
  createSession,
  handleInitialize,
  LATEST_PROTOCOL_VERSION,
  SERVER_CAPABILITIES,
  SERVER_INFO,
  SUPPORTED_PROTOCOL_VERSIONS,
} from '../src/protocol/initialize.js';
import { asFailure, asSuccess, createFixture } from './helpers.js';

describe('initialize：握手与版本协商', () => {
  it('缺省 protocolVersion → 使用最新版本并记录 clientInfo', () => {
    const { result, session } = handleInitialize({
      clientInfo: { name: 'vitest-client', version: '1.2.3' },
    });
    expect(result.protocolVersion).toBe(LATEST_PROTOCOL_VERSION);
    expect(result.serverInfo).toEqual(SERVER_INFO);
    expect(result.capabilities).toEqual(SERVER_CAPABILITIES);
    expect(typeof result.instructions).toBe('string');
    expect(session.clientInfo).toEqual({ name: 'vitest-client', version: '1.2.3' });
  });

  it('客户端请求受支持版本 → 原样回显（含 2024-11-05）', () => {
    for (const version of SUPPORTED_PROTOCOL_VERSIONS) {
      const { result } = handleInitialize({ protocolVersion: version });
      expect(result.protocolVersion).toBe(version);
    }
  });

  it('不支持的版本 → -32602 且 data.supported 列出服务端版本', () => {
    try {
      handleInitialize({ protocolVersion: '2099-01-01' });
      throw new Error('should have thrown');
    } catch (error) {
      expect(error).toMatchObject({
        name: 'RpcError',
        code: -32602,
      });
      expect((error as { data?: { supported?: string[] } }).data?.supported).toEqual([
        ...SUPPORTED_PROTOCOL_VERSIONS,
      ]);
    }
  });

  it('protocolVersion 非字符串 → -32602', () => {
    expect(() => handleInitialize({ protocolVersion: 42 })).toThrowError(
      expect.objectContaining({ code: -32602 }),
    );
  });

  it('clientInfo 非法形态 → null（宽松解析）', () => {
    const { session } = handleInitialize({ clientInfo: 'not-an-object' });
    expect(session.clientInfo).toBeNull();
  });

  it('createSession 初始状态：未完成 initialized 通知', () => {
    const session = createSession();
    expect(session.initialized).toBe(false);
    expect(session.protocolVersion).toBe(LATEST_PROTOCOL_VERSION);
    expect(typeof session.createdAt).toBe('string');
  });
});

describe('initialize：dispatcher 集成', () => {
  it('initialize 请求 → 成功响应；notifications/initialized 完成握手（无响应）', async () => {
    const fixture = createFixture();
    const response = asSuccess(
      await fixture.request('initialize', {
        protocolVersion: '2025-06-18',
        capabilities: {},
        clientInfo: { name: 'vitest', version: '0.1.0' },
      }),
    );
    expect(response.result).toMatchObject({ protocolVersion: '2025-06-18' });

    const session = fixture.sessions.get(fixture.ctx.sessionId);
    expect(session?.meta.clientInfo?.name).toBe('vitest');
    expect(session?.meta.initialized).toBe(false);

    const notificationResponse = await fixture.notify('notifications/initialized');
    expect(notificationResponse).toBeNull();
    expect(fixture.sessions.get(fixture.ctx.sessionId)?.meta.initialized).toBe(true);
  });

  it('不支持版本 → -32602（dispatcher 层）', async () => {
    const fixture = createFixture();
    const failure = asFailure(await fixture.request('initialize', { protocolVersion: '1999-01-01' }));
    expect(failure.error.code).toBe(-32602);
    expect((failure.error.data as { supported: string[] }).supported).toContain('2025-06-18');
  });

  it('initialize params 非对象 → -32602', async () => {
    const fixture = createFixture();
    const failure = asFailure(await fixture.request('initialize', 'not-an-object'));
    expect(failure.error.code).toBe(-32602);
  });
});
