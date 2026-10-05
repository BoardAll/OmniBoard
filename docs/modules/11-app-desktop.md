﻿# 11 · app-desktop —— 桌面应用

> 模块路径：`apps/desktop`
> 维护 agent：`wb-app-desktop-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：Flutter Windows 桌面应用的全部装配与交互——入口与路由（`lib/main.dart`、`lib/app.dart`、`lib/routes.dart`）、状态层（`lib/state/`）、服务层（`lib/services/`）、平台层（`lib/platform/`）、页面（`lib/pages/`）、widgets（`lib/widgets/` 及 8 个子目录）、单元/widget 测试（`test/`）、真实 DLL FFI 集成测试（`test/integration/`）、端到端场景（`integration_test/`）、Windows 运行器与 `wb_core.dll` 部署（`windows/`）、资源目录（`assets/`）。
- **不负责**：FFI 绑定与域服务封装（→ [07-dart-core](07-dart-core.md)）；基础组件/图标/主题库（→ [08-dart-ui](08-dart-ui.md)）；AI/REST/MCP 客户端协议（→ [09-dart-client](09-dart-client.md)）；平台插件原生实现（→ [10-dart-platform](10-dart-platform.md)）；C++ 引擎（→ 01-06）；服务端（→ 13-16）。
- **规模（如实）**：`lib/` 101 个实现文件；`test/` 43 文件 674 用例（声明）+ `test/integration/` 7 文件 26 用例；runner 实跑 **727 用例 = 722 通过 + 5 个 env-gated 跳过**（realtime `WB_REALTIME_E2E=1`），实测 `flutter test` 全绿（2026-10-03 复点）；`integration_test/` 9 个场景文件（19 个 `testWidgets`，需 Windows 桌面环境）；`assets/` 为骨架（仅 `.gitkeep` 占位）。
- **降级路径**：无 `wb_core.dll` 时应用进入"演示模式"（画布走内存数据源 `canvas_store`）；FFI 集成测试在 `WB_REQUIRE_CORE_DLL=1` 时强制真实 DLL、否则优雅跳过。

## 2. 功能 → 文件映射

### 2.1 应用装配与路由（lib/ 根）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 应用根组件：Provider 装配（ffi/shortcut/theme/sync/退出编排注入，board/page/selection/ai 页面级状态自建）、`MaterialApp.router`、路由单例（主题通知重建不重置导航栈）、关窗拦截（`WindowListener` → `WbAppExitService`：无脏即时退出 / 有脏三选，`handleWindowClose` 可测） | `lib/app.dart` | `test/desktop_test.dart`、`test/board_wiring_test.dart`、`test/window_close_prompt_test.dart` |
| 入口：窗口初始化（平台通道缺失时静默跳过）+ FFI 初始化（失败进入演示模式） | `lib/main.dart` | `test/desktop_test.dart` |
| 路由表：`WbRoutes` 常量与路径（`/`、`/board/:boardId`、`/board/:boardId/editor`、`/settings`）、`createRouter`；编辑页 `extra` 支持 `WbBoardOpenRequest`（本地文件直开） | `lib/routes.dart` | `test/desktop_test.dart`、`integration_test/app_test.dart`、`test/board_file_ui_test.dart` |

### 2.2 状态层（lib/state/）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 白板状态：当前白板生命周期（打开 / 关闭 / 重命名 / 撤销重做 / `loadBoard` 外部白板装配） | `lib/state/board_state.dart` | `test/desktop_test.dart`、`test/board_wiring_test.dart` |
| 页面状态：页面列表 / 当前页 / 增删改排序（`restore` 从文件数据整页装配） | `lib/state/page_state.dart` | `test/sidebar_deep_test.dart`、`test/board_file_service_test.dart`、`integration_test/page_management_test.dart` |
| 选区状态：当前选中元素集合 | `lib/state/selection_state.dart` | `test/canvas_deep_test.dart` |
| AI 状态：会话消息 / 流式回复 / 工具调用 / 幽灵预览 / 上下文引用 / 语音状态 | `lib/state/ai_state.dart` | `test/ai_panel_deep_test.dart`、`test/ai_canvas_executor_test.dart` |
| 主题状态：包装主题服务为可监听状态（可选注入 `WbSettingsStore` 构造即恢复 / 落盘） | `lib/state/theme_state.dart` | `test/settings_deep_test.dart`、`test/settings_persistence_test.dart`、`integration_test/theme_test.dart` |
| 透明批注状态：模式 / 笔迹层 / 当前笔刷 | `lib/state/annotation_state.dart` | `test/annotation_test.dart`、`test/transparent_overlay_test.dart` |
| 跟随控制器（M3）：`followingUserId` 状态机——`startFollow` 发 `interactive:follow` / `stopFollow` 发 `unfollow`；自动停止（目标离开 / 用户视口手势 / 用户切页 / 被移除 / 断连）；帧消费 `handlePreviews` 仅取被跟随者（viewport → 画布 `applyRemoteViewport`；page 帧按 `-page-(\d+)$` 页序切本地同序页、无此页忽略切页仅同步视口）；`syncWithRoom`（在线校验 + present 自动跟随，手动停止后本轮抑制） | `lib/state/follow_controller.dart` | `test/follow_controller_test.dart`、`test/collab_m3_widget_test.dart` |

### 2.3 服务层（lib/services/）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| FFI 服务：懒加载核心引擎（候选路径 + 演示模式降级）、聚合各领域子服务 | `lib/services/ffi_service.dart` | `test/desktop_test.dart`、`test/integration/ffi_init_test.dart` |
| 主题服务：桥接主题管理器与偏好持久化（`WbSettingsStore` 可选注入，缺省纯内存） | `lib/services/theme_service.dart` | `test/settings_deep_test.dart`、`test/settings_persistence_test.dart` |
| AI 应用服务：组合 Dart 侧 AI SDK 与引擎侧 AI 域 | `lib/services/ai_service.dart` | `test/ai_panel_deep_test.dart` |
| 白板内置 AI 工具定义（命名映射） | `lib/services/ai_tools.dart` | `test/ai_canvas_executor_test.dart` |
| AI 工具调用执行器：把模型返回的工具调用落地到画布 | `lib/services/ai_canvas_executor.dart` | `test/ai_canvas_executor_test.dart` |
| 协同同步服务（T1.6）：FFI 控制面封装（`WbCollabEngine` 端口 + `WbFfiCollabEngine` 转发 sync/crdt 域）；50ms `events` 轮询（Timer/时钟可注入）→ ops 应用 / previews 透传记录 / room+status 刷新；`WbSyncStatus` 映射（offline/connecting/online/syncing/error）；`start`（connect → `crdt.create` 幂等容忍 Conflict → join → 轮询）/ `stop`；画布出口 `handleCanvasCommit`（`crdt.applyLocal` → 响应 op → `sync.sendOperation`；`el:{id}:data` 全量 / `el:{id}:exists=false` 删除；actor = 每连接会话随机 uuid；离线自动入引擎 pending）；远端应用防回发（`isApplyingRemote`）；默认 endpoint `http://127.0.0.1:8790` 可注入；UI 读取面 `WbCollabParticipant` / `participantList`（room 快照解析；M1 末位 = 本人推断）；M2 扩展：预览出口 `sendPreview`（ink / transform / cursor / selection 任意 kind，异常降级 dropped、未入房丢弃）、软锁 `lock` / `releaseLock` / `renewLock`（`WbSyncLockResult.requested`、10s 周期续约、`remoteLocks` 排除本端、`onLockDenied` / `isHoldingLock`）、`room.lockAcks` drain 消费（授予 / 拒绝 / 续约三动作）、重连预算 `reconnectBudget = 5` + `shouldOfferReconnect` + `reconnect()`（stop + 同房 start）；M3 扩展：`interactive({action, userId?, targetUserId?})`（9 动作白名单 raiseHand / lowerHand / grantControl / revokeControl / startPresent / stopPresent / removeUser / follow / unfollow，离线 / 缺引擎恒 `requested:false` 不抛）+ 9 个便捷 helper；房间读取面 `selfRole` / `presentMode` / `presenterId` / `grantedWrite` / `hostUserId` / `checkpointStatus` / `recovered`（一次性通知 `shouldNotifyRecovered` / `markRecoveredNotified`）/ `isRemoved` + `removedMessage` / `followers`（Set）；权限面 `canEdit`（只控白板编辑，不控透明批注）/ `needsViewportBroadcast` / `canManageInteractions` / `canRaiseHand` / `selfHandRaised` / `canGrantControlParticipant` / `canRemoveParticipant`；drain 扩展 `interactiveAcks`（失败经 `onInteractiveError` 中文化）/ `incomingFollows`（followers 增减）/ `removed`（只读态）；followers 与在线名单求交清理（名单空保守）、重连 / 重新加入重置；发起端本地确定性更新（M3 修复；服务端互动广播排除发起者 `socket.to`）：raiseHand / lowerHand / grantControl / revokeControl / startPresent / stopPresent 经 `_requestInteractiveWithPatch` 转发受理后入队 `_pendingInteractivePatches`（ack 无 userId 按 action FIFO 结算：成功应用补丁 / 失败丢弃 + `onInteractiveError`），读取面（`participantList` / `presentMode` / `presenterId` / `selfHandRaised`）合并补丁，stop / 传输重连（reconnectCount 增长）/ grantedWrite 目标离开裁剪时清理 | `lib/services/sync_service.dart` | `test/sync_service_test.dart`、`test/canvas_sync_hooks_test.dart`、`test/collab_lock_test.dart`、`test/collab_m3_service_test.dart`、`test/desktop_test.dart`、`test/integration/ffi_sync_roundtrip_test.dart`、`test/integration/ffi_sync_dual_process_test.dart` |
| 快捷键服务：应用级快捷键注册表与展示格式化 | `lib/services/shortcut_service.dart` | `test/settings_deep_test.dart`、`test/board_wiring_test.dart` |
| 本地存储底座：`%APPDATA%\Whiteboard` 目录解析（可注入覆盖）+ JSON 同步读写（失败静默返回 null/false） | `lib/services/local_store.dart` | `test/settings_persistence_test.dart` |
| 设置存储：`settings.json` 版本化 JSON——主题 id / 外观偏好 / AI 提供商配置 / 协作地址 / 最近白板列表（上限 20、去重）；AI 配置 → `AiProvider` 工厂 | `lib/services/settings_store.dart` | `test/settings_persistence_test.dart` |
| 白板文件编解码：`.wbd`（UTF-8 JSON 信封）全元素类型 + 6 类专业元素 payload round-trip；容错口径（未知字段忽略、缺省取默认、坏结构抛 `FormatException`） | `lib/services/board_file_codec.dart` | `test/board_file_codec_test.dart` |
| 白板文件服务：保存 / 另存为 / 打开 / 最近列表 / 脏标记（`documentRevision` 比较，pan/zoom 不误伤）；文件对话框可注入（缺省走 `whiteboard_windows`） | `lib/services/board_file_service.dart` | `test/board_file_service_test.dart`、`test/board_file_ui_test.dart` |
| 应用退出编排：窗口 X / Alt+F4 与列表页「退出应用」按钮共用——未保存三选、防重入（`_closing`/`_handling`）、`setPreventClose(false)` + `close()` 标准关闭路径（窗口即时消失；替代 `destroy()` 的 ~40s 慢退出） | `lib/services/app_exit_service.dart` | `test/window_close_prompt_test.dart` |

### 2.4 平台层（lib/platform/）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 平台能力探测服务 | `lib/platform/platform_service.dart` | `test/desktop_test.dart` |
| 窗口服务：桌面窗口初始化与配置（window_manager 封装；`setPreventClose(true)` 关窗拦截） | `lib/platform/window_service.dart` | `test/desktop_test.dart`、`test/window_close_prompt_test.dart` |
| 透明批注模式服务：状态机 + 平台窗口能力（透明 / 置顶 / 穿透 / 全屏） | `lib/platform/transparent_overlay_service.dart` | `test/transparent_overlay_test.dart` |
| 桌面截图兜底背景控制器（降级路径） | `lib/platform/desktop_backdrop_controller.dart` | `test/desktop_backdrop_test.dart` |

### 2.5 页面（lib/pages/）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 白板列表页（首页）：最近白板入口 + 新建 + 「打开本地白板」对话框 + 本地文件最近列表（点击直开 / 失效可移除）+ AppBar「退出应用」按钮（与窗口 X 同编排） | `lib/pages/board_list_page.dart` | `test/desktop_test.dart`、`test/board_file_ui_test.dart`、`test/window_close_prompt_test.dart`、`integration_test/create_board_test.dart` |
| 白板编辑页：画布 + 左侧栏 + AI 面板 + 径向/浮动工具栏；保存（Ctrl+S）/ 打开 / 返回列表未保存三选 / 标题脏标记 ` •`；协同装配**默认本地**（打开白板不自动入房；点击「互动白板」入口 → 输入房间号 → `WbCollabService.start(boardId: 房间号)`，退出房间 / 关闭白板 → `stop`；画布钩子 ↔ 服务回调双向接线；M2：`onRemotePreviews` → 画布鬼影入口、预览四出口（ink / transform / cursor / selection）接线、`WbRemoteCursorsOverlay` 在场层挂载、软锁闸门（文本编辑 / 专业元素激活 / 尺寸对话框 acquire-release，`onLockDenied` 轻提示短 id）；工具栏「互动白板」入口按钮（离线 = 文字按钮 / 在房 = 状态 chip）+ 参与者入口 / `endDrawer` 面板；M3：`WbFollowController` 装配（画布三出口 `onViewportChanged` / `onPagePreview` / `onUserViewportGesture` 与 `handlePreviews` / `syncWithRoom` / `handleLocalPageChanged` 接线；`endDrawer` 面板经 Provider 共享同一实例）、顶部跟随 HUD（`wb-follow-hud` + `wb-follow-stop` 停止）、removed 只读横幅（`wb-removed-banner`）与编辑禁用、recovered「已从存档恢复」轻提示、present 状态条（本人演示 chip / 他人演示署名）、权限收窄接线（`canEdit` → 画布 `setInteractionEnabled` + 浮动工具栏 `drawingEnabled` + 径向 / 创建入口守卫）） | `lib/pages/board_edit_page.dart` | `test/board_wiring_test.dart`、`test/board_file_ui_test.dart`、`test/window_close_prompt_test.dart`、`test/canvas_sync_hooks_test.dart`、`test/collab_m3_widget_test.dart`、`integration_test/create_element_test.dart` |
| 专业元素独立编辑页：全屏路由承载六类上下文编辑器 | `lib/pages/element_editor_page.dart` | `test/element_editor_test.dart` |
| 设置页：外观（主题 / 背景 / 无障碍）、快捷键、AI 助手、协作同步（服务器地址保存：持久化 + 更新生效端点，在房时先断开；预填默认端点）与关于 | `lib/pages/settings_page.dart` | `test/settings_deep_test.dart`、`integration_test/theme_test.dart` |

### 2.6 主界面组件（lib/widgets/ 根）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 画布视图：选择 / 平移 / 缩放 / 绘制 / 创建 / 编辑的完整交互画布（M2：`MouseRegion.onHover` → 远端光标出口；实现位于共享包 `whiteboard_canvas`，本文件为转发层） | `lib/widgets/canvas_view.dart` | `test/canvas_deep_test.dart` |
| 左侧栏 | `lib/widgets/sidebar.dart` | `test/sidebar_deep_test.dart` |
| 页面管理：页面卡片列表 / 缩略图刷新 / 拖拽排序 / 右键菜单 / 多选 | `lib/widgets/page_manager.dart` | `test/sidebar_deep_test.dart`、`integration_test/page_management_test.dart` |
| 底部浮动主工具栏：声明式配置 + 响应式溢出折叠；M3：`drawingEnabled` 门控（false 时仅选择 / 抓手等导航项保留，绘制与撤销重做项置灰） | `lib/widgets/floating_toolbar.dart` | `test/floating_toolbar_deep_test.dart`、`test/collab_m3_widget_test.dart` |
| 齿轮圆盘工具栏：收起为浮动按钮，展开为三层径向工具盘 | `lib/widgets/radial_toolbar.dart` | `test/radial_toolbar_deep_test.dart` |
| AI 助手面板：上下文控制 / 对话流 / 执行卡片 / 幽灵预览 / 语音视觉 / 输入区 | `lib/widgets/ai_panel.dart` | `test/ai_panel_deep_test.dart`、`integration_test/ai_flow_test.dart` |
| 命令面板：模糊搜索、键盘导航与执行 | `lib/widgets/command_palette.dart` | `test/board_wiring_test.dart` |
| 图层区：当前页元素列表 | `lib/widgets/layers_panel.dart` | `test/sidebar_deep_test.dart` |
| 未保存改动三选弹窗（保存 / 不保存 / 取消；edit 页与关窗拦截共用） | `lib/widgets/unsaved_changes_dialog.dart` | `test/board_file_ui_test.dart`、`test/window_close_prompt_test.dart` |

### 2.7 透明批注（lib/widgets/annotation/）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 透明批注 UI 组件库入口 | `lib/widgets/annotation/annotation.dart` | `test/annotation_test.dart` |
| 控制器：状态机 / 进入退出编排 / 全局快捷键 / 保存回白板 | `lib/widgets/annotation/annotation_controller.dart` | `test/annotation_test.dart` |
| 组合层 + 覆盖层画布（笔迹 / 擦除 / 激光笔）+ 右上角悬浮工具栏 | `lib/widgets/annotation/annotation_layer.dart`、`annotation_overlay.dart`、`annotation_toolbar.dart` | `test/annotation_test.dart`、`test/transparent_overlay_test.dart` |
| 退出透明批注模式的三选项弹窗 | `lib/widgets/annotation/annotation_exit_dialog.dart` | `test/annotation_test.dart` |

### 2.8 画布（lib/widgets/canvas/）

> **共享实现（2026-10-02；2026-10-03 复点 37 件）**：画布实现已下沉共享包 `packages/canvas`（`whiteboard_canvas`，Web 端 12 同源接入）；本目录除桌面专用件（`screen_sampler.dart` 屏幕取色、`image_decoder.dart`、`canvas_store.dart` 的 FFI 存储实现）外均为**转发层**（`export 'package:whiteboard_canvas/...'`）；桌面端共 **37 个转发文件**：`widgets/canvas_view.dart`（1）、`widgets/canvas/*`（15）、`widgets/context_editors/*`（9）、`widgets/toolbar/*`（5，P3 迁移）、`widgets/collab/preview_page_match.dart` + `remote_cursors.dart`（2，P4 迁移）、`widgets/page_manager.dart`、`widgets/layers_panel.dart`（2）、`state/page_state.dart`、`state/selection_state.dart`（2）、`services/board_file_codec.dart`（1）。既有测试与 E2E 经原导入路径不感知（dlc-6 / P3/P4 迁移波全量回归 722 通过，与迁移前一致）。

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 画布控制器：视口变换 / 手势状态机 / 工具行为 / 选择 / 编辑命令 / 撤销栈；`documentRevision` 脏标记（真实变更才递增）+ `loadBoardData` 整板加载（提升 `_sequence` 防 id 冲突）；协同钩子（T1.6）：落定提交出口 `onLocalCommit`（`WbCanvasCommitBatch`，与撤销栈同批）+ `isRemoteApplying` 防回发谓词 + 远端入口 `applyRemoteElement` / `applyRemoteRemove`（不入本端撤销栈、选中集同步剔除）；M2 协同增强：预览出口注入面 `onInkPreview`（33ms 节流，笔迹开始预生成元素 id 关联终态）/ `onTransformPreview`（33ms）/ `onCursorMoved`（50ms，hover 世界坐标）/ `onSelectionChanged`（100ms）；远端入口 `applyRemotePreviews`（ink 鬼影 / transform 叠加 / 删除淡出 / 锁快照 `refreshRemoteLocks`；终态 op 到达清除、5s TTL 淡出、已终态 / 非当前页丢弃，跨端 pageId 命名空间经 `previewPageMatches` 页序后缀近似）；笔迹 Douglas-Peucker 抽稀（tolerance 0.75）；擦除逐批删除 op（100ms 节流 + 抬笔 flush）；软锁入口闸门（命中 / 拖动 / 双击 / 右键 / 橡皮擦跳过锁定元素，`ignoreRemoteLocks` 反查）；M3 跟随 / 收窄：视口帧出口 `onViewportChanged`（200ms 节流 `{kind:'viewport', pageId, offset:{dx,dy}, zoom}`；是否发送由应用层 `needsViewportBroadcast` 决定）、切页帧出口 `onPagePreview`（`setPage` 唯一汇聚点 `{kind:'page', pageId}`）、程序化视口入口 `applyRemoteViewport`（跟随同步，不触发用户手势出口）、交互开关 `setInteractionEnabled`（false 时编辑手势 / 快捷键忽略，保留视口浏览 space / 中键 / 手形 / 触屏）、用户视口手势回调 `onUserViewportGesture`（打断跟随） | `lib/widgets/canvas/canvas_controller.dart` | `test/canvas_deep_test.dart`、`test/board_file_service_test.dart`、`test/canvas_sync_hooks_test.dart`、`test/canvas_m2_preview_test.dart`、`test/canvas_m2_render_test.dart`、`test/collab_lock_test.dart`、`test/follow_controller_test.dart`、`test/collab_m3_widget_test.dart` |
| 元素内存模型 + 存储适配器（内存演示 / FFI 引擎两种实现） | `lib/widgets/canvas/canvas_model.dart`、`canvas_store.dart` | `test/canvas_deep_test.dart`、`test/canvas_3d_test.dart` |
| 画布绘制器 + 页面背景共享绘制（底色 / 图案 / 背景图片）；M2 远端呈现层：ink 鬼影（增量点连续绘制 + 缺口连线）/ transform 临时叠加（不落模型）/ 删除淡出 / 软锁角标与虚线框 | `lib/widgets/canvas/canvas_painter.dart`、`background_painter.dart` | `test/canvas_deep_test.dart`、`test/canvas_background_grid_test.dart`、`test/canvas_m2_render_test.dart` |
| 专业元素渲染 + 3D 网格投影公共模块 | `lib/widgets/canvas/professional_painter.dart`、`wb3d_projection.dart` | `test/professional_insert_test.dart`、`test/wb3d_projection_test.dart` |
| 图片解码缓存：文件路径 → `ui.Image`（异步解码 / 并发去重 / 失败静默） | `lib/widgets/canvas/canvas_image_cache.dart` | `test/canvas_deep_test.dart` |
| 文本编辑浮层：跟随元素位置与缩放的内联输入框 | `lib/widgets/canvas/canvas_text_editor.dart` | `test/canvas_deep_test.dart` |
| 工具调色板（11 工具 + 撤销/重做 + 参数）+ 缩放控件 + 迷你地图 | `lib/widgets/canvas/canvas_tool_palette.dart`、`zoom_controls.dart`、`minimap.dart` | `test/canvas_deep_test.dart` |
| 可拖动悬浮面板包装 + 元素尺寸对话框（3D / 2D 宽高） | `lib/widgets/canvas/draggable_overlay.dart`、`element_size_dialog.dart` | `test/draggable_overlay_test.dart`、`test/element_size_dialog_test.dart`、`test/canvas_3d_size_test.dart` |

### 2.9 协作 UI（lib/widgets/collab/）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 连接状态 chip（在房 / 连接中时经入口按钮展示，离线不渲染）：`WbSyncStatus` 五态映射（offline 灰「离线」/ connecting 含重连轮次「连接中」/ online「已连接」/ syncing「同步中」/ error「同步错误」）；悬停提示汇总端点 / 在线人数 / 延迟 / 待确认 / 错误详情 | `lib/widgets/collab/sync_status_chip.dart` | `test/collab_widget_test.dart`、`test/board_wiring_test.dart` |
| 参与者面板（编辑页 `endDrawer`）：名单来自 `WbCollabService.participantList`（`WbCollabParticipant`；本人标记 = `room.selfUserId` 精确匹配，缺失回退末位推断）/ 角色中文映射（主持人 / 联席主持人 / 演示者 / 参与者 / 观看者 / 访客）/ 状态行 + 空态引导（M2 在场以光标层 / 画布锁角标呈现，本面板不含）；M3：行内标记（演示中 / 已举手 / 已授权；subtitle 用 Wrap 防窄 Drawer 溢出）、他人条目「跟随 / 停止跟随」（无跟随 Provider 时降级直发）、CoHost+「授权控制 / 收回控制」与「移除成员」、房间操作区（非 CoHost+ 举手 / 收手、CoHost+ 开始 / 结束演示、演示中署名行） | `lib/widgets/collab/participants_panel.dart` | `test/collab_widget_test.dart`、`test/collab_m3_widget_test.dart` |
| 参与者入口按钮：在线人数徽标（0 隐藏、>9 封顶「9+」），点击打开面板 | `lib/widgets/collab/participants_button.dart` | `test/collab_widget_test.dart` |
| 互动白板入口按钮：离线态「互动白板」文字按钮，非离线态包裹状态 chip（点击挂载方弹「加入房间」或「房间信息」对话框） | `lib/widgets/collab/collab_entry_button.dart` | `test/collab_widget_test.dart`、`test/board_wiring_test.dart` |
| 协同对话框：加入房间（房间号输入 + 服务器地址提示，空输入禁用确认，返回 trim 后房间号）/ 房间信息（房间号 / 服务器 / 状态·人数 / 最近错误 + 「退出互动白板」返回 true；M2：重连预算耗尽时失败提示 + 「重新连接」恢复入口） | `lib/widgets/collab/collab_dialogs.dart` | `test/collab_widget_test.dart`、`test/board_wiring_test.dart` |
| 远端光标与选区层（M2）：按 userId 哈希配色 / 500ms 缓动插值（独立 Ticker）/ 静止 5s 淡出 / 10s 超时清理 / 短标签；世界坐标经 `controller.worldToScreen` 换算；`IgnorePointer` 不拦截画布交互；cursor / selection 帧 pageId 过滤经 `previewPageMatches` 跨端页序近似（M3 D3-0）；**P3/P4 迁移（2026-10-03）**：实现位于共享包 `packages/canvas/lib/collab/remote_cursors.dart`（Web 12 同源消费），本端为转导 | `lib/widgets/collab/remote_cursors.dart` | `test/remote_presence_test.dart`、`test/board_wiring_test.dart` |
| 跨端预览页匹配（M3 D3-0）：`previewPageMatches` —— 帧 pageId 非 String / 空串透传（M2 无 pageId 语义）；与本地全等直放（快速路径）；跨端命名空间（发送端本地板 id 派生 vs 房间号入房）按 `-page-(\d+)$` 页序后缀近似（贪婪取最后匹配）；其余保守丢弃。画布预览入口与在场层两处过滤点共用同一口径 | `lib/widgets/collab/preview_page_match.dart` | `test/preview_page_match_test.dart`、`test/canvas_m2_preview_test.dart`、`test/remote_presence_test.dart` |

### 2.10 上下文编辑器（lib/widgets/context_editors/）

> 实现位于共享包 `whiteboard_canvas`（`packages/canvas/lib/context_editors/`，Web 端同源接入）；本目录为转发层。

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 共享外壳（保存/返回编排）+ 全窗三区布局基础组件 | `lib/widgets/context_editors/context_editor_shell.dart`、`editor_workspace.dart` | `test/context_editors_test.dart` |
| 流程图编辑器（交互增强） | `lib/widgets/context_editors/flowchart_editor.dart` | `test/flowchart_workspace_test.dart`、`integration_test/flowchart_test.dart` |
| 思维导图编辑器（全窗三区重构） | `lib/widgets/context_editors/mindmap_editor.dart` | `test/table_mindmap_workspace_test.dart` |
| 表格编辑器（全窗三区工作区） | `lib/widgets/context_editors/table_editor.dart` | `test/table_mindmap_workspace_test.dart` |
| 函数图像编辑器（多曲线管理） | `lib/widgets/context_editors/function_editor.dart` | `test/context_editors_test.dart`、`integration_test/function_test.dart` |
| 2D 图元编辑器（圆盘「函数 / 3D / 2D」组 render2d 入口） | `lib/widgets/context_editors/render2d_editor.dart` | `test/context_editors_test.dart` |
| 3D 对象编辑器 | `lib/widgets/context_editors/render3d_editor.dart` | `test/context_editors_test.dart`、`integration_test/render3d_test.dart` |
| 快速创建入口（五类编辑器统一入口） | `lib/widgets/context_editors/quick_create.dart` | `test/board_wiring_test.dart`、各 workspace 测试 |

### 2.11 引导与帮助（lib/widgets/guide/）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 引导与帮助内容数据 + 语义图标映射 | `lib/widgets/guide/guide_content.dart`、`guide_icons.dart` | `test/guide_test.dart` |
| 帮助中心：快速上手 / 用户手册 / 进阶技巧 / FAQ 与全局搜索 | `lib/widgets/guide/help_center.dart` | `test/guide_test.dart`、`test/board_wiring_test.dart` |
| 新手引导浮层：分步高亮 + 提示卡片 | `lib/widgets/guide/onboarding_overlay.dart` | `test/guide_test.dart` |
| 快捷键卡片 + 弹层入口（命令面板 / 宿主共用） | `lib/widgets/guide/shortcut_card.dart`、`shortcut_card_dialog.dart` | `test/guide_test.dart` |

### 2.12 径向圆盘（lib/widgets/radial/）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 数据模型（工具 / 分组 / 目录 / 设置 / 命中结果）+ 右键配置菜单与"更多"菜单 | `lib/widgets/radial/radial_models.dart`、`radial_config.dart` | `test/radial_toolbar_deep_test.dart` |
| 几何纯函数：角度分配、径向命中测试与子环槽位计算 | `lib/widgets/radial/radial_layout.dart` | `test/radial_toolbar_deep_test.dart`（目录与几何组） |
| 可视化主体 + 条目按钮与最近使用快捷条 | `lib/widgets/radial/radial_menu.dart`、`radial_item.dart` | `test/radial_toolbar_deep_test.dart` |
| 临时圆盘弹出（长按画布）+ 拖拽轨迹线绘制 | `lib/widgets/radial/radial_popup.dart`、`radial_trail.dart` | `test/radial_toolbar_deep_test.dart`、`test/board_wiring_test.dart` |
| 圆盘工具 → 画布行为纯映射表（全量覆盖 `RadialCatalog`） | `lib/widgets/radial/radial_tool_mapping.dart` | `test/radial_tool_mapping_test.dart` |

### 2.13 设置面板（lib/widgets/settings/）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 设置分区组件：分组标题、卡片容器与条目样式 | `lib/widgets/settings/settings_section.dart` | `test/settings_deep_test.dart` |
| 主题选择器：9 个内置主题（+ 自定义）预览卡片、跟随系统、图标包 | `lib/widgets/settings/theme_selector.dart` | `test/settings_deep_test.dart`、`integration_test/theme_test.dart` |
| 背景选择器：内置预设网格（纯色 / 点阵 / 网格 / 横线 / 方格） | `lib/widgets/settings/background_picker.dart` | `test/settings_deep_test.dart`、`test/canvas_background_grid_test.dart` |
| 无障碍设置：减少动效 / 减少透明度 / 高对比度 / 字号缩放 | `lib/widgets/settings/accessibility_settings.dart` | `test/settings_deep_test.dart` |
| 快捷键设置：文档快捷键总览（只读）与键位冲突检测提示 | `lib/widgets/settings/hotkey_settings.dart` | `test/settings_deep_test.dart` |

### 2.14 工具栏原子组件（lib/widgets/toolbar/）

> **共享实现（2026-10-03）**：本目录 5 个文件（`toolbar_config` / `toolbar_item` / `color_picker_popover` / `color_wheel` / `context_toolbar`）已迁共享包 `packages/canvas/lib/toolbar/`（唯一实现来源；Web 端 12 同源直接消费），本端为**转发层**（各 7 行 `export 'package:whiteboard_canvas/toolbar/...'`）；既有测试经原导入路径不感知（P3/P4 全量回归通过）。

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 可扩展工具栏配置模型（ToolRegistry / ContextResolver 数据面）+ 原子组件（图标按钮 / 分隔线） | `lib/widgets/toolbar/toolbar_config.dart`、`toolbar_item.dart` | `test/floating_toolbar_deep_test.dart` |
| 上下文工具栏：按选中对象类型（便签 / 文本 / 形状 / 连线 / 图片 / 3D） | `lib/widgets/toolbar/context_toolbar.dart` | `test/floating_toolbar_deep_test.dart`、`test/canvas_deep_test.dart` |
| 工具栏样式弹层：颜色选择、单选（对齐 / 线型 / 字号）、线宽 | `lib/widgets/toolbar/color_picker_popover.dart` | `test/floating_toolbar_deep_test.dart` |

### 2.15 单元与 widget 测试（test/，43 文件 / 674 用例）

| 分组 | 测试文件 | 用例 |
|---|---|---|
| 应用装配与路由 | `test/desktop_test.dart`、`test/board_wiring_test.dart` | 23 |
| 协同同步（T1.6） | `test/sync_service_test.dart`、`test/canvas_sync_hooks_test.dart` | 70 |
| 协同 M2（预览 / 鬼影 / 软锁 / 在场） | `test/canvas_m2_preview_test.dart`、`canvas_m2_render_test.dart`、`collab_lock_test.dart`、`remote_presence_test.dart` | 47 |
| 协同 M3（跨端预览页匹配） | `test/preview_page_match_test.dart` | 10 |
| 协同 M3（跟随 / 演示 / 举手 / 授权 / 角色收窄 / 发起端补丁） | `test/collab_m3_service_test.dart`、`test/follow_controller_test.dart`、`test/collab_m3_widget_test.dart` | 101 |
| 协作 UI（T1.7） | `test/collab_widget_test.dart` | 18 |
| 画布核心交互 | `test/canvas_deep_test.dart` | 38 |
| 画布 3D（渲染 / 尺寸 / UI / 投影） | `test/canvas_3d_test.dart`、`canvas_3d_size_test.dart`、`canvas_3d_ui_test.dart`、`wb3d_projection_test.dart` | 29 |
| 画布背景与专业元素 | `test/canvas_background_grid_test.dart`、`test/professional_insert_test.dart` | 15 |
| 圆盘工具栏（含映射表） | `test/radial_toolbar_deep_test.dart`、`test/radial_tool_mapping_test.dart` | 35 |
| 侧栏与页面管理 | `test/sidebar_deep_test.dart` | 26 |
| 页面状态协同（R3 页结构同步） | `test/page_state_collab_test.dart` | 8 |
| AI 面板与工具执行器 | `test/ai_panel_deep_test.dart`、`test/ai_canvas_executor_test.dart` | 31 |
| 透明批注 | `test/annotation_test.dart` | 27 |
| 上下文编辑器与工作区 | `test/context_editors_test.dart`、`flowchart_workspace_test.dart`、`table_mindmap_workspace_test.dart`、`element_editor_test.dart` | 55 |
| 设置（主题 / 背景 / 无障碍 / 热键） | `test/settings_deep_test.dart` | 22 |
| 引导与帮助 | `test/guide_test.dart` | 20 |
| 浮动工具栏与部件 | `test/floating_toolbar_deep_test.dart`、`draggable_overlay_test.dart`、`element_size_dialog_test.dart` | 33 |
| 平台（透明叠加 / 桌面背景） | `test/transparent_overlay_test.dart`、`test/desktop_backdrop_test.dart` | 19 |
| 本地文件与设置持久化 | `test/settings_persistence_test.dart`、`board_file_codec_test.dart`、`board_file_service_test.dart`、`window_close_prompt_test.dart`、`board_file_ui_test.dart` | 47 |
| **合计** | **43 个文件** | **674** |

### 2.16 FFI 集成测试（test/integration/，7 文件 / 26 用例，真实 DLL）

| 文件 | 覆盖 | 用例 |
|---|---|---|
| `test/integration/ffi_init_test.dart` | 版本字符串、重复 init 幂等、非法配置返回 1、白板/页面探针；**缺失动态库路径时 load 抛出 ArgumentError（优雅降级入口）** | 5 |
| `test/integration/ffi_command_test.dart` | 元素 CRUD、命令总线（`command.history` / `command.undo` / `command.redo`）、工具调用、错误信封语义；**回归：undo/redo 走 command 域、`wb_element_batch` 顶层数组** | 6 |
| `test/integration/ffi_memory_test.dart` | UTF-8 中文/emoji 往返、句柄循环创建/销毁、渲染缓存命中与清空、`requireResult` 异常 | 5 |
| `test/integration/ffi_render_test.dart` | 显示列表、3D 创建与渲染、缩略图、缓存与性能统计不变量、已知偏差①②③（记录不修复） | 5 |
| `test/integration/ffi_sync_roundtrip_test.dart` | T1.6 真实 realtime 往返（env-gated：`WB_REALTIME_E2E=1`）：本地 realtime ← 真实 C++ socket.io 客户端（connect / join / sendOperation / events）；node 探针作第二客户端，验证发送方向 op key/value/actor 与反向回发放射接收 | 1 |
| `test/integration/ffi_sync_dual_process_test.dart` | T1.6 双进程「双开等价」（env-gated + `WB_DUAL_*` 注入）：两个真实引擎进程同房互发互收——接收端等 join 确认 → 收 op 应用；发送端落定提交 → 等服务端 ack（`latencyMs > 0`）。M3 D3-0 预览流闭环：发送端落定后再发一条命名空间无关的 ink 预览帧（pageId `remote-ns-page-1`）→ 接收端 `onRemotePreviews` 收集 + 断言后写 `WB_DUAL_PREVIEW_FLAG` 信号，发送端等待后退出（亦经仓库级 `tests/e2e/support/run_collab_dual_end.mjs` desktop 段编排真跑） | 2 |
| `test/integration/ffi_sync_interactive_e2e_test.dart` | M3 双进程「真引擎 interactive 闭环」（env-gated + `WB_DUAL_*` 注入；门 G3 证据补齐）：两真实引擎进程经 realtime 完成 raiseHand 广播 + follow 单播闭环（接收端等 join 确认 → 收 participants 增量 / follow 单播断言；亦经 `run_collab_dual_end.mjs` desktop 段编排） | 2 |
| `test/integration/support/`（`ffi_support.dart`、`wb_realtime_probe.mjs`、`run_dual_process_ffi_test.mjs`） | 脚手架：DLL 定位（候选路径 + 4 层父目录探测）、`ffiIntegrationSkipReason`（`WB_REQUIRE_CORE_DLL=1` 强校验）、`loadRealCore`、`FfiBoardHandle` / `createBoardWithPage`；node 探针（第二客户端）；双进程协调脚本（起服务 → 接收端就绪信号 → 发送端 → 双 exit 断言） | — |

### 2.17 端到端场景（integration_test/，9 场景 / 19 个 testWidgets）

| 场景文件 | 覆盖 |
|---|---|
| `integration_test/app_test.dart` | 启动进入首页（FFI 缺失降级演示模式）、首页 → 设置 → 返回、编辑页帮助中心 |
| `integration_test/create_board_test.dart` | 新建白板进入编辑页并可返回、连续创建累积最近白板 |
| `integration_test/create_element_test.dart` | 工具创建便签（进入编辑态 → 输入 → Esc 提交）、创建后连续撤销 |
| `integration_test/page_management_test.dart` | 新建页面卡片 +1、切回第一页 |
| `integration_test/theme_test.dart` | 切换深色主题、切换后背景预设分区仍可见 |
| `integration_test/ai_flow_test.dart` | 未配置提供商时降级提示、AI 面板收展 |
| `integration_test/flowchart_test.dart` | 快速创建打开流程图编辑器、添加节点 + 自动布局 |
| `integration_test/function_test.dart` | 表达式校验、曲线增删 |
| `integration_test/render3d_test.dart` | 类型 / 材质切换与重置、关闭后对话框回收 |
| `integration_test/support/e2e_support.dart` | 脚手架：`demoFfi`（失败路径注入 → 演示模式）、`pumpApp` / `pumpEditor`（1600x1000 视口）、`openQuickCreate`、`dismissOverlay` |

### 2.18 Windows 运行器与 wb_core.dll 部署（windows/）

| 功能 | 实现文件 |
|---|---|
| `wb_core.dll` 部署：`add_custom_target(wb_core_dll_deploy ALL)` + **四级源解析**（`-DWB_CORE_DLL` → `$ENV{WB_CORE_DLL}` → 默认 `<repo>/build/windows-x64/bin/$<CONFIG>/wb_core.dll` → Release 回退 `<repo>/build/windows-x64/bin/Release/wb_core.dll`，因 core preset 只构建 Release，Debug/Profile 构建靠回退部署而非跳过）；缺失仅 WARNING、绝不失败构建、不删文件 | `windows/CMakeLists.txt`、`windows/copy_wb_core.cmake` |
| 运行器（原生入口与窗口）：`main.cpp`、`flutter_window.*`、`win32_window.*`、`utils.*`、`Runner.rc`、`runner.exe.manifest`、`resource.h`、`resources/app_icon.ico` | `windows/runner/**` |
| Flutter 工具生成物（不手工修改）：`generated_plugins.cmake`、`generated_plugin_registrant.*`、`ephemeral/**` | `windows/flutter/**` |

### 2.19 资源目录（assets/）

| 功能 | 实现文件 |
|---|---|
| 资源目录骨架（仅 `.gitkeep`；已在 `pubspec.yaml` 声明 `assets/images/`、`assets/templates/`） | `assets/images/.gitkeep`、`assets/templates/.gitkeep` |

## 3. 契约与依赖

- **依赖（pubspec.yaml）**：10 个 path 包——`whiteboard_ui`、`whiteboard_ui_kit`、`whiteboard_theme`、`whiteboard_icons`、`whiteboard_core`、`whiteboard_canvas`（共享画布 / 上下文编辑器 / `.wbd` 编解码，与 12 Web 同源）、`whiteboard_ai`、`whiteboard_api_client`、`whiteboard_mcp_client`、`whiteboard_windows`；第三方——`provider` / `riverpod` / `go_router` / `window_manager` / `hotkey_manager` / `tray_manager` / `screen_retriever`；dev——`flutter_test` / `flutter_lints` / `integration_test`。
- **被依赖**：无（终端应用；`apps/web`（12）、`apps/mobile` 为预留）。
- **关键契约（回归依据）**：
  - **路由路径固化**（`lib/routes.dart` 的 `WbRoutes`）：`/`、`/board/:boardId`、`/board/:boardId/editor`、`/settings`；深链与 E2E 依赖，修改必须同步 `integration_test/**`；
  - **FFI 集成测试约定**（`test/integration/support/ffi_support.dart`）：DLL 候选路径 `../../build/windows-x64/bin/Release/wb_core.dll` / `build/windows-x64/bin/Release/wb_core.dll` + 最多 4 层父目录兜底探测；`WB_REQUIRE_CORE_DLL=1` 时 DLL 缺失直接抛 `StateError`（防整包静默假绿），否则返回跳过原因；断言不依赖具体 `board-N` 编号（并发 isolate 共享引擎状态）；不调用 `wb_shutdown`；
  - **演示模式接缝**：`WbFfiService(candidatePaths: [...])` 注入失败路径 → 应用内降级（`canvas_store` 内存数据源）；E2E 用 `__wb_missing__.dll` 保证确定性；
  - **windows DLL 部署**：`copy_wb_core.cmake` 四级源解析（含 Release 回退：Debug/Profile 构建部署 Release 版 DLL，避免 core preset 只构建 Release 时跳过部署）；目标为空或疑似文件路径 → WARNING 跳过；应用可在无原生核心时构建、运行时降级（与 07 的加载器行为配套）；
  - **本地文件契约**：`.wbd` 白板文件（UTF-8 JSON：`format:"whiteboard-board"` / `version:1`；全元素 + 6 类专业 payload；未知字段忽略、缺省取默认、坏结构抛 `FormatException`）与 `%APPDATA%\Whiteboard\settings.json`（主题/外观/AI/协作/最近列表；API 密钥明文）均由 `board_file_codec.dart`（实现位于共享包 `whiteboard_canvas`，本端为转发层；与 12 Web 同一 `.wbd` 格式） / `settings_store.dart` 固化，格式改动需同步 12 号（Web 导入 / 导出 / localStorage 存档同格式）与 18 号规模基线；
  - **协同同步契约（T1.6）**：op key `el:{id}:data`（value = 元素契约 JSON，复用 `board_file_codec` 映射）/ `el:{id}:exists=false`（删除）；actor 为每连接会话随机 uuid；远端应用期间画布出口跳过（防回发）、远端 op 不入本端撤销栈；`WbCollabService` 默认 endpoint `http://127.0.0.1:8790`（可注入）；UI 读取面 `WbCollabParticipant` / `participantList`（M1 末位自标识推断）；
  - **协同预览与软锁契约（M2）**：预览经 `presence:preview` 泛化转发（服务端注入 userId、排除发送者）——`ink`（strokeId = 预生成元素 id、pageId、Δpoints、style、highlight）/ `transform`（elementId、pageId、x/y/w/h）/ `cursor`（pageId、世界坐标）/ `selection`（pageId、elementIds）；锁经 `lock:acquire/release/renew`（ack 回执）+ `lock:changed` 广播，快照 `board:joined.locks`（对象 map `{elementId: {userId, expiresAt}}`，TTL 30s）；桌面侧 10s 续约 / `reconnectBudget = 5`；终态 op 到达即清对应鬼影（丢弃已终态预览）；接收端页过滤口径（M3 D3-0）：帧无 pageId / 空串透传，本地全等直放，跨端命名空间按 `-page-N` 页序后缀近似（`previewPageMatches`，画布与在场层共用；页结构跨端未同步，与 M3 跟随功能同口径），其余保守丢弃；
  - **协同交互契约（M3）**：`interactive:{action}` 动作白名单 9 个（raiseHand / lowerHand / grantControl / revokeControl / startPresent / stopPresent / removeUser / follow / unfollow）；`WbSyncInteractiveResult.requested` 离线 / 未连接恒 false 不抛；权限判定 `canEdit`（**只控白板编辑、不控透明批注**）：removed → false；`selfRole` 空串 → true（本地放行）；`grantedWrite` → true；present 模式 → selfRole ∈ {Host, CoHost, Presenter}；否则 roleCanWrite（≥ Participant）；演示自动跟随（mode=present 且 presenterId≠自己 → 自动 `interactive:follow`；手动停止后本轮抑制）；跟随帧消费：viewport `{kind:'viewport', pageId, offset:{dx,dy}, zoom}` → 画布 `applyRemoteViewport`，page `{kind:'page', pageId}` → `-page-(\d+)$` 提取页序切本地同序页（无此页忽略切页仅同步视口；仅取被跟随者帧）；checkpoint 引擎内自动响应与 `joined.snapshot` 自动恢复由引擎完成，桌面仅消费 `checkpointStatus` / `recovered` 提示；`room:removed` 单播 → 只读态（横幅 + 编辑禁用）；发起端本地确定性更新：服务端互动广播排除发起者（`socket.to`），6 个发起动作（raiseHand / lowerHand / grantControl / revokeControl / startPresent / stopPresent）ack 成功后由本端补丁先行生效（`_pendingInteractivePatches` 按 action FIFO；失败丢弃并报错），保证举手 / 收手、授权 / 收回、演示开关在发起端即时可用（修复「举手后按钮无法收手」）；
  - **widgets 稳定 Key 属隐性契约**：如 `wb-ctx-quick-create-*`、`page-card-*`、`pages-add`、`theme-card-*`、`wb-sync-status-chip`、`wb-collab-entry`、`wb-collab-join-dialog`、`wb-collab-room-dialog`、`wb-participants-panel`、`wb-participants-button`、`wb-participant-*`、`wb-participant-follow-*`、`wb-participant-grant-*`、`wb-participant-remove-*`、`wb-panel-hand-toggle`、`wb-panel-present-toggle`、`wb-follow-hud`、`wb-follow-stop`、`wb-removed-banner` 被 E2E / 深度测试定位，改动前先全局搜索；
  - **测试规模**：声明 **700 用例**（`test/` 674 + `test/integration/` 26；runner 参数化展开后实跑 **727 = 722 通过 + 5 跳过**，2026-10-03 复点）；`flutter test`（apps/desktop，`--no-pub`）的 5 个跳过为 realtime env-gated（双进程 ×4 + 单进程往返 ×1，未设 `WB_REALTIME_E2E=1` 时跳过）；E2E 19 用例需 Windows 桌面会话。
- **上游契约**：07（`WbCoreFfi` / 领域服务面）、08（UI Kit/主题/图标）、09（AI 客户端）、10（`whiteboard_windows` 插件）。

## 4. 常用命令

```powershell
# 依赖、分析、全量测试（apps/desktop 目录）
Set-Location apps\desktop; E:\code\flutter-sdk\flutter\bin\flutter.bat pub get; E:\code\flutter-sdk\flutter\bin\flutter.bat analyze
E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub
# 真实 DLL FFI 集成（先构建 C++ 核心，见 17-build-release）
$env:WB_REQUIRE_CORE_DLL='1'; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub test/integration
# 协同真连（env-gated：单进程往返先跑；双进程「双开等价」用协调脚本）
$env:WB_REALTIME_E2E='1'; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub test/integration
node test/integration/support/run_dual_process_ffi_test.mjs
# 桌面运行与构建（含 wb_core.dll 随构建部署）
E:\code\flutter-sdk\flutter\bin\flutter.bat run -d windows
E:\code\flutter-sdk\flutter\bin\flutter.bat build windows --release
# E2E 场景（需可交互 Windows 桌面会话；单文件示例）
E:\code\flutter-sdk\flutter\bin\flutter.bat test integration_test\app_test.dart -d windows
```

## 5. 变更影响提醒（改本模块时注意）

- 改 `lib/routes.dart` 路由路径 / 参数 → `integration_test/**` 与深链行为；若涉及跨端路径对齐，同步 12-app-web 规划。
- 改 `lib/widgets/canvas_view.dart`、`lib/widgets/canvas/*`、`lib/widgets/context_editors/*`、`lib/widgets/toolbar/*`（5 件）、`lib/widgets/collab/preview_page_match.dart` + `remote_cursors.dart`、`lib/state/selection_state.dart`、`lib/services/board_file_codec.dart` 等**共享包转发层** → 真实实现在 `packages/canvas`（`whiteboard_canvas`），改动落共享包并同时回归两端（12 Web 同源消费；转发层保持导出名稳定，勿在桌面端新增重复实现）。
- 改 `lib/state/**` 的 ChangeNotifier 契约 → 多组 widget 测试编译/断言受影响，改后必须全量 `flutter test`（722 通过 / 5 跳过）。
- 画布元素 id 格式为 `wb-el-<ns>-N`（控制器实例级命名空间，方案 B 跨端防撞车；旧格式 `wb-el-N` 文档读取兼容无需迁移）→ 改 `canvas_controller.dart` 的 `_nextId` / `_adoptIdSequence` 或元素 id 生成路径时，回归 `test/canvas_sync_hooks_test.dart`「元素 id 命名空间」组，并复核协同双端 id 不撞。
- 改 `lib/services/ffi_service.dart`（候选路径 / 降级判定 / 子服务 getter）→ `test/integration/**` 与 E2E 演示模式链路；FFI 行为回归同时对照 07 模块。
- 改 `lib/services/sync_service.dart`（op key 契约 / 状态映射 / 轮询时序 / participantList 与 selfUserId 读取面；M2 预览 `sendPreview` / 软锁 `lock*` 与 `remoteLocks` / `reconnect` 语义；M3 `interactive` 动作面与 `canEdit` / `followers` / `removed` / `checkpointStatus` 读取面）或 `canvas_controller.dart` 协同钩子与 M2 预览注入面 / M3 跟随出口（`onViewportChanged` / `onPagePreview` / `applyRemoteViewport` / `setInteractionEnabled` / `onUserViewportGesture`）/ `lib/state/follow_controller.dart` / `lib/widgets/collab/**` UI → `test/sync_service_test.dart`、`test/collab_widget_test.dart`、`test/canvas_sync_hooks_test.dart`、M2 专项 `test/canvas_m2_preview_test.dart`、`test/canvas_m2_render_test.dart`、`test/collab_lock_test.dart`、`test/remote_presence_test.dart`、M3 专项 `test/preview_page_match_test.dart`、`test/collab_m3_service_test.dart`、`test/follow_controller_test.dart`、`test/collab_m3_widget_test.dart` 与 `test/integration/ffi_sync_*` 真连测试（协议联动 services/realtime，13-16）。
- 改 `test/integration/support/run_dual_process_ffi_test.mjs` / `wb_realtime_probe.mjs`，或仓库级 `tests/e2e/support/run_collab_dual_end.mjs` 的 desktop 段（经 `WB_DUAL_*` / `WB_DUAL_PREVIEW_FLAG` 注入驱动本模块双进程测试）→ 双进程与探针真连依赖 node + `services/realtime` 的 dist 构建与已构建 `wb_core.dll`（构建写 DLL 期间避免并发真跑），与 13-16 协议变更同步核对。
- 改 `windows/copy_wb_core.cmake` / `windows/CMakeLists.txt` 部署逻辑 → 17-build-release 打包链路与运行时分发（`wb_core.dll` 随包）核对。
- 改 widgets 稳定 Key（`wb-ctx-quick-create-*`、`page-card-*` 等）→ E2E 与深度测试大量使用，属"隐性契约"；先全局搜索再改。
- 改 `.wbd` 文件格式 / `settings.json` 形状 / `board_file_*` 服务 API → 同步本文档 2.3、10 号（对话框方法）与 18 号规模基线；`WbBoardOpenRequest` 改名会打穿列表页 / 编辑页 / 路由三处。
- 依赖 07/08/09/10 的公开 API：对方改动会使本模块编译期暴露，用全量 `flutter analyze` + `flutter test` 验证。
- 新增/删除 `lib/**`、`test/**`、`integration_test/**` 文件 → 同步更新本文档 2.x 映射、2.15-2.17 用例数。
