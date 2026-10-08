/**
 * Web 端持久化 + 导入导出浏览器实测探针（Edge headless + CDP）。
 *
 * 验证链路（《Web 端方案设计》持久化补充）：
 *  1. 打开白板编辑页，等待 WASM 引擎加载；
 *  2. 在画布上模拟鼠标拖拽绘制一笔；
 *  3. 断言 localStorage 出现存档键 `wb.canvas.<boardId>`（自动保存）；
 *  4. 刷新页面（引擎重建为空）后再次绘制；
 *  5. 断言刷新后存档元素数 = 第一笔 + 第二笔（证明恢复 + 回灌后合并，
 *     而非被覆写为仅第二笔）；
 *  6. （语义树可用时）按 aria-label 定位「导出 .wbd 文件」按钮并点击，
 *     检查 SnackBar / 下载目录。
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
const PORT = 9333;
const BOARD_ID = 'e2e-persist';
const BOARD_NAME = 'E2E持久化';
const APP_BASE = process.env.WB_WEB_URL || 'http://localhost:8090';
const EDITOR_URL = `${APP_BASE}/#/board/${BOARD_ID}?name=${encodeURIComponent(BOARD_NAME)}`;
const OUT_DIR = 'e:\\code\\whiteboard\\.agent_tmp';
const DOWNLOAD_DIR = path.join(OUT_DIR, 'downloads');
const PROFILE_DIR = path.join(
  process.env.TEMP || 'C:\\Windows\\Temp',
  'wb-web-e2e-profile',
);
const STORAGE_KEY = `wb.canvas.${BOARD_ID}`;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const result = {
  editorUrl: EDITOR_URL,
  semanticsEnabled: false,
  firstStrokeSaved: false,
  firstStrokeElementCount: 0,
  restoredAndMerged: false,
  secondStrokeElementCount: 0,
  elementTypes: [],
  appBarLabels: [],
  exportButtonFound: false,
  exportSnackBarSeen: false,
  importButtonFound: false,
  downloadFiles: [],
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

async function drag(cdp, x1, y1, x2, y2, steps = 10) {
  await cdp.send('Input.dispatchMouseEvent', {
    type: 'mousePressed',
    x: x1,
    y: y1,
    button: 'left',
    clickCount: 1,
    pointerType: 'mouse',
  });
  for (let i = 1; i <= steps; i += 1) {
    await cdp.send('Input.dispatchMouseEvent', {
      type: 'mouseMoved',
      x: x1 + ((x2 - x1) * i) / steps,
      y: y1 + ((y2 - y1) * i) / steps,
      button: 'left',
      buttons: 1,
      pointerType: 'mouse',
    });
    await sleep(16);
  }
  await cdp.send('Input.dispatchMouseEvent', {
    type: 'mouseReleased',
    x: x2,
    y: y2,
    button: 'left',
    clickCount: 1,
    pointerType: 'mouse',
  });
  await sleep(400);
}

async function readArchive(cdp) {
  const raw = await cdp.eval(`localStorage.getItem(${JSON.stringify(STORAGE_KEY)})`);
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
async function waitArchive(cdp, attempts = 20, interval = 400) {
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
}

async function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  fs.mkdirSync(DOWNLOAD_DIR, { recursive: true });
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
  await cdp.send('Emulation.setDeviceMetricsOverride', {
    width: 1280,
    height: 800,
    deviceScaleFactor: 1,
    mobile: false,
  });
  try {
    await cdp.send('Page.setDownloadBehavior', {
      behavior: 'allow',
      downloadPath: DOWNLOAD_DIR,
    });
  } catch {
    result.notes.push('Page.setDownloadBehavior 不可用（跳过下载目录断言）');
  }

  // 1. 进入编辑页并等待引擎加载。
  await cdp.send('Page.navigate', { url: EDITOR_URL });
  await sleep(9000);
  await capture(cdp, 'wb_iex-1-editor.png');

  // 尝试激活 Flutter 语义树（AppBar 文案可读）。
  try {
    const activated = await cdp.eval(
      `(() => { const p = document.querySelector('flt-semantics-placeholder'); if (!p) { return false; } p.click(); return true; })()`,
    );
    await sleep(1500);
    const labels = await collectSemantics(cdp);
    result.semanticsEnabled = activated === true && labels.length > 0;
    result.appBarLabels = labels.slice(0, 40);
  } catch {
    result.notes.push('语义树激活失败（AppBar 文案不可读）');
  }

  // 2. 第一笔：画布中央拖拽。
  await drag(cdp, 700, 400, 950, 480);
  const archive1 = await waitArchive(cdp);
  await capture(cdp, 'wb_iex-2-drawn.png');
  if (archive1) {
    result.firstStrokeSaved = true;
    result.firstStrokeElementCount = elementCountOf(archive1);
    result.elementTypes = (archive1.pages[0].elements || []).map(
      (e) => `${e.type}:${(e.points || []).length}`,
    );
  } else {
    result.notes.push('第一笔未写穿存档（引擎可能未就绪）');
  }

  // 3. 刷新（引擎重建为空）→ 第二笔 → 断言合并。
  await cdp.send('Page.reload', {});
  await sleep(9000);
  await capture(cdp, 'wb_iex-3-after-reload.png');
  await drag(cdp, 700, 600, 950, 650);
  const archive2 = await waitArchive(cdp);
  await capture(cdp, 'wb_iex-4-second-stroke.png');
  if (archive2) {
    result.secondStrokeElementCount = elementCountOf(archive2);
    result.restoredAndMerged =
      result.secondStrokeElementCount > result.firstStrokeElementCount &&
      result.firstStrokeElementCount >= 1;
  }

  // 4. 导出 / 导入按钮（语义树可用时按 aria-label 定位）。
  if (result.semanticsEnabled) {
    const labels = await collectSemantics(cdp);
    result.appBarLabels = labels.slice(0, 60);
    result.exportButtonFound = labels.some((l) => l.includes('导出 .wbd'));
    result.importButtonFound = labels.some((l) => l.includes('导入 .wbd'));
    if (result.exportButtonFound) {
      const center = await findSemanticsCenter(cdp, '导出 .wbd');
      if (center) {
        await clickAt(cdp, center[0], center[1]);
        await sleep(900);
        await capture(cdp, 'wb_iex-5-export-click.png');
        const afterLabels = await collectSemantics(cdp);
        result.exportSnackBarSeen = afterLabels.some((l) => l.includes('已导出'));
      }
    }
    await sleep(1200);
    try {
      result.downloadFiles = fs.readdirSync(DOWNLOAD_DIR);
    } catch {
      result.downloadFiles = [];
    }
  } else {
    result.notes.push('语义树不可用：导出 / 导入按钮存在性未程序化验证');
  }

  ws.close();
  edge.kill();
  console.log('=== WB_WEB_PERSIST_PROBE_RESULT ===');
  console.log(JSON.stringify(result, null, 2));
}

main().catch((error) => {
  console.error('=== WB_WEB_PERSIST_PROBE_ERROR ===');
  console.error(String(error && error.stack ? error.stack : error));
  console.log(JSON.stringify(result, null, 2));
  process.exit(1);
});
