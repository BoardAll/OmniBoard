# 11 · app-desktop —— 桌面应用

> 模块路径：`apps/desktop`
> 维护 agent：`wb-app-desktop-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：Flutter Windows 桌面应用的全部装配与交互——入口与路由（`lib/main.dart`、`lib/app.dart`、`lib/routes.dart`）、状态层（`lib/state/`）、服务层（`lib/services/`）、平台层（`lib/platform/`）、页面（`lib/pages/`）、widgets（`lib/widgets/` 及 7 个子目录）、单元/widget 测试（`test/`）、真实 DLL FFI 集成测试（`test/integration/`）、端到端场景（`integration_test/`）、Windows 运行器与 `wb_core.dll` 部署（`windows/`）、资源目录（`assets/`）。
- **不负责**：FFI 绑定与域服务封装（→ [07-dart-core](07-dart-core.md)）；基础组件/图标/主题库（→ [08-dart-ui](08-dart-ui.md)）；AI/REST/MCP 客户端协议（→ [09-dart-client](09-dart-client.md)）；平台插件原生实现（→ [10-dart-platform](10-dart-platform.md)）；C++ 引擎（→ 01-06）；服务端（→ 13-16）。
- **规模（如实）**：`lib/` 90 个实现文件；`test/` 31 文件 414 用例 + `test/integration/` 5 文件 21 用例（全量 **435** 用例，实测 `flutter test` 全绿）；`integration_test/` 9 个场景文件（19 个 `testWidgets`，需 Windows 桌面环境）；`assets/` 为骨架（仅 `.gitkeep` 占位）。
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

### 2.3 服务层（lib/services/）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| FFI 服务：懒加载核心引擎（候选路径 + 演示模式降级）、聚合各领域子服务 | `lib/services/ffi_service.dart` | `test/desktop_test.dart`、`test/integration/ffi_init_test.dart` |
| 主题服务：桥接主题管理器与偏好持久化（`WbSettingsStore` 可选注入，缺省纯内存） | `lib/services/theme_service.dart` | `test/settings_deep_test.dart`、`test/settings_persistence_test.dart` |
| AI 应用服务：组合 Dart 侧 AI SDK 与引擎侧 AI 域 | `lib/services/ai_service.dart` | `test/ai_panel_deep_test.dart` |
| 白板内置 AI 工具定义（命名映射） | `lib/services/ai_tools.dart` | `test/ai_canvas_executor_test.dart` |
| AI 工具调用执行器：把模型返回的工具调用落地到画布 | `lib/services/ai_canvas_executor.dart` | `test/ai_canvas_executor_test.dart` |
| 同步服务（骨架）：连接状态机 + 手动同步入口 | `lib/services/sync_service.dart` | `test/desktop_test.dart` |
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
| 白板编辑页：画布 + 左侧栏 + AI 面板 + 径向/浮动工具栏；保存（Ctrl+S）/ 打开 / 返回列表未保存三选 / 标题脏标记 ` •` | `lib/pages/board_edit_page.dart` | `test/board_wiring_test.dart`、`test/board_file_ui_test.dart`、`test/window_close_prompt_test.dart`、`integration_test/create_element_test.dart` |
| 专业元素独立编辑页：全屏路由承载六类上下文编辑器 | `lib/pages/element_editor_page.dart` | `test/element_editor_test.dart` |
| 设置页：外观（主题 / 背景 / 无障碍）、快捷键、AI 助手、协作同步与关于 | `lib/pages/settings_page.dart` | `test/settings_deep_test.dart`、`integration_test/theme_test.dart` |

### 2.6 主界面组件（lib/widgets/ 根）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 画布视图：选择 / 平移 / 缩放 / 绘制 / 创建 / 编辑的完整交互画布 | `lib/widgets/canvas_view.dart` | `test/canvas_deep_test.dart` |
| 左侧栏 | `lib/widgets/sidebar.dart` | `test/sidebar_deep_test.dart` |
| 页面管理：页面卡片列表 / 缩略图刷新 / 拖拽排序 / 右键菜单 / 多选 | `lib/widgets/page_manager.dart` | `test/sidebar_deep_test.dart`、`integration_test/page_management_test.dart` |
| 底部浮动主工具栏：声明式配置 + 响应式溢出折叠 | `lib/widgets/floating_toolbar.dart` | `test/floating_toolbar_deep_test.dart` |
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

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 画布控制器：视口变换 / 手势状态机 / 工具行为 / 选择 / 编辑命令 / 撤销栈；`documentRevision` 脏标记（真实变更才递增）+ `loadBoardData` 整板加载（提升 `_sequence` 防 id 冲突） | `lib/widgets/canvas/canvas_controller.dart` | `test/canvas_deep_test.dart`、`test/board_file_service_test.dart` |
| 元素内存模型 + 存储适配器（内存演示 / FFI 引擎两种实现） | `lib/widgets/canvas/canvas_model.dart`、`canvas_store.dart` | `test/canvas_deep_test.dart`、`test/canvas_3d_test.dart` |
| 画布绘制器 + 页面背景共享绘制（底色 / 图案 / 背景图片） | `lib/widgets/canvas/canvas_painter.dart`、`background_painter.dart` | `test/canvas_deep_test.dart`、`test/canvas_background_grid_test.dart` |
| 专业元素渲染 + 3D 网格投影公共模块 | `lib/widgets/canvas/professional_painter.dart`、`wb3d_projection.dart` | `test/professional_insert_test.dart`、`test/wb3d_projection_test.dart` |
| 图片解码缓存：文件路径 → `ui.Image`（异步解码 / 并发去重 / 失败静默） | `lib/widgets/canvas/canvas_image_cache.dart` | `test/canvas_deep_test.dart` |
| 文本编辑浮层：跟随元素位置与缩放的内联输入框 | `lib/widgets/canvas/canvas_text_editor.dart` | `test/canvas_deep_test.dart` |
| 工具调色板（11 工具 + 撤销/重做 + 参数）+ 缩放控件 + 迷你地图 | `lib/widgets/canvas/canvas_tool_palette.dart`、`zoom_controls.dart`、`minimap.dart` | `test/canvas_deep_test.dart` |
| 可拖动悬浮面板包装 + 元素尺寸对话框（3D / 2D 宽高） | `lib/widgets/canvas/draggable_overlay.dart`、`element_size_dialog.dart` | `test/draggable_overlay_test.dart`、`test/element_size_dialog_test.dart`、`test/canvas_3d_size_test.dart` |

### 2.9 上下文编辑器（lib/widgets/context_editors/）

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

### 2.10 引导与帮助（lib/widgets/guide/）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 引导与帮助内容数据 + 语义图标映射 | `lib/widgets/guide/guide_content.dart`、`guide_icons.dart` | `test/guide_test.dart` |
| 帮助中心：快速上手 / 用户手册 / 进阶技巧 / FAQ 与全局搜索 | `lib/widgets/guide/help_center.dart` | `test/guide_test.dart`、`test/board_wiring_test.dart` |
| 新手引导浮层：分步高亮 + 提示卡片 | `lib/widgets/guide/onboarding_overlay.dart` | `test/guide_test.dart` |
| 快捷键卡片 + 弹层入口（命令面板 / 宿主共用） | `lib/widgets/guide/shortcut_card.dart`、`shortcut_card_dialog.dart` | `test/guide_test.dart` |

### 2.11 径向圆盘（lib/widgets/radial/）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 数据模型（工具 / 分组 / 目录 / 设置 / 命中结果）+ 右键配置菜单与"更多"菜单 | `lib/widgets/radial/radial_models.dart`、`radial_config.dart` | `test/radial_toolbar_deep_test.dart` |
| 几何纯函数：角度分配、径向命中测试与子环槽位计算 | `lib/widgets/radial/radial_layout.dart` | `test/radial_toolbar_deep_test.dart`（目录与几何组） |
| 可视化主体 + 条目按钮与最近使用快捷条 | `lib/widgets/radial/radial_menu.dart`、`radial_item.dart` | `test/radial_toolbar_deep_test.dart` |
| 临时圆盘弹出（长按画布）+ 拖拽轨迹线绘制 | `lib/widgets/radial/radial_popup.dart`、`radial_trail.dart` | `test/radial_toolbar_deep_test.dart`、`test/board_wiring_test.dart` |
| 圆盘工具 → 画布行为纯映射表（全量覆盖 `RadialCatalog`） | `lib/widgets/radial/radial_tool_mapping.dart` | `test/radial_tool_mapping_test.dart` |

### 2.12 设置面板（lib/widgets/settings/）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 设置分区组件：分组标题、卡片容器与条目样式 | `lib/widgets/settings/settings_section.dart` | `test/settings_deep_test.dart` |
| 主题选择器：9 个内置主题（+ 自定义）预览卡片、跟随系统、图标包 | `lib/widgets/settings/theme_selector.dart` | `test/settings_deep_test.dart`、`integration_test/theme_test.dart` |
| 背景选择器：内置预设网格（纯色 / 点阵 / 网格 / 横线 / 方格） | `lib/widgets/settings/background_picker.dart` | `test/settings_deep_test.dart`、`test/canvas_background_grid_test.dart` |
| 无障碍设置：减少动效 / 减少透明度 / 高对比度 / 字号缩放 | `lib/widgets/settings/accessibility_settings.dart` | `test/settings_deep_test.dart` |
| 快捷键设置：文档快捷键总览（只读）与键位冲突检测提示 | `lib/widgets/settings/hotkey_settings.dart` | `test/settings_deep_test.dart` |

### 2.13 工具栏原子组件（lib/widgets/toolbar/）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 可扩展工具栏配置模型（ToolRegistry / ContextResolver 数据面）+ 原子组件（图标按钮 / 分隔线） | `lib/widgets/toolbar/toolbar_config.dart`、`toolbar_item.dart` | `test/floating_toolbar_deep_test.dart` |
| 上下文工具栏：按选中对象类型（便签 / 文本 / 形状 / 连线 / 图片 / 3D） | `lib/widgets/toolbar/context_toolbar.dart` | `test/floating_toolbar_deep_test.dart`、`test/canvas_deep_test.dart` |
| 工具栏样式弹层：颜色选择、单选（对齐 / 线型 / 字号）、线宽 | `lib/widgets/toolbar/color_picker_popover.dart` | `test/floating_toolbar_deep_test.dart` |

### 2.14 单元与 widget 测试（test/，31 文件 / 414 用例）

| 分组 | 测试文件 | 用例 |
|---|---|---|
| 应用装配与路由 | `test/desktop_test.dart`、`test/board_wiring_test.dart` | 21 |
| 画布核心交互 | `test/canvas_deep_test.dart` | 38 |
| 画布 3D（渲染 / 尺寸 / UI / 投影） | `test/canvas_3d_test.dart`、`canvas_3d_size_test.dart`、`canvas_3d_ui_test.dart`、`wb3d_projection_test.dart` | 29 |
| 画布背景与专业元素 | `test/canvas_background_grid_test.dart`、`test/professional_insert_test.dart` | 15 |
| 圆盘工具栏（含映射表） | `test/radial_toolbar_deep_test.dart`、`test/radial_tool_mapping_test.dart` | 35 |
| 侧栏与页面管理 | `test/sidebar_deep_test.dart` | 24 |
| AI 面板与工具执行器 | `test/ai_panel_deep_test.dart`、`test/ai_canvas_executor_test.dart` | 30 |
| 透明批注 | `test/annotation_test.dart` | 27 |
| 上下文编辑器与工作区 | `test/context_editors_test.dart`、`flowchart_workspace_test.dart`、`table_mindmap_workspace_test.dart`、`element_editor_test.dart` | 55 |
| 设置（主题 / 背景 / 无障碍 / 热键） | `test/settings_deep_test.dart` | 21 |
| 引导与帮助 | `test/guide_test.dart` | 20 |
| 浮动工具栏与部件 | `test/floating_toolbar_deep_test.dart`、`draggable_overlay_test.dart`、`element_size_dialog_test.dart` | 33 |
| 平台（透明叠加 / 桌面背景） | `test/transparent_overlay_test.dart`、`test/desktop_backdrop_test.dart` | 19 |
| 本地文件与设置持久化 | `test/settings_persistence_test.dart`、`board_file_codec_test.dart`、`board_file_service_test.dart`、`window_close_prompt_test.dart`、`board_file_ui_test.dart` | 47 |
| **合计** | **31 个文件** | **414** |

### 2.15 FFI 集成测试（test/integration/，5 文件 / 21 用例，真实 DLL）

| 文件 | 覆盖 | 用例 |
|---|---|---|
| `test/integration/ffi_init_test.dart` | 版本字符串、重复 init 幂等、非法配置返回 1、白板/页面探针；**缺失动态库路径时 load 抛出 ArgumentError（优雅降级入口）** | 5 |
| `test/integration/ffi_command_test.dart` | 元素 CRUD、命令总线（`command.history` / `command.undo` / `command.redo`）、工具调用、错误信封语义；**回归：undo/redo 走 command 域、`wb_element_batch` 顶层数组** | 6 |
| `test/integration/ffi_memory_test.dart` | UTF-8 中文/emoji 往返、句柄循环创建/销毁、渲染缓存命中与清空、`requireResult` 异常 | 5 |
| `test/integration/ffi_render_test.dart` | 显示列表、3D 创建与渲染、缩略图、缓存与性能统计不变量、已知偏差①②③（记录不修复） | 5 |
| `test/integration/support/ffi_support.dart` | 脚手架：DLL 定位（候选路径 + 4 层父目录探测）、`ffiIntegrationSkipReason`（`WB_REQUIRE_CORE_DLL=1` 强校验）、`loadRealCore`、`FfiBoardHandle` / `createBoardWithPage` | — |

### 2.16 端到端场景（integration_test/，9 场景 / 19 个 testWidgets）

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

### 2.17 Windows 运行器与 wb_core.dll 部署（windows/）

| 功能 | 实现文件 |
|---|---|
| `wb_core.dll` 部署：`add_custom_target(wb_core_dll_deploy ALL)` + **三级源解析**（`-DWB_CORE_DLL` → `$ENV{WB_CORE_DLL}` → 默认 `<repo>/build/windows-x64/bin/$<CONFIG>/wb_core.dll`）；缺失仅 WARNING、绝不失败构建、不删文件 | `windows/CMakeLists.txt`、`windows/copy_wb_core.cmake` |
| 运行器（原生入口与窗口）：`main.cpp`、`flutter_window.*`、`win32_window.*`、`utils.*`、`Runner.rc`、`runner.exe.manifest`、`resource.h`、`resources/app_icon.ico` | `windows/runner/**` |
| Flutter 工具生成物（不手工修改）：`generated_plugins.cmake`、`generated_plugin_registrant.*`、`ephemeral/**` | `windows/flutter/**` |

### 2.18 资源目录（assets/）

| 功能 | 实现文件 |
|---|---|
| 资源目录骨架（仅 `.gitkeep`；已在 `pubspec.yaml` 声明 `assets/images/`、`assets/templates/`） | `assets/images/.gitkeep`、`assets/templates/.gitkeep` |

## 3. 契约与依赖

- **依赖（pubspec.yaml）**：9 个 path 包——`whiteboard_ui`、`whiteboard_ui_kit`、`whiteboard_theme`、`whiteboard_icons`、`whiteboard_core`、`whiteboard_ai`、`whiteboard_api_client`、`whiteboard_mcp_client`、`whiteboard_windows`；第三方——`provider` / `riverpod` / `go_router` / `window_manager` / `hotkey_manager` / `tray_manager` / `screen_retriever`；dev——`flutter_test` / `flutter_lints` / `integration_test`。
- **被依赖**：无（终端应用；`apps/web`（12）、`apps/mobile` 为预留）。
- **关键契约（回归依据）**：
  - **路由路径固化**（`lib/routes.dart` 的 `WbRoutes`）：`/`、`/board/:boardId`、`/board/:boardId/editor`、`/settings`；深链与 E2E 依赖，修改必须同步 `integration_test/**`；
  - **FFI 集成测试约定**（`test/integration/support/ffi_support.dart`）：DLL 候选路径 `../../build/windows-x64/bin/Release/wb_core.dll` / `build/windows-x64/bin/Release/wb_core.dll` + 最多 4 层父目录兜底探测；`WB_REQUIRE_CORE_DLL=1` 时 DLL 缺失直接抛 `StateError`（防整包静默假绿），否则返回跳过原因；断言不依赖具体 `board-N` 编号（并发 isolate 共享引擎状态）；不调用 `wb_shutdown`；
  - **演示模式接缝**：`WbFfiService(candidatePaths: [...])` 注入失败路径 → 应用内降级（`canvas_store` 内存数据源）；E2E 用 `__wb_missing__.dll` 保证确定性；
  - **windows DLL 部署**：`copy_wb_core.cmake` 三级源解析；目标为空或疑似文件路径 → WARNING 跳过；应用可在无原生核心时构建、运行时降级（与 07 的加载器行为配套）；
  - **本地文件契约**：`.wbd` 白板文件（UTF-8 JSON：`format:"whiteboard-board"` / `version:1`；全元素 + 6 类专业 payload；未知字段忽略、缺省取默认、坏结构抛 `FormatException`）与 `%APPDATA%\Whiteboard\settings.json`（主题/外观/AI/协作/最近列表；API 密钥明文）均由 `board_file_codec.dart` / `settings_store.dart` 固化，格式改动需同步 18 号规模基线；
  - **widgets 稳定 Key 属隐性契约**：如 `wb-ctx-quick-create-*`、`page-card-*`、`pages-add`、`theme-card-*` 被 E2E / 深度测试定位，改动前先全局搜索；
  - **测试规模**：全量 **435 用例**（`test/` 414 + `test/integration/` 21），`flutter test`（apps/desktop）实测全绿；E2E 19 用例需 Windows 桌面会话。
- **上游契约**：07（`WbCoreFfi` / 领域服务面）、08（UI Kit/主题/图标）、09（AI 客户端）、10（`whiteboard_windows` 插件）。

## 4. 常用命令

```powershell
# 依赖、分析、全量测试（apps/desktop 目录）
Set-Location apps\desktop; E:\code\flutter-sdk\flutter\bin\flutter.bat pub get; E:\code\flutter-sdk\flutter\bin\flutter.bat analyze
E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub
# 真实 DLL FFI 集成（先构建 C++ 核心，见 17-build-release）
$env:WB_REQUIRE_CORE_DLL='1'; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub test/integration
# 桌面运行与构建（含 wb_core.dll 随构建部署）
E:\code\flutter-sdk\flutter\bin\flutter.bat run -d windows
E:\code\flutter-sdk\flutter\bin\flutter.bat build windows --release
# E2E 场景（需可交互 Windows 桌面会话；单文件示例）
E:\code\flutter-sdk\flutter\bin\flutter.bat test integration_test\app_test.dart -d windows
```

## 5. 变更影响提醒（改本模块时注意）

- 改 `lib/routes.dart` 路由路径 / 参数 → `integration_test/**` 与深链行为；若涉及跨端路径对齐，同步 12-app-web 规划。
- 改 `lib/state/**` 的 ChangeNotifier 契约 → 多组 widget 测试编译/断言受影响，改后必须全量 `flutter test`（435）。
- 改 `lib/services/ffi_service.dart`（候选路径 / 降级判定 / 子服务 getter）→ `test/integration/**` 与 E2E 演示模式链路；FFI 行为回归同时对照 07 模块。
- 改 `windows/copy_wb_core.cmake` / `windows/CMakeLists.txt` 部署逻辑 → 17-build-release 打包链路与运行时分发（`wb_core.dll` 随包）核对。
- 改 widgets 稳定 Key（`wb-ctx-quick-create-*`、`page-card-*` 等）→ E2E 与深度测试大量使用，属"隐性契约"；先全局搜索再改。
- 改 `.wbd` 文件格式 / `settings.json` 形状 / `board_file_*` 服务 API → 同步本文档 2.3、10 号（对话框方法）与 18 号规模基线；`WbBoardOpenRequest` 改名会打穿列表页 / 编辑页 / 路由三处。
- 依赖 07/08/09/10 的公开 API：对方改动会使本模块编译期暴露，用全量 `flutter analyze` + `flutter test` 验证。
- 新增/删除 `lib/**`、`test/**`、`integration_test/**` 文件 → 同步更新本文档 2.x 映射、2.14-2.16 用例数。
