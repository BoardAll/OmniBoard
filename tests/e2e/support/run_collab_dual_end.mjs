// tests/e2e 「双端互见」M1 场景编排（骨架版；对应《互动白板实时协同开发计划》
// §4「e2e：tests/e2e 新增"双端互见"场景（可复用 fixture 板）」与门 G1）。
//
// 场景步骤 → 可执行段映射：
//   server  : 启动 realtime（默认 :8790）并等 /healthz；
//   desktop : 桌面端参与者 ×2 —— 双进程真连等价物（复用 T1.6 资产
//             apps/desktop/test/integration/ffi_sync_dual_process_test.dart）：
//             接收端 join 确认 → 发送端落定提交插入 op → 接收端断言送达
//             （经真实服务端全程闭环；单进程引擎为进程级单例，故用两进程等价）；
//   ops     : 互见 op 矩阵（插入/移动/删除/文本终态）+ 断线重连恢复
//             （契约级探针 support/wb_collab_scenario_probe.mjs，同一真实服务）；
//   web     : Web 参与者 —— W1 浏览器真连冒烟（复用 T1.8 资产
//             apps/web/test/realtime_web_smoke_test.dart：成员/状态互见；
//             需 Chrome/Edge，缺浏览器 = SKIP，见 docs/modules/18）。
//
// 用法（任意 cwd，Windows）：
//   node tests/e2e/support/run_collab_dual_end.mjs                    # 全量
//   node tests/e2e/support/run_collab_dual_end.mjs --only=server,ops  # 分段执行
//   node tests/e2e/support/run_collab_dual_end.mjs --only=web --reuse-server
//   node tests/e2e/support/run_collab_dual_end.mjs --list             # 查看段说明
// 环境变量：
//   WB_E2E_PORT     覆盖 realtime 端口（默认 8790）；
//   WB_FLUTTER_BAT  覆盖 flutter 可执行路径（默认本机 SDK 路径）；
//   CHROME_EXECUTABLE / 常见 Chrome/Edge 安装路径 用于 web 段。
// 退出码：0 = 全部执行段 PASS（SKIP 段计入但不算失败）；1 = 任意段 FAIL / 编排错误。
// 前置：services/realtime 已 `npm run build`；desktop 段需已构建 wb_core.dll
// （tools/scripts/build_cpp.ps1）；Node ≥ 18。
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import http from 'node:http';

const here = dirname(fileURLToPath(import.meta.url)); // tests/e2e/support
const e2eDir = resolve(here, '..');
const repo = resolve(e2eDir, '..', '..');
const realtimeDir = join(repo, 'services', 'realtime');
const desktopDir = join(repo, 'apps', 'desktop');
const webDir = join(repo, 'apps', 'web');
const probeScript = join(here, 'wb_collab_scenario_probe.mjs');
const flutterBat =
  process.env.WB_FLUTTER_BAT ?? 'E:/code/flutter-sdk/flutter/bin/flutter.bat';
const port = process.env.WB_E2E_PORT ?? '8790';
const endpoint = 'http://127.0.0.1:' + port;
const stamp = String(Date.now());

const SEGMENTS = new Map([
  ['server', '启动 realtime（:' + port + '）并等 /healthz'],
  ['desktop', '桌面参与者 ×2：双进程真连（T1.6 等价物，插入 op 端到端）'],
  ['ops', '互见 op 矩阵（插入/移动/删除/文本终态）+ 断线重连恢复（契约探针）'],
  ['web', 'Web 参与者：W1 浏览器真连冒烟（T1.8；缺浏览器 = SKIP）'],
]);

const args = process.argv.slice(2);
const onlyArg = args.find((a) => a.startsWith('--only='));
const reuseServer = args.includes('--reuse-server');
const listMode = args.includes('--list');
const selected = onlyArg
  ? onlyArg
      .slice('--only='.length)
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean)
  : ['server', 'desktop', 'ops', 'web'];

const children = [];
const results = [];
let flagPath = null;

const log = (msg) => console.log('[scenario] ' + msg);

function track(child) {
  children.push(child);
  return child;
}

function killTree(pid) {
  if (!pid) return;
  spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' });
}

function pipePrefixed(child, name) {
  const tag = '[' + name + '] ';
  for (const stream of [child.stdout, child.stderr]) {
    if (!stream) continue;
    stream.setEncoding('utf8');
    stream.on('data', (chunk) => process.stdout.write(tag + chunk));
  }
}

function waitFlag(path, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((done) => {
    const attempt = () => {
      if (existsSync(path)) return done(true);
      if (Date.now() > deadline) return done(false);
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
      if (Date.now() > deadline) return finish(false);
      http
        .get(url, (res) => {
          res.resume();
          if (res.statusCode === 200) return finish(true);
          setTimeout(attempt, 250);
        })
        .on('error', () => setTimeout(attempt, 250));
    };
    attempt();
  });
}

function spawnFlutterTest(dir, argsList, name, extraEnv = {}) {
  const child = spawn(flutterBat, argsList, {
    cwd: dir,
    env: { ...process.env, ...extraEnv },
    shell: true,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  pipePrefixed(child, name);
  return track(child);
}

function findBrowser() {
  const candidates = [
    process.env.CHROME_EXECUTABLE,
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
  ].filter(Boolean);
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function preflight() {
  if (!existsSync(join(realtimeDir, 'dist', 'server.js'))) {
    throw new Error('services/realtime/dist/server.js 不存在：先 cd services/realtime && npm run build');
  }
  if (selected.includes('desktop')) {
    const dll = join(repo, 'build', 'windows-x64', 'bin', 'Release', 'wb_core.dll');
    if (!existsSync(dll)) {
      throw new Error('wb_core.dll 未构建：先执行 tools/scripts/build_cpp.ps1（或跳过 desktop 段）');
    }
  }
  if ((selected.includes('desktop') || selected.includes('web')) && !existsSync(flutterBat)) {
    throw new Error('flutter 可执行未找到（' + flutterBat + '）：设置 WB_FLUTTER_BAT');
  }
  if (selected.includes('ops') && !existsSync(probeScript)) {
    throw new Error('缺少场景探针：' + probeScript);
  }
}

async function startServer() {
  log('server: node dist/server.js（PORT=' + port + '）');
  const server = spawn('node', ['dist/server.js'], {
    cwd: realtimeDir,
    env: { ...process.env, PORT: port },
    shell: true,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  pipePrefixed(server, 'realtime');
  track(server);
  if (!(await waitHttp(endpoint + '/healthz', 30000))) {
    throw new Error('realtime /healthz 30s 未就绪（端口 ' + port + ' 被占用或构建过期？）');
  }
  log('server: /healthz ok');
}

async function runDesktop() {
  const boardId = 'e2e-m1-desktop-' + stamp;
  const elementId = 'e2e-m1-el-' + stamp;
  flagPath = join(desktopDir, '.dart_tool', 'wb_m1_scenario_' + stamp + '.flag');
  rmSync(flagPath, { force: true });
  const baseEnv = {
    WB_REALTIME_E2E: '1',
    WB_REQUIRE_CORE_DLL: '1',
    WB_DUAL_BOARD: boardId,
    WB_DUAL_ELEMENT: elementId,
    WB_DUAL_FLAG: flagPath,
    WB_DUAL_ENDPOINT: endpoint,
  };

  log('desktop: receiver 启动（board=' + boardId + '）');
  const receiver = spawnFlutterTest(
    desktopDir,
    ['test', 'test/integration/ffi_sync_dual_process_test.dart', '--no-pub'],
    'desktop-receiver',
    { ...baseEnv, WB_DUAL_ROLE: 'receiver' },
  );
  if (!(await waitFlag(flagPath, 300000))) {
    throw new Error('desktop: 接收端 300s 内未写就绪信号（flag=' + flagPath + '）');
  }
  log('desktop: receiver join 已服务端确认，启动 sender');

  const sender = spawnFlutterTest(
    desktopDir,
    ['test', 'test/integration/ffi_sync_dual_process_test.dart', '--no-pub'],
    'desktop-sender',
    { ...baseEnv, WB_DUAL_ROLE: 'sender' },
  );
  const senderExit = await waitExit(sender, 600000);
  if (!senderExit.exited || senderExit.code !== 0) {
    throw new Error('desktop: sender 未通过（exited=' + senderExit.exited + ' code=' + senderExit.code + '）');
  }
  const receiverExit = await waitExit(receiver, 480000);
  if (!receiverExit.exited || receiverExit.code !== 0) {
    throw new Error('desktop: receiver 未通过（exited=' + receiverExit.exited + ' code=' + receiverExit.code + '）');
  }
}

async function runOps() {
  const boardId = 'e2e-m1-ops-' + stamp;
  log('ops: 运行契约级场景探针（board=' + boardId + '）');
  const probe = track(
    spawn('node', [probeScript, realtimeDir, endpoint, boardId, '60000'], {
      cwd: repo,
      shell: true,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    }),
  );
  const milestones = [];
  let finalPayload = null;
  let stderrTail = '';
  probe.stdout.setEncoding('utf8');
  probe.stdout.on('data', (chunk) => {
    for (const line of String(chunk).split(/\r?\n/)) {
      if (!line.trim()) continue;
      try {
        const msg = JSON.parse(line);
        if (msg.milestone) {
          milestones.push(msg);
          log('ops: milestone ' + JSON.stringify(msg));
        }
        if (msg.ok !== undefined) finalPayload = msg;
      } catch (_) {
        log('ops: ' + line);
      }
    }
  });
  probe.stderr.setEncoding('utf8');
  probe.stderr.on('data', (chunk) => {
    stderrTail += chunk;
    process.stderr.write('[ops-probe] ' + chunk);
  });
  const exit = await waitExit(probe, 120000);
  if (!exit.exited || exit.code !== 0 || !finalPayload || finalPayload.ok !== true) {
    throw new Error(
      'ops: 探针未通过（exited=' + exit.exited + ' code=' + exit.code + '）'
        + (finalPayload ? ' ' + JSON.stringify(finalPayload) : '')
        + (stderrTail ? ' stderr 尾部：' + stderrTail.slice(-400) : ''),
    );
  }
  return '里程碑：' + milestones.map((m) => m.milestone).join(' → ');
}

async function runWeb() {
  const browser = findBrowser();
  if (!browser) {
    log('web: SKIP — 未找到 Chrome/Edge（设置 CHROME_EXECUTABLE 后重跑 --only=web）');
    return { status: 'SKIP', note: '未找到浏览器（设置 CHROME_EXECUTABLE 或安装 Chrome/Edge）' };
  }
  log('web: 浏览器 ' + browser);
  const smoke = spawnFlutterTest(
    webDir,
    [
      'test',
      '--no-pub',
      '--platform',
      'chrome',
      '--dart-define=WB_REALTIME_ENDPOINT=' + endpoint,
      'test/realtime_web_smoke_test.dart',
    ],
    'web-smoke',
    { CHROME_EXECUTABLE: browser },
  );
  const exit = await waitExit(smoke, 600000);
  if (!exit.exited || exit.code !== 0) {
    throw new Error('web: 浏览器冒烟未通过（exited=' + exit.exited + ' code=' + exit.code + '）');
  }
  return 'W1 成员/状态互见（浏览器真连）';
}

async function runSegment(name, fn) {
  try {
    const note = await fn();
    if (note && typeof note === 'object' && note.status === 'SKIP') {
      results.push({ segment: name, status: 'SKIP', note: note.note });
      return;
    }
    results.push({ segment: name, status: 'PASS', note: typeof note === 'string' ? note : '' });
  } catch (err) {
    const message = err && err.message ? err.message : String(err);
    console.error('[scenario] FAIL ' + name + ': ' + message);
    results.push({ segment: name, status: 'FAIL', note: message });
  }
}

function printSegments() {
  console.log('M1「双端互见」场景段：');
  for (const [name, desc] of SEGMENTS) {
    console.log('  ' + name.padEnd(8) + ' ' + desc);
  }
}

function summarize() {
  console.log('');
  console.log('---- M1「双端互见」场景结果（' + new Date().toISOString().slice(0, 10) + '）----');
  for (const r of results) {
    console.log('[' + r.status + '] ' + r.segment.padEnd(8) + ' ' + r.note);
  }
  const failed = results.some((r) => r.status === 'FAIL');
  const skipped = results.some((r) => r.status === 'SKIP');
  console.log(failed ? 'RESULT: FAIL' : 'RESULT: PASS' + (skipped ? '（含 SKIP）' : ''));
  return !failed;
}

async function main() {
  if (listMode || args.includes('--help')) {
    printSegments();
    return true;
  }
  for (const name of selected) {
    if (!SEGMENTS.has(name)) {
      throw new Error('未知段 "' + name + '"（可选：' + [...SEGMENTS.keys()].join(', ') + '）');
    }
  }
  preflight();

  if (reuseServer) {
    if (!(await waitHttp(endpoint + '/healthz', 8000))) {
      throw new Error('--reuse-server 但 ' + endpoint + '/healthz 不可达');
    }
    log('reuse-server: ' + endpoint + ' 可达');
  } else {
    await startServer();
  }

  if (selected.includes('server')) {
    results.push({
      segment: 'server',
      status: 'PASS',
      note: endpoint + (reuseServer ? '（复用外部实例）' : '（本脚本启动）'),
    });
  }
  if (selected.includes('desktop')) {
    await runSegment('desktop', async () => {
      await runDesktop();
      return 'A 发 B 收：插入 op 经真实服务端全程闭环';
    });
  }
  if (selected.includes('ops')) {
    await runSegment('ops', runOps);
  }
  if (selected.includes('web')) {
    await runSegment('web', runWeb);
  }
  return summarize();
}

let pass = false;
try {
  pass = await main();
} catch (err) {
  console.error('[scenario] ERROR: ' + (err && err.message ? err.message : err));
  pass = false;
} finally {
  for (const child of children) {
    killTree(child.pid);
  }
  if (flagPath) {
    rmSync(flagPath, { force: true });
  }
  log('cleanup done');
}
process.exitCode = pass ? 0 : 1;
