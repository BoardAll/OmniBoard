# tests/e2e —— 端到端测试（《Flutter + C++ 工程结构设计》§12.3）

独立 Flutter 测试包：以 `flutter_test` 驱动 `apps/desktop` 的**完整应用入口**
（`WhiteboardApp` + 演示模式 FFI 降级路径），覆盖 §12.3 规定的四条流程，
并承载 M1「双端互见」场景骨架（编排脚本见下）：

| 文件 | 流程 |
|---|---|
| `create_board_test.dart` | 新建白板：首页 → 编辑页 → 返回列表（最近白板累积） |
| `create_element_test.dart` | 画布工具创建便签 → 内联输入 → Esc 提交 → 撤销（显式切顶部工具栏风格） |
| `ai_flow_test.dart` | AI 面板发送消息（未配置提供商降级提示）→ 面板收展 |
| `page_management_test.dart` | 侧栏新建页面 → 卡片 +1 → 切回第一页 |
| `collab_dual_end_test.dart` | M1 场景骨架：复用资产存在性（双进程用例 / Web 冒烟 / 场景脚本）+ `fixture/boards` 可解析；恒可运行（无外部依赖） |

## 运行

```powershell
Set-Location tests/e2e
flutter pub get
flutter test                          # 推荐：扫描 test/ 目录（5 个转发入口）
flutter test create_board_test.dart   # 单文件直跑（实现文件在包根）
flutter test .                        # 备选：直跑根目录实现（会与 test/ 转发文件重复执行）
```

### M1「双端互见」场景编排（四段可独立执行）

前置：Node ≥ 18、`services/realtime` 已 `npm run build`；`desktop` 段另需
`wb_core.dll` 已构建（`tools\scripts\build_cpp.ps1`）；`web` 段需 Chrome/Edge
（缺失自动 SKIP）。脚本支持任意 cwd，端口默认 8790（`WB_E2E_PORT` 可覆盖）：

```powershell
node tests/e2e/support/run_collab_dual_end.mjs                    # 全量四段：server → desktop → ops → web
node tests/e2e/support/run_collab_dual_end.mjs --only=server,ops  # 无 GUI 环境：只跑服务端 + 契约探针
node tests/e2e/support/run_collab_dual_end.mjs --only=web --reuse-server
node tests/e2e/support/run_collab_dual_end.mjs --list             # 段说明
```

- 段职责：`server` = 起 realtime（:8790）+ 健康检查；`desktop` = 参与者 ×2
  双进程真连（T1.6 等价物：A 发 B 收闭环）；`ops` = 契约级探针（插入/移动/删除
  op 矩阵 + 断线重连恢复）；`web` = 参与者 ×1 浏览器冒烟（W1 成员/状态互见）。
- 退出码：0 = 全部执行段 PASS（SKIP 允许）；1 = 任意段 FAIL。
- 详见 `docs/modules/18-qa-testing.md` §2.2 / §2.7。

## 结构说明

- `flutter` 工具的 `flutter test`（不带参数）只递归扫描**包内 `test/` 子目录**，
  因此 §12.3 规定的 4 个应用流实现文件 + M1 场景骨架（共 5 个）放在本包根目录，
  `test/` 下放置同名转发入口（`import '../xxx_test.dart'; void main() => impl.main();`），
  两处一一对应。
- `support/e2e_support.dart`：共用脚手架（1600x1000 视口、演示模式 FFI、
  首页/编辑页启动；`pumpApp/pumpEditor` 返回 `WbThemeState` 供用例声明外观），
  与 `apps/desktop/test` 的 widget 测试同一策略。
- `support/run_collab_dual_end.mjs` + `support/wb_collab_scenario_probe.mjs`：
  M1 场景编排与契约级探针（复用 T1.6 双进程资产与 T1.8 Web 冒烟）。
- 与 `apps/desktop/integration_test/`（设备端）的流程对齐；本包的优势是
  **无需设备**，`flutter test` 在 Windows VM 直接全绿。
- FFI 为演示模式（DLL 候选路径必然失败）——真实 `wb_core.dll` 的执行覆盖在
  `apps/desktop/test/integration/`（ffi_*_test.dart）。
