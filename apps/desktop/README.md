# Whiteboard Desktop

白板桌面应用（Flutter UI + C++ 核心引擎 FFI），支持 Windows / macOS / Linux 宿主。

- 入口：`lib/main.dart`（`WhiteboardApp`）
- 测试：`flutter test`（widget/单元）；`flutter test integration_test/`（端到端）
- 构建：`flutter build windows --release`（由 `tools/scripts/build_all.ps1` 一键编排，自动随包部署 `wb_core.dll`）
