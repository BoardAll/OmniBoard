# 17 · build-release —— 构建打包与发布

> 模块路径：`tools/{scripts, packaging}`、`.github/workflows/`、`CMakePresets.json`、`VERSION`、根 `CMakeLists.txt`
> 维护 agent：`wb-build-release-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：全仓一键构建编排（`build_all` 5 步链路）；C++（`wb_core.dll`）/ Flutter（desktop 与 web）/ WASM 构建脚本；版本单一事实源（根 `VERSION`，`version_sync` 校验/更新 20 个版本承载文件）；SHA256 校验和（含写后回读自校验）；Windows Authenticode 签名（无证书优雅跳过）；打包制品（Inno Setup 安装包 + Web Docker/nginx）；CI/CD 三个工作流；CMake presets 与顶层 CMake 入口；C++ 第三方依赖 FetchContent 链的构建集成（`core/third_party`，含桌面 sioxx/Boost/OpenSSL）。
- **不负责**：C++ 引擎实现（→ [01-core-foundation](01-core-foundation.md)～[06-core-ai](06-core-ai.md)）、Flutter 应用实现（→ [11-app-desktop](11-app-desktop.md)、[12-app-web](12-app-web.md)）、服务端实现（→ [13-svc-api](13-svc-api.md)～[16-svc-convert](16-svc-convert.md)）、测试用例与 fixture 内容（→ [18-qa-testing](18-qa-testing.md)）。
- **地位**：全仓工程化支撑（与 18 并列）；所有模块的构建产物路径、CI 验证链路与发布物均经由本模块定义；脚本的退出码/参数/编码约定是跨模块"构建契约"。

## 2. 功能 → 文件映射

### 2.1 一键构建编排（tools/scripts）

| 功能 | 实现文件 | 测试/验证方式 |
|---|---|---|
| 一键编排 5 步：C++ → Windows 应用 → Web → WASM → 校验和；任一步失败即中止；`-Skip*` / `-RunCppTests` / `-WebWasm` | `tools/scripts/build_all.ps1` | 本机完整 5 步实证 EXIT=0（`tools/scripts/README.md` 验证矩阵）；Windows 步骤含 exe + `wb_core.dll` 部署检查 |
| C++ 核心构建（`windows-x64` preset；configure/build/可选 ctest；`wb_core.dll` 产物校验） | `tools/scripts/build_cpp.ps1` | `-RunTests` → ctest 全绿（自动发现 + 1 个环境门控 `[poc]` 用例，未设 `WB_SIOXX_POC_ENDPOINT` 时 Skipped 不失败；用例数随并行任务新增，非固定——2026-09-30 快照 205 / M0 期末 200）；启动时校验 preset 名是否在 `CMakePresets.json` 中定义 |
| Flutter 应用构建（windows/web 双目标；插件 symlink→NTFS junction 回退；web 注入 `--build-name/--build-number`） | `tools/scripts/build_flutter.ps1` | 本机双目标构建成功；产物校验（exe、`wb_core.dll`、`index.html`） |
| WASM 核心构建（`emcmake cmake --preset wasm` + `cmake --build --preset wasm-release`；无 EMSDK 打印安装指引并优雅跳过，`-Strict` 时失败；`-OutputDir` 收集产物（默认 `build\wasm\dist`），`-CopyToWebAssets` 复制到 `apps\web\web\`） | `tools/scripts/build_wasm.ps1` | 无 EMSDK 跳过 EXIT=0；**真实 Emscripten 构建路径已验证（2026-10-01，emsdk 3.1.74）**：configure 输出 `wb_core_wasm: 111 exported functions derived from wb.h`，build 成功，产物收集与 `-CopyToWebAssets` 复制 EXIT=0 |
| Flutter SDK 引导下载（国内镜像，一次性工具，本包未修改） | `tools/scripts/setup_flutter_sdk.ps1` | —（无自动化验证） |
| 脚本族总览、"已验证/未验证"矩阵与 PowerShell 约定 | `tools/scripts/README.md` | — |

### 2.2 版本同步 / 校验和 / 签名

| 功能 | 实现文件 | 测试/验证方式 |
|---|---|---|
| 版本一致性校验（`-Check`，默认、只读）与批量更新（`-Write`：pubspec / package.json / CMake `project() VERSION`；`-BuildNumber` 控 `+build`） | `tools/scripts/version_sync.ps1` | `-Check` 实测 20 文件 0 不一致 EXIT=0（apps×3、packages×9、platform×4、services×2、CMake×2） |
| SHA256 校验和（sha256sum 兼容 `<hash> *<name>`，UTF-8 无 BOM；`-PerFile`；写后回读自校验） | `tools/scripts/checksum.ps1` | 实测：缺失目录时跳过 EXIT=0、`-Strict` 时 EXIT=1；生成+自校验 PASS（脚本 README 记录） |
| Windows Authenticode 签名（signtool 解析链：`-SigntoolPath` → `WB_SIGNTOOL` → PATH → Windows Kits 探测；签后 `verify /pa`） | `tools/scripts/sign_windows.ps1` | 实测：无证书跳过 EXIT=0、`-Strict` 时 EXIT=1；真实签名路径未验证（本机无证书） |

### 2.3 打包制品（tools/packaging）

| 功能 | 实现文件 | 测试/验证方式 |
|---|---|---|
| Windows x64 安装包（Inno Setup 6；`OutputDir=..\..\..\dist`，相对 `.iss` 解析） | `tools/packaging/windows/inno_setup_x64.iss` | 本机无 iscc：结构校验（BOM/段落/相对路径）PASS；未编译 |
| Windows x86 安装包（预留；需先备 32 位产物，`Source` 目录按设计当前不存在） | `tools/packaging/windows/inno_setup_x86.iss` | 同上；未编译 |
| Web Docker 镜像（`nginx:alpine` + 构建上下文=仓库根） | `tools/packaging/web/Dockerfile` | 本机无 Docker：结构校验 PASS；未构建 |
| Web nginx 配置（COOP/COEP 隔离头、`application/wasm` MIME、SPA 回退、`/api` 与 `/ws` 反代占位） | `tools/packaging/web/nginx.conf` | 结构校验 PASS；未用 `nginx -t` 实测 |
| 打包说明与未验证清单 | `tools/packaging/README.md` | — |

### 2.4 构建配置与版本源

| 功能 | 实现文件 | 测试/验证方式 |
|---|---|---|
| CMake presets（configure：`windows-x64` / `windows-x64-debug` / `wasm`；build：`windows-x64-release` 等；test：`windows-x64-release`；含 GIT_CONFIG 代理绕过） | `CMakePresets.json` | ctest（快照 205）与各构建链路间接验证；`build_cpp.ps1` 启动时按名单校验 |
| 顶层 CMake 入口（`enable_testing()` + `add_subdirectory(core)`；契约冻结层） | `CMakeLists.txt`（根） | 全量构建 / ctest 间接验证 |
| C++ 第三方依赖（glm/nlohmann_json/fmt/spdlog/Catch2 既有；新增 sioxx 0.3.0 + Boost 1.90 + OpenSSL 3.5.9，均 FetchContent URL tarball；sioxx 仅桌面端，整段在 `if(NOT WB_BUILD_WASM)` 守卫内，L98–180） | `core/third_party/CMakeLists.txt`、`core/third_party/cmake/build_openssl.ps1` | 首次 configure EXIT=0（~12min：Boost 拉取 ~2m16s / OpenSSL 私有构建 ~9m14s / sioxx 拉取 ~5s；详见 M0 记录 §3.2）；`WB_BUILD_WASM=ON` 探针无 sioxx/Boost/OpenSSL 拉取 + T1.4 静态复核（2026-09-30：`core/src` 零 sioxx/boost/openssl 引用；守卫段 L98–180）；增量复跑 12.6s 全绿（G0 基线 12.8s）、OpenSSL 前缀未被重建；realtime smoke 真连通过 |
| 版本单一事实源（`MAJOR.MINOR.PATCH`） | `VERSION` | `version_sync -Check` 以它为期望值（当前 `1.0.0`） |

### 2.5 CI/CD（.github/workflows）

| 功能 | 实现文件 | 测试/验证方式 |
|---|---|---|
| CI：flutter analyze+test 全包循环（ubuntu）；desktop-tests（windows：先 `build_cpp.ps1`，再以 `WB_REQUIRE_CORE_DLL=1` 强校验 FFI）；cpp-tests（`build_cpp.ps1 -RunTests`）；services（`services/api` / `services/mcp_server` / `services/realtime` 三包 npm test 循环 + pytest） | `.github/workflows/ci.yml` | `WB_REQUIRE_CORE_DLL=1` 强制 DLL 缺失时硬失败（机制详见 [18-qa-testing](18-qa-testing.md)）；T1.4 YAML 结构校验（解析 + 断言）通过（2026-09-30） |
| CI 第三方依赖缓存（cpp-tests / desktop-tests 共享同一 key）：`actions/cache@v4`，缓存 `build/windows-x64/_deps` + `build/windows-x64/third_party/openssl-install` | `.github/workflows/ci.yml` | key = `wb-cpp-deps-${{ runner.os }}-${{ hashFiles('core/third_party/CMakeLists.txt', 'core/third_party/cmake/build_openssl.ps1') }}`；**无 restore-keys**（依赖定义变更即全量重建，防陈旧 OpenSSL 前缀按存在性被复用）；命中/未命中行为（≈12min 全量 vs 跳过依赖段）**待 CI 首跑实测观察** |
| 构建工作流：windows-app（C+++应用，exe+`wb_core.dll` 产物校验）；web（`index.html`/`main.dart.js`/`wb_core.js` 三项校验；`ENABLE_WASM_BUILD` 条件式 WASM） | `.github/workflows/build.yml` | 产物校验步骤与本地部署检查同契约 |
| 发布工作流：tag `v*` 触发；可选签名（`WB_SIGN_CERT_B64` secret 存在才执行）；zip / tar.gz + 校验和；web job `needs: windows` 串行（防两个 job 并发发布同一 Release）；web 端 `SHA256SUMS-web` 防与 windows 端 `SHA256SUMS` 同名冲突 | `.github/workflows/release.yml` | tag 触发与 secrets 条件按工作流注释中的契约 |

## 3. 契约与依赖

- **脚本接口约定（对外契约）**：
  - 退出码：`0` = 成功或按设计优雅跳过；`1` = 失败。`-Strict` 开关把"跳过"翻转为失败（`build_wasm` / `sign_windows` / `checksum`）。
  - 命名参数强制：所有脚本 `[CmdletBinding(PositionalBinding = $false)]`；脚本间调用必须哈希表 splat（数组 splat 会位置错绑，`build_all.ps1` 注释记录了历史案例）。
  - 编码：自建 `.ps1` 为 UTF-8 **带 BOM**；写回文本（`VERSION`、pubspec、package.json、`SHA256SUMS`）为 UTF-8 **无 BOM**；`.iss` 必须保留 BOM。
  - 环境变量：`WB_FLUTTER`（flutter 路径）、`WB_CMAKE`（cmake 路径）、`WB_CORE_DLL`（部署源覆盖）、`EMSDK`、`WB_SIGN_CERT` / `WB_SIGN_PASSWORD` / `WB_SIGNTOOL`；测试侧 `WB_REQUIRE_CORE_DLL`（见 18）。
  - 产物路径契约：`build\windows-x64\bin\Release\wb_core.dll`、`apps\desktop\build\windows\x64\runner\Release\`、`build\wasm\bin\`（`wb_core_wasm` 链接输出 `wb_core.js` + `wb_core.wasm`）→ `build\wasm\dist\`（`build_wasm.ps1` 收集）→ `apps\web\web\`（`-CopyToWebAssets`）、`apps\web\build\web\`、`dist\`（安装包与 `SHA256SUMS`）。
  - 调用留档（Windows PowerShell 5.1）：勿对脚本调用做 `2>&1` / `*>&1` 流合并再管道（如 `| Tee-Object`）——native 子进程（如 cmake）写 stderr 会被提升为 `NativeCommandError` 终止错误而误判失败（2026-09-30 复现实验）；需要全程留档请用 `Start-Transcript`。
- **被依赖**：18（测试链引用 DLL / 基准 / 应用产物路径）；11/12（构建与部署检查）；07/10（`wb_core.dll` / `wb_core.js` 加载链）；13–16（CI 测试接线）；发布消费方（`dist` 制品 + 校验和）。
- **依赖**：CMake ≥ 3.25 + VS2022；Flutter SDK；Emscripten / signtool+证书 / Inno Setup 6 / Docker（均可选，缺失时优雅跳过）。C++ 首次 configure 额外需要**原生 Windows Perl**（Strawberry 发行版；`build_openssl.ps1` 解析链：`-PerlExe`/`WB_PERL` → `C:\Strawberry` → `%LOCALAPPDATA%\wb-tools\strawberry` → ProgramFiles → PATH）与联网（Boost/OpenSSL/sioxx tarball 下载）。
- **已知契约事实（回归依据）**：`version_sync -Check` 检查 20 文件；`checksum` 输出格式 `<hash> *<name>`；`build_all` 5 步顺序且"任一步失败中止"；CI desktop-tests 必须先构建 DLL 且不可绕过 `WB_REQUIRE_CORE_DLL=1`；release 由 tag `v*` 触发、web job 串行于 windows；ctest 计数 = 自动发现用例 + 1 个 `[poc]` 门控用例（非固定值：M0 期末 200，2026-09-30 快照 205）；ci.yml 两个 Windows job 共享依赖缓存 key（§2.5）。

## 4. 常用命令

```powershell
# 一键完整构建（C++ + Windows 应用 + Web；无 EMSDK 自动跳过 WASM）
tools\scripts\build_all.ps1
tools\scripts\build_all.ps1 -SkipWindows -SkipWasm -RunCppTests   # 只 C++（含 ctest）+ Web

# 分步
tools\scripts\build_cpp.ps1 -RunTests
tools\scripts\build_flutter.ps1 -Target windows
tools\scripts\build_flutter.ps1 -Target web -Wasm
tools\scripts\build_wasm.ps1 -CopyToWebAssets   # WASM 核心（需 emsdk 环境；产物复制到 apps\web\web\）

# sioxx POC 连通（先启动 services/realtime：node dist/server.js，默认 :8790）
$env:WB_SIOXX_POC_ENDPOINT = 'localhost:8790'
build\windows-x64\bin\Release\wb_tests.exe "[poc]"

# 发布前检查链（版本 → 产物 → 校验和 → 签名）
tools\scripts\version_sync.ps1 -Check
iscc tools\packaging\windows\inno_setup_x64.iss
tools\scripts\checksum.ps1 -Path dist -PerFile
tools\scripts\sign_windows.ps1 -Strict
```

## 5. 变更影响提醒（改本模块时注意）

- 改 `build_cpp.ps1` / `CMakePresets.json` → 波及 **01–06**（C++ 构建入口）与 **07/11**（DLL 加载）：必须全量 ctest 全绿（快照 205）并跑 `WB_REQUIRE_CORE_DLL=1` 的 FFI 集成（18 的强校验链）。
- 改 `build_flutter.ps1` → 产物路径被 **11/12** 部署检查与 `build.yml` 校验步骤依赖；`Release` 目录名或 `build\web` 布局变化会直接打穿 CI 产物校验。
- 改 `build_wasm.ps1` / `wasm` preset / `wb_core_wasm` 目标（`core/src/CMakeLists.txt`）→ 影响 **12 app-web** 的真实画布产物（`-CopyToWebAssets` 落入 `apps\web\web\`）；关键守卫：`-Wl,--whole-archive`（域注册器自注册，缺失即域全部被丢弃）+ `MODULARIZE=1 -sEXPORT_NAME=WbCore` + `--post-js=core/wasm/post_js.js`（小写别名层 `utf8ToString`/`heapU8`，缺失即 Dart `callString`/`callInt` 抛 `NoSuchMethodError`）；导出列表由 `wb.h` 自动提取（2026-10-01 快照 111 个）。
- 改 `version_sync.ps1` 扫描集合 → 与"20 文件清单"联动（新增子包 pubspec 自动纳入）；改根 `VERSION` → 全仓版本级变更（安装包文件名、web `--build-name`、`.iss` 的 `AppVersion/OutputBaseFilename` 需同步）。
- 改 `checksum.ps1` 输出格式 / `sign_windows.ps1` 跳过语义 → **release.yml** 消费方（`SHA256SUMS`、`-Strict` 签名步骤）与制品分发流程。
- 改 C++ 第三方依赖链（`core/third_party/CMakeLists.txt` 的 sioxx/Boost/OpenSSL 段、`core/third_party/cmake/build_openssl.ps1`）→ **首次 configure 需联网并经 Perl 构建 OpenSSL（本机实测 ~12 分钟）**；**CI 已加依赖缓存**（ci.yml 两个 Windows job 共享 key；改上述两文件即失效转全量），命中行为待 CI 实测；sioxx 经 `wb::sioxx` 别名对外可见、可用时并入 `wb_third_party` 伞目标；全部包在 `if(NOT WB_BUILD_WASM)` 段内（L98–180）；**`core/src` 源码收集为无过滤 glob**——桌面专用新源码（如 socketio_transport）必须文件级 `#if !defined(__EMSCRIPTEN__)` 自守卫（缺失时 wasm 因找不到 sioxx 头而硬失败，非静默）。
- `core/tests/CMakeLists.txt` 的 `[poc]` 用例发现依赖四者联合：`TEST_SPEC "~[poc]"` + 手工 `add_test` + `SKIP_RETURN_CODE 4` + `DISCOVERY_MODE PRE_TEST`（Catch2 3.5.2 无 skip 发现支持；POST_BUILD 在增量不 relink 时静默丢列表）；真连启用见 §4 的 `WB_SIOXX_POC_ENDPOINT`。
- 改 `.github/workflows/*` → 影响全仓 CI 入口（每个模块的验证链路都从这里触发）；**禁止移除 `WB_REQUIRE_CORE_DLL=1`**（否则 FFI 集成会被静默跳过，形成假绿）；CI 依赖缓存 key 绑定 `core/third_party/CMakeLists.txt` + `cmake/build_openssl.ps1`，改动时两个 Windows job 需同步（§2.5）。
- 根 `CMakeLists.txt` / `CMakePresets.json` 属**契约冻结层**：任何修改先评估全仓影响（生成器版本、cache 变量默认值、preset 命名）。
