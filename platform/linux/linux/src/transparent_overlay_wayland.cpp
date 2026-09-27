// whiteboard_linux 插件 · Wayland 原生会话后端实现（GDK 运行时加载，C++20）。
//
// 背景（《透明批注模式技术方案》§7.4）：Wayland 无窗口管理器 / 全局定位 /
// 抓屏的统一协议，本后端经进程内 GTK3/GDK（dlopen libgtk-3 / libgdk-3 /
// libglib-2.0 / libcairo，无链接期依赖）对白板主窗口做 best-effort 请求：
//   * 透明：gtk_widget_set_app_paintable + 全透明背景（RGBA visual 兜底补
//     设，仅未 realize 窗口可切换视觉），最终透视效果由合成器决定；
//   * 置顶：gtk_window_set_keep_above（xdg-shell 无对应请求，合成器可
//     忽略；提供窗口规则的合成器 / 未来扩展可生效）；
//   * 全屏：gtk_window_fullscreen / gtk_window_unfullscreen（xdg_toplevel）；
//   * 位置：gtk_window_move（Wayland 合成器通常忽略客户端定位请求）；
//   * 尺寸：gtk_window_resize（经 xdg configure 协商，半可用）；
//   * 穿透：gdk_window_input_shape_combine_region —— 即 wl_compositor
//     输入区域语义（空区域 = 不接收输入；NULL = 恢复默认）。协议允许
//     合成器忽略输入区域请求，此时点击穿透不可用。
//
// 线程模型（关键设计决策）：Flutter Linux embedder 中 Dart 主 isolate 与
// GTK 主线程不保证为同一 OS 线程，而 GTK/GDK 仅允许在其 owner（主）线程
// 调用。因此本模块把全部 GDK 操作经 g_idle_add_full 同步投递到 GTK 主
// 循环执行（条件变量限时等待）：
//   * 绑定探针：首次操作前投递一个 idle 任务记录执行线程为主线程
//     （等待 100ms；失败不缓存，主循环随后活跃时自动重试）；
//   * 调用者已位于主线程：直接执行（零开销路径）；
//   * 调用者在其它线程：投递 + 限时等待（1500ms）；超时返回
//     WB_ERR_FAILED（不挂起）；任务状态经 std::shared_ptr 持有，迟到回调
//     亦安全（无 use-after-free）；
//   * 主循环不可用（纯 headless / 测试进程）：不冒险跨线程调用 GTK，
//     直接返回 WB_ERR_FAILED——绝不崩溃。
//
// 探测（ProbeGdkDisplayKind）只读 GDK 已初始化的 display 名称
// （gdk_display_get_default，GTK 未初始化时返回 NULL），不触发 GTK 初始
// 化、不产生副作用；GTK 缺失 / display 类型未知时返回 kNone，交由
// window_plugin.cpp 的环境变量兜底链路。
//
// 主窗口发现：进程内 gtk_window_list_toplevels() 仅含本进程顶层窗口（天然
// 排除跨应用误伤）；标题包含（WB_LINUX_WINDOW_TITLE，默认 "whiteboard"）
// 优先，其次可见窗口、分配面积较大者；无可见窗口时退回列表首项，交由
// 后续 GDK 调用自然失败。
//
// 无 GTK3 探测到的构建（WB_LINUX_HAVE_WAYLAND 未定义）：本文件退化为安全
// stub —— ProbeGdkDisplayKind 恒返回 kNone，全部窗口操作返回
// WB_ERR_UNSUPPORTED。

#include "window_plugin.h"

#if defined(WB_LINUX_HAVE_WAYLAND)

#include <chrono>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>

namespace wb::platform::linux_ {

namespace {

// ===== 不透明句柄（与 GTK3/GDK ABI 兼容；避免引入 GTK 头文件）=====
// GtkWidget 与 GtkWindow 均为单指针对象句柄，ABI 上可互换使用。
struct WbGtkWindow;
struct WbGdkWindow;
struct WbGdkDisplay;
struct WbGdkScreen;
struct WbGdkVisual;
struct WbCairoRegion;

// GdkRGBA（4 × double，32 字节，与 GDK 内存布局一致）。
struct WbGdkRgba {
  double red;
  double green;
  double blue;
  double alpha;
};

// GList 前缀（glib 双向链表；单向前进仅需前两个字段）。
struct WbGList {
  void* data;
  WbGList* next;
  WbGList* prev;
};

// ===== 运行时符号表（全部 dlopen/dlsym，无链接期依赖）=====

struct GdkApi {
  // ---- libgtk-3.so.0 ----
  WbGList* (*WindowListToplevels)() = nullptr;
  const char* (*WindowGetTitle)(WbGtkWindow*) = nullptr;
  void (*WindowSetKeepAbove)(WbGtkWindow*, int) = nullptr;
  void (*WindowFullscreen)(WbGtkWindow*) = nullptr;
  void (*WindowUnfullscreen)(WbGtkWindow*) = nullptr;
  void (*WindowMove)(WbGtkWindow*, int, int) = nullptr;
  void (*WindowResize)(WbGtkWindow*, int, int) = nullptr;
  WbGdkWindow* (*WidgetGetWindow)(WbGtkWindow*) = nullptr;
  void (*WidgetSetAppPaintable)(WbGtkWindow*, int) = nullptr;
  int (*WidgetGetVisible)(WbGtkWindow*) = nullptr;
  int (*WidgetGetRealized)(WbGtkWindow*) = nullptr;
  int (*WidgetGetAllocatedWidth)(WbGtkWindow*) = nullptr;
  int (*WidgetGetAllocatedHeight)(WbGtkWindow*) = nullptr;
  WbGdkScreen* (*WidgetGetScreen)(WbGtkWindow*) = nullptr;
  void (*WidgetSetVisual)(WbGtkWindow*, WbGdkVisual*) = nullptr;
  // ---- libgdk-3.so.0 ----
  WbGdkDisplay* (*DisplayGetDefault)() = nullptr;
  const char* (*DisplayGetName)(WbGdkDisplay*) = nullptr;
  void (*WindowSetBackgroundRgba)(WbGdkWindow*, const WbGdkRgba*) = nullptr;
  void (*WindowSetBackgroundPattern)(WbGdkWindow*, void*) = nullptr;
  void (*WindowInputShapeCombineRegion)(WbGdkWindow*, WbCairoRegion*, int,
                                        int) = nullptr;
  WbGdkVisual* (*ScreenGetRgbaVisual)(WbGdkScreen*) = nullptr;
  // ---- libcairo.so.2 ----
  WbCairoRegion* (*RegionCreate)() = nullptr;
  void (*RegionDestroy)(WbCairoRegion*) = nullptr;
  // ---- libglib-2.0.so.0 ----
  void (*ListFree)(WbGList*) = nullptr;
  // guint g_idle_add_full(gint, GSourceFunc, gpointer, GDestroyNotify)
  unsigned int (*IdleAddFull)(int, int (*)(void*), void*, void (*)(void*)) =
      nullptr;

  bool ready = false;

  // 进程级单例（幂等加载；失败后允许重试）。
  static GdkApi& Get();
};

// 关键符号集（探测 + 窗口枚举 + 投递机制；缺失任一项视为 GTK 运行时
// 不可用）。单项操作使用的符号在对应操作内单独校验。
void LoadGdkSymbols(GdkApi& api) {
  static const char* const kGtkNames[] = {"libgtk-3.so.0", "libgtk-3.so"};
  static const char* const kGdkNames[] = {"libgdk-3.so.0", "libgdk-3.so"};
  static const char* const kGlibNames[] = {"libglib-2.0.so.0", "libglib-2.0.so"};
  static const char* const kCairoNames[] = {"libcairo.so.2", "libcairo.so"};

  void* gtk = DlOpenFirst(kGtkNames, 2);
  void* gdk = DlOpenFirst(kGdkNames, 2);
  void* glib = DlOpenFirst(kGlibNames, 2);
  void* cairo = DlOpenFirst(kCairoNames, 2);

  api.WindowListToplevels = DlSymAs<decltype(api.WindowListToplevels)>(
      gtk, "gtk_window_list_toplevels");
  api.WindowGetTitle =
      DlSymAs<decltype(api.WindowGetTitle)>(gtk, "gtk_window_get_title");
  api.WindowSetKeepAbove =
      DlSymAs<decltype(api.WindowSetKeepAbove)>(gtk, "gtk_window_set_keep_above");
  api.WindowFullscreen =
      DlSymAs<decltype(api.WindowFullscreen)>(gtk, "gtk_window_fullscreen");
  api.WindowUnfullscreen =
      DlSymAs<decltype(api.WindowUnfullscreen)>(gtk, "gtk_window_unfullscreen");
  api.WindowMove = DlSymAs<decltype(api.WindowMove)>(gtk, "gtk_window_move");
  api.WindowResize =
      DlSymAs<decltype(api.WindowResize)>(gtk, "gtk_window_resize");
  api.WidgetGetWindow =
      DlSymAs<decltype(api.WidgetGetWindow)>(gtk, "gtk_widget_get_window");
  api.WidgetSetAppPaintable = DlSymAs<decltype(api.WidgetSetAppPaintable)>(
      gtk, "gtk_widget_set_app_paintable");
  api.WidgetGetVisible =
      DlSymAs<decltype(api.WidgetGetVisible)>(gtk, "gtk_widget_get_visible");
  api.WidgetGetRealized =
      DlSymAs<decltype(api.WidgetGetRealized)>(gtk, "gtk_widget_get_realized");
  api.WidgetGetAllocatedWidth = DlSymAs<decltype(api.WidgetGetAllocatedWidth)>(
      gtk, "gtk_widget_get_allocated_width");
  api.WidgetGetAllocatedHeight = DlSymAs<decltype(api.WidgetGetAllocatedHeight)>(
      gtk, "gtk_widget_get_allocated_height");
  api.WidgetGetScreen =
      DlSymAs<decltype(api.WidgetGetScreen)>(gtk, "gtk_widget_get_screen");
  api.WidgetSetVisual =
      DlSymAs<decltype(api.WidgetSetVisual)>(gtk, "gtk_widget_set_visual");

  api.DisplayGetDefault =
      DlSymAs<decltype(api.DisplayGetDefault)>(gdk, "gdk_display_get_default");
  api.DisplayGetName =
      DlSymAs<decltype(api.DisplayGetName)>(gdk, "gdk_display_get_name");
  api.WindowSetBackgroundRgba = DlSymAs<decltype(api.WindowSetBackgroundRgba)>(
      gdk, "gdk_window_set_background_rgba");
  api.WindowSetBackgroundPattern =
      DlSymAs<decltype(api.WindowSetBackgroundPattern)>(
          gdk, "gdk_window_set_background_pattern");
  api.WindowInputShapeCombineRegion =
      DlSymAs<decltype(api.WindowInputShapeCombineRegion)>(
          gdk, "gdk_window_input_shape_combine_region");
  api.ScreenGetRgbaVisual = DlSymAs<decltype(api.ScreenGetRgbaVisual)>(
      gdk, "gdk_screen_get_rgba_visual");

  api.RegionCreate =
      DlSymAs<decltype(api.RegionCreate)>(cairo, "cairo_region_create");
  api.RegionDestroy =
      DlSymAs<decltype(api.RegionDestroy)>(cairo, "cairo_region_destroy");

  api.ListFree = DlSymAs<decltype(api.ListFree)>(glib, "g_list_free");
  api.IdleAddFull = DlSymAs<decltype(api.IdleAddFull)>(glib, "g_idle_add_full");

  api.ready = api.WindowListToplevels != nullptr &&
              api.WindowGetTitle != nullptr &&
              api.WidgetGetWindow != nullptr &&
              api.WidgetGetVisible != nullptr &&
              api.WidgetGetRealized != nullptr &&
              api.WidgetGetAllocatedWidth != nullptr &&
              api.WidgetGetAllocatedHeight != nullptr &&
              api.DisplayGetDefault != nullptr &&
              api.DisplayGetName != nullptr && api.ListFree != nullptr &&
              api.IdleAddFull != nullptr;
}

GdkApi& GdkApi::Get() {
  static GdkApi instance;
  static std::mutex mutex;
  std::lock_guard<std::mutex> lock(mutex);
  if (!instance.ready) {
    LoadGdkSymbols(instance);
  }
  return instance;
}

// ===== GTK 主线程投递（见文件头「线程模型」）=====

// 首次绑定探针等待上限：主循环活跃时 idle 任务毫秒级完成，100ms 足够；
// 失败代价低（本次返回失败，主循环随后活跃时下次调用自动重试绑定）。
constexpr int kBindWaitMs = 100;
// 操作投递等待上限：超时视为主循环停滞，返回 WB_ERR_FAILED（不挂起）。
constexpr int kTaskWaitMs = 1500;
// G_PRIORITY_HIGH_IDLE（glib 常量值；避免为此引入 glib 头文件）。
constexpr int kHighIdlePriority = 100;

// 主线程绑定状态（统一由 g_bind_mutex 保护；探针写入，所有调用方读取）。
std::mutex g_bind_mutex;
std::condition_variable g_bind_cv;
bool g_main_thread_bound = false;
std::thread::id g_main_thread_id;

// 绑定探针：在主循环线程执行，记录主线程 id（重复投递不覆盖已绑定值）。
// 返回 G_SOURCE_REMOVE(0)：一次性任务，执行后由 glib 自动移除。
int OnIdleBind(void* /*data*/) {
  {
    std::lock_guard<std::mutex> lock(g_bind_mutex);
    if (!g_main_thread_bound) {
      g_main_thread_id = std::this_thread::get_id();
      g_main_thread_bound = true;
    }
  }
  g_bind_cv.notify_all();
  return 0;
}

// 投递绑定探针并限时等待（未绑定成功时静默返回，由调用方决定降级）。
void BindMainThreadProbe(GdkApi& api) {
  std::unique_lock<std::mutex> lock(g_bind_mutex);
  api.IdleAddFull(kHighIdlePriority, OnIdleBind, nullptr, nullptr);
  g_bind_cv.wait_for(lock, std::chrono::milliseconds(kBindWaitMs),
                     [] { return g_main_thread_bound; });
}

// 投递任务的状态（堆持有：迟到回调在调用方超时返回后仍可安全执行）。
struct IdleTaskState {
  std::mutex mutex;
  std::condition_variable cv;
  std::function<int()> body;
  int result = WB_ERR_FAILED;
  bool done = false;
};

// 任务体在主循环线程执行；异常（理论不可达）被边界宏吞掉并映射为失败。
int OnIdleRunTask(void* raw) {
  auto* state = static_cast<std::shared_ptr<IdleTaskState>*>(raw);
  int value = WB_ERR_FAILED;
  WB_LINUX_TRY {
    if ((*state)->body) {
      value = (*state)->body();
    }
  }
  WB_LINUX_CATCH_VOID
  {
    std::lock_guard<std::mutex> lock((*state)->mutex);
    (*state)->result = value;
    (*state)->done = true;
  }
  (*state)->cv.notify_all();
  return 0;  // G_SOURCE_REMOVE
}

// g_idle_add_full 的 destroy notify：回调执行或 source 销毁时释放持有者。
void DestroyIdleTaskState(void* raw) {
  delete static_cast<std::shared_ptr<IdleTaskState>*>(raw);
}

// 在 GTK 主线程同步执行 body，返回 body 的状态码：
//   * body 禁止抛异常、禁止重入本模块 API（当前实现均满足）；
//   * 主线程绑定失败（主循环不可用）→ WB_ERR_FAILED（不跨线程调用 GTK）；
//   * 投递超时 → WB_ERR_FAILED；迟到回调经 shared_ptr 安全丢弃。
template <typename Fn>
int RunOnGtkMain(Fn&& body) {
  GdkApi& api = GdkApi::Get();
  if (!api.ready) {
    return WB_ERR_UNSUPPORTED;
  }

  // 1) 确保主线程绑定（失败不缓存：主循环随后活跃时自动重试）。
  bool bound = false;
  {
    std::lock_guard<std::mutex> lock(g_bind_mutex);
    bound = g_main_thread_bound;
  }
  if (!bound) {
    BindMainThreadProbe(api);
    std::lock_guard<std::mutex> lock(g_bind_mutex);
    bound = g_main_thread_bound;
  }
  if (!bound) {
    // 主循环不可用（纯 headless / 测试进程）：安全失败，绝不挂起。
    return WB_ERR_FAILED;
  }

  // 2) 调用者即主线程：直接执行（零投递开销）。
  {
    std::lock_guard<std::mutex> lock(g_bind_mutex);
    if (std::this_thread::get_id() == g_main_thread_id) {
      return body();
    }
  }

  // 3) 其它线程：投递执行 + 限时等待。
  auto state = std::make_shared<IdleTaskState>();
  std::unique_lock<std::mutex> lock(state->mutex);
  state->body = std::forward<Fn>(body);
  auto* holder = new std::shared_ptr<IdleTaskState>(state);
  const unsigned int source_id =
      api.IdleAddFull(kHighIdlePriority, OnIdleRunTask, holder,
                      DestroyIdleTaskState);
  if (source_id == 0) {
    // attach 失败（理论仅内存耗尽）：不会再有回调，手动释放持有者。
    delete holder;
    return WB_ERR_FAILED;
  }
  const bool finished = state->cv.wait_for(
      lock, std::chrono::milliseconds(kTaskWaitMs),
      [&state] { return state->done; });
  if (!finished) {
    return WB_ERR_FAILED;  // 主循环停滞：不挂起、不误报。
  }
  return state->result;
}

// ===== 主窗口发现（仅在 GTK 主线程执行）=====

// 进程内顶层窗口选择：标题匹配优先 → 可见窗口 → 分配面积较大者；全部
// 不可见时退回列表首项（交由后续 GDK 调用自然失败）。GTK 无窗口指针
// 校验手段，不做缓存。
WbGtkWindow* FindMainGtkWindow() {
  GdkApi& api = GdkApi::Get();
  WbGList* list = api.WindowListToplevels();
  if (list == nullptr) {
    return nullptr;
  }
  const std::string want_title =
      EnvOrDefault("WB_LINUX_WINDOW_TITLE", "whiteboard");

  WbGtkWindow* first = nullptr;
  WbGtkWindow* best = nullptr;
  int best_score = -1;
  long long best_area = -1;
  for (WbGList* node = list; node != nullptr; node = node->next) {
    auto* window = static_cast<WbGtkWindow*>(node->data);
    if (window == nullptr) {
      continue;
    }
    if (first == nullptr) {
      first = window;
    }
    if (api.WidgetGetVisible(window) == 0) {
      continue;
    }
    int score = 0;
    if (!want_title.empty()) {
      const char* title = api.WindowGetTitle(window);
      if (title != nullptr && ContainsCaseInsensitive(title, want_title)) {
        score += 100;
      }
    }
    const long long area =
        static_cast<long long>(api.WidgetGetAllocatedWidth(window)) *
        static_cast<long long>(api.WidgetGetAllocatedHeight(window));
    if (best == nullptr || score > best_score ||
        (score == best_score && area > best_area)) {
      best = window;
      best_score = score;
      best_area = area;
    }
  }
  api.ListFree(list);
  return best != nullptr ? best : first;
}

// ===== 单个操作的执行体（经 RunOnGtkMain 在 GTK 主线程执行）=====

int ApplyTransparent(bool transparent) {
  GdkApi& api = GdkApi::Get();
  WbGtkWindow* window = FindMainGtkWindow();
  if (window == nullptr) {
    return WB_ERR_FAILED;
  }
  bool applied = false;
  if (api.WidgetSetAppPaintable != nullptr) {
    api.WidgetSetAppPaintable(window, transparent ? 1 : 0);
    applied = true;
  }
  if (transparent) {
    // RGBA visual：仅未 realize 的窗口可切换视觉（Flutter 宿主默认已使用
    // RGBA，此处为独立 GTK 宿主兜底）。
    if (api.WidgetGetRealized(window) == 0 && api.WidgetGetScreen != nullptr &&
        api.ScreenGetRgbaVisual != nullptr && api.WidgetSetVisual != nullptr) {
      WbGdkScreen* screen = api.WidgetGetScreen(window);
      WbGdkVisual* visual =
          screen != nullptr ? api.ScreenGetRgbaVisual(screen) : nullptr;
      if (visual != nullptr) {
        api.WidgetSetVisual(window, visual);
        applied = true;
      }
    }
    if (api.WindowSetBackgroundRgba != nullptr) {
      WbGdkWindow* gdk_window = api.WidgetGetWindow(window);
      if (gdk_window != nullptr) {
        const WbGdkRgba fully_transparent{0.0, 0.0, 0.0, 0.0};
        api.WindowSetBackgroundRgba(gdk_window, &fully_transparent);
        applied = true;
      }
    }
  } else {
    // 关闭：自定义背景置空 → 恢复主题默认背景色。
    if (api.WindowSetBackgroundPattern != nullptr) {
      WbGdkWindow* gdk_window = api.WidgetGetWindow(window);
      if (gdk_window != nullptr) {
        api.WindowSetBackgroundPattern(gdk_window, nullptr);
        applied = true;
      }
    }
  }
  return applied ? WB_OK : WB_ERR_UNSUPPORTED;
}
int ApplyAlwaysOnTop(bool on_top) {
  GdkApi& api = GdkApi::Get();
  WbGtkWindow* window = FindMainGtkWindow();
  if (window == nullptr) {
    return WB_ERR_FAILED;
  }
  if (api.WindowSetKeepAbove == nullptr) {
    return WB_ERR_UNSUPPORTED;
  }
  // Wayland（xdg-shell）无置顶请求：合成器可忽略；GDK 记录该请求，提供
  // 窗口规则 / 扩展协议的合成器可使其生效。
  api.WindowSetKeepAbove(window, on_top ? 1 : 0);
  return WB_OK;
}

int ApplyFullscreen(bool fullscreen) {
  GdkApi& api = GdkApi::Get();
  WbGtkWindow* window = FindMainGtkWindow();
  if (window == nullptr) {
    return WB_ERR_FAILED;
  }
  if (fullscreen) {
    if (api.WindowFullscreen == nullptr) {
      return WB_ERR_UNSUPPORTED;
    }
    api.WindowFullscreen(window);
  } else {
    if (api.WindowUnfullscreen == nullptr) {
      return WB_ERR_UNSUPPORTED;
    }
    api.WindowUnfullscreen(window);
  }
  return WB_OK;
}

int ApplyPosition(int x, int y) {
  GdkApi& api = GdkApi::Get();
  WbGtkWindow* window = FindMainGtkWindow();
  if (window == nullptr) {
    return WB_ERR_FAILED;
  }
  if (api.WindowMove == nullptr) {
    return WB_ERR_UNSUPPORTED;
  }
  // Wayland 合成器通常忽略客户端定位（xdg-shell 无 move 请求）；请求已
  // 提交，属 best-effort。
  api.WindowMove(window, x, y);
  return WB_OK;
}

int ApplySize(int width, int height) {
  GdkApi& api = GdkApi::Get();
  WbGtkWindow* window = FindMainGtkWindow();
  if (window == nullptr) {
    return WB_ERR_FAILED;
  }
  if (api.WindowResize == nullptr) {
    return WB_ERR_UNSUPPORTED;
  }
  // 尺寸经 xdg configure 与合成器协商后可生效（best-effort）。
  api.WindowResize(window, width, height);
  return WB_OK;
}

int ApplyIgnoreMouseEvents(bool ignore) {
  GdkApi& api = GdkApi::Get();
  WbGtkWindow* window = FindMainGtkWindow();
  if (window == nullptr) {
    return WB_ERR_FAILED;
  }
  if (api.WindowInputShapeCombineRegion == nullptr) {
    return WB_ERR_UNSUPPORTED;
  }
  WbGdkWindow* gdk_window = api.WidgetGetWindow(window);
  if (gdk_window == nullptr) {
    // 窗口尚未 realize（无 GdkWindow）：无法设置输入区域。
    return WB_ERR_FAILED;
  }
  if (!ignore) {
    // NULL 区域 = 恢复默认（整窗）输入区域。
    api.WindowInputShapeCombineRegion(gdk_window, nullptr, 0, 0);
    return WB_OK;
  }
  if (api.RegionCreate == nullptr || api.RegionDestroy == nullptr) {
    return WB_ERR_UNSUPPORTED;
  }
  WbCairoRegion* empty_region = api.RegionCreate();
  if (empty_region == nullptr) {
    return WB_ERR_FAILED;
  }
  // 空输入区域 = 不接收任何输入（点击穿透）；协议允许合成器忽略。
  api.WindowInputShapeCombineRegion(gdk_window, empty_region, 0, 0);
  api.RegionDestroy(empty_region);
  return WB_OK;
}

}  // namespace

// ===== 探测与 6 个窗口能力对外（内部）入口 =====

GdkDisplayKind ProbeGdkDisplayKind() {
  // 预检：无任何图形会话环境时不加载 GTK 库（纯 headless / 测试进程）。
  if (EnvString("DISPLAY").empty() && EnvString("WAYLAND_DISPLAY").empty()) {
    return GdkDisplayKind::kNone;
  }
  GdkApi& api = GdkApi::Get();
  if (!api.ready) {
    return GdkDisplayKind::kNone;
  }
  // 只读 GDK display（宿主 GTK 已初始化时非 NULL）；不触发 GTK 初始化、
  // 无副作用。
  WbGdkDisplay* display = api.DisplayGetDefault();
  if (display == nullptr) {
    return GdkDisplayKind::kNone;
  }
  const char* name = api.DisplayGetName(display);
  if (name == nullptr || name[0] == '\0') {
    return GdkDisplayKind::kNone;
  }
  // GDK display 命名：X11（含 XWayland）以 ':' 开头（如 ":0"）；Wayland
  // 原生为 "wayland-0" 等；Broadway / 其它后端不属本插件通路。
  if (name[0] == ':') {
    return GdkDisplayKind::kX11;
  }
  if (std::string(name).find("wayland") != std::string::npos) {
    return GdkDisplayKind::kWayland;
  }
  return GdkDisplayKind::kNone;
}

// ---- 6 个窗口能力：统一「异常边界 → GTK 主线程投递」----

int WaylandWindowSetTransparent(bool transparent) {
  WB_LINUX_TRY {
    return RunOnGtkMain([transparent] { return ApplyTransparent(transparent); });
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

int WaylandWindowSetAlwaysOnTop(bool on_top) {
  WB_LINUX_TRY {
    return RunOnGtkMain([on_top] { return ApplyAlwaysOnTop(on_top); });
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

int WaylandWindowSetIgnoreMouseEvents(bool ignore, bool) {
  // 第二参数为 Windows 平台「穿透但转发悬停」语义，Wayland 无对应机制，
  // 按契约忽略。
  WB_LINUX_TRY {
    return RunOnGtkMain([ignore] { return ApplyIgnoreMouseEvents(ignore); });
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

int WaylandWindowSetFullscreen(bool fullscreen) {
  WB_LINUX_TRY {
    return RunOnGtkMain([fullscreen] { return ApplyFullscreen(fullscreen); });
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

int WaylandWindowSetPosition(int x, int y) {
  WB_LINUX_TRY {
    return RunOnGtkMain([x, y] { return ApplyPosition(x, y); });
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

int WaylandWindowSetSize(int width, int height) {
  WB_LINUX_TRY {
    return RunOnGtkMain([width, height] { return ApplySize(width, height); });
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

}  // namespace wb::platform::linux_

#else  // !WB_LINUX_HAVE_WAYLAND

// 无 GTK3 探测到的构建：Wayland/GDK 能力整体安全降级（不编译任何 GTK
// 相关代码）。
namespace wb::platform::linux_ {

GdkDisplayKind ProbeGdkDisplayKind() { return GdkDisplayKind::kNone; }

int WaylandWindowSetTransparent(bool) { return WB_ERR_UNSUPPORTED; }
int WaylandWindowSetAlwaysOnTop(bool) { return WB_ERR_UNSUPPORTED; }
int WaylandWindowSetIgnoreMouseEvents(bool, bool) { return WB_ERR_UNSUPPORTED; }
int WaylandWindowSetFullscreen(bool) { return WB_ERR_UNSUPPORTED; }
int WaylandWindowSetPosition(int, int) { return WB_ERR_UNSUPPORTED; }
int WaylandWindowSetSize(int, int) { return WB_ERR_UNSUPPORTED; }

}  // namespace wb::platform::linux_

#endif  // WB_LINUX_HAVE_WAYLAND
