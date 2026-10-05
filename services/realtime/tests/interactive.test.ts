/**
 * realtime M3 契约测试（T3.1 互动模式 / 契约 A–E；《互动白板实时协同设计文档》§5.10 / §5.14 / §6）。
 *
 * 覆盖：
 * - 角色工具矩阵（roleRank / effectiveCanWrite / clampSessionRole seam）；
 * - interactive 权限矩阵：非法角色 → {ok:false, reason:'forbidden'} + authz.denied；
 *   合法 → 行为正确（raiseHand / lowerHand、grantControl / revokeControl、startPresent / stopPresent、
 *   removeUser、follow / unfollow）；
 * - 写权模式（契约 A；2026-11 修订）：free 默认 ≥Write（含 Participant）可写、present 收窄为
 *   Host/CoHost/Presenter、grantedWrite 恒可写、Viewer/Guest 默认只读；
 * - 自提升防御（契约 D）：join 载荷注入 role 被忽略，无 C→S 渠道可改自身角色。
 *
 * 全部离线：随机端口自起自停；JWT 角色经 WB_JWT_SECRET 注入（test-secret）。
 */

import { describe, expect, it } from 'vitest';
import { clampSessionRole, effectiveCanWrite, roleRank } from '../src/types.js';
import type {
  BoardJoinAck,
  BoardOpsAck,
  BoardParticipantsPayload,
  BoardRole,
  InteractiveAck,
  InteractiveFollowOutPayload,
  InteractiveModeChangedPayload,
  InteractiveRoleChangedPayload,
  LockAcquireAck,
  RoomErrorPayload,
  RoomRemovedPayload,
} from '../src/types.js';
import {
  collectArgs,
  connectAndWait,
  createTestContext,
  emitAck,
  expectNoEvent,
  failureError,
  joinBoard,
  makeOp,
  memoryAuditOf,
  signTestToken,
  waitFor,
  waitForDisconnect,
  waitForEvent,
} from './helpers.js';

const JWT_ENV = { WB_JWT_SECRET: 'test-secret' };

describe('realtime M3: 角色工具矩阵（契约 A/D）', () => {
  it('roleRank 全序：Host > CoHost > Presenter > Participant > Viewer > Guest', () => {
    const descending: BoardRole[] = ['Host', 'CoHost', 'Presenter', 'Participant', 'Viewer', 'Guest'];
    for (let index = 1; index < descending.length; index += 1) {
      expect(roleRank(descending[index]!)).toBeLessThan(roleRank(descending[index - 1]!));
    }
  });

  it('effectiveCanWrite：free 默认 ≥Write 可写（2026-11 修订）；present 收窄 Host/CoHost/Presenter；授权恒可写', () => {
    // free：Host/CoHost/Presenter/Participant 默认可写（默认协作开箱可用），Viewer/Guest 只读。
    expect(effectiveCanWrite('Host', false, 'free')).toBe(true);
    expect(effectiveCanWrite('CoHost', false, 'free')).toBe(true);
    expect(effectiveCanWrite('Presenter', false, 'free')).toBe(true);
    expect(effectiveCanWrite('Participant', false, 'free')).toBe(true);
    expect(effectiveCanWrite('Viewer', false, 'free')).toBe(false);
    expect(effectiveCanWrite('Guest', false, 'free')).toBe(false);
    expect(effectiveCanWrite('Participant', true, 'free')).toBe(true);
    expect(effectiveCanWrite('Viewer', true, 'free')).toBe(true);
    expect(effectiveCanWrite('Guest', true, 'free')).toBe(true);

    // present：Host/CoHost/Presenter（演示中可写）与授权可写；Participant 等仍默认只读。
    expect(effectiveCanWrite('Host', false, 'present')).toBe(true);
    expect(effectiveCanWrite('CoHost', false, 'present')).toBe(true);
    expect(effectiveCanWrite('Presenter', false, 'present')).toBe(true);
    expect(effectiveCanWrite('Participant', false, 'present')).toBe(false);
    expect(effectiveCanWrite('Viewer', false, 'present')).toBe(false);
    expect(effectiveCanWrite('Guest', false, 'present')).toBe(false);
    expect(effectiveCanWrite('Participant', true, 'present')).toBe(true);
    expect(effectiveCanWrite('Viewer', true, 'present')).toBe(true);
  });

  it('clampSessionRole seam：当前恒放行服务端显式授权（待板级协作者表接入）', () => {
    expect(clampSessionRole('Viewer', 'Host')).toBe('Host');
    expect(clampSessionRole('Host', 'CoHost')).toBe('CoHost');
    expect(clampSessionRole('Participant', 'Participant')).toBe('Participant');
  });
});

describe('realtime M3: 互动事件族（契约 B/C）', () => {
  it('raiseHand / lowerHand：最低 Viewer；置位广播 updated（排除发送者）；不落审计', async () => {
    const ctx = await createTestContext(JWT_ENV);
    try {
      const guest = await connectAndWait(ctx, { token: signTestToken('guest-1', { role: 'Guest' }) });
      const viewer = await connectAndWait(ctx, { token: signTestToken('user-v', { role: 'Viewer' }) });
      const other = await connectAndWait(ctx, { token: signTestToken('user-o', { role: 'Participant' }) });
      await joinBoard(guest.client, 'board-h');
      await joinBoard(viewer.client, 'board-h');
      await joinBoard(other.client, 'board-h');

      // Guest 低于 Viewer → 举/放均拒绝 + authz.denied
      const denied = await emitAck<InteractiveAck>(guest.client, 'interactive:raiseHand', {});
      expect(denied).toEqual({ ok: false, reason: 'forbidden' });
      expect(await emitAck<InteractiveAck>(guest.client, 'interactive:lowerHand', {})).toEqual({
        ok: false,
        reason: 'forbidden',
      });
      await waitFor(() => memoryAuditOf(ctx.server).entries.some((e) => e.action === 'authz.denied' && e.userId === 'guest-1'));

      // Viewer 举手：other 收到 updated；发送者自己不收到（socket.to 排除）
      const updates = collectArgs<[BoardParticipantsPayload]>(other.client, 'board:participants');
      const senderWindow = expectNoEvent(viewer.client, 'board:participants', 120);
      const raiseAck = await emitAck<InteractiveAck>(viewer.client, 'interactive:raiseHand', {});
      expect(raiseAck).toEqual({ ok: true });
      await senderWindow;
      await waitFor(() => updates.calls.some((c) => c[0].updated?.some((p) => p.userId === 'user-v' && p.handRaised === true)));

      // lowerHand 清位
      const lowerAck = await emitAck<InteractiveAck>(viewer.client, 'interactive:lowerHand', {});
      expect(lowerAck).toEqual({ ok: true });
      await waitFor(() => updates.calls.some((c) => c[0].updated?.some((p) => p.userId === 'user-v' && p.handRaised === false)));
      updates.stop();

      // 低频用户行为不落审计
      const entries = memoryAuditOf(ctx.server).entries;
      expect(entries.some((e) => e.action.includes('raiseHand') || e.action.includes('lowerHand'))).toBe(false);
    } finally {
      await ctx.close();
    }
  });

  it('grantControl / revokeControl：Participant 发起拒绝（+authz.denied）；CoHost 授予/收回全流程 + 审计', async () => {
    const ctx = await createTestContext(JWT_ENV);
    try {
      const coach = await connectAndWait(ctx, { token: signTestToken('user-c', { role: 'CoHost' }) });
      const member = await connectAndWait(ctx, { token: signTestToken('user-m', { role: 'Participant' }) });
      await joinBoard(coach.client, 'board-g');
      await joinBoard(member.client, 'board-g');
      const entries = memoryAuditOf(ctx.server).entries;

      // Participant 发起 → 拒绝 + 审计（无法自我/他人提权）
      const denied = await emitAck<InteractiveAck>(member.client, 'interactive:grantControl', { userId: 'user-m' });
      expect(denied).toEqual({ ok: false, reason: 'forbidden' });
      await waitFor(() => entries.some((e) => e.action === 'authz.denied' && e.userId === 'user-m'));

      // CoHost 授予：ack + roleChanged 单播 + updated 广播 + 审计
      const roleChanged = waitForEvent<InteractiveRoleChangedPayload>(member.client, 'interactive:roleChanged');
      const updates = collectArgs<[BoardParticipantsPayload]>(member.client, 'board:participants');
      const grantAck = await emitAck<InteractiveAck>(coach.client, 'interactive:grantControl', { userId: 'user-m' });
      expect(grantAck).toEqual({ ok: true });
      expect(await roleChanged).toEqual({ userId: 'user-m', role: 'Participant', grantedWrite: true });
      await waitFor(() =>
        updates.calls.some((c) => c[0].updated?.some((p) => p.userId === 'user-m' && p.grantedWrite === true)),
      );
      updates.stop();
      await waitFor(() => entries.some((e) => e.action === 'interactive.grantControl' && e.target?.id === 'user-m'));

      // 目标形状防御：Host/CoHost 不可为授权目标；不在房 / 缺参分别拒绝
      expect(await emitAck<InteractiveAck>(coach.client, 'interactive:grantControl', { userId: 'user-c' })).toEqual({
        ok: false,
        reason: 'invalid-target',
      });
      expect(await emitAck<InteractiveAck>(coach.client, 'interactive:grantControl', { userId: 'user-zzz' })).toEqual({
        ok: false,
        reason: 'user-not-in-room',
      });
      expect(await emitAck<InteractiveAck>(coach.client, 'interactive:grantControl', {})).toEqual({
        ok: false,
        reason: 'invalid-argument',
      });

      // 收回：grantedWrite=false（角色不变；2026-11 修订：收权效果随模式——
      // free 下 ≥Write 角色默认仍可写，present 下非 Presenter 收权即只读）+ 审计
      const roleChanged2 = waitForEvent<InteractiveRoleChangedPayload>(member.client, 'interactive:roleChanged');
      const updatesAfterRevoke = collectArgs<[BoardParticipantsPayload]>(member.client, 'board:participants');
      const revokeAck = await emitAck<InteractiveAck>(coach.client, 'interactive:revokeControl', { userId: 'user-m' });
      expect(revokeAck).toEqual({ ok: true });
      expect(await roleChanged2).toEqual({ userId: 'user-m', role: 'Participant', grantedWrite: false });
      await waitFor(() =>
        updatesAfterRevoke.calls.some((c) =>
          c[0].updated?.some((p) => p.userId === 'user-m' && p.role === 'Participant' && p.grantedWrite === false),
        ),
      );
      updatesAfterRevoke.stop();
      await waitFor(() => entries.some((e) => e.action === 'interactive.revokeControl' && e.target?.id === 'user-m'));
    } finally {
      await ctx.close();
    }
  });

  it('startPresent / stopPresent：CoHost 起（presenterId=发起者）/ Presenter 可停；广播 + 快照 + 审计', async () => {
    const ctx = await createTestContext(JWT_ENV);
    try {
      const coach = await connectAndWait(ctx, { token: signTestToken('user-c', { role: 'CoHost' }) });
      const member = await connectAndWait(ctx, { token: signTestToken('user-m', { role: 'Participant' }) });
      const presenter = await connectAndWait(ctx, { token: signTestToken('user-pr', { role: 'Presenter' }) });
      await joinBoard(coach.client, 'board-pr');
      await joinBoard(member.client, 'board-pr');
      await joinBoard(presenter.client, 'board-pr');
      const entries = memoryAuditOf(ctx.server).entries;

      // Participant 发起 → 拒绝 + 审计
      expect(await emitAck<InteractiveAck>(member.client, 'interactive:startPresent', {})).toEqual({
        ok: false,
        reason: 'forbidden',
      });
      await waitFor(() => entries.some((e) => e.action === 'authz.denied' && e.userId === 'user-m'));

      // CoHost 开始：modeChanged 广播（排除发起者）+ 审计
      const changed = waitForEvent<InteractiveModeChangedPayload>(member.client, 'interactive:modeChanged');
      expect(await emitAck<InteractiveAck>(coach.client, 'interactive:startPresent', {})).toEqual({ ok: true });
      expect(await changed).toEqual({ mode: 'present', by: 'user-c', presenterId: 'user-c' });
      await waitFor(() => entries.some((e) => e.action === 'interactive.startPresent' && e.target?.id === 'board-pr'));

      // present 态下 Participant 停止（低于 Presenter）→ 拒绝 + 审计
      expect(await emitAck<InteractiveAck>(member.client, 'interactive:stopPresent', {})).toEqual({
        ok: false,
        reason: 'forbidden',
      });
      await waitFor(() => entries.some((e) => e.action === 'authz.denied' && e.detail?.includes('interactive:stopPresent')));

      // present 态新加入者：joined.mode/presenterId 快照（默认跟随）
      const late = await connectAndWait(ctx, { token: signTestToken('user-late', { role: 'Participant' }) });
      const lateAck = await joinBoard(late.client, 'board-pr');
      if (!lateAck.ok) throw new Error(`join failed: ${failureError(lateAck).code}`);
      expect(lateAck.mode).toBe('present');
      expect(lateAck.presenterId).toBe('user-c');

      // Presenter（非发起者）可停：modeChanged free + 审计
      const changed2 = waitForEvent<InteractiveModeChangedPayload>(member.client, 'interactive:modeChanged');
      expect(await emitAck<InteractiveAck>(presenter.client, 'interactive:stopPresent', {})).toEqual({ ok: true });
      expect(await changed2).toEqual({ mode: 'free', by: 'user-pr' });
      await waitFor(() => entries.some((e) => e.action === 'interactive.stopPresent'));

      // 非 present 再停 → not-presenting（不新增审计）
      const stopCount = entries.filter((e) => e.action === 'interactive.stopPresent').length;
      expect(await emitAck<InteractiveAck>(coach.client, 'interactive:stopPresent', {})).toEqual({
        ok: false,
        reason: 'not-presenting',
      });
      expect(entries.filter((e) => e.action === 'interactive.stopPresent').length).toBe(stopCount);
    } finally {
      await ctx.close();
    }
  });

  it('写权矩阵（契约 A；2026-11 修订）：free 默认 ≥Write 可写，present 收窄仅 Presenter，授权恢复', async () => {
    const ctx = await createTestContext(JWT_ENV);
    try {
      const host = await connectAndWait(ctx, { token: signTestToken('user-h', { role: 'Host' }) });
      const part = await connectAndWait(ctx, { token: signTestToken('user-p', { role: 'Participant' }) });
      const presenter = await connectAndWait(ctx, { token: signTestToken('user-pr', { role: 'Presenter' }) });
      const viewer = await connectAndWait(ctx, { token: signTestToken('user-v', { role: 'Viewer' }) });
      for (const member of [host, part, presenter, viewer]) await joinBoard(member.client, 'board-narrow');
      const entries = memoryAuditOf(ctx.server).entries;

      // free：Participant 默认可写（2026-11 修订——默认协作开箱可用）
      expect(await emitAck<BoardOpsAck>(part.client, 'board:ops', [makeOp('p', 1)])).toEqual({ ok: true });

      // 进入 present
      expect(await emitAck<InteractiveAck>(host.client, 'interactive:startPresent', {})).toEqual({ ok: true });

      // present：Participant 被拒（Forbidden ack + room:error + 审计；被拒 op 不入账，seq 不推进）
      const roomError = waitForEvent<RoomErrorPayload>(part.client, 'room:error');
      const rejected = await emitAck<BoardOpsAck>(part.client, 'board:ops', [makeOp('p', 2)]);
      expect(failureError(rejected).code).toBe('Forbidden');
      expect((await roomError).code).toBe('Forbidden');
      await waitFor(
        () =>
          entries.filter(
            (e) => e.action === 'authz.denied' && e.userId === 'user-p' && e.detail?.includes('cannot submit ops'),
          ).length >= 1,
      );

      // Participant lock:acquire → present 收窄下 forbidden + lock.denied
      expect(await emitAck<LockAcquireAck>(part.client, 'lock:acquire', { elementId: 'e1' })).toEqual({
        ok: false,
        reason: 'forbidden',
      });
      await waitFor(() => entries.some((e) => e.action === 'lock.denied' && e.userId === 'user-p'));

      // Presenter 在 present 下可写（演示中可写）
      expect(await emitAck<BoardOpsAck>(presenter.client, 'board:ops', [makeOp('pr', 1)])).toEqual({ ok: true });

      // Viewer 获 grantedWrite 后：ops + lock 均可
      expect(await emitAck<InteractiveAck>(host.client, 'interactive:grantControl', { userId: 'user-v' })).toEqual({ ok: true });
      expect(await emitAck<BoardOpsAck>(viewer.client, 'board:ops', [makeOp('v', 1)])).toEqual({ ok: true });
      expect(await emitAck<LockAcquireAck>(viewer.client, 'lock:acquire', { elementId: 'e2' })).toMatchObject({
        ok: true,
        granted: true,
      });

      // stopPresent 恢复 free：Participant 恢复默认可写（被拒的 seq 2 未入账，此处续用）
      expect(await emitAck<InteractiveAck>(host.client, 'interactive:stopPresent', {})).toEqual({ ok: true });
      expect(await emitAck<BoardOpsAck>(part.client, 'board:ops', [makeOp('p', 2)])).toEqual({ ok: true });
    } finally {
      await ctx.close();
    }
  });

  it('removeUser：级别严格大于目标；单播 room:removed + 断开 + left 广播 + 审计；越级/同级拒绝', async () => {
    const ctx = await createTestContext(JWT_ENV);
    try {
      const host = await connectAndWait(ctx, { token: signTestToken('user-h', { role: 'Host' }) });
      const coach = await connectAndWait(ctx, { token: signTestToken('user-c', { role: 'CoHost' }) });
      const member = await connectAndWait(ctx, { token: signTestToken('user-m', { role: 'Participant' }) });
      await joinBoard(host.client, 'board-k');
      await joinBoard(coach.client, 'board-k');
      await joinBoard(member.client, 'board-k');
      const entries = memoryAuditOf(ctx.server).entries;

      // CoHost 踢 Host（越级）→ forbidden；Host 踢自己（不能自踢）→ forbidden
      expect(await emitAck<InteractiveAck>(coach.client, 'interactive:removeUser', { userId: 'user-h' })).toEqual({
        ok: false,
        reason: 'forbidden',
      });
      expect(await emitAck<InteractiveAck>(host.client, 'interactive:removeUser', { userId: 'user-h' })).toEqual({
        ok: false,
        reason: 'forbidden',
      });
      await waitFor(
        () => entries.filter((e) => e.action === 'authz.denied' && e.detail?.includes('interactive:removeUser')).length >= 2,
      );

      // Host 踢 Participant：room:removed 单播 → 断开 → left 广播 → 审计
      const removed = waitForEvent<RoomRemovedPayload>(member.client, 'room:removed');
      const disconnected = waitForDisconnect(member.client);
      const left = waitForEvent<BoardParticipantsPayload>(coach.client, 'board:participants');
      expect(await emitAck<InteractiveAck>(host.client, 'interactive:removeUser', { userId: 'user-m' })).toEqual({ ok: true });
      expect(await removed).toMatchObject({ code: 'Removed', reason: 'removed' });
      expect(await disconnected).toBe('io server disconnect');
      expect((await left).left?.map((p) => p.userId)).toEqual(['user-m']);
      await waitFor(() => entries.some((e) => e.action === 'interactive.removeUser' && e.target?.id === 'user-m'));
    } finally {
      await ctx.close();
    }
  });

  it('follow / unfollow：无状态透传单播 target；目标不在房 / 低于 Viewer 静默；旁观者与发送者不收到', async () => {
    const ctx = await createTestContext(JWT_ENV);
    try {
      const a = await connectAndWait(ctx, { token: signTestToken('user-a', { role: 'Viewer' }) });
      const b = await connectAndWait(ctx, { token: signTestToken('user-b', { role: 'Presenter' }) });
      const c = await connectAndWait(ctx, { token: signTestToken('user-c', { role: 'Participant' }) });
      for (const member of [a, b, c]) await joinBoard(member.client, 'board-f');

      // a(Viewer) → b：b 收到 followerUserId；c 与 a 不收到
      const received = waitForEvent<InteractiveFollowOutPayload>(b.client, 'interactive:follow');
      const bystander = expectNoEvent(c.client, 'interactive:follow', 120);
      const sender = expectNoEvent(a.client, 'interactive:follow', 120);
      a.client.emit('interactive:follow', { targetUserId: 'user-b' });
      expect(await received).toEqual({ followerUserId: 'user-a' });
      await bystander;
      await sender;

      // unfollow 同样透传
      const received2 = waitForEvent<InteractiveFollowOutPayload>(b.client, 'interactive:unfollow');
      a.client.emit('interactive:unfollow', { targetUserId: 'user-b' });
      expect(await received2).toEqual({ followerUserId: 'user-a' });

      // 目标不在房 → 静默忽略
      a.client.emit('interactive:follow', { targetUserId: 'user-zzz' });
      await expectNoEvent(b.client, 'interactive:follow', 100);

      // Guest 低于 Viewer → 静默不转发
      const guest = await connectAndWait(ctx, { token: signTestToken('user-g', { role: 'Guest' }) });
      await joinBoard(guest.client, 'board-f');
      guest.client.emit('interactive:follow', { targetUserId: 'user-b' });
      await expectNoEvent(b.client, 'interactive:follow', 100);

      // 低频用户行为不落审计
      const entries = memoryAuditOf(ctx.server).entries;
      expect(entries.some((e) => e.action.includes('follow'))).toBe(false);
    } finally {
      await ctx.close();
    }
  });

  it('自提升防御（契约 D）：join 注入 role/grantedWrite 被忽略；无 C→S 渠道可改自身角色', async () => {
    const ctx = await createTestContext(JWT_ENV);
    try {
      // 用 Viewer（只读声明，不参与房主自举）验证注入被忽略后的角色基线。
      const participant = await connectAndWait(ctx, { token: signTestToken('user-p', { role: 'Viewer' }) });

      // join 载荷注入多余字段（role / grantedWrite）→ 一律忽略，会话角色 = token role
      const ack = await emitAck<BoardJoinAck>(participant.client, 'board:join', {
        boardId: 'board-d',
        role: 'Host',
        grantedWrite: true,
      });
      if (!ack.ok) throw new Error(`join failed: ${failureError(ack).code}`);
      expect(ack.role).toBe('Viewer');
      expect(ack.participants.map((p) => p.role)).toEqual(['Viewer']);

      // 同板重入亦不升级（无在线 Host 也不自举：Viewer 为只读声明）
      const again = await emitAck<BoardJoinAck>(participant.client, 'board:join', { boardId: 'board-d', role: 'Host' });
      if (!again.ok) throw new Error('rejoin failed');
      expect(again.role).toBe('Viewer');

      // 无法自我提权：grantControl 需 ≥CoHost
      expect(await emitAck<InteractiveAck>(participant.client, 'interactive:grantControl', { userId: 'user-p' })).toEqual({
        ok: false,
        reason: 'forbidden',
      });
      // 也无法借 removeUser 改变他人角色（仅断开）；越级直接被拒
      expect(await emitAck<InteractiveAck>(participant.client, 'interactive:removeUser', { userId: 'user-p' })).toEqual({
        ok: false,
        reason: 'forbidden',
      });
    } finally {
      await ctx.close();
    }
  });
});
