// whiteboard_linux 插件 · 系统托盘实现（GTK3 运行时动态加载，C++20）。
//
// 后端链（《透明批注模式技术方案》§7.3 / 《Flutter + C++ 工程结构设计》§6.5）：
//   * AppIndicator（libayatana-appindicator3.so.1 → libappindicator3.so.1，
//     运行时 dlopen）——StatusNotifierItem 协议，现代桌面托盘首选；
//   * 降级 GtkStatusIcon（libgtk-3 自身）——传统 XEmbed 托盘；
//   * 均不可用（无 GTK3 / 无托盘宿主 / 无显示会话）→ WB_ERR_UNSUPPORTED。
//
// 线程模型：
//   * 全部导出函数由 Dart 主线程调用（Flutter Linux 下即 GTK 主线程）；
//     GTK 调用必须发生在 GTK 主线程，因此经 g_idle_add_full 投递 +
//     限时等待（见 RunOnTrayGtkThread）；
//   * 主线程绑定探针：首次投递时记录 GTK 主线程 id，此后 Dart 主线程
//     调用直连执行（零投递开销）；主循环不可用时安全失败不挂起；
//   * 菜单项点击回调在 GTK 主线程触发；Dart 侧经 NativeCallable.listener
//     异步转发。回调槽读写由 g_tray_callback_mutex 串行化，保证
//     set_callback(nullptr) 返回后不再有在途回调（Dart dispose 顺序：
//     setCallback(null) → callback.close()）。
//
// 菜单 JSON 协议（Dart wb_tray_plugin.dart 的 jsonEncode 输出）：
//   [{"id":"...","label":"...","type":"normal|separator|checkbox",
//     "enabled":true,"checked":false}, ...]
// 解析为本文件自研极简解析器（零第三方依赖）：字段顺序任意、未知字段
// 跳过、type 兼容数字 0/1/2、布尔兼容数字；解析失败返回 WB_ERR_FAILED
// 且不投递（Dart 侧静默降级）。
//
// 菜单项 id 生命周期：点击回调经 NativeCallable.listener 异步投递给
// Dart，字符串须存活至 Dart 实际读取（可能晚于菜单整体替换）——"退役
// 池"持有已触发 id 的持久引用（FIFO，上限 kTrayRetiredLimit）。
//
// 无 GTK3 构建（WB_LINUX_HAVE_GTK3 未定义）：全部调用安全降级
// （WB_ERR_UNSUPPORTED），无任何 GTK 依赖。

#include "window_plugin.h"

#if defined(WB_LINUX_HAVE_GTK3)

#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace wb::platform::linux_ {

// ===== 常量 =====

// 单次 GTK 投递等待上限：超时视为 GTK 主循环停滞，返回 WB_ERR_FAILED。
constexpr int kTrayTaskWaitMs = 1500;
// 主线程绑定探针等待上限（同量级；主循环不可用即失败）。
constexpr int kTrayBindWaitMs = 1500;
// G_PRIORITY_HIGH_IDLE（glib 常量值；避免为此引入 glib 头文件）。
constexpr int kTrayHighIdlePriority = 100;
// 退役池上限（FIFO；仅约束已触发未消费的 id 在途数量）。
constexpr size_t kTrayRetiredLimit = 512;

// GTK 信号回调的通用函数指针形态（glib GCallback = void (*)(void)）。
using TrayGCallback = void (*)(void);

// 函数指针跨类型转换（信号处理器 / 位置回调）：经 memcpy 规避
// -Wpedantic 下函数指针 reinterpret_cast 的可移植性告警。
template <typename To, typename From>
To TrayCastFunction(From from) {
  static_assert(sizeof(To) == sizeof(From), "function pointer size mismatch");
  To to = nullptr;
  std::memcpy(&to, &from, sizeof(from));
  return to;
}

// ===== 运行时符号表（全部 dlopen/dlsym，无链接期依赖）=====

// 库候选名（发行版差异：运行时镜像多只有 soname 版本化文件；开发包
// 提供无版本号符号链接。按优先级逐个尝试）。
const char* const kTrayGlibLibraryNames[] = {"libglib-2.0.so.0",
                                             "libglib-2.0.so"};
const char* const kTrayGtkLibraryNames[] = {"libgtk-3.so.0", "libgtk-3.so"};
const char* const kTrayAyatanaLibraryNames[] = {
    "libayatana-appindicator3.so.1", "libayatana-appindicator3.so"};
const char* const kTrayAppIndicatorLibraryNames[] = {
    "libappindicator3.so.1", "libappindicator3.so"};

// 全部 GTK/GLib/AppIndicator 句柄一律取为 void*（不透明）；gboolean /
// guint / gulong 等 GLib 标量按 ABI 宽度映射为 int / unsigned int /
// unsigned long（LP64）。
struct TrayGtkApi {
  // 运行时加载的库句柄（有意常驻进程生命周期：不 dlclose——已注册的
  // GTK 信号处理器与数据销毁函数指向库代码段，卸载后回调即野指针）。
  void* glib_library = nullptr;
  void* gtk_library = nullptr;
  void* indicator_library = nullptr;

  // ---- libglib-2.0（GLib 组；4 符号全非空 = glib == true）----
  unsigned int (*IdleAddFull)(int, int (*)(void*), void*,
                              void (*)(void*)) = nullptr;                  // g_idle_add_full
  unsigned long (*SignalConnectData)(void*, const char*, void (*)(void),   // g_signal_connect_data
                                     void*, void (*)(void*, void*),
                                     int) = nullptr;
  void (*ObjectSetDataFull)(void*, const char*, void*,                    // g_object_set_data_full
                            void (*)(void*)) = nullptr;
  void* (*ObjectGetData)(void*, const char*) = nullptr;                    // g_object_get_data

  // ---- libgtk-3 核心（GTK 组；11 符号全非空 = gtk == true）----
  int (*InitCheck)(int*, char***) = nullptr;                               // gtk_init_check
  void* (*MenuNew)(void) = nullptr;                                        // gtk_menu_new
  void* (*MenuItemNewWithLabel)(const char*) = nullptr;                    // gtk_menu_item_new_with_label
  void* (*CheckMenuItemNewWithLabel)(const char*) = nullptr;               // gtk_check_menu_item_new_with_label
  void (*CheckMenuItemSetActive)(void*, int) = nullptr;                    // gtk_check_menu_item_set_active
  void* (*SeparatorMenuItemNew)(void) = nullptr;                           // gtk_separator_menu_item_new
  void (*MenuShellAppend)(void*, void*) = nullptr;                         // gtk_menu_shell_append
  void (*WidgetSetSensitive)(void*, int) = nullptr;                        // gtk_widget_set_sensitive
  void (*WidgetShowAll)(void*) = nullptr;                                  // gtk_widget_show_all
  void (*WidgetDestroy)(void*) = nullptr;                                  // gtk_widget_destroy
  // gtk_menu_popup 的 position_func 取 GtkMenuPositionFunc 公开原型
  // （push_in 值传参）；与 gtk_status_icon_position_menu 的经典组合是
  // GTK 官方用法（历史签名差异由 GTK 内部消化）。
  void (*MenuPopup)(void*, void*, void*,
                    void (*)(void*, int*, int*, int, void*), void*,
                    unsigned int, unsigned int) = nullptr;               // gtk_menu_popup

  // ---- libgtk-3 状态图标（可选组；缺失时托盘整体降级）----
  void* (*StatusIconNew)(void) = nullptr;                                  // gtk_status_icon_new
  void (*StatusIconSetFromIconName)(void*, const char*) = nullptr;         // gtk_status_icon_set_from_icon_name
  void (*StatusIconSetFromFile)(void*, const char*) = nullptr;             // gtk_status_icon_set_from_file
  void (*StatusIconSetTooltipText)(void*, const char*) = nullptr;          // gtk_status_icon_set_tooltip_text
  void (*StatusIconSetVisible)(void*, int) = nullptr;                      // gtk_status_icon_set_visible
  void (*StatusIconPositionMenu)(void*, int*, int*, int, void*) = nullptr; // gtk_status_icon_position_menu

  // ---- AppIndicator（可选组；缺失时降级 GtkStatusIcon）----
  void* (*IndicatorNew)(const char*, const char*, int) = nullptr;          // app_indicator_new
  void (*IndicatorSetStatus)(void*, int) = nullptr;                        // app_indicator_set_status
  void (*IndicatorSetIconFull)(void*, const char*, const char*) = nullptr; // app_indicator_set_icon_full
  void (*IndicatorSetTitle)(void*, const char*) = nullptr;                 // app_indicator_set_title
  void (*IndicatorSetMenu)(void*, void*) = nullptr;                        // app_indicator_set_menu

  bool glib = false;           // GLib 组可用
  bool gtk = false;            // GTK 核心组可用
  bool status_icon = false;    // GtkStatusIcon 组可用
  bool app_indicator = false;  // AppIndicator 组可用
  bool ready = false;          // = glib && gtk（托盘搭建的最低要求）

  // 进程级单例（幂等加载；失败后允许重试——与 X11Api 一致）。
  static TrayGtkApi& Get();
};

// 幂等加载：已获取的库句柄不重复 dlopen；失败允许重试（后续调用再次
// 尝试——环境补齐库后无需重启进程亦可恢复）。绝不解引用空句柄。
void LoadTrayGtkSymbols(TrayGtkApi& api) {
  if (api.glib_library == nullptr) {
    api.glib_library = DlOpenFirst(
        kTrayGlibLibraryNames,
        sizeof(kTrayGlibLibraryNames) / sizeof(kTrayGlibLibraryNames[0]));
  }
  if (api.gtk_library == nullptr) {
    api.gtk_library = DlOpenFirst(
        kTrayGtkLibraryNames,
        sizeof(kTrayGtkLibraryNames) / sizeof(kTrayGtkLibraryNames[0]));
  }
  if (api.indicator_library == nullptr) {
    api.indicator_library = DlOpenFirst(
        kTrayAyatanaLibraryNames,
        sizeof(kTrayAyatanaLibraryNames) / sizeof(kTrayAyatanaLibraryNames[0]));
    if (api.indicator_library == nullptr) {
      api.indicator_library = DlOpenFirst(
          kTrayAppIndicatorLibraryNames,
          sizeof(kTrayAppIndicatorLibraryNames) /
              sizeof(kTrayAppIndicatorLibraryNames[0]));
    }
  }

  if (api.glib_library != nullptr && !api.glib) {
    api.IdleAddFull = DlSymAs<decltype(api.IdleAddFull)>(
        api.glib_library, "g_idle_add_full");
    api.SignalConnectData = DlSymAs<decltype(api.SignalConnectData)>(
        api.glib_library, "g_signal_connect_data");
    api.ObjectSetDataFull = DlSymAs<decltype(api.ObjectSetDataFull)>(
        api.glib_library, "g_object_set_data_full");
    api.ObjectGetData = DlSymAs<decltype(api.ObjectGetData)>(
        api.glib_library, "g_object_get_data");
    api.glib = api.IdleAddFull != nullptr &&
               api.SignalConnectData != nullptr &&
               api.ObjectSetDataFull != nullptr &&
               api.ObjectGetData != nullptr;
  }

  if (api.gtk_library != nullptr && !api.gtk) {
    api.InitCheck = DlSymAs<decltype(api.InitCheck)>(api.gtk_library,
                                                     "gtk_init_check");
    api.MenuNew = DlSymAs<decltype(api.MenuNew)>(api.gtk_library,
                                                 "gtk_menu_new");
    api.MenuItemNewWithLabel = DlSymAs<decltype(api.MenuItemNewWithLabel)>(
        api.gtk_library, "gtk_menu_item_new_with_label");
    api.CheckMenuItemNewWithLabel =
        DlSymAs<decltype(api.CheckMenuItemNewWithLabel)>(
            api.gtk_library, "gtk_check_menu_item_new_with_label");
    api.CheckMenuItemSetActive = DlSymAs<decltype(api.CheckMenuItemSetActive)>(
        api.gtk_library, "gtk_check_menu_item_set_active");
    api.SeparatorMenuItemNew = DlSymAs<decltype(api.SeparatorMenuItemNew)>(
        api.gtk_library, "gtk_separator_menu_item_new");
    api.MenuShellAppend = DlSymAs<decltype(api.MenuShellAppend)>(
        api.gtk_library, "gtk_menu_shell_append");
    api.WidgetSetSensitive = DlSymAs<decltype(api.WidgetSetSensitive)>(
        api.gtk_library, "gtk_widget_set_sensitive");
    api.WidgetShowAll = DlSymAs<decltype(api.WidgetShowAll)>(api.gtk_library,
                                                             "gtk_widget_show_all");
    api.WidgetDestroy = DlSymAs<decltype(api.WidgetDestroy)>(api.gtk_library,
                                                             "gtk_widget_destroy");
    api.MenuPopup = DlSymAs<decltype(api.MenuPopup)>(api.gtk_library,
                                                     "gtk_menu_popup");
    api.gtk = api.InitCheck != nullptr && api.MenuNew != nullptr &&
              api.MenuItemNewWithLabel != nullptr &&
              api.CheckMenuItemNewWithLabel != nullptr &&
              api.CheckMenuItemSetActive != nullptr &&
              api.SeparatorMenuItemNew != nullptr &&
              api.MenuShellAppend != nullptr &&
              api.WidgetSetSensitive != nullptr &&
              api.WidgetShowAll != nullptr && api.WidgetDestroy != nullptr &&
              api.MenuPopup != nullptr;
  }

  if (api.gtk_library != nullptr && !api.status_icon) {
    api.StatusIconNew = DlSymAs<decltype(api.StatusIconNew)>(api.gtk_library,
                                                             "gtk_status_icon_new");
    api.StatusIconSetFromIconName =
        DlSymAs<decltype(api.StatusIconSetFromIconName)>(
            api.gtk_library, "gtk_status_icon_set_from_icon_name");
    api.StatusIconSetFromFile = DlSymAs<decltype(api.StatusIconSetFromFile)>(
        api.gtk_library, "gtk_status_icon_set_from_file");
    api.StatusIconSetTooltipText =
        DlSymAs<decltype(api.StatusIconSetTooltipText)>(
            api.gtk_library, "gtk_status_icon_set_tooltip_text");
    api.StatusIconSetVisible = DlSymAs<decltype(api.StatusIconSetVisible)>(
        api.gtk_library, "gtk_status_icon_set_visible");
    api.StatusIconPositionMenu =
        DlSymAs<decltype(api.StatusIconPositionMenu)>(
            api.gtk_library, "gtk_status_icon_position_menu");
    api.status_icon = api.StatusIconNew != nullptr &&
                      api.StatusIconSetFromIconName != nullptr &&
                      api.StatusIconSetFromFile != nullptr &&
                      api.StatusIconSetTooltipText != nullptr &&
                      api.StatusIconSetVisible != nullptr &&
                      api.StatusIconPositionMenu != nullptr;
  }

  if (api.indicator_library != nullptr && !api.app_indicator) {
    api.IndicatorNew = DlSymAs<decltype(api.IndicatorNew)>(
        api.indicator_library, "app_indicator_new");
    api.IndicatorSetStatus = DlSymAs<decltype(api.IndicatorSetStatus)>(
        api.indicator_library, "app_indicator_set_status");
    api.IndicatorSetIconFull = DlSymAs<decltype(api.IndicatorSetIconFull)>(
        api.indicator_library, "app_indicator_set_icon_full");
    api.IndicatorSetTitle = DlSymAs<decltype(api.IndicatorSetTitle)>(
        api.indicator_library, "app_indicator_set_title");
    api.IndicatorSetMenu = DlSymAs<decltype(api.IndicatorSetMenu)>(
        api.indicator_library, "app_indicator_set_menu");
    api.app_indicator = api.IndicatorNew != nullptr &&
                        api.IndicatorSetStatus != nullptr &&
                        api.IndicatorSetIconFull != nullptr &&
                        api.IndicatorSetTitle != nullptr &&
                        api.IndicatorSetMenu != nullptr;
  }

  api.ready = api.glib && api.gtk;
}

TrayGtkApi& TrayGtkApi::Get() {
  static TrayGtkApi instance;
  static std::mutex load_mutex;
  std::lock_guard<std::mutex> lock(load_mutex);
  if (!instance.ready) {
    LoadTrayGtkSymbols(instance);
  }
  return instance;
}

// ===== GTK 主线程投递（g_idle_add_full 调度 + 限时等待）=====

// 主线程绑定状态（统一由 g_tray_bind_mutex 保护；探针写入，调用方读取）。
std::mutex g_tray_bind_mutex;
std::condition_variable g_tray_bind_cv;
bool g_tray_thread_bound = false;
std::thread::id g_tray_thread_id;

// 绑定探针：在 GTK 主线程执行，记录主线程 id（重复投递不覆盖已绑定值）。
// 返回 G_SOURCE_REMOVE(0)：一次性任务，执行后由 glib 自动移除。
int OnTrayIdleBind(void* /*data*/) {
  {
    std::lock_guard<std::mutex> lock(g_tray_bind_mutex);
    if (!g_tray_thread_bound) {
      g_tray_thread_id = std::this_thread::get_id();
      g_tray_thread_bound = true;
    }
  }
  g_tray_bind_cv.notify_all();
  return 0;
}

// 投递绑定探针并限时等待（未绑定成功时静默返回，由调用方决定降级）。
void BindTrayThreadProbe(TrayGtkApi& api) {
  std::unique_lock<std::mutex> lock(g_tray_bind_mutex);
  api.IdleAddFull(kTrayHighIdlePriority, OnTrayIdleBind, nullptr, nullptr);
  g_tray_bind_cv.wait_for(lock, std::chrono::milliseconds(kTrayBindWaitMs),
                          [] { return g_tray_thread_bound; });
}

// 任务状态（堆持有：迟到回调在调用方超时返回后仍可安全执行）。
struct TrayTaskState {
  std::mutex mutex;
  std::condition_variable cv;
  std::function<int()> body;
  int result = WB_ERR_FAILED;
  bool done = false;
};

// 任务体在 GTK 主线程执行；异常（理论不可达）被边界宏吞掉并映射为失败。
int OnTrayIdleRunTask(void* raw) {
  auto* state = static_cast<std::shared_ptr<TrayTaskState>*>(raw);
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
void DestroyTrayTaskState(void* raw) {
  delete static_cast<std::shared_ptr<TrayTaskState>*>(raw);
}

// 在 GTK 主线程同步执行 body，返回 body 的状态码：
//   * body 禁止重入本模块导出 API（当前实现均满足）；
//   * GTK 库缺失 → WB_ERR_UNSUPPORTED；主循环不可用 / 投递超时 →
//     WB_ERR_FAILED（绝不跨线程调用 GTK、绝不挂起）；
//   * 超时后的迟到任务经 shared_ptr 保活安全执行（托盘副作用幂等，
//     迟到无害；调用方已按失败处理）。
template <typename Fn>
int RunOnTrayGtkThread(Fn&& body) {
  TrayGtkApi& api = TrayGtkApi::Get();
  if (!api.ready) {
    return WB_ERR_UNSUPPORTED;
  }

  // 1) 确保主线程绑定（失败不缓存：主循环随后活跃时自动重试）。
  bool bound = false;
  {
    std::lock_guard<std::mutex> lock(g_tray_bind_mutex);
    bound = g_tray_thread_bound;
  }
  if (!bound) {
    BindTrayThreadProbe(api);
    std::lock_guard<std::mutex> lock(g_tray_bind_mutex);
    bound = g_tray_thread_bound;
  }
  if (!bound) {
    // 主循环不可用（纯 headless / 测试进程）：安全失败，绝不挂起。
    return WB_ERR_FAILED;
  }

  // 2) 调用者即 GTK 主线程（Dart 调用约定下的稳态）：直接执行。
  {
    std::lock_guard<std::mutex> lock(g_tray_bind_mutex);
    if (std::this_thread::get_id() == g_tray_thread_id) {
      return body();
    }
  }

  // 3) 其它线程：投递执行 + 限时等待。
  auto state = std::make_shared<TrayTaskState>();
  std::unique_lock<std::mutex> lock(state->mutex);
  state->body = std::forward<Fn>(body);
  auto* holder = new std::shared_ptr<TrayTaskState>(state);
  const unsigned int source_id =
      api.IdleAddFull(kTrayHighIdlePriority, OnTrayIdleRunTask, holder,
                      DestroyTrayTaskState);
  if (source_id == 0) {
    // attach 失败（理论仅内存耗尽）——此处不手动释放 holder：glib 对
    // 「回调已注册但 source 未挂载」的销毁通知语义不做双向保证，误释放
    // 可能双重释放；极窄路径下的微量持有者泄漏优先于崩溃风险。
    return WB_ERR_FAILED;
  }
  const bool finished = state->cv.wait_for(
      lock, std::chrono::milliseconds(kTrayTaskWaitMs),
      [&state] { return state->done; });
  if (!finished) {
    return WB_ERR_FAILED;  // 主循环停滞：不挂起、不误报。
  }
  return state->result;
}

// ===== 托盘状态与回调槽（GTK 状态仅 GTK 主线程访问）=====

enum class TrayKind { kNone, kAppIndicator, kStatusIcon };

// 菜单项 id 的堆持有者：经 g_object_set_data_full 挂在菜单项上；点击时
// 其 value 引用被移交退役池（见 OnMenuActivate），菜单销毁只释放壳。
struct MenuIdHandle {
  std::shared_ptr<const std::string> value;
};

struct TrayState {
  TrayKind kind = TrayKind::kNone;
  void* indicator = nullptr;    // AppIndicator 句柄
  void* status_icon = nullptr;  // GtkStatusIcon 句柄
  void* menu = nullptr;         // 当前 GtkMenu（nullptr = 未设置）
  std::string icon;             // 最近一次图标（主题名或路径）
  std::string tooltip;          // 最近一次提示
};

// 托盘状态：仅 GTK 主线程访问（全部经 RunOnTrayGtkThread 投递）。
TrayState g_tray;

// 已触发 id 的「退役池」：回调经 NativeCallable.listener 异步投递给
// Dart，字符串须存活至 Dart 实际读取（可能晚于菜单整体替换）；超上限
// 时 FIFO 淘汰。仅 GTK 主线程访问。
std::deque<std::shared_ptr<const std::string>> g_tray_retired_ids;

// 回调槽：GTK 主线程读取（调用时持锁），任意线程更新（set_callback）。
// 调用时持锁使 set_callback(nullptr) 与在途回调严格串行——返回后不再
// 有回调在途（Dart dispose 依赖该保证）。
std::mutex g_tray_callback_mutex;
WbLinuxStrCallback g_tray_callback = nullptr;

// 菜单项 id 的 GObject 数据键。
constexpr char kTrayMenuIdKey[] = "wb_menu_id";

// ===== 菜单 JSON 解析（自研极简解析器，零第三方依赖）=====
//
// 协议（Dart wb_tray_plugin.dart 的 jsonEncode 输出）：
//   [{"id":"...","label":"...","type":"normal|separator|checkbox",
//     "enabled":true,"checked":false}, ...]
// 宽容点：字段顺序任意、未知字段跳过、type 兼容数字 0/1/2、布尔兼容
// 数字；严格点：顶层必须是数组、字符串必须双引号、原始控制字符拒绝。
// 解析失败 → 调用方返回 WB_ERR_FAILED（不投递半成品菜单）。

struct TrayMenuItem {
  std::string id;
  std::string label;
  int type = 0;  // 0=normal 1=separator 2=checkbox
  bool enabled = true;
  bool checked = false;
};

// 追加一个 Unicode 码点的 UTF-8 编码（非法码点以 U+FFFD 替换）。
void AppendUtf8(std::string& out, unsigned int code_point) {
  if (code_point > 0x10FFFF ||
      (code_point >= 0xD800 && code_point <= 0xDFFF)) {
    code_point = 0xFFFD;
  }
  if (code_point <= 0x7F) {
    out.push_back(static_cast<char>(code_point));
  } else if (code_point <= 0x7FF) {
    out.push_back(static_cast<char>(0xC0 | (code_point >> 6)));
    out.push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
  } else if (code_point <= 0xFFFF) {
    out.push_back(static_cast<char>(0xE0 | (code_point >> 12)));
    out.push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
  } else {
    out.push_back(static_cast<char>(0xF0 | (code_point >> 18)));
    out.push_back(static_cast<char>(0x80 | ((code_point >> 12) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
  }
}

class TrayJsonParser {
 public:
  TrayJsonParser(const char* begin, const char* end)
      : cursor_(begin), end_(end) {}

  // 顶层：数组 + 尾部仅允许空白；空数组合法。
  bool ParseItems(std::vector<TrayMenuItem>* items) {
    SkipWhitespace();
    if (!Consume('[')) {
      return false;
    }
    SkipWhitespace();
    if (Consume(']')) {
      return AtEndAfterWhitespace();
    }
    while (true) {
      TrayMenuItem item;
      if (!ParseItem(&item)) {
        return false;
      }
      items->push_back(std::move(item));
      SkipWhitespace();
      if (Consume(',')) {
        SkipWhitespace();
        continue;
      }
      if (Consume(']')) {
        return AtEndAfterWhitespace();
      }
      return false;
    }
  }

 private:
  bool AtEndAfterWhitespace() {
    SkipWhitespace();
    return cursor_ == end_;
  }

  void SkipWhitespace() {
    while (cursor_ != end_ && (*cursor_ == ' ' || *cursor_ == '\t' ||
                               *cursor_ == '\n' || *cursor_ == '\r')) {
      ++cursor_;
    }
  }

  bool Consume(char expected) {
    if (cursor_ != end_ && *cursor_ == expected) {
      ++cursor_;
      return true;
    }
    return false;
  }

  char Peek() const { return cursor_ != end_ ? *cursor_ : '\0'; }

  bool MatchLiteral(const char* literal) {
    const size_t length = std::strlen(literal);
    if (static_cast<size_t>(end_ - cursor_) < length) {
      return false;
    }
    if (std::memcmp(cursor_, literal, length) != 0) {
      return false;
    }
    cursor_ += length;
    return true;
  }

  // ---- 值解析 ----

  // 解析 `{...}` 单个菜单项；未知键的值被宽容跳过。
  bool ParseItem(TrayMenuItem* item) {
    SkipWhitespace();
    if (!Consume('{')) {
      return false;
    }
    SkipWhitespace();
    if (Consume('}')) {
      return true;  // 空对象 → 全默认值项。
    }
    while (true) {
      SkipWhitespace();
      std::string key;
      if (!ParseString(&key)) {
        return false;
      }
      SkipWhitespace();
      if (!Consume(':')) {
        return false;
      }
      SkipWhitespace();
      if (!ParseMemberValue(key, item)) {
        return false;
      }
      SkipWhitespace();
      if (Consume(',')) {
        continue;
      }
      if (Consume('}')) {
        return true;
      }
      return false;
    }
  }

  bool ParseMemberValue(const std::string& key, TrayMenuItem* item) {
    if (key == "id") {
      return ParseString(&item->id);
    }
    if (key == "label") {
      return ParseString(&item->label);
    }
    if (key == "type") {
      return ParseType(&item->type);
    }
    if (key == "enabled") {
      return ParseBool(&item->enabled);
    }
    if (key == "checked") {
      return ParseBool(&item->checked);
    }
    return SkipValue(0);
  }

  bool ParseType(int* type) {
    // 协议主形态：字符串 "normal"/"separator"/"checkbox"（type.name）。
    if (Peek() == '"') {
      std::string name;
      if (!ParseString(&name)) {
        return false;
      }
      if (name == "separator") {
        *type = 1;
      } else if (name == "checkbox") {
        *type = 2;
      } else {
        *type = 0;  // "normal" 及未知名称按普通项（宽容）。
      }
      return true;
    }
    // 兼容数字编码：0/1/2；其余值按普通项。
    int number = 0;
    if (!ParseInt(&number)) {
      return false;
    }
    *type = (number == 1 || number == 2) ? number : 0;
    return true;
  }

  bool ParseBool(bool* out) {
    if (MatchLiteral("true")) {
      *out = true;
      return true;
    }
    if (MatchLiteral("false")) {
      *out = false;
      return true;
    }
    // 宽容：数字 0（false）/ 非 0（true）。
    int number = 0;
    if (ParseInt(&number)) {
      *out = number != 0;
      return true;
    }
    return false;
  }

  bool ParseInt(int* out) {
    bool negative = false;
    if (cursor_ != end_ && (*cursor_ == '-' || *cursor_ == '+')) {
      negative = *cursor_ == '-';
      ++cursor_;
    }
    if (cursor_ == end_ || *cursor_ < '0' || *cursor_ > '9') {
      return false;
    }
    long long value = 0;
    while (cursor_ != end_ && *cursor_ >= '0' && *cursor_ <= '9') {
      value = value * 10 + (*cursor_ - '0');
      if (value > 100000000LL) {
        value = 100000000LL;  // 钳制（真实值域远小于此）。
      }
      ++cursor_;
    }
    // 小数 / 指数部分（防 jsonEncode 意外输出）：消费但按整数近似。
    if (cursor_ != end_ && *cursor_ == '.') {
      ++cursor_;
      while (cursor_ != end_ && *cursor_ >= '0' && *cursor_ <= '9') {
        ++cursor_;
      }
    }
    if (cursor_ != end_ && (*cursor_ == 'e' || *cursor_ == 'E')) {
      ++cursor_;
      if (cursor_ != end_ && (*cursor_ == '-' || *cursor_ == '+')) {
        ++cursor_;
      }
      while (cursor_ != end_ && *cursor_ >= '0' && *cursor_ <= '9') {
        ++cursor_;
      }
    }
    *out = static_cast<int>(negative ? -value : value);
    return true;
  }

  bool ParseString(std::string* out) {
    out->clear();
    if (!Consume('"')) {
      return false;
    }
    while (true) {
      if (cursor_ == end_) {
        return false;
      }
      const char c = *cursor_;
      if (c == '"') {
        ++cursor_;
        return true;
      }
      if (static_cast<unsigned char>(c) < 0x20) {
        return false;  // 原始控制字符：严格拒绝。
      }
      if (c != '\\') {
        out->push_back(c);
        ++cursor_;
        continue;
      }
      // 转义序列。
      ++cursor_;
      if (cursor_ == end_) {
        return false;
      }
      const char escape = *cursor_;
      ++cursor_;
      switch (escape) {
        case '"':
          out->push_back('"');
          break;
        case '\\':
          out->push_back('\\');
          break;
        case '/':
          out->push_back('/');
          break;
        case 'b':
          out->push_back('\b');
          break;
        case 'f':
          out->push_back('\f');
          break;
        case 'n':
          out->push_back('\n');
          break;
        case 'r':
          out->push_back('\r');
          break;
        case 't':
          out->push_back('\t');
          break;
        case 'u': {
          unsigned int code_point = 0;
          if (!ParseHex4(&code_point)) {
            return false;
          }
          if (code_point >= 0xD800 && code_point <= 0xDBFF) {
            // 高代理：尝试配对紧随的 \uXXXX 低代理。
            if (end_ - cursor_ >= 2 && cursor_[0] == '\\' && cursor_[1] == 'u') {
              const char* saved = cursor_;
              cursor_ += 2;
              unsigned int low = 0;
              if (ParseHex4(&low) && low >= 0xDC00 && low <= 0xDFFF) {
                code_point =
                    0x10000 + ((code_point - 0xD800) << 10) + (low - 0xDC00);
              } else {
                cursor_ = saved;       // 还原，按孤立代理处理。
                code_point = 0xFFFD;
              }
            } else {
              code_point = 0xFFFD;     // 孤立高代理。
            }
          } else if (code_point >= 0xDC00 && code_point <= 0xDFFF) {
            code_point = 0xFFFD;       // 孤立低代理。
          }
          AppendUtf8(*out, code_point);
          break;
        }
        default:
          return false;
      }
    }
  }

  bool ParseHex4(unsigned int* value) {
    unsigned int result = 0;
    for (int i = 0; i < 4; ++i) {
      if (cursor_ == end_) {
        return false;
      }
      const char c = *cursor_;
      unsigned int digit = 0;
      if (c >= '0' && c <= '9') {
        digit = static_cast<unsigned int>(c - '0');
      } else if (c >= 'a' && c <= 'f') {
        digit = static_cast<unsigned int>(c - 'a' + 10);
      } else if (c >= 'A' && c <= 'F') {
        digit = static_cast<unsigned int>(c - 'A' + 10);
      } else {
        return false;
      }
      result = (result << 4) | digit;
      ++cursor_;
    }
    *value = result;
    return true;
  }

  // 宽容跳过任意 JSON 值（未知字段；深度上限防恶意嵌套）。
  bool SkipValue(int depth) {
    if (depth > 16) {
      return false;
    }
    SkipWhitespace();
    if (cursor_ == end_) {
      return false;
    }
    const char c = *cursor_;
    if (c == '"') {
      std::string scratch;
      return ParseString(&scratch);
    }
    if (c == '{') {
      ++cursor_;
      SkipWhitespace();
      if (Consume('}')) {
        return true;
      }
      while (true) {
        SkipWhitespace();
        std::string key;
        if (!ParseString(&key)) {
          return false;
        }
        SkipWhitespace();
        if (!Consume(':')) {
          return false;
        }
        if (!SkipValue(depth + 1)) {
          return false;
        }
        SkipWhitespace();
        if (Consume(',')) {
          continue;
        }
        return Consume('}');
      }
    }
    if (c == '[') {
      ++cursor_;
      SkipWhitespace();
      if (Consume(']')) {
        return true;
      }
      while (true) {
        if (!SkipValue(depth + 1)) {
          return false;
        }
        SkipWhitespace();
        if (Consume(',')) {
          continue;
        }
        return Consume(']');
      }
    }
    if (MatchLiteral("true") || MatchLiteral("false") ||
        MatchLiteral("null")) {
      return true;  // MatchLiteral 失败时不消费游标。
    }
    int number = 0;
    return ParseInt(&number);
  }

  const char* cursor_;
  const char* end_;
};

// 解析菜单 JSON 字符串（须以 NUL 结尾；Dart 传入的指针在本调用内有效）。
bool ParseTrayMenuJson(const char* json, std::vector<TrayMenuItem>* items) {
  TrayJsonParser parser(json, json + std::strlen(json));
  return parser.ParseItems(items);
}

// ===== 菜单构建与后端生命周期（仅在 GTK 主线程执行）=====

// 状态图标图片设置（路径含 '/' 按文件加载，否则按主题图标名）。
void SetStatusIconImage(TrayGtkApi& api, void* status_icon,
                        const std::string& icon) {
  if (icon.find('/') != std::string::npos) {
    api.StatusIconSetFromFile(status_icon, icon.c_str());
  } else {
    api.StatusIconSetFromIconName(status_icon, icon.c_str());
  }
}

// 菜单项点击（"activate" 信号；GTK 主线程执行）。
void OnMenuActivate(void* menu_item, void* /*user_data*/) {
  TrayGtkApi& api = TrayGtkApi::Get();
  if (api.ObjectGetData == nullptr || menu_item == nullptr) {
    return;
  }
  auto* handle = static_cast<MenuIdHandle*>(
      api.ObjectGetData(menu_item, kTrayMenuIdKey));
  if (handle == nullptr || !handle->value) {
    return;
  }
  // 先保命（引用移交退役池），再回调：Dart 侧为异步消费，指针可能晚读。
  g_tray_retired_ids.push_back(handle->value);
  while (g_tray_retired_ids.size() > kTrayRetiredLimit) {
    g_tray_retired_ids.pop_front();
  }
  // 持锁调用：与 set_callback(nullptr) 严格串行（dispose 安全保证）。
  std::lock_guard<std::mutex> lock(g_tray_callback_mutex);
  if (g_tray_callback != nullptr) {
    g_tray_callback(handle->value->c_str());
  }
}

// 菜单项销毁：释放壳（id 字符串由退役池引用保命）。
void OnMenuIdDestroy(void* data) {
  delete static_cast<MenuIdHandle*>(data);
}

// GtkStatusIcon "popup-menu" 信号（GTK 主线程执行）。
void OnStatusIconPopupMenu(void* status_icon, unsigned int button,
                           unsigned int activate_time, void* /*user_data*/) {
  TrayGtkApi& api = TrayGtkApi::Get();
  if (!api.ready || g_tray.menu == nullptr || api.MenuPopup == nullptr) {
    return;
  }
  api.MenuPopup(g_tray.menu, nullptr, nullptr, api.StatusIconPositionMenu,
                status_icon, button, activate_time);
}

// 构建全新菜单（GTK 主线程）。失败返回 nullptr（调用方映射 WB_ERR_FAILED）。
void* BuildTrayMenu(const std::vector<TrayMenuItem>& items) {
  TrayGtkApi& api = TrayGtkApi::Get();
  void* menu = api.MenuNew();
  if (menu == nullptr) {
    return nullptr;
  }
  for (const TrayMenuItem& item : items) {
    void* widget = nullptr;
    if (item.type == 1) {
      widget = api.SeparatorMenuItemNew();
    } else if (item.type == 2) {
      widget = api.CheckMenuItemNewWithLabel(item.label.c_str());
      if (widget != nullptr) {
        api.CheckMenuItemSetActive(widget, item.checked ? 1 : 0);
      }
    } else {
      widget = api.MenuItemNewWithLabel(item.label.c_str());
    }
    if (widget == nullptr) {
      continue;  // 单项创建失败不拖垮整体菜单。
    }
    if (item.type != 1 && !item.enabled) {
      api.WidgetSetSensitive(widget, 0);
    }
    if (item.type != 1) {
      auto* handle = new MenuIdHandle();
      handle->value = std::make_shared<const std::string>(item.id);
      api.ObjectSetDataFull(widget, kTrayMenuIdKey, handle, &OnMenuIdDestroy);
      (void)api.SignalConnectData(
          widget, "activate",
          TrayCastFunction<TrayGCallback>(&OnMenuActivate), nullptr, nullptr,
          0);
    }
    api.MenuShellAppend(menu, widget);
  }
  api.WidgetShowAll(menu);
  return menu;
}

// 确保托盘后端已创建（GTK 主线程）。返回 WB_OK / WB_ERR_FAILED /
// WB_ERR_UNSUPPORTED（无任何可用后端 / 无显示会话）。
int EnsureTrayCreated() {
  TrayGtkApi& api = TrayGtkApi::Get();
  if (!api.ready) {
    return WB_ERR_UNSUPPORTED;
  }
  if (g_tray.kind != TrayKind::kNone) {
    return WB_OK;
  }
  // 宿主（Flutter Linux）已在启动时 gtk_init；纯 headless / 测试进程由
  // gtk_init_check 尝试初始化——无 DISPLAY / WAYLAND_DISPLAY 时立即失败
  // （无副作用，绝不挂起）。
  int argc = 0;
  char** argv = nullptr;
  if (!api.InitCheck(&argc, &argv)) {
    return WB_ERR_FAILED;
  }
  const char* initial_icon =
      g_tray.icon.empty() ? "whiteboard" : g_tray.icon.c_str();
  if (api.app_indicator) {
    // 0 = APP_INDICATOR_CATEGORY_APPLICATION_STATUS。
    void* indicator = api.IndicatorNew("whiteboard", initial_icon, 0);
    if (indicator != nullptr) {
      api.IndicatorSetStatus(indicator, 1);  // 1 = ACTIVE。
      g_tray.kind = TrayKind::kAppIndicator;
      g_tray.indicator = indicator;
      return WB_OK;
    }
  }
  if (api.status_icon) {
    void* status_icon = api.StatusIconNew();
    if (status_icon != nullptr) {
      if (!g_tray.icon.empty()) {
        SetStatusIconImage(api, status_icon, g_tray.icon);
      }
      (void)api.SignalConnectData(
          status_icon, "popup-menu",
          TrayCastFunction<TrayGCallback>(&OnStatusIconPopupMenu), nullptr,
          nullptr, 0);
      api.StatusIconSetVisible(status_icon, 1);
      g_tray.kind = TrayKind::kStatusIcon;
      g_tray.status_icon = status_icon;
      return WB_OK;
    }
  }
  return WB_ERR_UNSUPPORTED;
}

// 设置图标（GTK 主线程）。
int ApplyTrayIcon(const std::string& icon) {
  const int created = EnsureTrayCreated();
  if (created != WB_OK) {
    return created;
  }
  TrayGtkApi& api = TrayGtkApi::Get();
  if (icon.empty()) {
    return WB_ERR_FAILED;  // 空图标名无法呈现。
  }
  if (g_tray.kind == TrayKind::kAppIndicator) {
    api.IndicatorSetIconFull(g_tray.indicator, icon.c_str(), nullptr);
  } else {
    SetStatusIconImage(api, g_tray.status_icon, icon);
  }
  g_tray.icon = icon;
  return WB_OK;
}

// 设置悬停提示（GTK 主线程；空串合法 = 清除）。
int ApplyTrayTooltip(const std::string& tooltip) {
  const int created = EnsureTrayCreated();
  if (created != WB_OK) {
    return created;
  }
  TrayGtkApi& api = TrayGtkApi::Get();
  if (g_tray.kind == TrayKind::kAppIndicator) {
    api.IndicatorSetTitle(g_tray.indicator, tooltip.c_str());
  } else {
    api.StatusIconSetTooltipText(g_tray.status_icon, tooltip.c_str());
  }
  g_tray.tooltip = tooltip;
  return WB_OK;
}

// 设置菜单（整体替换；GTK 主线程）。
int ApplyTrayMenu(const std::vector<TrayMenuItem>& items) {
  const int created = EnsureTrayCreated();
  if (created != WB_OK) {
    return created;
  }
  TrayGtkApi& api = TrayGtkApi::Get();
  void* menu = BuildTrayMenu(items);
  if (menu == nullptr) {
    return WB_ERR_FAILED;
  }
  void* old_menu = g_tray.menu;
  g_tray.menu = menu;
  if (g_tray.kind == TrayKind::kAppIndicator) {
    api.IndicatorSetMenu(g_tray.indicator, menu);  // 先换新引用…
  }
  if (old_menu != nullptr) {
    api.WidgetDestroy(old_menu);  // …再销毁旧菜单（避免悬空引用）。
  }
  return WB_OK;
}

// ===== 对外 ABI：4 个托盘符号 =====

extern "C" WB_LINUX_API int wb_linux_tray_set_icon(const char* icon) {
  WB_LINUX_TRY {
    if (icon == nullptr) {
      return WB_ERR_FAILED;
    }
    // 入参拷贝进投递闭包：超时迟到执行时原指针已失效。
    return RunOnTrayGtkThread([icon = std::string(icon)]() -> int {
      return ApplyTrayIcon(icon);
    });
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

extern "C" WB_LINUX_API int wb_linux_tray_set_tooltip(const char* tooltip) {
  WB_LINUX_TRY {
    if (tooltip == nullptr) {
      return WB_ERR_FAILED;
    }
    return RunOnTrayGtkThread([tooltip = std::string(tooltip)]() -> int {
      return ApplyTrayTooltip(tooltip);
    });
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

extern "C" WB_LINUX_API int wb_linux_tray_set_menu(const char* menu_json) {
  WB_LINUX_TRY {
    if (menu_json == nullptr) {
      return WB_ERR_FAILED;
    }
    // JSON 必须在本次调用内同步解析（Dart 侧入参内存在调用返回后即
    // 释放）；解析结果以值语义投递到 GTK 主线程（可安全迟到执行）。
    std::vector<TrayMenuItem> items;
    if (!ParseTrayMenuJson(menu_json, &items)) {
      return WB_ERR_FAILED;
    }
    return RunOnTrayGtkThread([items = std::move(items)]() -> int {
      return ApplyTrayMenu(items);
    });
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

extern "C" WB_LINUX_API void wb_linux_tray_set_callback(
    WbLinuxStrCallback callback) {
  // 回调槽更新 / 清理路径（Dart dispose）必须始终可用：不判定后端、
  // 不投递 GTK 线程（槽仅被 GTK 线程读取，更新本身线程安全）。
  WB_LINUX_TRY {
    std::lock_guard<std::mutex> lock(g_tray_callback_mutex);
    g_tray_callback = callback;
  }
  WB_LINUX_CATCH_VOID
}

}  // namespace wb::platform::linux_

#else  // !WB_LINUX_HAVE_GTK3

// 无 GTK3 的构建：托盘能力整体安全降级（无任何 GTK 依赖）。
namespace wb::platform::linux_ {

extern "C" WB_LINUX_API int wb_linux_tray_set_icon(const char* /*icon*/) {
  return WB_ERR_UNSUPPORTED;
}

extern "C" WB_LINUX_API int wb_linux_tray_set_tooltip(const char* /*tooltip*/) {
  return WB_ERR_UNSUPPORTED;
}

extern "C" WB_LINUX_API int wb_linux_tray_set_menu(const char* /*menu_json*/) {
  return WB_ERR_UNSUPPORTED;
}

extern "C" WB_LINUX_API void wb_linux_tray_set_callback(
    WbLinuxStrCallback /*callback*/) {}

}  // namespace wb::platform::linux_

#endif  // WB_LINUX_HAVE_GTK3
