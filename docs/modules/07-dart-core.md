# 07 · dart-core —— Dart FFI 封装包

> 模块路径：`packages/core_dart`
> 维护 agent：`wb-dart-core-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：C++ 引擎的 Dart FFI 封装——动态库加载与 `wb.h` 100 个导出符号的绑定表、统一响应信封解析、各域服务封装（board/element/page/tool/theme/render/background/ai）、数据模型与工具（JSON/二进制编解码、句柄管理）；Web 端 WASM 入口。
- **不负责**：C ABI 契约本体与错误语义（→ [01-core-foundation](01-core-foundation.md)）；应用状态与装配（→ [11-app-desktop](11-app-desktop.md)）；网络客户端（→ [09-dart-client](09-dart-client.md)）；Web 应用装配（→ [12-app-web](12-app-web.md)）。
- **地位**：Flutter 侧访问引擎的唯一通道；上层不得绕过本包直接 `lookupFunction` 符号。
- **注意**：`wb_core.dart`、`wb_core_ffi.dart` 为契约文件（Wave 0），既有导出名不可变更。

## 2. 功能 → 文件映射

### 2.1 FFI 绑定与加载

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 公共入口（聚合导出 bindings/ffi/models/services/utils；WASM 入口有意不导出） | `packages/core_dart/lib/wb_core.dart` | —（纯导出面，被全包测试间接覆盖） |
| 绑定表：100 个 `wb.h` 导出符号、13 种调用形状 Native/Dart typedef、惰性 `lookupFunction` | `packages/core_dart/lib/wb_core_bindings.dart` | `packages/core_dart/test/core_dart_test.dart` |
| `WbCoreFfi` 绑定与加载：`loadWbCore`（overridePath → 平台默认名 `wb_core.dll`/`libwb_core.dylib`/`libwb_core.so`；库缺失时抛 `ArgumentError` 作为优雅降级入口）、`withUtf8`/`takeString` 内存约定、`call0`…`callHandle1Int2` 泛型调用 | `packages/core_dart/lib/wb_core_ffi.dart` | `packages/core_dart/test/core_dart_test.dart`（native smoke）；真实 DLL：`apps/desktop/test/integration/ffi_init_test.dart`（含"缺失动态库路径时 load 抛出 ArgumentError"用例） |
| Web/WASM 入口：`WbCoreWasm`（Emscripten `ccall`、幂等加载、不支持类型抛 `ArgumentError`） | `packages/core_dart/lib/wb_core_wasm.dart` | —（Flutter Web 构建专用，桌面测试不加载） |

### 2.2 响应解析与工具

| 功能 | 实现文件 | 测试 |
|---|---|---|
| JSON 编解码 + `WbResponse` 解析（`ok/result/error` 信封、非信封宽容处理、`requireResult` 抛 `WbCoreException`） | `packages/core_dart/lib/utils/json_codec.dart` | `packages/core_dart/test/core_dart_test.dart`（WbJsonCodec 组 + WbResponse 组） |
| 二进制协议头/整帧编解码（16 字节 little-endian） | `packages/core_dart/lib/utils/binary_codec.dart` | 同上（WbBinaryCodec 组） |
| 句柄管理（`WbHandle` / `WbHandleManager` 注册-取回-注销） | `packages/core_dart/lib/utils/handle_manager.dart` | 同上（WbHandleManager 组） |

### 2.3 领域服务封装（services）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 白板服务：生命周期 + 命令/工具执行入口；**undo/redo 走 command 域（`command.undo`/`command.redo`）** | `packages/core_dart/lib/services/board_service.dart` | `core_dart_test.dart`（native smoke）；跨语言回归：`apps/desktop/test/integration/ffi_command_test.dart` |
| 页面服务：列表 / 增删改 / 排序 / 背景 / 锁定隐藏 | `packages/core_dart/lib/services/page_service.dart` | `core_dart_test.dart`（native smoke）；`ffi_command_test.dart` |
| 元素服务：CRUD + 批量；**`batch` 发送顶层数组（引擎侧 `args.ops.is_array()` 校验）** | `packages/core_dart/lib/services/element_service.dart` | `ffi_command_test.dart`（batch 顶层数组回归） |
| 工具服务：工具注册表（list/get/execute）+ 工具栏上下文 | `packages/core_dart/lib/services/tool_service.dart` | `core_dart_test.dart`（native smoke） |
| 主题服务：当前 / 列表 / 加载（**`wb_theme_load` 入参即"主题本身"**：内置传 `"dark-night"` JSON 串，自定义传完整对象，不传 `{id:...}` 包裹） | `packages/core_dart/lib/services/theme_service.dart` | 同上（9 内置主题断言） |
| 渲染服务：显示列表 / 脏区 / 3D / 缩略图 / 缓存与性能统计 | `packages/core_dart/lib/services/render_service.dart` | `apps/desktop/test/integration/ffi_render_test.dart` |
| 背景服务：11 个内置预设（`builtinPresets`）→ 经 `page` 域写入 | `packages/core_dart/lib/services/background_service.dart` | `core_dart_test.dart`（background presets 组） |
| AI 服务：会话生命周期 / 消息 / 语音 / 工具调用确认（ai 域） | `packages/core_dart/lib/services/ai_service.dart` | —（本包测试未直接覆盖） |

> 说明：sync 域（`wb_sync_*`）与权限/审计（`wb_permission_check`、`wb_audit_*`）符号已在本包绑定表（`wb_core_bindings.dart`）中，但本包暂无对应独立服务封装；同步的 Flutter 侧封装见 11 的 `apps/desktop/lib/services/sync_service.dart`（骨架）。

### 2.4 数据模型（models）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 白板 / 页面 / 元素（`raw` 字段透传类型专属数据） | `packages/core_dart/lib/models/{board,page,element}.dart` | `core_dart_test.dart`（models 组） |
| 连接线 / 图层 / 背景 | `packages/core_dart/lib/models/{connector,layer,background}.dart` | `core_dart_test.dart`（背景见 presets 组；connector/layer 无直接断言） |
| 主题规格（`WbThemeSpec`，`colorOf`） | `packages/core_dart/lib/models/theme.dart` | `core_dart_test.dart`（models 组） |
| 工具描述（`WbTool` / `WbToolSchema`） | `packages/core_dart/lib/models/tool.dart` | `core_dart_test.dart`（models 组） |

### 2.5 测试构成（24 用例）

| 测试文件 | 用例构成 |
|---|---|
| `packages/core_dart/test/core_dart_test.dart`（24） | WbJsonCodec 5 + WbResponse 5 + WbBinaryCodec 4 + WbHandleManager 2 + models 5 + background presets 2 + native smoke 1 |

## 3. 契约与依赖

- **对外契约（只读）**：`core/include/wb/wb.h`（100 个导出符号，绑定表为其手写镜像）；`core/tools/schema/*.json`（命令/元素 JSON 形状）。
- **被依赖**：11 app-desktop（经 `whiteboard_core` path 依赖，FFI 服务的唯一来源）；12 apps/web（`wb_core_wasm.dart`，显式 import，不经 `wb_core.dart`）。
- **依赖**：`ffi` ^2.1.0；dev：`ffigen` ^13.0.0（`wb.h` 变更后重新生成/校对绑定表，保持既有 typedef 名稳定）。
- **已知契约事实（回归依据）**：
  - undo/redo 走 `command.undo` / `command.redo`（command 域，经 `WbBoardService.undo/redo`），由 `apps/desktop/test/integration/ffi_command_test.dart` 回归守卫；
  - `wb_element_batch` 的 ops 参数为**顶层数组**（引擎侧 `args.ops.is_array()` 校验），`WbElementService.batch` 直接 `jsonEncode(ops)`，由 `ffi_command_test.dart` 回归守卫；
  - `WbCoreFfi.load(overridePath:)` 库缺失时抛 `ArgumentError`（`DynamicLibrary.open` 语义）——上层以此为优雅降级判定入口（11 的 `WbFfiService` 捕获后进入演示模式）；
  - 本包测试 **24 个用例**（构成见 2.5）；native smoke 用例在 `wb_core.dll` 不存在时自动 skip。

## 4. 常用命令

```powershell
Set-Location packages\core_dart; E:\code\flutter-sdk\flutter\bin\flutter.bat pub get
E:\code\flutter-sdk\flutter\bin\flutter.bat analyze
E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub

# 真实引擎冒烟前置（在仓库根构建 C++ 核心）
cmake --preset windows-x64; cmake --build build/windows-x64 --config Release

# 跨语言回归（07 ↔ 11，real DLL 强校验）
Set-Location apps\desktop; $env:WB_REQUIRE_CORE_DLL='1'; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub test/integration
```

## 5. 变更影响提醒（改本模块时注意）

- 改绑定表/加载逻辑 → 影响 **11 app-desktop**（`WbFfiService` 候选路径与演示模式降级）与 **12 app-web**（WASM 入口），需跑 `WB_REQUIRE_CORE_DLL=1` 的 FFI 集成。
- 改 `WbResponse`/`WbCoreException` 语义 → 全部域服务与 11 状态层的错误处理路径。
- `wb.h`（01 模块）变更 → 本包绑定表与 typedef 必须同步更新，否则跨语言回归失败。
- 改模型 `fromJson` 宽容行为 → 11 的 UI 断言与集成测试 fixture 可能受影响。
- 新增/删除 `lib/**` 文件 → 同步更新本文档 2.x 映射表，并通过 `wb_core.dart` 更新导出面（仅允许加名，不允许改名）。
