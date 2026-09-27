# tests/e2e —— 端到端测试（《Flutter + C++ 工程结构设计》§12.3）

独立 Flutter 测试包：以 `flutter_test` 驱动 `apps/desktop` 的**完整应用入口**
（`WhiteboardApp` + 演示模式 FFI 降级路径），覆盖 §12.3 规定的四条流程：

| 文件 | 流程 |
|---|---|
| `create_board_test.dart` | 新建白板：首页 → 编辑页 → 返回列表（最近白板累积） |
| `create_element_test.dart` | 画布工具创建便签 → 内联输入 → Esc 提交 → 撤销 |
| `ai_flow_test.dart` | AI 面板发送消息（未配置提供商降级提示）→ 面板收展 |
| `page_management_test.dart` | 侧栏新建页面 → 卡片 +1 → 切回第一页 |

## 运行

```powershell
Set-Location tests/e2e
flutter pub get
flutter test                          # 推荐：扫描 test/ 目录（4 个转发入口）
flutter test create_board_test.dart   # 单文件直跑（实现文件在包根）
flutter test .                        # 备选：直跑根目录实现（会与 test/ 转发文件重复执行）
```

## 结构说明

- `flutter` 工具的 `flutter test`（不带参数）只递归扫描**包内 `test/` 子目录**，
  因此 §12.3 规定的 4 个实现文件放在本包根目录，`test/` 下放置同名转发入口
  （`import '../xxx_test.dart'; void main() => impl.main();`），两处一一对应。
- `support/e2e_support.dart`：共用脚手架（1600x1000 视口、演示模式 FFI、
  首页/编辑页启动），与 `apps/desktop/test` 的 widget 测试同一策略。
- 与 `apps/desktop/integration_test/`（设备端）的流程对齐；本包的优势是
  **无需设备**，`flutter test` 在 Windows VM 直接全绿。
- FFI 为演示模式（DLL 候选路径必然失败）——真实 `wb_core.dll` 的执行覆盖在
  `apps/desktop/test/integration/`（ffi_*_test.dart）。
