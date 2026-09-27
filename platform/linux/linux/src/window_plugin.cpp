// whiteboard_linux 插件 · 公共基础设施与窗口能力对外接口（C++20 / POSIX）。
//
// 本文件包含：
//   * DlOpenFirst / DlSym / DlSymAs / EnvString / EnvOrDefault /
//     ContainsCaseInsensitive：dlopen 与环境读取的薄封装（全部后端共用）；
//   * ResolveSessionBackend：会话后端判定（WB_LINUX_BACKEND 显式覆盖 →
//     进程内 GDK display 名称 → DISPLAY / WAYLAND_DISPLAY 环境兜底；判定
//     结果进程内缓存，kNone 时允许随环境变化重试）；
//   * 窗口能力 6 个对外符号：按后端分发到 X11
//     （transparent_overlay_x11.cpp）或 Wayland / GDK
//     （transparent_overlay_wayland.cpp）实现。
//
// 线程约束：导出函数在 Dart 主 isolate 线程（Flutter Linux 下即 GTK 主
// 线程）调用；共享状态串行化由各后端实现负责（见各文件头部注释）。
//
// 符号可见性：17 个对外符号均为 extern "C" + WB_LINUX_API
// （visibility("default")）；配合 CMake 的 CXX_VISIBILITY_PRESET hidden，
// 其余内部符号对外不可见。

#include "window_plugin.h"

#include <dlfcn.h>

#include <cctype>
#include <cstdlib>
#include <mutex>
#include <string>

namespace wb::platform::linux_ {

// ===== 通用工具 =====

void* DlOpenFirst(const char* const* names, size_t count) {
  if (names == nullptr) {
    return nullptr;
  }
  for (size_t i = 0; i < count; ++i) {
    if (names[i] == nullptr) {
      continue;
    }
    void* handle = ::dlopen(names[i], RTLD_LAZY | RTLD_LOCAL);
    if (handle != nullptr) {
      return handle;
    }
  }
  return nullptr;
}

void* DlSym(void* handle, const char* symbol) {
  if (handle == nullptr || symbol == nullptr) {
    return nullptr;
  }
  return ::dlsym(handle, symbol);
}

std::string EnvString(const char* name) {
  if (name == nullptr) {
    return std::string();
  }
  const char* value = std::getenv(name);
  return value != nullptr ? std::string(value) : std::string();
}

std::string EnvOrDefault(const char* name, const char* fallback) {
  const std::string value = EnvString(name);
  if (!value.empty()) {
    return value;
  }
  return fallback != nullptr ? std::string(fallback) : std::string();
}

bool ContainsCaseInsensitive(const std::string& text, const std::string& needle) {
  if (needle.empty()) {
    return true;
  }
  if (needle.size() > text.size()) {
    return false;
  }
  const auto lower = [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  };
  for (size_t i = 0; i + needle.size() <= text.size(); ++i) {
    size_t j = 0;
    while (j < needle.size() && lower(static_cast<unsigned char>(text[i + j])) ==
                                   lower(static_cast<unsigned char>(needle[j]))) {
      ++j;
    }
    if (j == needle.size()) {
      return true;
    }
  }
  return false;
}

// ===== 会话后端判定 =====

namespace {

SessionBackend BackendFromGdk(GdkDisplayKind kind) {
  switch (kind) {
    case GdkDisplayKind::kX11:
      return SessionBackend::kX11;
    case GdkDisplayKind::kWayland:
      return SessionBackend::kWayland;
    case GdkDisplayKind::kNone:
      break;
  }
  return SessionBackend::kNone;
}

SessionBackend DetectSessionBackend() {
  // 1) 显式覆盖（测试 / 强制后端）。
  const std::string override_value = EnvString("WB_LINUX_BACKEND");
  if (override_value == "x11") {
    return SessionBackend::kX11;
  }
  if (override_value == "wayland") {
    return SessionBackend::kWayland;
  }
  if (override_value == "none") {
    return SessionBackend::kNone;
  }

  // 2) 进程内 GDK display 名称（Flutter / GTK 初始化后最可靠）。
  const SessionBackend from_gdk = BackendFromGdk(ProbeGdkDisplayKind());
  if (from_gdk != SessionBackend::kNone) {
    return from_gdk;
  }

  // 3) 环境变量兜底（无 GTK 可用：纯 headless / 测试进程）。DISPLAY 优先：
  //    该场景经 XWayland 的 X11 通路能力最完整（快捷键 / 截屏可用）。
  if (!EnvString("DISPLAY").empty()) {
    return SessionBackend::kX11;
  }
  if (!EnvString("WAYLAND_DISPLAY").empty() ||
      EnvString("XDG_SESSION_TYPE") == "wayland") {
    return SessionBackend::kWayland;
  }
  return SessionBackend::kNone;
}

}  // namespace

SessionBackend ResolveSessionBackend() {
  static std::mutex mutex;
  static bool cached = false;
  static SessionBackend backend = SessionBackend::kNone;
  std::lock_guard<std::mutex> lock(mutex);
  if (cached && backend != SessionBackend::kNone) {
    return backend;
  }
  backend = DetectSessionBackend();
  cached = true;
  return backend;
}

// ===== 窗口能力导出（6 符号）=====
//
// 统一骨架：异常边界 → 后端判定 → 分发。所有后端实现内部再做安全
// 降级（无 X11 / 无 GTK / 主窗口未找到 → 错误码，绝不崩溃）。

extern "C" WB_LINUX_API int wb_linux_window_set_transparent(int transparent) {
  WB_LINUX_TRY {
    switch (ResolveSessionBackend()) {
      case SessionBackend::kX11:
        return X11WindowSetTransparent(transparent != 0);
      case SessionBackend::kWayland:
        return WaylandWindowSetTransparent(transparent != 0);
      case SessionBackend::kNone:
        break;
    }
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

extern "C" WB_LINUX_API int wb_linux_window_set_always_on_top(int on_top) {
  WB_LINUX_TRY {
    switch (ResolveSessionBackend()) {
      case SessionBackend::kX11:
        return X11WindowSetAlwaysOnTop(on_top != 0);
      case SessionBackend::kWayland:
        return WaylandWindowSetAlwaysOnTop(on_top != 0);
      case SessionBackend::kNone:
        break;
    }
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

extern "C" WB_LINUX_API int wb_linux_window_set_ignore_mouse_events(int ignore,
                                                                    int forward) {
  WB_LINUX_TRY {
    // forward 为 Windows 平台「穿透但转发悬停」语义，Linux 无对应机制，
    // 按契约忽略（透传给后端仅作签名一致性）。
    switch (ResolveSessionBackend()) {
      case SessionBackend::kX11:
        return X11WindowSetIgnoreMouseEvents(ignore != 0, forward != 0);
      case SessionBackend::kWayland:
        return WaylandWindowSetIgnoreMouseEvents(ignore != 0, forward != 0);
      case SessionBackend::kNone:
        break;
    }
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

extern "C" WB_LINUX_API int wb_linux_window_set_fullscreen(int fullscreen) {
  WB_LINUX_TRY {
    switch (ResolveSessionBackend()) {
      case SessionBackend::kX11:
        return X11WindowSetFullscreen(fullscreen != 0);
      case SessionBackend::kWayland:
        return WaylandWindowSetFullscreen(fullscreen != 0);
      case SessionBackend::kNone:
        break;
    }
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

extern "C" WB_LINUX_API int wb_linux_window_set_position(int x, int y) {
  WB_LINUX_TRY {
    switch (ResolveSessionBackend()) {
      case SessionBackend::kX11:
        return X11WindowSetPosition(x, y);
      case SessionBackend::kWayland:
        return WaylandWindowSetPosition(x, y);
      case SessionBackend::kNone:
        break;
    }
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

extern "C" WB_LINUX_API int wb_linux_window_set_size(int width, int height) {
  WB_LINUX_TRY {
    // 尺寸合法性校验在分发层完成（两个后端共用同一契约：宽高必须 > 0）。
    if (width <= 0 || height <= 0) {
      return WB_ERR_FAILED;
    }
    switch (ResolveSessionBackend()) {
      case SessionBackend::kX11:
        return X11WindowSetSize(width, height);
      case SessionBackend::kWayland:
        return WaylandWindowSetSize(width, height);
      case SessionBackend::kNone:
        break;
    }
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

}  // namespace wb::platform::linux_
