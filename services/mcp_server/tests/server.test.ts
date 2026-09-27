/**
 * 主入口：CLI/env 参数解析与启动装配。
 * - 解析部分为纯函数测试；
 * - 启动部分仅测 HTTP（随机端口 + 显式关闭），不触碰 stdio（避免挂起进程 stdin）。
 */

import { describe, expect, it } from 'vitest';
import {
  DEFAULT_HOST,
  DEFAULT_PORT,
  main,
  parseServerOptions,
  renderHelp,
  ServerConfigError,
  startServer,
  type ParsedInvocation,
  type ServerOptions,
} from '../src/server.js';
import { KNOWN_SCOPES } from '../src/auth/index.js';
import { httpCall } from './http-utils.js';
import { initializeRequest } from './fixtures.js';

function runOptions(parsed: ParsedInvocation): ServerOptions {
  expect(parsed.kind).toBe('run');
  if (parsed.kind !== 'run') throw new Error('expected run invocation');
  return parsed.options;
}

describe('server: 参数解析', () => {
  it('默认值（无 env / CLI）', () => {
    expect(runOptions(parseServerOptions([], {}))).toEqual({
      transport: 'stdio',
      host: DEFAULT_HOST,
      port: DEFAULT_PORT,
      apiBaseUrl: null,
      apiKey: null,
      mcpApiKey: null,
      boards: [],
      logLevel: 'info',
      allowAnonymous: false,
    });
  });

  it('环境变量读取', () => {
    const options = runOptions(
      parseServerOptions([], {
        WB_MCP_TRANSPORT: 'http',
        WB_MCP_PORT: '9999',
        WB_MCP_HOST: '0.0.0.0',
        WB_API_BASE_URL: 'http://api.local',
        WB_API_KEY: 'svc-key',
        WB_MCP_API_KEY: 'mcp-key',
        WB_BOARD_ID: ' b1, b2 ',
        WB_MCP_LOG_LEVEL: 'debug',
        WB_MCP_ALLOW_ANONYMOUS: '1',
      }),
    );
    expect(options).toMatchObject({
      transport: 'http',
      port: 9999,
      host: '0.0.0.0',
      apiBaseUrl: 'http://api.local',
      apiKey: 'svc-key',
      mcpApiKey: 'mcp-key',
      boards: ['b1', 'b2'],
      logLevel: 'debug',
      allowAnonymous: true,
    });
  });

  it('CLI 覆盖 env；支持 --flag value / --flag=value / 纯开关；--board 追加合并', () => {
    const merged = runOptions(
      parseServerOptions(['--transport', 'sse', '--port', '0', '--board', 'x'], {
        WB_MCP_PORT: '1234',
        WB_BOARD_ID: 'env-board',
      }),
    );
    expect(merged).toMatchObject({ transport: 'sse', port: 0, boards: ['env-board', 'x'] });

    const inline = runOptions(
      parseServerOptions(
        ['--transport=http', '--port=8789', '--api-base-url=http://api.test', '--allow-anonymous'],
        {},
      ),
    );
    expect(inline).toMatchObject({
      transport: 'http',
      port: 8789,
      apiBaseUrl: 'http://api.test',
      allowAnonymous: true,
    });

    expect(runOptions(parseServerOptions(['--transport', 'streamable-http'], {})).transport).toBe('http');
    expect(runOptions(parseServerOptions(['--transport', 'streamable_http'], {})).transport).toBe('http');
  });

  it('--help / --version 返回标记而非启动', () => {
    expect(parseServerOptions(['--help'], {})).toEqual({ kind: 'help' });
    expect(parseServerOptions(['-h'], {})).toEqual({ kind: 'help' });
    expect(parseServerOptions(['--version'], {})).toEqual({ kind: 'version' });
    expect(parseServerOptions(['-v'], {})).toEqual({ kind: 'version' });
  });

  it('非法配置 → ServerConfigError', () => {
    expect(() => parseServerOptions(['--port', 'abc'], {})).toThrowError(ServerConfigError);
    expect(() => parseServerOptions(['--port', '70000'], {})).toThrowError(ServerConfigError);
    expect(() => parseServerOptions(['--port', '-1'], {})).toThrowError(ServerConfigError);
    expect(() => parseServerOptions([], { WB_MCP_PORT: '1.5' })).toThrowError(ServerConfigError);
    expect(() => parseServerOptions(['--transport', 'grpc'], {})).toThrowError(ServerConfigError);
    expect(() => parseServerOptions([], { WB_MCP_LOG_LEVEL: 'loud' })).toThrowError(ServerConfigError);
    expect(() => parseServerOptions(['--bogus'], {})).toThrowError(ServerConfigError);
    expect(() => parseServerOptions(['--transport'], {})).toThrowError(ServerConfigError);
    expect(() => parseServerOptions(['--port=abc'], {})).toThrowError(ServerConfigError);
  });

  it('renderHelp 包含用法与关键环境变量', () => {
    const help = renderHelp();
    expect(help).toContain('whiteboard-mcp');
    expect(help).toContain('WB_MCP_TRANSPORT');
    expect(help).toContain('WB_API_KEYS');
    expect(help).toContain('--allow-anonymous');
  });
});

describe('server: main 退出码', () => {
  it('--version → 0；非法参数 → 1', async () => {
    await expect(main(['-v'], {})).resolves.toBe(0);
    await expect(main(['--bogus-flag'], {})).resolves.toBe(1);
  });
});

describe('server: startServer 装配', () => {
  const baseOptions: ServerOptions = {
    transport: 'http',
    host: '127.0.0.1',
    port: 0,
    apiBaseUrl: null,
    apiKey: null,
    mcpApiKey: null,
    boards: [],
    logLevel: 'error',
    allowAnonymous: false,
  };

  it('http + allowAnonymous + 随机端口：healthz 可达，close 幂等', async () => {
    const started = await startServer({ ...baseOptions, allowAnonymous: true }, {});
    try {
      expect(started.transport).toBe('http');
      const port = started.port ?? 0;
      expect(port).toBeGreaterThan(0);

      const health = await httpCall(port, 'GET', '/healthz');
      expect(health.status).toBe(200);
      expect(JSON.parse(health.text)).toMatchObject({ ok: true, data: { status: 'ok' } });
    } finally {
      await started.close();
      await started.close(); // 幂等：重复关闭不抛错
    }
  });

  it('http 未配置凭据且未 allowAnonymous → 拒绝启动', async () => {
    await expect(startServer({ ...baseOptions }, {})).rejects.toThrowError(ServerConfigError);
    await expect(startServer({ ...baseOptions }, {})).rejects.toThrowError(/credentials/i);
  });

  it('http + WB_API_KEYS：无凭据 401；凭据请求 initialize 成功并建会话', async () => {
    const env = {
      WB_API_KEYS: JSON.stringify({
        'k-transport': { userId: 'u-1', scopes: [...KNOWN_SCOPES] },
      }),
    };
    const started = await startServer({ ...baseOptions }, env);
    try {
      const port = started.port ?? 0;
      expect(port).toBeGreaterThan(0);

      const denied = await httpCall(port, 'POST', '/mcp', { body: JSON.stringify(initializeRequest(1)) });
      expect(denied.status).toBe(401);

      const ok = await httpCall(port, 'POST', '/mcp', {
        headers: { 'x-api-key': 'k-transport' },
        body: JSON.stringify(initializeRequest(1)),
      });
      expect(ok.status).toBe(200);
      expect(typeof ok.headers['mcp-session-id']).toBe('string');
      const body = JSON.parse(ok.text) as { result?: { protocolVersion?: string } };
      expect(body.result?.protocolVersion).toBe('2025-06-18');
    } finally {
      await started.close();
    }
  });

  it('WB_API_KEYS 非法 JSON → 拒绝启动', async () => {
    await expect(
      startServer({ ...baseOptions, allowAnonymous: true }, { WB_API_KEYS: '{broken' }),
    ).rejects.toThrowError(ServerConfigError);
  });
});
