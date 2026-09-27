/// Whiteboard macOS 平台插件。
///
/// 提供窗口（透明 / 置顶 / 点击穿透 / 全屏 / 位置尺寸）、全局快捷键、
/// 托盘与屏幕捕获的 Dart 接口；原生侧见 `macos/`（Objective-C++ /
/// Cocoa，Carbon 热键 / NSStatusBar / CGDisplayCreateImage）。
/// 原生插件未注册时（未打包 / 单元测试环境）全部静默降级：窗口与
/// 快捷键调用为 no-op、触发流为空、捕获返回 null，保证上层应用可正常运行。
library;

export 'src/wb_screen_capture.dart';
export 'src/wb_shortcut_plugin.dart';
export 'src/wb_tray_plugin.dart';
export 'src/wb_window_plugin.dart';
