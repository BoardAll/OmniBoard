# 17 · build-release —— 构建打包与发布

> 模块路径：`tools/{scripts, packaging}`、`.github/workflows/`、`CMakePresets.json`、`VERSION`、根 `CMakeLists.txt`
> 维护 agent：`wb-build-release-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：全仓一键构建编排（`build_all` 5 步链路）；C++（`wb_core.dll`）/ Flutter（desktop 与 web）/ WASM 构建脚本；版本单一事实源（根 `VERSION`，`version_sync` 校验/更新 20 个版本承载文件）；SHA256 校验和（含写后回读自校验）；Windows Authenticode 签名（无证书优雅跳过）；打包制品（Inno Setup 安装包 + Web Docker/nginx）；CI/CD 三个工作流；CMake presets 与顶层 CMake 入口。
- **不负责**：C++ 引擎实现（→ [01-core-foundation](01-core-foundation.md)～[06-core-ai](06-core-ai.md)）、Flutter 应用实现（→ [11-app-desktop](11-app-desktop.md)、[12-app-web](12-app-web.md)）、服务端实现（→ [13-svc-api](13-svc-api.md)～[16-svc-convert](16-svc-convert.md)）、测试用例与 fixture 内容（→ [18-qa-testing](18-qa-testing.md)）。
- **地位**：全仓工程化支撑（与 18 并列）；所有模块的构建产物路径、CI 验证链路与发布物均经由本模块定义；脚本的退出码/参数/编码约定是跨模块"构建契约"。

## 2. 功能 → 文件映射

### 2.1 一键构建编排（tools/scripts）

| 功能 | 实现文件 | 测试/验证方式 |
|---|---|---|
| 一键编排 5 步：C++ → Windows 应用 → Web → WASM → 校验和；任一步失败即中止；`-Skip*` / `-RunCppTests` / `-WebWasm` | `tools/scripts/build_all.ps1` | 本机完整 5 步实证 EXIT=0（`tools/scripts/README.md` 验证矩阵）；Windows 步骤含 exe + `wb_core.dll` 部署检查 |
| C++ 核心构建（`windows-x64` preset；configure/build/可选 ctest；`wb_core.dll` 产物校验） | `tools/scripts/build_cpp.ps1` | `-RunTests` → ctest 199/199；启动时校验 preset 名是否在 `CMakePresets.json` 中定义 |
| Flutter 应用构建（windows/web 双目标；插件 symlink→NTFS junction 回退；web 注入 `--build-name/--build-number`） | `tools/scripts/build_flutter.ps1` | 本机双目标构建成功；产物校验（exe、`wb_core.dll`、`index.html`） |
| WASM 核心构建（`emcmake cmake --preset wasm`；无 EMSDK 打印安装指引并优雅跳过，`-Strict` 时失败） | `tools/scripts/build_wasm.ps1` | 无 EMSDK 环境实测跳过 EXIT=0；真实 Emscripten 构建路径未验证 |
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
| CMake presets（configure：`windows-x64` / `windows-x64-debug` / `wasm`；build：`windows-x64-release` 等；test：`windows-x64-release`；含 GIT_CONFIG 代理绕过） | `CMakePresets.json` | ctest 199 与各构建链路间接验证；`build_cpp.ps1` 启动时按名单校验 |
| 顶层 CMake 入口（`enable_testing()` + `add_subdirectory(core)`；契约冻结层） | `CMakeLists.txt`（根） | 全量构建 / ctest 间接验证 |
| 版本单一事实源（`MAJOR.MINOR.PATCH`） | `VERSION` | `version_sync -Check` 以它为期望值（当前 `1.0.0`） |

### 2.5 CI/CD（.github/workflows）

| 功能 | 实现文件 | 测试/验证方式 |
|---|---|---|
| CI：flutter analyze+test 全包循环（ubuntu）；desktop-tests（windows：先 `build_cpp.ps1`，再以 `WB_REQUIRE_CORE_DLL=1` 强校验 FFI）；cpp-tests（`build_cpp.ps1 -RunTests`）；services（npm test + pytest） | `.github/workflows/ci.yml` | `WB_REQUIRE_CORE_DLL=1` 强制 DLL 缺失时硬失败（机制详见 [18-qa-testing](18-qa-testing.md)） |
| 构建工作流：windows-app（C+++应用，exe+`wb_core.dll` 产物校验）；web（`index.html`/`main.dart.js`/`wb_core.js` 三项校验；`ENABLE_WASM_BUILD` 条件式 WASM） | `.github/workflows/build.yml` | 产物校验步骤与本地部署检查同契约 |
| 发布工作流：tag `v*` 触发；可选签名（`WB_SIGN_CERT_B64` secret 存在才执行）；zip / tar.gz + 校验和；web job `needs: windows` 串行（防两个 job 并发发布同一 Release）；web 端 `SHA256SUMS-web` 防与 windows 端 `SHA256SUMS` 同名冲突 | `.github/workflows/release.yml` | tag 触发与 secrets 条件按工作流注释中的契约 |

## 3. 契约与依赖

- **脚本接口约定（对外契约）**：
  - 退出码：`0` = 成功或按设计优雅跳过；`1` = 失败。`-Strict` 开关把"跳过"翻转为失败（`build_wasm` / `sign_windows` / `checksum`）。
  - 命名参数强制：所有脚本 `[CmdletBinding(PositionalBinding = $false)]`；脚本间调用必须哈希表 splat（数组 splat 会位置错绑，`build_all.ps1` 注释记录了历史案例）。
  - 编码：自建 `.ps1` 为 UTF-8 **带 BOM**；写回文本（`VERSION`、pubspec、package.json、`SHA256SUMS`）为 UTF-8 **无 BOM**；`.iss` 必须保留 BOM。
  - 环境变量：`WB_FLUTTER`（flutter 路径）、`WB_CMAKE`（cmake 路径）、`WB_CORE_DLL`（部署源覆盖）、`EMSDK`、`WB_SIGN_CERT` / `WB_SIGN_PASSWORD` / `WB_SIGNTOOL`；测试侧 `WB_REQUIRE_CORE_DLL`（见 18）。
  - 产物路径契约：`build\windows-x64\bin\Release\wb_core.dll`、`apps\desktop\build\windows\x64\runner\Release\`、`apps\web\build\web\`、`build\wasm\dist\`、`dist\`（安装包与 `SHA256SUMS`）。
- **被依赖**：18（测试链引用 DLL / 基准 / 应用产物路径）；11/12（构建与部署检查）；07/10（`wb_core.dll` / `wb_core.js` 加载链）；13–16（CI 测试接线）；发布消费方（`dist` 制品 + 校验和）。
- **依赖**：CMake ≥ 3.25 + VS2022；Flutter SDK；Emscripten / signtool+证书 / Inno Setup 6 / Docker（均可选，缺失时优雅跳过）。
- **已知契约事实（回归依据）**：`version_sync -Check` 检查 20 文件；`checksum` 输出格式 `<hash> *<name>`；`build_all` 5 步顺序且"任一步失败中止"；CI desktop-tests 必须先构建 DLL 且不可绕过 `WB_REQUIRE_CORE_DLL=1`；release 由 tag `v*` 触发、web job 串行于 windows。

## 4. 常用命令

```powershell
# 一键完整构建（C++ + Windows 应用 + Web；无 EMSDK 自动跳过 WASM）
tools\scripts\build_all.ps1
tools\scripts\build_all.ps1 -SkipWindows -SkipWasm -RunCppTests   # 只 C++（含 ctest）+ Web

# 分步
tools\scripts\build_cpp.ps1 -RunTests
tools\scripts\build_flutter.ps1 -Target windows
tools\scripts\build_flutter.ps1 -Target web -Wasm

# 发布前检查链（版本 → 产物 → 校验和 → 签名）
tools\scripts\version_sync.ps1 -Check
iscc tools\packaging\windows\inno_setup_x64.iss
tools\scripts\checksum.ps1 -Path dist -PerFile
tools\scripts\sign_windows.ps1 -Strict
```

## 5. 变更影响提醒（改本模块时注意）

- 改 `build_cpp.ps1` / `CMakePresets.json` → 波及 **01–06**（C++ 构建入口）与 **07/11**（DLL 加载）：必须全量 ctest（199）并跑 `WB_REQUIRE_CORE_DLL=1` 的 FFI 集成（18 的强校验链）。
- 改 `build_flutter.ps1` → 产物路径被 **11/12** 部署检查与 `build.yml` 校验步骤依赖；`Release` 目录名或 `build\web` 布局变化会直接打穿 CI 产物校验。
- 改 `version_sync.ps1` 扫描集合 → 与"20 文件清单"联动（新增子包 pubspec 自动纳入）；改根 `VERSION` → 全仓版本级变更（安装包文件名、web `--build-name`、`.iss` 的 `AppVersion/OutputBaseFilename` 需同步）。
- 改 `checksum.ps1` 输出格式 / `sign_windows.ps1` 跳过语义 → **release.yml** 消费方（`SHA256SUMS`、`-Strict` 签名步骤）与制品分发流程。
- 改 `.github/workflows/*` → 影响全仓 CI 入口（每个模块的验证链路都从这里触发）；**禁止移除 `WB_REQUIRE_CORE_DLL=1`**（否则 FFI 集成会被静默跳过，形成假绿）。
- 根 `CMakeLists.txt` / `CMakePresets.json` 属**契约冻结层**：任何修改先评估全仓影响（生成器版本、cache 变量默认值、preset 命名）。
