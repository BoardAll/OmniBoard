/**
 * Web 端 P4/P5 功能对齐浏览器实测探针（Edge headless + CDP）。
 *
 * 覆盖（对齐《Web三阶段功能对齐》计划 §浏览器实测）：
 *  A. 单机（P5 高级模块 + P3 上下文浮层）：
 *   A1. 宽屏打开编辑页 → 工具栏「更多」菜单出现专业元素分组（pro.*）；
 *   A2. 点「表格」→ 全屏编辑器对话框（新建表格）→ 保存 → 存档出现 table 元素；
 *   A3. 选中态上下文浮层出现（表格直条目「公式」为锚）→ 浮层「更多」→
 *       「删除」菜单 → 删除确认框出现（取消关闭；真删除在 A5 执行）；
 *   A4. 双击元素 → 编辑对话框（编辑表格，预填）→ 保存 → 存档计数不变；
 *   A5. 点空白 → 浮层收起；重新选中 → 浮层回归 → 「更多」→「删除」→
 *       确认对话框 → 删除生效；
 *   A6. 更多菜单创建「3D 对象」→ 尺寸角标（选择框下缘居中 +6px）→
 *       尺寸对话框 → 改宽 500 → 存档回写；
 *  B. 协作（P4 画布 op + 远端在场；双标签同房间）：
 *   B1. A 先入房（自举 Host）；B 后入房（默认只读 Participant）；
 *   B2. A 画便签 → B 存档出现同 id note 元素（onLocalCommit → crdt.applyLocal →
 *       board:ops → 服务端 → B onRemoteOps → crdt.applyRemote → 画布 → 自动存档）；
 *   B3. A 画布移动指针（presence:preview 上报）→ B 不崩（浮层/选区帧驱动）；
 *   B4. B 退出房间 → 内容保留（本地化）；
 *   B5. A 清空本地存档 + 刷新 + 重新入房 → 服务端全量 replay → 画布重建同 id
 *       note（快照/重放 → state 回放链路的端到端证明）。
 *
 * 依赖：复用 services/realtime 的 `ws`；静态托管 8090（release 产物）+
 * realtime 8790 已就绪。运行：`node tests/e2e/support/wb_web_p45_probe.mjs`。
 * 输出：截图（多处）+ 结果 JSON（stdout，`=== WB_WEB_P45_PROBE_RESULT ===` 后）。
 * 失败：`=== WB_WEB_P45_PROBE_ERROR ===` + 退出码 1（结果 JSON 仍然输出）。
 */

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const WebSocket = require('e:/code/whiteboard/services/realtime/node_modules/ws');

const EDGE = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
// 随机高位端口 + 唯一 profile：规避上次探针残留 Edge 实例占住固定端口 /
// profile 锁导致本次「附着到陈旧浏览器」的假失败。
const PORT = 9330 + Math.floor(Math.random() * 500);
const APP_BASE = process.env.WB_WEB_URL || 'http://localhost:8090';
const OUT_DIR = 'e:\\code\\whiteboard\\.agent_tmp';
const PROFILE_DIR = path.join(
  process.env.TEMP || 'C:\\Windows\\Temp',
  `wb-web-p45-profile-${Date.now().toString(36)}`,
);
const LOCAL_BOARD = 'e2e-p45-local';
const COLLAB_A = 'e2e-p45-a';
const COLLAB_B = 'e2e-p45-b';
const ROOM = 'e2e-p45-room';

const urlOf = (id, name) =>
  `${APP_BASE}/#/board/${id}?name=${encodeURIComponent(name)}`;
const storageKey = (id) => `wb.canvas.${id}`;

/** 画布视口中心估计（1400×900；左侧栏 ≈ 228 宽 / AppBar ≈ 56 高）。 */
const VW_CX = 814;
const VW_CY = 478;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** 探针内的 Edge 进程句柄（异常退出时兜底清理）。 */
let edgeProcess = null;

const result = {
  base: APP_BASE,
  browser: '',
  single: {
    paletteReady: false,
    moreButtonFound: false,
    moreButtonX: 0,
    createDialogShown: false,
    createdType: '',
    createdCount: 0,
    contextPopupShown: false,
    popupLabels: [],
    moreDeleteItemShown: false,
    deleteConfirmShown: false,
    editDialogShown: false,
    editSavedCount: 0,
    popupClosedOnDeselect: false,
    deleteConfirmed: false,
    deleteCountAfter: -1,
    sizeBadgeDialogShown: false,
    sizeAppliedWidth: -1,
    sizeApplied: false,
  },
  collab: {
    aJoined: false,
    bJoined: false,
    aNoteId: '',
    aLocalCount: 0,
    bSyncedCount: 0,
    bSyncedType: '',
    bSyncedSameId: false,
    presenceMovedNoCrash: false,
    bExitKeptContent: false,
    replayCount: 0,
    replaySameId: false,
    replayTypes: [],
  },
  screenshots: [],
  notes: [],
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
    const { data } = await cdp.send('Page.captureScreenshot', {
      format: 'png',
    });
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
  await sleep(600);
}

/** 收集全部语义标签（aria-label 与 textContent 双通道）。 */
async function collectLabels(cdp) {
  return (
    (await cdp.eval(`(() => {
      const nodes = document.querySelectorAll('flt-semantics');
      const labels = [];
      for (const n of nodes) {
        const label = (n.getAttribute('aria-label') || n.textContent || '').trim();
        if (label) { labels.push(label.slice(0, 60)); }
      }
      return labels;
    })()`)) || []
  );
}

/**
 * 查找标签节点（exact=true 全等 / false 子串）；返回 [{label,x,y,w,h}]。
 *
 * Flutter Web 语义树双通道：Tooltip / PopupMenuItem 等走 aria-label；
 * 纯 Text / 按钮文字走 textContent（aria-label 为空）。按面积升序返回，
 * 点击方取 nodes[0]（最小节点 = 最具体的可点击目标，避免命中父容器中心）。
 */
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
            label: raw.slice(0, 60),
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

/** 轮询等待标签出现（子串）；返回首节点或 null。 */
async function waitForSubstr(cdp, text, attempts = 24, interval = 400) {
  for (let i = 0; i < attempts; i += 1) {
    const nodes = await findLabelNodes(cdp, text, false);
    if (nodes.length > 0) {
      return nodes[0];
    }
    await sleep(interval);
  }
  return null;
}

/** 轮询等待标签消失（子串）；返回 true 表消失。 */
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

/** 双击（两次 press/release，间隔 < 双击阈值）。 */
async function doubleClickAt(cdp, x, y) {
  for (let i = 1; i <= 2; i += 1) {
    await cdp.send('Input.dispatchMouseEvent', {
      type: 'mousePressed',
      x,
      y,
      button: 'left',
      clickCount: i,
      pointerType: 'mouse',
    });
    await sleep(40);
    await cdp.send('Input.dispatchMouseEvent', {
      type: 'mouseReleased',
      x,
      y,
      button: 'left',
      clickCount: i,
      pointerType: 'mouse',
    });
    await sleep(80);
  }
  await sleep(400);
}

/** 指针移动（presence 光标上报路径）。 */
async function moveMouse(cdp, x, y) {
  await cdp.send('Input.dispatchMouseEvent', {
    type: 'mouseMoved',
    x,
    y,
    pointerType: 'mouse',
  });
  await sleep(120);
}

async function insertText(cdp, text) {
  await cdp.send('Input.insertText', { text });
  await sleep(300);
}

/** 确保 Flutter 文本编辑宿主聚焦（点击语义节点后的兜底）。 */
async function ensureInputFocused(cdp) {
  await cdp.eval(`(() => {
    const el = document.querySelector('input, textarea');
    if (el && typeof el.focus === 'function') { el.focus(); return true; }
    return false;
  })()`);
  await sleep(200);
}

/**
 * 输入文本（每次尝试先 Ctrl+A 清空）；校验 DOM 输入值并最多重试 3 次。
 * 返回是否确认写入。
 */
async function typeInto(cdp, text) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await cdp.send('Input.dispatchKeyEvent', {
      type: 'rawKeyDown', modifiers: 2, key: 'a', code: 'KeyA',
      windowsVirtualKeyCode: 65, nativeVirtualKeyCode: 65,
    });
    await cdp.send('Input.dispatchKeyEvent', {
      type: 'keyUp', modifiers: 2, key: 'a', code: 'KeyA',
      windowsVirtualKeyCode: 65, nativeVirtualKeyCode: 65,
    });
    await sleep(120);
    await cdp.send('Input.insertText', { text });
    await sleep(250);
    const value = await cdp.eval(
      `(() => { const el = document.querySelector('input, textarea'); return el ? String(el.value || '') : ''; })()`,
    );
    if (value && value.includes(text)) {
      return true;
    }
    await ensureInputFocused(cdp);
  }
  return false;
}

/** 读 localStorage 存档并解析。 */
async function readArchive(cdp, key) {
  const raw = await cdp.eval(
    `localStorage.getItem(${JSON.stringify(key)})`,
  );
  if (!raw) {
    return null;
  }
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function elementsOf(data) {
  const pages = data && Array.isArray(data.pages) ? data.pages : [];
  if (pages.length === 0) {
    return [];
  }
  return Array.isArray(pages[0].elements) ? pages[0].elements : [];
}

/** 轮询存档直到 predicate(elements) 成立；返回元素数组（或最后快照）。 */
async function waitElements(cdp, key, predicate, attempts = 30, interval = 500) {
  let last = [];
  for (let i = 0; i < attempts; i += 1) {
    const data = await readArchive(cdp, key);
    last = elementsOf(data);
    if (predicate(last)) {
      return last;
    }
    await sleep(interval);
  }
  return last;
}

/** 调色板 32×32 role=button 节点（按 x 升序）。 */
async function dumpPaletteButtons(cdp) {
  return (
    (await cdp.eval(`(() => {
      const out = [];
      for (const n of document.querySelectorAll('flt-semantics')) {
        const r = n.getBoundingClientRect();
        if (r.width === 32 && r.height === 32 && n.getAttribute('role') === 'button'
            && r.x > 200 && r.y > 40 && r.y < 170) {
          out.push({
            label: (n.getAttribute('aria-label') || '').slice(0, 40),
            x: Math.round(r.x), y: Math.round(r.y),
            cx: Math.round(r.x + r.width / 2), cy: Math.round(r.y + r.height / 2),
          });
        }
      }
      out.sort((a, b) => a.x - b.x);
      return out;
    })()`)) || []
  );
}

/** 激活当前标签页（多标签 headless 下语义树仅在活动标签可靠激活）。 */
async function focusTab(cdp) {
  try {
    await cdp.send('Page.bringToFront');
  } catch {
    /* 激活失败不阻塞。 */
  }
}

/** 打开编辑页：导航 + 激活语义树 + 等调色板就绪（周期性重试 + 重载兜底）。 */
async function openEditor(cdp, url, label) {
  await focusTab(cdp);
  await cdp.send('Page.navigate', { url });
  await sleep(6000);
  return waitEditorReady(cdp, label);
}

/**
 * 等待编辑页就绪（激活语义树 + 轮询调色板；周期重试 + 重载兜底）。
 *
 * 供 openEditor 复用；B5 同 URL 刷新场景亦直接使用——同 URL（含相同
 * hash）的 `Page.navigate` 属同文档跳转、不触发真实重载，须先 `Page.reload`。
 */
async function waitEditorReady(cdp, label) {
  const activate = async () => {
    try {
      await cdp.eval(
        `(() => { const p = document.querySelector('flt-semantics-placeholder'); if (!p) { return false; } p.click(); return true; })()`,
      );
    } catch {
      /* 语义树激活失败不阻塞。 */
    }
  };
  const poll = async () => {
    let found = [];
    for (let i = 0; i < 40; i += 1) {
      found = await dumpPaletteButtons(cdp);
      if (found.length >= 11) {
        break;
      }
      // 多标签页竞争 / 加载慢时语义树可能未激活：周期性重试点击 placeholder。
      if (i > 0 && i % 6 === 0) {
        await activate();
      }
      await sleep(500);
    }
    return found;
  };
  await activate();
  await sleep(1200);
  let buttons = await poll();
  if (buttons.length < 11) {
    // 兜底：后台标签 / 加载竞态下激活偶发失效 → 拉到前台重载一次再试。
    await focusTab(cdp);
    await cdp.send('Page.reload');
    await sleep(6000);
    await activate();
    buttons = await poll();
  }
  if (buttons.length < 11) {
    result.notes.push(`${label}: 调色板未就绪（32×32 按钮 ${buttons.length} 个）`);
  }
  return buttons;
}

/** 打开「更多」菜单并点选 pro.* 条目（菜单项按文字精确匹配）。 */
async function createViaMoreMenu(cdp, buttons, itemLabel) {
  const more = buttons.length > 0 ? buttons[buttons.length - 1] : null;
  result.single.moreButtonFound = more !== null;
  result.single.moreButtonX = more ? more.cx : 0;
  if (!more) {
    result.notes.push('未定位「更多」按钮（调色板最右侧 32×32）');
    return false;
  }
  await clickAt(cdp, more.cx, more.cy);
  const item = await waitForSubstr(cdp, itemLabel, 12, 300);
  if (!item) {
    const labels = await collectLabels(cdp);
    result.notes.push(
      `菜单项「${itemLabel}」未出现；当前标签样例：${labels.slice(0, 30).join(' | ')}`,
    );
    return false;
  }
  await clickAt(cdp, item.x, item.y);
  return true;
}

/** 浮层「更多」按钮（画布区 y>200 的精确「更多」；排除调色板同标签按钮）。 */
async function findPopupMore(cdp) {
  const nodes = await findLabelNodes(cdp, '更多', true);
  const popup = nodes.filter((n) => n.y > 200 && n.x > 220);
  return popup.length > 0 ? popup[0] : null;
}

/** 轮询等待浮层「更多」出现（浮层已展示的通用信号，跨元素类型）。 */
async function waitPopupMore(cdp, attempts = 10, interval = 300) {
  for (let i = 0; i < attempts; i += 1) {
    const node = await findPopupMore(cdp);
    if (node) {
      return node;
    }
    await sleep(interval);
  }
  return null;
}

/**
 * 预置「目标元素单选 + 上下文浮层已收起」的确定状态。
 *
 * 遮罩语义（实测）：浮层可见时，第一次点击（任意位置）被全屏遮罩消费并
 * 收起浮层（选区保留、同选区不再自动重开）；需「清选区 → 重选」让浮层
 * 回归。序列：点空白（消费遮罩）→ 点空白（清选区）→ 点元素（选中 + 浮层
 * 出现）→ 再点元素（遮罩消费 → 收起，选区保留）。
 */
async function primeElementSelected(cdp) {
  await clickAt(cdp, 1250, 800);
  await clickAt(cdp, 1250, 800);
  await clickAt(cdp, VW_CX, VW_CY);
  const more = await waitPopupMore(cdp, 12, 250);
  await clickAt(cdp, VW_CX, VW_CY);
  await sleep(550);
  return more !== null;
}

/**
 * 3D 上下文浮层可见性：条目「材质」为唯一锚（调色板 / 其它 UI 无此标签）。
 */
async function contextPopupVisible(cdp) {
  const nodes = await findLabelNodes(cdp, '材质', true);
  return nodes.length > 0;
}

/**
 * 确保「3D 单选 + 上下文浮层收起」，供尺寸角标点击前使用。
 *
 * 浮层可见 → 单击空白消费遮罩（选区保留）；浮层不可见且元素未选中
 * （脱靶点击会清空选区）→ 点元素中心重选（触发浮层后下一轮消费）。
 * 以浮层可见性为唯一条件判据，避免盲点击在无浮层时误清选区。
 */
async function ensureBadgeReady(cdp, cx, cy) {
  for (let i = 0; i < 4; i += 1) {
    if (await contextPopupVisible(cdp)) {
      await clickAt(cdp, 1250, 800);
      continue;
    }
    await clickAt(cdp, cx, cy);
    if (!(await contextPopupVisible(cdp))) {
      return true;
    }
  }
  return !(await contextPopupVisible(cdp));
}

async function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  try {
    fs.rmSync(PROFILE_DIR, { recursive: true, force: true });
  } catch {
    /* 清理失败不阻塞。 */
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
    const tab = await httpRequest(
      'PUT',
      `http://127.0.0.1:${PORT}/json/new?about:blank`,
    );
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

  // ===================== 阶段 A：单机（P5 + P3 浮层） =====================
  const { cdp: a, ws: wsA } = await openTab();
  const keyLocal = storageKey(LOCAL_BOARD);
  const buttons = await openEditor(
    a,
    urlOf(LOCAL_BOARD, 'P45本地'),
    'single',
  );
  result.single.paletteReady = buttons.length >= 11;
  await capture(a, 'wb_p45-1-palette.png');

  // A1+A2：更多菜单 → 表格 → 新建对话框 → 保存。
  if (await createViaMoreMenu(a, buttons, '表格')) {
    const dialog = await waitForSubstr(a, '新建表格', 16, 400);
    result.single.createDialogShown = dialog !== null;
    await capture(a, 'wb_p45-2-create-dialog.png');
    if (dialog) {
      const save = await waitForSubstr(a, '保存', 10, 300);
      if (save) {
        await clickAt(a, save.x, save.y);
      }
    }
    const elements = await waitElements(a, keyLocal, (es) => es.length >= 1);
    result.single.createdCount = elements.length;
    result.single.createdType = elements.length > 0 ? elements[0].type || '' : '';
  }

  // A3：上下文浮层出现（表格直条目「公式」为锚）→ 浮层「更多」→「删除」
  // 菜单 → 删除确认框出现（取消关闭；真删除在 A5 执行）。
  let popupItem = await waitForSubstr(a, '公式', 10, 400);
  if (!popupItem) {
    // 保存后未自动选中 / 浮层已被前置点击消费：预置选择并唤醒浮层。
    await primeElementSelected(a);
    popupItem = await waitForSubstr(a, '公式', 6, 350);
  }
  result.single.contextPopupShown = popupItem !== null;
  const popupLabels = await collectLabels(a);
  result.single.popupLabels = popupLabels
    .filter((l) => ['背景', '边框', '对齐', '公式', '排序', '筛选'].some((k) => l.includes(k)))
    .slice(0, 20);
  await capture(a, 'wb_p45-3-context-popup.png');
  if (popupItem) {
    const popupMore = await findPopupMore(a);
    if (popupMore) {
      await clickAt(a, popupMore.x, popupMore.y);
      const delItem = await waitForSubstr(a, '删除', 8, 300);
      result.single.moreDeleteItemShown = delItem !== null;
      if (delItem) {
        await clickAt(a, delItem.x, delItem.y);
        const confirm = await waitForSubstr(a, '删除表格', 12, 350);
        result.single.deleteConfirmShown = confirm !== null;
        await capture(a, 'wb_p45-3b-delete-confirm.png');
        if (confirm) {
          const cancel = (await findLabelNodes(a, '取消', true))[0] || null;
          if (cancel) {
            await clickAt(a, cancel.x, cancel.y);
          }
          await sleep(400);
        }
      }
    } else {
      result.notes.push('浮层「更多」未找到（A3）');
    }
  }

  // A4：双击编辑 → 编辑表格 → 保存。
  // 前置：目标单选且浮层已收起（否则双击首击被遮罩消费，双击无法达成）。
  const baseCount = result.single.createdCount || 1;
  await primeElementSelected(a);
  const editCandidates = [
    [VW_CX, VW_CY],
    [VW_CX - 60, VW_CY],
    [VW_CX + 60, VW_CY],
    [VW_CX, VW_CY - 40],
    [VW_CX, VW_CY + 40],
  ];
  for (const [x, y] of editCandidates) {
    await doubleClickAt(a, x, y);
    const edit = await waitForSubstr(a, '编辑表格', 6, 300);
    if (edit) {
      result.single.editDialogShown = true;
      await capture(a, 'wb_p45-4-edit-dialog.png');
      const save = await waitForSubstr(a, '保存', 8, 300);
      if (save) {
        await clickAt(a, save.x, save.y);
      }
      break;
    }
  }
  const afterEdit = await waitElements(
    a,
    keyLocal,
    (es) => es.length >= baseCount,
    12,
    400,
  );
  result.single.editSavedCount = afterEdit.length;

  // A5：点空白收起浮层 → 重选回归 → 「更多」→「删除」→ 确认 → 删除生效。
  // 点空白两次：浮层可见时首击被遮罩消费（收起），次击到达画布清空选区。
  await clickAt(a, 1250, 800);
  await clickAt(a, 1250, 800);
  result.single.popupClosedOnDeselect = await waitForSubstrAbsent(a, '公式', 10, 350);
  await clickAt(a, VW_CX, VW_CY);
  let popupAgain = await waitForSubstr(a, '公式', 10, 400);
  if (!popupAgain) {
    // 收起锁定兜底：再走一次「清选区 → 重选」让浮层回归。
    await clickAt(a, 1250, 800);
    await clickAt(a, 1250, 800);
    await clickAt(a, VW_CX, VW_CY);
    popupAgain = await waitForSubstr(a, '公式', 8, 350);
  }
  const moreInPopup = popupAgain ? await findPopupMore(a) : null;
  if (moreInPopup) {
    await clickAt(a, moreInPopup.x, moreInPopup.y);
    const delMenuItem = await waitForSubstr(a, '删除', 8, 300);
    if (delMenuItem) {
      await clickAt(a, delMenuItem.x, delMenuItem.y);
    }
    const confirm = await waitForSubstr(a, '删除表格', 12, 350);
    if (confirm) {
      await capture(a, 'wb_p45-5-delete-confirm.png');
      // 确认按钮：精确「删除」节点面积最小者（对话框按钮 76×32；大面积节点
      // 为整页 / 对话框组合标签，菜单项已随菜单关闭）。
      const delNodes = await findLabelNodes(a, '删除', true);
      const target = delNodes[0] || null;
      if (target) {
        await clickAt(a, target.x, target.y);
      }
    }
    const afterDelete = await waitElements(
      a,
      keyLocal,
      (es) => es.length < baseCount,
      16,
      400,
    );
    result.single.deleteConfirmed = afterDelete.length < baseCount;
    result.single.deleteCountAfter = afterDelete.length;
  } else {
    result.notes.push('重选后上下文浮层未回归（未找到浮层「更多」）');
  }

  // A6：3D 对象 → 尺寸角标 → 尺寸对话框 → 宽 500。
  if (await createViaMoreMenu(a, buttons, '3D 对象')) {
    const dialog = await waitForSubstr(a, '新建3D', 16, 400);
    if (dialog) {
      const save = await waitForSubstr(a, '保存', 10, 300);
      if (save) {
        await clickAt(a, save.x, save.y);
      }
    }
    const elements3d = await waitElements(
      a,
      keyLocal,
      (es) => es.some((e) => e.type === 'render3d'),
      20,
      400,
    );
    const scene = elements3d.find((e) => e.type === 'render3d');
    if (scene) {
      // 契约形状：尺寸在嵌套键 size.{width,height}（顶层无 width/height；
      // 误读会回落默认值导致角标纵向脱靶）。
      const h = Number(scene?.size?.height) || 332;
      // 尺寸角标 = 选择框「下缘居中、下方 6px」（canvas_controller
      // sizeBadgeScreenRect，高 20）；元素插入屏幕中心实测 ≈ (820, 478)
      // （A2 表格锚点同口径），角标中心 y ≈ 中心 + h/2 + 6 + 10。
      const badgeY = 478 + h / 2 + 16;
      const candidates = [
        [820, badgeY],
        [820, badgeY - 6],
        [820, badgeY + 6],
        [806, badgeY],
        [834, badgeY],
      ];
      for (const [x, y] of candidates) {
        // 每次尝试前确保「3D 单选 + 浮层收起」（浮层可见才消费，避免误清选区）。
        await ensureBadgeReady(a, VW_CX, VW_CY);
        await clickAt(a, x, y);
        const sizeDialog = await waitForSubstr(a, '尺寸设置', 10, 300);
        if (sizeDialog) {
          result.single.sizeBadgeDialogShown = true;
          await capture(a, 'wb_p45-6-size-dialog.png');
          const field = await waitForSubstr(a, '宽', 6, 250);
          if (field) {
            await clickAt(a, field.x, field.y);
          }
          // 宽字段 autofocus：无论标签是否定位到都直接输入。
          await typeInto(a, '500');
          const ok = await waitForSubstr(a, '确定', 6, 250);
          if (ok) {
            await clickAt(a, ok.x, ok.y);
          }
          const resized = await waitElements(
            a,
            keyLocal,
            (es) =>
              es.some(
                (e) =>
                  e.type === 'render3d' &&
                  Math.abs(Number(e?.size?.width) - 500) < 1,
              ),
            16,
            400,
          );
          const hit = resized.find(
            (e) =>
              e.type === 'render3d' &&
              Math.abs(Number(e?.size?.width) - 500) < 1,
          );
          if (hit) {
            result.single.sizeAppliedWidth = Number(hit.size.width);
            result.single.sizeApplied = true;
          }
          break;
        }
      }
      if (!result.single.sizeBadgeDialogShown) {
        result.notes.push('尺寸角标未命中（下缘居中 5 点扫描无「尺寸设置」对话框）');
      }
    }
  }
  await capture(a, 'wb_p45-7-single-final.png');

  // ===================== 阶段 B：协作（P4） =====================
  const { cdp: c, ws: wsC } = await openTab();
  const { cdp: b, ws: wsB } = await openTab();
  const keyA = storageKey(COLLAB_A);
  const keyB = storageKey(COLLAB_B);

  const joinRoom = async (cdp, label) => {
    const entry = await waitForSubstr(cdp, '互动白板', 12, 400);
    if (!entry) {
      result.notes.push(`${label}: 未找到「互动白板」入口`);
      return false;
    }
    await clickAt(cdp, entry.x, entry.y);
    const field = await waitForSubstr(cdp, '房间号', 12, 350);
    if (!field) {
      result.notes.push(`${label}: 加入对话框未出现`);
      return false;
    }
    await clickAt(cdp, field.x, field.y);
    await ensureInputFocused(cdp);
    await typeInto(cdp, ROOM);
    const exact = await findLabelNodes(cdp, '加入', true);
    if (exact.length === 0) {
      result.notes.push(`${label}: 「加入」按钮未找到`);
      return false;
    }
    await clickAt(cdp, exact[0].x, exact[0].y);
    const connected = await waitForSubstr(cdp, '已连接', 40, 500);
    if (!connected) {
      result.notes.push(`${label}: 未进入「已连接」（入房失败）`);
      return false;
    }
    await sleep(1500);
    return true;
  };

  await openEditor(c, urlOf(COLLAB_A, 'P45协作A'), 'collabA');
  result.collab.aJoined = await joinRoom(c, 'collabA');
  await capture(c, 'wb_p45-8-collab-a-joined.png');

  await openEditor(b, urlOf(COLLAB_B, 'P45协作B'), 'collabB');
  result.collab.bJoined = await joinRoom(b, 'collabB');
  await capture(b, 'wb_p45-9-collab-b-joined.png');
  await sleep(1000);

  // B2：A 画便签 → B 出现同 id note。
  //
  // 两个稳健性要点（此前实锤过的坑）：
  // 1) 便签创建后自动进入文本编辑态（空文本）。若保持空文本，后续失焦 /
  //    页面 dispose 会触发 endTextEditing 的「空文本清理」删除元素
  //    （exists=false op 上行污染服务端 oplog，令 B5 重放「创建 + 删除」
  //    而看不到元素）——故创建后必须输入文字并点空白提交。
  // 2) 文本输入必须校验生效：非活动标签页（语义树 / 编辑输入宿主不可靠）
  //    下裸 Input.insertText 会无声丢字，效果等同空文本被清理。
  if (result.collab.aJoined && result.collab.bJoined) {
    const createNoteWithText = async (label) => {
      await focusTab(c);
      await sleep(400);
      const sticky = await waitForSubstr(c, '便签', 8, 300);
      await clickAt(c, sticky ? sticky.x : 457, sticky ? sticky.y : 88);
      await clickAt(c, 1000, 500);
      let typed = await typeInto(c, 'E2E');
      if (!typed) {
        // 兜底：元素可能未进入编辑态（首击落空 / 输入宿主未聚焦），
        // 双击元素重进编辑后再试。
        await doubleClickAt(c, 1000, 500);
        typed = await typeInto(c, 'E2E');
      }
      // 点空白提交（非空文本在此定格；空文本会被 endTextEditing 清理）。
      await clickAt(c, 1250, 800);
      await sleep(400);
      result.notes.push(`${label}: 便签文本输入=${typed}`);
    };

    await createNoteWithText('collabA');
    let aElements = await waitElements(
      c,
      keyA,
      (es) => es.length >= 1 && String(es[0].text || '').length >= 1,
      20,
      400,
    );
    if (aElements.length === 0) {
      // 整段重试一次（多标签激活 / 时序抖动下的纵深防御）。
      await createNoteWithText('collabA-retry');
      aElements = await waitElements(
        c,
        keyA,
        (es) => es.length >= 1 && String(es[0].text || '').length >= 1,
        20,
        400,
      );
    }
    result.collab.aLocalCount = aElements.length;
    result.collab.aNoteId = aElements.length > 0 ? aElements[0].id || '' : '';
    await capture(c, 'wb_p45-9b-collab-a-note.png');
    const bElements = await waitElements(b, keyB, (es) => es.length >= 1, 45, 500);
    result.collab.bSyncedCount = bElements.length;
    result.collab.bSyncedType = bElements.length > 0 ? bElements[0].type || '' : '';
    result.collab.bSyncedSameId =
      bElements.length > 0 && bElements[0].id === result.collab.aNoteId;
    await capture(b, 'wb_p45-10-collab-synced.png');

    // B3：A 指针移动（presence 上报）→ B 保持存活。
    await focusTab(c);
    for (const [x, y] of [[900, 400], [950, 450], [1000, 500], [1050, 550]]) {
      await moveMouse(c, x, y);
    }
    await sleep(1200);
    // 切回 B（多标签下语义树仅在活动页可靠激活，读标签前先激活）。
    await focusTab(b);
    await sleep(600);
    const bLabels = await collectLabels(b);
    result.collab.presenceMovedNoCrash =
      bLabels.length > 0 && (await readArchive(b, keyB)) !== null;
    await capture(b, 'wb_p45-11-collab-presence.png');

    // B4：B 退出房间 → 内容保留。
    const chip = await findLabelNodes(b, '已连接', false);
    if (chip.length > 0) {
      await clickAt(b, chip[0].x, chip[0].y);
      const leave = await waitForSubstr(b, '退出互动白板', 12, 400);
      if (leave) {
        await clickAt(b, leave.x, leave.y);
        await sleep(1500);
      }
    }
    const bAfterLeave = await waitElements(b, keyB, (es) => es.length >= 1, 8, 400);
    result.collab.bExitKeptContent = bAfterLeave.length >= 1;
    await capture(b, 'wb_p45-12-collab-b-left.png');

    // B5：A 退出房间 → 清空存档 → 刷新 → 重入房 → 全量 replay → 同 id 重建。
    // 先退出房间（会话解绑后再清档）：清档动作会令旧画布重置（失焦 /
    // dispose 触发 endTextEditing 清理），退出后其删除 op 不再上行
    // （纵深防御；B2 已输入文本从根上避免空文本清理）。
    // 先激活 A 页再找「已连接」chip（多标签下语义树仅在活动页可靠）。
    await focusTab(c);
    await sleep(600);
    const chipA = await findLabelNodes(c, '已连接', false);
    if (chipA.length > 0) {
      await clickAt(c, chipA[0].x, chipA[0].y);
      const leaveA = await waitForSubstr(c, '退出互动白板', 12, 400);
      if (leaveA) {
        await clickAt(c, leaveA.x, leaveA.y);
        await sleep(1500);
      }
    }
    await c.eval(`localStorage.removeItem(${JSON.stringify(keyA)})`);
    // 同 URL（含相同 hash）Page.navigate 为同文档跳转、不触发真实刷新：
    // 显式 reload 让页面以「存档已空」重新初始化（否则仍处于「已连接」
    // 态，不会出现「互动白板」入口）。
    await focusTab(c);
    await c.send('Page.reload');
    await sleep(6000);
    await waitEditorReady(c, 'collabA-reload');
    result.collab.aJoined = (await joinRoom(c, 'collabA-reload')) || result.collab.aJoined;
    const replayed = await waitElements(c, keyA, (es) => es.length >= 1, 90, 500);
    result.collab.replayCount = replayed.length;
    result.collab.replayTypes = replayed.map((e) => e.type || '');
    result.collab.replaySameId =
      replayed.length > 0 && replayed.some((e) => e.id === result.collab.aNoteId);
    await capture(c, 'wb_p45-13-collab-replay.png');
  }

  wsA.close();
  wsB.close();
  wsC.close();
  edgeProcess?.kill();

  const single = result.single;
  const collab = result.collab;
  const hardFailures = [];
  const check = (ok, name) => {
    if (!ok) {
      hardFailures.push(name);
    }
  };
  check(single.paletteReady, 'single.paletteReady');
  check(single.moreButtonFound, 'single.moreButtonFound');
  check(single.createDialogShown, 'single.createDialogShown');
  check(single.createdCount >= 1 && single.createdType === 'table', 'single.createdTable');
  check(single.contextPopupShown, 'single.contextPopupShown');
  check(single.moreDeleteItemShown, 'single.moreDeleteItemShown');
  check(single.deleteConfirmShown, 'single.deleteConfirmShown');
  check(single.editDialogShown, 'single.editDialogShown');
  check(single.editSavedCount >= 1, 'single.editSaved');
  check(single.popupClosedOnDeselect, 'single.popupClosedOnDeselect');
  check(single.deleteConfirmed, 'single.deleteConfirmed');
  check(collab.aJoined && collab.bJoined, 'collab.joined');
  check(collab.bSyncedCount >= 1, 'collab.aToBSync');
  check(collab.bSyncedSameId, 'collab.sameId');
  check(collab.presenceMovedNoCrash, 'collab.presenceAlive');
  check(collab.bExitKeptContent, 'collab.bExitKept');
  check(collab.replayCount >= 1 && collab.replaySameId, 'collab.replaySameId');
  if (!single.sizeApplied) {
    result.notes.push('尺寸角标链路未完成（A6 软断言，见 single.*）');
  }

  console.log('=== WB_WEB_P45_PROBE_RESULT ===');
  console.log(
    JSON.stringify(
      { ok: hardFailures.length === 0, hardFailures, ...result },
      null,
      2,
    ),
  );
}

main().catch((error) => {
  console.error('=== WB_WEB_P45_PROBE_ERROR ===');
  console.error(String(error && error.stack ? error.stack : error));
  console.log(JSON.stringify({ ok: false, ...result }, null, 2));
  try {
    edgeProcess?.kill();
  } catch {
    /* 进程清理失败不阻塞退出。 */
  }
  process.exit(1);
});
