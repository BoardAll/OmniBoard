# 性能测试（tests/perf）

本目录把《测试方案设计》§10.4 的三条性能测试命令串成一条可执行流水线：

| 步骤 | 对应命令（§10.4） | 本仓库 Windows 形态 |
| --- | --- | --- |
| 1. C++ 基准 | `./build/linux-x64/benchmarks/wb_benchmarks` | `build/windows-x64/bin/Release/wb_benchmarks.exe` |
| 2. Flutter 性能 | `flutter test --profile integration_test/perf_test.dart` | `flutter test --profile integration_test/app_test.dart`（perf_test.dart 尚未创建，暂以应用流冒烟代替，可用 `-FlutterTarget` 覆盖） |
| 3. Web 性能 | `lighthouse http://localhost:8080 --output=json --output-path=./lighthouse.json` | 同左；需先启动 `apps/web` 的开发服务器（`flutter run -d web-server --web-port 8080`），本机未安装 Lighthouse 时自动跳过 |

## 用法

```powershell
# 完整执行（各步骤缺失工具时自动跳过并给出指引）
pwsh -File tests/perf/run_perf.ps1

# 只打印将要执行的命令，不真正执行
pwsh -File tests/perf/run_perf.ps1 -DryRun

# 指定 Flutter 目标（如真实 perf_test.dart 就绪后）
pwsh -File tests/perf/run_perf.ps1 -FlutterTarget integration_test/perf_test.dart
```

可选开关：`-SkipCpp`、`-SkipFlutter`、`-SkipWeb` 单独跳过对应步骤；
`-Strict` 让"跳过"也视为失败（CI 用）。Flutter 可执行文件可用环境变量
`WB_FLUTTER` 覆盖，默认按 `flutter`（PATH）→ `E:\code\flutter-sdk\flutter\bin\flutter.bat` 顺序探测。

## 产物

运行后日志写入 `tests/perf/out/`（该目录为运行时生成，未纳入版本控制结构）：

- `out/benchmarks.log`：C++ 基准原始输出
- `out/lighthouse.json`：Web 性能报告

## 环境说明

- C++ 基准需先用 `cmake --preset windows-x64 -DWB_BUILD_BENCHMARKS=ON` 构建；
  产物缺失时脚本给出上条构建指引并跳过。
- Flutter 步骤在本机单独跑单个 integration_test 文件可行；批量目录运行存在
  设备侧限制（多文件连续启动会报 "Unable to start the app on the device"），
  故默认只跑 `app_test.dart`。
- Web 步骤依赖外部 Lighthouse CLI 与本地服务器，缺一即跳过（非失败）。
