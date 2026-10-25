/**
 * 局域网投屏 WebRTC 闭环浏览器探针（Edge headless + CDP + fake camera）。
 *
 * 目标（对齐《局域网投屏功能完整开发 Prompt》阶段 4/5/6）：
 *  - 接收端：`/#/board/<id>?cast=1` → 自动建房 → 语义树读取四位投屏码；
 *  - 发送端：首页「输入投屏码」→ 输入码 → 选「摄像头」→「开始投屏」；
 *  - 媒体面：Chrome fake media device 提供真实视频轨，双方交换真实
 *    SDP / ICE（浏览器内 WebRTC，不经信令转发）；
 *  - 断言：接收端 `<video>` 的 videoWidth > 0 且 srcObject 含 video track、
 *    连接列表计数、单路结束后的浮层 / 渲染器清理。
 *
 * 依赖（与既有 P4/P5 探针一致）：
 *  - 静态托管 apps/web/build/web（默认 http://localhost:8090）；
 *  - realtime 服务已就绪且包含 /cast（默认 http://127.0.0.1:8790）。
 * 运行：`node tests/e2e/support/wb_web_cast_probe.mjs`
 * 可选环境变量：
 *  - WB_WEB_URL / WB_CAST_ENDPOINT：覆盖静态站点 / 信令地址；
 *  - WB_CAST_SENDERS：并发发送端数量（1–4，默认 1）；
 *  - WB_CAST_TEST_OVERFLOW=1：达到上限后第 5 路应被服务端拒绝；
 *  - WB_CAST_TEST_DISCONNECT=1：断开中间一路，验证其他路不受影响。
 * 输出：截图 + `=== WB_WEB_CAST_PROBE_RESULT ===` 后的 JSON；
 *      失败时 `=== WB_WEB_CAST_PROBE_ERROR ===` 且退出码 1。
 */

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const WebSocket = require('e:/code/whiteboard/services/realtime/node_modules/ws');

const EDGE = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const PORT = 9330 + Math.floor(Math.random() * 500);
// 默认用 127.0.0.1：Windows 上 localhost 可能先解析到 ::1，而静态服务仅监听 IPv4。
// 127.0.0.1 仍属安全上下文（getUserMedia 可用）。
const APP_BASE = process.env.WB_WEB_URL || 'http://127.0.0.1:8090';
const ENDPOINT = process.env.WB_CAST_ENDPOINT || 'http://127.0.0.1:8790';
const OUT_DIR = 'e:\\code\\whiteboard\\.agent_tmp';
const PROFILE_DIR = path.join(
  process.env.TEMP || 'C:\\Windows\\Temp',
  `wb-web-cast-profile-${Date.now().toString(36)}`,
);
const SENDERS = Math.max(1, Math.min(4, Number(process.env.WB_CAST_SENDERS || '1')));
const TEST_OVERFLOW = process.env.WB_CAST_TEST_OVERFLOW === '1';
const TEST_DISCONNECT = process.env.WB_CAST_TEST_DISCONNECT === '1';

const RX_BOARD = `e2e-cast-rx-${Date.now().toString(36)}`;
const RX_URL = `${APP_BASE}/#/board/${RX_BOARD}?name=${encodeURIComponent('投屏接收端')}&cast=1`;
const HOME_URL = `${APP_BASE}/#/`;

/** 投屏错误文案（对话框 / 浮层）关键字。 */
const ERROR_HINTS = [
  '请输入接收端显示的四位投屏码',
  '投屏码不存在或已失效',
  '接收端已达到最大投屏路数',
  '接收端暂时离线',
  '尝试次数过多',
  '发起投屏失败',
  '无法采集',
  '媒体采集失败',
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

let edgeProcess = null;

const result = {
  base: APP_BASE,
  endpoint: ENDPOINT,
  browser: '',
  sendersConfigured: SENDERS,
  receiver: {
    url: RX_URL,
    code: '',
    codeValid: false,
    labelsAtCode: [],
    waitingShown: false,
    connectedLabel: '',
    panelLabel: '',
    videoCount: 0,
    videos: [],
  },
  senders: [],
  overflow: { attempted: false, rejected: false, message: '' },
  disconnect: { target: '', receiverVideosAfter: -1, othersStillConnected: false },
  cleanup: {
    sendersEnded: 0,
    receiverVideosAfter: -1,
    waitingAgain: false,
    sessionClosed: false,
  },
  screenshots: [],
  notes: [],
  error: '',
};

function httpRequest(method, url) {
  return new Promise((resolve, reject) => {
    const req = http.request(url, { method }, (res) => {
      let body = '';
      res.on('data', (chunk) => (body += chunk));
      res.on('end', () => {
        try {
          resolve(JSON.parse(body));
        } catch {
          resolve(body);
        }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    ws.on('message', (data) => {
      const msg = JSON.parse(String(data));
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) {
          reject(new Error(`${msg.error.message} (${msg.error.code})`));
        } else {
          resolve(msg.result || {});
        }
      }
    });
  }

  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`CDP timeout: ${method}`));
        }
      }, 30000);
    });
  }

  async eval(expression) {
    try {
      const r = await this.send('Runtime.evaluate', {
        expression,
        returnByValue: true,
        awaitPromise: true,
      });
      if (r.exceptionDetails) {
        return null;
      }
      return r.result ? r.result.value : null;
    } catch {
      return null;
    }
  }
}

async function capture(cdp, name) {
  try {
    const { data } = await cdp.send('Page.captureScreenshot', { format: 'png' });
    const file = path.join(OUT_DIR, name);
    fs.writeFileSync(file, Buffer.from(data, 'base64'));
    result.screenshots.push(file);
    return file;
  } catch {
    return null;
  }
}

async function setViewport(cdp, width, height) {
  await cdp.send('Emulation.setDeviceMetricsOverride', {
    width,
    height,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await sleep(500);
}

async function focusTab(cdp) {
  try {
    await cdp.send('Page.bringToFront');
  } catch {
    /* 激活失败不阻塞。 */
  }
}

/** 激活 Flutter Web 语义树（点击 flt-semantics-placeholder）。 */
async function activateSemantics(cdp) {
  try {
    return await cdp.eval(
      `(() => { const p = document.querySelector('flt-semantics-placeholder'); if (!p) return false; p.click(); return true; })()`,
    );
  } catch {
    return false;
  }
}

/** 收集全部语义标签（aria-label 与 textContent 双通道）。 */
async function collectLabels(cdp) {
  return (
    (await cdp.eval(`(() => {
      const out = [];
      for (const n of document.querySelectorAll('flt-semantics')) {
        const label = (n.getAttribute('aria-label') || n.textContent || '').trim();
        if (label) { out.push(label.slice(0, 80)); }
      }
      return out;
    })()`)) || []
  );
}

/** 查找标签节点（exact=true 全等 / false 子串）；按面积升序返回。 */
async function findLabelNodes(cdp, text, exact) {
  return (
    (await cdp.eval(`(() => {
      const out = [];
      const want = ${JSON.stringify(text)};
      for (const n of document.querySelectorAll('flt-semantics')) {
        const raw = (n.getAttribute('aria-label') || n.textContent || '').trim();
        const hit = ${exact ? 'raw === want' : 'raw.includes(want)'};
        if (!hit) { continue; }
        const r = n.getBoundingClientRect();
        if (r.width > 0 && r.height > 0) {
          out.push({
            label: raw.slice(0, 80),
            x: r.x + r.width / 2, y: r.y + r.height / 2,
            w: r.width, h: r.height, area: r.width * r.height,
          });
        }
      }
      out.sort((a, b) => a.area - b.area);
      return out;
    })()`)) || []
  );
}

async function waitForSubstr(cdp, text, attempts = 24, interval = 400) {
  for (let i = 0; i < attempts; i += 1) {
    const nodes = await findLabelNodes(cdp, text, false);
    if (nodes.length > 0) {
      return nodes[0];
    }
    if (i > 0 && i % 8 === 0) {
      await activateSemantics(cdp);
    }
    await sleep(interval);
  }
  return null;
}

async function waitForSubstrAbsent(cdp, text, attempts = 16, interval = 400) {
  for (let i = 0; i < attempts; i += 1) {
    const nodes = await findLabelNodes(cdp, text, false);
    if (nodes.length === 0) {
      return true;
    }
    await sleep(interval);
  }
  return false;
}

async function clickAt(cdp, x, y) {
  await cdp.send('Input.dispatchMouseEvent', {
    type: 'mousePressed',
    x,
    y,
    button: 'left',
    clickCount: 1,
    pointerType: 'mouse',
  });
  await sleep(60);
  await cdp.send('Input.dispatchMouseEvent', {
    type: 'mouseReleased',
    x,
    y,
    button: 'left',
    clickCount: 1,
    pointerType: 'mouse',
  });
  await sleep(450);
}

async function clickLabel(cdp, text, exact = false) {
  const node = await waitForSubstr(cdp, text, 16, 350);
  if (!node) {
    return null;
  }
  const nodes = await findLabelNodes(cdp, text, exact);
  const target = nodes[0] || node;
  await clickAt(cdp, target.x, target.y);
  return target;
}

/**
 * 读取语义树中的四位投屏码。
 *
 * Flutter 会把投屏码卡片的文本合并为一个语义节点
 * （`局域网投屏\n5517\n等待设备输入投屏码…\n0/4 路`），因此按行解析，
 * 只接受**整行**为四位数字的行——保证前导零不被数字化。
 */
async function readCastCode(cdp) {
  return await cdp.eval(`(() => {
    const linesOf = (raw) => String(raw || '').split(/[\\n\\r]+/).map((s) => s.trim());
    const nodes = Array.from(document.querySelectorAll('flt-semantics'));
    // 优先含「局域网投屏」标题的节点，避免误取其他四位数文本。
    nodes.sort((a, b) => {
      const la = (a.getAttribute('aria-label') || a.textContent || '').includes('局域网投屏') ? 0 : 1;
      const lb = (b.getAttribute('aria-label') || b.textContent || '').includes('局域网投屏') ? 0 : 1;
      return la - lb;
    });
    for (const n of nodes) {
      const raw = n.getAttribute('aria-label') || n.textContent || '';
      for (const line of linesOf(raw)) {
        if (/^[0-9]{4}$/.test(line)) { return line; }
      }
    }
    return '';
  })()`);
}

async function readHash(cdp) {
  return (await cdp.eval('location.hash || ""')) || '';
}

/** 读取页面内全部 <video> 的媒体状态（真实解码尺寸 / 轨道）。 */
async function readVideos(cdp) {
  return (
    (await cdp.eval(`(() => {
      const out = [];
      for (const v of document.querySelectorAll('video')) {
        const stream = v.srcObject || null;
        const tracks = stream && stream.getVideoTracks
          ? stream.getVideoTracks().map((t) => ({
              kind: t.kind, state: t.readyState, enabled: t.enabled, label: t.label,
            }))
          : [];
        const r = v.getBoundingClientRect();
        out.push({
          width: v.videoWidth || 0,
          height: v.videoHeight || 0,
          readyState: v.readyState || 0,
          paused: !!v.paused,
          streamId: stream && stream.id ? String(stream.id) : '',
          tracks,
          rect: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) },
        });
      }
      return out;
    })()`)) || []
  );
}

async function waitVideos(cdp, predicate, attempts = 60, interval = 500) {
  let last = [];
  for (let i = 0; i < attempts; i += 1) {
    last = await readVideos(cdp);
    if (predicate(last)) {
      return last;
    }
    await sleep(interval);
  }
  return last;
}

/** 语义树错误文案（对话框内）。 */
async function readErrorText(cdp) {
  const labels = await collectLabels(cdp);
  for (const hint of ERROR_HINTS) {
    const hit = labels.find((label) => label.includes(hint));
    if (hit) {
      return hit;
    }
  }
  return '';
}

async function ensureInputFocused(cdp) {
  await cdp.eval(`(() => {
    const el = document.querySelector('input.flt-text-editing, textarea.flt-text-editing, input, textarea');
    if (el && typeof el.focus === 'function') { el.focus(); return true; }
    return false;
  })()`);
  await sleep(200);
}

async function anyInputHas(cdp, text) {
  return (
    (await cdp.eval(`(() => {
      const want = ${JSON.stringify(text)};
      return Array.from(document.querySelectorAll('input, textarea'))
        .some((el) => String(el.value || '').includes(want));
    })()`)) === true
  );
}

/** 聚焦并输入四位码（Ctrl+A 清空 + insertText；校验 DOM 值，最多 3 次）。 */
async function typeCode(cdp, code) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (attempt > 0) {
      const rect = await cdp.eval(`(() => {
        const el = document.querySelector('input.flt-text-editing, textarea.flt-text-editing, input, textarea');
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return r.width > 0 ? { x: r.x + r.width / 2, y: r.y + r.height / 2 } : null;
      })()`);
      if (rect) {
        await clickAt(cdp, rect.x, rect.y);
      }
      await ensureInputFocused(cdp);
    }
    await cdp.send('Input.dispatchKeyEvent', {
      type: 'rawKeyDown', modifiers: 2, key: 'a', code: 'KeyA',
      windowsVirtualKeyCode: 65, nativeVirtualKeyCode: 65,
    });
    await cdp.send('Input.dispatchKeyEvent', {
      type: 'keyUp', modifiers: 2, key: 'a', code: 'KeyA',
      windowsVirtualKeyCode: 65, nativeVirtualKeyCode: 65,
    });
    await sleep(120);
    await cdp.send('Input.insertText', { text: code });
    await sleep(350);
    if (await anyInputHas(cdp, code)) {
      return true;
    }
  }
  return false;
}

/**
 * 发送端完整流程：首页 → 输入投屏码 → 选摄像头 → 开始投屏 → 编辑页胶囊。
 * 返回该发送端的状态对象（同时写入 result.senders）。
 */
async function runSender(tab, index, code) {
  const { cdp } = tab;
  const state = {
    index,
    dialogShown: false,
    typed: false,
    cameraSelected: false,
    submitted: false,
    started: false,
    chipShown: false,
    hash: '',
    errorText: '',
  };
  result.senders.push(state);

  await focusTab(cdp);
  await cdp.send('Page.navigate', { url: HOME_URL });
  await sleep(5000);
  await activateSemantics(cdp);

  const entry = await waitForSubstr(cdp, '输入投屏码', 30, 500);
  if (!entry) {
    state.errorText = '首页未找到「输入投屏码」入口';
    result.notes.push(`sender#${index}: ${state.errorText}`);
    return state;
  }
  await clickAt(cdp, entry.x, entry.y);

  // 注意：弹窗标题「发起投屏」不进入 Web 语义树（Text 与图标同行时被
  // 合并/过滤），以唯一的提交按钮「开始投屏」作为弹窗就绪锚点。
  const dialog = await waitForSubstr(cdp, '开始投屏', 24, 400);
  state.dialogShown = dialog !== null;
  if (!dialog) {
    state.errorText = '投屏对话框未出现';
    await capture(cdp, `wb_cast-sender${index}-0-no-dialog.png`);
    return state;
  }
  await capture(cdp, `wb_cast-sender${index}-1-dialog.png`);

  state.typed = await typeCode(cdp, code);

  // 媒体源：默认 screen（getDisplayMedia 在 headless 下会被策略阻断），
  // 显式选择「摄像头」（fake device 提供真实视频轨）。
  const camera = await waitForSubstr(cdp, '摄像头', 12, 300);
  if (camera) {
    await clickAt(cdp, camera.x, camera.y);
    state.cameraSelected = true;
  }
  await capture(cdp, `wb_cast-sender${index}-2-filled.png`);

  const start = await waitForSubstr(cdp, '开始投屏', 12, 300);
  if (!start) {
    state.errorText = '未找到「开始投屏」按钮';
    return state;
  }
  await clickAt(cdp, start.x, start.y);
  state.submitted = true;

  // join 内包含 getUserMedia + createOffer，等待路由切到 castSender 或出现错误。
  for (let i = 0; i < 100; i += 1) {
    const hash = await readHash(cdp);
    if (hash.includes('castSender=1')) {
      state.started = true;
      state.hash = hash;
      break;
    }
    const error = await readErrorText(cdp);
    if (error) {
      state.errorText = error;
      break;
    }
    await sleep(500);
  }

  if (state.started) {
    await focusTab(cdp);
    await activateSemantics(cdp);
    const chip = await waitForSubstr(cdp, '正在投屏', 30, 400);
    state.chipShown = chip !== null;
    await capture(cdp, `wb_cast-sender${index}-3-chip.png`);
  } else {
    await capture(cdp, `wb_cast-sender${index}-3-failed.png`);
    result.notes.push(`sender#${index}: 未建立投屏（${state.errorText || '超时'}）`);
  }
  return state;
}

/** 聚焦接收端并等待连接计数 + 真实视频（videoWidth > 0）。 */
async function waitReceiverVideos(rx, expected) {
  const { cdp } = rx;
  await focusTab(cdp);
  await activateSemantics(cdp);
  const connected = await waitForSubstr(cdp, `已连接 ${expected} 路设备`, 60, 500);
  result.receiver.connectedLabel = connected ? connected.label : '';
  const videos = await waitVideos(
    cdp,
    (list) => list.filter((v) => v.width > 0).length >= expected,
    60,
    500,
  );
  result.receiver.videos = videos;
  result.receiver.videoCount = videos.length;
  return videos;
}

async function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  try {
    fs.rmSync(PROFILE_DIR, { recursive: true, force: true });
  } catch {
    /* 清理失败不阻塞。 */
  }

  // 静态站点 / realtime 就绪性检查。
  try {
    await httpRequest('GET', `${APP_BASE}/`);
  } catch (error) {
    throw new Error(`静态站点不可用（${APP_BASE}）：${error.message}`);
  }
  const health = await httpRequest('GET', `${ENDPOINT}/healthz`).catch(() => null);
  if (!health || health.ok !== true) {
    throw new Error(`realtime 不可用（${ENDPOINT}/healthz）`);
  }

  edgeProcess = spawn(
    EDGE,
    [
      '--headless=new',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-sync',
      '--remote-allow-origins=*',
      '--use-fake-device-for-media-stream',
      '--use-fake-ui-for-media-stream',
      '--autoplay-policy=no-user-gesture-required',
      '--disable-background-timer-throttling',
      '--disable-renderer-backgrounding',
      '--disable-backgrounding-occluded-windows',
      `--remote-debugging-port=${PORT}`,
      `--user-data-dir=${PROFILE_DIR}`,
      'about:blank',
    ],
    { stdio: 'ignore' },
  );

  let version = null;
  for (let i = 0; i < 60 && !version; i += 1) {
    try {
      version = await httpRequest('GET', `http://127.0.0.1:${PORT}/json/version`);
    } catch {
      await sleep(250);
    }
  }
  if (!version) {
    throw new Error('Edge CDP 未就绪');
  }
  result.browser = version['Browser'] || version.browser || 'edge';

  const openTab = async () => {
    const tab = await httpRequest('PUT', `http://127.0.0.1:${PORT}/json/new?about:blank`);
    const ws = new WebSocket(tab.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      ws.on('open', resolve);
      ws.on('error', reject);
    });
    const cdp = new Cdp(ws);
    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');
    await setViewport(cdp, 1400, 900);
    return { cdp, ws };
  };

  // ===================== 接收端：建房 + 读取四位码 =====================
  const rx = await openTab();
  await focusTab(rx.cdp);
  await rx.cdp.send('Page.navigate', { url: RX_URL });
  await sleep(6000);
  await activateSemantics(rx.cdp);

  for (let i = 0; i < 50; i += 1) {
    result.receiver.code = (await readCastCode(rx.cdp)) || '';
    if (result.receiver.code) {
      break;
    }
    if (i > 0 && i % 8 === 0) {
      await activateSemantics(rx.cdp);
    }
    await sleep(500);
  }
  result.receiver.codeValid = /^[0-9]{4}$/.test(result.receiver.code);
  result.receiver.labelsAtCode = (await collectLabels(rx.cdp))
    .filter((label) => label.includes('投屏') || label.includes('等待') || /^[0-9]{4}$/.test(label))
    .slice(0, 30);
  await capture(rx.cdp, 'wb_cast-rx-1-code.png');
  if (!result.receiver.codeValid) {
    throw new Error(`未读取到四位投屏码（当前：${result.receiver.code || '空'}）`);
  }
  result.receiver.waitingShown =
    (await findLabelNodes(rx.cdp, '等待设备输入投屏码', false)).length > 0;

  // ===================== 发送端：逐路加入 =====================
  const senderTabs = [];
  for (let i = 0; i < SENDERS; i += 1) {
    const tab = await openTab();
    senderTabs.push({ tab, index: i + 1 });
    await runSender(tab, i + 1, result.receiver.code);
    if (!result.senders[i] || !result.senders[i].started) {
      break;
    }
  }

  const startedCount = result.senders.filter((s) => s.started).length;

  // ===================== 接收端：真实视频断言 =====================
  if (startedCount > 0) {
    const videos = await waitReceiverVideos(rx, startedCount);
    result.receiver.panelLabel =
      (await findLabelNodes(rx.cdp, '投屏连接', false))[0]?.label || '';
    await capture(rx.cdp, 'wb_cast-rx-2-videos.png');
    const live = videos.filter((v) => v.width > 0 && v.tracks.length > 0);
    if (live.length < startedCount) {
      throw new Error(
        `接收端真实视频不足：期望 ${startedCount} 路，实测 ${live.length} 路（${JSON.stringify(videos)}）`,
      );
    }
  }

  // ===================== 并发上限：第 5 路应被拒绝 =====================
  if (TEST_OVERFLOW && startedCount === 4) {
    result.overflow.attempted = true;
    const tab = await openTab();
    const state = await runSender(tab, 5, result.receiver.code);
    result.overflow.rejected = !state.started && state.errorText.includes('已达到最大投屏路数');
    result.overflow.message = state.errorText;
    await capture(tab.cdp, 'wb_cast-overflow-1-rejected.png');
  }

  // ===================== 单路断开：不影响其他路 =====================
  if (TEST_DISCONNECT && startedCount >= 2) {
    const targetIndex = Math.ceil(startedCount / 2);
    const target = senderTabs[targetIndex - 1];
    result.disconnect.target = `sender#${targetIndex}`;
    await focusTab(target.tab.cdp);
    const end = await waitForSubstr(target.tab.cdp, '结束投屏', 12, 400);
    if (end) {
      await clickAt(target.tab.cdp, end.x, end.y);
    }
    await waitForSubstrAbsent(target.tab.cdp, '正在投屏', 20, 400);
    const after = await waitVideos(rx.cdp, (list) => list.length <= startedCount - 1, 40, 500);
    result.disconnect.receiverVideosAfter = after.filter((v) => v.width > 0).length;
    await focusTab(rx.cdp);
    const others = await waitForSubstr(rx.cdp, `已连接 ${startedCount - 1} 路设备`, 30, 500);
    result.disconnect.othersStillConnected = others !== null;
    await capture(rx.cdp, 'wb_cast-rx-3-after-disconnect.png');
    // 从列表中移除该发送端，后续清理只处理仍活跃的端。
    senderTabs.splice(targetIndex - 1, 1);
  }

  // ===================== 清理：结束全部发送端 → 视频浮层释放 =====================
  for (const { tab, index } of senderTabs) {
    if (!result.senders[index - 1] || !result.senders[index - 1].started) {
      continue;
    }
    await focusTab(tab.cdp);
    const end = await waitForSubstr(tab.cdp, '结束投屏', 10, 400);
    if (end) {
      await clickAt(tab.cdp, end.x, end.y);
      result.cleanup.sendersEnded += 1;
    }
    await waitForSubstrAbsent(tab.cdp, '正在投屏', 20, 400);
  }

  if (startedCount > 0) {
    const remaining = await waitVideos(rx.cdp, (list) => list.length === 0, 40, 500);
    result.cleanup.receiverVideosAfter = remaining.length;
    await focusTab(rx.cdp);
    result.cleanup.waitingAgain =
      (await waitForSubstr(rx.cdp, '等待设备输入投屏码', 20, 400)) !== null;
    await capture(rx.cdp, 'wb_cast-rx-4-cleaned.png');
  }

  // 关闭接收端会话（投屏码失效，浮层整体移除）。
  await focusTab(rx.cdp);
  const stop = await waitForSubstr(rx.cdp, '关闭投屏接收', 8, 300);
  if (stop) {
    await clickAt(rx.cdp, stop.x, stop.y);
    await sleep(1200);
    // 关闭后不再显示投屏码卡片（无码 / 无关闭按钮 / 无等待文案）。
    result.cleanup.sessionClosed =
      (await waitForSubstrAbsent(rx.cdp, '关闭投屏接收', 16, 400)) &&
      (await waitForSubstrAbsent(rx.cdp, '等待设备输入投屏码', 8, 300));
  }
  await capture(rx.cdp, 'wb_cast-rx-5-session-closed.png');

  // 关闭标签页（释放 tab 进程）。
  for (const { tab } of senderTabs) {
    try {
      await httpRequest('GET', `http://127.0.0.1:${PORT}/json/close/${tab.targetId || ''}`);
    } catch {
      /* 忽略。 */
    }
  }

  result.error = '';
  const passed =
    result.receiver.codeValid &&
    result.senders.filter((s) => s.started && s.chipShown).length === SENDERS &&
    result.receiver.videos.filter((v) => v.width > 0).length >= SENDERS &&
    result.cleanup.receiverVideosAfter === 0 &&
    result.cleanup.waitingAgain &&
    (!TEST_OVERFLOW || result.overflow.rejected) &&
    (!TEST_DISCONNECT || result.disconnect.othersStillConnected);
  result.passed = passed;
  if (!passed) {
    throw new Error(`断言未全部通过（passed=${passed}）`);
  }
}

main()
  .catch(async (error) => {
    result.error = error && error.message ? error.message : String(error);
    result.passed = false;
  })
  .finally(async () => {
    try {
      edgeProcess?.kill();
    } catch {
      /* 忽略。 */
    }
    try {
      fs.rmSync(PROFILE_DIR, { recursive: true, force: true });
    } catch {
      /* 忽略。 */
    }
    console.log('=== WB_WEB_CAST_PROBE_RESULT ===');
    console.log(JSON.stringify(result, null, 2));
    if (result.error) {
      console.log('=== WB_WEB_CAST_PROBE_ERROR ===');
      console.log(result.error);
      process.exitCode = 1;
    }
    await sleep(200);
    process.exit(process.exitCode || 0);
  });
