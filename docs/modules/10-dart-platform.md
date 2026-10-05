# 10 · dart-platform —— 平台插件包

> 模块路径：`platform/{windows,macos,linux,web}`（`platform/{android,ios}` 为空目录，预留）
> 维护 agent：`wb-dart-platform-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：四个平台插件包（`whiteboard_windows` / `whiteboard_macos` / `whiteboard_linux` / `whiteboard_web_platform`）的 Dart 包装层与原生实现：
  - **Windows**（`platform/windows`）：Dart MethodChannel 层（通道 `whiteboard/windows`，`window.*` / `dialog.*` / `shortcut.*` / `tray.*` / `capture.*` 方法）+ C++/Win32 原生（窗口管理、透明覆盖层 `WS_EX_LAYERED|WS_EX_TRANSPARENT`、`RegisterHotKey` 快捷键、`Shell_NotifyIcon` 托盘、GDI `BitBlt` 屏幕捕获、D3D11 纹理共享骨架）。
  - **macOS**（`platform/macos`）：Dart 镜像层（通道 `whiteboard/macos`）+ Objective-C++ 原生（CocoaPods podspec + `Classes/*.mm`；Carbon 热键 / NSWindow / NSStatusItem / CGDisplay）。
  - **Linux**（`platform/linux`，`ffiPlugin: true`）：无 MethodChannel；dart:ffi 直调 `libwhiteboard_linux.so` + `NativeCallable.listener` 回调 + 库缺失全链路降级；C++ 原生（X11 / Wayland 双路径）。
  - **Web**（`platform/web`）：`pluginClass` + 条件导入（`whiteboard_web_platform.dart`、`wb_core_loader.dart`、`wb_core_bindings.dart`、`web_window.dart`；`web/wb_core.js` 为占位脚本，宿主可覆盖为真实产物——`apps/web` 已接入真实 Emscripten 产物）。
- **不负责**：引擎 C++ 核心与 C ABI 契约（→ [01-core-foundation](01-core-foundation.md)）；Dart FFI 封装包（→ [07-dart-core](07-dart-core.md)）；UI 基础库（→ [08-dart-ui](08-dart-ui.md)）；应用层装配与平台服务适配（→ [11-app-desktop](11-app-desktop.md) / [12-app-web](12-app-web.md)）。
- **地位**：平台能力适配层（桌面三平台 + Web）；被 11 号应用以 path 依赖使用（Windows 插件已随 `apps/desktop` 构建链自动注册），被 12 号应用用于 WASM 加载与全屏能力。
- **预留**：`platform/android`、`platform/ios` 为空目录（移动端插件预留，未实现）。
- **已知状态（如实记录）**：macOS / Linux 原生代码无法在 Windows 开发机编译——**代码交付，待对应平台 CI 验证**；Windows 原生已接入宿主 `apps/desktop` 的 Flutter 插件注册链（`generated_plugins.cmake` / `generated_plugin_registrant.cc`）；Web WASM 加载链已以真实 Emscripten 产物端到端验证（2026-10-01，宿主 `apps/web` 就绪态可绘制；`platform/web/web/wb_core.js` 自身仍为占位示例，由宿主覆盖）。

## 2. 功能 → 文件映射

### 2.1 Windows —— Dart 通道层（`whiteboard_windows`）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 包入口与四组插件导出 | `platform/windows/lib/whiteboard_windows.dart` | `platform/windows/test/windows_platform_test.dart`（17 用例） |
| 窗口能力：`window.setTransparent`（仅原生 true 为成功，返回 `Future<bool>`）/ `setAlwaysOnTop` / `setIgnoreMouseEvents`（含 `forward`）/ `setFullscreen` / `setPosition` / `setSize` | `platform/windows/lib/src/wb_window_plugin.dart` | 同上 |
| 文件对话框：`dialog.openImage` / `dialog.openBoard`（无参）→ 绝对路径 / null；`dialog.saveBoard`（`suggestedPath` 作为预填建议路径）→ 绝对路径 / null | 同上 | 同上 |
| 全局快捷键：`shortcut.register` / `unregister` / `unregisterAll` + `shortcut.triggered` 事件流 | `platform/windows/lib/src/wb_shortcut_plugin.dart` | 同上 |
| 托盘：`tray.setIcon` / `setTooltip` / `setMenu`（`WbTrayMenuItem` 序列化）+ `tray.clicked` 事件流 | `platform/windows/lib/src/wb_tray_plugin.dart` | 同上 |
| 屏幕捕获：`capture.captureDisplay` / `capture.captureVirtualScreen` / `capture.isAvailable`（`WbCaptureFrame`，BGRA） | `platform/windows/lib/src/wb_screen_capture.dart` | 同上 |

### 2.2 Windows —— C++/Win32 原生（`platform/windows/windows/`）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 插件注册与通道分发（`WhiteboardWindowsPluginRegisterWithRegistrar`、方法路由、事件回发） | `platform/windows/windows/whiteboard_windows_plugin.cpp`、`platform/windows/windows/include/whiteboard_windows/whiteboard_windows_plugin.h` | 构建验证：`flutter build windows`（见 §4） |
| 内部共享头（编码工具、加速键解析、UiTaskRunner、插件类声明） | `platform/windows/windows/include/window_plugin.h` | —（随 Dart 测试间接覆盖契约） |
| 窗口与对话框实现（`window.*`；`dialog.openImage` / `dialog.openBoard` 共用 `GetOpenFileNameW`（filter `*.wbd`、`OFN_FILEMUSTEXIST|OFN_PATHMUSTEXIST|OFN_EXPLORER|OFN_NOCHANGEDIR`）；`dialog.saveBoard` 走 `GetSaveFileNameW`（`lpstrDefExt=wbd`、`OFN_OVERWRITEPROMPT`、预填建议全路径）；兜底顶层窗口查找） | `platform/windows/windows/src/window_plugin.cpp` | — |
| 透明覆盖层（`SetWindowCompositionAttribute` 强调色、`WS_EX_TRANSPARENT` 切换、`forward` 轮询伪造 `WM_MOUSEMOVE`） | `platform/windows/windows/src/transparent_overlay.cpp` | — |
| 全局快捷键（`RegisterHotKey` + 插件私有消息窗口转发 `WM_HOTKEY`） | `platform/windows/windows/src/shortcut_plugin.cpp` | — |
| 托盘（`Shell_NotifyIconW` + `TrackPopupMenu` + `TaskbarCreated` 重建） | `platform/windows/windows/src/tray_plugin.cpp` | — |
| 屏幕捕获（`EnumDisplayMonitors` + `BitBlt`、`WDA_EXCLUDEFROMCAPTURE` 排除自身窗口） | `platform/windows/windows/src/screen_capture.cpp` | — |
| D3D11 纹理共享骨架（占位，恒不支持，未接通道） | `platform/windows/windows/src/texture_share.cpp` | — |
| CMake 构建定义（`PLUGIN_NAME=whiteboard_windows_plugin`、C++20、链接 user32/shell32/gdi32/comdlg32） | `platform/windows/windows/CMakeLists.txt` | — |

### 2.3 macOS —— Dart 镜像层（`whiteboard_macos`）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 包入口与四组插件导出 | `platform/macos/lib/whiteboard_macos.dart` | `platform/macos/test/macos_platform_test.dart`（12 用例） |
| 窗口能力：`window.setTransparent`（`Future<void>`）/ `setAlwaysOnTop` / `setIgnoreMouseEvents`（`forward` 按"尽力"处理）/ `setFullscreen` / `setPosition` / `setSize` | `platform/macos/lib/src/wb_window_plugin.dart` | 同上 |
| 全局快捷键：`shortcut.register` / `unregister` / `unregisterAll` + `shortcut.triggered` 事件流 | `platform/macos/lib/src/wb_shortcut_plugin.dart` | 同上 |
| 托盘：`tray.setIcon` / `setTooltip` / `setMenu` + `tray.clicked` 事件流 | `platform/macos/lib/src/wb_tray_plugin.dart` | 同上 |
| 屏幕捕获：`capture.captureDisplay` / `capture.isAvailable`（`WbCaptureFrame`） | `platform/macos/lib/src/wb_screen_capture.dart` | 同上 |

### 2.4 macOS —— Objective-C++ 原生（`platform/macos/macos/`）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 插件入口（通道 `whiteboard/macos` 注册与方法分发） | `platform/macos/macos/Classes/WhiteboardMacosPlugin.h`、`platform/macos/macos/Classes/WhiteboardMacosPlugin.mm` | 待 macOS CI 验证（本机不构建） |
| 窗口（`NSScreenSaverWindowLevel` 置顶、frame 定位尺寸） | `platform/macos/macos/Classes/WindowPlugin.h`、`platform/macos/macos/Classes/WindowPlugin.mm` | 同上 |
| 透明覆盖层（borderless + NonactivatingPanel、`CanJoinAllSpaces\|FullScreenAuxiliary\|Stationary`） | `platform/macos/macos/Classes/TransparentOverlay.h`、`platform/macos/macos/Classes/TransparentOverlay.mm` | 同上 |
| 全局快捷键（Carbon `RegisterEventHotKey`，`'wbht'` FourCC 过滤） | `platform/macos/macos/Classes/ShortcutPlugin.h`、`platform/macos/macos/Classes/ShortcutPlugin.mm` | 同上 |
| 托盘（`NSStatusItem` + `NSMenu` + `representedObject` 回传 id） | `platform/macos/macos/Classes/TrayPlugin.h`、`platform/macos/macos/Classes/TrayPlugin.mm` | 同上 |
| 屏幕捕获（`CGGetActiveDisplayList` + `CGDisplayCreateImage` → BGRA → `FlutterStandardTypedData`） | `platform/macos/macos/Classes/ScreenCapture.h`、`platform/macos/macos/Classes/ScreenCapture.mm` | 同上 |
| 纹理共享骨架（IOSurface 占位） | `platform/macos/macos/Classes/TextureShare.h`、`platform/macos/macos/Classes/TextureShare.mm` | 同上 |
| CocoaPods 打包定义（`Classes/**/*` 源文件、FlutterMacOS 依赖） | `platform/macos/macos/whiteboard_macos.podspec` | — |

### 2.5 Linux —— Dart FFI 直调层（`whiteboard_linux`）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 包入口与七组模块导出（无 MethodChannel） | `platform/linux/lib/whiteboard_linux.dart` | `platform/linux/test/linux_platform_test.dart`（19 用例） |
| 动态库加载（候选名 `libwhiteboard_linux.so` / `libwhiteboard_linux_plugin.so`；缺失返回 null） | `platform/linux/lib/src/wb_native_library.dart` | 同上 |
| dart:ffi 绑定（函数类型对、`WbStatus` 状态码 0/1/2、8 个符号查找辅助，失败返回 null 不抛异常） | `platform/linux/lib/src/wb_ffi_bindings.dart` | 同上 |
| 快捷键加速器解析（`WbAccelerator` 归一化） | `platform/linux/lib/src/wb_accelerator.dart` | 同上 |
| 窗口插件（直调 `wb_linux_window_*`；X11 全能力 / Wayland best-effort） | `platform/linux/lib/src/wb_window_plugin.dart` | 同上 |
| 快捷键插件（`NativeCallable.listener` 跨线程回调 → broadcast 流） | `platform/linux/lib/src/wb_shortcut_plugin.dart` | 同上 |
| 托盘插件（`WbTrayMenuItem` 序列化 + 点击回调流） | `platform/linux/lib/src/wb_tray_plugin.dart` | 同上 |
| 屏幕捕获（`WbCaptureFrame`；库缺失返回 null） | `platform/linux/lib/src/wb_screen_capture.dart` | 同上 |

### 2.6 Linux —— C++ 原生（`platform/linux/linux/`，X11/Wayland 双路径）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 扁平 C API（17 个导出符号；`WB_OK` / `WB_ERR_UNSUPPORTED` / `WB_ERR_FAILED`） | `platform/linux/linux/include/window_plugin.h` | 待 Linux CI 验证（本机不构建） |
| 窗口与后端探测（X11/Wayland 会话判定、GTK 探测、X11/GTK 符号表运行时 dlopen） | `platform/linux/linux/src/window_plugin.cpp` | 同上 |
| 透明覆盖层 X11（`_NET_WM_WINDOW_TYPE_DOCK`、`_NET_WM_STATE_ABOVE`、XShape 输入区域、EWMH） | `platform/linux/linux/src/transparent_overlay_x11.cpp` | 同上 |
| 透明覆盖层 Wayland（`wl_compositor` input region 等 best-effort 路径） | `platform/linux/linux/src/transparent_overlay_wayland.cpp` | 同上 |
| 全局快捷键（`XGrabKey` 含 CapsLock/NumLock 变体；Wayland 返回 `WB_ERR_UNSUPPORTED` 降级应用内快捷键） | `platform/linux/linux/src/shortcut_plugin.cpp` | 同上 |
| 托盘（AppIndicator 运行时 dlopen，失败降级 GtkStatusIcon） | `platform/linux/linux/src/tray_plugin.cpp` | 同上 |
| 屏幕捕获（X11 `XGetImage`；Wayland 返回不支持） | `platform/linux/linux/src/screen_capture.cpp` | 同上 |
| CMake 构建定义（目标产出 `libwhiteboard_linux.so`；X11/Wayland/GTK3 可选探测→stub；无链接期依赖） | `platform/linux/linux/CMakeLists.txt` | 同上 |

### 2.7 Web（`whiteboard_web_platform`）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 插件入口（`WhiteboardWebPlatform.registerWith` 空实现——Web 无原生侧；条件导入注册器） | `platform/web/lib/whiteboard_web_platform.dart`、`platform/web/lib/src/registrar_web.dart`、`platform/web/lib/src/registrar_stub.dart` | `platform/web/test/web_platform_test.dart`（13 用例） |
| WASM 加载器（注入 `wb_core.js` → `window.WbCore` 工厂 → 实例化；超时 15s；`progress` 0→1；失败 → `unavailable`；幂等；`callString` / `callInt` 调用约定 C ABI JSON 信封——`ccall` 返回指针 → `utf8ToString` 读串 → `free` 释放，`argTypes` 自动推断（String→string / bool→boolean / 其余→number），VM 桩恒 null） | `platform/web/lib/wb_core_loader.dart`、`platform/web/lib/src/wb_core_loader_web.dart`、`platform/web/lib/src/wb_core_loader_stub.dart` | 同上 |
| Emscripten 模块绑定（`ccall` / `cwrap` / `utf8ToString` / `malloc` / `free` / `heapU8` / `readBytes`；小写别名 `malloc` / `free` / `utf8ToString` / `heapU8` 由产物侧 post_js 层补齐——Emscripten 原生仅发布 `_malloc` / `_free` / `UTF8ToString` / `HEAPU8`，缺失时调用抛 `NoSuchMethodError`） | `platform/web/lib/wb_core_bindings.dart`、`platform/web/lib/src/wb_core_bindings_web.dart`、`platform/web/lib/src/wb_core_bindings_stub.dart` | 同上 |
| 窗口能力（全屏映射 Fullscreen API；透明/置顶/穿透/位置/尺寸 no-op + `WebWindowCapabilities` 能力查询） | `platform/web/lib/web_window.dart`、`platform/web/lib/src/web_window_web.dart`、`platform/web/lib/src/web_window_stub.dart`、`platform/web/lib/src/web_window_types.dart` | 同上 |
| 公共类型（`WbCoreStatus` 状态机 idle→loading→ready/unavailable；`WbCoreCallable`） | `platform/web/lib/src/wb_core_types.dart` | 同上 |
| Web 宿主占位脚本（不定义 `window.WbCore` → 探测为 `unavailable`；宿主用真实 Emscripten 产物覆盖——`apps/web/web/` 已为真实产物） | `platform/web/web/wb_core.js` | 同上 |

## 3. 契约与依赖

- **对外契约（只读）**：4 个 `pubspec.yaml` 的插件声明（`WhiteboardWindowsPlugin` / `WhiteboardMacosPlugin` / `ffiPlugin: true` / `WhiteboardWebPlatform` + `fileName`）与包名；各包 `lib/` 顶层导出面。
- **通道契约（MethodChannel 两平台一致）**：
  - Windows 通道 `whiteboard/windows`、macOS 通道 `whiteboard/macos`；
  - 方法：`window.setTransparent`{transparent}、`window.setAlwaysOnTop`{onTop}、`window.setIgnoreMouseEvents`{ignore,forward}、`window.setFullscreen`{fullscreen}、`window.setPosition`{x,y}、`window.setSize`{width,height}、`shortcut.register`{accelerator,id}、`shortcut.unregister`{id}、`shortcut.unregisterAll`、`tray.setIcon`{iconPath}、`tray.setTooltip`{tooltip}、`tray.setMenu`{items}、`capture.captureDisplay`{displayId}→{bytes,width,height,stride}/null、`capture.isAvailable`→bool；
  - Windows 特有：`dialog.openImage` / `dialog.openBoard`→路径/null、`dialog.saveBoard`{suggestedPath}→路径/null、`capture.captureVirtualScreen`；
  - 入站事件（原生→Dart）：`shortcut.triggered`{id}、`tray.clicked`{id}。
- **Linux C API（`linux/include/window_plugin.h`，17 个符号；Dart 绑定 `wb_ffi_bindings.dart` 一一对应，修改必须同步）**：
  - 窗口 6：`wb_linux_window_set_transparent` / `set_always_on_top` / `set_ignore_mouse_events` / `set_fullscreen` / `set_position` / `set_size`；
  - 快捷键 4：`wb_linux_shortcut_register` / `unregister` / `unregister_all` / `set_callback`；
  - 托盘 4：`wb_linux_tray_set_icon` / `set_tooltip` / `set_menu` / `set_callback`；
  - 捕获 3：`wb_linux_capture_display` / `capture_free` / `capture_is_available`；
  - 状态码：`WB_OK`=0 / `WB_ERR_UNSUPPORTED`=1 / `WB_ERR_FAILED`=2。
- **Web 契约**：条件导入开关 `dart.library.js_interop`；默认脚本 `wb_core.js`、默认超时 15s；`WbCoreStatus` 四态（`idle`/`loading`/`ready`/`unavailable`）；产物接口契约 = `window.WbCore()` 工厂（Emscripten `MODULARIZE=1 -sEXPORT_NAME=WbCore`）+ 调用面 `ccall`/`cwrap` + post_js 别名（`malloc`/`free`/`utf8ToString`/`heapU8`）——真实产物必须带别名层（`core/wasm/post_js.js`），否则 `callString`/`callInt` 抛 `NoSuchMethodError`。
- **降级约定（四包统一，回归依据；任何路径不得向 Dart 调用方抛异常）**：
  - Windows/macOS 原生未注册（`MissingPluginException`）→ 窗口/快捷键/托盘 no-op、透明返回 false（Windows）、对话框/捕获返回 null、事件流为空；
  - Linux 库缺失 → no-op、查询 false/null、事件流为空；
  - Web 非 Web 环境（VM / `flutter test`）→ 桩实现（`unavailable` / no-op）。
- **依赖**：`package:flutter`（MethodChannel / 插件注册）、`package:ffi`（Linux）、`flutter_web_plugins` + `package:web`（Web）；不依赖 07/08/09 包。
- **被依赖**：10 ← 11（`apps/desktop` 已声明 `whiteboard_windows` path 依赖并自动注册）、10 ← 12（`apps/web` 使用 `whiteboard_web_platform` 的 WASM 加载与全屏）。
- **已知跨平台差异（调用方按平台适配，勿假设四平台完全同形）**：`setTransparent` Windows 返回 `Future<bool>`、macOS/Linux/Web 返回 `Future<void>`；`openImageFile` / `openBoardFile` / `saveBoardFile` 仅 Windows 提供；`captureVirtualScreen` 仅 Windows 提供。

## 4. 常用命令

```powershell
# 各包 Dart 测试（本机 Windows 可跑，全绿为准）
Set-Location platform\windows; E:\code\flutter-sdk\flutter\bin\flutter.bat test
Set-Location platform\macos;   E:\code\flutter-sdk\flutter\bin\flutter.bat test
Set-Location platform\linux;   E:\code\flutter-sdk\flutter\bin\flutter.bat test
Set-Location platform\web;     E:\code\flutter-sdk\flutter\bin\flutter.bat test

# Windows 原生构建验证（经宿主 app 构建链）
Set-Location apps\desktop; E:\code\flutter-sdk\flutter\bin\flutter.bat build windows

# macOS / Linux 原生构建（须在对应平台执行，本机不构建）
# macOS: pod lib lint platform\macos\macos\whiteboard_macos.podspec
# Linux: cmake -S platform\linux\linux -B build\linux-plugin; cmake --build build\linux-plugin
```

## 5. 变更影响提醒（改本模块时注意）

- 修改通道名 / 方法名 / 事件名（`whiteboard/windows`、`whiteboard/macos`、`shortcut.triggered`、`tray.clicked`）→ 影响 **11 app-desktop** 的平台服务适配层（`apps/desktop/lib/platform/`，含 `transparent_overlay_service.dart`、`desktop_backdrop_controller.dart`），必须同步跑 11 号测试。
- 修改插件包导出类或方法签名 → 同上；如需统一跨平台签名（`setTransparent` 返回值等），四个包一起评估后改。
- 修改 Linux C API 头（`linux/include/window_plugin.h`）→ 必须同步 `platform/linux/lib/src/wb_ffi_bindings.dart`（两者一一对应）。
- 修改 Web 加载器行为 / `WbCoreStatus` → 影响 **12 app-web**（`WbCoreService`、`WbCoreStatusChip`、演示画布降级），必须同步跑 12 号测试。
- 修改 `web/wb_core.js` 占位约定（`window.WbCore` 工厂；真实产物为 Emscripten `MODULARIZE=1 -s EXPORT_NAME=WbCore` + post_js 别名层）→ 与 **17 build-release** 的 WASM 构建流程（`build_wasm.ps1 -CopyToWebAssets`）及 **12 app-web** 的 `web/` 产物约定联动。
- 4 个 `pubspec.yaml` 的插件名与 pluginClass/ffiPlugin 声明为**固化契约，禁止修改**；新增文件按现有目录结构放置即可（CMake/podspec 已按目录收录）。
