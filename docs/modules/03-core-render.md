# 03 · core-render —— C++ 渲染与界面元数据

> 模块路径：`core/include/wb/{render, render2d, render3d, theme, background, radial, toolbar}`（当前为空占位；`sidebar` 无对应 include 目录）、`core/src/{render, render2d, render3d, theme, background, radial, toolbar, sidebar}`、`core/tests/unit/{render, render2d, render3d, theme, background, radial, toolbar, sidebar}`
> 维护 agent：`wb-core-render-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：渲染调度（显示列表生成与图层映射、脏矩形、缩略图缓存、帧性能统计）；2D 绘制元数据；3D 离屏渲染模型（CPU 网格、表面拾取、OBJ/GLTF 导出）；主题（9 内置 tokens）；背景预设（11 项）；齿轮圆盘元数据（布局/命中/交互状态）；工具栏（默认/上下文/调用转发）；侧栏状态（宽度/折叠）。
- **不负责**：元素与页面数据本身（→ [02-core-model](02-core-model.md)）、领域元素的内部数据模型（→ [04-core-domain](04-core-domain.md)）、FFI 导出实现与工具注册表（→ [01-core-foundation](01-core-foundation.md)）、真实 GPU/PDF 光栅化绘制（bgfx 平台层，后续 wave）。
- **地位**：数据驱动的渲染元数据层：本模块不产生像素，而是把 02/04 的元素数据编译为显示列表/渲染作业/界面状态供平台层（bgfx、前端）消费。

## 2. 功能 → 文件映射

| 功能 | 实现文件 | 测试 |
|---|---|---|
| render 域（`getDisplayList`/`thumbnail`/`cacheStats`/`cacheClear`/`perfStats`/`recordFrame`；图层映射、隐藏跳过、dirtyRect 并集、缩略图 LRU 缓存） | `core/src/render/render.cpp` | `core/tests/unit/render/render_test.cpp` |
| render2d 域（`create`/`setStyle`/`annotate`/`list`；type 固定 `render2d`，复用元素 z-order） | `core/src/render2d/render2d.cpp` | `core/tests/unit/render2d/render2d_test.cpp` |
| render3d 域（`create`/`render`/`pickSurface`/`setFaceColor`/`setMaterial`/`setLight`/`transform`/`export`/`list`；CPU 三角网 + Möller–Trumbore 射线拾取） | `core/src/render3d/render3d.cpp` | `core/tests/unit/render3d/render3d_test.cpp` |
| theme 域（`list`/`current`/`load`/`get`；9 内置主题、默认 `clean-professional`、完整 token 展开） | `core/src/theme/theme.cpp` | `core/tests/unit/theme/theme_test.cpp` |
| background 域（`list`/`set`/`get`；11 预设，与 page.setBackground 共用槽位） | `core/src/background/background.cpp` | `core/tests/unit/background/background_test.cpp` |
| radial 齿轮圆盘（`layout`/`hitTest`/`stateCreate`/`stateGet`/`stateUpdate`/`rememberTool`/`clearRecent`；直径 240/收起 56，内环 6 工具 60°、外环 8 组 45°） | `core/src/radial/radial.cpp` | `core/tests/unit/radial/radial_test.cpp` |
| toolbar 域（`list`/`context`/`invoke`；按选中元素解析上下文工具栏，`invoke` 转发 tool 域执行器） | `core/src/toolbar/toolbar.cpp` | `core/tests/unit/toolbar/toolbar_test.cpp` |
| sidebar 域（`toggle`/`setWidth`/`get`/`reset`；展开默认 240、收起 56、拖拽范围 200–320） | `core/src/sidebar/sidebar.cpp` | `core/tests/unit/sidebar/sidebar_test.cpp` |

## 3. 契约与依赖

- **对外契约（只读）**：`core/include/wb/wb.h` 的 Render 段（`wb_get_display_list`/`wb_render_display_list`/`wb_render_dirty`/`wb_render_3d`/`wb_render_thumbnail`/`wb_render_cache_stats`/`wb_render_cache_clear`/`wb_render_perf_stats`）、Toolbar 段、Radial 段、3D 段（`wb_3d_*`）、2D 段（`wb_render_2d_*`）、Sidebar 段、Theme 段。
- **被依赖**：01 工具注册表已注册 `render.*`/`3d.*`/`theme.*`/`background.*`/`radial.*`/`toolbar.*`/`sidebar.*` 工具（`core/src/tool/tool_registry.cpp`）；07 `packages/core_dart` 封装 `wb_render_*`/`wb_theme_*`/`wb_radial_*`/`wb_toolbar_*`/`wb_sidebar_*`（`lib/services/render_service.dart`、`theme_service.dart`、`background_service.dart`）；`core/tests/integration/` 多个用例断言 display list 与 dirtyRect 对齐（如 `test_3d_render.cpp`、`test_flowchart_render.cpp`、`test_function_render.cpp`）。
- **依赖**：01 契约基础层（`wb/ffi/domain.h`、`wb/platform/platform.h`）；02 数据模型（`core/src/model/scene_store.h`、`geom_math.h`：render/render2d/render3d/toolbar/background 引用）；third_party（nlohmann/json）。
- **已知契约事实（回归依据）**：图层映射 `render3d→Render3D`、`render2d→Render2D`、`function→Function`、`annotation→Annotation`、`document→Document`、其余 `Dynamic`；隐藏元素不进显示列表；dirtyRect 为旋转感知 AABB 并集；缩略图缓存 256 条（最旧淘汰）；主题 token 含 `radius.s|m|l = 4|8|12` 与 `opacity` radial 0.9 / toolbar 0.95 / panel 1.0；背景 11 预设；圆盘角度以顶部为 0° 顺时针。

## 4. 常用命令

```powershell
# 构建（改动本模块后必须全量构建）
cmake --preset windows-x64; cmake --build build/windows-x64 --config Release

# 全量单测
ctest --test-dir build/windows-x64 -C Release --output-on-failure

# 只跑本模块相关用例（按名称过滤）
ctest --test-dir build/windows-x64 -C Release -R "render|theme|background|radial|toolbar|sidebar" --output-on-failure
```

## 5. 变更影响提醒（改本模块时注意）

- 修改图层映射或 dirtyRect 算法 → 影响 `core/tests/integration/`（3D/流程图/函数/文档等渲染链路断言）与 02 geom_math 几何对齐，需联动回归。
- 修改主题 token 结构/内置主题 id → 07 `theme_service.dart` 与 11 桌面端主题切换用例可能失效；背景预设变化同步 02 `wb_page_set_background` 语义（共用 `PageRec.background` 槽位）。
- 修改圆盘几何常量（240/56/60°/45°）→ 与《齿轮圆盘交互详细设计》联动，前端圆盘交互（11）需回归。
- 修改 toolbar `invoke` 转发链路（tool 域 `execute`）→ 影响所有工具栏动作与 06 的 MCP 工具桥接。
- 修改 `render3d` 的面 id 顺序/拾取算法 → `core/tests/unit/render3d/` 与 `core/tests/integration/test_3d_render.cpp` 强断言（box 面 id、世界坐标顶点）。

### 5.1 已知问题（Wave 1 遗留缺陷，修复/使用前优先核对）

1. `wb_render_display_list`（契约 `core/include/wb/wb.h:68`，实现 `core/src/ffi/ffi_api.cpp:164`）转发的 op 是 `renderDisplayList`，但 render 域**不存在**该 op（域内仅 `getDisplayList`/`thumbnail`/`cacheStats`/`cacheClear`/`perfStats`/`recordFrame`，见 `core/src/render/render.cpp:116-121`）→ 调用返回 `NotFound: unknown render op: renderDisplayList`。
2. `wb_render_dirty`（契约 `core/include/wb/wb.h:69`，实现 `core/src/ffi/ffi_api.cpp:171`）转发的 op 是 `renderDirty`，同样不存在于 render 域 → 调用失败；脏矩形目前由 `getDisplayList` 响应内联返回。
3. `wb_get_display_list(uint64_t handle, int layer)`（契约 `core/include/wb/wb.h:67`，实现 `core/src/ffi/ffi_api.cpp:157`）把 `handle` 传给 render 域，但 `render.getDisplayList` 按 `pageId` 查找（`core/src/render/render.cpp` 头部契约；`core/tests/unit/render/render_test.cpp` 全部用 `pageId`）→ 传句柄无法命中页面；**可用路径：工具 `render.getDisplayList`**（参数 `{pageId, layer?}`，注册见 `core/src/tool/tool_registry.cpp:61`）。
4. 上述 3 个缺陷已被 07 侧直接封装（`packages/core_dart/lib/services/render_service.dart` 的 `displayList`/`renderDisplayList`/`renderDirty`）→ 修复前这些 SDK 方法不可用；改动 `ffi_api.cpp` 属 01 职责，本模块只提供域实现与测试证据。
