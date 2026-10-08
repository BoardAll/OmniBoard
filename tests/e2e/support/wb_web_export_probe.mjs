/**
 * Web 端导入 / 导出浏览器实测探针（Edge headless + CDP，坐标点击版）。
 *
 * 承接 wb_web_persist_probe.mjs（已证明：绘制 → localStorage 自动保存 →
 * 刷新恢复合并）。本探针验证 `.wbd` 文件互通闭环：
 *  1. 白板 A：绘制一笔 → localStorage 存档出现；
 *  2. 点 AppBar「导出 .wbd 文件」→ 截图（SnackBar）+ 下载目录出现
 *     `.wbd` 文件 → 解析文件断言元素数与存档一致；
 *  3. 白板 B（整页重载重建引擎，空画布）：劫持 `document.createElement`
 *     捕获文件选择输入框 → 点「导入 .wbd 文件」→ 用 DataTransfer 注入
 *     第 2 步下载的文件内容并派发 change → 断言白板 B 的 localStorage
 *     存档元素数与导出文件一致（导出 → 导入 → 持久化 全链路）。
 *
 * 说明：Flutter 语义树在无头环境无法激活（placeholder 点击无效），
 * AppBar 按钮改用 1280x800 视口截图量得的坐标点击；断言不依赖语义树，
 * 全部基于 localStorage / 下载文件 / 截图，结果自证。
 */

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const WebSocket = require('e:/code/whiteboard/services/realtime/node_modules/ws');

const EDGE = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const PORT = 9335;
const APP_BASE = process.env.WB_WEB_URL || 'http://localhost:8090';
const BOARD_A_ID = 'e2e-export-a';
const BOARD_B_ID = 'e2e-export-b';
const URL_A = `${APP_BASE}/#/board/${BOARD_A_ID}?name=${encodeURIComponent('E2E-A')}`;
const URL_B = `${APP_BASE}/#/board/${BOARD_B_ID}?name=${encodeURIComponent('E2E-B')}`;
const OUT_DIR = 'e:\\code\\whiteboard\\.agent_tmp';
const DOWNLOAD_DIR = path.join(OUT_DIR, 'downloads');
const PROFILE_DIR = path.join(
  process.env.TEMP || 'C:\\Windows\\Temp',
  'wb-web-e2e-profile-3',
);
const KEY_A = `wb.canvas.${BOARD_A_ID}`;
const KEY_B = `wb.canvas.${BOARD_B_ID}`;

// AppBar actions 顺序（board_edit_page.dart L270）：导出 → 导入 → …；
// 1280x800 视口下按钮中心坐标（由 wb_iex-6-semantics.png 截图量得）。
const EXPORT_BTN = { x: 1101, y: 28 };
const IMPORT_BTN = { x: 1139, y: 28 };

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const result = {
  boardA: {
    editorUrl: URL_A,
    drawnElementCount: 0,
    archiveKeySeen: false,
  },
  export: {
    clicked: false,
    downloadedFiles: [],
    exportedFileName: null,
    exportedFormat: null,
    exportedFileElementCount: 0,
  },
  boardB: {
    editorUrl: URL_B,
    importClicked: false,
    chooserIntercepted: false,
    pickerInputCaptured: false,
    pickerInputAccept: null,
    injectionResult: '',
    archiveKeySeen: false,
    importedElementCount: 0,
    importedElementTypes: [],
    payloadSource: '',
    roundTripMatched: false,
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
    this.eventHandlers = new Map();
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
        return;
      }
      if (msg.method && this.eventHandlers.has(msg.method)) {
        this.eventHandlers.get(msg.method)(msg.params || {});
      }
    });
  }

  on(method, handler) {
    this.eventHandlers.set(method, handler);
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

async function readArchive(cdp, key) {
  const raw = await cdp.eval(`localStorage.getItem(${JSON.stringify(key)})`);
  if (!raw) {
    return null;
  }
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

async function waitArchive(cdp, key, attempts = 20, interval = 400) {
  for (let i = 0; i < attempts; i += 1) {
    const data = await readArchive(cdp, key);
    if (data) {
      return data;
    }
    await sleep(interval);
  }
  return null;
}

function elementsOf(data) {
  const pages = data && Array.isArray(data.pages) ? data.pages : [];
  if (pages.length === 0) {
    return [];
  }
  return Array.isArray(pages[0].elements) ? pages[0].elements : [];
}

function listWbdFiles() {
  try {
    return fs
      .readdirSync(DOWNLOAD_DIR)
      .filter((n) => n.toLowerCase().endsWith('.wbd'));
  } catch {
    return [];
  }
}

async function waitWbdFile(attempts = 16, interval = 500) {
  for (let i = 0; i < attempts; i += 1) {
    const files = listWbdFiles();
    if (files.length > 0) {
      return files[0];
    }
    await sleep(interval);
  }
  return null;
}

async function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  try {
    fs.rmSync(DOWNLOAD_DIR, { recursive: true, force: true });
  } catch {
    /* 旧下载目录清理失败不阻塞。 */
  }
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
    await cdp.send('Browser.setDownloadBehavior', {
      behavior: 'allow',
      downloadPath: DOWNLOAD_DIR,
      eventsEnabled: true,
    });
  } catch {
    result.notes.push('Browser.setDownloadBehavior 不可用');
  }
  try {
    await cdp.send('Page.setDownloadBehavior', {
      behavior: 'allow',
      downloadPath: DOWNLOAD_DIR,
    });
  } catch {
    result.notes.push('Page.setDownloadBehavior 不可用');
  }
  try {
    await cdp.send('Page.setInterceptFileChooserDialog', { enabled: true });
  } catch {
    result.notes.push('Page.setInterceptFileChooserDialog 不可用');
  }
  cdp.on('Page.fileChooserOpened', () => {
    result.boardB.chooserIntercepted = true;
  });

  // ── 阶段 1：白板 A 绘制一笔并等待自动保存 ─────────────────────────
  await cdp.send('Page.navigate', { url: URL_A });
  await sleep(9000);
  await capture(cdp, 'wb_iex-8-a-empty.png');
  await drag(cdp, 700, 400, 950, 480);
  const archiveA = await waitArchive(cdp, KEY_A);
  await capture(cdp, 'wb_iex-9-a-drawn.png');
  if (archiveA) {
    result.boardA.archiveKeySeen = true;
    result.boardA.drawnElementCount = elementsOf(archiveA).length;
  } else {
    result.notes.push('白板 A 绘制后未出现存档（引擎或持久化异常）');
  }

  // ── 阶段 2：导出 .wbd（坐标点击 AppBar 导出按钮）─────────────────
  await clickAt(cdp, EXPORT_BTN.x, EXPORT_BTN.y);
  result.export.clicked = true;
  await sleep(1500);
  await capture(cdp, 'wb_iex-10-a-export.png');
  let wbdFile = await waitWbdFile();
  if (!wbdFile) {
    // 重试一次（按钮命中容差）。
    await clickAt(cdp, EXPORT_BTN.x, EXPORT_BTN.y);
    await sleep(1500);
    wbdFile = await waitWbdFile(8, 500);
  }
  result.export.downloadedFiles = listWbdFiles();
  if (wbdFile) {
    result.export.exportedFileName = wbdFile;
    const text = fs.readFileSync(path.join(DOWNLOAD_DIR, wbdFile), 'utf8');
    try {
      const data = JSON.parse(text);
      result.export.exportedFormat = data.format || null;
      result.export.exportedFileElementCount = elementsOf(data).length;
    } catch {
      result.notes.push('导出文件不是合法 JSON');
    }
  } else {
    result.notes.push('导出未产出 .wbd 下载文件');
  }

  // ── 阶段 3：白板 B 整页重载 → 导入第 2 步文件 → 持久化断言 ────────
  let payload = null;
  if (wbdFile) {
    payload = fs.readFileSync(path.join(DOWNLOAD_DIR, wbdFile), 'utf8');
    result.boardB.payloadSource = 'downloaded-file';
  } else if (archiveA) {
    payload = JSON.stringify(archiveA);
    result.boardB.payloadSource = 'archive-fallback';
    result.notes.push('无下载文件：回退用白板 A 存档内容测试导入链路');
  }

  await cdp.send('Page.navigate', { url: 'about:blank' });
  await sleep(800);
  await cdp.send('Page.navigate', { url: URL_B });
  await sleep(10000);
  await capture(cdp, 'wb_iex-11-b-empty.png');

  if (payload) {
    // 劫持 createElement 捕获 wbPickTextFile 创建的文件输入框。
    await cdp.eval(`(() => {
      window.__wbInput = null;
      const orig = document.createElement.bind(document);
      document.createElement = function (tag, ...rest) {
        const el = orig(tag, ...rest);
        if (String(tag).toLowerCase() === 'input') {
          window.__wbInput = el;
        }
        return el;
      };
      return true;
    })()`);

    await clickAt(cdp, IMPORT_BTN.x, IMPORT_BTN.y);
    result.boardB.importClicked = true;
    await sleep(1200);

    const inputInfo = await cdp.eval(`(() => {
      const input = window.__wbInput;
      if (!input) { return null; }
      return { type: input.type || '', accept: input.accept || '' };
    })()`);
    if (inputInfo) {
      result.boardB.pickerInputCaptured = inputInfo.type === 'file';
      result.boardB.pickerInputAccept = inputInfo.accept;
    }

    await cdp.eval(`window.__wbPayload = ${JSON.stringify(payload)}; true`);
    result.boardB.injectionResult = await cdp.eval(`(() => {
      const input = window.__wbInput;
      if (!input) { return 'no-input'; }
      if (!window.__wbPayload) { return 'no-payload'; }
      try {
        const dt = new DataTransfer();
        dt.items.add(new File([window.__wbPayload], 'roundtrip.wbd', {
          type: 'application/json',
        }));
        input.files = dt.files;
        input.dispatchEvent(new Event('change', { bubbles: true }));
        return 'injected';
      } catch (e) {
        return 'error:' + String(e);
      }
    })()`);

    const archiveB = await waitArchive(cdp, KEY_B, 25, 400);
    if (archiveB) {
      const elements = elementsOf(archiveB);
      result.boardB.archiveKeySeen = true;
      result.boardB.importedElementCount = elements.length;
      result.boardB.importedElementTypes = elements.map(
        (e) => `${e.type}:${(e.points || []).length}`,
      );
      result.boardB.roundTripMatched =
        elements.length > 0 &&
        elements.length === result.export.exportedFileElementCount;
    } else {
      result.notes.push('白板 B 导入后未出现存档（导入链路或持久化异常）');
    }
    await capture(cdp, 'wb_iex-12-b-imported.png');
  }

  ws.close();
  edge.kill();
  console.log('=== WB_WEB_EXPORT_PROBE_RESULT ===');
  console.log(JSON.stringify(result, null, 2));
}

main().catch((error) => {
  console.error('=== WB_WEB_EXPORT_PROBE_ERROR ===');
  console.error(String(error && error.stack ? error.stack : error));
  console.log(JSON.stringify(result, null, 2));
  process.exit(1);
});
