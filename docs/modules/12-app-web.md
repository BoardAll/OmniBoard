# 12 · app-web —— Web 应用

> 模块路径：`apps/web`（`apps/mobile` 仅含 `pubspec.yaml`，预留）
> 维护 agent：`wb-app-web-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：白板 Web 应用（包名 `whiteboard_web`）——
  - 白板列表页 / 编辑页（演示数据闭环：列表 → 编辑 → 返回）；
  - 响应式布局：列表页 600px 断点（宽屏网格 / 窄屏列表）；编辑页 `kWideBreakpoint=840`（宽屏左侧 240px 工具面板 + 画布区，窄屏单栏 + 60px 底部工具栏）；
  - 主题切换（复用 `whiteboard_theme` 的 `WbThemeManager`，9 个内置主题）；
  - WASM 核心接线（`WbCoreService` → `WbCoreLoader`）：首帧后按需加载，失败降级内置演示画布，状态可视化（`WbCoreStatusChip`）；
  - Socket.IO JS 客户端桥（T0.2 POC）：动态脚本加载 + `dart:js_interop` externals + `WbSocketIoBridge` 传输抽象（详见 §2.6）；
  - W1 实时协作层（T1.8）：`WbRealtimeService`（成员 / 连接状态 / presence 元数据）→ 连接状态 chip + 参与者列表 UI（详见 §2.7；**不含画布 op 协作，W2 后置**）；
  - Web 宿主配置（`web/`：`index.html`、`manifest.json`、图标、`wb_core.js` 占位脚本）。
- **不负责**：WASM 加载器与 JS 互操作细节、窗口能力（→ [10-dart-platform](10-dart-platform.md) `platform/web`）；UI 组件与主题定义（→ [08-dart-ui](08-dart-ui.md)）；HTTP 服务客户端（→ [09-dart-client](09-dart-client.md)）；WASM 核心 C++ 实现（→ 01～06 C++ 模块，真实产物经 Emscripten 构建）；realtime 服务端（→ 13～16 服务模块）；画布 op 协作（W2 后置）。
- **地位**：两个应用之一（与 11 桌面应用并列）；依赖 08/09/10 的包；**不 import core_dart**（`whiteboard_core` 在 pubspec 声明但代码未直接引用，WASM 路径统一经 `whiteboard_web_platform`）。
- **预留**：`apps/mobile` 仅含 `pubspec.yaml`（移动端应用预留，未实现）。
- **已知状态（如实记录）**：`web/wb_core.js` 为占位脚本（Wave 4 产出真实 WASM 前，编辑页以演示画布降级运行、不阻塞 UI）；`test/` 共 **72 用例（VM）+ 12 用例 browser-only**（`--platform chrome`）全绿；Socket.IO JS 桥已对本机 :8790 实测连通（T0.2，见 §2.6）；W1 协作层（T1.8）已对本机 :8790 完成浏览器真连冒烟（2 用例，见 §2.7）。

## 2. 功能 → 文件映射

### 2.1 入口与路由

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 应用入口（`main`，启动 `WhiteboardWebApp`） | `apps/web/lib/main.dart` | `apps/web/test/widget_test.dart`（5 用例） |
| 应用壳 `WhiteboardWebApp`（`MultiProvider` + `MaterialApp.router`；`WbWebThemeState` / `WbCoreService` / `WbRealtimeService` 可注入供测试） | `apps/web/lib/app.dart` | 同上 |
| 路由 `WbWebRoutes` / `createWebRouter`（`/` 列表页、`/board/:boardId` 编辑页；`boardPath` 携带 `name` 查询参数） | `apps/web/lib/routes.dart` | 同上 |

### 2.2 页面

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 白板列表页（演示数据 `wbDemoBoards` 3 条、新建入口、响应式 ≥600 网格 / <600 列表、主题菜单 `_ThemeMenu`、相对时间） | `apps/web/lib/pages/board_list_page.dart` | `apps/web/test/widget_test.dart` |
| 白板编辑页（`kWideBreakpoint=840`；宽屏 `_ToolPanel` 240px + 分隔线 + 画布；窄屏单栏 + `_BottomToolBar` 60px；`_FallbackBanner` 降级提示；`_FullscreenButton` → `WebWindowPlugin`；首帧后触发 WASM 初始化 + W1 协作连接；AppBar 协作状态 chip + 参与者入口 `endDrawer`；退出 `leave()`） | `apps/web/lib/pages/board_edit_page.dart` | 同上 + `collab_widget_test.dart` + `test/integration/` |

### 2.3 服务、状态与组件

| 功能 | 实现文件 | 测试 |
|---|---|---|
| WASM 核心服务 `WbCoreService`（ChangeNotifier；`initialize()` 幂等、失败不抛异常；`status` / `isAvailable`） | `apps/web/lib/services/wb_core_service.dart` | `apps/web/test/integration/wasm_load_test.dart`（12 用例）等 |
| 主题状态 `WbWebThemeState`（包装 `WbThemeManager`，默认 `clean-professional`，`select` 切换） | `apps/web/lib/state/theme_state.dart` | `apps/web/test/widget_test.dart` |
| 核心状态 chip `WbCoreStatusChip`（四态文案：引擎待命 / 引擎加载中 / 引擎就绪 / 演示画布） | `apps/web/lib/widgets/core_status_chip.dart` | 同上 + `wasm_load_test.dart` |
| 演示画布 `WbDemoCanvas`（key `wb-demo-canvas`；20px 网格 + 3 张示例卡；WASM 不可用 / 就绪前的降级视图） | `apps/web/lib/widgets/demo_canvas.dart` | 同上 |
| Socket.IO JS 桥（T0.2 POC）：动态脚本加载 + `dart:js_interop` externals + 可注入传输抽象（条件导入：Web 实现 / VM 桩） | `apps/web/lib/services/socketio_js.dart`、`socketio_js_types.dart`、`socketio_js_web.dart`、`socketio_js_stub.dart` | `apps/web/test/socketio_js_vm_test.dart`（3 用例）；`socketio_js_poc_test.dart`（browser-only） |
| W1 实时协作服务 `WbRealtimeService`（ChangeNotifier；连接状态机 + `board:session/joined/participants/room:error` 处理 + 参与者增量合并；`connect` / `joinBoard` / `leave`；脚本加载器 / 桥工厂可注入——详见 §2.7） | `apps/web/lib/services/realtime_service.dart` | `apps/web/test/realtime_service_test.dart`（23 用例） |
| 协作 UI（`widgets/collab/`）：状态 chip `WbCollabStatusChip`（key `wb-collab-status-chip`；idle 隐藏）、参与者面板 `WbParticipantsPanel`（endDrawer；key `wb-participants-panel`）、入口按钮 `WbParticipantsButton`（在线人数徽标；key `wb-participants-button`） | `apps/web/lib/widgets/collab/collab_status_chip.dart`、`participants_panel.dart`、`participants_button.dart` | `apps/web/test/collab_widget_test.dart`（6 用例） |

### 2.4 Web 宿主（`apps/web/web/`）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 宿主页（`flutter_bootstrap.js` 引导；`wb_core.js` 按需注入说明；`$FLUTTER_BASE_HREF` base 占位） | `apps/web/web/index.html` | —（部署时验证） |
| PWA 清单（192/512 + maskable 图标、主题色 `#2E6BE6`） | `apps/web/web/manifest.json` | — |
| `wb_core.js` 占位脚本（不定义 `window.WbCore` → 探测为 unavailable，驱动演示画布降级；真实产物由构建覆盖） | `apps/web/web/wb_core.js` | — |
| 图标资源 | `apps/web/web/favicon.png`、`apps/web/web/icons/`（Icon-192 / Icon-512 / Icon-maskable-192 / Icon-maskable-512） | — |

> `apps/web/build/`（50 个文件）为构建生成目录，不入映射；`.dart_tool/`、`.idea/` 同理。

### 2.5 测试（`apps/web/test/`，共 72 用例 VM + 12 用例 browser-only）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| widget 冒烟（5 用例：列表页 / 编辑页 / 响应式） | `apps/web/test/widget_test.dart` | — |
| WASM 命令链路（7 用例） | `apps/web/test/integration/wasm_command_test.dart` | — |
| WASM 加载与降级（12 用例） | `apps/web/test/integration/wasm_load_test.dart` | — |
| WASM 内存（10 用例） | `apps/web/test/integration/wasm_memory_test.dart` | — |
| WASM 渲染（6 用例） | `apps/web/test/integration/wasm_render_test.dart` | — |
| Socket.IO 桥 VM 桩（3 用例：加载抛 `WbSocketIoLoadException` / `UnsupportedPlatform` 回调 / `emitWithAck` 抛 `UnsupportedError`） | `apps/web/test/socketio_js_vm_test.dart` | — |
| Socket.IO 浏览器连通 POC（10 用例，browser-only：加载幂等 / session / join+ping / echo 广播 / direct / volatile / websocket-only / polling-only / default 升级 / gated 拒连；文件须在 `test/` 根目录） | `apps/web/test/socketio_js_poc_test.dart` | — |
| W1 协作服务（23 用例：连接状态机 / join 挂起与补发 / 快照全量替换 / 参与者 joined-updated-left 增量 / room:error / leave-dispose / 数据模型容错） | `apps/web/test/realtime_service_test.dart` | — |
| W1 协作 UI（6 用例：默认降级 chip 与面板、已连接徽标与列表、断线重连保留、窄屏 600、列表页无协作 UI、idle 隐藏） | `apps/web/test/collab_widget_test.dart` | — |
| W1 浏览器真连冒烟（2 用例，browser-only：连接 + `board:session` 匿名回落 / join 快照 + 双连接互见 + leave 增量；文件须在 `test/` 根目录） | `apps/web/test/realtime_web_smoke_test.dart` | — |

> 假桥支持文件 `apps/web/test/support/fake_socketio_bridge.dart`（记录调用 + 手动触发事件；非 `_test.dart` 后缀，不被当作用例执行）。

### 2.6 Socket.IO JS 桥（T0.2 POC，Wave 1 实测）

- **文件落点**（`lib/services/`，接口与实现分离）：`socketio_js.dart`（入口：条件导入 + `loadSocketIoClient` / `createWbSocketIoBridge` 对外 API）；`socketio_js_types.dart`（`WbSocketIoBridge` 桥接口与类型：connect/on/off/emit/emitWithAck/volatileEmit/disconnect + 连接状态回调）；`socketio_js_web.dart`（浏览器实现：`dart:js_interop` externals 包装全局 `io()` 及 socket/engine/volatile API）；`socketio_js_stub.dart`（VM 桩：不触 JS，连接回调 `UnsupportedPlatform`）。
- **脚本加载策略**：`loadSocketIoClient(endpoint)` 幂等注入 `<script src="{endpoint}/socket.io/socket.io.min.js">`——文件由 socket.io@4 服务端自动托管，**版本随服务端、零 npm 依赖**；同 endpoint 复用同一 Future；以 `globalThis.io` 为函数判定加载完成，失败抛 `WbSocketIoLoadException`（不阻塞 UI）。
- **传输抽象**：realtime 接线注入 `WbSocketIoBridge`——VM（纯 Dart）测试不加载 JS（走桩），仅浏览器路径走 js_interop 桥；W1 服务层注入用法见 §2.7。
- **浏览器连通结论（2026-09-30，本机 :8790）**：`flutter test --no-pub --platform chrome test\socketio_js_poc_test.dart` 两轮全绿（主轮 `+9 ~1`，gated 轮 `--dart-define=WB_POC_BAD_TOKEN=...` `+10`）。覆盖：连接成功、`board:session`（userId/authMode）、`board:join` + `board:ping` ack、`board:echo` 自端不广播且第二连接收到 `board:broadcast`、`board:direct` 单播、拒连 `code=Unauthorized`。
- **volatile / transport / polling 结论**：`socket.volatile.emit` 存在且送达（以 `board:joined` 回执实证，非仅 API 存在）；`engine.transport.name`：websocket-only 连接为 `websocket`；default transports 观测到 `polling → websocket` 升级（实测 0～125ms）；`transports:['polling']` 保持 `polling`、800ms 内不升级。
- **CORS 注意**：服务端 POC 阶段 `origin:'*'`（宽松）；生产接线需由服务端收敛 origin 白名单（服务端范畴，本模块不动）。
- **Windows 平台注意**：① 浏览器测试文件**必须放 `test/` 根目录**——flutter_tools 对子目录生成 `window.testSelector` 时反斜杠转义丢失，致 "Web test ... not found" 挂起；② 运行依赖 `test/canvaskit/` 资源兜底（flutter_tools 直供 canvaskit 404 的 workaround，可从 Flutter SDK `flutter_web_sdk/canvaskit` 重建，已 gitignore）；③ JS→Dart 事件回调一律用**可选位置参数** `([JSAny? _]) {...}`——DDC 严格校验实参个数，0 参事件（如 `connect`）会抛 `NoSuchMethodError` 中断回调链。

### 2.7 W1 实时协作层（T1.8，Wave 1 实测）

- **口径（D-H）**：Web M1 = **W1 层**（参与者列表 / 连接状态可见）；**不发送、不应用画布 op**（画布协作 W2 后置，依赖 WASM 核心）。
- **服务 API（`WbRealtimeService`，ChangeNotifier + Provider 注入）**：
  - `connect(endpoint, {token})`——幂等、失败不抛异常；endpoint 归一化（去空白 / 尾部 `/`），实际连接 `{endpoint}/board`；`kWbRealtimeEndpoint` 默认 `http://127.0.0.1:8790`，可 `--dart-define=WB_REALTIME_ENDPOINT=...` 覆盖；
  - `joinBoard(boardId, {pageId})`——未连接时挂起记录，连接 / 重连成功后自动补发（重连时服务端参与者表已随断开清除）；
  - `leave()`——先发 `board:leave`（800ms ack 超时兜底）再本地断开；幂等；旧桥回调经 identity 守卫与本实例隔离；
  - 读侧：`status`（`WbRealtimeStatus{idle,connecting,connected,reconnecting,disconnected}`）/ `userId` / `authMode` / `boardId` / `role` / `mode` / `participants`（不可变列表，插入序）/ `lastError` / `isConnected`；
  - 注入点（D-G 测试用）：`clientLoader`（缺省 `loadSocketIoClient`）+ `bridgeFactory`（缺省 `createWbSocketIoBridge`）。
- **事件处理（§6 契约）**：`board:session`（`userId/authMode/role`）、`board:joined`（快照全量替换 `participants` 并更新 `boardId/role/mode`）、`board:participants`（`joined/updated` 按 socketId 合并（替换保序）、`left` 移除）、`room:error`（记入 `lastError`，不改连接状态）；畸形载荷一律忽略不崩溃。
- **状态机**：`idle → connecting → connected`；意外断线（非 `io server/client disconnect`）→ `reconnecting`（socket.io 自动退避重试；重连尝试失败保持「重连中」）；重连成功 → `connected` 并自动补 `board:join`；首连失败 / `io server disconnect` / 主动 `leave` → `disconnected`。
- **UI 挂载点（`board_edit_page`，最小侵入）**：AppBar `title` 行内追加 `WbCollabStatusChip`（`idle` 时不占位）；`actions` 内 `WbParticipantsButton` → `Scaffold.endDrawer = WbParticipantsPanel`；页面 `initState` 首帧后 `connect + joinBoard(widget.boardId)`、`dispose` 中 `leave()`（全程 `unawaited`，不阻塞 UI）。布局断点不变（840 / 240px / 60px），协作入口在窄屏（如 600）同样可用。
- **传输差异补充（W1 层；T0.2 已记录项不复述）**：① 服务的事件 `on()` 注册严格在桥 `connect()` 之后（桥契约）；② `io server/client disconnect` 不自动重连（socket.io 语义）→ 服务映射为 `disconnected`；③ 重连成功后需重新 `board:join`（服务自动补发）；④ `leave` 的 800ms ack 超时兜底——服务端不可达时页面退出不悬挂；⑤ VM 下脚本加载失败（`WbSocketIoLoadException`）收敛为 `disconnected + lastError`，UI 降级「未连接」（真实浏览器路径与 VM 测试分流，互不影响）。
- **浏览器真连结论（2026-09-30，本机 :8790）**：`flutter test --no-pub --platform chrome test\realtime_web_smoke_test.dart` 全绿（`+2`；Edge 兜底）。覆盖：连接 + `board:session`（`anon-*` / `anonymous` 匿名回落）、`board:joined` 快照含自身（role `Participant`）、双连接互见（A/B 各收对方 joined 增量）、B `leave()` → A 收 left 增量。

## 3. 契约与依赖

- **路由契约**：`/`（`boardList`）与 `/board/:boardId`（`boardEdit`，查询参数 `name`）；路径生成统一走 `WbWebRoutes`，勿在页面内手拼字符串。
- **响应式断点（回归依据）**：列表页 600px（`constraints.maxWidth >= 600` 网格 / 否则列表）；编辑页 `kWideBreakpoint = 840`。修改断点或布局结构会影响 `widget_test.dart` 的布局断言。
- **WASM 降级链**：编辑页首帧后 `WbCoreService.initialize()`（幂等）→ `WbCoreLoader.load()` → `WbCoreStatus`（idle→loading→ready/unavailable，失败不抛异常）→ `WbCoreStatusChip` 展示 → 画布降级 `WbDemoCanvas`（key `wb-demo-canvas`）。加载器行为契约见 [10-dart-platform](10-dart-platform.md)。
- **Socket.IO 桥契约（T0.2）**：统一经 `createWbSocketIoBridge()` + `loadSocketIoClient()`（`socketio_js.dart`）访问；`WbSocketIoBridge` 为唯一传输抽象，VM/浏览器分流由条件导入保证（勿在 UI 层直接 `dart:js_interop`）；客户端脚本仅从服务端 `{endpoint}/socket.io/socket.io.min.js` 加载，不加 npm 依赖。
- **W1 协作服务契约（T1.8）**：协作链路统一经 `WbRealtimeService`（底层桥经构造注入，勿在 UI 层直触 `WbSocketIoBridge`）；协作 UI 组件从 Provider 读服务；`idle` 态不展示协作 UI（单机模式功能零阻塞）；**W1 层不发送 / 应用画布 op**（W2 后置）。
- **主题契约**：`WbWebThemeState` 包装 `WbThemeManager`（`whiteboard_theme`），默认主题 `clean-professional`，`_ThemeMenu` 遍历 `theme.available`（9 个内置主题）；颜色一律取 `context.wbColors` / `WbThemeColors`，勿硬编码色值。
- **依赖**：path 依赖 `whiteboard_ui` / `whiteboard_ui_kit` / `whiteboard_theme` / `whiteboard_icons` / `whiteboard_api_client` / `whiteboard_web_platform`（10）+ `go_router` / `provider`；**不依赖 core_dart**（`whiteboard_core` 已声明未引用，属待清理项，是否移除请协调者裁决）。
- **被依赖**：无（终端应用）；部署宿主为静态服务器 + `web/` 目录产物。

## 4. 常用命令

```powershell
# 静态分析 + 测试（72 用例；browser-only 文件在 VM 下自动跳过）
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat analyze --no-pub
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub

# 本地运行（Chrome）/ 构建（部署 web/ 产物到静态服务器）
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat run -d chrome
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat build web --release

# 浏览器连通 POC（T0.2；需先启动服务：cd services\realtime; node dist\server.js → :8790）
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub --platform chrome test\socketio_js_poc_test.dart

# W1 协作浏览器真连冒烟（T1.8；同样需先启动 realtime :8790）
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub --platform chrome test\realtime_web_smoke_test.dart
# 本机无 Chrome 时用 Edge 兜底：$env:CHROME_EXECUTABLE='C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
# gated 拒连轮次（T0.2）：服务端带 WB_JWT_SECRET 启动，并追加 --dart-define=WB_POC_BAD_TOKEN=invalid.token.value
```

## 5. 变更影响提醒（改本模块时注意）

- 修改路由（`WbWebRoutes`）→ `widget_test.dart` 与部署侧外部链接同步；路径是唯一来源，勿散落硬编码。
- 修改响应式断点 / 布局（600、840、240px、60px）→ `test/widget_test.dart` 布局断言必须同步更新。
- 修改 WASM 接线 / 降级行为 → 联动 **10 dart-platform**（`WbCoreStatus`、加载器契约）与 `test/integration/wasm_*` 断言；改断言前先读 10 号文档。
- 修改 Socket.IO JS 桥（`socketio_js_*.dart`）→ 保持 `WbSocketIoBridge` 接口稳定（Web 实现与 VM 桩同步改）；JS→Dart 回调一律可选位置参数（DDC 实参个数校验）；浏览器测试文件保持在 `test/` 根目录运行；**不得新增 npm 依赖**（客户端脚本由服务端提供）。
- 修改 W1 协作层（`realtime_service.dart`、`widgets/collab/`、编辑页接线）→ `test/realtime_service_test.dart` / `test/collab_widget_test.dart` 断言同步；状态枚举与文案（连接中 / 已连接 / 重连中 / 未连接）变化会影响 widget 断言；守住「W1 不发画布 op」边界；浏览器冒烟命令见 §4。
- 修改 `web/index.html` / `manifest.json` / `wb_core.js` 占位约定（`window.WbCore` 工厂）→ 影响部署与 **17 build-release** 的 Web 构建产物约定（真实产物覆盖占位脚本）。
- 新增页面 / 组件时复用 08-ui 包（`whiteboard_theme` / `whiteboard_icons` / `whiteboard_ui_kit`），不复制样式代码；**不得新增对 core_dart 的直接依赖**（WASM 路径经 10）。
- `apps/mobile` 为预留目录：新增移动端实现不属于本模块，先与协调者确认归属规范。
