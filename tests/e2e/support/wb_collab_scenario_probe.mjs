// tests/e2e 「双端互见」M1 场景探针（socket.io 契约级，两个客户端同房间）。
//
// 覆盖（对齐《互动白板实时协同设计文档》§5.4/§5.12/§6 与 desktop 侧 op 契约
// `el:{id}:data` / `el:{id}:exists=false`）：
//   1. 成员互见：A/B 加入同一 board 房间，双方观测到彼此（participants 增量）；
//   2. op 矩阵：B 依次发「插入 → 移动 → 文本终态」三条 data op，A 按序收到并
//      核对各字段终值；
//   3. 断线重连恢复：A 断开（B 观测 left 增量）→ B 在 A 离线期间发删除 op
//      （`exists=false`）→ A 以 `lastSeenVersion={actor:3}` 重连，服务端回放
//      缺口感增量（seq4 删除）→ 恢复后 A 写自己的 op（写路径不崩）。
//
// 用法：node wb_collab_scenario_probe.mjs <realtimeDir> <endpoint> <boardId> <timeoutMs>
// 输出（stdout 每行一条 JSON；诊断走 stderr）：
//   {"milestone":"ready","participants":2}
//   {"milestone":"op-matrix","received":3}
//   {"milestone":"away"}
//   {"milestone":"recovered","replayed":1,"postWrite":true}
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
try {
  const require = createRequire(join(realtimeDir, 'package.json'));
  ioFactory = require('socket.io-client').io;
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

/** 连接并等待 board:session 身份单播。 */
async function connectClient(tag) {
  const socket = ioFactory(endpoint + '/board', {
    transports: ['websocket'],
    reconnection: false,
  });
  const [session] = await until(socket, 'board:session', () => true, 15000, tag + ' board:session');
  log(tag + ' connected userId=' + session.userId + ' authMode=' + session.authMode);
  return { socket, userId: session.userId };
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

async function emitOps(client, ops) {
  const ack = await emitAck(client.socket, 'board:ops', ops, 20000);
  if (!ack || ack.ok !== true) {
    throw new Error('board:ops 被拒：' + JSON.stringify(ack));
  }
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

  // 3) A 断线：B 观测 left 增量。
  const seesALeft = until(
    clientB.socket,
    'board:participants',
    (p) => Array.isArray(p?.left) && p.left.some((x) => x.userId === clientA.userId),
    15000,
    'B 观测 A 离开增量',
  );
  clientA.socket.disconnect();
  await seesALeft;
  emit({ milestone: 'away' });

  // 4) A 离线期间：B 发删除 op（seq4，exists=false）。
  await emitOps(clientB, [op(4, 'el:' + elementId + ':exists', false)]);

  // 5) A 断线重连：以 lastSeenVersion 请求裁差分，服务端回放 seq4。
  const clientA2 = await connectClient('A2');
  const replay = collectOps(
    clientA2.socket,
    [{ actor: bActor, seq: 4 }],
    15000,
    'A2 断线重连回放（差分补洞）',
  );
  const ackA2 = await emitAck(clientA2.socket, 'board:join', {
    boardId,
    lastSeenVersion: { [bActor]: 3 },
  });
  if (!ackA2 || ackA2.ok !== true) throw new Error('A2 join 失败：' + JSON.stringify(ackA2));
  const [deleteOp] = await replay;
  assertEq(deleteOp.key, 'el:' + elementId + ':exists', '回放删除 op key');
  assertEq(deleteOp.value, false, '回放删除 op value');

  // 6) 恢复后写路径：A2 发自己的 op，B 收到（不崩）。
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
  emit({ milestone: 'recovered', replayed: 1, postWrite: true });

  clientA2.socket.disconnect();
  clientB.socket.disconnect();
  finish({ ok: true }, 0);
}
