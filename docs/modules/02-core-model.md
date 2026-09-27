# 02 · core-model —— C++ 数据模型层

> 模块路径：`core/include/wb/{model, element, page, geometry, layout}`（当前为空占位）、`core/src/{model, element, page, geometry, layout}`、`core/tests/unit/{model, element, page, geometry, layout}`
> 维护 agent：`wb-core-model-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：白板进程内数据模型（board/page/element 记录、z-order、锁定/隐藏语义、ID 生成）；`board`/`page`/`element`/`geometry`/`layout` 五个 FFI 域的实现（element 是全引擎最高频 FFI 入口）；几何计算（命中测试、旋转感知包围盒）；布局引擎（对齐/分布/吸附）；模型私有几何工具（schema 默认值读取）。
- **不负责**：FFI 导出签名与域注册机制（→ [01-core-foundation](01-core-foundation.md)）、渲染显示列表与主题背景（→ [03-core-render](03-core-render.md)）、领域元素内部模型（→ [04-core-domain](04-core-domain.md)）、CRDT/同步/权限/审计（→ [05-core-collab](05-core-collab.md)）、AI/MCP（→ [06-core-ai](06-core-ai.md)）。
- **地位**：数据模型层；03/04 模块通过 `core/src/model/scene_store.h`（进程内共享状态）与域调用读写元素数据；模型状态的所有写入都必须经由本层域处理（统一持 `SceneStore::mutex()`）。
- **现状说明**：`core/include/wb/{model, element, page, geometry, layout}` 目录目前为**空占位**，本模块实现全部在 `core/src/`（`scene_store.h`、`geom_math.h` 为 core 内部跨域复用私有头，不属于公共 include 契约面）。

## 2. 功能 → 文件映射

### 2.1 模型存储与几何工具

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 进程内场景状态（board/page/element 记录、句柄与 ID 生成、摘要输出、全局锁约定） | `core/src/model/scene_store.h`、`core/src/model/scene_store.cpp` | 经 `core/tests/unit/{model,page,element,geometry,layout}/` 各域测试间接覆盖 |
| 几何数学私有工具（度→弧度、schema 默认值读取、元素矩形/旋转读取） | `core/src/model/geom_math.h` | 经 `core/tests/unit/{geometry,layout,render}/` 间接覆盖 |

### 2.2 域实现

| 功能 | 实现文件 | 测试 |
|---|---|---|
| board 域（`create`/`destroy`/`get`；默认页"页面 1"；FFI：`wb_create_board`/`wb_destroy_board`/`wb_board_get`） | `core/src/model/board_registry.cpp` | `core/tests/unit/model/board_test.cpp` |
| page 域（`list`/`create`/`duplicate`/`delete`/`move`/`rename`/`setBackground`/`lock`/`hide`，含撤销逆操作；FFI：`wb_page_list`…`wb_page_hide`） | `core/src/page/page_manager.cpp` | `core/tests/unit/page/page_manager_test.cpp` |
| element 域（`create`/`update`/`delete`/`list`/`batch`；patch 一级深合并、连线级联删除、批量原子回滚；FFI：`wb_element_create`…`wb_element_batch`） | `core/src/element/element_manager.cpp` | `core/tests/unit/element/element_test.cpp` |
| geometry 域（`hitTest`/`bounds`；旋转感知 AABB、connector 线段命中） | `core/src/geometry/geometry.cpp` | `core/tests/unit/geometry/geometry_test.cpp` |
| layout 域（`align`/`distribute`/`snap`；对齐/等距/吸附辅助线） | `core/src/layout/layout.cpp` | `core/tests/unit/layout/layout_test.cpp` |

## 3. 契约与依赖

- **对外契约（只读）**：`core/include/wb/wb.h` 的 Board/Page/Element 段（`wb_create_board` … `wb_element_batch`）；JSON 数据契约 `core/tools/schema/element.schema.json`（01 维护）。
- **被依赖**：03/04 渲染与领域模块直接 `#include "../model/scene_store.h"`（render、render2d、render3d、toolbar、background、function、flowchart、table、mindmap、document 等 14 处）；07 `packages/core_dart` 封装 `wb_element_*`/`wb_page_*`/`wb_board_*`（如 `lib/services/element_service.dart`、`page_service.dart`）；11 桌面端经 FFI 消费。
- **依赖**：01 契约基础层（`wb/ffi/domain.h` 注册宏、`wb/platform/platform.h` 时间函数）；third_party（nlohmann/json）；测试脚手架 `core/tests/unit/support/scene_probe.h`（01 维护）。
- **已知契约事实（回归依据）**：元素 z-order 即 `page->elements` 数组序（增删后重编号 `zIndex`）；element patch 不覆盖 `id`/`pageId`/`createdAt`，`style`/`data` 仅一级深合并；`element.delete` 级联删除指向该元素的 connector 并返回 `deletedConnectorIds`；`element.batch` 任一步失败整页回滚（`Conflict` + `failedIndex`/`failedOp`/`cause`）；FFI `wb_element_batch(pageId, opsJson)` 的 `opsJson` 必须是**顶层 JSON 数组**（引擎侧 `args.ops.is_array()` 校验）；锁定页写入返回 `Conflict`；删除最后一个页面返回 `Conflict`。

## 4. 常用命令

```powershell
# 构建（改动本模块后必须全量构建）
cmake --preset windows-x64; cmake --build build/windows-x64 --config Release

# 全量单测
ctest --test-dir build/windows-x64 -C Release --output-on-failure

# 只跑本模块相关用例（按名称过滤）
ctest --test-dir build/windows-x64 -C Release -R "board|page|element|geometry|layout" --output-on-failure
```

## 5. 变更影响提醒（改本模块时注意）

- 修改 `core/src/model/scene_store.h`（结构或锁约定）→ 03/04 全部引用方重编译并联动验证；锁约定："域处理期间持有 `SceneStore::mutex()`，持有期间禁止 `invokeDomain()`"。
- 修改 `core/src/model/geom_math.h` 的默认值/几何读取 → 02 geometry/layout、03 render（dirtyRect 对齐）共同受影响，建议跑 `core/tests/integration/` 跨模块用例。
- 修改 element/page op 语义或响应结构 → 07 `packages/core_dart`（`element_service.dart`/`page_service.dart` 等已按当前结构解析）与 11 桌面端集成测试（`ffi_*_test.dart`）。
- element 是全引擎最高频 FFI 入口：改动须保持原子性与顺序语义，并同步更新 `core/tests/unit/element/element_test.cpp`。
- `wb_page_set_background` 与 03 background 域共用 `PageRec` 的同一 `background` 槽位：任一侧语义变化都要联动对方模块测试。
- `core/include/wb/{model,...}` 为空占位：新增实现请放 `core/src/<模块>/`（私有头）；确需扩展公共契约面时先按 01 的"契约冻结层"流程评估全仓影响。
