// whiteboard_windows 插件 C 接口：Flutter 工具生成的注册代码调用入口。
//
// 函数名与 pubspec.yaml 中固化的 `pluginClass: WhiteboardWindowsPlugin` 对应：
// Flutter 工具生成 generated_plugin_registrant.cc 时按
//   #include <whiteboard_windows/whiteboard_windows_plugin.h>
//   WhiteboardWindowsPluginRegisterWithRegistrar(...)
// 引用本头文件与函数，请勿变更文件名与函数名。
#pragma once

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

// 注册 whiteboard_windows 插件：创建 'whiteboard/windows' 方法通道，
// 装配窗口 / 快捷键 / 托盘 / 屏幕捕获子插件。
FLUTTER_PLUGIN_EXPORT void WhiteboardWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif
