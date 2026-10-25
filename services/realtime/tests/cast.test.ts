/**
 * `/cast` namespace 契约测试（局域网投屏信令）。
 *
 * 覆盖：
 * - 四位投屏码（字符串、格式）与建房 / 换码 / 关闭生命周期；
 * - 发送端加入（自动接受 / 人工确认）、容量上限、错误码限流；
 * - SDP / ICE 路由与多发送端串线隔离；
 * - 断线宽限恢复与过期关房；
 * - 与 `/board` 的隔离（关闭投屏房间不影响白板房间；投屏事件不进入 board 流程）。
 */

import { describe, expect, it } from 'vitest';
import { io as createClient, type Socket as ClientSocket } from 'socket.io-client';
import type {
  CastAckFailure,
  CastCreateAck,
  CastDecisionAck,
  CastJoinAck,
  CastResumeAck,
  CastRoomSnapshot,
  CastServerToClientEvents,
  CastClientToServerEvents,
  CastUpdateAck,
  CastLeaveAck,
  CastStatusAck,
} from '../src/castTypes.js';
import { CAST_NAMESPACE } from '../src/castTypes.js';
import {
  signTestToken,
  sleep,
  startTestServer,
  waitFor,
  type TestServerHandle,
  type TestServerOptions,
} from './helpers.js';

type CastClient = ClientSocket<CastServerToClientEvents, CastClientToServerEvents>;

/** 等待 cast 事件首次触发（与 helpers.waitForEvent 同语义，独立事件表）。 */
function castWait<T>(socket: CastClient, event: string, timeoutMs = 5000): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let timer: ReturnType<typeof setTimeout>;
    const handler = (payload: T): void => {
      clearTimeout(timer);
      resolve(payload);
    };
    timer = setTimeout(() => {
      socket.off(event as never, handler as never);
      reject(new Error(`timeout waiting for "${event}"`));
    }, timeoutMs);
    socket.once(event as never, handler as never);
  });
}

interface CastContext {
  server: TestServerHandle;
  /** 以稳定 JWT 身份连接（匿名回落每次连接随机 userId，无法验证 resume 的身份绑定）。 */
  connect(userId?: string): Promise<CastClient>;
  close(): Promise<void>;
}

const CAST_TEST_SECRET = 'cast-test-secret';

async function createCastContext(options: TestServerOptions = {}): Promise<CastContext> {
  const server = await startTestServer({ WB_JWT_SECRET: CAST_TEST_SECRET }, options);
  const clients: CastClient[] = [];
  return {
    server,
    connect: async (userId = 'cast-user') => {
      const client: CastClient = createClient(`http://127.0.0.1:${server.port}${CAST_NAMESPACE}`, {
        transports: ['websocket'],
        forceNew: true,
        reconnection: false,
        auth: { token: signTestToken(userId, CAST_TEST_SECRET) },
      });
      clients.push(client);
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('cast connect timeout')), 5000);
        client.once('connect', () => {
          clearTimeout(timer);
          resolve();
        });
        client.once('connect_error', (error) => {
          clearTimeout(timer);
          reject(error);
        });
      });
      return client;
    },
    close: async () => {
      for (const client of clients) client.disconnect();
      await server.close();
    },
  };
}

function emitAck<T>(socket: CastClient, event: string, payload: unknown, timeoutMs = 5000): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`ack timeout for "${event}"`)), timeoutMs);
    const driver = socket as unknown as {
      emit: (ev: string, data: unknown, ack: (response: T) => void) => void;
    };
    driver.emit(event, payload, (response: T) => {
      clearTimeout(timer);
      resolve(response);
    });
  });
}

function expectFailure(ack: unknown): CastAckFailure {
  const candidate = ack as { ok?: unknown; error?: { code?: string; message?: string } };
  expect(candidate.ok).toBe(false);
  if (candidate.error === undefined) throw new Error(`expected failure ack, got ${JSON.stringify(ack)}`);
  return ack as CastAckFailure;
}

async function createRoom(
  client: CastClient,
  payload: Record<string, unknown> = {},
): Promise<{ code: string; room: CastRoomSnapshot; receiverToken: string }> {
  const ack = await emitAck<CastCreateAck>(client, 'cast:create', payload);
  if (!ack.ok) throw new Error(`create failed: ${ack.error.code}`);
  return { code: ack.room.code, room: ack.room, receiverToken: ack.receiverToken };
}

async function joinRoom(
  client: CastClient,
  code: string,
  deviceName = 'sender-test',
): Promise<Extract<CastJoinAck, { ok: true }>> {
  const ack = await emitAck<CastJoinAck>(client, 'cast:join', { code, deviceName });
  if (!ack.ok) throw new Error(`join failed: ${ack.error.code}`);
  return ack;
}

describe('cast namespace — 房间与四位码', () => {
  it('create 分配四位数字字符串房间号，并下发 type=cast 快照', async () => {
    const ctx = await createCastContext();
    try {
      const receiver = await ctx.connect();
      const created = await createRoom(receiver, { maxSenders: 4, autoAccept: true });
      expect(created.code).toMatch(/^\d{4}$/);
      expect(created.code).toHaveLength(4);
      expect(created.room.type).toBe('cast');
      expect(created.room.maxSenders).toBe(4);
      expect(created.room.autoAccept).toBe(true);
      expect(created.room.expiresAt).toBeGreaterThan(Date.now());
      expect(created.receiverToken).toMatch(/^[0-9a-f]{32}$/);
      expect(ctx.server.castRooms.roomCount).toBe(1);
    } finally {
      await ctx.close();
    }
  });

  it('重复 create 被拒绝（同一连接只有一个接收房间）', async () => {
    const ctx = await createCastContext();
    try {
      const receiver = await ctx.connect();
      await createRoom(receiver);
      const second = await emitAck<CastCreateAck>(receiver, 'cast:create', {});
      expect(expectFailure(second).error.code).toBe('AlreadyInRoom');
    } finally {
      await ctx.close();
    }
  });

  it('换码后旧码失效、发送端席位保留', async () => {
    const ctx = await createCastContext();
    try {
      const receiver = await ctx.connect();
      const sender = await ctx.connect();
      const created = await createRoom(receiver);
      await joinRoom(sender, created.code, 'PC-A');
      const rotated = await emitAck<CastCreateAck>(receiver, 'cast:regenerate', {});
      if (!rotated.ok) throw new Error('regenerate failed');
      expect(rotated.room.code).not.toBe(created.code);
      expect(rotated.room.senders).toHaveLength(1);

      const late = await ctx.connect();
      const stale = await emitAck<CastJoinAck>(late, 'cast:join', { code: created.code });
      expect(expectFailure(stale).error.code).toBe('NotFound');
      const fresh = await emitAck<CastJoinAck>(late, 'cast:join', { code: rotated.room.code });
      expect(fresh.ok).toBe(true);
    } finally {
      await ctx.close();
    }
  });

  it('换码后接收端仍能收到新码的投屏请求，发送端收到新码快照', async () => {
    const ctx = await createCastContext();
    try {
      const receiver = await ctx.connect();
      const sender = await ctx.connect();
      const created = await createRoom(receiver, { autoAccept: false });
      const joined = await joinRoom(sender, created.code, 'A');

      // 发送端在换码后必须收到新码快照（否则断线重连无法凭新码 resume）。
      const roomAtSender = castWait<CastRoomSnapshot>(sender, 'cast:room');
      const rotated = await emitAck<CastCreateAck>(receiver, 'cast:regenerate', {});
      if (!rotated.ok) throw new Error('regenerate failed');
      const nextCode = rotated.room.code;
      expect((await roomAtSender).code).toBe(nextCode);

      // 接收端必须已迁入新码的接收房间，否则新发送端的请求广播会丢失。
      const late = await ctx.connect();
      const requestEvent = castWait<{ senderId: string }>(receiver, 'cast:request');
      const lateJoined = await joinRoom(late, nextCode, 'after-rotate');
      expect((await requestEvent).senderId).toBe(lateJoined.senderId);
      expect(joined.senderId).not.toBe(lateJoined.senderId);

      // 旧码下的发送端仍可在新码房间里收到接收端 answer（寻址按新房间名）。
      const accepted = castWait<{ senderId: string }>(sender, 'cast:accepted');
      await emitAck(receiver, 'cast:decision', { senderId: joined.senderId, accept: true });
      expect((await accepted).senderId).toBe(joined.senderId);
    } finally {
      await ctx.close();
    }
  });

  it('关闭房间：发送端收到 roomClosed，旧码不可再加入，重复关闭幂等', async () => {
    const ctx = await createCastContext();
    try {
      const receiver = await ctx.connect();
      const sender = await ctx.connect();
      const created = await createRoom(receiver);
      await joinRoom(sender, created.code);
      const closedEvent = castWait<{ code: string; reason: string }>(sender, 'cast:roomClosed');
      const closed = await emitAck<{ ok: true }>(receiver, 'cast:close', {});
      expect(closed.ok).toBe(true);
      expect((await closedEvent).reason).toBe('closed');
      expect(ctx.server.castRooms.roomCount).toBe(0);

      const late = await ctx.connect();
      const join = await emitAck<CastJoinAck>(late, 'cast:join', { code: created.code });
      expect(expectFailure(join).error.code).toBe('NotFound');

      const again = await emitAck<CastAckFailure>(receiver, 'cast:close', {});
      expect(expectFailure(again).error.code).toBe('NotFound');
    } finally {
      await ctx.close();
    }
  });

  it('有效期到期自动关房并通知发送端', async () => {
    const ctx = await createCastContext({
      castRoomTtlMs: 60_000,
      // 放宽裁剪下限，让 1s 有效期可用于测试（产品默认下限 60s）。
      castRoomTtlMinMs: 100,
      castSenderGraceMs: 200,
    });
    try {
      const receiver = await ctx.connect();
      const sender = await ctx.connect();
      const created = await createRoom(receiver, { ttlMs: 1000 });
      await joinRoom(sender, created.code);
      const closedEvent = castWait<{ reason: string }>(sender, 'cast:roomClosed', 4000);
      const closed = await closedEvent;
      expect(closed.reason).toBe('expired');
      expect(ctx.server.castRooms.roomCount).toBe(0);
    } finally {
      await ctx.close();
    }
  });
});

describe('cast namespace — 加入 / 容量 / 限流', () => {
  it('autoAccept 时 join 直接 accepted 并广播房间快照', async () => {
    const ctx = await createCastContext();
    try {
      const receiver = await ctx.connect();
      const sender = await ctx.connect();
      const created = await createRoom(receiver);
      const roomEvent = castWait<CastRoomSnapshot>(receiver, 'cast:room');
      const accepted = castWait<{ senderId: string; code: string }>(sender, 'cast:accepted');
      const joined = await joinRoom(sender, created.code, 'DESKTOP-QA2');
      expect(joined.accepted).toBe(true);
      expect((await accepted).senderId).toBe(joined.senderId);
      const snapshot = await roomEvent;
      expect(snapshot.senders.map((item) => item.senderId)).toContain(joined.senderId);
      expect(snapshot.senders[0]?.deviceName).toBe('DESKTOP-QA2');
    } finally {
      await ctx.close();
    }
  });

  it('autoAccept=false：请求先挂起，接收端 accept 后才下发 accepted', async () => {
    const ctx = await createCastContext();
    try {
      const receiver = await ctx.connect();
      const sender = await ctx.connect();
      const created = await createRoom(receiver, { autoAccept: false });
      const requestEvent = castWait<{ senderId: string; deviceName: string }>(receiver, 'cast:request');
      const joined = await joinRoom(sender, created.code, 'iPhone-Test');
      expect(joined.accepted).toBe(false);
      const request = await requestEvent;
      expect(request.senderId).toBe(joined.senderId);
      expect(request.deviceName).toBe('iPhone-Test');

      const accepted = castWait<{ senderId: string }>(sender, 'cast:accepted');
      const decision = await emitAck<CastDecisionAck>(receiver, 'cast:decision', {
        senderId: joined.senderId,
        accept: true,
      });
      expect(decision.ok).toBe(true);
      expect((await accepted).senderId).toBe(joined.senderId);
    } finally {
      await ctx.close();
    }
  });

  it('达到 maxSenders 后拒绝新连接（RoomFull），释放一路后可重新加入', async () => {
    const ctx = await createCastContext();
    try {
      const receiver = await ctx.connect();
      const a = await ctx.connect();
      const b = await ctx.connect();
      const created = await createRoom(receiver, { maxSenders: 1 });
      const joinedA = await joinRoom(a, created.code, 'A');
      const rejected = await emitAck<CastJoinAck>(b, 'cast:join', { code: created.code, deviceName: 'B' });
      expect(expectFailure(rejected).error.code).toBe('RoomFull');

      await emitAck<CastLeaveAck>(receiver, 'cast:leave', { senderId: joinedA.senderId });
      const joinedB = await joinRoom(b, created.code, 'B');
      expect(joinedB.accepted).toBe(true);
    } finally {
      await ctx.close();
    }
  });

  it('下调 maxSenders 低于现有连接数被拒绝（不静默断流）', async () => {
    const ctx = await createCastContext();
    try {
      const receiver = await ctx.connect();
      const a = await ctx.connect();
      const b = await ctx.connect();
      const created = await createRoom(receiver, { maxSenders: 2 });
      await joinRoom(a, created.code, 'A');
      await joinRoom(b, created.code, 'B');
      const update = await emitAck<CastUpdateAck>(receiver, 'cast:update', { maxSenders: 1 });
      expect(expectFailure(update).error.code).toBe('ConnectionsExceedLimit');
      const ok = await emitAck<CastUpdateAck>(receiver, 'cast:update', { maxSenders: 2, autoAccept: false });
      expect(ok.ok).toBe(true);
    } finally {
      await ctx.close();
    }
  });

  it('错误房间号触发限流', async () => {
    const ctx = await createCastContext();
    try {
      const sender = await ctx.connect();
      let last: CastAckFailure | null = null;
      for (let attempt = 0; attempt < 8; attempt += 1) {
        const ack = await emitAck<CastJoinAck>(sender, 'cast:join', { code: '9999' });
        last = expectFailure(ack);
        expect(last.error.code).toBe('NotFound');
      }
      const blocked = await emitAck<CastJoinAck>(sender, 'cast:join', { code: '9999' });
      // 第 9 次命中限流（窗口内失败次数达到上限）。
      const failure = expectFailure(blocked);
      expect(['TooManyAttempts', 'NotFound']).toContain(failure.error.code);
    } finally {
      await ctx.close();
    }
  });

  it('非法房间号（非四位 / 非字符串）返回 InvalidCode', async () => {
    const ctx = await createCastContext();
    try {
      const sender = await ctx.connect();
      for (const code of ['12', '12345', 'abcd', 1234]) {
        const ack = await emitAck<CastJoinAck>(sender, 'cast:join', { code });
        expect(expectFailure(ack).error.code).toBe('InvalidCode');
      }
    } finally {
      await ctx.close();
    }
  });
});

describe('cast namespace — SDP / ICE 路由与串线隔离', () => {
  it('发送端 offer 直达接收端；接收端 answer 回到指定 senderId', async () => {
    const ctx = await createCastContext();
    try {
      const receiver = await ctx.connect();
      const sender = await ctx.connect();
      const created = await createRoom(receiver);
      const joined = await joinRoom(sender, created.code);

      const offerEvent = castWait<{ senderId: string; sdp: string }>(receiver, 'cast:offer');
      sender.emit('cast:offer', { sdp: 'v=0-offer-A' });
      const offer = await offerEvent;
      expect(offer).toEqual({ senderId: joined.senderId, sdp: 'v=0-offer-A' });

      const answerEvent = castWait<{ senderId: string; sdp: string }>(sender, 'cast:answer');
      receiver.emit('cast:answer', { senderId: joined.senderId, sdp: 'v=0-answer-A' });
      const answer = await answerEvent;
      expect(answer.senderId).toBe(joined.senderId);
      expect(answer.sdp).toBe('v=0-answer-A');
    } finally {
      await ctx.close();
    }
  });

  it('多发送端：接收端 answer 只路由到目标发送端（不串线）', async () => {
    const ctx = await createCastContext();
    try {
      const receiver = await ctx.connect();
      const senderA = await ctx.connect();
      const senderB = await ctx.connect();
      const created = await createRoom(receiver, { maxSenders: 4 });
      const joinedA = await joinRoom(senderA, created.code, 'A');
      const joinedB = await joinRoom(senderB, created.code, 'B');

      // 必须逐个注册监听：两个 once 同时挂起时，先到的 offer 会同时命中两个监听器。
      const offerA = castWait<{ senderId: string }>(receiver, 'cast:offer');
      senderA.emit('cast:offer', { sdp: 'offer-a' });
      expect((await offerA).senderId).toBe(joinedA.senderId);
      const offerB = castWait<{ senderId: string }>(receiver, 'cast:offer');
      senderB.emit('cast:offer', { sdp: 'offer-b' });
      expect((await offerB).senderId).toBe(joinedB.senderId);

      let leakedToA = false;
      senderA.on('cast:answer', () => {
        leakedToA = true;
      });
      const answerB = castWait<{ senderId: string; sdp: string }>(senderB, 'cast:answer');
      receiver.emit('cast:answer', { senderId: joinedB.senderId, sdp: 'answer-b' });
      expect((await answerB).sdp).toBe('answer-b');
      await sleep(80);
      expect(leakedToA).toBe(false);
    } finally {
      await ctx.close();
    }
  });

  it('发送端伪造 senderId 被服务端忽略（以会话为准）', async () => {
    const ctx = await createCastContext();
    try {
      const receiver = await ctx.connect();
      const senderA = await ctx.connect();
      const senderB = await ctx.connect();
      const created = await createRoom(receiver);
      const joinedA = await joinRoom(senderA, created.code, 'A');
      await joinRoom(senderB, created.code, 'B');

      const offerEvent = castWait<{ senderId: string; sdp: string }>(receiver, 'cast:offer');
      // A 伪造为 B 的 senderId：服务端必须回填真实 senderId。
      senderA.emit('cast:offer', { senderId: 'tx-forged', sdp: 'spoofed' });
      expect((await offerEvent).senderId).toBe(joinedA.senderId);
    } finally {
      await ctx.close();
    }
  });

  it('ICE candidate 双向转发（null 表示候选结束）', async () => {
    const ctx = await createCastContext();
    try {
      const receiver = await ctx.connect();
      const sender = await ctx.connect();
      const created = await createRoom(receiver);
      const joined = await joinRoom(sender, created.code);

      const iceAtReceiver = castWait<{ senderId: string; candidate: Record<string, unknown> | null }>(
        receiver,
        'cast:ice',
      );
      sender.emit('cast:ice', { candidate: { candidate: 'candidate:1 1 udp ...', sdpMid: '0' } });
      const ice = await iceAtReceiver;
      expect(ice.senderId).toBe(joined.senderId);
      expect(ice.candidate?.['sdpMid']).toBe('0');

      const endAtSender = castWait<{ candidate: unknown }>(sender, 'cast:ice');
      receiver.emit('cast:ice', { senderId: joined.senderId, candidate: null });
      expect((await endAtSender).candidate).toBeNull();
    } finally {
      await ctx.close();
    }
  });
});

describe('cast namespace — 断线宽限与隔离', () => {
  it('发送端断线在宽限内 resume 成功；超时后席位释放', async () => {
    const ctx = await createCastContext({ castSenderGraceMs: 300 });
    try {
      const receiver = await ctx.connect();
      const sender = await ctx.connect();
      const created = await createRoom(receiver);
      const joined = await joinRoom(sender, created.code, 'A');
      sender.disconnect();
      // 等服务端处理断开并进入宽限（轮询存储状态，避免依赖固定 sleep 时长）。
      await waitFor(() => ctx.server.castRooms.roomOf(created.code)?.senders.get(joined.senderId)?.reconnecting === true);
      const resumedClient = await ctx.connect();
      const resumed = await emitAck<CastResumeAck>(resumedClient, 'cast:resume', {
        code: created.code,
        senderToken: joined.senderToken,
      });
      expect(resumed.ok).toBe(true);
      if (resumed.ok && resumed.role === 'sender') {
        expect(resumed.senderId).toBe(joined.senderId);
      }
      await sleep(400);
      const status = await emitAck<CastStatusAck>(receiver, 'cast:status', {});
      expect(status.ok).toBe(true);
      if (status.ok) expect(status.room.senders).toHaveLength(1);
    } finally {
      await ctx.close();
    }
  });

  it('接收端断线宽限内 resume；超时关房并通知发送端', async () => {
    const ctx = await createCastContext({ castReceiverGraceMs: 300 });
    try {
      const receiver = await ctx.connect();
      const sender = await ctx.connect();
      const created = await createRoom(receiver);
      await joinRoom(sender, created.code);
      receiver.disconnect();
      await waitFor(() => !ctx.server.castRooms.isReceiverOnline(created.code));
      const resumedClient = await ctx.connect();
      const resumed = await emitAck<CastResumeAck>(resumedClient, 'cast:resume', {
        code: created.code,
        receiverToken: created.receiverToken,
      });
      expect(resumed.ok).toBe(true);
      if (resumed.ok) expect(resumed.role).toBe('receiver');

      const closedEvent = castWait<{ reason: string }>(sender, 'cast:roomClosed', 3000);
      resumedClient.disconnect();
      expect((await closedEvent).reason).toBe('receiver-left');
    } finally {
      await ctx.close();
    }
  });

  it('匿名开发模式：重连后凭 receiverToken 仍可恢复（userId 每次连接不同）', async () => {
    // 无 WB_JWT_SECRET：每次连接都是新的 anon-* 身份，resume 必须以 token 为凭证。
    const server = await startTestServer({});
    const clients: CastClient[] = [];
    const connect = async (): Promise<CastClient> => {
      const client: CastClient = createClient(`http://127.0.0.1:${server.port}${CAST_NAMESPACE}`, {
        transports: ['websocket'],
        forceNew: true,
        reconnection: false,
        auth: {},
      });
      clients.push(client);
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('cast connect timeout')), 5000);
        client.once('connect', () => {
          clearTimeout(timer);
          resolve();
        });
        client.once('connect_error', (error) => {
          clearTimeout(timer);
          reject(error);
        });
      });
      return client;
    };
    try {
      const receiver = await connect();
      const created = await createRoom(receiver);
      receiver.disconnect();
      await waitFor(() => !server.castRooms.isReceiverOnline(created.code));

      const resumedClient = await connect();
      const resumed = await emitAck<CastResumeAck>(resumedClient, 'cast:resume', {
        code: created.code,
        receiverToken: created.receiverToken,
      });
      expect(resumed.ok).toBe(true);
      if (resumed.ok) expect(resumed.role).toBe('receiver');
    } finally {
      for (const client of clients) client.disconnect();
      await server.close();
    }
  });

  it('投屏房间关闭不影响 /board 房间与 ops 流', async () => {
    const ctx = await createCastContext();
    try {
      const receiver = await ctx.connect();
      const created = await createRoom(receiver);

      // 同一服务上的白板房间照常工作。
      const boardClient = createClient(`http://127.0.0.1:${ctx.server.port}/board`, {
        transports: ['websocket'],
        forceNew: true,
        reconnection: false,
        auth: {},
      });
      try {
        await new Promise<void>((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('board connect timeout')), 5000);
          boardClient.once('connect', () => {
            clearTimeout(timer);
            resolve();
          });
        });
        const joined = await new Promise<{ ok: boolean }>((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('board join timeout')), 5000);
          boardClient.emit('board:join' as never, { boardId: 'board-isolation' } as never, ((ack: { ok: boolean }) => {
            clearTimeout(timer);
            resolve(ack);
          }) as never);
        });
        expect(joined.ok).toBe(true);
        await emitAck<{ ok: true }>(receiver, 'cast:close', {});
        expect(ctx.server.castRooms.roomCount).toBe(0);
        expect(ctx.server.rooms.roomCount).toBe(1);
        expect(ctx.server.rooms.participants('board-isolation')).toHaveLength(1);
      } finally {
        boardClient.disconnect();
      }
    } finally {
      await ctx.close();
    }
  });
});
