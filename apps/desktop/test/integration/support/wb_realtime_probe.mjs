// T1.6 真连集成测试对端探针（node）：加入 board 房间、抓取 board:ops 广播，
// 并回发一条 op 验证反向链路（服务端广播 → 桌面引擎 events）。
//
// 用法：node wb_realtime_probe.mjs <realtimeDir> <endpoint> <boardId> <timeoutMs>
// 输出（stdout 每行一条 JSON；诊断走 stderr）：
//   {"ready":true}                           join 成功，等待广播
//   {"ok":true,"ops":[...],"meta":{...},"echoId":"..."}  收到广播（并已回发 echo）
//   {"ok":false,"reason":"..."}              失败 / 超时
import { createRequire } from 'node:module';
import { join } from 'node:path';

const NL = String.fromCharCode(10);

const args = process.argv.slice(2);
const realtimeDir = args[0];
const endpoint = args[1];
const boardId = args[2];
const timeoutMs = Number(args[3] || 15000);

let done = false;
let timer = null;

function finish(payload, exitCode) {
  if (done) return;
  done = true;
  if (timer !== null) clearTimeout(timer);
  process.stdout.write(JSON.stringify(payload) + NL);
  setTimeout(() => process.exit(exitCode), 30);
}

timer = setTimeout(() => {
  finish({ ok: false, reason: 'timeout waiting for board:ops after ' + timeoutMs + 'ms' }, 2);
}, timeoutMs);

let socketFactory = null;
try {
  const require = createRequire(join(realtimeDir, 'package.json'));
  socketFactory = require('socket.io-client').io;
} catch (err) {
  finish({ ok: false, reason: 'socket.io-client resolve failed: ' + err.message }, 4);
}

if (socketFactory !== null) {
  const socket = socketFactory(endpoint + '/board', {
    transports: ['websocket'],
    reconnection: false,
  });
  socket.on('connect', () => {
    socket.emit('board:join', { boardId }, (ack) => {
      if (!ack || ack.ok !== true) {
        finish({ ok: false, reason: 'join failed: ' + JSON.stringify(ack ?? null) }, 3);
        return;
      }
      process.stdout.write(JSON.stringify({ ready: true }) + NL);
    });
  });
  socket.on('board:ops', (ops, meta) => {
    // 回发一条 op：验证反向（服务端 → 桌面引擎 events drain）链路。
    const echoId = 'probe-note-' + Date.now().toString(36);
    const echo = {
      actor: 'probe-actor-' + Date.now().toString(36),
      seq: 1,
      key: 'el:' + echoId + ':data',
      value: {
        id: echoId,
        type: 'note',
        position: { x: 8, y: 8 },
        size: { width: 120, height: 80 },
      },
      timestamp: Date.now(),
      origin: 'remote',
    };
    socket.emit('board:ops', [echo], (ack) => {
      if (!ack || ack.ok !== true) {
        process.stderr.write('probe echo rejected: ' + JSON.stringify(ack ?? null) + NL);
      }
    });
    finish({ ok: true, ops, meta, echoId }, 0);
  });
  socket.on('connect_error', (err) => {
    finish({ ok: false, reason: 'connect_error: ' + err.message }, 5);
  });
}
