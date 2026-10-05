/**
 * Web 端工具栏（P3：宽屏画布左上角浮动工具面板）浏览器实测探针
 * （Edge headless + CDP）。
 *
 * 验证链路（宽屏浮动面板 ↔ 窄屏底部工具条 的响应式切换 + 真实交互）：
 *  1. 宽屏 1400×900 打开编辑页，等待 WASM 引擎就绪 + 浮动工具面板挂载；
 *  2. 面板断言：DOM 几何（工具行 11 个 32×32 role=button 连排）+ 语义树
 *     （无精确 label '工具'——左侧栏旧工具分区已移除；'撤销 (Ctrl+Z)' 参考）。
 *     注：Flutter Web 语义树将自定义 InkWell 按钮的 tooltip 合并入容器节点、
 *     按钮自身 aria-label 为空，故工具存在性以几何计数为主判据；
 *  3. 真实交互：点「便签」→ 点击画布 → 断言 localStorage 存档出现元素
 *     （浮动面板 → controller.setTool → 画布创建 → 自动保存 全链路）；
 *  4. 缩窄 600×900：浮动面板退场（无 '撤销 (Ctrl+Z)'）、底部工具条出现
 *     （9 工具 tooltip）；
 *  5. 恢复 1400×900：浮动面板回归。
 *
 * 依赖：复用 services/realtime 的 `ws`；Edge 位于 Program Files (x86)。
 * 输出：截图 + 结果 JSON（stdout）。
 */

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const WebSocket = require('e:/code/whiteboard/services/realtime/node_modules/ws');

const EDGE = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const PORT = 9334;
const BOARD_ID = 'e2e-p3-toolbar';
const BOARD_NAME = 'E2E工具栏';
const APP_BASE = process.env.WB_WEB_URL || 'http://localhost:8090';
const EDITOR_URL = `${APP_BASE}/#/board/${BOARD_ID}?name=${encodeURIComponent(BOARD_NAME)}`;
const OUT_DIR = 'e:\\code\\whiteboard\\.agent_tmp';
const PROFILE_DIR = path.join(
  process.env.TEMP || 'C:\\Windows\\Temp',
  'wb-web-p3-profile',
);
const STORAGE_KEY = `wb.canvas.${BOARD_ID}`;

/** 浮动面板 11 工具 tooltip（`WbCanvasTool.label`）。 */
const PALETTE_TOOLS = [
  '选择',
  '抓手',
  '画笔',
  '荧光笔',
  '橡皮擦',
  '便签',
  '文本',
  '形状',
  '图片',
  '连线',
  '3D',
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const result = {
  editorUrl: EDITOR_URL,
  browser: '',
  wide: {
    paletteMounted: false,
    paletteUndoLabelSeen: false,
    paletteToolRowCount: 0,
    paletteButtonCount: 0,
    leftToolsPartitionFound: false,
    toolsFoundByLabel: [],
    sampleRounds: [],
    debugNodes: [],
    labels: [],
  },
  interaction: {
    stickyCenterFound: false,
    elementCreated: false,
    elementCount: 0,
    elementTypes: [],
  },
  narrow: {
    paletteGone: false,
    paletteToolRowCount: 0,
    bottomBarMounted: false,
    bottomBarButtonCount: 0,
    bottomToolsRowCount: 0,
    bottomExtrasSeen: false,
    bottomNodes: [],
    labels: [],
  },
  back: {
    paletteBackFound: false,
    paletteToolRowCount: 0,
    labels: [],
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
      }, 20000);
    });
  }

  /** 求值（返回按值序列化；异常返回 null 并记录）。 */
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
  const { data } = await cdp.send('Page.captureScreenshot', { format: 'png' });
  const file = path.join(OUT_DIR, name);
  fs.writeFileSync(file, Buffer.from(data, 'base64'));
  result.screenshots.push(file);
  return file;
}

async function setViewport(cdp, width, height) {
  await cdp.send('Emulation.setDeviceMetricsOverride', {
    width,
    height,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await sleep(700);
}

/** 收集 Flutter 语义树中的 aria-label 列表。 */
async function collectSemantics(cdp) {
  return (
    (await cdp.eval(`(() => {
      const nodes = document.querySelectorAll('flt-semantics, [aria-label]');
      const labels = [];
      for (const n of nodes) {
        const label = n.getAttribute && n.getAttribute('aria-label');
        if (label) { labels.push(label); }
      }
      return labels;
    })()`)) || []
  );
}

/** 按 aria-label 子串查找语义节点中心坐标。 */
async function findSemanticsCenter(cdp, text) {
  return cdp.eval(`(() => {
    const nodes = document.querySelectorAll('[aria-label]');
    for (const n of nodes) {
      const label = n.getAttribute('aria-label') || '';
      if (label.includes(${JSON.stringify(text)})) {
        const r = n.getBoundingClientRect();
        if (r.width > 0 && r.height > 0) {
          return [r.x + r.width / 2, r.y + r.height / 2];
        }
      }
    }
    return null;
  })()`);
}

/** 轮询语义树直到 predicate 成立；返回最后一次的 labels。 */
async function waitForLabels(cdp, predicate, attempts = 30, interval = 500) {
  let labels = [];
  for (let i = 0; i < attempts; i += 1) {
    labels = await collectSemantics(cdp);
    if (predicate(labels)) {
      return labels;
    }
    await sleep(interval);
  }
  return labels;
}

/**
 * 多轮采样取并集：Flutter Web 对运行中后挂载的子树（如引擎就绪后才出现
 * 的浮动工具面板）可能分帧构建语义节点，单次快照存在中间态。
 */
async function collectSemanticsMerged(cdp, rounds = 8, interval = 400) {
  const merged = [];
  const seen = new Set();
  const sizes = [];
  for (let i = 0; i < rounds; i += 1) {
    const labels = await collectSemantics(cdp);
    sizes.push(labels.length);
    for (const label of labels) {
      if (!seen.has(label)) {
        seen.add(label);
        merged.push(label);
      }
    }
    await sleep(interval);
  }
  return { labels: merged, sizes };
}

/** 诊断：dump 画布左上角区域（浮动面板落点）的语义节点明细。 */
async function dumpPaletteRegion(cdp) {
  return (
    (await cdp.eval(`(() => {
      const out = [];
      for (const n of document.querySelectorAll('flt-semantics')) {
        const r = n.getBoundingClientRect();
        if (r.x > 230 && r.y > 40 && r.y < 170 && r.width > 0 && r.height > 0) {
          out.push({
            label: (n.getAttribute('aria-label') || '').slice(0, 60),
            role: n.getAttribute('role') || '',
            x: Math.round(r.x),
            y: Math.round(r.y),
            w: Math.round(r.width),
            h: Math.round(r.height),
          });
        }
      }
      return out.slice(0, 40);
    })()`)) || []
  );
}

/** 浮动面板工具行按钮（DOM 几何：32×32 role=button）计数。 */
function toolRowButtonsOf(nodes) {
  return nodes.filter((n) => n.w === 32 && n.h === 32 && n.role === 'button');
}

/** 底部条区域语义节点（视口底部 60px 带；窄屏工具行几何判据）。 */
async function dumpBottomRegion(cdp) {
  return (
    (await cdp.eval(`(() => {
      const limit = window.innerHeight - 60;
      const out = [];
      for (const n of document.querySelectorAll('flt-semantics')) {
        const r = n.getBoundingClientRect();
        if (r.y >= limit && r.width > 0 && r.height > 0) {
          out.push({
            label: (n.getAttribute('aria-label') || '').slice(0, 60),
            role: n.getAttribute('role') || '',
            x: Math.round(r.x),
            y: Math.round(r.y),
            w: Math.round(r.width),
            h: Math.round(r.height),
          });
        }
      }
      return out.slice(0, 60);
    })()`)) || []
  );
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
  await sleep(500);
}

async function readArchive(cdp) {
  const raw = await cdp.eval(
    `localStorage.getItem(${JSON.stringify(STORAGE_KEY)})`,
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

/** 轮询存档；返回解析后的 `WbBoardData` 或 null。 */
async function waitArchive(cdp, attempts = 25, interval = 400) {
  for (let i = 0; i < attempts; i += 1) {
    const data = await readArchive(cdp);
    if (data) {
      return data;
    }
    await sleep(interval);
  }
  return null;
}

function elementCountOf(data) {
  const pages = data && Array.isArray(data.pages) ? data.pages : [];
  if (pages.length === 0) {
    return 0;
  }
  return Array.isArray(pages[0].elements) ? pages[0].elements.length : 0;
}

async function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  try {
    fs.rmSync(PROFILE_DIR, { recursive: true, force: true });
  } catch {
    /* 旧 profile 清理失败不阻塞。 */
  }

  const edge = spawn(
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

  // 1. 宽屏进入编辑页，激活语义树，等待浮动面板挂载。
  await cdp.send('Page.navigate', { url: EDITOR_URL });
  await sleep(6000);
  try {
    const activated = await cdp.eval(
      `(() => { const p = document.querySelector('flt-semantics-placeholder'); if (!p) { return false; } p.click(); return true; })()`,
    );
    if (activated !== true) {
      result.notes.push('语义树占位节点未找到（可能已激活）');
    }
  } catch {
    result.notes.push('语义树激活失败');
  }
  await sleep(1200);

  const wideLabels = await waitForLabels(
    cdp,
    (ls) => ls.some((l) => l.startsWith('画布就绪') || l === '撤销 (Ctrl+Z)'),
  );
  // 实测：Flutter Web 语义树把自定义 InkWell 按钮的 tooltip 合并入容器节点
  // （容器 label 不稳定），按钮自身 aria-label 为空——因此面板挂载与工具行
  // 存在性以 DOM 几何（32×32 role=button 连排）为主判据，语义 label 仅作参考。
  const wideMerged = await collectSemanticsMerged(cdp);
  const wideAll = [...new Set([...wideLabels, ...wideMerged.labels])];
  result.wide.sampleRounds = wideMerged.sizes;
  const wideNodes = await dumpPaletteRegion(cdp);
  result.wide.debugNodes = wideNodes;
  const wideButtons = toolRowButtonsOf(wideNodes);
  result.wide.paletteButtonCount = wideButtons.length;
  result.wide.paletteToolRowCount = wideButtons.filter(
    (n) => n.x >= 240 && n.x <= 620,
  ).length;
  result.wide.paletteMounted = result.wide.paletteToolRowCount >= 11;
  result.wide.paletteUndoLabelSeen = wideAll.includes('撤销 (Ctrl+Z)');
  result.wide.leftToolsPartitionFound = wideAll.includes('工具');
  result.wide.toolsFoundByLabel = PALETTE_TOOLS.filter((t) =>
    wideAll.includes(t),
  );
  await capture(cdp, 'wb_p3-1-wide-palette.png');
  result.wide.labels = wideAll.slice(0, 100);
  if (!result.wide.paletteMounted) {
    result.notes.push('宽屏浮动工具面板未挂载（工具行 32×32 按钮数 < 11）');
  }

  // 2. 真实交互：点「便签」→ 点击画布 → 存档出现元素。
  const stickyCenter = await findSemanticsCenter(cdp, '便签');
  // 坐标兜底：1400 宽下浮动面板第 6 颗按钮（便签）几何中心固定。
  const stickyPoint = stickyCenter || [444, 88];
  result.interaction.stickyCenterFound = stickyCenter !== null;
  if (!stickyCenter) {
    result.notes.push('语义树未定位「便签」，改用面板几何坐标兜底');
  }
  await clickAt(cdp, stickyPoint[0], stickyPoint[1]);
  await clickAt(cdp, 900, 520);
  const archive = await waitArchive(cdp);
  if (archive) {
    result.interaction.elementCreated = elementCountOf(archive) >= 1;
    result.interaction.elementCount = elementCountOf(archive);
    result.interaction.elementTypes = (archive.pages[0].elements || []).map(
      (e) => e.type,
    );
  } else {
    result.notes.push('便签交互后存档未出现（元素未创建）');
  }
  await capture(cdp, 'wb_p3-2-after-sticky.png');

  // 3. 缩窄 600×900：浮动面板退场、底部工具条出现。
  await setViewport(cdp, 600, 900);
  await sleep(1500);
  const narrowLabels = (await collectSemanticsMerged(cdp, 5, 300)).labels;
  const narrowButtons = toolRowButtonsOf(await dumpPaletteRegion(cdp)).filter(
    (n) => n.x >= 240 && n.x <= 620,
  );
  result.narrow.paletteToolRowCount = narrowButtons.length;
  // 底部条与浮动面板同用共享 WbCanvasIconButton：tooltip 语义并入容器
  // 节点（不逐格外露），故与宽屏一致以 DOM 几何为主判据——视口底部
  // 60px 带内 role=button 连排；按钮语义节点为整槽位 34×60（非面板的
  // 32×32），撤销 / 重做区仅撤销可用时合并为 68×60 单节点。首簇
  // （间距 34）为工具行；分隔线（11 宽、无 role）后为撤销 / 重做 /
  // 更多。本场景（插入 1 元素）预期 13 颗：11 工具 + 撤销重做区 + 更多。
  const narrowBottomNodes = await dumpBottomRegion(cdp);
  const narrowBottom = narrowBottomNodes
    .filter((n) => n.role === 'button' && n.h >= 56)
    .sort((a, b) => a.x - b.x);
  result.narrow.bottomNodes = narrowBottomNodes;
  result.narrow.bottomBarButtonCount = narrowBottom.length;
  let toolsRow = narrowBottom.length > 0 ? 1 : 0;
  for (let i = 1; i < narrowBottom.length; i += 1) {
    if (narrowBottom[i].x - narrowBottom[i - 1].x <= 36) {
      toolsRow += 1;
    } else {
      break;
    }
  }
  result.narrow.bottomToolsRowCount = toolsRow;
  result.narrow.bottomExtrasSeen = narrowBottom.length - toolsRow >= 2;
  result.narrow.bottomBarMounted =
    toolsRow === 11 && result.narrow.bottomExtrasSeen;
  await capture(cdp, 'wb_p3-3-narrow-bottom-bar.png');
  result.narrow.labels = narrowLabels.slice(0, 100);
  result.narrow.paletteGone =
    narrowButtons.length === 0 &&
    !narrowLabels.includes('更多工具（专业元素 / 平行四边形 / 连线 / 3D 直绘）');
  if (!result.narrow.bottomBarMounted) {
    result.notes.push(
      '窄屏底部工具条判据未过（首簇工具行 / 撤销重做更多计数不足）',
    );
  }

  // 4. 恢复 1400×900：浮动面板回归。
  await setViewport(cdp, 1400, 900);
  await sleep(1500);
  const backLabels = (await collectSemanticsMerged(cdp, 5, 300)).labels;
  result.back.paletteToolRowCount = toolRowButtonsOf(
    await dumpPaletteRegion(cdp),
  ).filter((n) => n.x >= 240 && n.x <= 620).length;
  await capture(cdp, 'wb_p3-4-wide-back.png');
  result.back.labels = backLabels.slice(0, 100);
  result.back.paletteBackFound = result.back.paletteToolRowCount >= 11;

  ws.close();
  edge.kill();
  console.log('=== WB_WEB_TOOLBAR_PROBE_RESULT ===');
  console.log(JSON.stringify(result, null, 2));
}

main().catch((error) => {
  console.error('=== WB_WEB_TOOLBAR_PROBE_ERROR ===');
  console.error(String(error && error.stack ? error.stack : error));
  console.log(JSON.stringify(result, null, 2));
  process.exit(1);
});
