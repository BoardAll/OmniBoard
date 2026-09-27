# 08 · dart-ui —— Dart UI 基础库

> 模块路径：`packages/{ui_kit, icons, theme, ui, fonts}`
> 维护 agent：`wb-dart-ui-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：Flutter 侧纯 UI 基础库——设计 token 与原子组件（ui_kit）、多风格语义图标集（icons）、主题系统（theme：完整主题模型 / token / 9 个内置主题 / JSON 加载器 / 管理器 / 主题包）。
- **不负责**：业务组件与页面装配（→ [11-app-desktop](11-app-desktop.md)）；引擎主题域的 FFI 调用与 `WbThemeSpec` 原始 JSON 读取（→ [07-dart-core](07-dart-core.md)）；服务端主题/背景接口（→ [13-svc-api](13-svc-api.md)）。
- **占位包（如实标注）**：`packages/ui` 与 `packages/fonts` 当前**仅有 `pubspec.yaml`**（名称与 path 依赖已固化），尚无 `lib/` 实现或资产；使用前不得假定存在公开 API。
- **依赖方向**：`icons ← ui_kit ← theme`（path 依赖链，无循环）。

## 2. 功能 → 文件映射

### 2.1 ui_kit —— 基础组件库（38 用例）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 入口导出面 | `packages/ui_kit/lib/ui_kit.dart` | —（全部 ui_kit 测试经入口导入） |
| foundation 设计 token：colors / spacing（4pt 网格）/ radius / elevation / duration / typography | `packages/ui_kit/lib/foundation/{colors,spacing,radius,elevation,duration,typography}.dart` | `packages/ui_kit/test/foundation_test.dart`（12 用例） |
| 纯函数工具：颜色 / 文本 / 布局几何 | `packages/ui_kit/lib/utils/{color_utils,text_utils,layout_utils}.dart` | `packages/ui_kit/test/utils_test.dart`（16 用例） |
| 原子组件：avatar / badge / divider / icon / image / progress / skeleton / text | `packages/ui_kit/lib/widgets/{avatar,badge,divider,icon,image,progress,skeleton,text}.dart` | `packages/ui_kit/test/widgets_test.dart`（10 用例） |

### 2.2 icons —— 图标库（9 用例）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 入口与风格枚举（`WbIconStyle`） | `packages/icons/lib/icons.dart` | `packages/icons/test/icons_test.dart`（9 用例） |
| 5 种风格图标集：linear（默认，outlined 变体）/ filled / minimal（rounded 变体）/ pixel / hand_drawn | `packages/icons/lib/{linear,filled,minimal,pixel,hand_drawn}/*.dart`（5 文件） | 同上（风格与图标集完整性组） |

### 2.3 theme —— 主题系统（9 个内置主题，10 用例）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 入口（模型 + token + 9 内置主题 + 加载器 + 管理器聚合） | `packages/theme/lib/theme.dart` | `packages/theme/test/theme_test.dart` |
| 完整主题模型（与 C++ theme 域 `BuildTheme` 输出结构对齐） | `packages/theme/lib/theme_data.dart` | 同上（JSON 往返组） |
| 主题 JSON 加载器 | `packages/theme/lib/theme_loader.dart` | 同上 |
| 主题管理器（持有当前主题 / 切换 / 注册自定义主题与主题包 / 通知监听者） | `packages/theme/lib/theme_manager.dart` | 同上（主题管理器组 + Flutter 集成组） |
| 主题包（一个包可携带多个主题） | `packages/theme/lib/theme_pack.dart` | 同上 |
| 颜色 token（与 C++ theme 域 `colors` 映射一一对应） | `packages/theme/lib/theme_tokens.dart` | 同上 |
| 9 个内置主题：clean_professional（默认）/ dark_night / blackboard / greenboard / minimal / hand_drawn / cyberpunk（C++ id 为 `cyber`）/ kids / enterprise | `packages/theme/lib/builtin/*.dart`（9 文件） | 同上（内置主题组） |

### 2.4 占位包（尚无实现）

| 包 | 现状 | 测试 |
|---|---|---|
| `packages/ui`（`whiteboard_ui`） | **占位包：仅 `packages/ui/pubspec.yaml`**（path 依赖 ui_kit/theme/icons/core_dart，均未使用）；无 `lib/` | — |
| `packages/fonts`（`whiteboard_fonts`） | **占位包：仅 `packages/fonts/pubspec.yaml`**；无 `lib/`、无字体资产 | — |

## 3. 契约与依赖

- **依赖**：`ui_kit` → `icons`（path）；`theme` → `ui_kit`（path）；`ui` → ui_kit/theme/icons/core_dart（path，占位未用）；`fonts` 仅 flutter sdk。
- **被依赖**：11 app-desktop（`whiteboard_ui_kit`、`whiteboard_theme`、`whiteboard_icons`、`whiteboard_ui` 四包均在 `pubspec.yaml` 中直接声明）。
- **已知契约事实（回归依据）**：
  - theme 9 个内置主题与 C++ `kThemes` 一一对齐（每个 builtin 文件头注释标注对应 `kThemes[i]`，修改时两边保持一致）；
  - `icons` 默认风格为 linear；`ui_kit` 不含任何业务逻辑（组件库定位）；
  - 测试规模：ui_kit 38 + icons 9 + theme 10 = **57 个用例**，全部离线运行（不依赖 `wb_core.dll`）。
- **上游设计文档**：`docs/主题与背景系统设计.md`、`docs/Flutter + C++ 工程结构设计.md`。

## 4. 常用命令

```powershell
# 三个包各自独立测试（进入各自目录）
Set-Location packages\ui_kit; E:\code\flutter-sdk\flutter\bin\flutter.bat pub get; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub
Set-Location ..\icons; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub
Set-Location ..\theme; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub

# 全仓静态分析（在仓库根）
E:\code\flutter-sdk\flutter\bin\flutter.bat analyze
```

## 5. 变更影响提醒（改本模块时注意）

- 改 `theme_tokens` / `theme_data` / 9 个内置主题 → 影响 **11** 的 `lib/state/theme_state.dart`、`lib/widgets/settings/theme_selector.dart` 与主题切换测试（`settings_deep_test.dart`、`integration_test/theme_test.dart`）。
- 改 `ui_kit` foundation / 组件签名 → 影响 **11** 的大量 widgets（编译期暴露，需全量 `flutter analyze` + `flutter test`）。
- 改 `icons` 风格映射或图标名 → 检查 11 的引用点（如 `lib/widgets/guide/guide_icons.dart`）。
- 与 C++ 主题域（03-core-render 的 theme 部分）对齐关系：id 与颜色映射需两边同步修改，改后建议跑 11 的 FFI 集成（真实 DLL）核对 `wb_theme_list` 输出。
- `packages/ui` 从占位升级为实现时：先更新本文档 2.4 的"占位包"标注与 11 的装配说明，再落地代码。
