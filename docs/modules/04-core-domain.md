# 04 · core-domain —— C++ 领域模块

> 模块路径：`core/include/wb/{flowchart, mindmap, table, function, document, annotation}`（当前为空占位）、`core/src/{flowchart, mindmap, table, function, document, annotation}`、`core/tests/unit/{flowchart, mindmap, table, function, document, annotation}`
> 维护 agent：`wb-core-domain-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：六类领域元素的内部数据模型与算法——流程图（节点/连线/分层自动布局/泳道/分支标注）、思维导图（树与放射布局/大纲导出）、表格（A1 地址/公式引擎/排序筛选）、函数图形（表达式解析/采样/数学分析/导出）、文档导入（PDF 页表 stub/PPT 外部打开标记）、透明批注（两态机/笔迹栈/退出动作）。
- **不负责**：通用元素 CRUD、z-order 与页面管理（→ [02-core-model](02-core-model.md)，领域元素复用 `SceneStore` 元素列表）；渲染显示列表与图层（→ [03-core-render](03-core-render.md)）；CRDT/同步（→ [05-core-collab](05-core-collab.md)）；MCP 工具桥接（→ [06-core-ai](06-core-ai.md)）；工具注册与 FFI 实现（→ [01-core-foundation](01-core-foundation.md)）。
- **地位**：领域算法层；元素以 `element.type` + `data` 区块承载领域数据（如 `data.nodes`、`data.cells`、`data.root`、`data.expressions`、`data.strokes`），因此天然参与 02 的 z-order/命中测试与 03 的图层映射。

## 2. 功能 → 文件映射

| 功能 | 实现文件 | 测试 |
|---|---|---|
| flowchart 域（`create`/`addNode`/`removeNode`/`connect`/`lockNode`/`autoLayout`/`toSwimlane`/`labelBranches`/`list`；分层布局间距 80/60、polyline 路由、泳道分组、`是/否` 分支标注） | `core/src/flowchart/flowchart.cpp` | `core/tests/unit/flowchart/flowchart_test.cpp` |
| mindmap 域（`create`/`addNode`/`removeNode`/`setLayout`/`setStyle`/`layout`/`export`/`list`；树/放射布局、节点框宽 = 码点数×8+24（最小 48）、高 32、大纲导出） | `core/src/mindmap/mindmap.cpp` | `core/tests/unit/mindmap/mindmap_test.cpp` |
| table 域（`create`/`setCell`/`getCell`/`setFormula`/`sort`/`filter`/`setStyle`/`list`；A1 地址、公式引擎 `+ - * / ^`、范围 `A1:B2`、`SUM/AVG/MAX/…`、循环引用 `#CYCLE!`） | `core/src/table/table.cpp` | `core/tests/unit/table/table_test.cpp` |
| function 域（`create`/`setStyle`/`add`/`remove`/`analyze`/`export`/`list`；递归下降表达式解析（trig/指数/隐式乘法/常数 pi,e）、零点/极值/导数/积分/面积/对称性、csv/json 采样导出） | `core/src/function/function.cpp` | `core/tests/unit/function/function_test.cpp` |
| document 域（`import`/`info`/`setPage`/`list`；headless PDF 后端 stub：页表 A4 595×842pt、PPT 标记 `openWithSystem`） | `core/src/document/document.cpp` | `core/tests/unit/document/document_test.cpp` |
| annotation 域（`enterTransparent`/`exitTransparent`/`setPenetrate`/`addStroke`/`undo`/`redo`/`clear`/`saveToBoard`/`state`；穿透态/批注态两态机、退出动作 save/discard/keep、激光笔不落盘） | `core/src/annotation/annotation.cpp` | `core/tests/unit/annotation/annotation_test.cpp` |

## 3. 契约与依赖

- **对外契约（只读）**：`core/include/wb/wb.h` 的 Function 段（`wb_function_create`/`set_style`/`add`/`analyze`/`export`）、Flowchart 段（`wb_flowchart_create`/`auto_layout`/`to_swimlane`/`label_branches`）、Annotation 段（`wb_annotate_enter_transparent`/`exit_transparent`/`set_penetrate`）。mindmap/table/document **无直接 FFI 函数**，经工具调用（`mindmap.*`/`table.*`/`document.*`，注册于 `core/src/tool/tool_registry.cpp`）与域调用（`invokeDomain`）进入。
- **被依赖**：01 工具注册表已注册本模块全部工具（含 MCP/AI 使用的 snake_case op 别名，如 `add_node`/`set_cell`）；07 `packages/core_dart` 封装 `wb_function_*`/`wb_flowchart_*`（`wb_core_bindings.dart`）；`core/tests/integration/` 的 `test_flowchart_render.cpp`、`test_function_render.cpp` 断言领域数据 → 渲染显示列表链路；06 AI/MCP 经工具注册表调用本模块（AI 工具调用面）。
- **依赖**：01 契约基础层（`wb/ffi/domain.h`、`wb/platform/platform.h`）；02 数据模型（`core/src/model/scene_store.h`：六个域均引用）；third_party（nlohmann/json）。
- **已知契约事实（回归依据）**：流程图节点类型集合（start/end/process/decision/inputOutput/document/database/manualOperation/connector/annotation/swimlane/custom，大小写不敏感）；思维导图/表格/文档/批注的 op 同时接受 camelCase 与 snake_case 别名；表格公式支持 `SUM AVG/AVERAGE MIN MAX COUNT COUNTA IF ROUND ABS SQRT`，循环引用呈现 `#CYCLE!`，每次变更全表重算；批注退出 `save` 会把批注层并入白板（frame 或 layer）。

## 4. 常用命令

```powershell
# 构建（改动本模块后必须全量构建）
cmake --preset windows-x64; cmake --build build/windows-x64 --config Release

# 全量单测
ctest --test-dir build/windows-x64 -C Release --output-on-failure

# 只跑本模块相关用例（按名称过滤）
ctest --test-dir build/windows-x64 -C Release -R "flowchart|mindmap|table|function|document|annotation" --output-on-failure
```

## 5. 变更影响提醒（改本模块时注意）

- 修改元素 `data` 区块结构（nodes/cells/root/expressions/strokes）→ 02 element patch 的 `data` 一级深合并语义、03 图层映射与 `core/tests/integration/test_*_render.cpp` 的 dirtyRect 断言联动。
- 修改表格公式引擎/函数注册表 → `core/tests/unit/table/` 强断言 + 06 AI 表格工具（`table.setFormula`）行为；新增函数须同步文档与用例。
- 修改流程图自动布局常数（间距 80/60）或泳道规则 → `test_flowchart_render.cpp` 坐标单调性断言。
- 修改函数表达式解析（precedence/隐式乘法）→ `core/tests/unit/function/` 与 `test_function_render.cpp` 采样点断言。
- 修改批注退出动作语义（save/discard/keep）→ 与《透明批注模式技术方案》§5.4 对话框联动；`saveToBoard` 产物（frame/layer）经 02 element 域写入。
- PDF 光栅化从 stub 转真实实现时 → 协作点为 01 platform 层（PDFium/MuPDF），届时同步 `document.cpp` 头注释与本文档。
