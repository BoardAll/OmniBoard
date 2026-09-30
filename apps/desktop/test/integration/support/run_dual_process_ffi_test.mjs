// T1.6 双进程「双开等价」集成测试协调脚本。
//
// 步骤：
// 1) 启动本地 realtime（node dist/server.js，PORT=默认 18792）；
// 2) 启动接收端 flutter test 进程（WB_DUAL_ROLE=receiver，真实 DLL）；
// 3) 等接收端就绪信号文件出现（join 已被服务端 board:joined 确认）；
// 4) 启动发送端 flutter test 进程（WB_DUAL_ROLE=sender）并等其退出；
// 5) 等接收端退出——收到对端 op 才算端到端闭环；
// 6) 两个 exit code 均为 0 → PASS；最后清理全部子进程与信号文件。
//
// 用法（任意 cwd，Windows）：
//   node apps/desktop/test/integration/support/run_dual_process_ffi_test.mjs
// 环境变量：WB_FLUTTER_BAT 覆盖 flutter 可执行路径（默认本机 SDK 路径）、
// WB_DUAL_PORT 覆盖端口（默认 18792）。
// 注意：flutter.bat / node 均可经 cmd 启动，故 spawn 需 shell: true；
// 终止用 taskkill /T 整树（flutter.bat → dart → flutter_tester）。
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import http from 'node:http';

const here = dirname(fileURLToPath(import.meta.url)); // test/integration/support
const desktop = resolve(here, '..', '..', '..'); // apps/desktop
const repo = resolve(desktop, '..', '..'); // 仓库根
const realtimeDir = join(repo, 'services', 'realtime');
const flutterBat =
  process.env.WB_FLUTTER_BAT ?? 'E:/code/flutter-sdk/flutter/bin/flutter.bat';
const port = process.env.WB_DUAL_PORT ?? '18792';
const endpoint = 'http://127.0.0.1:' + port;
const stamp = String(Date.now());
const boardId = 'dual-' + stamp;
const elementId = 'dual-el-' + stamp;
const flagPath = join(desktop, '.dart_tool', 'wb_t16_dual_' + stamp + '.flag');
const testFile = 'test/integration/ffi_sync_dual_process_test.dart';

const children = [];

function log(msg) {
  console.log('[dual] ' + msg);
}

function track(child) {
  children.push(child);
  return child;
}

function killTree(pid) {
  if (!pid) {
    return;
  }
  spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], {
    stdio: 'ignore',
  });
}

function pipePrefixed(child, name) {
  const tag = '[' + name + '] ';
  const hook = (stream) => {
    stream.setEncoding('utf8');
    stream.on('data', (chunk) => {
      process.stdout.write(tag + chunk);
    });
  };
  if (child.stdout) {
    hook(child.stdout);
  }
  if (child.stderr) {
    hook(child.stderr);
  }
}

function sleep(ms) {
  return new Promise((done) => setTimeout(done, ms));
}

function waitFlag(path, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((done) => {
    const attempt = () => {
      if (existsSync(path)) {
        return done(true);
      }
      if (Date.now() > deadline) {
        return done(false);
      }
      setTimeout(attempt, 250);
    };
    attempt();
  });
}

function waitExit(child, timeoutMs) {
  if (child.exitCode !== null) {
    return Promise.resolve({ exited: true, code: child.exitCode });
  }
  return new Promise((done) => {
    const timer = setTimeout(() => done({ exited: false, code: null }), timeoutMs);
    child.on('exit', (code) => {
      clearTimeout(timer);
      done({ exited: true, code });
    });
  });
}

function waitHttp(url, timeoutMs) {
  return new Promise((done) => {
    const deadline = Date.now() + timeoutMs;
    let settled = false;
    const finish = (ok) => {
      if (!settled) {
        settled = true;
        done(ok);
      }
    };
    const attempt = () => {
      if (Date.now() > deadline) {
        return finish(false);
      }
      http
        .get(url, (res) => {
          res.resume();
          if (res.statusCode === 200) {
            finish(true);
          } else {
            setTimeout(attempt, 250);
          }
        })
        .on('error', () => setTimeout(attempt, 250));
    };
    attempt();
  });
}

function spawnFlutterTest(role, env) {
  return spawn(flutterBat, ['test', testFile, '--no-pub'], {
    cwd: desktop,
    env: { ...process.env, ...env, WB_DUAL_ROLE: role },
    shell: true,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

let receiverCode = null;
let senderCode = null;

try {
  // 1) 本地 realtime 服务端。
  log('realtime on :' + port + ' (' + realtimeDir + ')');
  const server = track(
    spawn('node', ['dist/server.js'], {
      cwd: realtimeDir,
      env: { ...process.env, PORT: port },
      shell: true,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    }),
  );
  pipePrefixed(server, 'realtime');
  if (!(await waitHttp(endpoint + '/healthz', 30000))) {
    throw new Error('realtime /healthz 30s 未就绪');
  }

  const baseEnv = {
    WB_REALTIME_E2E: '1',
    WB_REQUIRE_CORE_DLL: '1',
    WB_DUAL_BOARD: boardId,
    WB_DUAL_ELEMENT: elementId,
    WB_DUAL_FLAG: flagPath,
    WB_DUAL_ENDPOINT: endpoint,
  };

  // 2) 接收端（真实 DLL 引擎）。
  rmSync(flagPath, { force: true });
  log('receiver: flutter test（board=' + boardId + '）');
  const receiver = track(spawnFlutterTest('receiver', baseEnv));
  pipePrefixed(receiver, 'receiver');

  // 3) 等接收端 join 确认信号。
  const flagOk = await waitFlag(flagPath, 300000);
  if (!flagOk) {
    throw new Error('接收端 300s 内未写出就绪信号（flag=' + flagPath + '）');
  }
  log('receiver ready（join 已服务端确认），启动 sender');

  // 4) 发送端（真实 DLL 引擎）。
  const sender = track(spawnFlutterTest('sender', baseEnv));
  pipePrefixed(sender, 'sender');
  const senderExit = await waitExit(sender, 600000);
  if (!senderExit.exited) {
    throw new Error('发送端 600s 未退出');
  }
  senderCode = senderExit.code;
  log('sender 退出 code=' + senderCode);

  // 5) 等接收端收到对端 op 后退出。
  const receiverExit = await waitExit(receiver, 480000);
  if (!receiverExit.exited) {
    throw new Error('接收端 480s 未退出');
  }
  receiverCode = receiverExit.code;

  // 6) 汇总。
  if (receiverCode === 0 && senderCode === 0) {
    log('PASS：两个真实引擎进程经 realtime 端到端往返一致');
    process.exitCode = 0;
  } else {
    console.error(
      '[dual] FAIL：receiver=' + receiverCode + ' sender=' + senderCode,
    );
    process.exitCode = 1;
  }
} catch (err) {
  console.error('[dual] ERROR: ' + (err && err.message ? err.message : err));
  process.exitCode = 1;
} finally {
  for (const child of children) {
    killTree(child.pid);
  }
  rmSync(flagPath, { force: true });
  log('cleanup done');
}
