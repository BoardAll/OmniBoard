// tests/e2e 「双端互见」场景探针（socket.io 契约级，两个客户端同房间；M1 基线 + M2 扩展 + M3 互动/checkpoint）。
//
// 覆盖（对齐《互动白板实时协同设计文档》§5.4/§5.5/§5.6/§5.10/§5.12/§5.14/§6/§7 与 desktop 侧 op 契约
// `el:{id}:data` / `el:{id}:exists=false`）：
//   1. 成员互见：A/B 加入同一 board 房间，双方观测到彼此（participants 增量）；
//      （2026-10 默认无权限：后加入者默认只读——B 入房后由 A（自举 Host）授权写入）；
//   2. op 矩阵：B 依次发「插入 → 移动 → 文本终态」三条 data op，A 按序收到并
//      核对各字段终值；
//   3. presence:preview（M2）：A 发 cursor（载荷含伪造 userId）→ B 收到且 userId
//      为服务端权威注入值（伪造被覆盖）；A 自己收不到（排除发送者）；未入房 socket
//      发送被静默忽略（不转发、不崩）；
//   4. 软锁（M2）：A acquire 授予（ack + 广播）→ B 同元素被拒（granted:false +
//      holderUserId）→ B 他元素授予 → 新成员 join 快照含锁表 → A release →
//      B 重获 → B renew 续期 → A 再持一锁（供断连释放验证）；
//   5. 断线重连（M2 增强）：A 断开（B 观测 left 增量 + 服务端断连释放 A 的锁
//      lock:changed('released')）→ B 在 A 离线期间发 2 条 op → A2（CoHost，JWT 注入；
//      默认无权限下重连写路径需具备写权限）以 `lastSeenVersion={actor:3}` 重连，
//      精确回放缺口感增量（仅 2 条，无重复已见 op；重连快照不含已释放锁）
//      → 恢复后 A2 写自己的 op（写路径不崩）；
//   6. interactive 契约（M3，独立房间 + JWT 角色注入）：raiseHand/lowerHand
//      （updated 增量、排除发送者）；grantControl/revokeControl（目标收 roleChanged
//      单播 + updated 广播；2026-10 默认无权限：revoke 仅清 grantedWrite、角色不变——
//      与「后加入未授权」完全等效，free/present 均即时只读、需重新 grant 才能编辑；
//      专用 peer 参与者验证收权后拒写）；startPresent →
//      modeChanged{present,presenterId}；present 下 Participant 发 op 被拒（Forbidden）、
//      Presenter 仍可写、stopPresent 后未授权仍只读（grant 后写路径恢复）；follow/unfollow 单播 {followerUserId}
//      （无 ack、旁观者静默）；
//      removeUser → 目标收 room:removed 单播后断开 + left 广播；
//   7. 角色矩阵拒绝路径（M3）：Viewer 发 grantControl/startPresent/removeUser →
//      forbidden 回执且无任何广播扩散；
//   8. checkpoint（M3）：注入 `WB_CHECKPOINT_OP_THRESHOLD` 量 op → 在房最早 ≥CoHost
//      客户端收 board:checkpointRequest 单播（后加入的 Host 不收）→ 回传
//      board:checkpoint{stateVector,payload} → 新连接 join（无 lastSeenVersion）→
//      board:joined.snapshot 与上传内容一致（只存不解释）；无 CoHost 在线不请求。
//
// 用法：node wb_collab_scenario_probe.mjs <realtimeDir> <endpoint> <boardId> <timeoutMs>
// 环境（M3）：
//   WB_JWT_SECRET               服务端 JWT 密钥（角色注入签名；缺省 test-secret，须与服务端一致）
//   WB_CHECKPOINT_OP_THRESHOLD  checkpoint 触发阈值（缺省 500，须与服务端一致；小值加速触发）
// 输出（stdout 每行一条 JSON；诊断走 stderr）：
//   {"milestone":"ready","participants":2}
//   {"milestone":"op-matrix","received":3}
//   {"milestone":"presence","injected":true,"authoritative":true,"excludedSender":true,"notInRoomIgnored":true}
//   {"milestone":"locks","granted":true,"busyDenied":true,"reacquired":true,"renewed":true,"joinSnapshot":true}
//   {"milestone":"away","lockReleased":true}
//   {"milestone":"recovered","replayed":2,"noDup":true,"postWrite":true,"locksClean":true}
//   {"milestone":"m3-ready","participants":5}
//   {"milestone":"m3-raise-hand","raised":true,"lowered":true,"senderExcluded":true}
//   {"milestone":"m3-grant","granted":true,"revoked":true,"roleChanged":true,"updated":true,"revokedDenied":true}
//   {"milestone":"m3-present","started":true,"deniedForbidden":true,"presenterWritable":true,"stopped":true,"recovered":true}
//   {"milestone":"m3-follow","followed":true,"unfollowed":true,"noAck":true,"quiet":true}
//   {"milestone":"m3-role-matrix","viewerGrantDenied":true,"viewerPresentDenied":true,"viewerRemoveDenied":true,"noSpread":true}
//   {"milestone":"m3-remove-user","removed":true,"disconnected":true,"leftBroadcast":true}
//   {"milestone":"m3-checkpoint","requested":true,"singleCast":true,"snapshotMatches":true,"byInjection":true}
//   {"milestone":"m3-checkpoint-bootstrapped","requested":true,"viewerQuiet":true}
//   {"ok":true}
// 失败：{"ok":false,"reason":"..."} + 退出码 2。
import { createRequire } from 'node:module';
import { join } from 'node:path';

const NL = String.fromCharCode(10);
const args = process.argv.slice(2);
const realtimeDir = args[0];
const endpoint = args[1];
const boardId = args[2];
const timeoutMs = Number(args[3] || 60000);
const stamp = Date.now().toString(36);
// M3：checkpoint 触发阈值（默认 500，与 realtime 服务默认值一致；编排以 WB_CHECKPOINT_OP_THRESHOLD 覆盖对齐）。
const checkpointThresholdRaw = Number((process.env.WB_CHECKPOINT_OP_THRESHOLD ?? '').trim());
const checkpointThreshold =
  Number.isInteger(checkpointThresholdRaw) && checkpointThresholdRaw >= 1 ? checkpointThresholdRaw : 500;
// M3：JWT 角色注入密钥（须与服务端 WB_JWT_SECRET 一致；这里默认与 services/realtime 测试同款）。
const jwtSecret = (process.env.WB_JWT_SECRET ?? '').trim() || 'test-secret';

const emit = (payload) => process.stdout.write(JSON.stringify(payload) + NL);
const log = (msg) => process.stderr.write('[scenario-probe] ' + msg + NL);

let finished = false;
function finish(payload, code) {
  if (finished) return;
  finished = true;
  emit(payload);
  setTimeout(() => process.exit(code), 50);
}
const fail = (reason) => {
  log('FAIL: ' + reason);
  finish({ ok: false, reason }, 2);
};

setTimeout(() => fail('场景超时（' + timeoutMs + 'ms）'), timeoutMs);

let ioFactory = null;
let jwtSign = null;
try {
  const require = createRequire(join(realtimeDir, 'package.json'));
  ioFactory = require('socket.io-client').io;
  jwtSign = require('jsonwebtoken').sign;
} catch (err) {
  fail('socket.io-client 解析失败: ' + err.message);
}

if (ioFactory !== null) {
  runScenario().catch((err) => fail(err && err.message ? err.message : String(err)));
}

// ---- 通用工具 --------------------------------------------------------------

function assertEq(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(label + ' 不一致：actual=' + JSON.stringify(actual) + ' expected=' + JSON.stringify(expected));
  }
}

/** 水位向量逐键严格比较（键集合 + 每键数值）。 */
function assertVectorEq(actual, expected, label) {
  const a = actual ?? {};
  const e = expected ?? {};
  const keysA = Object.keys(a).sort();
  const keysE = Object.keys(e).sort();
  if (keysA.length !== keysE.length || keysA.some((key, index) => key !== keysE[index])) {
    throw new Error(label + ' 键集合不一致：actual=' + JSON.stringify(a) + ' expected=' + JSON.stringify(e));
  }
  for (const key of keysA) {
    if (a[key] !== e[key]) {
      throw new Error(label + ' [' + key + '] 不一致：actual=' + a[key] + ' expected=' + e[key]);
    }
  }
}

/** 等到 socket 事件满足断言（非目标事件继续等待）。 */
function until(socket, event, predicate, ms, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.off(event, handler);
      reject(new Error('超时 ' + ms + 'ms：' + label));
    }, ms);
    function handler(...payloadArgs) {
      let ok = false;
      try {
        ok = predicate(...payloadArgs);
      } catch (_) {
        ok = false;
      }
      if (ok) {
        clearTimeout(timer);
        socket.off(event, handler);
        resolve(payloadArgs);
      }
    }
    socket.on(event, handler);
  });
}

/** 静默窗口断言：ms 内该 socket 不得收到 event；收到即失败（用于「单播、不广播」类断言）。 */
function assertQuiet(socket, event, ms, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.off(event, handler);
      resolve();
    }, ms);
    function handler() {
      clearTimeout(timer);
      socket.off(event, handler);
      reject(new Error('不应收到 ' + event + '：' + label));
    }
    socket.on(event, handler);
  });
}

/** 持续收集某事件的触发参数（用于「不应扩散 / 不应收到」类断言；记得 stop）。 */
function collectEvents(socket, event) {
  const calls = [];
  const handler = (...payloadArgs) => calls.push(payloadArgs);
  socket.on(event, handler);
  return { calls, stop: () => socket.off(event, handler) };
}

/** 轮询等待条件成立（50ms 间隔；超时抛错）。 */
function waitUntil(predicate, ms, label) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + ms;
    const attempt = () => {
      let ok = false;
      try {
        ok = predicate();
      } catch (_) {
        ok = false;
      }
      if (ok) {
        resolve();
        return;
      }
      if (Date.now() > deadline) {
        reject(new Error('超时 ' + ms + 'ms：' + label));
        return;
      }
      setTimeout(attempt, 50);
    };
    attempt();
  });
}

/** 延时等待（静默窗口 / 增量收敛）。 */
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** 等待连接被（服务端）断开，返回断开原因。 */
function waitDisconnect(socket, ms, label) {
  if (socket.disconnected) return Promise.resolve('already-disconnected');
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('超时 ' + ms + 'ms：' + label)), ms);
    socket.once('disconnect', (reason) => {
      clearTimeout(timer);
      resolve(reason);
    });
  });
}

/** 带回调 emit（ack 超时抛错）。 */
function emitAck(socket, event, payload, ms = 15000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('ack 超时：' + event)), ms);
    socket.emit(event, payload, (ack) => {
      clearTimeout(timer);
      resolve(ack);
    });
  });
}

/** 连接并等待 board:session 身份单播；传 options.token / options.expectRole 时校验 JWT 角色注入。 */
async function connectClient(tag, options = {}) {
  const socket = ioFactory(endpoint + '/board', {
    transports: ['websocket'],
    reconnection: false,
    ...(options.token ? { auth: { token: options.token } } : {}),
  });
  const [session] = await until(socket, 'board:session', () => true, 15000, tag + ' board:session');
  log(tag + ' connected userId=' + session.userId + ' authMode=' + session.authMode + ' role=' + session.role);
  if (options.expectRole) {
    if (session.authMode !== 'jwt' || session.role !== options.expectRole) {
      throw new Error(
        tag + ' 角色注入失败：期望 jwt/' + options.expectRole + '，实际 ' + session.authMode + '/' + session.role
          + '（须与服务端共享 WB_JWT_SECRET）',
      );
    }
  }
  return { socket, userId: session.userId, role: session.role };
}

/** M3：按 JWT role 注入连接（对齐服务端 token.ts 的 sub + role claim 语义）。 */
async function connectRoleClient(tag, role, userId) {
  if (typeof jwtSign !== 'function') {
    throw new Error('jsonwebtoken 不可用：无法执行 M3 角色注入（从 realtime 依赖解析）');
  }
  const token = jwtSign({ role }, jwtSecret, { algorithm: 'HS256', subject: userId });
  return connectClient(tag, { token, expectRole: role });
}

/** join 房间（失败抛错），返回 ack（含 participants/locks/stateVector/snapshot 等）。 */
async function joinRoom(client, tag, roomId) {
  const ack = await emitAck(client.socket, 'board:join', { boardId: roomId });
  if (!ack || ack.ok !== true) throw new Error(tag + ' join 失败：' + JSON.stringify(ack));
  return ack;
}

/** 收集指定 (actor, seq) 集合的 op（按 wanted 顺序返回）。 */
function collectOps(socket, wanted, ms, label) {
  return new Promise((resolve, reject) => {
    const found = new Map();
    const timer = setTimeout(() => {
      socket.off('board:ops', handler);
      reject(new Error('超时 ' + ms + 'ms：' + label + '（已收 ' + found.size + '/' + wanted.length + '）'));
    }, ms);
    function handler(ops) {
      if (!Array.isArray(ops)) return;
      for (const op of ops) {
        for (const want of wanted) {
          if (op.actor === want.actor && op.seq === want.seq && !found.has(op.seq)) {
            found.set(op.seq, op);
          }
        }
      }
      if (found.size === wanted.length) {
        clearTimeout(timer);
        socket.off('board:ops', handler);
        resolve(wanted.map((want) => found.get(want.seq)));
      }
    }
    socket.on('board:ops', handler);
  });
}

/** 收集到达的 board:ops 批次，直至累计 >= expectedCount 条后再静默 quietMs 收敛（超时抛错）。 */
function collectBurst(socket, expectedCount, ms, quietMs, label) {
  return new Promise((resolve, reject) => {
    const batches = [];
    let quietTimer = null;
    let overallTimer = null;
    const countOps = () => batches.reduce((sum, batch) => sum + batch.ops.length, 0);
    const cleanup = () => {
      clearTimeout(overallTimer);
      if (quietTimer !== null) clearTimeout(quietTimer);
      socket.off('board:ops', handler);
    };
    overallTimer = setTimeout(() => {
      cleanup();
      reject(new Error('超时 ' + ms + 'ms：' + label + '（已收 ' + countOps() + '/' + expectedCount + '）'));
    }, ms);
    function handler(ops, meta) {
      if (!Array.isArray(ops) || ops.length === 0) return;
      batches.push({ ops, meta });
      if (countOps() >= expectedCount) {
        if (quietTimer !== null) clearTimeout(quietTimer);
        quietTimer = setTimeout(() => {
          cleanup();
          resolve(batches);
        }, quietMs);
      }
    }
    socket.on('board:ops', handler);
  });
}

async function emitOps(client, ops) {
  const ack = await emitAck(client.socket, 'board:ops', ops, 20000);
  if (!ack || ack.ok !== true) {
    throw new Error('board:ops 被拒：' + JSON.stringify(ack));
  }
}

/** 构造 op（M3：任意 actor / seq / key / value）。 */
function mkOp(actor, seq, key, value) {
  return { actor, seq, key, value, timestamp: Date.now() };
}

// ---- 场景主体 --------------------------------------------------------------

const elementId = 'probe-el-' + stamp;
const aActor = 'e2e-probe-a-' + stamp;
const bActor = 'e2e-probe-b-' + stamp;

function elementValue(x, text) {
  return {
    id: elementId,
    type: 'note',
    position: { x, y: 10 },
    size: { width: 160, height: 96 },
    zIndex: 0,
    text,
  };
}

const op = (seq, key, value) => ({ actor: bActor, seq, key, value, timestamp: Date.now() });

async function runScenario() {
  // 1) 连接 + 加入房间 → 成员互见。
  const clientA = await connectClient('A');
  const clientB = await connectClient('B');

  const ackA = await emitAck(clientA.socket, 'board:join', { boardId });
  if (!ackA || ackA.ok !== true) throw new Error('A join 失败：' + JSON.stringify(ackA));
  const seesBJoined = until(
    clientA.socket,
    'board:participants',
    (p) => Array.isArray(p?.joined) && p.joined.some((x) => x.userId === clientB.userId),
    15000,
    'A 观测 B 加入增量',
  );
  const ackB = await emitAck(clientB.socket, 'board:join', { boardId });
  if (!ackB || ackB.ok !== true) throw new Error('B join 失败：' + JSON.stringify(ackB));
  if (!Array.isArray(ackB.participants) || ackB.participants.length !== 2) {
    throw new Error('B 快照应含 2 名成员：' + JSON.stringify(ackB.participants));
  }
  await seesBJoined;

  // 1.1) 2026-10 默认无权限：后加入者默认只读——A（自举 Host）授权 B 写入；
  //      后续 op 矩阵 / 软锁 / 断线期间写入均依赖该授权（服务端权威 grantedWrite）。
  const grantBAck = await emitAck(clientA.socket, 'interactive:grantControl', { userId: clientB.userId });
  if (!grantBAck || grantBAck.ok !== true) {
    throw new Error('A 授权 B 失败：' + JSON.stringify(grantBAck));
  }
  emit({ milestone: 'ready', participants: 2 });

  // 2) op 矩阵：插入（seq1）→ 移动（seq2）→ 文本终态（seq3）。
  const matrix = collectOps(
    clientA.socket,
    [
      { actor: bActor, seq: 1 },
      { actor: bActor, seq: 2 },
      { actor: bActor, seq: 3 },
    ],
    30000,
    'A 收取 B 的 op 矩阵',
  );
  await emitOps(clientB, [op(1, 'el:' + elementId + ':data', elementValue(10, 'v1·插入'))]);
  await emitOps(clientB, [op(2, 'el:' + elementId + ':data', elementValue(110, 'v1·插入'))]);
  await emitOps(clientB, [op(3, 'el:' + elementId + ':data', elementValue(110, '终态文本·v2'))]);
  const [insertOp, moveOp, textOp] = await matrix;
  assertEq(insertOp.value.position.x, 10, '插入 op x');
  assertEq(insertOp.value.text, 'v1·插入', '插入 op text');
  assertEq(moveOp.value.position.x, 110, '移动 op x');
  assertEq(textOp.value.text, '终态文本·v2', '文本终态 op text');
  emit({ milestone: 'op-matrix', received: 3 });

  // 3) presence:preview 泛化转发（M2）：B 收到 + 服务端权威 userId（覆盖伪造值）；
  //    排除发送者；未入房静默忽略。
  const clientC = await connectClient('C'); // 先保持未入房：测静默忽略；4) 用它 join 校验锁快照。
  const presencePageId = 'probe-presence-' + stamp;
  let aEchoCount = 0;
  const aEchoHandler = (p) => {
    if (p && p.x === 321 && p.y === 654) aEchoCount += 1;
  };
  clientA.socket.on('presence:preview', aEchoHandler);
  const bSeesPreview = until(
    clientB.socket,
    'presence:preview',
    (p) => p?.kind === 'cursor' && p?.x === 321 && p?.y === 654
      && p?.pageId === presencePageId && p?.userId === clientA.userId,
    10000,
    'B 收到 A 的 presence:preview（伪造 userId 被覆盖为权威 userId）',
  );
  // 载荷带伪造 userId：服务端转发必须覆盖为权威值（rooms.ts: {...payload, userId}）。
  clientA.socket.emit('presence:preview', {
    kind: 'cursor', x: 321, y: 654, pageId: presencePageId, userId: 'spoofed-' + stamp,
  });
  await bSeesPreview;

  // 未入房 socket 发送：服务端静默忽略（不转发、不断连）；顺带静默窗口收敛排除发送者断言。
  let notInRoomLeak = 0;
  const leakHandler = (p) => {
    if (p && p.x === 987) notInRoomLeak += 1;
  };
  clientA.socket.on('presence:preview', leakHandler);
  clientB.socket.on('presence:preview', leakHandler);
  clientC.socket.emit('presence:preview', { kind: 'cursor', x: 987, y: 654, pageId: 'not-in-room' });
  await sleep(600);
  clientA.socket.off('presence:preview', aEchoHandler);
  clientA.socket.off('presence:preview', leakHandler);
  clientB.socket.off('presence:preview', leakHandler);
  assertEq(aEchoCount, 0, '发送者不应收到自己的 presence:preview（排除发送者）');
  assertEq(notInRoomLeak, 0, '未入房 sender 的 presence:preview 不应被转发');
  assertEq(clientC.socket.connected, true, '未入房发送后连接应保持（静默不崩）');
  emit({
    milestone: 'presence',
    injected: true,
    authoritative: true,
    excludedSender: true,
    notInRoomIgnored: true,
  });

  // 4) 软锁（M2）：授予 + 广播 → 占用拒绝（holderUserId）→ 他元素授予 → join 快照 → 释放 → 重获 → 续期。
  const lockEl1 = 'probe-lock-' + stamp;
  const lockEl2 = 'probe-lock2-' + stamp;

  // 4.1 A acquire：ack granted:true + expiresAt；B 收到 lock:changed（acquired）广播。
  let aSelfEcho = 0;
  const aSelfEchoHandler = (p) => {
    if (p?.elementId === lockEl1 && p?.action === 'acquired') aSelfEcho += 1;
  };
  clientA.socket.on('lock:changed', aSelfEchoHandler);
  const bSeesLockAcquired = until(
    clientB.socket,
    'lock:changed',
    (p) => p?.elementId === lockEl1 && p?.userId === clientA.userId
      && p?.action === 'acquired' && typeof p?.expiresAt === 'number',
    10000,
    'B 收到 lock:changed（acquired）',
  );
  const acquireA = await emitAck(clientA.socket, 'lock:acquire', { elementId: lockEl1 });
  if (!acquireA || acquireA.ok !== true || acquireA.granted !== true) {
    throw new Error('A lock:acquire 未授予：' + JSON.stringify(acquireA));
  }
  assertEq(acquireA.elementId, lockEl1, 'acquire ack elementId');
  if (!(typeof acquireA.expiresAt === 'number' && acquireA.expiresAt > Date.now())) {
    throw new Error('acquire ack expiresAt 异常：' + JSON.stringify(acquireA));
  }
  await bSeesLockAcquired;

  // 4.2 B 同元素被拒：单播 granted:false + holderUserId=A；不广播（静默窗口一并验发送者排除）。
  const deniedB = await emitAck(clientB.socket, 'lock:acquire', { elementId: lockEl1 });
  assertEq(deniedB.ok, true, 'busy 回执 ok');
  assertEq(deniedB.granted, false, 'busy 回执 granted');
  assertEq(deniedB.holderUserId, clientA.userId, 'busy 回执 holderUserId');
  await assertQuiet(clientA.socket, 'lock:changed', 400, '占用拒绝应单播、不广播');
  clientA.socket.off('lock:changed', aSelfEchoHandler);
  assertEq(aSelfEcho, 0, '发送者不应收到自己的 lock:changed（排除发送者）');

  // 4.3 B 换元素授予：A 收到 lock:changed（acquired）广播。
  const aSeesLockAcquired2 = until(
    clientA.socket,
    'lock:changed',
    (p) => p?.elementId === lockEl2 && p?.userId === clientB.userId && p?.action === 'acquired',
    10000,
    'A 收到 B 的 lock:changed（acquired）',
  );
  const acquireB2 = await emitAck(clientB.socket, 'lock:acquire', { elementId: lockEl2 });
  if (!acquireB2 || acquireB2.ok !== true || acquireB2.granted !== true) {
    throw new Error('B 他元素 acquire 未授予：' + JSON.stringify(acquireB2));
  }
  await aSeesLockAcquired2;

  // 4.4 join 快照：C 入房，board:joined（ack）应含锁表 {elementId: {userId, expiresAt}}。
  const joinC = await emitAck(clientC.socket, 'board:join', { boardId });
  if (!joinC || joinC.ok !== true) throw new Error('C join 失败：' + JSON.stringify(joinC));
  const locksSnapshot = joinC.locks ?? {};
  assertEq(locksSnapshot[lockEl1]?.userId, clientA.userId, 'join 锁快照 el1 持有者');
  assertEq(locksSnapshot[lockEl2]?.userId, clientB.userId, 'join 锁快照 el2 持有者');
  if (!(typeof locksSnapshot[lockEl1]?.expiresAt === 'number'
    && typeof locksSnapshot[lockEl2]?.expiresAt === 'number')) {
    throw new Error('join 锁快照缺 expiresAt：' + JSON.stringify(locksSnapshot));
  }

  // 4.5 A 释放：B 收到 lock:changed（released）广播。
  const bSeesLockReleased = until(
    clientB.socket,
    'lock:changed',
    (p) => p?.elementId === lockEl1 && p?.action === 'released' && p?.userId === clientA.userId,
    10000,
    'B 收到 lock:changed（released）',
  );
  const releaseA = await emitAck(clientA.socket, 'lock:release', { elementId: lockEl1 });
  assertEq(releaseA.ok, true, 'release 回执 ok');
  await bSeesLockReleased;

  // 4.6 B 重获第一元素：A 收到广播。
  const aSeesLockReacquired = until(
    clientA.socket,
    'lock:changed',
    (p) => p?.elementId === lockEl1 && p?.userId === clientB.userId && p?.action === 'acquired',
    10000,
    'A 收到 B 重获 lock:changed（acquired）',
  );
  const acquireB3 = await emitAck(clientB.socket, 'lock:acquire', { elementId: lockEl1 });
  if (!acquireB3 || acquireB3.ok !== true || acquireB3.granted !== true) {
    throw new Error('B 重获 lock 未授予：' + JSON.stringify(acquireB3));
  }
  await aSeesLockReacquired;

  // 4.7 B renew 续期：ok:true 且 expiresAt 不早于重获时（同毫秒相等亦不倒退）。
  const renewB = await emitAck(clientB.socket, 'lock:renew', { elementId: lockEl1 });
  if (!renewB || renewB.ok !== true) throw new Error('lock:renew 未成功：' + JSON.stringify(renewB));
  if (!(typeof renewB.expiresAt === 'number' && renewB.expiresAt >= acquireB3.expiresAt)) {
    throw new Error('lock:renew expiresAt 未续期：' + JSON.stringify(renewB) + '（旧 ' + acquireB3.expiresAt + '）');
  }
  emit({
    milestone: 'locks',
    granted: true,
    busyDenied: true,
    reacquired: true,
    renewed: true,
    joinSnapshot: true,
  });

  // 4.8 断连释放预置（M2）：A 再持一锁；步骤 5 断连时断言服务端自动释放并广播
  //     lock:changed（released）（实现：leaveBoard → releaseLocksBySocket）。
  const lockEl3 = 'probe-lock3-' + stamp;
  const acquireA3 = await emitAck(clientA.socket, 'lock:acquire', { elementId: lockEl3 });
  if (!acquireA3 || acquireA3.ok !== true || acquireA3.granted !== true) {
    throw new Error('A lockEl3 acquire 未授予：' + JSON.stringify(acquireA3));
  }

  // 5) A 断线：B 观测 left 增量 + 服务端断连释放 A 持有的锁（lock:changed released）。
  const seesALeft = until(
    clientB.socket,
    'board:participants',
    (p) => Array.isArray(p?.left) && p.left.some((x) => x.userId === clientA.userId),
    15000,
    'B 观测 A 离开增量',
  );
  const bSeesDisconnectRelease = until(
    clientB.socket,
    'lock:changed',
    (p) => p?.elementId === lockEl3 && p?.action === 'released'
      && p?.userId === clientA.userId,
    15000,
    'B 观测断连释放 lock:changed（released）',
  );
  clientA.socket.disconnect();
  await seesALeft;
  await bSeesDisconnectRelease;
  emit({ milestone: 'away', lockReleased: true });

  // 断线期间：B 发 2 条 op（seq4 删除 / seq5 回写），供重连差分精确回放。
  await emitOps(clientB, [op(4, 'el:' + elementId + ':exists', false)]);
  await emitOps(clientB, [op(5, 'el:' + elementId + ':data', elementValue(210, '断线期间·v3'))]);

  // 6) A2 以 lastSeenVersion（已见 B:1..3）重连 join：精确回放缺口增量（仅 2 条，无重复已见 op）。
  //    2026-10 默认无权限：A2 经 JWT 注入 CoHost（恒可写）——后加入者默认只读，
  //    重连写路径需具备写权限（不依赖 Host 转移窗口时序）。
  const clientA2 = await connectRoleClient('A2', 'CoHost', 'e2e-probe-a2-' + stamp);
  const burstPromise = collectBurst(clientA2.socket, 2, 15000, 600, 'A2 断线重连差分量');
  const joinA2 = await emitAck(clientA2.socket, 'board:join', {
    boardId,
    lastSeenVersion: { [bActor]: 3 },
  });
  if (!joinA2 || joinA2.ok !== true) throw new Error('A2 join 失败：' + JSON.stringify(joinA2));
  const replayBatches = await burstPromise;
  const replayed = replayBatches.flatMap((batch) => batch.ops);
  assertEq(replayed.length, 2, '重连回放条数（仅缺口增量）');
  assertEq(replayed.filter((o) => o.actor === bActor && o.seq <= 3).length, 0, '重复已见 op 条数');
  assertEq(replayed[0].seq, 4, '回放 op[0] seq');
  assertEq(replayed[1].seq, 5, '回放 op[1] seq');
  assertEq(replayed[0].key, 'el:' + elementId + ':exists', '回放删除 op key');
  assertEq(replayed[0].value, false, '回放删除 op value');
  assertEq(replayed[1].value?.text, '断线期间·v3', '回放文本 op text');
  for (const batch of replayBatches) {
    if (!batch.meta || batch.meta.replay !== true) {
      throw new Error('重连回放应为 {replay:true} 单播：' + JSON.stringify(batch.meta));
    }
  }
  assertEq(joinA2.stateVector?.[bActor], 5, 'join ack stateVector 水位');

  // 断连释放不残留：A2 快照不含 lockEl3；B 续期中的锁（el1）保留。
  const locksAfterRejoin = joinA2.locks ?? {};
  assertEq(locksAfterRejoin[lockEl3], undefined, '断连释放锁不应残留于重连快照');
  assertEq(locksAfterRejoin[lockEl1]?.userId, clientB.userId, '重连快照保留 B 持有锁（el1）');

  // 7) 恢复后写路径：A2 发自己的 op，B 收到（写路径不崩）。
  const postWriteSeen = collectOps(
    clientB.socket,
    [{ actor: aActor, seq: 1 }],
    15000,
    'B 收取 A 恢复后的写入',
  );
  await emitOps(clientA2, [
    { actor: aActor, seq: 1, key: 'el:probe-a-' + stamp + ':data', value: elementValue(8, 'A·恢复后写入'), timestamp: Date.now() },
  ]);
  await postWriteSeen;
  emit({
    milestone: 'recovered',
    replayed: replayed.length,
    noDup: true,
    postWrite: true,
    locksClean: true,
  });

  clientA2.socket.disconnect();
  clientB.socket.disconnect();
  clientC.socket.disconnect();

  // 8) M3 契约组（interactive / 角色矩阵拒绝 / checkpoint；独立房间，角色经 JWT 注入）。
  await runM3Scenario();

  finish({ ok: true }, 0);
}

/**
 * M3 契约组（interactive / 角色矩阵拒绝 / checkpoint；独立房间 + JWT 角色注入）。
 *
 * 覆盖（对齐 services/realtime M3 实现与《互动白板实时协同设计文档》§5.10/§5.14/§7）：
 * - 五身份连接（JWT role 经 WB_JWT_SECRET 注入，sub=userId、role=claim）：CoHost 最先入房 →
 *   房主自举升 Host（即 checkpoint「最早 Host/CoHost」候选）/ Host 后入 → 冲突降级 CoHost /
 *   Participant / Presenter / Viewer；
 * - raiseHand / lowerHand：他人收 participants updated(handRaised)；发送者排除；
 * - grantControl / revokeControl：目标收 roleChanged 单播（grantedWrite）+ 他人收 updated 广播；
 * - startPresent / stopPresent：广播 modeChanged{present,presenterId}/{free}；发起者排除（start）；
 * - present 收窄：Participant 发 op 被拒（ack Forbidden + room:error，无广播）；Presenter 可写；
 *   stopPresent 恢复后可写（重发同 seq 成功）；
 * - follow / unfollow：目标收单播 {followerUserId}（无 ack）；发送者 / 旁观者静默；幽灵目标静默；
 * - 角色矩阵拒绝：Viewer 发 grantControl / startPresent / removeUser → {ok:false,reason:'forbidden'}
 *   且无任何广播扩散；
 * - removeUser：目标收 room:removed 单播 → 断开（io server disconnect）→ 他人收 left 广播；
 * - checkpoint：注入阈值量 op → 最早 Host/CoHost 候选（coach，自举 Host）收 board:checkpointRequest
 *   单播（后加入的 host（降级 CoHost）/ Participant / Viewer 不收）→ 照抄请求水位回传
 *   board:checkpoint{stateVector,payload} → 新连接 join（无 lastSeenVersion）→ board:joined.snapshot
 *   与上传内容一致（只存不解释）；
 * - 自举房（独立房间）：Participant 首入空房自举 Host → 达标时由自举 Host 承接 checkpointRequest，
 *   Viewer（非候选）静默。
 */

async function runM3Scenario() {
  const m3Board = boardId + '-m3';
  const m3BootstrapBoard = boardId + '-m3-boot';
  const coachId = 'e2e-m3-coach-' + stamp;
  const hostId = 'e2e-m3-host-' + stamp;
  const memberId = 'e2e-m3-member-' + stamp;
  const peerId = 'e2e-m3-peer-' + stamp;
  const presenterId = 'e2e-m3-presenter-' + stamp;
  const viewerId = 'e2e-m3-viewer-' + stamp;
  const newcomerId = 'e2e-m3-newcomer-' + stamp;
  const ckActor = 'e2e-m3-ck-' + stamp;
  const ncActor = 'e2e-m3-nc-' + stamp;
  const ncMemberId = 'e2e-m3-ncm-' + stamp;
  const ncViewerId = 'e2e-m3-ncv-' + stamp;
  const ckPayload = '<<m3-checkpoint-' + stamp + '>> "中文" 😀 {} [未解析·只存不解释]';

  // 0) 五身份连接 + 依次入房（coach 最先 → 房主自举 Host，即 checkpoint 最早候选；
  //    host 后入 → Host 冲突降级 CoHost）。
  //    checkpointRequest 收集器从最早期挂载，防小阈值下「提前触发」造成漏检。
  const coach = await connectRoleClient('M3-coach', 'CoHost', coachId);
  await joinRoom(coach, 'M3-coach', m3Board);
  const host = await connectRoleClient('M3-host', 'Host', hostId);
  await joinRoom(host, 'M3-host', m3Board);
  const member = await connectRoleClient('M3-member', 'Participant', memberId);
  await joinRoom(member, 'M3-member', m3Board);
  const presenter = await connectRoleClient('M3-presenter', 'Presenter', presenterId);
  await joinRoom(presenter, 'M3-presenter', m3Board);
  const viewer = await connectRoleClient('M3-viewer', 'Viewer', viewerId);
  const viewerJoin = await joinRoom(viewer, 'M3-viewer', m3Board);
  if (!Array.isArray(viewerJoin.participants) || viewerJoin.participants.length !== 5) {
    throw new Error('M3 房应含 5 名成员：' + JSON.stringify(viewerJoin.participants));
  }
  const ckRequests = collectEvents(coach.socket, 'board:checkpointRequest');
  const hostCkQuiet = collectEvents(host.socket, 'board:checkpointRequest');
  const memberCkQuiet = collectEvents(member.socket, 'board:checkpointRequest');
  emit({ milestone: 'm3-ready', participants: 5 });

  // 1) raiseHand / lowerHand（member）：他人收 updated 增量；发送者排除。
  const senderParticipants = collectEvents(member.socket, 'board:participants');
  const raisedOnCoach = until(
    coach.socket,
    'board:participants',
    (p) => Array.isArray(p?.updated) && p.updated.some((x) => x.userId === memberId && x.handRaised === true),
    15000,
    'coach 收 raiseHand updated(handRaised=true)',
  );
  const raiseAck = await emitAck(member.socket, 'interactive:raiseHand', {});
  assertEq(raiseAck?.ok, true, 'raiseHand 回执');
  await raisedOnCoach;

  const loweredOnCoach = until(
    coach.socket,
    'board:participants',
    (p) => Array.isArray(p?.updated) && p.updated.some((x) => x.userId === memberId && x.handRaised === false),
    15000,
    'coach 收 lowerHand updated(handRaised=false)',
  );
  const lowerAck = await emitAck(member.socket, 'interactive:lowerHand', {});
  assertEq(lowerAck?.ok, true, 'lowerHand 回执');
  await loweredOnCoach;

  await sleep(150);
  const senderHandEcho = senderParticipants.calls.filter(
    ([p]) => Array.isArray(p?.updated) && p.updated.some((x) => x.userId === memberId),
  ).length;
  senderParticipants.stop();
  assertEq(senderHandEcho, 0, '发送者不应收到自己的 handRaised 更新（排除发送者）');
  emit({ milestone: 'm3-raise-hand', raised: true, lowered: true, senderExcluded: true });

  // 2) grantControl / revokeControl（coach → peer，本题专用 Participant）：目标收 roleChanged
  //    单播；他人收 updated 广播。2026-10 默认无权限：revoke 仅清 grantedWrite、角色不变——
  //    收权后与「后加入未授权」完全等效（free/present 均即时只读、发 op 被拒）、
  //    需重新 grant 才能编辑（present 收窄场景仍由全程未被收权的 member 原样验证）。
  const peer = await connectRoleClient('M3-peer', 'Participant', peerId);
  await joinRoom(peer, 'M3-peer', m3Board);
  const hostRoleQuiet = collectEvents(host.socket, 'interactive:roleChanged');
  const grantedOnHost = until(
    host.socket,
    'board:participants',
    (p) => Array.isArray(p?.updated) && p.updated.some((x) => x.userId === peerId && x.grantedWrite === true),
    15000,
    'host 收 grantControl updated(grantedWrite=true)',
  );
  const grantAck = await emitAck(coach.socket, 'interactive:grantControl', { userId: peerId });
  assertEq(grantAck?.ok, true, 'grantControl 回执');
  const roleChangedGranted = await until(
    peer.socket,
    'interactive:roleChanged',
    (p) => p?.userId === peerId && p?.grantedWrite === true,
    15000,
    'peer 收 roleChanged 单播(grantedWrite=true)',
  );
  assertEq(roleChangedGranted[0]?.role, 'Participant', 'grantControl 不改变 role');
  const grantedPayload = (await grantedOnHost)[0];
  assertEq(
    grantedPayload.updated.find((x) => x.userId === peerId)?.role,
    'Participant',
    'grantedWrite 不改变 role（updated）',
  );

  const revokedOnHost = until(
    host.socket,
    'board:participants',
    (p) => Array.isArray(p?.updated)
      && p.updated.some((x) => x.userId === peerId && x.grantedWrite === false && x.role === 'Participant'),
    15000,
    'host 收 revokeControl updated(grantedWrite=false, role=Participant)',
  );
  const revokeAck = await emitAck(coach.socket, 'interactive:revokeControl', { userId: peerId });
  assertEq(revokeAck?.ok, true, 'revokeControl 回执');
  const roleChangedRevoked = await until(
    peer.socket,
    'interactive:roleChanged',
    (p) => p?.userId === peerId && p?.grantedWrite === false,
    15000,
    'peer 收 roleChanged 单播(grantedWrite=false)',
  );
  assertEq(roleChangedRevoked[0]?.role, 'Participant', 'revokeControl 不改变角色（roleChanged）');
  await revokedOnHost;
  await sleep(150);
  assertEq(hostRoleQuiet.calls.length, 0, 'roleChanged 应单播目标，不应发给他人');
  hostRoleQuiet.stop();

  // 2.1) 收权后 free 态拒写（2026-10 默认无权限：未授权即只读）：peer 发 op 被拒
  //      （Forbidden + room:error），无广播扩散。
  const peerDeniedError = until(
    peer.socket,
    'room:error',
    (p) => p?.code === 'Forbidden',
    15000,
    'revoke 后 peer 收 room:error(Forbidden)',
  );
  const hostPeerOpQuiet = collectEvents(host.socket, 'board:ops');
  const revokedOpAck = await emitAck(peer.socket, 'board:ops', [
    mkOp(peerId, 1, 'el:m3-peer-' + stamp + ':data', { id: 'm3-peer', n: 1 }),
  ]);
  assertEq(revokedOpAck?.ok, false, 'revoke 后 free 态 peer 发 op 应被拒（未授权）');
  assertEq(revokedOpAck?.error?.code, 'Forbidden', 'revoke 被拒错误码');
  await peerDeniedError;
  await sleep(200);
  assertEq(hostPeerOpQuiet.calls.length, 0, 'revoke 后被拒 op 不应广播');
  hostPeerOpQuiet.stop();
  emit({
    milestone: 'm3-grant',
    granted: true,
    revoked: true,
    roleChanged: true,
    updated: true,
    revokedDenied: true,
  });

  // 3) startPresent（coach）：广播 modeChanged{present,presenterId}；发起者排除。
  const coachModeEcho = collectEvents(coach.socket, 'interactive:modeChanged');
  const presentStarted = until(
    member.socket,
    'interactive:modeChanged',
    (p) => p?.mode === 'present' && p?.presenterId === coachId,
    15000,
    'member 收 modeChanged(present)',
  );
  const startAck = await emitAck(coach.socket, 'interactive:startPresent', {});
  assertEq(startAck?.ok, true, 'startPresent 回执');
  const presentPayload = (await presentStarted)[0];
  assertEq(presentPayload?.by, coachId, 'modeChanged.by（present）');

  // 4) present 收窄：Participant 发 op 被拒（Forbidden + room:error），无广播扩散。
  const memberRoomError = until(
    member.socket,
    'room:error',
    (p) => p?.code === 'Forbidden',
    15000,
    'present 下 member 收 room:error(Forbidden)',
  );
  const hostOpsQuiet = collectEvents(host.socket, 'board:ops');
  const deniedOp = mkOp(memberId, 1, 'el:m3-denied-' + stamp + ':data', { id: 'm3-denied', n: 1 });
  const deniedOpAck = await emitAck(member.socket, 'board:ops', [deniedOp]);
  assertEq(deniedOpAck?.ok, false, 'present 下 Participant 发 op 应被拒');
  assertEq(deniedOpAck?.error?.code, 'Forbidden', '拒绝错误码');
  await memberRoomError;
  await sleep(200);
  assertEq(hostOpsQuiet.calls.length, 0, '被拒 op 不应广播');
  hostOpsQuiet.stop();

  // 5) present 态下 Presenter 仍可写：发 op 成功，host 收到广播。
  const presenterOpSeen = until(
    host.socket,
    'board:ops',
    (ops) => Array.isArray(ops) && ops.some((o) => o.actor === presenterId && o.seq === 1),
    15000,
    'host 收 present 态 presenter 的 op',
  );
  await emitOps(presenter, [mkOp(presenterId, 1, 'el:m3-presenter-' + stamp + ':data', { id: 'm3-presenter', n: 1 })]);
  await presenterOpSeen;

  // 6) stopPresent（presenter 发起）：广播 modeChanged{free}；coach 的 start 不回显（发起者排除）。
  const presentStopped = until(
    member.socket,
    'interactive:modeChanged',
    (p) => p?.mode === 'free' && p?.by === presenterId,
    15000,
    'member 收 modeChanged(free)',
  );
  const stopAck = await emitAck(presenter.socket, 'interactive:stopPresent', {});
  assertEq(stopAck?.ok, true, 'stopPresent 回执');
  await presentStopped;
  await sleep(150);
  const coachStartEcho = coachModeEcho.calls.filter(([p]) => p?.mode === 'present').length;
  coachModeEcho.stop();
  assertEq(coachStartEcho, 0, 'startPresent 发起者不应收到自己的 modeChanged（排除发送者）');

  // 7) stopPresent 后 member（未授权 Participant）仍只读：重发被拒的 seq1 op → 仍被拒
  //    （2026-10 默认无权限）→ coach 授权 member（grantedWrite）→ 重发成功（写路径经授权恢复）。
  const memberDeniedAgain = await emitAck(member.socket, 'board:ops', [deniedOp]);
  assertEq(memberDeniedAgain?.ok, false, 'stopPresent 后未授权 member 发 op 仍应被拒');
  assertEq(memberDeniedAgain?.error?.code, 'Forbidden', '授权前被拒错误码');

  const memberGrantSeen = until(
    member.socket,
    'interactive:roleChanged',
    (p) => p?.userId === memberId && p?.grantedWrite === true,
    15000,
    'member 收 roleChanged 单播(grantedWrite=true)',
  );
  const memberGrantAck = await emitAck(coach.socket, 'interactive:grantControl', { userId: memberId });
  assertEq(memberGrantAck?.ok, true, 'coach 授权 member 回执');
  await memberGrantSeen;

  const memberOpSeen = until(
    coach.socket,
    'board:ops',
    (ops) => Array.isArray(ops) && ops.some((o) => o.actor === memberId && o.seq === 1),
    15000,
    'coach 收授权后 member 的 op（恢复可写）',
  );
  await emitOps(member, [deniedOp]);
  await memberOpSeen;
  emit({
    milestone: 'm3-present',
    started: true,
    deniedForbidden: true,
    presenterWritable: true,
    stopped: true,
    recovered: true,
  });

  // 8) follow / unfollow（member → coach）：单播 {followerUserId}；无 ack；发送者 / 旁观者静默；
  //    幽灵目标（不在房）静默忽略。
  const coachFollows = collectEvents(coach.socket, 'interactive:follow');
  const coachUnfollows = collectEvents(coach.socket, 'interactive:unfollow');
  const senderFollowQuiet = collectEvents(member.socket, 'interactive:follow');
  const bystanderFollowQuiet = collectEvents(host.socket, 'interactive:follow');

  const coachFollowSeen = until(
    coach.socket,
    'interactive:follow',
    (p) => p?.followerUserId === memberId,
    15000,
    'coach 收 follow(followerUserId)',
  );
  let followAck = null;
  member.socket.emit('interactive:follow', { targetUserId: coachId }, (ack) => {
    followAck = ack;
  });
  const followPayload = (await coachFollowSeen)[0];
  assertEq(followPayload?.followerUserId, memberId, 'follow 载荷');

  const coachUnfollowSeen = until(
    coach.socket,
    'interactive:unfollow',
    (p) => p?.followerUserId === memberId,
    15000,
    'coach 收 unfollow(followerUserId)',
  );
  member.socket.emit('interactive:unfollow', { targetUserId: coachId });
  const unfollowPayload = (await coachUnfollowSeen)[0];
  assertEq(unfollowPayload?.followerUserId, memberId, 'unfollow 载荷');

  member.socket.emit('interactive:follow', { targetUserId: 'ghost-' + stamp });
  await sleep(350);
  assertEq(followAck, null, 'follow 不应有 ack');
  assertEq(coachFollows.calls.length, 1, '幽灵目标不应触发 follow 转发');
  assertEq(coachUnfollows.calls.length, 1, 'unfollow 应单播一次');
  assertEq(senderFollowQuiet.calls.length, 0, 'follow 发送者不应收到转发');
  assertEq(bystanderFollowQuiet.calls.length, 0, '旁观者不应收到 follow（单播目标）');
  coachFollows.stop();
  coachUnfollows.stop();
  senderFollowQuiet.stop();
  bystanderFollowQuiet.stop();
  emit({ milestone: 'm3-follow', followed: true, unfollowed: true, noAck: true, quiet: true });

  // 9) 角色矩阵拒绝（Viewer 发管理动作）：{ok:false,reason:'forbidden'} 且无广播扩散。
  const hostSpreadQuiet = {
    updated: collectEvents(host.socket, 'board:participants'),
    mode: collectEvents(host.socket, 'interactive:modeChanged'),
    role: collectEvents(host.socket, 'interactive:roleChanged'),
    removed: collectEvents(host.socket, 'room:removed'),
  };
  const memberRoleQuiet = collectEvents(member.socket, 'interactive:roleChanged');
  const memberRemovedQuiet = collectEvents(member.socket, 'room:removed');

  const viewerGrantDenied = await emitAck(viewer.socket, 'interactive:grantControl', { userId: memberId });
  assertEq(viewerGrantDenied?.ok, false, 'Viewer grantControl 应拒绝');
  assertEq(viewerGrantDenied?.reason, 'forbidden', 'Viewer grantControl reason');
  const viewerPresentDenied = await emitAck(viewer.socket, 'interactive:startPresent', {});
  assertEq(viewerPresentDenied?.ok, false, 'Viewer startPresent 应拒绝');
  assertEq(viewerPresentDenied?.reason, 'forbidden', 'Viewer startPresent reason');
  const viewerRemoveDenied = await emitAck(viewer.socket, 'interactive:removeUser', { userId: memberId });
  assertEq(viewerRemoveDenied?.ok, false, 'Viewer removeUser 应拒绝');
  assertEq(viewerRemoveDenied?.reason, 'forbidden', 'Viewer removeUser reason');

  await sleep(450);
  const hostUpdatedSpread = hostSpreadQuiet.updated.calls.filter(
    ([p]) => p && p.updated !== undefined,
  ).length;
  assertEq(hostUpdatedSpread, 0, 'Viewer 被拒操作不应扩散 participants updated');
  assertEq(hostSpreadQuiet.mode.calls.length, 0, 'Viewer 被拒操作不应扩散 modeChanged');
  assertEq(hostSpreadQuiet.role.calls.length, 0, 'Viewer 被拒操作不应扩散 roleChanged');
  assertEq(hostSpreadQuiet.removed.calls.length, 0, 'Viewer 被拒操作不应扩散 room:removed');
  assertEq(memberRoleQuiet.calls.length, 0, 'Viewer 被拒操作不应触发 member roleChanged');
  assertEq(memberRemovedQuiet.calls.length, 0, 'Viewer 被拒操作不应触发 member room:removed');
  emit({
    milestone: 'm3-role-matrix',
    viewerGrantDenied: true,
    viewerPresentDenied: true,
    viewerRemoveDenied: true,
    noSpread: true,
  });

  // 10) removeUser（host 踢 viewer）：room:removed 单播 → 断开（io server disconnect）→ left 广播。
  const viewerRemovedSeen = until(viewer.socket, 'room:removed', () => true, 15000, 'viewer 收 room:removed 单播');
  const viewerDisconnectSeen = waitDisconnect(viewer.socket, 15000, 'viewer 被服务端断开');
  const memberSeesViewerLeft = until(
    member.socket,
    'board:participants',
    (p) => Array.isArray(p?.left) && p.left.some((x) => x.userId === viewerId),
    15000,
    'member 收 viewer left 广播',
  );
  const removeAck = await emitAck(host.socket, 'interactive:removeUser', { userId: viewerId });
  assertEq(removeAck?.ok, true, 'Host removeUser 回执');
  const removedPayload = (await viewerRemovedSeen)[0];
  assertEq(removedPayload?.code, 'Removed', 'room:removed.code');
  assertEq(removedPayload?.reason, 'removed', 'room:removed.reason');
  const viewerDisconnectReason = await viewerDisconnectSeen;
  assertEq(viewerDisconnectReason, 'io server disconnect', 'viewer 断开原因');
  await memberSeesViewerLeft;
  await sleep(200);
  assertEq(memberRemovedQuiet.calls.length, 0, 'room:removed 应单播目标，不应扩散至 member');
  hostSpreadQuiet.updated.stop();
  hostSpreadQuiet.mode.stop();
  hostSpreadQuiet.role.stop();
  hostSpreadQuiet.removed.stop();
  memberRoleQuiet.stop();
  memberRemovedQuiet.stop();
  emit({ milestone: 'm3-remove-user', removed: true, disconnected: true, leftBroadcast: true });

  // 11) checkpoint 正例：注入阈值量 op → 最早 Host/CoHost 候选（coach，自举 Host）收
  //     checkpointRequest 单播 → 照抄请求水位上传 → 新连接 join（无 lastSeenVersion）→ snapshot 一致。
  //     m3 房注入前累计已接受 op 恰为 2（presenter/member 各 1）；阈值 > 2 时请求必由注入触发。
  const ckOps = Array.from({ length: checkpointThreshold }, (_, index) =>
    mkOp(ckActor, index + 1, 'el:m3-ck-' + stamp + '-' + (index + 1) + ':data', { n: index + 1 }));
  await emitOps(host, ckOps);
  await waitUntil(
    () => ckRequests.calls.length >= 1,
    20000,
    'checkpointRequest 未到达（阈值 ' + checkpointThreshold + '）',
  );
  const requestPayload = ckRequests.calls[ckRequests.calls.length - 1][0];
  const byInjection =
    typeof requestPayload?.stateVector?.[ckActor] === 'number' && requestPayload.stateVector[ckActor] >= 1;
  if (checkpointThreshold > 2 && !byInjection) {
    throw new Error(
      'checkpointRequest.stateVector 应含注入 op 水位（ckActor≥1）；实际 ' + JSON.stringify(requestPayload?.stateVector),
    );
  }
  const uploadAck = await emitAck(coach.socket, 'board:checkpoint', {
    stateVector: requestPayload.stateVector,
    payload: ckPayload,
  });
  assertEq(uploadAck?.ok, true, 'checkpoint 上传回执');
  const newcomer = await connectRoleClient('M3-newcomer', 'Viewer', newcomerId);
  const newcomerJoin = await joinRoom(newcomer, 'M3-newcomer', m3Board); // 无 lastSeenVersion → snapshot 路径
  if (!newcomerJoin.snapshot) {
    throw new Error('新成员 join 应下发 snapshot（checkpoint 已存储）');
  }
  assertEq(newcomerJoin.snapshot.payload, ckPayload, 'snapshot.payload 应字节原样（只存不解释）');
  assertVectorEq(newcomerJoin.snapshot.stateVector, requestPayload.stateVector, 'snapshot.stateVector');
  await sleep(250);
  assertEq(hostCkQuiet.calls.length, 0, '后加入的 host（降级 CoHost）不应收到 checkpointRequest（单播最早 Host/CoHost）');
  assertEq(memberCkQuiet.calls.length, 0, 'Participant 不应收到 checkpointRequest');
  emit({ milestone: 'm3-checkpoint', requested: true, singleCast: true, snapshotMatches: true, byInjection });

  // 12) checkpoint 自举房：Participant 首入空房 → 自举 Host 承接请求；Viewer（非候选）静默。
  const ncMember = await connectRoleClient('M3-boot-member', 'Participant', ncMemberId);
  const bootMemberJoin = await joinRoom(ncMember, 'M3-boot-member', m3BootstrapBoard);
  if (bootMemberJoin.role !== 'Host') {
    throw new Error('自举房内首位可写角色应升 Host：' + JSON.stringify(bootMemberJoin.role));
  }
  const ncViewer = await connectRoleClient('M3-boot-viewer', 'Viewer', ncViewerId);
  await joinRoom(ncViewer, 'M3-boot-viewer', m3BootstrapBoard);
  const ncMemberCk = collectEvents(ncMember.socket, 'board:checkpointRequest');
  const ncViewerCk = collectEvents(ncViewer.socket, 'board:checkpointRequest');
  const ncOps = Array.from({ length: checkpointThreshold }, (_, index) =>
    mkOp(ncActor, index + 1, 'el:m3-nc-' + stamp + '-' + (index + 1) + ':data', { n: index + 1 }));
  await emitOps(ncMember, ncOps);
  await waitUntil(
    () => ncMemberCk.calls.length >= 1,
    20000,
    '自举 Host 未承接 checkpointRequest（阈值 ' + checkpointThreshold + '）',
  );
  const bootRequest = ncMemberCk.calls[ncMemberCk.calls.length - 1][0];
  if (typeof bootRequest?.stateVector?.[ncActor] !== 'number' || bootRequest.stateVector[ncActor] < 1) {
    throw new Error(
      '自举 Host 的 checkpointRequest.stateVector 应含注入水位（ncActor≥1）：'
        + JSON.stringify(bootRequest?.stateVector),
    );
  }
  await sleep(300);
  assertEq(ncViewerCk.calls.length, 0, 'Viewer（非候选）不应收到 checkpointRequest');
  ncMemberCk.stop();
  ncViewerCk.stop();
  emit({ milestone: 'm3-checkpoint-bootstrapped', requested: true, viewerQuiet: true });

  // 收尾：停止早期收集器并断开 M3 全部连接（viewer 已被服务端断开）。
  ckRequests.stop();
  hostCkQuiet.stop();
  memberCkQuiet.stop();
  coach.socket.disconnect();
  host.socket.disconnect();
  member.socket.disconnect();
  presenter.socket.disconnect();
  peer.socket.disconnect();
  newcomer.socket.disconnect();
  ncMember.socket.disconnect();
  ncViewer.socket.disconnect();
}
