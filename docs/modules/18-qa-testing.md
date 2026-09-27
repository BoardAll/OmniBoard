# 18 · qa-testing —— 测试与质量体系

> 模块路径：`tests/{e2e, fixture, perf}`、`core/tests`（unit / integration / perf）、`core/benchmarks`、FFI 强校验机制与各包/服务的测试规模基线
> 维护 agent：`wb-qa-testing-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：全仓测试分层体系（C++ 单元/集成/基准 → Flutter 单测/widget/集成 → e2e → 四个服务端测试层）的组织与规模基线；`core/tests` 的用例组织、ctest 注册链与运行链路；`core/benchmarks` 基准程序；`tests/e2e` 端到端用例（8 个）与 `test/` 转发结构；`tests/fixture` 标准数据集（10 子目录 / 33 JSON + 1 最小 PDF）；`tests/perf` 性能测试流水线；FFI 强校验机制（`WB_REQUIRE_CORE_DLL`：DLL 缺失时普通环境优雅跳过、CI 硬失败）。
- **不负责**：功能实现与其单测用例内容（C++ 域用例、Dart 用例、服务用例随功能演进，由 [01-core-foundation](01-core-foundation.md)～[16-svc-convert](16-svc-convert.md) 各自维护）；构建产物与 CI 工作流本体（→ [17-build-release](17-build-release.md)，本模块只提供其"测试侧契约"）。
- **地位**：全仓质量守门（与 17 并列的工程化支撑）；§2.5 规模基线与 §2.6 强校验语义是全仓回归判据。

## 2. 功能 → 文件映射

### 2.1 C++ 测试与基准（core/tests、core/benchmarks）

| 功能 | 实现文件 | 测试/验证方式 |
|---|---|---|
| C++ 单元测试：33 个子目录 / 34 个测试文件，覆盖 01–06 全部域（用例内容随各域演进） | `core/tests/unit/<域>/`（32 个用例目录，`base/`、`ffi/` 各 2 文件；公共脚手架 `unit/support/scene_probe.h`） | ctest 逐用例注册（unit 175 个用例；实跑全过） |
| C++ 集成测试：跨模块协作 7 文件（3D 渲染 / 命令模型 / CRDT 同步 / 流程图渲染 / 函数渲染 / 页面元素 / 权限审计） | `core/tests/integration/test_{3d_render,command_model,crdt_sync,flowchart_render,function_render,page_element,permission_audit}.cpp`、`integration/support/test_probe.h` | ctest（integration 24 个用例；实跑全过） |
| 测试注册链：GLOB 收集 `unit/*.cpp` + `integration/*.cpp`，`catch_discover_tests` 逐用例注册（新增文件自动纳入） | `core/tests/CMakeLists.txt` | `ctest -N` 实测注册 199；全量实跑 199/199 通过 |
| 性能基准：5 个程序 6 个用例（元素吞吐 / 序列化 / 页面切换 / CRDT 增量写 + 同步链路 / 流程图与函数） | `core/benchmarks/bench_{elements,serialization,page_switch,crdt_sync,flowchart_function}.cpp` | 产物 `build/windows-x64/bin/Release/wb_benchmarks.exe`（实测存在）；由 `tests/perf` 流水线调用 |
| 基准工程：GLOB + `WB_BUILD_BENCHMARKS` 开关（默认不构建）；无源时生成占位程序 | `core/benchmarks/CMakeLists.txt`、`benchmarks/support/bench_util.h` | 开关打开后构建；产物路径被 `run_perf.ps1` 探测 |
| 性能测试目录（预留）：空目录，未纳入构建；C++ 性能用例实际归 `core/benchmarks` | `core/tests/perf/`（空） | — |

### 2.2 端到端测试（tests/e2e）

| 功能 | 实现文件 | 测试/验证方式 |
|---|---|---|
| e2e 用例 8 个：板创建 ×2 / 元素创建 ×2 / 页面管理 ×2 / AI 流程 ×2（驱动完整应用入口 + 演示模式 FFI） | 包根 `create_board_test.dart`、`create_element_test.dart`、`page_management_test.dart`、`ai_flow_test.dart` | `flutter test`（经 `test/` 转发）；实测 **+6 -2**（元素创建 2 用例失败，根因见 §5） |
| 转发结构：`flutter test` 无参只扫包内 `test/`；实现文件在包根，`test/` 下同名转发 | `test/{create_board,create_element,page_management,ai_flow}_test.dart`（`import '../xxx_test.dart'`） | 两处一一对应；缺转发入口的用例会被静默漏跑 |
| e2e 脚手架：1600×1000 视口、演示模式 FFI（DLL 候选路径必然失败）、首页 → 编辑页启动 | `support/e2e_support.dart` | 4 个用例文件共用；与 apps/desktop 深度 widget 测试同一策略 |

### 2.3 标准数据集（tests/fixture）—— 10 子目录 / 33 JSON + 1 最小 PDF

> 布局与路径约定（`tests/fixture/<域>/<名>.json`）由《测试方案设计》§17 定义。
> **核验注**：当前全仓检索无测试代码按路径引用本数据集（命中均为文档性描述）——数据已就绪、接线待办（见 §5）。

| 数据集（文件数） | 实现文件 | 测试/验证方式 |
|---|---|---|
| ai（2）：AI 提示词 / 响应样例 | `ai/{prompts,responses}.json` | 未接线 |
| backgrounds（4）：背景预设 | `backgrounds/{blackboard,dots,greenboard,whiteboard}.json` | 未接线 |
| boards（5）：整板快照（含 100 / 1000 元素性能板） | `boards/{empty,simple,complex,performance_100,performance_1000}.json` | 未接线 |
| elements（10）：元素类型单例 | `elements/{sticky,text,shape,connector,image,table,flowchart,mindmap,function,3d}.json` | 未接线 |
| flows（2）：流程图数据 | `flows/{simple_flow,swimlane}.json` | 未接线 |
| functions（3）：函数图数据 | `functions/{sin,cos,multiple}.json` | 未接线 |
| mcp（2）：MCP 工具 / 资源契约样例 | `mcp/{tools,resources}.json` | 未接线 |
| pages（2）：单页 / 多页结构 | `pages/{single,multiple}.json` | 未接线 |
| pdf（1）：最小样例 PDF（解析 / 导入边界） | `pdf/sample.pdf` | 未接线 |
| themes（3）：主题数据 | `themes/{clean,dark,blackboard}.json` | 未接线 |

### 2.4 性能测试流水线（tests/perf）

| 功能 | 实现文件 | 测试/验证方式 |
|---|---|---|
| 三步流水线：① C++ 基准（`wb_benchmarks.exe` → `out/benchmarks.log`）② Flutter 性能（`flutter test --profile integration_test/app_test.dart`；真实 `perf_test.dart` 未创建，`-FlutterTarget` 可覆盖）③ Lighthouse（需 8080 开发服务器）；缺工具 = SKIP（EXIT=0）、`-Strict` 将跳过翻转为失败、`-DryRun` 预览、`-Skip{Cpp,Flutter,Web}` 单步跳过 | `tests/perf/run_perf.ps1` | 实测 `-DryRun`：步骤 ①② 打印 DRY-RUN、③ SKIP（lighthouse 未安装），EXIT=0 |
| 流水线说明：§10.4 三命令映射、环境依赖、产物 `out/`、设备侧限制（批量目录运行受限，默认单文件 `app_test.dart`） | `tests/perf/README.md` | —（步骤②目标 `apps/desktop/integration_test/app_test.dart` 已存在，该目录归属 [11-app-desktop](11-app-desktop.md)） |

### 2.5 测试分层与规模基线（回归判据）

> workspace = melos 定义范围（`apps/**` + `packages/**` + `platform/**`，见 `melos.yaml`）；`tests/e2e` 为独立包（不在 melos 内）。
> 以下为本文档生成时逐项实跑核验结果；数字变化需更新本文件并说明原因。

| 测试层 | 命令 | 实测规模 |
|---|---|---|
| C++ 单元 + 集成 | `ctest --test-dir build/windows-x64 -C Release` | 199/199（unit 175 + integration 24） |
| Flutter workspace 合计 | 逐包 `flutter test` | 698（apps 475 + packages 162 + platform 61） |
| apps/desktop | `flutter test` | 435/435（含 FFI 集成 21；本地文件与设置持久化新增 47——`settings_persistence_test.dart` 16 / `board_file_codec_test.dart` 5 / `board_file_service_test.dart` 12 / `window_close_prompt_test.dart` 8 / `board_file_ui_test.dart` 6） |
| apps/web | `flutter test` | 40/40 |
| packages/*（9 包，7 包有测试） | `flutter test` | 162：core_dart 24 / ui_kit 38 / icons 9 / theme 10 / ai_dart 21 / api_client 28 / mcp_client 32 |
| platform/*（4 插件） | `flutter test` | 61：windows 17 / macos 12 / linux 19 / web 13 |
| tests/e2e（独立包） | `flutter test`（包根） | 8（实测 +6 -2） |
| services/api | `npm test` | 51/51 |
| services/mcp_server | `npm test` | 109/109 |
| services/ai_gateway | `.venv` pytest | 76/76 |
| services/convert | `.venv` pytest | 39/39 |

### 2.6 FFI 强校验机制（WB_REQUIRE_CORE_DLL）

| 功能 | 实现文件 | 测试/验证方式 |
|---|---|---|
| 强校验语义：DLL 缺失时普通环境返回统一 skip 理由（优雅跳过）；`WB_REQUIRE_CORE_DLL=1` 时抛 `StateError`（硬失败，防整包静默假绿）；DLL 定位（2 条相对路径 + 向上 4 层探测） | `apps/desktop/test/integration/support/ffi_support.dart` | 实测：`WB_REQUIRE_CORE_DLL=1` + `flutter test test/integration` → 21/21 全过（真实引擎 `[wb] core initialized v1.0.0`） |
| FFI 集成用例（初始化 / 命令总线 / 内存 / 渲染，4 文件共 21 用例） | `apps/desktop/test/integration/ffi_init_test.dart`、`ffi_command_test.dart`、`ffi_memory_test.dart`、`ffi_render_test.dart` | 同上（21/21）；并发约定：断言不依赖具体 `board-N`/`element-N` 编号、不调用 `wb_shutdown` |
| CI 强制接线：desktop-tests job 先构建 DLL，再以 `WB_REQUIRE_CORE_DLL=1` 运行集成测试 | `.github/workflows/ci.yml`（归属 17） | 本机制唯一 CI 消费方；**禁止移除 / 弱化**（见 17 文档） |

## 3. 契约与依赖

- **对外契约（回归判据）**：
  - 注册链：`core/tests/CMakeLists.txt` GLOB 收集 + `catch_discover_tests` 逐用例注册；新增 `*_test.cpp` 自动纳入（勿手改文件清单）；规模基线 **199**（unit 175 / integration 24）。
  - 强校验：`WB_REQUIRE_CORE_DLL=1` 且 DLL 缺失 → `StateError`；未设置 → skip；CI 必须保持 `=1`。
  - fixture 路径：`tests/fixture/<域>/<名>.json`（+ `pdf/sample.pdf`）；文件名是后续接线的引用目标，改动前全仓检索。
  - e2e 结构：实现文件在包根、`test/` 同名转发；`flutter test` 无参只扫 `test/`。
  - 规模基线（§2.5）：ctest 199 / workspace 698 / e2e 8 / api 51 / mcp 109 / ai_gateway 76 / convert 39。
  - FFI 集成并发约定（多 isolate 共享引擎状态）：不依赖具体编号、不调 `wb_shutdown`。
  - 基准开关：`WB_BUILD_BENCHMARKS=ON`（默认不构建）；基准产物 `build/windows-x64/bin/Release/wb_benchmarks.exe`。
  - perf 流水线：缺工具 = SKIP（EXIT=0）、`-Strict` = 失败（exit 1）。
- **被依赖**：17（验证矩阵与 CI 链路引用 ctest 199 与各层规模）；01–16（各模块文档"测试"列指向 `core/tests/unit/<域>/`、各包 `test/`、`services/*/tests`，由本模块保证注册与运行链路）。
- **依赖**：Catch2（third_party）、Flutter SDK、CMake ≥ 3.25 + VS2022；服务侧 Node（vitest）与 Python（`services/{ai_gateway,convert}/.venv` 内 pytest）。
- **已知契约事实（核验依据）**：ctest 199/199；workspace 698（desktop 435 / web 40 / packages 162 / platform 61）；e2e 8（当前 +6 -2）；api 51；mcp 109；ai_gateway 76；convert 39；FFI 集成 21；fixture 33 JSON + 1 PDF。

## 4. 常用命令

```powershell
# C++ 单测 + 集成（199）
cmake --preset windows-x64; cmake --build build/windows-x64 --config Release
ctest --test-dir build/windows-x64 -C Release --output-on-failure --timeout 120

# C++ 基准 + 性能流水线（缺工具自动跳过；-Strict 将跳过翻转为失败）
cmake --preset windows-x64 -DWB_BUILD_BENCHMARKS=ON; cmake --build build/windows-x64 --config Release
powershell -File tests\perf\run_perf.ps1 -DryRun

# Flutter 各层
Set-Location apps\desktop; flutter test                                                  # 435（含 FFI 集成）
Set-Location tests\e2e; flutter test                                                     # e2e 8（经 test/ 转发）
Set-Location apps\desktop; $env:WB_REQUIRE_CORE_DLL='1'; flutter test --no-pub test/integration   # FFI 强校验

# 服务端（ai_gateway / convert 用各自 .venv）
Set-Location services\api; npm test
Set-Location services\mcp_server; npm test
services\ai_gateway\.venv\Scripts\python.exe -m pytest services\ai_gateway
services\convert\.venv\Scripts\python.exe -m pytest services\convert
```

## 5. 变更影响提醒（改本模块时注意）

- **当前已知缺口（本文档生成时核验）**：
  1. `tests/e2e/create_element_test.dart` 2 个用例失败（finder 找不到 `wb-canvas-tool-sticky`，tap 失败位置 :26、:44）：默认工具栏风格为圆盘（`apps/desktop/lib/services/theme_service.dart:70/78`），画布工具面板仅在 `toolbarStyle == 'top'` 时挂载（`board_edit_page.dart:622-623、710` → `canvas_view.dart:221-229`）；e2e 脚手架未切到顶部面板风格即按面板键查找。建议：在 `support/e2e_support.dart` 注入 `toolbarStyle='top'` 的主题状态，或与 [11-app-desktop](11-app-desktop.md) 对齐整体方案后同步用例。
  2. `tests/fixture` 数据集暂无代码引用（数据已就绪、接线待办）。
  3. `core/tests/perf` 为空目录（C++ 性能用例归 `core/benchmarks`，性能编排归 `tests/perf`）。
- 改 `core/tests/**`：ctest 规模（199）与 01–06 文档的"测试"列联动；GLOB 自动注册，但**子目录名即域名**，迁移路径需同步 01–06 文档。
- 改 `tests/e2e/**`：转发入口缺失会静默漏跑；e2e 是应用行为的端到端守门，删改用例前评估 11/12 的覆盖缺口。
- 改 `tests/fixture/**`：接线后改名 / 移动会打穿引用方；当前无引用，是调整成本最低窗口。
- 改 FFI 强校验语义或 CI 的 `WB_REQUIRE_CORE_DLL=1`：直接决定 CI 是"真实回归"还是"静默假绿"（17 文档同样列为禁止项）。
- 改 `core/benchmarks/**` 文件名 / 开关：`tests/perf` 流水线与 17 的产物路径探测（`wb_benchmarks.exe`）联动。
- 规模基线（§2.5）数字变化：必须同步更新本文档，并在提交说明中解释原因（外部流程引用这些数字）。
