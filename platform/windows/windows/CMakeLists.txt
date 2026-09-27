# whiteboard_windows 插件 · Flutter Windows CMake 构建脚本（C++20 / Win32）。
#
# 结构遵循 Flutter 官方 Windows 插件模板（plugin/windows.tmpl）：
#   project(...) + add_library(<name>_plugin) + apply_standard_settings(...)。
#
# 注意：PLUGIN_NAME 必须为 "<包名>_plugin"（即 whiteboard_windows_plugin）。
# Flutter 工具生成的 generated_plugins.cmake 按 `${plugin}_plugin` 链接本目标
# 并收集 $<TARGET_FILE:${plugin}_plugin>，修改目标名将导致桌面应用集成失败。
cmake_minimum_required(VERSION 3.14)

# 工程级配置。
project(whiteboard_windows LANGUAGES CXX)

# 显式启用现代 CMake 行为，避免新版 CMake 警告。
cmake_policy(VERSION 3.14...3.25)

# 插件目标名（Flutter 工具链接契约，见文件头注释）。
set(PLUGIN_NAME "whiteboard_windows_plugin")

# 插件全部源文件（新增源文件需在此登记）。
set(PLUGIN_SOURCES
  "whiteboard_windows_plugin.cpp"
  "src/window_plugin.cpp"
  "src/transparent_overlay.cpp"
  "src/shortcut_plugin.cpp"
  "src/tray_plugin.cpp"
  "src/screen_capture.cpp"
  "src/texture_share.cpp"
)

# 插件动态库目标（C 接口头 + 全部实现）。
add_library(${PLUGIN_NAME} SHARED
  "include/whiteboard_windows/whiteboard_windows_plugin.h"
  ${PLUGIN_SOURCES}
)

# 应用宿主工程定义的公共编译设置（/W4 /WX /wd4100 /EHsc、_HAS_EXCEPTIONS=0 等）。
apply_standard_settings(${PLUGIN_NAME})

# 本插件要求 C++20（与宿主 C++17 基线取最严格者，最终生成 /std:c++20）。
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_20)

# MSVC 源码 / 执行字符集统一为 UTF-8：源码含中文注释与中文错误消息，而
# Flutter 模板的 apply_standard_settings 不含 /utf-8；若按系统代码页（如 GBK）
# 编译，将触发 C4819/C4566 警告（/WX 下构建失败），或把消息字符串编译成
# 非 UTF-8 字节导致 Dart 侧显示乱码。
if(MSVC)
  target_compile_options(${PLUGIN_NAME} PRIVATE "/utf-8")
endif()

# 符号默认隐藏，仅 FLUTTER_PLUGIN_EXPORT 显式导出的符号对外可见，
# 避免与其它插件/宿主符号冲突。
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN TRUE
)

# 编译插件自身时 FLUTTER_PLUGIN_EXPORT 展开为 __declspec(dllexport)。
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# 对外暴露 include 目录（供宿主/其它插件引用 C 接口头 <whiteboard_windows/...>）。
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

# 插件内部头文件目录（window_plugin.h 等内部共享声明）。
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

# 依赖说明：
#   flutter             —— flutter_windows.dll 的 C API 头（flutter_windows.h 等）
#                          与导入库（FlutterDesktopGetDpiForHWND 等符号）；
#   flutter_wrapper_plugin —— cpp_client_wrapper 的 C++ 封装（flutter/method_channel.h、
#                          flutter/plugin_registrar_windows.h 等），其 PUBLIC include
#                          目录即 cpp_client_wrapper/include，由 Flutter 宿主工程提供；
#   user32/shell32/gdi32/comdlg32 —— 窗口（含 SetWindowCompositionAttribute 动态
#                          解析与扩展样式）/热键、托盘、屏幕捕获、文件对话框
#                          （GetOpenFileNameW）所需系统库。
# cpp_client_wrapper/include 与 flutter_windows.h 的 include 路径分别通过
# flutter_wrapper_plugin / flutter 的 INTERFACE include 传递，此处不硬编码 SDK 绝对路径。
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  user32
  shell32
  gdi32
  comdlg32
)

# 需随包分发的预编译库（当前无，保持变量供 Flutter 工具收集）。
set(whiteboard_windows_bundled_libraries
  ""
  PARENT_SCOPE
)
