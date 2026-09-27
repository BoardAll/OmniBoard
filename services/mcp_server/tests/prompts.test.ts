/** 提示模板：prompts/list、prompts/get 与参数校验。 */

import { describe, expect, it } from 'vitest';
import { RPC_ERROR_CODES } from '../src/protocol/jsonrpc.js';
import { PROMPT_DEFINITIONS, PromptRegistry } from '../src/prompts/registry.js';
import { asFailure, asSuccess, createFixture } from './helpers.js';

describe('prompts/list', () => {
  it('返回 10 个内置模板（name/description/arguments）', async () => {
    const fixture = createFixture();
    const result = asSuccess(await fixture.request('prompts/list')).result as {
      prompts: Array<{ name: string; description: string; arguments: Array<Record<string, unknown>> }>;
      nextCursor?: string;
    };
    expect(result.prompts).toHaveLength(10);
    expect(result.nextCursor).toBeUndefined();
    expect(PROMPT_DEFINITIONS).toHaveLength(10);

    const names = result.prompts.map((prompt) => prompt.name);
    expect(names).toEqual(
      expect.arrayContaining([
        'brainstorm',
        'flowchart',
        'mindmap',
        'summarize',
        'cluster',
        'vote',
        'userJourney',
        'swot',
        'retrospective',
        'kanban',
      ]),
    );
    for (const prompt of result.prompts) {
      expect(typeof prompt.description).toBe('string');
      expect(Array.isArray(prompt.arguments)).toBe(true);
    }
  });
});

describe('prompts/get', () => {
  it('brainstorm：渲染 messages（role=user + text）', async () => {
    const fixture = createFixture();
    const result = asSuccess(
      await fixture.request('prompts/get', { name: 'brainstorm', arguments: { topic: '新品发布', count: '6' } }),
    ).result as { description: string; messages: Array<{ role: string; content: { type: string; text: string } }> };
    expect(result.description.length).toBeGreaterThan(0);
    expect(result.messages).toHaveLength(1);
    expect(result.messages[0]?.role).toBe('user');
    expect(result.messages[0]?.content.type).toBe('text');
    expect(result.messages[0]?.content.text).toContain('新品发布');
    expect(result.messages[0]?.content.text).toContain('6');
  });

  it('无参数模板（summarize）可直接获取', () => {
    const registry = new PromptRegistry();
    const result = registry.get('summarize', {});
    expect(result.messages[0]?.content.text).toContain('总结');
  });

  it('未知模板 → -32602', async () => {
    const fixture = createFixture();
    const failure = asFailure(await fixture.request('prompts/get', { name: 'no_such_prompt' }));
    expect(failure.error.code).toBe(RPC_ERROR_CODES.invalidParams);
  });

  it('缺少必填参数 → -32602（data 标注缺失参数）', async () => {
    const fixture = createFixture();
    const failure = asFailure(await fixture.request('prompts/get', { name: 'flowchart', arguments: {} }));
    expect(failure.error.code).toBe(RPC_ERROR_CODES.invalidParams);
    expect(failure.error.data).toMatchObject({ name: 'flowchart', argument: 'process' });
  });

  it('参数值非字符串 → -32602', async () => {
    const fixture = createFixture();
    const failure = asFailure(
      await fixture.request('prompts/get', { name: 'brainstorm', arguments: { topic: 42 } }),
    );
    expect(failure.error.code).toBe(RPC_ERROR_CODES.invalidParams);
    expect(failure.error.data).toMatchObject({ argument: 'topic' });
  });

  it('arguments 非对象 → -32602', async () => {
    const fixture = createFixture();
    const failure = asFailure(await fixture.request('prompts/get', { name: 'brainstorm', arguments: 'x' }));
    expect(failure.error.code).toBe(RPC_ERROR_CODES.invalidParams);
  });
});
