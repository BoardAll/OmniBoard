/// Whiteboard Windows 平台插件。
///
/// 提供窗口（透明 / 置顶 / 点击穿透 / 全屏 / 位置尺寸 / 图片选择对话框）、
/// 全局快捷键、托盘与屏幕捕获（单显示器 / 整虚拟桌面）的 Dart 接口；原生侧
/// 见 `windows/`（C++ / Win32，《Flutter + C++ 工程结构设计》§6.1）。原生插件
/// 未注册时（未打包 / 单元测试环境）全部静默降级：窗口与快捷键调用为
/// no-op（透明返回 false、对话框返回 null）、触发流为空、捕获返回 null，
/// 保证上层应用可正常运行。
library;

export 'src/wb_screen_capture.dart';
export 'src/wb_shortcut_plugin.dart';
export 'src/wb_tray_plugin.dart';
export 'src/wb_window_plugin.dart';
