// whiteboard_linux 插件 · X11 / XWayland 后端实现（C++20，运行时动态加载）。
//
// 覆盖《透明批注模式技术方案》§7.3 的 X11 通路：
//   * 透明：_NET_WM_WINDOW_TYPE 置为 _NET_WM_WINDOW_TYPE_DOCK（原值保存，
//     关闭时还原；实际透视由运行中的合成器 + 应用侧 ARGB 视觉决定）；
//   * 置顶 / 全屏：EWMH ClientMessage（_NET_WM_STATE_ADD / REMOVE）+
//     _NET_WM_STATE 属性直接更新「双保险」；
//   * 穿透：XShape 输入区域置空（关闭时以整窗矩形恢复）；
//   * 位置 / 尺寸：EWMH _NET_MOVERESIZE_WINDOW + XMove/Resize 直接请求。
//
// 依赖策略：全部 libX11 / libXext 符号经 dlopen/dlsym 获取（无链接期
// 依赖）；库缺失或副本损坏时整体安全降级（返回错误码，绝不崩溃）。
//
// X 错误处理：libX11 加载成功后安装一次分流处理器——
//   * 处于捕获态（X11ErrorTrap）的本线程错误 → 记录待查；
//   * 其余线程 / 时段 → 转发链上的旧处理器（如 GDK 的），无旧处理器时
//     静默忽略；绝不调用 Xlib 默认处理器（其行为是 exit(1)，会杀死宿主）；
//   * I/O 错误（连接断开等）：经 XSetIOErrorHandler 安装静默处理器，
//     抑制 Xlib 默认的进程终止行为。
//
// 主窗口发现策略（FindMainWindowLocked）：
//   1. WB_LINUX_WINDOW_ID 显式指定（十进制 / 0x 十六进制 XID）；
//   2. 进程内缓存（XGetWindowAttributes 校验，失效自动重查）；
//   3. root 子树两层扫描 + 打分：_NET_WM_PID == 本进程 +200（PID 明确为
//      其它进程的窗口直接排除）、WM_CLASS 子串（环境变量
//      WB_LINUX_WINDOW_CLASS，默认 "whiteboard"）+100、标题（_NET_WM_NAME /
//      WM_NAME，WB_LINUX_WINDOW_TITLE，默认 "whiteboard"）+50；无身份命中时
//      以「首个可见、非 override_redirect、非 DOCK/DESKTOP/NOTIFICATION
//      等特殊类型」的顶层窗口兜底。缓存窗口在透明模式自身变为 DOCK 后
//      仍由 PID / WM_CLASS 命中，不受特殊类型排除影响。
//
// 线程约束：本文件的 X11WindowSet* 由 window_plugin.cpp 分发调用，均在
// Dart 主 isolate 线程执行；共享主连接由 X11MainDisplayMutex() 串行化。

#include "window_plugin.h"

#if defined(WB_LINUX_HAVE_X11)

#include <X11/Xlib.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace wb::platform::linux_ {

// ===== 运行时符号加载与全局 X 错误处理 =====

namespace {

void* g_x11_library = nullptr;
void* g_xext_library = nullptr;
bool g_error_handler_installed = false;
bool g_io_handler_installed = false;
std::atomic<XErrorHandler> g_previous_error_handler{nullptr};
thread_local bool g_trap_active = false;
thread_local unsigned char g_trap_error = 0;

// 分流错误处理器：捕获态线程记录；否则转发旧处理器；无旧处理器静默。
int WbX11ErrorHandler(Display* display, XErrorEvent* event) {
  if (g_trap_active) {
    if (g_trap_error == 0 && event != nullptr) {
      g_trap_error = event->error_code;
    }
    return 0;
  }
  XErrorHandler previous = g_previous_error_handler.load();
  if (previous != nullptr) {
    return previous(display, event);
  }
  return 0;
}

// I/O 错误处理器：X 连接断开等致命 I/O 错误发生时，抑制 Xlib 默认
// 处理器（打印错误后 exit(1)，会杀死宿主）。直接返回：断连连接上的
// 后续请求自然失败，由各调用点映射为错误码，绝不终止宿主进程。
int WbX11IoErrorHandler(Display* /*display*/) { return 0; }

// 幂等加载（允许「先失败后可用」场景重试；dlopen 由内核缓存，代价极小）。
void LoadX11Symbols(X11Api& api) {
  static const char* const kLibX11Names[] = {"libX11.so.6", "libX11.so"};
  static const char* const kLibXextNames[] = {"libXext.so.6", "libXext.so"};

  if (g_x11_library == nullptr) {
    g_x11_library = DlOpenFirst(kLibX11Names, 2);
  }
  void* x11 = g_x11_library;
  if (x11 == nullptr) {
    return;
  }

  api.OpenDisplay = DlSymAs<decltype(api.OpenDisplay)>(x11, "XOpenDisplay");
  api.CloseDisplay = DlSymAs<decltype(api.CloseDisplay)>(x11, "XCloseDisplay");
  api.DefaultRootWindow =
      DlSymAs<decltype(api.DefaultRootWindow)>(x11, "XDefaultRootWindow");
  api.QueryTree = DlSymAs<decltype(api.QueryTree)>(x11, "XQueryTree");
  api.Free = DlSymAs<decltype(api.Free)>(x11, "XFree");
  api.InternAtom = DlSymAs<decltype(api.InternAtom)>(x11, "XInternAtom");
  api.GetWindowProperty =
      DlSymAs<decltype(api.GetWindowProperty)>(x11, "XGetWindowProperty");
  api.ChangeProperty =
      DlSymAs<decltype(api.ChangeProperty)>(x11, "XChangeProperty");
  api.DeleteProperty =
      DlSymAs<decltype(api.DeleteProperty)>(x11, "XDeleteProperty");
  api.SendEvent = DlSymAs<decltype(api.SendEvent)>(x11, "XSendEvent");
  api.Sync = DlSymAs<decltype(api.Sync)>(x11, "XSync");
  api.Flush = DlSymAs<decltype(api.Flush)>(x11, "XFlush");
  api.MoveWindow = DlSymAs<decltype(api.MoveWindow)>(x11, "XMoveWindow");
  api.ResizeWindow = DlSymAs<decltype(api.ResizeWindow)>(x11, "XResizeWindow");
  api.MoveResizeWindow =
      DlSymAs<decltype(api.MoveResizeWindow)>(x11, "XMoveResizeWindow");
  api.RaiseWindow = DlSymAs<decltype(api.RaiseWindow)>(x11, "XRaiseWindow");
  api.GetWindowAttributes = DlSymAs<decltype(api.GetWindowAttributes)>(
      x11, "XGetWindowAttributes");
  api.StringToKeysym =
      DlSymAs<decltype(api.StringToKeysym)>(x11, "XStringToKeysym");
  api.KeysymToKeycode =
      DlSymAs<decltype(api.KeysymToKeycode)>(x11, "XKeysymToKeycode");
  api.GrabKey = DlSymAs<decltype(api.GrabKey)>(x11, "XGrabKey");
  api.UngrabKey = DlSymAs<decltype(api.UngrabKey)>(x11, "XUngrabKey");
  api.SelectInput = DlSymAs<decltype(api.SelectInput)>(x11, "XSelectInput");
  api.NextEvent = DlSymAs<decltype(api.NextEvent)>(x11, "XNextEvent");
  api.Pending = DlSymAs<decltype(api.Pending)>(x11, "XPending");
  api.ConnectionNumber =
      DlSymAs<decltype(api.ConnectionNumber)>(x11, "XConnectionNumber");
  api.SetErrorHandler =
      DlSymAs<decltype(api.SetErrorHandler)>(x11, "XSetErrorHandler");
  api.GetImage = DlSymAs<decltype(api.GetImage)>(x11, "XGetImage");
  api.DestroyImage = DlSymAs<decltype(api.DestroyImage)>(x11, "XDestroyImage");
  api.GetErrorText = DlSymAs<decltype(api.GetErrorText)>(x11, "XGetErrorText");

  // core = 全部基础符号就绪（libX11 任一正常版本均完整导出）。
  api.core = api.OpenDisplay != nullptr && api.CloseDisplay != nullptr &&
             api.DefaultRootWindow != nullptr && api.QueryTree != nullptr &&
             api.Free != nullptr && api.InternAtom != nullptr &&
             api.GetWindowProperty != nullptr && api.ChangeProperty != nullptr &&
             api.DeleteProperty != nullptr && api.SendEvent != nullptr &&
             api.Sync != nullptr && api.Flush != nullptr &&
             api.MoveWindow != nullptr && api.ResizeWindow != nullptr &&
             api.MoveResizeWindow != nullptr && api.RaiseWindow != nullptr &&
             api.GetWindowAttributes != nullptr &&
             api.StringToKeysym != nullptr &&
             api.KeysymToKeycode != nullptr && api.GrabKey != nullptr &&
             api.UngrabKey != nullptr && api.NextEvent != nullptr &&
             api.Pending != nullptr && api.ConnectionNumber != nullptr &&
             api.SetErrorHandler != nullptr && api.GetImage != nullptr &&
             api.DestroyImage != nullptr;

  // 错误分流处理器：仅在首次加载成功时安装（保留链上旧处理器）。
  if (api.core && !g_error_handler_installed) {
    g_error_handler_installed = true;
    g_previous_error_handler.store(api.SetErrorHandler(WbX11ErrorHandler));
  }

  // I/O 错误分流：同样仅安装一次（XSetIOErrorHandler 为进程级全局槽位）。
  if (api.core && !g_io_handler_installed) {
    using SetIoErrorHandlerFn = XIOErrorHandler (*)(XIOErrorHandler);
    SetIoErrorHandlerFn set_io_error_handler =
        DlSymAs<SetIoErrorHandlerFn>(x11, "XSetIOErrorHandler");
    if (set_io_error_handler != nullptr) {
      g_io_handler_installed = true;
      (void)set_io_error_handler(WbX11IoErrorHandler);
    }
  }

  if (g_xext_library == nullptr) {
    g_xext_library = DlOpenFirst(kLibXextNames, 2);
  }
  if (g_xext_library != nullptr) {
    api.ShapeQueryExtension = DlSymAs<decltype(api.ShapeQueryExtension)>(
        g_xext_library, "XShapeQueryExtension");
    api.ShapeCombineRectangles = DlSymAs<decltype(api.ShapeCombineRectangles)>(
        g_xext_library, "XShapeCombineRectangles");
  }
  api.shape =
      api.ShapeQueryExtension != nullptr && api.ShapeCombineRectangles != nullptr;
}

}  // namespace

X11Api& X11Api::Get() {
  static X11Api instance;
  static std::mutex mutex;
  std::lock_guard<std::mutex> lock(mutex);
  if (!instance.core) {
    LoadX11Symbols(instance);
  }
  return instance;
}

// ===== X11ErrorTrap =====

X11ErrorTrap::X11ErrorTrap(Display* display) : display_(display) {
  g_trap_error = 0;
  g_trap_active = true;
}

X11ErrorTrap::~X11ErrorTrap() {
  if (!finished_) {
    FinishAndCheck();
  }
}

bool X11ErrorTrap::FinishAndCheck() {
  if (finished_) {
    return error_code_ != 0;
  }
  finished_ = true;
  if (display_ != nullptr) {
    X11Api& api = X11Api::Get();
    if (api.Sync != nullptr) {
      // 冲刷请求队列并等待服务器处理完毕：确保此前请求的异步错误已投递。
      api.Sync(display_, False);
    }
  }
  if (g_trap_error != 0 && error_code_ == 0) {
    error_code_ = g_trap_error;
  }
  g_trap_active = false;
  return error_code_ != 0;
}

// ===== 主线程共享连接 =====

Display* X11MainDisplay() {
  // 调用方必须持有 X11MainDisplayMutex()（头文件约定）；静态连接只在
  // 持锁路径访问。打开失败不缓存，后续调用重试。
  static Display* display = nullptr;
  if (display == nullptr) {
    X11Api& api = X11Api::Get();
    if (!api.core || api.OpenDisplay == nullptr) {
      return nullptr;
    }
    display = api.OpenDisplay(nullptr);
  }
  return display;
}

std::mutex& X11MainDisplayMutex() {
  static std::mutex mutex;
  return mutex;
}

// ===== 窗口发现与操作实现 =====

namespace {

// ---- 常量（与 X11/Xatom.h、X.h 协议值一致；不引入额外头文件）----
constexpr long kXaAtom = 4;                  // XA_ATOM
constexpr int kClientMessage = 33;           // ClientMessage
constexpr long kSubstructureNotifyMask = 1L << 19;
constexpr long kSubstructureRedirectMask = 1L << 20;
constexpr int kShapeInput = 2;               // ShapeInput（X11/extensions/shape.h）
constexpr int kShapeSet = 0;                 // ShapeSet

// ---- 状态（仅在持有 X11MainDisplayMutex() 的路径访问）----

struct X11Atoms {
  bool loaded = false;
  Atom wm_class = None;
  Atom wm_name = None;
  Atom net_wm_name = None;
  Atom net_wm_pid = None;
  Atom net_wm_window_type = None;
  Atom net_wm_state = None;
  Atom net_wm_state_above = None;
  Atom net_wm_state_fullscreen = None;
  Atom net_moveresize_window = None;
  Atom window_type_dock = None;
  Atom special_types[9] = {};
};

X11Atoms g_atoms;

// 主窗口缓存（XGetWindowAttributes 校验；None 表示未命中 / 已失效）。
Window g_cached_top_window = None;

// 透明模式保存的 _NET_WM_WINDOW_TYPE 原值（用于关闭时还原）。
struct SavedWindowType {
  bool valid = false;
  Window target = None;
  Atom type = None;
  int format = 0;
  std::vector<unsigned char> bytes;
};

SavedWindowType g_saved_window_type;

// ---- 属性读取 ----

struct PropertyData {
  Atom type = None;
  int format = 0;
  std::vector<unsigned char> bytes;
};

PropertyData ReadWindowProperty(Display* display, Window window, Atom property) {
  PropertyData result;
  X11Api& api = X11Api::Get();
  if (!api.core || property == None) {
    return result;
  }
  Atom actual_type = None;
  int actual_format = 0;
  unsigned long items = 0;
  unsigned long bytes_after = 0;
  unsigned char* data = nullptr;
  const int status = api.GetWindowProperty(
      display, window, property, 0, 1024, False, 0 /* AnyPropertyType */,
      &actual_type, &actual_format, &items, &bytes_after, &data);
  if (status != Success) {
    return result;
  }
  result.type = actual_type;
  result.format = actual_format;
  if (data != nullptr) {
    const size_t unit =
        actual_format > 0 ? static_cast<size_t>(actual_format) / 8 : 0;
    if (unit > 0 && items > 0 && items <= 4096) {
      result.bytes.assign(data, data + items * unit);
    }
    api.Free(data);
  }
  return result;
}

std::string PropertyToUtf8String(const PropertyData& data) {
  if (data.format != 8) {
    return std::string();
  }
  std::string text(data.bytes.begin(), data.bytes.end());
  while (!text.empty() && text.back() == '\0') {
    text.pop_back();
  }
  return text;
}

// WM_CLASS 为两个 NUL 结尾字符串（instance / class），拼接后供子串匹配。
std::string WindowClassOf(const PropertyData& data) {
  if (data.format != 8 || data.bytes.empty()) {
    return std::string();
  }
  const std::vector<unsigned char>& bytes = data.bytes;
  size_t first_end = 0;
  while (first_end < bytes.size() && bytes[first_end] != 0) {
    ++first_end;
  }
  std::string combined(bytes.begin(), bytes.begin() + first_end);
  const size_t second_begin = first_end + 1;
  if (second_begin < bytes.size()) {
    size_t second_end = second_begin;
    while (second_end < bytes.size() && bytes[second_end] != 0) {
      ++second_end;
    }
    if (second_end > second_begin) {
      combined.push_back(' ');
      combined.append(bytes.begin() + second_begin, bytes.begin() + second_end);
    }
  }
  return combined;
}

long long PropertyToPid(const PropertyData& data) {
  if (data.format != 32 || data.bytes.size() < sizeof(long)) {
    return -1;
  }
  long value = 0;
  std::memcpy(&value, data.bytes.data(), sizeof(long));
  return static_cast<long long>(value);
}

bool HasSpecialWindowType(const PropertyData& data) {
  if (data.format != 32 || data.bytes.empty()) {
    return false;
  }
  const size_t count = data.bytes.size() / sizeof(long);
  for (size_t i = 0; i < count; ++i) {
    long atom = 0;
    std::memcpy(&atom, data.bytes.data() + i * sizeof(long), sizeof(long));
    for (const Atom special : g_atoms.special_types) {
      if (special != None && static_cast<unsigned long>(atom) == special) {
        return true;
      }
    }
  }
  return false;
}

void EnsureAtomsLoaded(Display* display) {
  if (g_atoms.loaded) {
    return;
  }
  X11Api& api = X11Api::Get();
  if (!api.core) {
    return;
  }
  X11Atoms& atoms = g_atoms;
  atoms.wm_class = api.InternAtom(display, "WM_CLASS", False);
  atoms.wm_name = api.InternAtom(display, "WM_NAME", False);
  atoms.net_wm_name = api.InternAtom(display, "_NET_WM_NAME", False);
  atoms.net_wm_pid = api.InternAtom(display, "_NET_WM_PID", False);
  atoms.net_wm_window_type =
      api.InternAtom(display, "_NET_WM_WINDOW_TYPE", False);
  atoms.net_wm_state = api.InternAtom(display, "_NET_WM_STATE", False);
  atoms.net_wm_state_above =
      api.InternAtom(display, "_NET_WM_STATE_ABOVE", False);
  atoms.net_wm_state_fullscreen =
      api.InternAtom(display, "_NET_WM_STATE_FULLSCREEN", False);
  atoms.net_moveresize_window =
      api.InternAtom(display, "_NET_MOVERESIZE_WINDOW", False);
  atoms.window_type_dock =
      api.InternAtom(display, "_NET_WM_WINDOW_TYPE_DOCK", False);
  static const char* const kSpecialTypeNames[9] = {
      "_NET_WM_WINDOW_TYPE_DOCK",     "_NET_WM_WINDOW_TYPE_DESKTOP",
      "_NET_WM_WINDOW_TYPE_SPLASH",   "_NET_WM_WINDOW_TYPE_NOTIFICATION",
      "_NET_WM_WINDOW_TYPE_TOOLTIP",  "_NET_WM_WINDOW_TYPE_POPUP_MENU",
      "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU", "_NET_WM_WINDOW_TYPE_COMBO",
      "_NET_WM_WINDOW_TYPE_DND",
  };
  for (size_t i = 0; i < 9; ++i) {
    atoms.special_types[i] = api.InternAtom(display, kSpecialTypeNames[i], False);
  }
  atoms.loaded = true;
}

// ---- 主窗口发现 ----

bool IsUsableWindow(Display* display, Window window) {
  X11Api& api = X11Api::Get();
  if (!api.core || window == None) {
    return false;
  }
  XWindowAttributes attrs{};
  if (api.GetWindowAttributes(display, window, &attrs) == 0) {
    return false;
  }
  return attrs.class_ == InputOutput;
}

Window ParseWindowId(const std::string& text) {
  const bool hex =
      text.size() > 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X');
  const std::string digits = hex ? text.substr(2) : text;
  if (digits.empty() ||
      digits.find_first_not_of(hex ? "0123456789abcdefABCDEF" : "0123456789") !=
          std::string::npos) {
    return None;
  }
  const unsigned long long value =
      std::strtoull(digits.c_str(), nullptr, hex ? 16 : 10);
  if (value == 0) {
    return None;
  }
  return static_cast<Window>(value);
}

struct WindowCandidate {
  Window window = None;
  int score = -1;
  bool viewable = false;
  long long area = 0;
};

bool CandidateWins(int score, bool viewable, long long area,
                   const WindowCandidate& best) {
  if (score != best.score) {
    return score > best.score;
  }
  if (viewable != best.viewable) {
    return viewable;
  }
  return area > best.area;
}

void ConsiderWindow(Display* display, Window window, Window root,
                    const std::string& want_class,
                    const std::string& want_title, WindowCandidate* best) {
  if (window == None || window == root) {
    return;
  }
  X11Api& api = X11Api::Get();
  XWindowAttributes attrs{};
  if (api.GetWindowAttributes(display, window, &attrs) == 0) {
    return;
  }
  if (attrs.class_ != InputOutput || attrs.override_redirect != False) {
    return;
  }
  const bool viewable = attrs.map_state == IsViewable;

  int score = 0;
  // 进程归属（_NET_WM_PID == 本进程）为最强信号；明确属于其它进程的
  // 窗口直接排除，避免跨应用窗口误操作。
  const long long pid =
      PropertyToPid(ReadWindowProperty(display, window, g_atoms.net_wm_pid));
  if (pid > 0) {
    if (pid != static_cast<long long>(::getpid())) {
      return;
    }
    score += 200;
  }
  const std::string window_class =
      WindowClassOf(ReadWindowProperty(display, window, g_atoms.wm_class));
  if (!want_class.empty() &&
      ContainsCaseInsensitive(window_class, want_class)) {
    score += 100;
  }
  std::string title = PropertyToUtf8String(
      ReadWindowProperty(display, window, g_atoms.net_wm_name));
  if (title.empty()) {
    title = PropertyToUtf8String(
        ReadWindowProperty(display, window, g_atoms.wm_name));
  }
  if (!want_title.empty() &&
      ContainsCaseInsensitive(title, want_title)) {
    score += 50;
  }

  const long long area =
      static_cast<long long>(attrs.width) * static_cast<long long>(attrs.height);
  if (score > 0) {
    if (CandidateWins(score, viewable, area, *best)) {
      best->window = window;
      best->score = score;
      best->viewable = viewable;
      best->area = area;
    }
    return;
  }

  // 零分兜底：仅在尚无任何身份命中时考虑；要求可见、非特殊窗口类型。
  if (best->score > 0 || !viewable) {
    return;
  }
  if (HasSpecialWindowType(
          ReadWindowProperty(display, window, g_atoms.net_wm_window_type))) {
    return;
  }
  if (CandidateWins(0, viewable, area, *best)) {
    best->window = window;
    best->score = 0;
    best->viewable = viewable;
    best->area = area;
  }
}

Window FindMainWindowLocked(Display* display) {
  X11Api& api = X11Api::Get();
  if (!api.core) {
    return None;
  }

  // 1) 显式指定（测试 / 特殊宿主）。
  const std::string explicit_id = EnvString("WB_LINUX_WINDOW_ID");
  if (!explicit_id.empty()) {
    const Window explicit_window = ParseWindowId(explicit_id);
    if (explicit_window != None && IsUsableWindow(display, explicit_window)) {
      return explicit_window;
    }
  }

  // 2) 缓存（属性校验失败自动失效重查）。
  if (g_cached_top_window != None &&
      IsUsableWindow(display, g_cached_top_window)) {
    return g_cached_top_window;
  }
  g_cached_top_window = None;

  // 3) root 子树两层扫描 + 打分。
  EnsureAtomsLoaded(display);
  const Window root = api.DefaultRootWindow(display);
  if (root == None) {
    return None;
  }
  const std::string want_class =
      EnvOrDefault("WB_LINUX_WINDOW_CLASS", "whiteboard");
  const std::string want_title =
      EnvOrDefault("WB_LINUX_WINDOW_TITLE", "whiteboard");

  WindowCandidate best;
  Window root_ret = None;
  Window parent_ret = None;
  Window* children = nullptr;
  unsigned int child_count = 0;
  if (api.QueryTree(display, root, &root_ret, &parent_ret, &children,
                    &child_count) == 0) {
    return None;
  }
  for (unsigned int i = 0; i < child_count; ++i) {
    const Window top = children[i];
    if (top == None) {
      continue;
    }
    ConsiderWindow(display, top, root, want_class, want_title, &best);
    // 深度 2：窗口管理器重父化后（frame → client），目标常为顶层窗口的
    // 直接子窗口；GTK 客户端侧的额外根也在此覆盖。
    Window frame_root = None;
    Window frame_parent = None;
    Window* grand_children = nullptr;
    unsigned int grand_count = 0;
    if (api.QueryTree(display, top, &frame_root, &frame_parent, &grand_children,
                      &grand_count) != 0) {
      for (unsigned int j = 0; j < grand_count; ++j) {
        ConsiderWindow(display, grand_children[j], root, want_class, want_title,
                       &best);
      }
      if (grand_children != nullptr) {
        api.Free(grand_children);
      }
    }
  }
  if (children != nullptr) {
    api.Free(children);
  }

  g_cached_top_window = best.window;
  return best.window;
}

// ---- 各能力操作 ----

int ApplyTransparent(Display* display, Window window, bool transparent) {
  X11Api& api = X11Api::Get();
  EnsureAtomsLoaded(display);
  if (transparent) {
    // 首次启用（或目标窗口已变化）：保存原 _NET_WM_WINDOW_TYPE。
    if (!g_saved_window_type.valid || g_saved_window_type.target != window) {
      const PropertyData current =
          ReadWindowProperty(display, window, g_atoms.net_wm_window_type);
      g_saved_window_type = SavedWindowType{};
      g_saved_window_type.valid = true;
      g_saved_window_type.target = window;
      g_saved_window_type.type = current.type;
      g_saved_window_type.format = current.format;
      g_saved_window_type.bytes = current.bytes;
    }
    const Atom dock = g_atoms.window_type_dock;
    api.ChangeProperty(display, window, g_atoms.net_wm_window_type, kXaAtom, 32,
                       PropModeReplace,
                       reinterpret_cast<const unsigned char*>(&dock), 1);
    return WB_OK;
  }

  // 关闭透明：还原保存的原值（原属性不存在则删除我们写入的属性）。
  if (!g_saved_window_type.valid || g_saved_window_type.target != window) {
    return WB_OK;  // 从未启用（或目标已变化）：无状态可还原，视为成功。
  }
  if (g_saved_window_type.type == None) {
    api.DeleteProperty(display, window, g_atoms.net_wm_window_type);
  } else {
    const int unit = g_saved_window_type.format / 8;
    if (unit > 0 && !g_saved_window_type.bytes.empty() &&
        g_saved_window_type.bytes.size() % static_cast<size_t>(unit) == 0) {
      api.ChangeProperty(
          display, window, g_atoms.net_wm_window_type, g_saved_window_type.type,
          g_saved_window_type.format, PropModeReplace,
          g_saved_window_type.bytes.data(),
          static_cast<int>(g_saved_window_type.bytes.size() / unit));
    }
  }
  g_saved_window_type = SavedWindowType{};
  return WB_OK;
}

void SendWmStateMessage(Display* display, Window window, Atom state, bool add) {
  X11Api& api = X11Api::Get();
  const Window root = api.DefaultRootWindow(display);
  XEvent event{};
  event.xclient.type = kClientMessage;
  event.xclient.window = window;
  event.xclient.message_type = g_atoms.net_wm_state;
  event.xclient.format = 32;
  event.xclient.data.l[0] = add ? 1 : 0;  // _NET_WM_STATE_ADD / REMOVE
  event.xclient.data.l[1] = static_cast<long>(state);
  event.xclient.data.l[2] = 0;
  event.xclient.data.l[3] = 1;  // source indication：application
  event.xclient.data.l[4] = 0;
  api.SendEvent(display, root, False,
                kSubstructureRedirectMask | kSubstructureNotifyMask, &event);
}

void UpdateWmStateProperty(Display* display, Window window, Atom state,
                           bool add) {
  X11Api& api = X11Api::Get();
  const PropertyData current =
      ReadWindowProperty(display, window, g_atoms.net_wm_state);
  std::vector<long> states;
  if (current.format == 32) {
    const size_t count = current.bytes.size() / sizeof(long);
    for (size_t i = 0; i < count; ++i) {
      long value = 0;
      std::memcpy(&value, current.bytes.data() + i * sizeof(long), sizeof(long));
      if (value != 0) {
        states.push_back(value);
      }
    }
  }
  const auto found =
      std::find(states.begin(), states.end(), static_cast<long>(state));
  if (add) {
    if (found == states.end()) {
      states.push_back(static_cast<long>(state));
    }
  } else if (found != states.end()) {
    states.erase(found);
  }
  if (states.empty()) {
    api.DeleteProperty(display, window, g_atoms.net_wm_state);
  } else {
    api.ChangeProperty(display, window, g_atoms.net_wm_state, kXaAtom, 32,
                       PropModeReplace,
                       reinterpret_cast<const unsigned char*>(states.data()),
                       static_cast<int>(states.size()));
  }
}

// EWMH 状态双保险：属性直接更新（无 WM 场景亦可观测）+ ClientMessage。
void ApplyWmState(Display* display, Window window, Atom state, bool add) {
  UpdateWmStateProperty(display, window, state, add);
  SendWmStateMessage(display, window, state, add);
}

int ApplyAlwaysOnTop(Display* display, Window window, bool on_top) {
  X11Api& api = X11Api::Get();
  EnsureAtomsLoaded(display);
  ApplyWmState(display, window, g_atoms.net_wm_state_above, on_top);
  if (on_top) {
    api.RaiseWindow(display, window);
  }
  return WB_OK;
}

int ApplyFullscreen(Display* display, Window window, bool fullscreen) {
  EnsureAtomsLoaded(display);
  ApplyWmState(display, window, g_atoms.net_wm_state_fullscreen, fullscreen);
  return WB_OK;
}

void SendMoveresizeMessage(Display* display, Window window, int x, int y,
                           int width, int height, bool set_x, bool set_y,
                           bool set_width, bool set_height) {
  X11Api& api = X11Api::Get();
  const Window root = api.DefaultRootWindow(display);
  long gravity_and_flags = 10;   // StaticGravity：坐标按客户端区域解释
  gravity_and_flags |= 1L << 8;  // source indication：application
  if (set_x) {
    gravity_and_flags |= 1L << 12;
  }
  if (set_y) {
    gravity_and_flags |= 1L << 13;
  }
  if (set_width) {
    gravity_and_flags |= 1L << 14;
  }
  if (set_height) {
    gravity_and_flags |= 1L << 15;
  }
  XEvent event{};
  event.xclient.type = kClientMessage;
  event.xclient.window = window;
  event.xclient.message_type = g_atoms.net_moveresize_window;
  event.xclient.format = 32;
  event.xclient.data.l[0] = gravity_and_flags;
  event.xclient.data.l[1] = x;
  event.xclient.data.l[2] = y;
  event.xclient.data.l[3] = width;
  event.xclient.data.l[4] = height;
  api.SendEvent(display, root, False,
                kSubstructureRedirectMask | kSubstructureNotifyMask, &event);
}

int ApplyPosition(Display* display, Window window, int x, int y) {
  X11Api& api = X11Api::Get();
  EnsureAtomsLoaded(display);
  // EWMH 优先 + 直接移动（无 WM / 普通 X11 语义的 ConfigureRequest）。
  SendMoveresizeMessage(display, window, x, y, 0, 0, true, true, false, false);
  api.MoveWindow(display, window, x, y);
  return WB_OK;
}

int ApplySize(Display* display, Window window, int width, int height) {
  X11Api& api = X11Api::Get();
  EnsureAtomsLoaded(display);
  SendMoveresizeMessage(display, window, 0, 0, width, height, false, false,
                        true, true);
  api.ResizeWindow(display, window, static_cast<unsigned int>(width),
                   static_cast<unsigned int>(height));
  return WB_OK;
}

int ApplyIgnoreMouseEvents(Display* display, Window window, bool ignore,
                           bool /*forward*/) {
  X11Api& api = X11Api::Get();
  if (!api.shape || api.ShapeCombineRectangles == nullptr) {
    return WB_ERR_UNSUPPORTED;
  }
  if (api.ShapeQueryExtension != nullptr) {
    int event_base = 0;
    int error_base = 0;
    if (api.ShapeQueryExtension(display, &event_base, &error_base) == False) {
      return WB_ERR_UNSUPPORTED;
    }
  }
  if (ignore) {
    // 空输入区域 → 指针事件全部穿透到底层窗口。
    api.ShapeCombineRectangles(display, window, kShapeInput, 0, 0, nullptr, 0,
                               kShapeSet, 0);
    return WB_OK;
  }
  // 关闭穿透：整窗矩形作为输入区域（恢复默认语义）。
  XWindowAttributes attrs{};
  if (api.GetWindowAttributes(display, window, &attrs) == 0) {
    return WB_ERR_FAILED;
  }
  XRectangle rect{};
  rect.x = 0;
  rect.y = 0;
  rect.width = static_cast<unsigned short>(
      attrs.width > 0xFFFF ? 0xFFFF : attrs.width);
  rect.height = static_cast<unsigned short>(
      attrs.height > 0xFFFF ? 0xFFFF : attrs.height);
  api.ShapeCombineRectangles(display, window, kShapeInput, 0, 0, &rect, 1,
                             kShapeSet, 0);
  return WB_OK;
}

// 公共骨架：连接 → 主窗口发现（错误隔离）→ 操作（错误映射）。
template <typename Fn>
int RunX11WindowOp(Fn&& op) {
  X11Api& api = X11Api::Get();
  if (!api.core) {
    return WB_ERR_FAILED;
  }
  std::lock_guard<std::mutex> lock(X11MainDisplayMutex());
  Display* display = X11MainDisplay();
  if (display == nullptr) {
    return WB_ERR_FAILED;
  }

  Window window = None;
  {
    // 发现阶段的偶发 X 错误（并发销毁窗口的枚举竞争）不致命：吞掉继续。
    X11ErrorTrap discovery(display);
    window = FindMainWindowLocked(display);
    (void)discovery.FinishAndCheck();
  }
  if (window == None) {
    return WB_ERR_FAILED;
  }

  X11ErrorTrap trap(display);
  const int status = op(display, window);
  if (trap.FinishAndCheck() && status == WB_OK) {
    // 请求被拒（BadWindow / BadValue 等）：返回失败；失效缓存由下次
    // 调用的属性校验自动重查。
    return WB_ERR_FAILED;
  }
  return status;
}

}  // namespace

// ===== 对外（内部）入口：6 个窗口能力 =====

int X11WindowSetTransparent(bool transparent) {
  return RunX11WindowOp([transparent](Display* display, Window window) {
    return ApplyTransparent(display, window, transparent);
  });
}

int X11WindowSetAlwaysOnTop(bool on_top) {
  return RunX11WindowOp([on_top](Display* display, Window window) {
    return ApplyAlwaysOnTop(display, window, on_top);
  });
}

int X11WindowSetIgnoreMouseEvents(bool ignore, bool forward) {
  return RunX11WindowOp([ignore, forward](Display* display, Window window) {
    return ApplyIgnoreMouseEvents(display, window, ignore, forward);
  });
}

int X11WindowSetFullscreen(bool fullscreen) {
  return RunX11WindowOp([fullscreen](Display* display, Window window) {
    return ApplyFullscreen(display, window, fullscreen);
  });
}

int X11WindowSetPosition(int x, int y) {
  return RunX11WindowOp([x, y](Display* display, Window window) {
    return ApplyPosition(display, window, x, y);
  });
}

int X11WindowSetSize(int width, int height) {
  return RunX11WindowOp([width, height](Display* display, Window window) {
    return ApplySize(display, window, width, height);
  });
}

}  // namespace wb::platform::linux_

#else  // !WB_LINUX_HAVE_X11

// 无 X11 头文件的构建：X11 能力整体安全降级（不编译任何 Xlib 依赖）。
namespace wb::platform::linux_ {

int X11WindowSetTransparent(bool) { return WB_ERR_UNSUPPORTED; }
int X11WindowSetAlwaysOnTop(bool) { return WB_ERR_UNSUPPORTED; }
int X11WindowSetIgnoreMouseEvents(bool, bool) { return WB_ERR_UNSUPPORTED; }
int X11WindowSetFullscreen(bool) { return WB_ERR_UNSUPPORTED; }
int X11WindowSetPosition(int, int) { return WB_ERR_UNSUPPORTED; }
int X11WindowSetSize(int, int) { return WB_ERR_UNSUPPORTED; }

}  // namespace wb::platform::linux_

#endif  // WB_LINUX_HAVE_X11
