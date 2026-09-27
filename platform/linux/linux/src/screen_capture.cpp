// whiteboard_linux 插件 · 屏幕捕获实现（X11 XGetImage，C++20）。
//
// 能力（《透明批注模式技术方案》§7.3）：
//   * X11 / XWayland：抓取 root window 上指定显示器的矩形，输出 BGRA
//     （stride = width * 4，alpha = 255），缓冲由 wb_linux_capture_free
//     释放；显示器矩形来源三级降级：RandR 1.5 monitors → Xinerama →
//     整屏兜底；display_id = -1 主显示器，>= 0 为按 (y, x) 排序的序号；
//   * Wayland 原生 / 无图形会话：WB_ERR_UNSUPPORTED（需 xdg-desktop-
//     portal + PipeWire 协议，不在本插件范围）。
//
// 内存与线程：
//   * 输出缓冲 std::malloc 分配、wb_linux_capture_free（std::free）释放，
//     NULL 安全；
//   * 与窗口操作共用主线程 X11 连接（X11MainDisplay + X11MainDisplayMutex
//     串行化全部 X 请求）；XGetImage 期间的协议错误经 X11ErrorTrap 捕获
//     并映射为 WB_ERR_FAILED（绝不触发 Xlib 默认 handler 的退出行为）；
//   * 依赖符号（XGetImage / RandR / Xinerama）全部 dlopen/dlsym 运行时
//     获取：无 X11 环境调用安全返回错误码而非崩溃。
//
// 像素转换：掩码法（red/green/blue_mask 驱动，不硬编码通道序），支持
// 8/16/24/32 bpp 与 LSBFirst/MSBFirst 字节序；未知位宽安全失败。
// 结构镜像（自研）以 static_assert 锁定 LP64 / ILP32 布局。

#include "window_plugin.h"

#if defined(WB_LINUX_HAVE_X11)

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace wb::platform::linux_ {

// ===== 显示器矩形发现（RandR / Xinerama / 整屏兜底）=====

// 自研 RandR 1.5 结构镜像（不引入 randr 头文件；仅取所需字段）。
// LP64 布局：6×int(24) + Atom 8 → 32 + 2×Bool(int) → 40 + int → 44 +
// 4 字节对齐填充 + 指针 8 = 56 字节。ILP32：44 字节。
struct WbXrrMonitorInfo {
  int x;
  int y;
  int width;
  int height;
  int mwidth;
  int mheight;
  unsigned long name;
  int primary;
  int automatic;
  int noutput;
  void* outputs;
};
static_assert(sizeof(void*) != 8 || sizeof(WbXrrMonitorInfo) == 56,
              "XRRMonitorInfo LP64 layout mismatch");
static_assert(sizeof(void*) != 4 || sizeof(WbXrrMonitorInfo) == 44,
              "XRRMonitorInfo ILP32 layout mismatch");

// 自研 Xinerama 结构镜像（int + 4×short = 12 字节，无 padding）。
struct WbXineramaScreenInfo {
  int screen_number;
  short x_org;
  short y_org;
  short width;
  short height;
};
static_assert(sizeof(WbXineramaScreenInfo) == 12,
              "XineramaScreenInfo layout mismatch");

// libXrandr / libXinerama 运行时符号表（均为可选增强；缺失时逐级降级，
// 不视为错误）。库句柄有意常驻（不 dlclose）。
struct CaptureApi {
  void* randr_library = nullptr;
  void* xinerama_library = nullptr;

  WbXrrMonitorInfo* (*XrrGetMonitors)(Display*, Window, int, int*) = nullptr;
  void (*XrrFreeMonitors)(WbXrrMonitorInfo*) = nullptr;
  WbXineramaScreenInfo* (*XineramaQueryScreens)(Display*, int*) = nullptr;
  void (*XineramaFreeScreens)(WbXineramaScreenInfo*) = nullptr;

  bool randr = false;
  bool xinerama = false;

  // 进程级单例（幂等加载；失败允许重试——与 X11Api 一致）。
  static CaptureApi& Get();
};

void LoadCaptureSymbols(CaptureApi& api) {
  if (api.randr_library == nullptr) {
    static const char* const kRandrNames[] = {"libXrandr.so.2",
                                              "libXrandr.so"};
    api.randr_library =
        DlOpenFirst(kRandrNames, sizeof(kRandrNames) / sizeof(kRandrNames[0]));
  }
  if (api.xinerama_library == nullptr) {
    static const char* const kXineramaNames[] = {"libXinerama.so.1",
                                                 "libXinerama.so"};
    api.xinerama_library = DlOpenFirst(
        kXineramaNames, sizeof(kXineramaNames) / sizeof(kXineramaNames[0]));
  }

  if (api.randr_library != nullptr && !api.randr) {
    api.XrrGetMonitors = DlSymAs<decltype(api.XrrGetMonitors)>(
        api.randr_library, "XRRGetMonitors");
    api.XrrFreeMonitors = DlSymAs<decltype(api.XrrFreeMonitors)>(
        api.randr_library, "XRRFreeMonitors");
    api.randr =
        api.XrrGetMonitors != nullptr && api.XrrFreeMonitors != nullptr;
  }
  if (api.xinerama_library != nullptr && !api.xinerama) {
    api.XineramaQueryScreens = DlSymAs<decltype(api.XineramaQueryScreens)>(
        api.xinerama_library, "XineramaQueryScreens");
    api.XineramaFreeScreens = DlSymAs<decltype(api.XineramaFreeScreens)>(
        api.xinerama_library, "XineramaFreeScreens");
    api.xinerama = api.XineramaQueryScreens != nullptr &&
                   api.XineramaFreeScreens != nullptr;
  }
}

CaptureApi& CaptureApi::Get() {
  static CaptureApi instance;
  static std::mutex load_mutex;
  std::lock_guard<std::mutex> lock(load_mutex);
  LoadCaptureSymbols(instance);
  return instance;
}

// ===== 显示器枚举与选择 =====

struct CaptureRect {
  long long x;
  long long y;
  long long width;
  long long height;
  bool primary;
};

// 收集显示器矩形（RandR → Xinerama → 整屏兜底），按 (y, x) 字典序排序
// （跨屏布局下顺序稳定）。
void CollectMonitors(CaptureApi& cap, Display* display, Window root,
                     int root_width, int root_height,
                     std::vector<CaptureRect>* rects) {
  if (cap.randr) {
    int count = 0;
    WbXrrMonitorInfo* monitors = cap.XrrGetMonitors(display, root, 1, &count);
    if (monitors != nullptr) {
      for (int i = 0; i < count; ++i) {
        rects->push_back(CaptureRect{monitors[i].x, monitors[i].y,
                                     monitors[i].width, monitors[i].height,
                                     monitors[i].primary != 0});
      }
      cap.XrrFreeMonitors(monitors);
    }
  }
  if (rects->empty() && cap.xinerama) {
    int count = 0;
    WbXineramaScreenInfo* screens = cap.XineramaQueryScreens(display, &count);
    if (screens != nullptr) {
      for (int i = 0; i < count; ++i) {
        rects->push_back(CaptureRect{screens[i].x_org, screens[i].y_org,
                                     screens[i].width, screens[i].height,
                                     i == 0});
      }
      cap.XineramaFreeScreens(screens);
    }
  }
  if (rects->empty()) {
    rects->push_back(CaptureRect{0, 0, root_width, root_height, true});
  }
  std::sort(rects->begin(), rects->end(),
            [](const CaptureRect& a, const CaptureRect& b) {
              if (a.y != b.y) {
                return a.y < b.y;
              }
              return a.x < b.x;
            });
}

// 依 display_id 选择目标显示器：-1 = 主显示器（无标记时取排序首项）；
// >= 0 = 排序序号；越界返回 nullptr（调用方映射 WB_ERR_FAILED）。
const CaptureRect* SelectMonitor(const std::vector<CaptureRect>& rects,
                                 int display_id) {
  if (rects.empty()) {
    return nullptr;
  }
  if (display_id == -1) {
    for (const CaptureRect& rect : rects) {
      if (rect.primary) {
        return &rect;
      }
    }
    return &rects[0];
  }
  if (display_id < 0 || display_id >= static_cast<int>(rects.size())) {
    return nullptr;
  }
  return &rects[static_cast<size_t>(display_id)];
}

// ===== 像素转换（掩码法，BGRA 输出）=====

// 通道掩码 →（低位零个数，右对齐最大值）；掩码为 0（通道缺失）时
// full = 0，输出恒 0。
void PrepareCaptureChannel(unsigned long mask, int* shift,
                           unsigned long* full) {
  int bits = 0;
  while (mask != 0 && (mask & 1UL) == 0) {
    mask >>= 1;
    ++bits;
  }
  *shift = bits;
  *full = mask;
}

// 通道值线性拉伸到 0..255（四舍五入；8 位掩码常见路径免除法）。
unsigned char ScaleCaptureChannel(unsigned long pixel, int shift,
                                  unsigned long full) {
  if (full == 0) {
    return 0;
  }
  const unsigned long value = (pixel >> shift) & full;
  if (full == 0xFFUL) {
    return static_cast<unsigned char>(value);
  }
  const unsigned long long scaled =
      static_cast<unsigned long long>(value) * 255ULL + full / 2ULL;
  return static_cast<unsigned char>(scaled / full);
}

// XImage → BGRA（stride = width*4，alpha = 255）。out 缓冲由调用方分配，
// 尺寸须 >= stride * height。仅支持 8/16/24/32 bpp；其余安全失败。
bool ConvertImageToBgra(const XImage* image, unsigned char* out, int stride) {
  if (image == nullptr || image->data == nullptr || out == nullptr) {
    return false;
  }
  const int width = image->width;
  const int height = image->height;
  const int bpp = image->bits_per_pixel;
  if (width <= 0 || height <= 0 || stride < width * 4) {
    return false;
  }
  if (bpp != 8 && bpp != 16 && bpp != 24 && bpp != 32) {
    return false;  // 未支持的像素位宽：不猜测布局，安全失败。
  }

  int red_shift = 0;
  int green_shift = 0;
  int blue_shift = 0;
  unsigned long red_full = 0;
  unsigned long green_full = 0;
  unsigned long blue_full = 0;
  PrepareCaptureChannel(image->red_mask, &red_shift, &red_full);
  PrepareCaptureChannel(image->green_mask, &green_shift, &green_full);
  PrepareCaptureChannel(image->blue_mask, &blue_shift, &blue_full);

  const bool lsb_first = image->byte_order == LSBFirst;
  const int bytes_per_line = image->bytes_per_line;
  const int bytes_per_pixel = bpp / 8;
  const unsigned char* data =
      reinterpret_cast<const unsigned char*>(image->data);

  for (int y = 0; y < height; ++y) {
    const unsigned char* row =
        data + static_cast<size_t>(y) * static_cast<size_t>(bytes_per_line);
    unsigned char* dst_row =
        out + static_cast<size_t>(y) * static_cast<size_t>(stride);
    for (int x = 0; x < width; ++x) {
      const unsigned char* pixel_bytes =
          row + static_cast<size_t>(x) * static_cast<size_t>(bytes_per_pixel);
      unsigned long pixel = 0;
      if (bpp == 32) {
        if (lsb_first) {
          pixel = static_cast<unsigned long>(pixel_bytes[0]) |
                  (static_cast<unsigned long>(pixel_bytes[1]) << 8) |
                  (static_cast<unsigned long>(pixel_bytes[2]) << 16) |
                  (static_cast<unsigned long>(pixel_bytes[3]) << 24);
        } else {
          pixel = (static_cast<unsigned long>(pixel_bytes[0]) << 24) |
                  (static_cast<unsigned long>(pixel_bytes[1]) << 16) |
                  (static_cast<unsigned long>(pixel_bytes[2]) << 8) |
                  static_cast<unsigned long>(pixel_bytes[3]);
        }
      } else if (bpp == 24) {
        if (lsb_first) {
          pixel = static_cast<unsigned long>(pixel_bytes[0]) |
                  (static_cast<unsigned long>(pixel_bytes[1]) << 8) |
                  (static_cast<unsigned long>(pixel_bytes[2]) << 16);
        } else {
          pixel = (static_cast<unsigned long>(pixel_bytes[0]) << 16) |
                  (static_cast<unsigned long>(pixel_bytes[1]) << 8) |
                  static_cast<unsigned long>(pixel_bytes[2]);
        }
      } else if (bpp == 16) {
        if (lsb_first) {
          pixel = static_cast<unsigned long>(pixel_bytes[0]) |
                  (static_cast<unsigned long>(pixel_bytes[1]) << 8);
        } else {
          pixel = (static_cast<unsigned long>(pixel_bytes[0]) << 8) |
                  static_cast<unsigned long>(pixel_bytes[1]);
        }
      } else {  // bpp == 8
        pixel = static_cast<unsigned long>(pixel_bytes[0]);
      }
      unsigned char* dst = dst_row + static_cast<size_t>(x) * 4U;
      dst[0] = ScaleCaptureChannel(pixel, blue_shift, blue_full);
      dst[1] = ScaleCaptureChannel(pixel, green_shift, green_full);
      dst[2] = ScaleCaptureChannel(pixel, red_shift, red_full);
      dst[3] = 255;
    }
  }
  return true;
}

// ===== 捕获主流程（X11 主线程 + 共享连接锁内执行）=====

int CaptureDisplayOnX11(int display_id, unsigned char** out_bytes, int* out_len,
                        int* out_width, int* out_height, int* out_stride) {
  X11Api& x11 = X11Api::Get();
  if (!x11.core || x11.GetImage == nullptr || x11.DestroyImage == nullptr) {
    return WB_ERR_FAILED;  // libX11 或 XGetImage 符号不可用。
  }
  CaptureApi& cap = CaptureApi::Get();

  std::lock_guard<std::mutex> lock(X11MainDisplayMutex());
  Display* display = X11MainDisplay();
  if (display == nullptr) {
    return WB_ERR_FAILED;  // 无可用 X server（headless）。
  }
  const Window root = x11.DefaultRootWindow(display);

  XWindowAttributes attributes;
  if (x11.GetWindowAttributes(display, root, &attributes) == 0 ||
      attributes.width <= 0 || attributes.height <= 0) {
    return WB_ERR_FAILED;
  }
  const int root_width = attributes.width;
  const int root_height = attributes.height;

  std::vector<CaptureRect> rects;
  CollectMonitors(cap, display, root, root_width, root_height, &rects);
  const CaptureRect* target = SelectMonitor(rects, display_id);
  if (target == nullptr) {
    return WB_ERR_FAILED;
  }

  // 与 root 边界求交（裁剪越界区域；完全越界 → 失败）。
  long long x0 = target->x;
  long long y0 = target->y;
  long long x1 = target->x + target->width;
  long long y1 = target->y + target->height;
  if (x0 < 0) {
    x0 = 0;
  }
  if (y0 < 0) {
    y0 = 0;
  }
  if (x1 > root_width) {
    x1 = root_width;
  }
  if (y1 > root_height) {
    y1 = root_height;
  }
  if (x1 <= x0 || y1 <= y0) {
    return WB_ERR_FAILED;
  }
  const int cap_width = static_cast<int>(x1 - x0);
  const int cap_height = static_cast<int>(y1 - y0);
  if (cap_width > 32768 || cap_height > 32768) {
    return WB_ERR_FAILED;  // 防御异常几何。
  }
  const long long buffer_size_ll =
      static_cast<long long>(cap_width) * 4LL * static_cast<long long>(cap_height);
  if (buffer_size_ll > 1073741824LL) {
    return WB_ERR_FAILED;  // 1 GiB 上限（out_len 为 int，防溢出）。
  }

  // XGetImage 期间的协议错误（如 BadMatch）由捕获态记录；绝不触发 Xlib
  // 默认 handler 的退出行为。
  X11ErrorTrap trap(display);
  XImage* image = x11.GetImage(
      display, root, static_cast<int>(x0), static_cast<int>(y0),
      static_cast<unsigned int>(cap_width),
      static_cast<unsigned int>(cap_height), AllPlanes, ZPixmap);
  const bool had_error = trap.FinishAndCheck();
  if (image == nullptr || had_error) {
    if (image != nullptr) {
      x11.DestroyImage(image);
    }
    return WB_ERR_FAILED;
  }

  const int stride = cap_width * 4;
  const size_t buffer_size = static_cast<size_t>(cap_width) * 4U *
                             static_cast<size_t>(cap_height);
  auto* buffer = static_cast<unsigned char*>(std::malloc(buffer_size));
  if (buffer == nullptr) {
    x11.DestroyImage(image);
    return WB_ERR_FAILED;
  }
  const bool converted = ConvertImageToBgra(image, buffer, stride);
  x11.DestroyImage(image);
  if (!converted) {
    std::free(buffer);
    return WB_ERR_FAILED;
  }

  *out_bytes = buffer;
  *out_len = static_cast<int>(buffer_size);
  *out_width = cap_width;
  *out_height = cap_height;
  *out_stride = stride;
  return WB_OK;
}

// ===== 对外 ABI：3 个捕获符号 =====

extern "C" WB_LINUX_API int wb_linux_capture_display(
    int display_id, unsigned char** out_bytes, int* out_len, int* out_width,
    int* out_height, int* out_stride) {
  WB_LINUX_TRY {
    if (out_bytes == nullptr || out_len == nullptr || out_width == nullptr ||
        out_height == nullptr || out_stride == nullptr) {
      return WB_ERR_FAILED;
    }
    *out_bytes = nullptr;
    *out_len = 0;
    *out_width = 0;
    *out_height = 0;
    *out_stride = 0;
    switch (ResolveSessionBackend()) {
      case SessionBackend::kX11:
        return CaptureDisplayOnX11(display_id, out_bytes, out_len, out_width,
                                   out_height, out_stride);
      case SessionBackend::kWayland:
        // 无抓屏协议（需 xdg-desktop-portal + PipeWire），安全降级。
        return WB_ERR_UNSUPPORTED;
      case SessionBackend::kNone:
        break;
    }
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_UNSUPPORTED;
}

extern "C" WB_LINUX_API void wb_linux_capture_free(unsigned char* bytes) {
  // 与 wb_linux_capture_display 的 std::malloc 配对；NULL 安全
  // （Dart 侧 finally 路径可能以任意状态调用）。
  std::free(bytes);
}

extern "C" WB_LINUX_API int wb_linux_capture_is_available(void) {
  WB_LINUX_TRY {
    switch (ResolveSessionBackend()) {
      case SessionBackend::kX11: {
        X11Api& x11 = X11Api::Get();
        if (!x11.core || x11.GetImage == nullptr ||
            x11.DestroyImage == nullptr) {
          return WB_ERR_FAILED;
        }
        // 实际连接校验（懒连接进程内缓存；无 X server → 不可用）。
        std::lock_guard<std::mutex> lock(X11MainDisplayMutex());
        return X11MainDisplay() != nullptr ? WB_OK : WB_ERR_FAILED;
      }
      case SessionBackend::kWayland:
        return WB_ERR_UNSUPPORTED;
      case SessionBackend::kNone:
        break;
    }
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_UNSUPPORTED;
}

}  // namespace wb::platform::linux_

#else  // !WB_LINUX_HAVE_X11

// 无 X11 头文件（或未启用 X11 后端）的构建：捕获能力整体安全降级，
// 无任何 Xlib 依赖。
#include <cstdlib>

namespace wb::platform::linux_ {

extern "C" WB_LINUX_API int wb_linux_capture_display(
    int /*display_id*/, unsigned char** out_bytes, int* out_len,
    int* out_width, int* out_height, int* out_stride) {
  // 输出参数清零（防御调用方直接读取未初始化槽位）。
  if (out_bytes != nullptr) {
    *out_bytes = nullptr;
  }
  if (out_len != nullptr) {
    *out_len = 0;
  }
  if (out_width != nullptr) {
    *out_width = 0;
  }
  if (out_height != nullptr) {
    *out_height = 0;
  }
  if (out_stride != nullptr) {
    *out_stride = 0;
  }
  return WB_ERR_UNSUPPORTED;
}

extern "C" WB_LINUX_API void wb_linux_capture_free(unsigned char* bytes) {
  // 符号必须可查找（Dart 侧整体加载依赖它）；free(NULL) 恒安全。
  std::free(bytes);
}

extern "C" WB_LINUX_API int wb_linux_capture_is_available(void) {
  return WB_ERR_UNSUPPORTED;
}

}  // namespace wb::platform::linux_

#endif  // WB_LINUX_HAVE_X11
