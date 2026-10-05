# 18 · qa-testing —— 测试与质量体系

> 模块路径：`tests/{e2e, fixture, perf}`、`core/tests`（unit / integration / perf）、`core/benchmarks`、FFI 强校验机制与各包/服务的测试规模基线
> 维护 agent：`wb-qa-testing-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：全仓测试分层体系（C++ 单元/集成/基准 → Flutter 单测/widget/集成 → e2e → 四个服务端测试层）的组织与规模基线；`core/tests` 的用例组织、ctest 注册链与运行链路；`core/benchmarks` 基准程序；`tests/e2e` 端到端用例（10 个：应用流 8 + M1 场景骨架 2）与 `test/` 转发结构；**M1/M2/M3「双端互见」场景编排**（`tests/e2e/support/`，四段可独立执行：server / desktop×2 / ops / web）；`tests/fixture` 标准数据集（10 子目录 / 33 JSON + 1 最小 PDF）；`tests/perf` 性能测试流水线；FFI 强校验机制（`WB_REQUIRE_CORE_DLL`：DLL 缺失时普通环境优雅跳过、CI 硬失败）。
- **不负责**：功能实现与其单测用例内容（C++ 域用例、Dart 用例、服务用例随功能演进，由 [01-core-foundation](01-core-foundation.md)～[16-svc-convert](16-svc-convert.md) 各自维护）；构建产物与 CI 工作流本体（→ [17-build-release](17-build-release.md)，本模块只提供其"测试侧契约"）。
- **地位**：全仓质量守门（与 17 并列的工程化支撑）；§2.5 规模基线与 §2.6 强校验语义是全仓回归判据。

## 2. 功能 → 文件映射

### 2.1 C++ 测试与基准（core/tests、core/benchmarks）

| 功能 | 实现文件 | 测试/验证方式 |
|---|---|---|
| C++ 单元测试：33 个子目录 / 36 个测试文件，覆盖 01–06 全部域（含 M1 新增 `sync/outbound_queue_test.cpp`、`ffi/ffi_collab_symbols_test.cpp`；M3 用例增强集中于 sync / ffi_collab 域；用例内容随各域演进） | `core/tests/unit/<域>/`（32 个用例目录 + `support/`；公共脚手架 `unit/support/scene_probe.h`、`unit/sync/fake_transport.h`） | ctest 逐用例注册（**unit 209 个用例**；实跑全过） |
| C++ 集成测试：跨模块协作 9 文件（3D 渲染 / 命令模型 / CRDT 同步 / 流程图渲染 / 函数渲染 / 页面元素 / 权限审计 / SocketIO POC / Sync SocketIO） | `core/tests/integration/test_{3d_render,command_model,crdt_sync,flowchart_render,function_render,page_element,permission_audit,socketio_poc,sync_socketio}.cpp`、`integration/support/test_probe.h` | ctest（**integration 25 个用例**；实跑全过，POC 为 env-gated） |
| 测试注册链：GLOB 收集 `unit/*.cpp` + `integration/*.cpp`，`catch_discover_tests`（`TEST_SPEC "~[poc]"`）逐用例注册；SocketIO POC 由显式 `add_test` 单独注册（env-gated，`SKIP_RETURN_CODE 4`） | `core/tests/CMakeLists.txt` | `ctest -N` 实测注册 **234**；全量实跑 234/234（233 通过 + 1 env-gated skip，快照 2026-10-01 M3） |
| 性能基准：5 个程序 6 个用例（元素吞吐 / 序列化 / 页面切换 / CRDT 增量写 + 同步链路 / 流程图与函数） | `core/benchmarks/bench_{elements,serialization,page_switch,crdt_sync,flowchart_function}.cpp` | 产物 `build/windows-x64/bin/Release/wb_benchmarks.exe`（实测存在）；由 `tests/perf` 流水线调用 |
| 基准工程：GLOB + `WB_BUILD_BENCHMARKS` 开关（默认不构建）；无源时生成占位程序 | `core/benchmarks/CMakeLists.txt`、`benchmarks/support/bench_util.h` | 开关打开后构建；产物路径被 `run_perf.ps1` 探测 |
| 性能测试目录（预留）：空目录，未纳入构建；C++ 性能用例实际归 `core/benchmarks` | `core/tests/perf/`（空） | — |

### 2.2 端到端测试（tests/e2e）

| 功能 | 实现文件 | 测试/验证方式 |
|---|---|---|
| e2e 用例 10 个：应用流 8（板创建 ×2 / 元素创建 ×2 / 页面管理 ×2 / AI 流程 ×2，驱动完整应用入口 + 演示模式 FFI）+ M1 场景骨架 2（复用资产存在性 / fixture 板可解析，恒可运行） | 包根 `create_board_test.dart`、`create_element_test.dart`、`page_management_test.dart`、`ai_flow_test.dart`、`collab_dual_end_test.dart` | `flutter test`（经 `test/` 转发）；实测 **+10 全过**（2026-10-01，M3 复核） |
| M1/M2/M3「双端互见」场景编排（骨架化 + 可执行编排，四段）：server（:8790）→ desktop（参与者 ×2 双进程真连）→ ops（互见 op 矩阵 + M2 契约里程碑：presence 转发 / 软锁 / 断线差分量；M3 契约里程碑：interactive 9 动作 / 角色矩阵拒绝 / checkpoint 单播-快照恢复 / 自举房承接，JWT 角色注入）→ web（参与者 ×1，W1 成员/状态） | `support/run_collab_dual_end.mjs`（编排）、`support/wb_collab_scenario_probe.mjs`（契约级探针） | `node tests/e2e/support/run_collab_dual_end.mjs [--only=server,desktop,ops,web] [--reuse-server]`；实测全量四段 **PASS**（快照 2026-10-01，M3 复核两轮，退出码 0） |
| 转发结构：`flutter test` 无参只扫包内 `test/`；实现文件在包根，`test/` 下同名转发 | `test/{create_board,create_element,page_management,ai_flow,collab_dual_end}_test.dart`（`import '../xxx_test.dart'`） | 两处一一对应；缺转发入口的用例会被静默漏跑 |
| e2e 脚手架：1600×1000 视口、演示模式 FFI（DLL 候选路径必然失败）、首页 → 编辑页启动；`pumpApp/pumpEditor` 返回 `WbThemeState`（用例可显式声明工具栏风格） | `support/e2e_support.dart` | 全部用例文件共用；与 apps/desktop 深度 widget 测试同一策略 |

> 场景分段说明（无完整 GUI / 浏览器环境时）：`desktop` 段 = T1.6 双进程真连等价物（单进程引擎为进程级单例，用两进程等价"双开"）；`ops` 段 = 契约级探针（同一真实服务端）；`web` 段 = T1.8 浏览器冒烟（缺 Chrome/Edge 自动 SKIP）。运行前置：`services/realtime` 已 `npm run build`、`wb_core.dll` 已构建（desktop 段）、Node ≥ 18；M3 探针 env（`WB_JWT_SECRET` / `WB_CHECKPOINT_OP_THRESHOLD`）由编排以默认值（`e2e-m3-secret` / `6`）双端注入，可用同名环境变量覆盖。

### 2.3 标准数据集（tests/fixture）—— 10 子目录 / 33 JSON + 1 最小 PDF

> 布局与路径约定（`tests/fixture/<域>/<名>.json`）由《测试方案设计》§17 定义。
> **核验注**：实现代码目前无按路径引用（命中均为文档性描述）；`tests/e2e` 场景骨架已引用 `boards/{empty,simple}.json` 做可解析校验（M1 补充）。整体接线待办（见 §5）。

| 数据集（文件数） | 实现文件 | 测试/验证方式 |
|---|---|---|
| ai（2）：AI 提示词 / 响应样例 | `ai/{prompts,responses}.json` | 未接线 |
| backgrounds（4）：背景预设 | `backgrounds/{blackboard,dots,greenboard,whiteboard}.json` | 未接线 |
| boards（5）：整板快照（含 100 / 1000 元素性能板） | `boards/{empty,simple,complex,performance_100,performance_1000}.json` | e2e 骨架校验 empty/simple 可解析 |
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
> **快照日期：2026-10-01（M3 逐层实跑）**；数字仅作快照，不以"绝对正确值"固化；变化时更新本文件并说明原因。

| 测试层 | 命令 | 实跑快照（2026-10-01 M3） |
|---|---|---|
| C++ 单元 + 集成 | `tools\scripts\build_cpp.ps1 -RunTests`（配置 + 构建 + ctest） | **234/234**（unit 209 + integration 25；1 个 env-gated skip） |
| Flutter workspace 合计 | 逐包 `flutter test --no-pub` | **1030**（apps 786 + packages 183 + platform 61） |
| apps/desktop | `flutter test --no-pub` | **697** 通过（另有 5 skip：未设 `WB_REALTIME_E2E` 的双进程/往返用例） |
| apps/web | `flutter test --no-pub` | **89** 通过 |
| packages/*（9 包，7 包有测试） | `flutter test --no-pub` | **183**：core_dart 45 / ui_kit 38 / icons 9 / theme 10 / ai_dart 21 / api_client 28 / mcp_client 32 |
| platform/*（4 插件） | `flutter test --no-pub` | **61**：windows 17 / macos 12 / linux 19 / web 13 |
| Flutter 静态分析（门禁） | 各包 `flutter analyze --no-pub` | apps/desktop、apps/web 与 packages 9 包全 **0 issues**（2026-10-01，M3 复核） |
| tests/e2e（独立包） | `flutter test --no-pub`（包根） | **10 通过**（应用流 8 + M1 场景骨架 2） |
| services/realtime | `npm test` | **74** 通过 |
| services/api | `npm test` | **51** 通过 |
| services/mcp_server | `npm test` | **109** 通过 |
| services/ai_gateway | `.venv` pytest | **76** 通过 |
| services/convert | `.venv` pytest | **39** 通过 |
| FFI 集成专项（强校验） | `WB_REQUIRE_CORE_DLL=1` + `flutter test test/integration` | **21 通过 + 5 env-gated skip**（integration 目录共 26 用例） |
| M1/M2/M3 场景（编排） | `node tests\e2e\support\run_collab_dual_end.mjs` | 四段 **PASS**（server / desktop / ops / web；M3 复核两轮） |

> **M2 → M3 增量（2026-10-01 复核）**：ctest 228→234（+6，unit 203→209，集中于 sync / ffi_collab 域）；services/realtime 48→74（+26：interactive / host-transfer / checkpoint / host-bootstrap 四组）；apps/desktop 557→697（+140，含幽灵预览修复回归、门 G3 证据补齐、互动补丁与 id 命名空间用例）；apps/web 72→89（+17）；packages/core_dart 41→45（+4）；workspace 869→1030（+161）；e2e 10 / platform 61 / api 51 / mcp 109 / ai_gateway 76 / convert 39 / FFI 21+5 不变。

### 2.6 FFI 强校验机制（WB_REQUIRE_CORE_DLL）

| 功能 | 实现文件 | 测试/验证方式 |
|---|---|---|
| 强校验语义：DLL 缺失时普通环境返回统一 skip 理由（优雅跳过）；`WB_REQUIRE_CORE_DLL=1` 时抛 `StateError`（硬失败，防整包静默假绿）；DLL 定位（2 条相对路径 + 向上 4 层探测） | `apps/desktop/test/integration/support/ffi_support.dart` | 实测（2026-10-01）：`WB_REQUIRE_CORE_DLL=1` + `flutter test test/integration` → **21/21 全过**（真实引擎 `[wb] core initialized v1.0.0`）+ 5 个 `WB_REALTIME_E2E` 未设的优雅 skip |
| FFI 集成用例：基础 4 文件 21 用例（初始化 / 命令总线 / 内存 / 渲染）+ M1 新增 2 文件 3 用例（`ffi_sync_roundtrip_test.dart` 1、`ffi_sync_dual_process_test.dart` 2）+ M3 新增 1 文件 2 用例（`ffi_sync_interactive_e2e_test.dart`；门 G3 真引擎 interactive 闭环证据补齐；以上未设 `WB_REALTIME_E2E=1` 时优雅 skip） | `apps/desktop/test/integration/ffi_{init,command,memory,render,sync_roundtrip,sync_dual_process,sync_interactive_e2e}_test.dart` | 同上；并发约定：断言不依赖具体 `board-N`/`element-N` 编号、不调用 `wb_shutdown` |
| env-gated 真连：`WB_REALTIME_E2E=1` + 端点/板/元素 env（`WB_DUAL_*`）时双进程真连与真实 realtime 往返真跑（由 `tests/e2e` 场景 desktop 段编排设置） | `apps/desktop/test/integration/support/run_dual_process_ffi_test.mjs`、`…/wb_realtime_probe.mjs` | 场景实测：receiver join 确认 → sender 落定提交 → receiver 收到远端 op（`+1 All tests passed` ×2） |
| CI 强制接线：desktop-tests job 先构建 DLL，再以 `WB_REQUIRE_CORE_DLL=1` 运行集成测试 | `.github/workflows/ci.yml`（归属 17） | 本机制唯一 CI 消费方；**禁止移除 / 弱化**（见 17 文档） |

### 2.7 M1/M2/M3 协同测试资产索引

| 类别 | 资产文件 | 运行入口 | 快照状态（2026-10-01，M3） |
|---|---|---|---|
| C++ sync / crdt 域用例 | `core/tests/unit/sync/{sync_test.cpp,outbound_queue_test.cpp,fake_transport.h}`、`unit/crdt/crdt_test.cpp`、`unit/ffi/ffi_collab_symbols_test.cpp`、`integration/{test_crdt_sync.cpp,test_sync_socketio.cpp,test_socketio_poc.cpp}` | ctest（POC 需 `WB_SIOXX_POC_ENDPOINT` 且 env-gated） | 全过（M3 复核）；POC 正向对照 1/1 Passed（本机起 realtime 时） |
| realtime 契约用例 | `services/realtime/tests/{contract.test.ts,realtime.test.ts,oplog.test.ts,presence-lock.test.ts,interactive.test.ts,host-transfer.test.ts,checkpoint.test.ts,host-bootstrap.test.ts}`（+ `helpers.ts`） | `services/realtime` → `npm test` | 74/74（M3：+21；房主自举 +5） |
| 桌面双进程真连 | `apps/desktop/test/integration/ffi_sync_dual_process_test.dart` + `support/run_dual_process_ffi_test.mjs` + `support/wb_realtime_probe.mjs` | `node support/run_dual_process_ffi_test.mjs`（须设 `WB_REALTIME_E2E=1`）；或经场景 desktop 段 | 场景内 PASS（A 发 B 收闭环） |
| Web W1 冒烟 | `apps/web/test/realtime_web_smoke_test.dart`（`@TestOn('browser')`，endpoint 经 `--dart-define=WB_REALTIME_ENDPOINT` 覆盖） | `flutter test --platform chrome`（需 CHROME_EXECUTABLE）；或经场景 web 段 | 场景内 PASS（Edge 真连，成员/状态互见） |
| e2e 场景编排 | `tests/e2e/support/run_collab_dual_end.mjs`、`support/wb_collab_scenario_probe.mjs`、包根 `collab_dual_end_test.dart`（+ `test/` 转发） | `node tests/e2e/support/run_collab_dual_end.mjs`（全量 / `--only=` 分段 / `--list`） | 四段全 PASS（M3 复核两轮）；里程碑 15 条：ready → op-matrix → presence → locks → away → recovered → m3-ready → m3-raise-hand → m3-grant → m3-present → m3-follow → m3-role-matrix → m3-remove-user → m3-checkpoint → m3-checkpoint-bootstrapped（M2：presence 防伪造 / 锁断连释放 / 重连快照净度；M3：interactive 定向单播 / 角色矩阵拒绝无扩散 / checkpoint 阈值-单播-快照恢复-自举房承接） |

## 3. 契约与依赖

- **对外契约（回归判据）**：
  - 注册链：`core/tests/CMakeLists.txt` GLOB 收集 + `catch_discover_tests`（`~[poc]`）+ SocketIO POC 显式注册；新增 `*_test.cpp` 自动纳入（勿手改文件清单）；规模基线 **234**（unit 209 / integration 25；快照 2026-10-01 M3）。
  - 强校验：`WB_REQUIRE_CORE_DLL=1` 且 DLL 缺失 → `StateError`；未设置 → skip；CI 必须保持 `=1`。
  - env-gated 真连：`WB_REALTIME_E2E=1` 未设置 → 双进程/往返 3 用例优雅 skip；设置 → 真跑（场景 desktop 段自动设置，含 `WB_DUAL_{ROLE,BOARD,ELEMENT,FLAG,ENDPOINT}` 约定）。
  - fixture 路径：`tests/fixture/<域>/<名>.json`（+ `pdf/sample.pdf`）；文件名是后续接线的引用目标，改动前全仓检索。
  - e2e 结构：实现文件在包根、`test/` 同名转发（5 组）；`flutter test` 无参只扫 `test/`。
  - M1/M2/M3 场景：四段（server/desktop/ops/web）可独立执行；ops 段含 M2/M3 契约里程碑（M2：presence 转发 / 软锁 / 断线差分量；M3：interactive 9 动作 / 角色矩阵拒绝 / checkpoint 阈值-单播-快照恢复 / 自举房承接）；M3 探针 env（`WB_JWT_SECRET` / `WB_CHECKPOINT_OP_THRESHOLD`，默认 `e2e-m3-secret` / `6`）由编排双端注入；退出码 0 = 全部执行段 PASS（SKIP 允许）、1 = 任意段 FAIL；`web` 段缺浏览器 = SKIP（不算失败）。
  - 规模基线（§2.5，快照）：ctest 234 / workspace 1030 / e2e 10 / realtime 74 / api 51 / mcp 109 / ai_gateway 76 / convert 39。
  - FFI 集成并发约定（多 isolate 共享引擎状态）：不依赖具体编号、不调 `wb_shutdown`。
  - 基准开关：`WB_BUILD_BENCHMARKS=ON`（默认不构建）；基准产物 `build/windows-x64/bin/Release/wb_benchmarks.exe`。
  - perf 流水线：缺工具 = SKIP（EXIT=0）、`-Strict` = 失败（exit 1）。
- **被依赖**：17（验证矩阵与 CI 链路引用 ctest 234 与各层规模）；01–16（各模块文档"测试"列指向 `core/tests/unit/<域>/`、各包 `test/`、`services/*/tests`，由本模块保证注册与运行链路）。
- **依赖**：Catch2（third_party）、Flutter SDK、CMake ≥ 3.25 + VS2022；服务侧 Node（vitest）与 Python（`services/{ai_gateway,convert}/.venv` 内 pytest）。

## 4. 常用命令

```powershell
# C++ 单测 + 集成（234：233 通过 + 1 env-gated skip；socketio POC 未设端点时跳过）
tools\scripts\build_cpp.ps1 -RunTests                                            # 配置 + 构建 + ctest
ctest --test-dir build/windows-x64 -C Release --output-on-failure --timeout 120  # 仅重跑测试

# M1/M2/M3「双端互见」场景（全量 / 分段 / 段说明；前置：realtime 已构建、wb_core.dll 已构建；M3 env 由脚本双端注入）
node tests\e2e\support\run_collab_dual_end.mjs                    # 全量四段
node tests\e2e\support\run_collab_dual_end.mjs --only=server,ops  # 无 GUI / 浏览器环境分段
node tests\e2e\support\run_collab_dual_end.mjs --list             # 段说明

# C++ 基准 + 性能流水线（缺工具自动跳过；-Strict 将跳过翻转为失败）
cmake --preset windows-x64 -DWB_BUILD_BENCHMARKS=ON; cmake --build build/windows-x64 --config Release
powershell -File tests\perf\run_perf.ps1 -DryRun

# Flutter 各层（analyze 门禁 = 0 issues）
Set-Location apps\desktop; flutter analyze --no-pub; flutter test --no-pub                        # 697（含 FFI 集成；另 5 skip）
Set-Location apps\web; flutter analyze --no-pub; flutter test --no-pub                            # 89
Set-Location tests\e2e; flutter test --no-pub                                                     # e2e 10（经 test/ 转发）
Set-Location apps\desktop; $env:WB_REQUIRE_CORE_DLL='1'; flutter test --no-pub test/integration   # 强校验（21 + 5 env-gated）

# 服务端（ai_gateway / convert 用各自 .venv）
Set-Location services\realtime; npm test
Set-Location services\api; npm test
Set-Location services\mcp_server; npm test
services\ai_gateway\.venv\Scripts\python.exe -m pytest services\ai_gateway
services\convert\.venv\Scripts\python.exe -m pytest services\convert
```

## 5. 变更影响提醒（改本模块时注意）

- **当前已知缺口（快照 2026-10-01 核验）**：
  1. `tests/fixture` 数据集除 `boards/{empty,simple}`（e2e 骨架自检）外暂无实现代码引用（数据已就绪、接线待办）。
  2. `core/tests/perf` 为空目录（C++ 性能用例归 `core/benchmarks`，性能编排归 `tests/perf`）。
  - 已修复（2026-09-30）：`tests/e2e/create_element_test.dart` 2 用例的工具栏风格适配——应用默认 `radial`（圆盘）时顶部面板不挂载，用例现经 `e2e_support` 返回的 `WbThemeState.applyAppearance(toolbarStyle: top)` 显式声明风格假设（与 `apps/desktop/test/board_wiring_test.dart` 同款手法）。
  - 已修复（2026-10-01 复核确认）：`apps/desktop/integration_test/create_element_test.dart` 已按同款手法适配（`pumpEditorWithTopToolbar` 先切 `toolbarStyle: top` 再断言 `wb-canvas-tool-sticky`）——2026-09-30 疑似项闭环。
- 改 `core/tests/**`：ctest 规模（234）与 01–06 文档的"测试"列联动；GLOB 自动注册，但**子目录名即域名**，迁移路径需同步 01–06 文档。
- 改 `tests/e2e/**`：转发入口缺失会静默漏跑；场景编排（`support/run_collab_dual_end.mjs`）复用 T1.6 双进程用例与 T1.8 浏览器冒烟——**这两处资产移动 / 改名会打断场景**（骨架自检 `collab_dual_end_test.dart` 会先失败报警）；`support/wb_collab_scenario_probe.mjs` 的 M3 契约组与服务端 `services/realtime/src/{interactive,checkpoint}.ts` 行为绑定（定向单播 / 阈值触发 / 快照透传），服务端语义变更须同步探针与本文档。
- 改 `WB_REALTIME_E2E` / `WB_DUAL_*` env 约定：场景 desktop 段启用双进程真连的开关，语义变化须同步本文件与 11 文档；M3 另涉 `WB_JWT_SECRET` / `WB_CHECKPOINT_OP_THRESHOLD`（编排以默认值双端注入，变更须同步本文件与 `tests/e2e/README.md`）。
- 改 `tests/fixture/**`：接线后改名 / 移动会打穿引用方；当前无引用，是调整成本最低窗口。
- 改 FFI 强校验语义或 CI 的 `WB_REQUIRE_CORE_DLL=1`：直接决定 CI 是"真实回归"还是"静默假绿"（17 文档同样列为禁止项）。
- 改 `core/benchmarks/**` 文件名 / 开关：`tests/perf` 流水线与 17 的产物路径探测（`wb_benchmarks.exe`）联动。
- 规模基线（§2.5）数字变化：必须同步更新本文档，并在提交说明中解释原因（外部流程引用这些数字）。
