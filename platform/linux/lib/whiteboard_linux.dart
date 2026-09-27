/// Whiteboard Linux 平台插件。
///
/// FFI 插件（`pubspec.yaml` 中 `linux: ffiPlugin: true`）：不经过任何
/// MethodChannel，Dart 侧通过 `dart:ffi` 直接调用 `libwhiteboard_linux.so`
/// 导出的扁平 C API（见 `linux/include/window_plugin.h`）。
///
/// 支持矩阵（《透明批注模式技术方案》§7.3 / §7.4）：
///
///   - X11 / XWayland：窗口透明 / 置顶 / 全屏 / 位置尺寸、XShape 点击
///     穿透、XGrabKey 全局快捷键、AppIndicator 托盘、XGetImage 截屏；
///   - Wayland 原生：透明 / 置顶 / 位置尺寸为 best-effort（合成器可忽略
///     请求），点击穿透经 wl_compositor input region（部分合成器不支持），
///     全局快捷键与截屏无协议支撑，返回不支持（应用内快捷键 / 后续
///     xdg-desktop-portal 集成降级）。
///
/// 原生库缺失时（未打包 / 单元测试环境）全部静默降级：窗口、快捷键、
/// 托盘调用为 no-op，查询返回 false/null，事件流保持为空，绝不抛异常；
/// 保证上层应用在缺少原生组件时仍可运行。
library;

export 'src/wb_accelerator.dart';
export 'src/wb_ffi_bindings.dart';
export 'src/wb_native_library.dart';
export 'src/wb_screen_capture.dart';
export 'src/wb_shortcut_plugin.dart';
export 'src/wb_tray_plugin.dart';
export 'src/wb_window_plugin.dart';
