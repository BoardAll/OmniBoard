/**
 * OpLog / parseOp / token 单元测试（M1 / T1.3）——纯离线，无网络。
 *
 * 覆盖：环形淘汰与水位不回退、去重判定、gap 检测（含上限）、裁差分（fetchAfter / fetchSince）、
 * 防御式 op 解析、生产环境认证收紧与匿名回落判定。
 */

import { describe, expect, it } from 'vitest';
import { MAX_MISSING_SEQS, OpLog, parseOp } from '../src/oplog.js';
import { resolveConnectionIdentity } from '../src/token.js';
import type { Op } from '../src/types.js';
import { signTestToken } from './helpers.js';

function op(actor: string, seq: number): Op {
  return { actor, seq, key: `k-${seq}`, value: seq };
}

describe('oplog: 环形日志与水位', () => {
  it('append 推进水位；stateVector / isDuplicate 按 actor 独立', () => {
    const log = new OpLog(10);
    expect(log.watermark('a')).toBe(0);
    log.append(op('a', 1));
    log.append(op('a', 2));
    expect(log.count).toBe(2);
    expect(log.watermark('a')).toBe(2);
    expect(log.stateVector()).toEqual({ a: 2 });
    expect(log.isDuplicate('a', 1)).toBe(true);
    expect(log.isDuplicate('a', 2)).toBe(true);
    expect(log.isDuplicate('a', 3)).toBe(false);
    expect(log.isDuplicate('b', 1)).toBe(false); // 不同 actor 水位独立
  });

  it('missingSeqsFor：接续 / 重复 → null；断档 → 缺失列表', () => {
    const log = new OpLog(10);
    log.append(op('a', 1));
    log.append(op('a', 2));
    expect(log.missingSeqsFor('a', 3)).toBeNull(); // 接续
    expect(log.missingSeqsFor('a', 2)).toBeNull(); // 重复（调用方先判 dup）
    expect(log.missingSeqsFor('a', 6)).toEqual([3, 4, 5]);
    expect(log.missingSeqsFor('b', 3)).toEqual([1, 2]); // 新 actor 从 1 起
  });

  it('missingSeqsFor 上限 100（防御巨型跳变）', () => {
    const log = new OpLog(10);
    const missing = log.missingSeqsFor('a', 10_000);
    expect(missing).not.toBeNull();
    expect(missing).toHaveLength(MAX_MISSING_SEQS);
    expect(missing?.[0]).toBe(1);
    expect(missing?.[MAX_MISSING_SEQS - 1]).toBe(MAX_MISSING_SEQS);
  });

  it('环形淘汰最旧；水位不回退（已淘汰 op 仍判 dup，幂等重放）', () => {
    const log = new OpLog(3);
    for (let seq = 1; seq <= 4; seq += 1) log.append(op('a', seq));
    expect(log.count).toBe(3);
    expect(log.toArray().map((o) => o.seq)).toEqual([2, 3, 4]);
    expect(log.watermark('a')).toBe(4);
    expect(log.isDuplicate('a', 1)).toBe(true);
    expect(log.fetchSince('a', 0).map((o) => o.seq)).toEqual([2, 3, 4]); // 仅保留区可回放
  });

  it('fetchAfter 按各 actor 水位裁差分；空水位 = 全量', () => {
    const log = new OpLog(10);
    log.append(op('a', 1));
    log.append(op('b', 1));
    log.append(op('a', 2));
    log.append(op('b', 2));
    expect(log.fetchAfter({ a: 1 })).toEqual([op('b', 1), op('a', 2), op('b', 2)]);
    expect(log.fetchAfter({ a: 2, b: 2 })).toEqual([]);
    expect(log.fetchAfter({})).toHaveLength(4);
  });

  it('容量非法 → 构造抛错', () => {
    expect(() => new OpLog(0)).toThrow();
    expect(() => new OpLog(1.5)).toThrow();
  });
});

describe('oplog: parseOp 防御式解析', () => {
  it('合法 op：trim actor/key；保留 value / timestamp / origin', () => {
    const parsed = parseOp({ actor: ' a ', seq: 2, key: ' x ', value: { v: 1 }, timestamp: 123, origin: 'o' });
    expect(parsed).toEqual({ actor: 'a', seq: 2, key: 'x', value: { v: 1 }, timestamp: 123, origin: 'o' });
    expect(parseOp({ actor: 'a', seq: 1, key: 'k', value: null })).toEqual({ actor: 'a', seq: 1, key: 'k', value: null });
  });

  it('非法输入 → null', () => {
    const invalidInputs: unknown[] = [
      null,
      'str',
      42,
      [],
      {},
      { actor: '', seq: 1, key: 'k', value: 1 },
      { actor: 'a', seq: 0, key: 'k', value: 1 },
      { actor: 'a', seq: -1, key: 'k', value: 1 },
      { actor: 'a', seq: 1.5, key: 'k', value: 1 },
      { actor: 'a', seq: '1', key: 'k', value: 1 },
      { actor: 'a', seq: 1, key: '', value: 1 },
      { actor: 'a', seq: 1, key: 'k', value: 1, timestamp: Number.NaN },
      { actor: 'a', seq: 1, key: 'k', value: 1, timestamp: 'now' },
      { actor: 'a', seq: 1, key: 'k', value: 1, origin: 7 },
    ];
    for (const input of invalidInputs) {
      expect(parseOp(input), `expected null for ${JSON.stringify(input)}`).toBeNull();
    }
  });
});

describe('token: resolveConnectionIdentity 判定', () => {
  it('production 缺密钥 → rejected（不静默匿名）；缺 token 同样收紧', () => {
    const noSecret = resolveConnectionIdentity(undefined, { NODE_ENV: 'production' });
    expect(noSecret.kind).toBe('rejected');
    const noToken = resolveConnectionIdentity(undefined, { NODE_ENV: 'production', WB_JWT_SECRET: 's' });
    expect(noToken.kind).toBe('rejected');
  });

  it('非生产无密钥 → 匿名回落（no_token / missing_secret）', () => {
    const noToken = resolveConnectionIdentity(undefined, { NODE_ENV: 'development' });
    expect(noToken).toMatchObject({ kind: 'anonymous', fallbackReason: 'no_token' });
    const withToken = resolveConnectionIdentity({ token: 'x' }, { NODE_ENV: 'development' });
    expect(withToken).toMatchObject({ kind: 'anonymous', fallbackReason: 'missing_secret' });
  });

  it('HS256 验签：sub → userId；role 白名单校验，非法 role 回落 Participant', () => {
    const env = { NODE_ENV: 'test', WB_JWT_SECRET: 'secret' };
    const ok = resolveConnectionIdentity({ token: signTestToken('u1', 'secret', { role: 'Viewer' }) }, env);
    expect(ok).toEqual({ kind: 'jwt', userId: 'u1', role: 'Viewer' });

    const badRole = resolveConnectionIdentity({ token: signTestToken('u2', 'secret') }, env);
    expect(badRole).toMatchObject({ kind: 'jwt', userId: 'u2', role: 'Participant' });
  });

  it('错签 / 过期 → rejected', () => {
    const env = { NODE_ENV: 'test', WB_JWT_SECRET: 'secret' };
    expect(resolveConnectionIdentity({ token: signTestToken('u1', 'other') }, env).kind).toBe('rejected');
    expect(resolveConnectionIdentity({ token: signTestToken('u1', 'secret', { expired: true }) }, env).kind).toBe(
      'rejected',
    );
  });
});
