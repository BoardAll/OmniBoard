// screen_capture.cpp — 屏幕捕获（GDI）：EnumDisplayMonitors 选择显示器 /
// 虚拟桌面整屏；BitBlt 截取 BGRA 缓冲（自上而下，stride = width * 4）。
//
// 合规说明：调用前必须已获得用户授权（《安全与合规设计》：屏幕内容涉及
// 隐私）；本编译单元只实现采集，不做授权判断（由 Dart 上层状态机负责）。
//
// 线程约束：可在任意线程调用（GDI 非窗口 API 无 UI 线程要求），实际由
// 方法通道回调在 UI 线程调用。

#include "window_plugin.h"

#include <algorithm>
#include <vector>

// WDA_EXCLUDEFROMCAPTURE：窗口从截屏中排除（Win10 2004+）。旧 SDK 头文件
// 可能未定义该常量，此处兜底。
#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

namespace wb::platform::windows {

namespace {

// EnumDisplayMonitors 回调：收集全部显示器矩形（rcMonitor，物理像素）。
BOOL CALLBACK CollectMonitorsProc(HMONITOR monitor, HDC hdc, LPRECT rect,
                                  LPARAM lparam) {
  (void)hdc;
  (void)rect;
  auto* monitors = reinterpret_cast<std::vector<RECT>*>(lparam);
  MONITORINFO info = {};
  info.cbSize = sizeof(MONITORINFO);
  if (GetMonitorInfoW(monitor, &info) != FALSE) {
    monitors->push_back(info.rcMonitor);
  }
  return TRUE;
}

// 捕获指定屏幕矩形为 BGRA 帧（自上而下，stride = width * 4）。
// CaptureDisplay / CaptureVirtualScreen 共用；失败返回 false。
bool CaptureRectangle(const RECT& bounds, CapturedFrame* out) {
  if (out == nullptr) {
    return false;
  }
  const int width = static_cast<int>(bounds.right - bounds.left);
  const int height = static_cast<int>(bounds.bottom - bounds.top);
  if (width <= 0 || height <= 0) {
    return false;
  }

  // 1. 屏幕 DC + 内存 DC + 32bpp DIB。
  const HDC screen_dc = GetDC(nullptr);
  if (screen_dc == nullptr) {
    return false;
  }
  const HDC memory_dc = CreateCompatibleDC(screen_dc);
  if (memory_dc == nullptr) {
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  BITMAPINFO bitmap_info = {};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = width;
  bitmap_info.bmiHeader.biHeight = -height;  // 负值 = 自上而下（top-down）
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;  // BGRA 分量序（BGRX）
  bitmap_info.bmiHeader.biCompression = BI_RGB;

  void* pixels = nullptr;
  const HBITMAP bitmap = CreateDIBSection(screen_dc, &bitmap_info,
                                          DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (bitmap == nullptr || pixels == nullptr) {
    if (bitmap != nullptr) {
      DeleteObject(bitmap);
    }
    DeleteDC(memory_dc);
    ReleaseDC(nullptr, screen_dc);
    return false;
  }
  const HGDIOBJ previous = SelectObject(memory_dc, bitmap);

  // 2. BitBlt 抓取。故意不用 CAPTUREBLT：避免把本进程窗口也捕捉进来
  //    （captureVirtualScreen 另以 WDA_EXCLUDEFROMCAPTURE 排除自身覆盖层）。
  const BOOL copied = BitBlt(memory_dc, 0, 0, width, height, screen_dc,
                             bounds.left, bounds.top, SRCCOPY);
  GdiFlush();

  bool success = false;
  if (copied != FALSE) {
    const int32_t stride = width * 4;
    auto* begin = static_cast<uint8_t*>(pixels);
    // BitBlt 不定义 alpha 通道内容（通常为 0）：统一置 255，保证下游
    // 编码（PNG 等）按不透明像素处理。
    const size_t pixel_count =
        static_cast<size_t>(width) * static_cast<size_t>(height);
    for (size_t i = 0; i < pixel_count; ++i) {
      begin[i * 4 + 3] = 0xFF;
    }
    out->bytes.assign(begin, begin + static_cast<size_t>(stride) *
                                  static_cast<size_t>(height));
    out->width = width;
    out->height = height;
    out->stride = stride;
    success = true;
  }

  // 3. GDI 资源清理（严格逆序）。
  SelectObject(memory_dc, previous);
  DeleteObject(bitmap);
  DeleteDC(memory_dc);
  ReleaseDC(nullptr, screen_dc);
  return success;
}

}  // namespace

bool ScreenCapturePlugin::CaptureDisplay(int64_t display_id,
                                         CapturedFrame* out) const {
  if (out == nullptr) {
    return false;
  }

  // 1. 选择目标显示器。
  RECT bounds = {};
  if (display_id < 0) {
    // -1（及其它负值）：主显示器。主显示器左上角恒为虚拟桌面原点 (0,0)。
    const POINT origin = {0, 0};
    const HMONITOR monitor =
        MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO info = {};
    info.cbSize = sizeof(MONITORINFO);
    if (monitor == nullptr || GetMonitorInfoW(monitor, &info) == FALSE) {
      return false;
    }
    bounds = info.rcMonitor;
  } else {
    std::vector<RECT> monitors;
    if (EnumDisplayMonitors(nullptr, nullptr, &CollectMonitorsProc,
                            reinterpret_cast<LPARAM>(&monitors)) == FALSE) {
      return false;
    }
    // 多显示器约定：按虚拟桌面位置排序（左→右、上→下）后取 displayId 序号；
    // 支持负坐标的多屏拼接（bounds 直接使用物理坐标，可为负）。
    std::stable_sort(monitors.begin(), monitors.end(),
                     [](const RECT& a, const RECT& b) {
                       if (a.left != b.left) {
                         return a.left < b.left;
                       }
                       return a.top < b.top;
                     });
    if (display_id >= static_cast<int64_t>(monitors.size())) {
      return false;  // 越界：无效显示器序号
    }
    bounds = monitors[static_cast<size_t>(display_id)];
  }

  // 2. 抓取所选显示器矩形。
  return CaptureRectangle(bounds, out);
}

bool ScreenCapturePlugin::CaptureVirtualScreen(HWND exclude_window,
                                               CapturedFrame* out) const {
  if (out == nullptr) {
    return false;
  }

  // 1. 整虚拟桌面范围（多显示器拼接，坐标可为负）。
  const int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (width <= 0 || height <= 0) {
    return false;
  }
  const RECT bounds = {x, y, x + width, y + height};

  // 2. 防截到自身：抓取期间把应用窗口从截屏中排除（Win10 2004+；旧系统 /
  //    调用失败忽略——最坏情况仅把覆盖层画面截入背景，不影响其它流程）。
  if (exclude_window != nullptr) {
    SetWindowDisplayAffinity(exclude_window, WDA_EXCLUDEFROMCAPTURE);
  }
  const bool success = CaptureRectangle(bounds, out);
  if (exclude_window != nullptr) {
    // 恢复默认亲和性（与抓取前设置配对；失败忽略）。
    SetWindowDisplayAffinity(exclude_window, WDA_NONE);
  }
  return success;
}

}  // namespace wb::platform::windows
