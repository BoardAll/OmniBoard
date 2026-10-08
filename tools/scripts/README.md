# tools/scripts — 构建脚本族

Windows-first 的构建/打包/发布辅助脚本（PowerShell 5.1+），实现
`docs/构建打包与发布设计.md` §6–§16：C++ 核心、Flutter 桌面/Web、WASM、
签名、版本同步与校验和。

> 约定：所有脚本的退出码 **0 = 成功（或按设计优雅跳过）**，**1 = 失败**。
> 脚本只读取/写入 `build\` 与产物目录，从不删除既有文件。

## 脚本总览

| 脚本 | 用途 | 本机（Windows 22H2）最近验证 |
| --- | --- | --- |
| `build_all.ps1` | 一键编排：C++ → Windows 应用 → Web → WASM → 校验和 | 完整 5 步运行 EXIT=0 |
| `build_cpp.ps1` | CMake preset `windows-x64` 构建 `wb_core.dll`（可跑 ctest） | 构建 OK；`-RunTests` 199/199 通过 |
| `build_flutter.ps1` | `flutter build windows/web --release` | 两者均构建成功 |
| `build_wasm.ps1` | Emscripten WASM 核心（`emcmake` + `wasm` preset） | 真实构建验证 EXIT=0（2026-10-01，emsdk 3.1.74；`-CopyToWebAssets` 复制到 `apps\web\web\`） |
| `sign_windows.ps1` | signtool Authenticode 签名（dist + runner 产物） | 本机无证书 → 跳过 EXIT=0 |
| `version_sync.ps1` | 版本一致性校验/更新（根 `VERSION` 为唯一事实源） | `-Check`：20 个文件 0 不一致 |
| `checksum.ps1` | 生成 `SHA256SUMS`（`<hash> *<name>` 格式 + 自校验） | 生成/自校验 PASS |
| `setup_flutter_sdk.ps1` | （既有脚本，本包未修改）Flutter SDK 下载引导 | — |

## 快速开始

```powershell
# 一键完整构建（C++ + Windows 应用 + Web；无 EMSDK 时自动跳过 WASM）
tools\scripts\build_all.ps1

# 常用开关组合
tools\scripts\build_all.ps1 -SkipWindows -SkipWasm -RunCppTests   # 只 C++(+ctest) + Web
tools\scripts\build_all.ps1 -SkipCpp -SkipWeb -SkipWasm           # 只 Windows 应用
tools\scripts\build_all.ps1 -WebWasm                              # Web 用 dart2wasm

# 分步执行
tools\scripts\build_cpp.ps1 -RunTests
tools\scripts\build_flutter.ps1 -Target windows
tools\scripts\build_flutter.ps1 -Target web
```

若出现“禁止运行脚本”（执行策略）提示：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

## 各脚本说明

### build_all.ps1（编排器）

步骤：**1** C++ 核心 → **2** Windows 应用（含 exe + `wb_core.dll` 部署检查）→
**3** Web 应用 → **4** WASM（无 EMSDK 优雅跳过）→ **5** 校验和（仅当 `dist\` 存在）。
任一步失败立即中止并给出清晰错误。

| 参数 | 说明 |
| --- | --- |
| `-SkipCpp` `-SkipWindows` `-SkipWeb` `-SkipWasm` `-SkipChecksum` | 跳过对应步骤 |
| `-RunCppTests` | 传给 `build_cpp.ps1 -RunTests`（ctest） |
| `-WebWasm` | Web 用 `--wasm`（dart2wasm）构建 |
| `-NoSymlinkFallback` | 禁用 Windows 插件 junction 回退（见下文） |
| `-FlutterPath` `-CmakePath` | 显式指定 flutter(.bat) / cmake.exe |

### build_cpp.ps1

| 参数 | 说明 |
| --- | --- |
| `-Preset windows-x64` | CMakePresets.json 中的 configure preset（默认 windows-x64） |
| `-Config Release\|Debug` | 构建配置 |
| `-RunTests` | 构建后跑 ctest（test preset 优先，否则 `ctest --test-dir ... -C`） |
| `-Fresh` | `cmake --preset ... --fresh`（CMake ≥ 3.24） |
| `-CmakePath` / `-SourceDir` | 显式 cmake.exe / 仓库根 |

产物：`build\windows-x64\bin\Release\wb_core.dll`；
Flutter 构建时由 `apps/desktop/windows/CMakeLists.txt` 的
`wb_core_dll_deploy` 目标自动拷到 exe 旁（可用环境变量 `WB_CORE_DLL` 覆盖源路径）。

### build_flutter.ps1

| 参数 | 说明 |
| --- | --- |
| `-Target windows\|web` | 目标应用（`apps/desktop` / `apps/web`） |
| `-BuildName` `-BuildNumber` | 仅 Web：`--build-name/--build-number`（默认读根 `VERSION`） |
| `-Wasm` | 仅 Web：`--wasm` |
| `-NoSymlinkFallback` | 不预创建 junction 回退 |
| `-ExtraArgs ...` | 追加参数原样传给 `flutter build` |

注意：
* Windows 构建需要插件 symlink（`windows\flutter\ephemeral\.plugin_symlinks`）。
  未开启开发者模式且未提权时，脚本检测到后自动创建 **NTFS junction 回退**
  （`mklink /J` 等价、无需权限），构建完成后可随时手工清理。
* 产物：`apps\desktop\build\windows\x64\runner\Release\whiteboard_desktop.exe`（+ `wb_core.dll`）；
  `apps\web\build\web\`（`index.html`、`main.dart.js`、`wb_core.js` 等）。

### build_wasm.ps1

| 参数 | 说明 |
| --- | --- |
| `-Strict` | 无 EMSDK 时改为失败（CI 可用） |
| `-OutputDir` | 产物收集目录（默认 `build\wasm\dist`） |
| `-CopyToWebAssets` | 可选：拷贝到 `apps\web\web\`（真实产物直接更新宿主资产；默认关闭） |
| `-CmakePath` | 显式 cmake.exe |

无 EMSDK 时打印安装指引并 **exit 0**（优雅跳过）。启用流程：
`git clone ...emsdk` → `emsdk.ps1 install/activate latest` → 每个新 shell 加载
`emsdk_env.ps1`（设置 `EMSDK`）→ 重跑脚本（内部走 `emcmake cmake --preset wasm` → `cmake --build --preset wasm-release`）。

### sign_windows.ps1

| 参数 | 说明 |
| --- | --- |
| `-Files` | 显式文件列表；缺省签 `dist\*.exe/.msi/.dll` + runner 的 exe/dll（存在的才签） |
| `-CertificatePath` `-CertificatePassword` | 缺省读 `WB_SIGN_CERT` / `WB_SIGN_PASSWORD` |
| `-CertHasNoPassword` | 无密码测试证书 |
| `-TimestampUrl` / `-NoTimestamp` | RFC3161 时间戳（默认 digicert）/ 离线跳过时间戳 |
| `-Strict` | 缺证书/signtool 时改为失败（CI 发布用） |
| `-SigntoolPath` | 显式 signtool.exe（缺省 `WB_SIGNTOOL` → PATH → Windows Kits 探测） |

未配置证书时打印配置指引并 exit 0（保持本地/CI 无密钥可用）。

### version_sync.ps1

| 模式 | 说明 |
| --- | --- |
| `-Check`（**默认**） | 只读校验：`VERSION` ↔ apps/packages/platform 的 pubspec、services 的 package.json、根/`core` 的 CMakeLists 版本一致性 |
| `-Write` | 按 `VERSION`（或 `-Version`）更新上述文件；`-BuildNumber` 控制 `+build`；`-SkipVersionFile`/`-SkipCmake` 可排除 |

不一致时 exit 1。发布前务必先 `-Check`。

### checksum.ps1

| 参数 | 说明 |
| --- | --- |
| `-Path dist` | 目标目录（默认 `dist`；不存在时打印提示 exit 0，`-Strict` 则 exit 1） |
| `-Output` | 输出文件（默认 `<Path>\SHA256SUMS`） |
| `-PerFile` | 另写每个产物旁的 `<name>.sha256` |
| `-Recurse` | 递归子目录 |
| `-Strict` | 目录缺失时失败 |

格式为标准 `sha256sum` 兼容的 `<sha256> *<filename>`（UTF-8 无 BOM），
写完自动自校验一次。

## 环境变量

| 变量 | 用途 |
| --- | --- |
| `WB_FLUTTER` | flutter(.bat) 路径（缺省 PATH → 仓库同级 `..\flutter-sdk`） |
| `WB_CMAKE` | cmake.exe 路径（缺省 PATH；ctest 从其同目录解析） |
| `WB_CORE_DLL` | 可选：覆盖 Flutter Windows 构建拷贝的 `wb_core.dll` 源路径 |
| `EMSDK` | Emscripten SDK 根（由 `emsdk_env` 设置），供 `build_wasm.ps1` |
| `WB_SIGN_CERT` / `WB_SIGN_PASSWORD` / `WB_SIGNTOOL` | 签名证书/密码/signtool 路径 |

## 环境依赖矩阵

| 工具 | 用于 | 本机状态 | 缺失时的行为 |
| --- | --- | --- | --- |
| CMake 3.20+（VS2022 generator） | build_cpp / build_wasm | 已有（`D:\Program Files\Cmake`） | build_cpp 报错提示安装或设 `WB_CMAKE` |
| Flutter SDK | build_flutter | 已有（`E:\code\flutter-sdk`） | 报错提示设 `WB_FLUTTER` 或加入 PATH |
| VS2022 + Windows SDK | C++ / Windows runner | 已有 | CMake 配置阶段报错 |
| Emscripten（EMSDK） | build_wasm | 已有（`E:\code\emsdk`，3.1.74） | 打印安装指引，exit 0（`-Strict` 时 exit 1） |
| signtool + 代码签名证书 | sign_windows | signtool 有 / 证书**无** | 打印配置指引，exit 0（`-Strict` 时 exit 1） |
| Inno Setup 6（iscc） | 安装包（见 `tools/packaging`） | **无** | 不涉及本目录脚本；未编译验证 |
| Docker | Web 镜像（见 `tools/packaging`） | **无** | 同上 |

## PowerShell 约定（重要）

1. **命名参数强制**：所有脚本声明 `[CmdletBinding(PositionalBinding = $false)]`，
   参数只能按名传递；位置形式调用会响亮报错。
2. **脚本间调用必须用哈希表 splat**：`$a = @{}; $a['RunTests'] = $true;
   & .\build_cpp.ps1 @a`。数组 splat（`@('-RunTests')`）会把元素按**位置**传给
   第一个位置参数（本仓库曾因此出现 `$Preset='-RunTests'` 的静默错绑）。
   数组 splat 仅用于**原生 exe**（flutter/cmake/signtool，argv 字符串不受影响）。
3. **编码**：自建 `.ps1` 均为 UTF-8 **带 BOM**（PowerShell 5.1 正确解读中文的最省事
   做法）；`version_sync`/`checksum` 写回的文本文件使用 UTF-8 无 BOM。
4. **异常安全**：脚本不删除文件；失败路径只报告并 exit 1。

## 与 CI 的关系

`.github/workflows/` 直接调用本目录脚本（全部命名参数）：

* `ci.yml`：`build_cpp.ps1 -RunTests`（windows job）。
* `build.yml`：`build_cpp.ps1` → `build_flutter.ps1 -Target windows`；web job 走
  `flutter build web`（WASM 步骤由仓库变量 `ENABLE_WASM_BUILD` 条件启用）。
* `release.yml`：tag 触发；`sign_windows.ps1 -Strict -NoTimestamp` 仅在配置了
  `WB_SIGN_CERT_B64` secret 时执行；`checksum.ps1 -Path dist -PerFile` 生成校验和。

## 本机已验证 / 未验证

**已实际运行验证**（Windows 22H2，2026-09-26）：`build_all.ps1` 完整 5 步 EXIT=0、
`build_cpp.ps1 -RunTests`（ctest 199/199）、`build_flutter.ps1` 双目标、
`build_wasm.ps1`/`sign_windows.ps1` 优雅跳过、`version_sync.ps1 -Check`（20 文件
0 不一致）、`checksum.ps1`（生成+自校验+缺失目录路径）。

**未验证**：`build_wasm.ps1` 的 EMSDK 真实构建路径（本机无 EMSDK）、
`sign_windows.ps1` 的真实签名路径（本机无证书）、macOS/Linux 相关流程（本机不可构建）。
