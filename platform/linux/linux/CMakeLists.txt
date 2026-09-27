# whiteboard_linux 插件 · 原生构建脚本（C++20 / X11 + Wayland + GTK3 运行时动态加载）。
#
# 规范：Flutter Linux ffiPlugin（pubspec.yaml: linux.ffiPlugin=true），无通道，
# 产出单一动态库 libwhiteboard_linux.so，Dart 侧（dart:ffi）以文件名 dlopen：
#
#   * 目标名 = 包名 whiteboard_linux（见 platform/linux/lib/src/wb_native_library.dart
#     的候选加载名 libwhiteboard_linux.so）；
#   * 本脚本可被桌面应用 linux/CMakeLists.txt 以 add_subdirectory 集成
#     （探测到宿主定义的 apply_standard_settings 时复用宿主编译设置，
#     并按 Flutter 约定向父作用域导出 whiteboard_linux_bundled_libraries）；
#   * 同时保持独立可配置/构建（不依赖 Flutter 构建上下文），例如：
#       cmake -S platform/linux/linux -B build/linux-x64/whiteboard_linux
#       cmake --build build/linux-x64/whiteboard_linux
#
# 依赖策略（与《透明批注模式技术方案》§7.3 / §7.4 对齐）：
#   * X11 / wayland / GTK3 头文件与库全部“可选”：探测成功 → 对应后端源码
#     参与编译（WB_LINUX_HAVE_* 宏）；探测失败 → 编译同构 stub，运行时
#     统一返回 WB_ERR_UNSUPPORTED / WB_ERR_FAILED，绝不崩溃；
#   * 所有原生库（libX11 / libXext / libXrandr / libXinerama / libwayland-client /
#     libgtk-3 / libgdk-3 / libcairo / libayatana-appindicator3 …）均不被链接，
#     由实现代码在运行时 dlopen/dlsym 并逐个校验符号——保证在纯 headless /
#     无 X11 环境进程中加载本插件绝对安全（调用安全降级而非崩溃）。
#
# 构建依赖（编译带完整 X11 后端时）：libx11-dev（提供 X11/Xlib.h）。
# 缺少该头文件也能构建（X11 后端退化为 stub）。

cmake_minimum_required(VERSION 3.14)

# 工程级配置（作为子目录被 Flutter 宿主集成时，嵌套 project() 亦为标准用法）。
project(whiteboard_linux LANGUAGES CXX)

cmake_policy(VERSION 3.14...3.25)

# 插件目标名（构建契约：产出 libwhiteboard_linux.so；Dart 侧按文件名加载）。
set(WB_LINUX_TARGET "whiteboard_linux")

# 插件全部源文件（新增源文件需在此登记；全部编译进单一动态库）。
set(WB_LINUX_SOURCES
  "src/window_plugin.cpp"
  "src/transparent_overlay_x11.cpp"
  "src/transparent_overlay_wayland.cpp"
  "src/shortcut_plugin.cpp"
  "src/tray_plugin.cpp"
  "src/screen_capture.cpp"
)

# 插件动态库目标（公共 C 接口头 + 全部实现）。
add_library(${WB_LINUX_TARGET} SHARED
  "include/window_plugin.h"
  ${WB_LINUX_SOURCES}
)

# 本插件要求 C++20（严格标准模式；宿主 Flutter 模板默认 cxx_std_17，
# 目标级 cxx_std_20 取更严格者）。
target_compile_features(${WB_LINUX_TARGET} PRIVATE cxx_std_20)

# 宿主编译设置：Flutter Linux 应用在 linux/CMakeLists.txt 定义
# apply_standard_settings（-Wall -Werror -Wextra -Wpedantic 等）；
# 独立构建（未定义该函数）时自行施加等价的告警级别（不含 -Werror）。
if(COMMAND apply_standard_settings)
  apply_standard_settings(${WB_LINUX_TARGET})
else()
  if(NOT MSVC)
    target_compile_options(${WB_LINUX_TARGET} PRIVATE
      -Wall
      -Wextra
      -Wpedantic
    )
  endif()
endif()

# 符号默认隐藏：仅 WB_LINUX_API（__attribute__((visibility("default")))）显式
# 导出的 17 个扁平 C API 对外可见，避免与宿主 / 其它插件符号冲突。
set_target_properties(${WB_LINUX_TARGET} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN TRUE
  POSITION_INDEPENDENT_CODE ON
)

# 对外暴露 include 目录（供宿主 / 其它组件引用 C 接口头）。
target_include_directories(${WB_LINUX_TARGET} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

# 插件内部头文件目录（window_plugin.h 同时承载对外 C API 与内部共享声明）。
target_include_directories(${WB_LINUX_TARGET} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

# 线程（快捷键专属 X11 读取线程）与 dlopen/dlsym（${CMAKE_DL_LIBS} = dl）。
set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)
target_link_libraries(${WB_LINUX_TARGET} PRIVATE
  Threads::Threads
  ${CMAKE_DL_LIBS}
)

# ---------------------------------------------------------------------------
# 可选能力探测（仅决定源文件内 #ifdef 的编译开关，不产生任何链接依赖）。
# ---------------------------------------------------------------------------

# ---- X11 后端（transparent_overlay_x11.cpp 完整实现需要 X11/Xlib.h）----
find_package(X11 QUIET)
set(WB_LINUX_X11_INCLUDE_DIR "")
if(X11_FOUND AND EXISTS "${X11_INCLUDE_DIR}/X11/Xlib.h")
  set(WB_LINUX_X11_INCLUDE_DIR "${X11_INCLUDE_DIR}")
else()
  # X11_FOUND 为空但头文件存在（仅装了头文件的精简环境）时兜底探测。
  find_path(WB_LINUX_X11_FALLBACK_INCLUDE_DIR X11/Xlib.h)
  if(WB_LINUX_X11_FALLBACK_INCLUDE_DIR)
    set(WB_LINUX_X11_INCLUDE_DIR "${WB_LINUX_X11_FALLBACK_INCLUDE_DIR}")
  endif()
endif()

if(WB_LINUX_X11_INCLUDE_DIR)
  target_compile_definitions(${WB_LINUX_TARGET} PRIVATE WB_LINUX_HAVE_X11=1)
  target_include_directories(${WB_LINUX_TARGET} PRIVATE "${WB_LINUX_X11_INCLUDE_DIR}")
  set(WB_LINUX_X11_STATUS "ON  (headers: ${WB_LINUX_X11_INCLUDE_DIR})")
else()
  set(WB_LINUX_X11_STATUS "OFF (未找到 X11/Xlib.h，X11 后端编译为安全降级 stub)")
endif()

# ---- GTK3（托盘 tray_plugin.cpp + Wayland 后端运行路径：均运行时加载）----
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
  pkg_check_modules(WB_LINUX_GTK3 QUIET gtk+-3.0)
endif()
if(NOT WB_LINUX_GTK3_FOUND)
  # pkg-config 不可用（如裁剪环境）时按库文件兜底探测。
  find_library(WB_LINUX_GTK3_LIBRARY NAMES gtk-3 libgtk-3.so.0)
  if(WB_LINUX_GTK3_LIBRARY)
    set(WB_LINUX_GTK3_FOUND TRUE)
  endif()
endif()

if(WB_LINUX_GTK3_FOUND)
  target_compile_definitions(${WB_LINUX_TARGET} PRIVATE WB_LINUX_HAVE_GTK3=1)
  set(WB_LINUX_GTK3_STATUS "ON")
else()
  set(WB_LINUX_GTK3_STATUS "OFF (未找到 gtk+-3.0，托盘编译为安全降级 stub)")
endif()

# ---- Wayland 后端（transparent_overlay_wayland.cpp：GDK 运行时加载）----
# 探测仅为编译开关信号（不产生链接依赖）：libwayland-client 库文件或
# GTK3（GDK 内含 Wayland 后端）任一可用即启用完整实现，否则安全 stub。
find_library(WB_LINUX_WAYLAND_CLIENT_LIBRARY NAMES wayland-client libwayland-client.so.0)
if(WB_LINUX_WAYLAND_CLIENT_LIBRARY OR WB_LINUX_GTK3_FOUND)
  target_compile_definitions(${WB_LINUX_TARGET} PRIVATE WB_LINUX_HAVE_WAYLAND=1)
  if(WB_LINUX_WAYLAND_CLIENT_LIBRARY)
    set(WB_LINUX_WAYLAND_STATUS "ON  (probe: ${WB_LINUX_WAYLAND_CLIENT_LIBRARY})")
  else()
    set(WB_LINUX_WAYLAND_STATUS "ON  (probe: gtk+-3.0 / GDK)")
  endif()
else()
  set(WB_LINUX_WAYLAND_STATUS "OFF (未找到 libwayland-client / gtk+-3.0，Wayland 后端编译为安全降级 stub)")
endif()

message(STATUS "whiteboard_linux: X11=${WB_LINUX_X11_STATUS}")
message(STATUS "whiteboard_linux: Wayland=${WB_LINUX_WAYLAND_STATUS}")
message(STATUS "whiteboard_linux: GTK3=${WB_LINUX_GTK3_STATUS}")

# 需随包分发的预编译库（当前无，保持变量供 Flutter 工具收集）。
# 独立构建（本工程为顶层）时无父作用域，本地设置即可（避免开发告警）；
# 被 Flutter 宿主 add_subdirectory 集成时向父作用域导出（工具收集约定）。
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  set(whiteboard_linux_bundled_libraries "")
else()
  set(whiteboard_linux_bundled_libraries
    ""
    PARENT_SCOPE
  )
endif()
