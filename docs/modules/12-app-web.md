# 12 · app-web —— Web 应用

> 模块路径：`apps/web`（`apps/mobile` 仅含 `pubspec.yaml`，预留）
> 维护 agent：`wb-app-web-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：白板 Web 应用（包名 `whiteboard_web`）——
  - 白板列表页 / 编辑页（列表 → 编辑 → 返回闭环；列表为会话内内存数据 + 空态引导——2026-10-05 移除此前的 3 条预留演示数据）；
  - 响应式布局：列表页 600px 断点（宽屏网格 / 窄屏列表）；编辑页 `kWideBreakpoint=840`（宽屏左侧 240px 页面 / 图层面板 + 画布区（工具为画布左上角浮动面板），窄屏单栏 + 60px 底部工具条）；
  - 主题切换（复用 `whiteboard_theme` 的 `WbThemeManager`，9 个内置主题）；
  - WASM 核心接线（`WbCoreService` → `WbCoreLoader`）：首帧后按需加载，状态可视化（`WbCoreStatusChip`）；**就绪后挂载共享画布 `whiteboard_canvas` 的 `CanvasView`**（选择 / 平移 / 缩放 / 绘制 / 文本 / 形状 / 便签 / 连线等完整交互，与桌面端同一实现；元素经 `WbWasmCanvasStore` 落 `wb_element_*`；详见 §2.3），加载失败 / 产物缺失降级内置演示画布；
  - **工具栏（P3）**：宽屏（≥840px）复用共享包 `WbCanvasToolPalette` 作为画布左上角浮动工具面板（11 工具 + 撤销 / 重做 + 更多菜单 + 工具参数行，与桌面「顶部」风格同一组件，`showToolPalette: wide`）；窄屏 60px 底部工具条（与浮动面板同集：11 工具 + 撤销 / 重做 + 「更多」入口，复用共享 `WbCanvasIconButton` 与端上同样式，底部弹出菜单列 6 类专业元素）；**上下文工具栏浮层**（选中元素 → `WbContextToolbarHost` 按选中元素屏幕矩形锚点弹出共享 `WbContextToolbar`，命令全映射共享 canvas API）；「更多」菜单经 `onQuickCreate` 激活专业元素分组（创建入口 → P5 编辑器对话框）；详见 §2.2 / §2.8 / §3；
  - **页面与图层（P2）**：宽屏左侧栏两分区（页面 / 图层）——页面区与图层区复用共享包 `PageManager` / `LayersPanel`（与桌面端同一实现），数据经 `WbWasmPageOps` / `WbWasmCanvasEngine` 桥接 WASM 域服务（page / element / render），缩略图经 `wb_render_thumbnail` 渲染；引擎不可用时面板自身降级（内存页面 / 演示缓存）；详见 §2.3；
  - **URL 深链（编辑页）**：`createWebRouter` 开启 `GoRouter.optionURLReflectsImperativeAPIs`——进入白板写 `#/board/:boardId?name=...`，F5 / 分享链接直达编辑页并按存档恢复；「返回」经 `context.go(homePath)` 清查询串回列表；详见 §3；
  - **画布持久化与文件互通**（本地优先，无服务端依赖）：画布改动自动写穿 `localStorage`（键 `wb.canvas.<boardId>`，`.wbd` 信封同桌面格式），**存档按页合并**（多页全量落盘、页间互不覆盖），刷新 / 重开恢复页面列表 / 各页元素 / 当前页并回灌引擎；AppBar 提供导出 / 导入 `.wbd` 文件入口（`WbBoardFileCodec` 与桌面端互通，两端文件可互相打开）；详见 §2.3、§3；
  - Socket.IO JS 客户端桥（T0.2 POC）：动态脚本加载 + `dart:js_interop` externals + `WbSocketIoBridge` 传输抽象（详见 §2.6）；
  - W1 实时协作层（T1.8）+ **P4 协作画布 op + 远端光标**：`WbRealtimeService`（成员 / 连接状态 / presence 元数据）→ 互动白板入口（默认本地，按需输入房间号加入 / 房间信息与退出）+ 参与者列表 UI；`WbCollabSession` 页面级协调器打通 **本地提交 → `crdt.applyLocal` → `board:ops` → 远端 `crdt.applyRemote` → 画布应用** 全链路（水印 `lastSeenVersion` / 快照恢复 state 回放 / checkpoint 响应 / ack `missingSeqs` 补发；**页结构 op 双向同步**——出口 `handlePageOp` / 入口 `applyRemotePageOp`（`pg:{pageId}:{field}`，2026-10-05 补齐发送侧））；远端光标与选区经 `presence:preview` 渲染（`WbRemotePresenceStore` + 共享 `WbRemoteCursorsOverlay`，详见 §2.7）；
  - M3 互动层（T3.4）：`interactive:*` 事件族接线（举手 / 授权控制 / 演示模式 / 移出）+ 角色权限判定 → 举手按钮、演示模式 chip 与入口、参与者面板标记与操作、`room:removed` 只读降级（详见 §2.7；视口跟随**消费**降级，登记 W2/M5——画布 op 联动已由 P4 落地；**被跟随广播（M3.1）已落地**——订阅 `interactive:follow/unfollow`，有人跟随或自身演示时经画布出口外发 viewport / page 帧）；
  - Web 宿主配置（`web/`：`index.html`、`manifest.json`、图标、真实 WASM 产物 `wb_core.js` + `wb_core.wasm`）。
- **不负责**：WASM 加载器与 JS 互操作细节、窗口能力（→ [10-dart-platform](10-dart-platform.md) `platform/web`）；UI 组件与主题定义（→ [08-dart-ui](08-dart-ui.md)）；HTTP 服务客户端（→ [09-dart-client](09-dart-client.md)）；WASM 核心 C++ 实现（→ 01～06 C++ 模块，真实产物经 Emscripten 构建）；realtime 服务端（→ 13～16 服务模块，互动事件契约见 [13-svc-api](13-svc-api.md)）；视口跟随**消费** / 软锁 / fetchOps 主动补洞（P4 按计划不做，偏差见 §2.7 末；被跟随广播 M3.1 已落地）。
- **地位**：两个应用之一（与 11 桌面应用并列）；依赖 08/09/10 的包 + 共享画布包 `whiteboard_canvas`（`packages/canvas`，与桌面端同一实现）；`whiteboard_core` 经平台中立入口 `wb_core_common.dart` 使用（域服务 + 模型，引擎实例由 `wb_core_wasm.dart` 注入；WASM 模块加载仍经 `whiteboard_web_platform`）。共享包同时承载 P3/P4 迁移件（`lib/toolbar/` 5 件、`lib/collab/remote_cursors.dart`；桌面端为转导）。
- **预留**：`apps/mobile` 仅含 `pubspec.yaml`（移动端应用预留，未实现）。
- **已知状态（如实记录）**：`web/wb_core.js` + `wb_core.wasm` 已为真实 Emscripten 产物（2026-10-01 本机 emsdk 3.1.74 构建；`build_wasm.ps1 -CopyToWebAssets` 链路验证 EXIT=0），编辑页就绪态挂载共享画布 `CanvasView`（与桌面端同一实现），浏览器端到端实测通过（绘制 → localStorage 自动保存 → 刷新恢复合并；导出 `.wbd` 下载；导入回灌往返；P2 多页 / 刷新恢复 / URL 深链 / 中文文本（CanvasKit 回退字体）修复，2026-10-02 Edge headless + CDP 与人工复测，详见 §2.5）；P3 工具栏（宽屏画布左上角浮动面板 / 窄屏底部工具条响应式切换 + 点便签建元素全链路）同批 CDP 探针实测通过（`wb_web_toolbar_probe.mjs`，详见 §2.5）；`test/` 共 **164 用例（VM）+ 12 用例 browser-only**（`--platform chrome`）全绿；Socket.IO JS 桥已对本机 :8790 实测连通（T0.2，见 §2.6）；W1 协作层（T1.8）已对本机 :8790 完成浏览器真连冒烟（2 用例，见 §2.7）；M3 互动层（T3.4）Web 补全完成——interactive 事件接线 + 举手 / 演示 / 授权 UI（视口跟随**消费**降级，登记 W2/M5；画布 op 联动已由 P4 落地，见 §2.7）；**M3.1 双缺陷修复（2026-10-05）**：参与者面板授权入口解绑「先举手」前置（对齐桌面端）；被跟随广播落地（`interactive:follow/unfollow` + viewport / page 帧外发）——浏览器实测 11 项全过（Edge headless CDP + Node socket.io-client 模拟桌面端，见 §2.7）；互动白板交互对齐桌面（默认本地 + 入口按需输入房间号加入 / 房间信息退出；服务器地址保持构建期静态注入）同批完成并浏览器实测全流程通过（2026-10-02，见 §2.7）。**列表页去预留演示数据（2026-10-05）**：移除 `wbDemoBoards` 3 条演示白板（产品路线图 / 系统架构草图 / 需求脑图），改空态引导 + 「新建白板」会话内条目（详见 §2.2）；浏览器实测 12 项全过（空列表 / 新建白板进编辑页（存档 0 元素）/ 返回列表条目保留，`e2e_home_cleanup.mjs`），同批暴露并修复编辑页 dispose 同步 `leave()` 通知触发 Provider「markNeedsBuild while locked」断言（微任务延后）。**P3.2-P3.4 / P4 / P5 全批完成并综合探针实测全绿（2026-10-03）**：`tests/e2e/support/wb_web_p45_probe.mjs`（Edge headless + CDP，1400×900 三标签双端）——单机段 12 项（更多菜单建表 / 上下文浮层与命令 / 更多菜单删除 / 双击编辑回写 / 尺寸角标 500 生效）+ 协作段 6 项（双端入房、便签同 id 同步、presence 存活、B 退房内容保留、**清档刷新重入房全量 replay 同 id 重建**）hardFailures 清零（详见 §2.5 / §2.7）。**页结构协同补齐（2026-10-05）**：web 端补齐页结构发送出口 `handlePageOp`（对齐桌面 `WbSyncService.handlePageOp`），修复协作下「web 新建页面他端不可见」——新建 / 删除 / 重命名 / 排序经 `pg:{pageId}:{field}` 同一 `board:ops` 可靠通道双向同步（op log 回放供迟到入房者重建页结构）；切换页面为本地视图状态不外发（设计口径）；浏览器实测 15 项全过（双 Edge 窗口 + Node socket.io-client 模拟桌面端，`.agent_tmp/e2e_page_sync.mjs`：A 新建 → B 实时出现 + 服务端收 `pg:page-2:create`；切换页不发 op；A 删除 → B 移除 + `pg:page-2:delete`；桌面 → web 方向创建 ack ok 且 A/B 均出现；B 刷新重入 → op log 回放重建）；VM 单测 +3（`wb_collab_session_test.dart`，全量 164/164，见 §2.7）。

## 2. 功能 → 文件映射

### 2.1 入口与路由

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 应用入口（`main`，启动 `WhiteboardWebApp`） | `apps/web/lib/main.dart` | `apps/web/test/widget_test.dart`（6 用例） |
| 应用壳 `WhiteboardWebApp`（`MultiProvider` + `MaterialApp.router`；`WbWebThemeState` / `WbCoreService` / `WbRealtimeService` 可注入供测试） | `apps/web/lib/app.dart` | 同上 |
| 路由 `WbWebRoutes` / `createWebRouter`（`/` 列表页、`/board/:boardId` 编辑页；`boardPath` 携带 `name` 查询参数；`optionURLReflectsImperativeAPIs = true` 让命令式导航写浏览器 URL——深链 / F5 保持编辑页） | `apps/web/lib/routes.dart` | 同上 |

### 2.2 页面

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 白板列表页（空态引导 `wb-board-list-empty` + 「新建白板」入口（命名 `未命名白板 N`）、响应式 ≥600 网格 / <600 列表、主题菜单 `_ThemeMenu`、相对时间；2026-10-05 移除预留演示数据） | `apps/web/lib/pages/board_list_page.dart` | `apps/web/test/widget_test.dart` |
| 白板编辑页（`kWideBreakpoint=840`；宽屏 `_EditSidebar` 240px（页面 / 图层两分区）+ 分隔线 + 画布；窄屏单栏 + `_BottomToolBar` 60px。**工具栏（P3）**：宽屏画布 `showToolPalette: wide` → 共享浮动工具面板（11 工具 + 撤销 / 重做 + 更多 + 参数行，同桌面「顶部」风格）；窄屏 9 工具受控贯通（`_tool` / `_selectTool` → 控制器 `setTool`）。（P2：页面区 / 图层区为共享包 `PageManager` / `LayersPanel`，Provider 注入 `WbPageState` + 引擎桥；存档恢复经 `restoreWbArchive` 对齐引擎页并整板载入 `loadBoardData`）；画布区按 `WbCoreStatus` 切换——就绪且控制器就位 → 共享 `CanvasView`（`showToolPalette: wide`、`drawingEnabled: !removed`、`pageId: core.pageId`），否则 `WbDemoCanvas` + `_FallbackBanner` 降级提示；AppBar 导出 / 导入 `.wbd` 按钮（导入随 `isRemoved` 禁用）+ 互动白板入口 `WbCollabEntryButton`（未入房文字按钮 / 在房状态 chip，点击入房或看房间信息）+ 演示模式 chip + 举手 / 演示入口 + 参与者入口 `endDrawer`；`_FullscreenButton` → `WebWindowPlugin`；首帧后触发 WASM 初始化（协作默认本地，不自动连接）；M3 `room:removed` 只读横幅 `_RemovedBanner` + 顶部浮动面板置灰（`drawingEnabled`）/ 底部工具条编辑禁用；退出 `_leave()`（`context.go(homePath)` 清 URL）；**P3.2-P3.4 / P4 / P5 接线**：画布区挂 `WbContextToolbarHost`（选中出上下文浮层）；`CanvasView` 传 `onQuickCreate: _createProfessionalElement`（更多菜单专业分组）/ `onElementActivate`（双击专业元素 → 编辑对话框回写）/ `onSizeBadgeTap`（尺寸对话框）；宽屏右下 `WbQuickCreateLauncher`；窄屏底部工具条含「更多」入口（底部弹出菜单）；入房建 `WbCollabSession`（`onLocalCommit` / `isRemoteApplying` 注入画布、session 回调 → `applyRemoteElement` / `applyRemoteRemove` / `applyRemotePageOp`（页结构接收）、`_pages.onPageOp = session.handlePageOp`（页结构出口，退房解绑））+ 远端光标 overlay（`WbRemotePresenceStore` + `WbRemoteCursorsOverlay`）；`onCursorMoved` / `onSelectionChanged` → 房间内 `sendPreview`；退出房间全量清理） | `apps/web/lib/pages/board_edit_page.dart` | 同上 + `collab_widget_test.dart` + `element_editor_test.dart` + `wb_collab_session_test.dart` + `test/integration/` |

### 2.3 服务、状态与组件

| 功能 | 实现文件 | 测试 |
|---|---|---|
| WASM 核心服务 `WbCoreService`（ChangeNotifier；`initialize()` 幂等、失败不抛异常；`status` / `isAvailable` / `engine`（聚合引擎，失败 null）/ `pageId`） | `apps/web/lib/services/wb_core_service.dart` | `apps/web/test/integration/wasm_load_test.dart`（12 用例）等 |
| 主题状态 `WbWebThemeState`（包装 `WbThemeManager`，默认 `clean-professional`，`select` 切换） | `apps/web/lib/state/theme_state.dart` | `apps/web/test/widget_test.dart` |
| 核心状态 chip `WbCoreStatusChip`（四态文案：引擎待命 / 引擎加载中 / 引擎就绪 / 演示画布） | `apps/web/lib/widgets/core_status_chip.dart` | 同上 + `wasm_load_test.dart` |
| 共享画布接入：就绪态挂载 `whiteboard_canvas` 的 `CanvasView`（完整交互，与桌面端同一实现；宽屏 `showToolPalette: true`——画布左上角浮动工具面板 `WbCanvasToolPalette`：11 工具（选择 / 抓手 / 画笔 / 荧光笔 / 橡皮 / 文本 / 便签 / 形状 / 图片 / 连线 / 3D）+ 撤销 / 重做 + 更多菜单 + 参数行；窄屏工具选择由页面底部工具条承担（与浮动面板同集：11 工具（选择 / 抓手 / 画笔 / 荧光笔 / 橡皮擦 / 便签 / 文本 / 形状 / 图片 / 连线 / 3D）+ 撤销 / 重做 + 「更多」入口，复用共享 `WbCanvasIconButton`）），页面持有 `WbCanvasController` + `WbSelectionState` | 实现位于 `packages/canvas/lib/{canvas_view.dart,canvas/**,context_editors/**,services/board_file_codec.dart}`；Web 接入点 `apps/web/lib/pages/board_edit_page.dart` | `wasm_render_test.dart`（就绪挂载 `CanvasView` + 宽屏浮动面板、演示画布让位；降级态无工具 UI） |
| 上下文工具栏浮层（P3.2）：`WbContextToolbarHost` 监听选区（`_resolveType` 经 `document.byId` 元素类型映射 `WbContextTarget`）→ 非空 `showWbContextToolbar`（锚点 = 画布 RenderBox 全局偏移 + `worldRectToScreen(selectionBounds)`），空 / 重开时旧 handle 先关；命令执行器全映射共享 canvas API（删除 / 复制 / 颜色 / 对齐 / 分布 / 前后序 / 字体 / 文本对齐，未覆盖命令轻提示） | `apps/web/lib/widgets/context_toolbar_host.dart` | `apps/web/test/collab_widget_test.dart`（浮层组） |
| 元素编辑器对话框（P5.1）：`showWbElementEditorDialog`（`Dialog.fullscreen`；workspace 型编辑器全屏、其余 620 限宽居中；`onChanged` 收集最新模型，保存 pop / 取消 pop null；barrierDismissible=false）——创建 / 双击编辑 / 尺寸角标共用 | `apps/web/lib/widgets/element_editor_dialog.dart` | `apps/web/test/element_editor_test.dart`（4 用例） |
| 引擎聚合入口 `WbWebEngine`（条件导入：Web 聚合 `wb_init` → `wb_create_board` → `wb_board_get` → 首页 id + 整板快照 + 域服务 `board` / `element` / `page` / `render` / `crdt` / `tools`（`crdt` / `tools` 供 P4 协作会话；经 `wb_execute_tool` 点分路由，零 C++ / 绑定改动）；任一步失败返回 null 降级内存画布；非 Web 桩恒 null） | `apps/web/lib/services/wb_core_engine.dart`（+`_web` / `_stub`） | `wasm_load_test.dart` 等（经编辑页链路间接覆盖） |
| 引擎桥适配器（P2）：`WbWasmPageOps`（包装 `WbPageService` → `WbPageOps`：增删改 / 排序 / 锁定隐藏 / 背景）与 `WbWasmCanvasEngine`（包装 `WbElementService` + `WbRenderService` → `WbCanvasEngine`：元素列表 / 行操作 / `wb_render_thumbnail` 缩略图）；`attach` / `detach` 延迟绑定，未绑定时 `isAvailable` false 上层降级 | `apps/web/lib/services/wb_wasm_bridges.dart` | `apps/web/test/wb_wasm_bridges_test.dart`（7 用例） |
| 存档 → 引擎恢复（P2）：`readWbArchive`（无 / 损坏存档返回 null 不抛异常）+ `restoreWbArchive`（存档页与引擎页对齐——同 id 复用并字段回写 / 缺页经引擎新建 / 孤儿余页删除；引擎不可用按存档原样输出） | `apps/web/lib/services/wb_archive_restore.dart` | `apps/web/test/wb_archive_restore_test.dart`（9 用例） |
| 引擎画布存储适配 `WbWasmCanvasStore`（控制器事务提交点尽力同步 `wb_element_*`：`load` = list、`upsert` = update 失败回退 create、`remove` = delete、错误静默；与桌面 `WbFfiCanvasStore` 同构） | `apps/web/lib/services/wb_wasm_canvas_store.dart` | `persistent_canvas_store_test.dart`（引擎协同组） |
| 持久化画布存储 `WbPersistentCanvasStore`（引擎优先 load → 本地存档恢复并回灌引擎；写穿存档键 `wb.canvas.<boardId>`；`replaceAll`（撤销 / 导入）差量同步引擎；**不抛异常**；P2 多页：镜像为「页 id → 元素」全量表（首次访问整体载入），写穿全部页一并落盘（页间互不覆盖），切页 / 未知页返回空不回退他页）+ 浏览器 IO 三件套（条件导入：localStorage 存储 / Blob 下载 / 文件选择；VM 桩 = 内存存储共享单例 + no-op） | `apps/web/lib/services/wb_persistent_canvas_store.dart`、`wb_browser_io.dart`（+`_web` / `_stub`）、`wb_canvas_storage.dart` | `apps/web/test/persistent_canvas_store_test.dart`（16 用例） |
| 演示画布 `WbDemoCanvas`（key `wb-demo-canvas`；20px 网格 + 3 张示例卡；WASM 不可用 / 就绪前的降级视图） | `apps/web/lib/widgets/demo_canvas.dart` | 同上 |
| Socket.IO JS 桥（T0.2 POC）：动态脚本加载 + `dart:js_interop` externals + 可注入传输抽象（条件导入：Web 实现 / VM 桩） | `apps/web/lib/services/socketio_js.dart`、`socketio_js_types.dart`、`socketio_js_web.dart`、`socketio_js_stub.dart` | `apps/web/test/socketio_js_vm_test.dart`（3 用例）；`socketio_js_poc_test.dart`（browser-only） |
| 实时协作服务 `WbRealtimeService`（ChangeNotifier；连接状态机 + `board:session/joined/participants/room:error` 处理 + 参与者增量合并；M3：`interactive:*` 发送 7 方法与 5 类订阅（含 follow/unfollow——M3.1）、`selfRole` / `presentMode` / `presenterId` / `grantedWrite` / `raisedHands` / `followers` / `needsViewportBroadcast` 状态暴露、`canManageInteractions` / `canRaiseHand` 权限判定；`connect` / `joinBoard` / `leave`；**P4**：回调 `onBoardJoined` / `onRemoteOps` / `onRemotePreviews` / `onCheckpointRequest` + 发送 `sendOps`（ack 三态 `{ok}` / `{ok,dup}` / `{ok:false,missingSeqs}`）/ `sendPreview` / `sendCheckpoint` + `lastSeenVersionProvider`（join 载荷水位）；脚本加载器 / 桥工厂可注入——详见 §2.7） | `apps/web/lib/services/realtime_service.dart` | `apps/web/test/realtime_service_test.dart`（46 用例） |
| 协作会话协调器（P4）：`WbCollabSession`（页面级；本地出口 `handleLocalCommit`（upsert → `el:{id}:data` + pageId 内嵌 / removed → `el:{id}:exists=false`；`crdt.applyLocal` NotFound → 惰性 create 重试 → `sendOps` → ack `missingSeqs` 缓存补发）与远端入口 `handleRemoteOps`（`crdt.applyRemote`，**applied==true 才路由画布**；水印推进）、快照恢复 `handleJoined`（`decodeState` + `snapshot.payload` 的 `el:*` 键回放画布）、checkpoint 响应（`encodeState` → `sendCheckpoint`）、页结构出口 `handlePageOp`（`pg:{pageId}:{field}`——create / delete / rename / move，2026-10-05 补齐对齐桌面）、`isApplyingRemote` 防回发；回调 `onRemoteElement` / `onRemoteRemove` / `onRemotePageOp`） | `apps/web/lib/services/wb_collab_session.dart` | `apps/web/test/wb_collab_session_test.dart`（14 用例） |
| 协作 UI（`widgets/collab/`）：互动白板入口 `WbCollabEntryButton`（key `wb-collab-entry`；未入房文字按钮 / 在房状态 chip 即入口）、加入 / 房间信息对话框（`showWbCollabJoinDialog` / `showWbCollabRoomDialog`；键 `wb-collab-join-dialog` / `wb-collab-room-field` / `wb-collab-join-cancel` / `wb-collab-join-confirm` / `wb-collab-room-dialog` / `wb-collab-room-reconnect` / `wb-collab-room-close` / `wb-collab-room-leave`）、状态 chip `WbCollabStatusChip`（key `wb-collab-status-chip`；idle 隐藏）、演示模式 chip `WbPresentModeChip`（key `wb-present-mode-chip`；present 态「演示中」）、举手按钮 `WbRaiseHandButton`（key `wb-raise-hand-button`；Viewer～Presenter 举手 / 收手）、演示入口 `WbPresentButton`（key `wb-present-button`；CoHost+ 开始 / 结束）、参与者面板 `WbParticipantsPanel`（endDrawer；key `wb-participants-panel`；举手标记 / 角色徽标 / 「可编辑」标记 + 授权 / 收回操作）、入口按钮 `WbParticipantsButton`（在线人数徽标；key `wb-participants-button`）、互动失败轻提示 `showWbInteractiveFailure` | `apps/web/lib/widgets/collab/collab_entry_button.dart`、`collab_dialogs.dart`、`collab_status_chip.dart`、`participants_panel.dart`、`participants_button.dart`、`raise_hand_button.dart`、`present_button.dart`、`interactive_feedback.dart` | `apps/web/test/collab_widget_test.dart`（16 用例） |

### 2.4 Web 宿主（`apps/web/web/`）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 宿主页（`flutter_bootstrap.js` 引导；`wb_core.js` 按需注入说明；`$FLUTTER_BASE_HREF` base 占位） | `apps/web/web/index.html` | —（部署时验证） |
| PWA 清单（192/512 + maskable 图标、主题色 `#2E6BE6`） | `apps/web/web/manifest.json` | — |
| 真实 WASM 产物 `wb_core.js`（Emscripten `MODULARIZE=1 -sEXPORT_NAME=WbCore`，约 90KB；含 post_js 别名层 `utf8ToString` / `heapU8`，见 10） | `apps/web/web/wb_core.js` | 浏览器端到端验证（2026-10-01） |
| 真实 WASM 产物 `wb_core.wasm`（约 1.7MB） | `apps/web/web/wb_core.wasm` | 同上 |
| 图标资源 | `apps/web/web/favicon.png`、`apps/web/web/icons/`（Icon-192 / Icon-512 / Icon-maskable-192 / Icon-maskable-512） | — |

> `apps/web/build/`（50 个文件）为构建生成目录，不入映射；`.dart_tool/`、`.idea/` 同理。

### 2.5 测试（`apps/web/test/`，共 164 用例 VM + 12 用例 browser-only）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| widget 冒烟（6 用例：列表页空态（无预置数据）/ 新建白板 → 编辑页（降级画布）→ 返回列表保留 / 响应式 + P2 新建页面后页面列表增加；P3 宽屏断言左侧仅页面 / 图层分区、降级态无工具 UI，窄屏断言底部工具条 11 工具 `wb-bottom-tool-*` + 撤销 / 重做 / 更多在位） | `apps/web/test/widget_test.dart` | — |
| 窄屏底部工具条对齐端上（2 用例：同集断言（11 工具 + 撤销 / 重做 / 更多，宽屏浮动面板不挂载）+ 工具切换贯通控制器、撤销 / 重做随编辑启停并生效（插入 → 撤销 → 清空 → 重做 → 恢复）） | `apps/web/test/bottom_toolbar_test.dart` | — |
| WASM 命令链路（7 用例） | `apps/web/test/integration/wasm_command_test.dart` | — |
| WASM 加载与降级（12 用例） | `apps/web/test/integration/wasm_load_test.dart` | — |
| WASM 内存（10 用例） | `apps/web/test/integration/wasm_memory_test.dart` | — |
| WASM 渲染（6 用例：降级渲染契约 + 状态 chip 三态 + 显示列表接口；P3 就绪态断言画布左上角浮动工具面板挂载（`wb-canvas-tool-select` / `wb-canvas-undo` / `wb-canvas-more`），降级态断言无工具 UI） | `apps/web/test/integration/wasm_render_test.dart` | — |
| 持久化画布存储与浏览器 IO 桩（16 用例：存档读写 / 引擎协同回灌与差量 / 损坏存档容错 / 导出往返 / 存储工厂共享；P2 多页合并：按页隔离 / 全量写穿 / 切页不回退） | `apps/web/test/persistent_canvas_store_test.dart` | — |
| 引擎桥适配器（7 用例：页面桥委托 / 未绑定降级与抛错 / attach-detach 幂等 / 画布引擎列表与缩略图解码） | `apps/web/test/wb_wasm_bridges_test.dart` | — |
| 存档恢复（9 用例：readWbArchive 无 / 损坏 / 正常 + restoreWbArchive 同 id 复用 / 缺页新建 / 孤儿清理 / 引擎不可用 / 新建异常回退 / 当前页回退） | `apps/web/test/wb_archive_restore_test.dart` | — |
| Socket.IO 桥 VM 桩（3 用例：加载抛 `WbSocketIoLoadException` / `UnsupportedPlatform` 回调 / `emitWithAck` 抛 `UnsupportedError`） | `apps/web/test/socketio_js_vm_test.dart` | — |
| Socket.IO 浏览器连通 POC（10 用例，browser-only：加载幂等 / session / join+ping / echo 广播 / direct / volatile / websocket-only / polling-only / default 升级 / gated 拒连；文件须在 `test/` 根目录） | `apps/web/test/socketio_js_poc_test.dart` | — |
| 协作服务（46 用例：连接状态机 / join 挂起与补发 / 快照全量替换 / 参与者 joined-updated-left 增量 / room:error / leave-dispose（含 leave 复位被移出态）/ 数据模型容错；M3：interactive 发送 4 用例 + 订阅 5 用例（modeChanged / roleChanged / hostChanged / participants 扩展字段 / room:removed）+ 跟随集合 2 用例（follow/unfollow 折叠与求交清理 / present 演示者广播条件——M3.1）+ 权限判定 1 用例；**P4**：sendOps ack 三态透传 / onRemoteOps / onRemotePreviews / onCheckpointRequest 投递 / join 载荷带 lastSeenVersion） | `apps/web/test/realtime_service_test.dart` | — |
| 协作 UI（16 用例：默认本地入口 / chip 隐藏 / 加入失败提示、加入对话框校验（空输入禁用 / 取消无副作用）、经入口加入后已连接徽标与列表、已在房房间信息 → 退出回本地、断线重连保留、窄屏 600、列表页无协作 UI、idle 隐藏；M3：举手按钮（含 Guest·Host 隐藏与失败轻提示）、面板举手 / 徽标 / 可编辑标记与授权・收回（含未举手成员的授权入口——M3.1）、演示模式 Host 入口与 Participant 广播路径、room:removed 只读横幅与编辑禁用（注入 ready 假核心 → 断言顶部浮动面板置灰：非导航工具 / 更多置灰、导航工具保留）；**P4**：远端光标 overlay 挂载不崩 + 选区出现上下文浮层 2 用例） | `apps/web/test/collab_widget_test.dart` | — |
| 协作会话协调器（14 用例：本地 upsert / removed op 形状（`el:data` + pageId 内嵌 / `el:exists=false`）、ack `missingSeqs` 补发、applied=true 路由回调、duplicate / applied=false 不回调、NotFound 惰性 create 重试、快照 → decodeState + state 回放、checkpointRequest → encodeState + sendCheckpoint；页结构出口 3 用例（`handlePageOp` op 形状与守卫 / 防回发窗口内静默 / `WbPageState.onPageOp` 装配链路——2026-10-05）） | `apps/web/test/wb_collab_session_test.dart` | — |
| 元素编辑器对话框（4 用例：更多菜单 pro 组创建 → 保存 → 画布元素 +1、双击专业元素编辑预填保存回写、取消无副作用、尺寸角标 → 对话框 resize） | `apps/web/test/element_editor_test.dart` | — |
| W1 浏览器真连冒烟（2 用例，browser-only：连接 + `board:session` 匿名回落 / join 快照 + 双连接互见 + leave 增量；文件须在 `test/` 根目录） | `apps/web/test/realtime_web_smoke_test.dart` | — |

> 假桥支持文件 `apps/web/test/support/fake_socketio_bridge.dart`（记录调用 + 手动触发事件；非 `_test.dart` 后缀，不被当作用例执行）。
>
> **浏览器端到端探针（CDP，2026-10-02 实测通过）**：`tests/e2e/support/wb_web_persist_probe.mjs`（绘制 → `wb.canvas.<boardId>` 自动保存 → 刷新重建引擎 → 第二笔合并 = 2 元素）与 `wb_web_export_probe.mjs`（A 板绘制 → 导出下载 `E2E-A.wbd`（format `whiteboard-board`，1 元素）→ B 板整页重载（空引擎）→ 点「导入 .wbd 文件」（文件选择框经 CDP 捕获）→ 注入文件 → `wb.canvas.<boardId>` 出现 1 元素，往返一致）。运行：先 `flutter build web --release` 并静态托管 `build/web`（默认 `http://localhost:8090`，`WB_WEB_URL` 可覆盖），再 `node tests\e2e\support\<探针>.mjs`。
>
> **P2 浏览器实测（2026-10-02，静态托管 `build/web` :8090）**：多页创建 / 按页隔离 / 切页不丢数据 / F5 刷新恢复（多页 + 当前页 + 元素 + 图层）全过；P2 下沉曾引入 `dart:ffi` 断裂（共享包误引 FFI 入口 `wb_core.dart`）——`flutter build web` 门禁发现并修复（改经 `wb_core_common.dart`）；URL 深链写入与「返回」URL 清理、CanvasKit 回退字体中文直出（无方框、无需交互）复测通过。
>
> **P3 工具栏浏览器实测（2026-10-02；2026-10-04 底部条对齐端上后复跑，静态托管 `build/web` :8090，Edge headless + CDP）**：`tests/e2e/support/wb_web_toolbar_probe.mjs`——宽屏 1400×900：画布左上角浮动工具面板挂载（工具行 11 个按钮 + 更多；DOM 几何计数）、左侧栏无「工具」分区；真实交互「点便签 → 点画布」→ `wb.canvas.<boardId>` 存档出现 `note` 元素（面板 → `setTool` → 画布创建 → 自动保存全链路）；缩窄 600×900：面板退场、底部工具条与端上工具行同集出现（11 工具 + 撤销 / 重做 / 更多）；恢复 1400×900：面板回归（元素与撤销栈存活）。注：Flutter Web 语义树将自定义 `InkWell` 按钮 tooltip 合并入容器节点、按钮自身 `aria-label` 为空——工具存在性以 DOM 几何为主判据（浮动面板 32×32 `role=button` 连排 11 颗 + 更多；底部条为整槽位 34×60——工具行 11 颗连排、分隔条（宽 11、无 role）后为撤销 / 重做 / 更多区，复跑计数 13 颗节点：仅撤销可用时撤销 / 重做合并为 68×60 单节点）。
>
> **P3.2-P3.4 / P4 / P5 综合浏览器实测（2026-10-03，静态托管 `build/web` :8090 + realtime :8790，Edge headless + CDP，1400×900）**：`tests/e2e/support/wb_web_p45_probe.mjs`——单机段 12 项全过（更多菜单 → 表格创建对话框 → 画布 1 元素；上下文浮层出现与「更多」删除项 → 确认删除；双击编辑对话框 → 保存回写；3D 尺寸角标 → 「尺寸设置」→ 宽 500 生效）；协作段 6 项全过（A/B 双标签同房 → A 建「E2E」便签 → B 同 id 同步出现；A 指针移动 presence 不崩；B 退房内容保留；**A 退房 + 清空存档 + 刷新 + 重入房 → 服务端全量 replay → 画布同 id 重建**）——hardFailures 清零。探针要点：多标签下语义树 / 编辑输入宿主仅在活动标签可靠（各动作前 `Page.bringToFront`；文本输入用 Ctrl+A + `Input.insertText` + DOM `value` 校验式重试）；便签创建即进入文本编辑态，**空文本会在失焦 / dispose 时被 `endTextEditing` 清理并产生删除 op**（须输入文本后点空白提交，否则污染 oplog 令 replay「创建 + 删除」——诊断实锤）。

### 2.6 Socket.IO JS 桥（T0.2 POC，Wave 1 实测）

- **文件落点**（`lib/services/`，接口与实现分离）：`socketio_js.dart`（入口：条件导入 + `loadSocketIoClient` / `createWbSocketIoBridge` 对外 API）；`socketio_js_types.dart`（`WbSocketIoBridge` 桥接口与类型：connect/on/off/emit/emitWithAck/volatileEmit/disconnect + 连接状态回调）；`socketio_js_web.dart`（浏览器实现：`dart:js_interop` externals 包装全局 `io()` 及 socket/engine/volatile API）；`socketio_js_stub.dart`（VM 桩：不触 JS，连接回调 `UnsupportedPlatform`）。
- **脚本加载策略**：`loadSocketIoClient(endpoint)` 幂等注入 `<script src="{endpoint}/socket.io/socket.io.min.js">`——文件由 socket.io@4 服务端自动托管，**版本随服务端、零 npm 依赖**；同 endpoint 复用同一 Future；以 `globalThis.io` 为函数判定加载完成，失败抛 `WbSocketIoLoadException`（不阻塞 UI）。
- **传输抽象**：realtime 接线注入 `WbSocketIoBridge`——VM（纯 Dart）测试不加载 JS（走桩），仅浏览器路径走 js_interop 桥；W1 服务层注入用法见 §2.7。
- **浏览器连通结论（2026-09-30，本机 :8790）**：`flutter test --no-pub --platform chrome test\socketio_js_poc_test.dart` 两轮全绿（主轮 `+9 ~1`，gated 轮 `--dart-define=WB_POC_BAD_TOKEN=...` `+10`）。覆盖：连接成功、`board:session`（userId/authMode）、`board:join` + `board:ping` ack、`board:echo` 自端不广播且第二连接收到 `board:broadcast`、`board:direct` 单播、拒连 `code=Unauthorized`。
- **volatile / transport / polling 结论**：`socket.volatile.emit` 存在且送达（以 `board:joined` 回执实证，非仅 API 存在）；`engine.transport.name`：websocket-only 连接为 `websocket`；default transports 观测到 `polling → websocket` 升级（实测 0～125ms）；`transports:['polling']` 保持 `polling`、800ms 内不升级。
- **CORS 注意**：服务端 POC 阶段 `origin:'*'`（宽松）；生产接线需由服务端收敛 origin 白名单（服务端范畴，本模块不动）。
- **Windows 平台注意**：① 浏览器测试文件**必须放 `test/` 根目录**——flutter_tools 对子目录生成 `window.testSelector` 时反斜杠转义丢失，致 "Web test ... not found" 挂起；② 运行依赖 `test/canvaskit/` 资源兜底（flutter_tools 直供 canvaskit 404 的 workaround，可从 Flutter SDK `flutter_web_sdk/canvaskit` 重建，已 gitignore）；③ JS→Dart 事件回调一律用**可选位置参数** `([JSAny? _]) {...}`——DDC 严格校验实参个数，0 参事件（如 `connect`）会抛 `NoSuchMethodError` 中断回调链。

### 2.7 实时协作层 W1（T1.8）+ 互动层 M3（T3.4）

- **口径（D-H；P4 更新 2026-10-03；M3.1 / 页结构更新 2026-10-05）**：Web M1 = **W1 层**（参与者列表 / 连接状态可见）+ **P4 画布 op 协作 + 远端光标 + 页结构 op 双向**（`WbCollabSession` 协调器全链路，见下）。M3 = 互动层（举手 / 授权 / 演示 / 移出）。视口跟随**消费**仍降级（登记 W2/M5）；**被跟随广播（M3.1）已落地**——订阅 `interactive:follow/unfollow` 折叠跟随者集合，有人跟随或自身演示时经画布出口外发 viewport / page 帧（桌面端跟随 Web 端可用）。
- **服务 API（`WbRealtimeService`，ChangeNotifier + Provider 注入）**：
  - `connect(endpoint, {token})`——幂等、失败不抛异常；endpoint 归一化（去空白 / 尾部 `/`），实际连接 `{endpoint}/board`；`kWbRealtimeEndpoint` 默认 `http://127.0.0.1:8790`，可 `--dart-define=WB_REALTIME_ENDPOINT=...` 覆盖（**构建期静态注入，Web 无运行时设置面板**）；
  - `joinBoard(boardId, {pageId})`——未连接时挂起记录，连接 / 重连成功后自动补发（重连时服务端参与者表已随断开清除）；
  - `leave()`——先发 `board:leave`（800ms ack 超时兜底）再本地断开；幂等；旧桥回调经 identity 守卫与本实例隔离；复位被移出态（`isRemoved` / 原因 / 消息）回到本地模式；
  - 读侧：`status`（`WbRealtimeStatus{idle,connecting,connected,reconnecting,disconnected}`）/ `userId` / `authMode` / `boardId` / `role` / `mode` / `participants`（不可变列表，插入序）/ `lastError` / `isConnected`；
  - 注入点（D-G 测试用）：`clientLoader`（缺省 `loadSocketIoClient`）+ `bridgeFactory`（缺省 `createWbSocketIoBridge`）。
  - **P4 扩展（画布 op / 预览 / checkpoint）**：回调字段 `onBoardJoined(Map payload)`（joined ack 全量，含 snapshot）/ `onRemoteOps(List ops, {bool replay})`（`board:ops` 批量）/ `onRemotePreviews(List previews)`（`presence:preview`）/ `onCheckpointRequest()`；发送 `sendOps(List ops)`（`emitWithAck('board:ops')` 透传 ack 三态）/ `sendPreview(Map)` / `sendCheckpoint({stateVector, payload})`；`lastSeenVersionProvider` 回调（join 载荷 `lastSeenVersion: provider?.call() ?? {}`——首 join 空对象 = 新成员语义全量 replay，重连带本地水印增量）；
- **事件处理（§6 契约）**：`board:session`（`userId/authMode/role`）、`board:joined`（快照全量替换 `participants` 并更新 `boardId/role/mode`，M3 含 `presenterId`）、`board:participants`（`joined/updated` 按 socketId 合并（替换保序）、`left` 移除；M3 扩展 `grantedWrite` / `handRaised`）、`room:error`（记入 `lastError`，不改连接状态）；畸形载荷一律忽略不崩溃。
- **状态机**：`idle → connecting → connected`；意外断线（非 `io server/client disconnect`）→ `reconnecting`（socket.io 自动退避重试；重连尝试失败保持「重连中」）；重连成功 → `connected` 并自动补 `board:join`；首连失败 / `io server disconnect` / 主动 `leave` → `disconnected`。
- **UI 挂载点（`board_edit_page`；交互对齐桌面端）**：**默认本地白板**——`initState` 不自动连接；AppBar `title` 行内 `WbCollabEntryButton`（key `wb-collab-entry`；未入房 = 「互动白板」文字按钮，在房 = `WbCollabStatusChip` 即入口）→ `_openCollabEntry()`：已在房（`boardId != null`，含连接失败 / 重连中）→ `showWbCollabRoomDialog`（房间号 / 服务器 / 状态・人数 / 最近错误；`disconnected` 时提供「重新连接」；「退出互动白板」→ `leave()` + snack「已退出互动白板（回到本地模式）」）；否则 → `showWbCollabJoinDialog`（serverHint = `kWbRealtimeEndpoint`）→ `connect + joinBoard(房间号)` → snack「已加入互动白板：X」/「加入失败：…（请检查打包时注入的服务器地址）」；`actions` 内 `WbParticipantsButton` → `Scaffold.endDrawer = WbParticipantsPanel`；`dispose` 中 `leave()`（全程 `unawaited`，不阻塞 UI）。布局断点不变（840 / 240px / 60px），协作入口在窄屏（如 600）同样可用。
- **传输差异补充（W1 层；T0.2 已记录项不复述）**：① 服务的事件 `on()` 注册严格在桥 `connect()` 之后（桥契约）；② `io server/client disconnect` 不自动重连（socket.io 语义）→ 服务映射为 `disconnected`；③ 重连成功后需重新 `board:join`（服务自动补发）；④ `leave` 的 800ms ack 超时兜底——服务端不可达时页面退出不悬挂；⑤ VM 下脚本加载失败（`WbSocketIoLoadException`）收敛为 `disconnected + lastError`，UI 降级「未连接」（真实浏览器路径与 VM 测试分流，互不影响）。
- **浏览器真连结论（2026-09-30，本机 :8790）**：`flutter test --no-pub --platform chrome test\realtime_web_smoke_test.dart` 全绿（`+2`；Edge 兜底）。覆盖：连接 + `board:session`（`anon-*` / `anonymous` 匿名回落）、`board:joined` 快照含自身（role `Host`：空房首位加入房主自举）、双连接互见（A/B 各收对方 joined 增量）、B `leave()` → A 收 left 增量。
- **P4 交互浏览器实测（2026-10-02，静态托管 :8090 + realtime :8790）**：默认本地（无协作 chip、入口「互动白板」文字按钮）；未启 :8790 点加入 → 底部「加入失败：无法加载客户端脚本 …（请检查打包时注入的服务器地址）」；启 :8790 后加入成功（snack「已加入互动白板：X」→ chip「已连接」→ 参与者徽标 1）→ 房间信息对话框（房间号 / 服务器 / 「已连接 · 1 人在线」）→「退出互动白板」回文字按钮（snack「已退出互动白板（回到本地模式）」）。
- **M3 互动层事件接线（服务端契约 `services/realtime/src/interactive.ts`，见 13 服务端文档）**：
  - 发送（全部 `Future<bool>`；统一经 `emitWithAck` 轻量 ack `{ok:true}`；未连接 / 已移除 / ack 拒绝 / 异常超时 → `false` 且**不写** `lastError`，UI 以 `showWbInteractiveFailure` 轻提示）：`raiseHand()` / `lowerHand()`、`grantControl(userId)` / `revokeControl(userId)`、`startPresent()` / `stopPresent()`、`removeUser(userId)`；
  - 订阅：`interactive:modeChanged`（→ `presentMode` / `presenterId`，缺省回落 `by`）、`interactive:roleChanged`（单播 → `selfRole` / `grantedWrite`；他人 userId 忽略）、`interactive:hostChanged`（`newHostId == self` → Host，参与者表乐观同步）、`board:participants` updated 扩展（`grantedWrite` / `handRaised` 入库并同步自身条目）、`room:removed`（单播 → `isRemoved` / `removedReason` / `removedMessage`；畸形载荷仍置移除态；重连时重置）、`interactive:follow` / `interactive:unfollow`（单播 `{followerUserId}` → 折入 / 移出跟随者集合；随 `board:joined` / `board:participants` 与在线名单求交清理——M3.1）；
  - 状态与判定：`selfRole` / `isPresenting` / `presenterId` / `grantedWrite` / `selfHandRaised` / `raisedHands` / `followers` / `needsViewportBroadcast`（followers 非空或自身即演示者——M3.1）/ `isRemoved` / `removedReason` / `removedMessage`；权限辅助 `isHost` / `isCoHostOrHigher` / `isPresenterOrHigher` / `canManageInteractions`（连接 + 未移除 + ≥CoHost）/ `canRaiseHand`（连接 + 未移除 + ≥Viewer 且 <CoHost；Guest 不显示入口）——角色排序对齐服务端 `ROLE_RANK`；
  - **发起端本地确定性更新**：服务端 interactive 广播经 `socket.to(room)` **排除发起者自身**，故 ack 成功后本端补丁（举手标志 / 目标 `grantedWrite` / 模式与 `presenterId`），幂等，不依赖回环广播。
- **M3 UI 挂载点（`board_edit_page` + `widgets/collab/`）**：
  - AppBar `actions`：`WbRaiseHandButton`（key `wb-raise-hand-button`；Viewer～Presenter「举手 / 收手」切换）、`WbPresentButton`（key `wb-present-button`；CoHost+「开始 / 结束演示」）；
  - AppBar `title`：`WbPresentModeChip`（key `wb-present-mode-chip`；present 态「演示中」+ 演示者 tooltip）；
  - 参与者面板：举手标记（key `wb-hand-raised-<userId>`）、Host（实底）/ Presenter（浅底）徽标高亮（key `wb-role-badge-<userId>`）、「可编辑」标记（key `wb-granted-write-<userId>`）、授权 / 收回入口（key `wb-grant-control-<userId>` / `wb-revoke-control-<userId>`；仅本地 ≥CoHost 且目标非 Host/CoHost——对齐服务端角色矩阵；不设「先举手才能授权」前置——M3.1 对齐桌面端）；
  - `room:removed`：`_RemovedBanner` 只读横幅（key `wb-removed-banner`，「你已被移出该白板，当前为只读模式」）+ 宽屏浮动工具面板与窄屏底部工具条同口径置灰（非导航工具 / 撤销重做 / 更多置灰，选择 / 抓手保留）+ 互动入口随 `isRemoved` 隐藏（页面其余信息仍可查看，不阻塞）。
- **P4 画布 op 链路（`WbCollabSession`，页面级）**：
  - 本地出口：画布 `onLocalCommit(WbCanvasCommitBatch)` → upsert 元素经 `WbBoardFileCodec.encodeElement` + `value['pageId']` 内嵌 → op `el:{id}:data`；removedIds → op `el:{id}:exists=false` → `crdt.applyLocal`（NotFound → `crdt.create` 惰性重试）→ `realtime.sendOps` → ack `missingSeqs` 从本地缓存补发一次；
  - 页结构出口（2026-10-05 补齐，对齐桌面双向装配）：`WbPageState.onPageOp` → `handlePageOp(pageId, field, value)` → op `pg:{pageId}:{field}`（value：create → `{'name': ...}`；delete → true；rename → 新名；move → 目标索引；null 缺省 true）→ 与元素 op 同一 `crdt.applyLocal` + `board:ops` 可靠通道（op log 回放供迟到入房者重建页结构）；编辑页装配 `_pages.onPageOp = session.handlePageOp`、退房解绑；`applyRemotePageOp` 应用路径不经出口（防空回发）；
  - 远端入口：`board:ops` → `_applying=true` 包裹 → 逐条 `tools.execute('crdt.applyRemote', ...)`（`wb_execute_tool` 点分路由，零 C++ / 绑定改动）→ 水印 `_watermarks[actor] = seq` 推进（服务端日志按 actor 连续，直接推进）→ **`applied==true` 才路由画布**（duplicate / LWW 败者不上）：`el:*:data` → `decodeElement` → `applyRemoteElement`（pageId 取 value 内嵌，先 `ensureRemotePage`）；`el:*:exists=false` → `applyRemoteRemove`；`pg:{pageId}:{field}` → `onRemotePageOp` → `applyRemotePageOp`（create / delete / rename / move 全字段，幂等、不回发）；
  - 快照恢复：`board:joined.snapshot` 非空且 `crdt.encodeState` probe 返回 NotFound（本端 doc 不存在）→ `crdt.create` + `decodeState(payload)` + 水印 = snapshot.stateVector → **解析 payload 的 `el:*` 键回放画布**（补桌面 drain 只下发 applied=true op 的缺口：快照内 key 的重放 op 因 LWW 平局 applied=false，不回放则画布不可见）；
  - checkpoint：收 `board:checkpointRequest` → `crdt.encodeState` → `sendCheckpoint({stateVector: 水印, payload: state})`（不做主动 checkpoint）。
- **远端光标与选区（P4）**：页面级 `WbRemotePresenceStore` 消费 `presence:preview`（`realtime.onRemotePreviews`）；画布 `onCursorMoved`（50ms）/ `onSelectionChanged`（100ms）→ 房间内 `realtime.sendPreview`；渲染挂共享 `WbRemoteCursorsOverlay`（画布 Stack `Positioned.fill`；配色 / 缓动 / 淡出与桌面同源；pageId 过滤经 `previewPageMatches`）。
- **M3.1 被跟随广播（Web 作为被跟随者；2026-10-05）**：服务端 `interactive:follow` 单播 `{followerUserId}` → `followers` 集合（`interactive:unfollow` 移除；`_pruneFollowers` 随 `board:joined` / `board:participants` 与在线名单求交，名单为空保守等待；`leave()` / 重连清空）；`needsViewportBroadcast`（followers 非空或自身即演示者）为真时，画布出口 `onViewportChanged`（200ms 节流）/ `onPagePreview` → `sendPreview` 外发 `{kind:'viewport', pageId, offset, zoom}` / `{kind:'page', pageId}`（帧形状与桌面 `WbFollowController` 消费契约一致）。浏览器实测（2026-10-05，Edge headless CDP + Node socket.io-client 模拟桌面端，11 项全过）：未举手成员面板出现「授权控制」→ 授权 / 收回单播（`grantedWrite` true/false）；`interactive:follow` 单播达被跟随端；滚轮 / 抓手 → viewport 帧、新建页 → page 帧（`page-2`）；审计无 `authz.denied`。探针注：面板中带行内按钮的成员行在语义树为 `flt-semantics-img` 元素（宽 0、高 54，`aria-label` 合并 userId + 头像首字母 + 角色），文本断言须全 DOM 扫描，勿仅查 `flt-semantics`。
- **降级登记（D3-E → P4 后更新；M3.1 2026-10-05 修订）**：画布 op 协作**已由 P4 落地**；**视口跟随消费仍不在 Web 实现**（不显示 follow 按钮、不消费远端 viewport / page 帧，登记 W2/M5）；**被跟随广播已落地（M3.1）**——订阅 `interactive:follow/unfollow`，有人跟随或自身演示时外发 viewport / page 帧（桌面端跟随 Web 端可用）；软锁 / fetchOps 补洞不做（见下）。`removeUser` 服务层已就绪（含 VM 测试），Web 暂未挂 UI 入口（移出当前由服务端 / 桌面端触发）。
- **P4 实现偏差与已知边界（记录）**：① pending style（选色后再点表面应用）不做——颜色即时应用；② `pg:*` 页结构键已全字段双向支持（create / delete / rename / move；2026-10-05 补齐发送侧，原「`create/delete` 外忽略」记录作废）；③ 软锁 `lock:*` / 视口跟随消费（远端 viewport / page 帧不入画布——被跟随广播 M3.1 除外）/ fetchOps 主动补洞（用 `lastSeenVersion` 重锚替代）不做；④ 入房不上行本地既有元素（此后增量上行；快照 state 回放仅在本端 crdt doc 不存在的新会话时执行）；⑤ **空便签编辑态清理语义**：便签创建即进文本编辑态，空文本在失焦 / dispose 时被 `endTextEditing` 清理并产生删除 op——协同下会污染 oplog（B5 重放「创建 + 删除」），使用提示：创建便签后应及时输入文本提交；⑥ 同 URL（含相同 hash）`Page.navigate` 为同文档跳转不触发刷新（调试 / 探针须显式 `Page.reload`）；⑦ 探针 / 自动化注意：多标签下语义树与文本编辑宿主仅在活动标签可靠（动作前先激活目标标签；文本输入须校验 DOM `value`）。

### 2.8 高级模块编辑器（P5）

- **交互模型**：六类专业元素（flowchart / table / mindmap / function / render3d / render2d）编辑器经**全屏对话框**承载（`showWbElementEditorDialog`；不走 go_router 路由——规避浏览器刷新丢 `extra`）：
  - 创建：宽屏「更多」菜单 pro.* 分组（`onQuickCreate` 非空时显示）+ 窄屏底部工具条「更多」→ 底部弹出菜单 + 宽屏右下 `WbQuickCreateLauncher`；`_createProfessionalElement(kind)`（只读态 `_removed` 拦截）→ 对话框 → `WbProfessionalRenderer.measure(kind.id, model) ?? Size(320, 240)` → `insertElement` → 回选择工具；
  - 编辑：画布双击专业元素（`onElementActivate`）→ 对话框预填 `element.payload` → 保存经 `updateElement` 回写 payload + 重测尺寸；
  - 尺寸：选中专业元素下缘角标（`onSizeBadgeTap`）→ 共享 `showElementSizeDialog` → `resizeElementById`（3D / 2D 尺寸契约：宽高在嵌套键 `size.{width,height}`）；
- **稳定 key**：`wb-element-editor-cancel` / `wb-element-editor-save`（对话框按钮，探针 / widget 测试定位锚点）；更多菜单 `wb-canvas-more`、工具面板各工具 `wb-canvas-tool-*`（共享组件）。

## 3. 契约与依赖

- **路由契约**：`/`（`boardList`）与 `/board/:boardId`（`boardEdit`，查询参数 `name`）；路径生成统一走 `WbWebRoutes`，勿在页面内手拼字符串。**URL 策略**：`createWebRouter` 设 `GoRouter.optionURLReflectsImperativeAPIs = true`（默认 false 时命令式导航不写 URL）——进入编辑页 URL 为 `#/board/<id>?name=...`（hash 策略），F5 / 深链直达并按存档恢复；离开编辑页用 `context.go(homePath)`（勿用 `pop`，深链进入时无栈可退且会残留查询串）。
- **响应式断点（回归依据）**：列表页 600px（`constraints.maxWidth >= 600` 网格 / 否则列表）；编辑页 `kWideBreakpoint = 840`。修改断点或布局结构会影响 `widget_test.dart` 的布局断言。
- **WASM 降级链**：编辑页首帧后 `WbCoreService.initialize()`（幂等）→ `WbCoreLoader.load()` → `WbCoreStatus`（idle→loading→ready/unavailable，失败不抛异常）→ `WbCoreStatusChip` 展示 → **就绪挂载共享 `CanvasView`（与桌面端同一实现），否则降级 `WbDemoCanvas`（key `wb-demo-canvas`）**；就绪后 `WbCoreService.engine` 聚合 `WbWebEngine`（失败为 null → 画布以内存模式运行）。加载器行为契约见 [10-dart-platform](10-dart-platform.md)。
- **共享画布契约（`whiteboard_canvas`）**：Web 与桌面共用同一套画布实现（`CanvasView` / `WbCanvasController` / 元素模型 / 上下文编辑器；实现位于 `packages/canvas`，桌面经转发层接入）；工具集经 `WbCanvasTool` 枚举受控（勿在画布内自持工具态）：**P3 宽屏**由共享 `WbCanvasToolPalette`（`showToolPalette: wide`，画布左上角浮动面板）直接驱动控制器 `setTool`（11 工具 + 撤销 / 重做 + 更多菜单 + 参数行，与桌面「顶部」风格同一组件；只读经 `drawingEnabled` 置灰）；**窄屏**经页面底部工具条（`_tool` / `_selectTool` → `setTool`，9 工具）；画布挂载参数 `drawingEnabled: !isRemoved`、`pageId: core.pageId`；元素契约与桌面端一致（`drawing` 的 `data.points` 为世界绝对坐标 + 包围盒）。**P2 页面 / 图层**：页面状态（`WbPageState`）与 `PageManager` / `LayersPanel` 均为共享包组件，经引擎桥接口 `WbPageOps` / `WbCanvasEngine` 取数——Web 用 `WbWasmPageOps` / `WbWasmCanvasEngine` 延迟绑定 WASM 域服务（与桌面 `WbFfiPageOps` / `WbFfiCanvasEngine` 同构）；桥未就绪时面板自身降级（内存页面 / 演示缓存）。**文本缓存失效**：`CanvasView` 监听 `PaintingBinding.instance.systemFonts`，字体变化（Web CanvasKit 动态下载 CJK 回退字体就绪）时经 `WbCanvasController.invalidateTextLayouts()` 清文本布局缓存并重绘——否则缺字形段落会被 `WbCanvasTextCache` 永久缓存（中文显示方框）；监听挂 Widget 层（控制器可能在无绑定单测环境构造）。**P3/P4 共享迁移件**：`packages/canvas/lib/toolbar/`（`toolbar_config` / `toolbar_item` / `color_picker_popover` / `color_wheel` / `context_toolbar` 5 件）与 `lib/collab/remote_cursors.dart` 为双端共用的唯一实现（桌面端为转导；Web 上下文浮层与远端光标层直接消费）。
- **持久化与文件互通契约**：画布存储为 `WbPersistentCanvasStore`（引擎 + `localStorage` 复合）——存档键 `wb.canvas.<boardId>`，内容为 `.wbd` 信封（`WbBoardFileCodec`，与桌面端同一格式，两端文件可互相打开）；**存档为整板多页**（页 id → 元素全量镜像，写穿全部页一并落盘、页间互不覆盖，切页 / 未知页返回空不回退他页）；`load` 引擎优先、空则读存档并回灌引擎；`replaceAll`（撤销 / 导入）写穿存档并差量同步引擎；刷新后引擎为全新实例，由 `restoreWbArchive` 把存档页与引擎页对齐（同 id 复用 / 缺页新建 / 孤儿删除）后再整板载入画布；**存储层不抛异常**（撤销 / 导入路径未包 try，依赖此约定）；导入 / 导出经 AppBar 按钮（导出当前页元素；导入替换当前页并写穿存档，`isRemoved` 时禁用）。
- **Socket.IO 桥契约（T0.2）**：统一经 `createWbSocketIoBridge()` + `loadSocketIoClient()`（`socketio_js.dart`）访问；`WbSocketIoBridge` 为唯一传输抽象，VM/浏览器分流由条件导入保证（勿在 UI 层直接 `dart:js_interop`）；客户端脚本仅从服务端 `{endpoint}/socket.io/socket.io.min.js` 加载，不加 npm 依赖。
- **实时协作服务契约（T1.8 + M3 + P4）**：协作链路统一经 `WbRealtimeService`（底层桥经构造注入，勿在 UI 层直触 `WbSocketIoBridge`）；协作 UI 组件从 Provider 读服务；`idle` 态不展示协作 UI（单机模式功能零阻塞）；**画布 op 一律经 `WbCollabSession`**（见下条契约，勿绕行直发）；M3 互动操作统一经服务层方法（返回 `bool`，失败不抛异常 / 不写 `lastError`），权限判定用 `canManageInteractions` / `canRaiseHand`（对齐服务端角色矩阵）；`room:removed` 后为只读降级（编辑入口禁用 + 互动入口隐藏 + 横幅提示）。
- **协作画布 op 契约（P4）**：op key `el:{id}:data`（value = `WbBoardFileCodec.encodeElement` 元素 JSON + `pageId` 内嵌）/ `el:{id}:exists=false`（删除）；本地出口 `handleLocalCommit`（画布 `onLocalCommit` 批次）；远端经 `crdt.applyRemote`（`WbToolService.execute` → `wb_execute_tool` 点分路由；NotFound → 惰性 `crdt.create` 重试）——**`applied==true` 才路由画布**（duplicate / LWW 败者不上）；水印 `_watermarks[actor]=seq`（服务端按 actor 连续）随 join 以 `lastSeenVersion` 上报（首 join `{}`）；快照恢复：`joined.snapshot` 非空时 `crdt.decodeState` + 水印 = snapshot.stateVector，并解析 `snapshot.payload` 的 `el:*` 键回放画布；checkpoint：`board:checkpointRequest` → `crdt.encodeState` → `realtime.sendCheckpoint`；守护边界：入房不上行本地既有元素、快照回放仅本端 doc 不存在时执行；**页结构 op `pg:{pageId}:{field}` 双向全支持**（create / delete / rename / move；出口 `handlePageOp` / 入口 `applyRemotePageOp`；切换当前页不发 op——本地视图状态，仅跟随 / 演示模式经 page 帧外发）。
- **M3 降级契约（D3-E；M3.1 修订）**：视口跟随**消费**与画布联动不做（登记 W2/M5）；不显示 follow 按钮；**被跟随广播落地**——`interactive:follow/unfollow` → `followers` 集合，`needsViewportBroadcast`（有人跟随或自身即演示者）经画布出口 `onViewportChanged` / `onPagePreview` 外发 viewport / page 帧；`room:removed` 只读模式不阻塞页面其余信息展示。
- **主题契约**：`WbWebThemeState` 包装 `WbThemeManager`（`whiteboard_theme`），默认主题 `clean-professional`，`_ThemeMenu` 遍历 `theme.available`（9 个内置主题）；颜色一律取 `context.wbColors` / `WbThemeColors`，勿硬编码色值。
- **依赖**：path 依赖 `whiteboard_ui` / `whiteboard_ui_kit` / `whiteboard_theme` / `whiteboard_icons` / `whiteboard_canvas`（共享画布与 `.wbd` 编解码，`packages/canvas`）/ `whiteboard_core`（域服务与模型经平台中立入口 `wb_core_common.dart`；WASM 引擎实例经 `wb_core_wasm.dart` 注入）/ `whiteboard_api_client` / `whiteboard_web_platform`（10）+ `go_router` / `provider` / `web`（直接依赖：localStorage / Blob / 文件选择，见 `wb_browser_io_web.dart`）。
- **被依赖**：无（终端应用）；部署宿主为静态服务器 + `web/` 目录产物。

## 4. 常用命令

```powershell
# 静态分析 + 测试（164 用例；browser-only 文件在 VM 下自动跳过）
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat analyze --no-pub
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub

# 本地运行（Chrome）/ 构建（部署 web/ 产物到静态服务器）
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat run -d chrome
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat build web --release

# 本地静态托管 build/web（正确 wasm MIME + no-store；浏览器实测 / 探针共用；默认端口 8090）
node build\wasm\serve_web.mjs apps\web\build\web 8090

# 持久化 / 导入导出 / P3 工具栏 / P3-P5 综合 浏览器实测（Edge headless + CDP；需静态托管 build/web，默认 :8090）
node tests\e2e\support\wb_web_persist_probe.mjs
node tests\e2e\support\wb_web_export_probe.mjs
node tests\e2e\support\wb_web_toolbar_probe.mjs
node tests\e2e\support\wb_web_p45_probe.mjs

# WASM 产物构建（需 emsdk 环境；产物复制到 web/ 后需重新 build web 才生效；详见 17 build-release）
tools\scripts\build_wasm.ps1 -CopyToWebAssets

# 浏览器连通 POC（T0.2；需先启动服务：cd services\realtime; node dist\server.js → :8790）
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub --platform chrome test\socketio_js_poc_test.dart

# W1 协作浏览器真连冒烟（T1.8；同样需先启动 realtime :8790）
Set-Location apps\web; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub --platform chrome test\realtime_web_smoke_test.dart
# 本机无 Chrome 时用 Edge 兜底：$env:CHROME_EXECUTABLE='C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
# gated 拒连轮次（T0.2）：服务端带 WB_JWT_SECRET 启动，并追加 --dart-define=WB_POC_BAD_TOKEN=invalid.token.value
```

## 5. 变更影响提醒（改本模块时注意）

- 修改路由（`WbWebRoutes`）→ `widget_test.dart` 与部署侧外部链接同步；路径是唯一来源，勿散落硬编码。URL 深链行为由 `createWebRouter` 的 `optionURLReflectsImperativeAPIs` 与编辑页 `_leave()`（`context.go`）共同决定，改动后需浏览器复测「进入写 URL / F5 保持编辑态 / 返回清 URL」。
- 修改响应式断点 / 布局（600、840、240px、60px）→ `test/widget_test.dart` 布局断言必须同步更新。宽屏工具 UI 为共享 `WbCanvasToolPalette`（`showToolPalette: wide`，画布左上角浮动面板），窄屏为 `_BottomToolBar`（`_tool` / `_selectTool` / `_canvasTools`）——勿再往左侧栏加工具分区；工具面板的可见性、只读置灰语义已分别被 `wasm_render_test.dart`（ready / 降级）与 `collab_widget_test.dart`（room:removed，需注入 ready 假核心）覆盖；布局响应式回归经 `wb_web_toolbar_probe.mjs`（§2.5）。
- 修改 WASM 接线 / 降级行为 / 画布挂载（`board_edit_page.dart` 的 `_canvasArea`、`wb_core_engine*.dart`）→ 联动 **10 dart-platform**（`WbCoreStatus`、加载器契约）与 `test/integration/wasm_*` 断言（`wasm_render_test.dart` 断言就绪态 `CanvasView` 与 `wb-demo-canvas` 互斥挂载 + 宽屏浮动工具面板（`wb-canvas-tool-select` / `wb-canvas-undo` / `wb-canvas-more`），降级态无工具 UI）；改断言前先读 10 号文档。
- 修改持久化 / 导入导出（`wb_persistent_canvas_store.dart`、`wb_browser_io*.dart`、`board_edit_page.dart` 的 `_exportBoard` / `_importBoard`）→ `test/persistent_canvas_store_test.dart` 与 §2.5 浏览器探针同步；存档键与 `.wbd` 格式属跨端契约（与 11 桌面端互通），改动需两端回归。
- 修改页面 / 图层接线（`wb_wasm_bridges.dart`、`wb_archive_restore.dart`、编辑页 `_EditSidebar` / `_initCore`）→ `wb_wasm_bridges_test.dart` / `wb_archive_restore_test.dart` / `persistent_canvas_store_test.dart` 断言同步；共享组件（`PageManager` / `LayersPanel` / `WbPageState` / 引擎桥接口 `WbPageOps` / `WbCanvasEngine`）位于 `packages/canvas`，改动同时影响桌面端（跑两端 `flutter test`）。
- 共享画布 / 工具栏 / 远端光标（`CanvasView` / 控制器 / 上下文编辑器 / `.wbd` 编解码 / `lib/toolbar/` 5 件 / `lib/collab/remote_cursors.dart`）位于 `packages/canvas`（`whiteboard_canvas`）——Web 与桌面共用；改共享包同时影响两端（桌面经转发层接入），跨端回归跑两端 `flutter test`。
- 修改 Socket.IO JS 桥（`socketio_js_*.dart`）→ 保持 `WbSocketIoBridge` 接口稳定（Web 实现与 VM 桩同步改）；JS→Dart 回调一律可选位置参数（DDC 实参个数校验）；浏览器测试文件保持在 `test/` 根目录运行；**不得新增 npm 依赖**（客户端脚本由服务端提供）。
- 修改协作层（`realtime_service.dart`、`wb_collab_session.dart`、`widgets/collab/`、`widgets/context_toolbar_host.dart`、编辑页接线）→ `test/realtime_service_test.dart` / `test/collab_widget_test.dart` / `test/wb_collab_session_test.dart` 断言同步；**「默认本地 + 入口按需入房」为交互契约**（`initState` 不自动连接；`leave()` 复位被移出态；入口判定用 `boardId != null`——退出后自动回文字按钮）；状态枚举与文案（连接中 / 已连接 / 重连中 / 未连接）、协作稳定 key（`wb-collab-entry` / `wb-collab-join-dialog` / `wb-collab-room-field` / `wb-collab-join-cancel` / `wb-collab-join-confirm` / `wb-collab-room-dialog` / `wb-collab-room-reconnect` / `wb-collab-room-close` / `wb-collab-room-leave` / `wb-raise-hand-button` / `wb-present-button` / `wb-present-mode-chip` / `wb-removed-banner` / `wb-hand-raised-*` / `wb-granted-write-*` / `wb-grant-control-*` 等）变化会影响 widget 断言；M3 只读编辑入口断言经顶部浮动面板（`wb-canvas-tool-*` / `wb-canvas-more`，需注入 ready 假核心）；守护「画布 op / 页结构 op 仅经 `WbCollabSession`（编辑页装配 `onLocalCommit` / `onPageOp` 出口，退房解绑）、applied==true 才路由画布、视口跟随 / 软锁不做」边界（见 §2.7 偏差记录）；M3 互动统一经服务层（ack 成功后做本地确定性更新，失败收敛 `false` 不抛异常）；浏览器冒烟命令见 §4。
- 修改高级模块入口（`element_editor_dialog.dart`、编辑页 `_createProfessionalElement` / `_onElementActivate` / `_onSizeBadgeTap`）→ `test/element_editor_test.dart` 与 §2.5 综合探针同步；编辑器对话框 key `wb-element-editor-cancel` / `wb-element-editor-save` 为探针定位锚点。
- 修改 `web/index.html` / `manifest.json` / `wb_core.js` / `wb_core.wasm` 产物约定（`window.WbCore` 工厂）→ 影响部署与 **17 build-release** 的 WASM 构建流程（`build_wasm.ps1 -CopyToWebAssets` 产物直接落入 `web/`，重新 `build web` 生效）。
- 新增页面 / 组件时复用 08-ui 包（`whiteboard_theme` / `whiteboard_icons` / `whiteboard_ui_kit`），不复制样式代码；**不得新增对 core_dart 的直接依赖**（WASM 路径经 10）。
- `apps/mobile` 为预留目录：新增移动端实现不属于本模块，先与协调者确认归属规范。
