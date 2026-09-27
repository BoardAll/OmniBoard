# 01 · core-foundation —— C++ 契约基础层

> 模块路径：`core/include/wb/{wb.h, base, ffi, serialization, platform}`、`core/src/{base, ffi, serialization, platform, command, tool, facade}`、`core/tools/schema`
> 维护 agent：`wb-core-foundation-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：C ABI FFI 契约（`wb.h`）与其实现入口、域注册机制；基础类型/错误/日志/内存/线程/字符串工具；序列化编解码；平台抽象；命令总线与工具注册表（引擎对外的两个核心扩展点）；门面层；JSON 数据契约（schema）。
- **不负责**：具体元素与页面数据（→ [02-core-model](02-core-model.md)）、渲染（→ [03-core-render](03-core-render.md)）、AI/MCP（→ [06-core-ai](06-core-ai.md)）。
- **地位**：最底层，所有其他 C++ 模块都依赖本层；FFI 边界行为（UTF-8 JSON、`wb_free` 释放约定）由本层定义。

## 2. 功能 → 文件映射

### 2.1 契约与 FFI

| 功能 | 实现文件 | 测试 |
|---|---|---|
| C ABI 全部导出函数（`wb_init`/`wb_free`/各域入口） | `core/include/wb/wb.h`（契约，只读）、`core/src/ffi/ffi_api.cpp` | `core/tests/unit/ffi/`；跨语言回归：`apps/desktop/test/integration/ffi_*_test.dart` |
| 域注册表（域 → 处理器分发，`command.undo` 等域名的路由） | `core/include/wb/ffi/domain.h`、`core/src/ffi/domain_registry.cpp` | `core/tests/unit/ffi/` |

### 2.2 基础工具（base）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 基础类型（Id/尺寸/枚举等） | `core/include/wb/base/types.h` | `core/tests/unit/base/` |
| 二维点/矩形 | `core/include/wb/base/{point,rect}.h` | `core/tests/unit/base/` |
| 颜色 | `core/include/wb/base/color.h`、`core/src/base/color.cpp` | `core/tests/unit/base/` |
| 变换矩阵 | `core/include/wb/base/transform.h`、`core/src/base/transform.cpp` | `core/tests/unit/base/` |
| 错误与结果类型（`wb::Result<T>`） | `core/include/wb/base/error.h` | `core/tests/unit/base/` |
| 日志（含 FFI 日志 sink） | `core/include/wb/base/log.h`、`core/src/base/log.cpp` | `core/tests/unit/base/` |
| 内存工具 | `core/include/wb/base/memory.h`、`core/src/base/memory.cpp` | `core/tests/unit/base/` |
| 对象池 | `core/include/wb/base/object_pool.h` | `core/tests/unit/base/` |
| 线程池 | `core/include/wb/base/thread_pool.h`、`core/src/base/thread_pool.cpp` | `core/tests/unit/base/` |
| 字符串工具（UTF-8 处理等） | `core/include/wb/base/string_utils.h`、`core/src/base/string_utils.cpp` | `core/tests/unit/base/` |

### 2.3 序列化 / 平台 / 扩展点 / 门面

| 功能 | 实现文件 | 测试 |
|---|---|---|
| JSON 序列化编解码（codec） | `core/include/wb/serialization/codec.h`、`core/src/serialization/codec.cpp` | `core/tests/unit/serialization/` |
| 平台抽象（系统信息/路径等） | `core/include/wb/platform/platform.h`、`core/src/platform/platform.cpp` | `core/tests/unit/platform/` |
| 命令总线（执行/撤销/重做/历史） | `core/src/command/command_bus.cpp` | `core/tests/unit/command/` |
| 工具注册表（`tool.list`/`tool.invoke` 与各域工具的注册） | `core/src/tool/tool_registry.cpp` | `core/tests/unit/tool/` |
| 门面（对 FFI 的高层聚合接口） | `core/src/facade/facade.h`、`core/src/facade/facade.cpp` | `core/tests/unit/facade/` |
| JSON 数据契约（命令/元素/主题/工具） | `core/tools/schema/{command,element,theme,tool}.schema.json`（契约，只读） | —（被各模块测试间接校验） |
| 测试公共脚手架 | `core/tests/unit/support/` | — |

## 3. 契约与依赖

- **对外契约（只读）**：`core/include/wb/wb.h`（所有导出函数签名）、`core/include/wb/base/*.h`（基础类型）、`core/tools/schema/*.json`。
- **被依赖**：01←02/03/04/05/06（全部 C++ 模块）；FFI 行为被 07 `packages/core_dart`（及其上层 11 桌面应用）依赖。
- **依赖**：third_party（nlohmann/json、spdlog、fmt、glm）。
- **已知契约事实（回归依据）**：命令总线域名为 `command.undo`/`command.redo`；FFI 边界输入输出均为 UTF-8 JSON；对象/句柄生命周期由 `wb_free` 释放；引擎启动日志 `[wb] core initialized v1.0.0`。

## 4. 常用命令

```powershell
# 构建（改动本模块后必须全量构建）
cmake --preset windows-x64; cmake --build build/windows-x64 --config Release

# 本层单测（全量 ctest 中筛选本层标签）
ctest --test-dir build/windows-x64 -C Release --output-on-failure

# FFI 跨语言回归（优先：真实 DLL）
Set-Location apps\desktop; $env:WB_REQUIRE_CORE_DLL='1'
E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub test/integration
```

## 5. 变更影响提醒（改本模块时注意）

- 修改 `wb.h` 或 FFI 错误语义 → 影响 **07 dart-core**（封装签名）与 **11 app-desktop**（集成测试 `ffi_*_test.dart` 按真实引擎断言），需同步跑 FFI 集成测试。
- 修改 `base/*.h` 公共头 → 所有 C++ 模块重编译；`error.h`/`types.h` 语义变化需全量 ctest。
- 修改命令总线 → 影响 02/03/04 中所有注册命令的撤销行为。
- 修改 schema JSON → 对应 **04/03** 模块测试的序列化 fixtures 可能失效。
- 本层是"契约冻结层"：新增函数优先在模块内实现头文件，确需改契约须评估全仓影响后再动。
