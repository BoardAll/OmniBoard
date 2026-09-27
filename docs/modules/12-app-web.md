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
  - Web 宿主配置（`web/`：`index.html`、`manifest.json`、图标、`wb_core.js` 占位脚本）。
- **不负责**：WASM 加载器与 JS 互操作细节、窗口能力（→ [10-dart-platform](10-dart-platform.md) `platform/web`）；UI 组件与主题定义（→ [08-dart-ui](08-dart-ui.md)）；服务客户端（→ [09-dart-client](09-dart-client.md)）；WASM 核心 C++ 实现（→ 01～06 C++ 模块，真实产物经 Emscripten 构建）。
- **地位**：两个应用之一（与 11 桌面应用并列）；依赖 08/09/10 的包；**不 import core_dart**（`whiteboard_core` 在 pubspec 声明但代码未直接引用，WASM 路径统一经 `whiteboard_web_platform`）。
- **预留**：`apps/mobile` 仅含 `pubspec.yaml`（移动端应用预留，未实现）。
- **已知状态（如实记录）**：`web/wb_core.js` 为占位脚本（Wave 4 产出真实 WASM 前，编辑页以演示画布降级运行、不阻塞 UI）；`test/` 共 40 用例全绿。

## 2. 功能 → 文件映射

### 2.1 入口与路由

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 应用入口（`main`，启动 `WhiteboardWebApp`） | `apps/web/lib/main.dart` | `apps/web/test/widget_test.dart`（5 用例） |
| 应用壳 `WhiteboardWebApp`（`MultiProvider` + `MaterialApp.router`；`WbWebThemeState` / `WbCoreService` 可注入供测试） | `apps/web/lib/app.dart` | 同上 |
| 路由 `WbWebRoutes` / `createWebRouter`（`/` 列表页、`/board/:boardId` 编辑页；`boardPath` 携带 `name` 查询参数） | `apps/web/lib/routes.dart` | 同上 |

### 2.2 页面

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 白板列表页（演示数据 `wbDemoBoards` 3 条、新建入口、响应式 ≥600 网格 / <600 列表、主题菜单 `_ThemeMenu`、相对时间） | `apps/web/lib/pages/board_list_page.dart` | `apps/web/test/widget_test.dart` |
| 白板编辑页（`kWideBreakpoint=840`；宽屏 `_ToolPanel` 240px + 分隔线 + 画布；窄屏单栏 + `_BottomToolBar` 60px；`_FallbackBanner` 降级提示；`_FullscreenButton` → `WebWindowPlugin`；首帧后触发 WASM 初始化） | `apps/web/lib/pages/board_edit_page.dart` | 同上 + `test/integration/` |

### 2.3 服务、状态与组件

| 功能 | 实现文件 | 测试 |
|---|---|---|
| WASM 核心服务 `WbCoreService`（ChangeNotifier；`initialize()` 幂等、失败不抛异常；`status` / `isAvailable`） | `apps/web/lib/services/wb_core_service.dart` | `apps/web/test/integration/wasm_load_test.dart`（12 用例）等 |
| 主题状态 `WbWebThemeState`（包装 `WbThemeManager`，默认 `clean-professional`，`select` 切换） | `apps/web/lib/state/theme_state.dart` | `apps/web/test/widget_test.dart` |
| 核心状态 chip `WbCoreStatusChip`（四态文案：引擎待命 / 引擎加载中 / 引擎就绪 / 演示画布） | `apps/web/lib/widgets/core_status_chip.dart` | 同上 + `wasm_load_test.dart` |
| 演示画布 `WbDemoCanvas`（key `wb-demo-canvas`；20px 网格 + 3 张示例卡；WASM 不可用 / 就绪前的降级视图） | `apps/web/lib/widgets/demo_canvas.dart` | 同上 |

### 2.4 Web 宿主（`apps/web/web/`）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 宿主页（`flutter_bootstrap.js` 引导；`wb_core.js` 按需注入说明；`$FLUTTER_BASE_HREF` base 占位） | `apps/web/web/index.html` | —（部署时验证） |
| PWA 清单（192/512 + maskable 图标、主题色 `#2E6BE6`） | `apps/web/web/manifest.json` | — |
| `wb_core.js` 占位脚本（不定义 `window.WbCore` → 探测为 unavailable，驱动演示画布降级；真实产物由构建覆盖） | `apps/web/web/wb_core.js` | — |
| 图标资源 | `apps/web/web/favicon.png`、`apps/web/web/icons/`（Icon-192 / Icon-512 / Icon-maskable-192 / Icon-maskable-512） | — |

> `apps/web/build/`（48 个文件）为构建生成目录，不入映射；`.dart_tool/`、`.idea/` 同理。

### 2.5 测试（`apps/web/test/`，共 40 用例）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| widget 冒烟（5 用例：列表页 / 编辑页 / 响应式） | `apps/web/test/widget_test.dart` | — |
| WASM 命令链路（7 用例） | `apps/web/test/integration/wasm_command_test.dart` | — |
| WASM 加载与降级（12 用例） | `apps/web/test/integration/wasm_load_test.dart` | — |
| WASM 内存（10 用例） | `apps/web/test/integration/wasm_memory_test.dart` | — |
| WASM 渲染（6 用例） | `apps/web/test/integration/wasm_render_test.dart` | — |

## 3. 契约与依赖

- **路由契约**：`/`（`boardList`）与 `/board/:boardId`（`boardEdit`，查询参数 `name`）；路径生成统一走 `WbWebRoutes`，勿在页面内手拼字符串。
- **响应式断点（回归依据）**：列表页 600px（`constraints.maxWidth >= 600` 网格 / 否则列表）；编辑页 `kWideBreakpoint = 840`。修改断点或布局结构会影响 `widget_test.dart` 的布局断言。
- **WASM 降级链**：编辑页首帧后 `WbCoreService.initialize()`（幂等）→ `WbCoreLoader.load()` → `WbCoreStatus`（idle→loading→ready/unavailable，失败不抛异常）→ `WbCoreStatusChip` 展示 → 画布降级 `WbDemoCanvas`（key `wb-demo-canvas`）。加载器行为契约见 [10-dart-platform](10-dart-platform.md)。
- **主题契约**：`WbWebThemeState` 包装 `WbThemeManager`（`whiteboard_theme`），默认主题 `clean-professional`，`_ThemeMenu` 遍历 `theme.available`（9 个内置主题）；颜色一律取 `context.wbColors` / `WbThemeColors`，勿硬编码色值。
- **依赖**：path 依赖 `whiteboard_ui` / `whiteboard_ui_kit` / `whiteboard_theme` / `whiteboard_icons` / `whiteboard_api_client` / `whiteboard_web_platform`（10）+ `go_router` / `provider`；**不依赖 core_dart**（`whiteboard_core` 已声明未引用，属待清理项，是否移除请协调者裁决）。
- **被依赖**：无（终端应用）；部署宿主为静态服务器 + `web/` 目录产物。

## 4. 常用命令

```powershell
# 静态分析 + 测试（40 用例）
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat analyze
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat test

# 本地运行（Chrome）/ 构建（部署 web/ 产物到静态服务器）
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat run -d chrome
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat build web --release
```

## 5. 变更影响提醒（改本模块时注意）

- 修改路由（`WbWebRoutes`）→ `widget_test.dart` 与部署侧外部链接同步；路径是唯一来源，勿散落硬编码。
- 修改响应式断点 / 布局（600、840、240px、60px）→ `test/widget_test.dart` 布局断言必须同步更新。
- 修改 WASM 接线 / 降级行为 → 联动 **10 dart-platform**（`WbCoreStatus`、加载器契约）与 `test/integration/wasm_*` 断言；改断言前先读 10 号文档。
- 修改 `web/index.html` / `manifest.json` / `wb_core.js` 占位约定（`window.WbCore` 工厂）→ 影响部署与 **17 build-release** 的 Web 构建产物约定（真实产物覆盖占位脚本）。
- 新增页面 / 组件时复用 08-ui 包（`whiteboard_theme` / `whiteboard_icons` / `whiteboard_ui_kit`），不复制样式代码；**不得新增对 core_dart 的直接依赖**（WASM 路径经 10）。
- `apps/mobile` 为预留目录：新增移动端实现不属于本模块，先与协调者确认归属规范。
