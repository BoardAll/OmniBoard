// whiteboard_linux 插件公共 C 接口契约与内部共享声明（C++20）。
//
// 本头文件是 Dart 侧 platform/linux/lib/src/wb_ffi_bindings.dart 的唯一
// 对应物：Dart 通过 dart:ffi 查找的 17 个 wb_linux_* 扁平 C 符号全部在
// 此声明（extern "C"，默认可见性导出）。Dart 文件头注明「与原生头文件
// linux/include/window_plugin.h 一一对应，修改需同步」——两份文件必须
// 成对修改。
//
// 状态码约定（与 Dart WbStatus 一致）：
//   WB_OK              = 0  成功；
//   WB_ERR_UNSUPPORTED = 1  当前后端不支持该能力（如 Wayland 原生会话的
//                           全局快捷键 / 截屏）；
//   WB_ERR_FAILED      = 2  调用失败（无 X11 会话、主窗口未找到、符号
//                           缺失、X 请求被拒等）。
//
// 线程约定（《透明批注模式技术方案》§8.4）：
//   * 全部导出函数在 Dart 主 isolate 线程调用（Flutter Linux 下即 GTK
//     主线程），内部对共享 X11 连接 / GTK 状态做了串行化保护；
//   * wb_linux_shortcut_set_callback / wb_linux_tray_set_callback 注册的
//     回调可能在任意线程触发（快捷键为专属 X11 读取线程；托盘为 GTK
//     主线程）。Dart 侧使用 NativeCallable.listener，天然跨线程安全；
//     原生侧保证：set_callback(nullptr) 返回后不再有任何在途回调。

#pragma once

#include <stddef.h>

#if defined(_WIN32)
#define WB_LINUX_API __declspec(dllexport)
#elif defined(__GNUC__) || defined(__clang__)
#define WB_LINUX_API __attribute__((visibility("default")))
#else
#define WB_LINUX_API
#endif

#define WB_OK 0
#define WB_ERR_UNSUPPORTED 1
#define WB_ERR_FAILED 2

#ifdef __cplusplus
extern "C" {
#endif

// ===========================================================================
// 对外 ABI：17 个扁平 C API（与 Dart wbLookupFunction 符号一一对应）。
// ===========================================================================

// ---- 窗口能力（wb_window_plugin.dart：6 符号）----------------------------
//
// 语义对齐《透明批注模式技术方案》§7.3（X11）/ §7.4（Wayland）：
//   * X11 / XWayland：透明 = 设置 _NET_WM_WINDOW_TYPE_DOCK（原值保存，
//     关闭时还原；实际透视由合成器 + 应用侧 ARGB 视觉决定）；置顶 =
//     _NET_WM_STATE_ABOVE；穿透 = XShape 输入区域置空；全屏 = EWMH
//     _NET_WM_STATE_FULLSCREEN；位置 / 尺寸 = EWMH _NET_MOVERESIZE_WINDOW
//     + 直接 XMove/Resize 双保险。
//   * Wayland 原生：透明 / 置顶 / 全屏 / 位置尺寸经进程内 GDK 请求，
//     合成器可忽略（best-effort）；穿透 = GDK 输入区域（部分合成器
//     不支持）。
//   * 主窗口发现：WM_CLASS / 标题包含 "whiteboard"（可用环境变量
//     WB_LINUX_WINDOW_CLASS / WB_LINUX_WINDOW_TITLE / WB_LINUX_WINDOW_ID
//     覆盖，见实现注释）；缓存 + 失效重查。

// 窗口背景透明开关（transparent: 0/1）。
WB_LINUX_API int wb_linux_window_set_transparent(int transparent);

// 始终置顶开关（on_top: 0/1）。
WB_LINUX_API int wb_linux_window_set_always_on_top(int on_top);

// 鼠标事件穿透开关（ignore: 0/1）。forward 为 Windows 平台转发悬停
// 语义，Linux 无对应机制，实现忽略该参数（与 Dart 注释一致）。
WB_LINUX_API int wb_linux_window_set_ignore_mouse_events(int ignore, int forward);

// 全屏开关（fullscreen: 0/1）。
WB_LINUX_API int wb_linux_window_set_fullscreen(int fullscreen);

// 移动窗口（屏幕逻辑坐标；负坐标合法，如主屏左侧的显示器）。
WB_LINUX_API int wb_linux_window_set_position(int x, int y);

// 调整窗口尺寸（逻辑像素；宽高必须 > 0）。
WB_LINUX_API int wb_linux_window_set_size(int width, int height);

// ---- 全局快捷键（wb_shortcut_plugin.dart：4 符号）------------------------
//
// X11 / XWayland：XGrabKey 抓取（含 CapsLock / NumLock 变体），专属后台
// 线程读取 KeyPress 并经回调投递；Wayland 原生：无全局快捷键协议，注册
// 返回 WB_ERR_UNSUPPORTED（应用侧降级为应用内快捷键）。

// 原生字符串事件回调：参数为业务 id（UTF-8，注册 / 菜单项 id）。
typedef void (*WbLinuxStrCallback)(const char* id);

// 注册全局快捷键。accelerator 形如 'Ctrl+Shift+J'（键名集合与 Dart
// WbAccelerator 归一结果一致：Ctrl/Shift/Alt/Super 修饰键 + A-Z、0-9、
// F1-F24、Space/Tab/Escape/Return/Backspace/Delete/Insert/Home/End/
// PageUp/PageDown/方向键）。解析失败、抓取冲突返回 WB_ERR_FAILED。
WB_LINUX_API int wb_linux_shortcut_register(const char* accelerator,
                                            const char* id);

// 注销单个快捷键（id 未注册视为成功）。
WB_LINUX_API int wb_linux_shortcut_unregister(const char* id);

// 注销全部快捷键。
WB_LINUX_API int wb_linux_shortcut_unregister_all(void);

// 注册 / 清除触发回调（NULL 清除；清除后保证不再回调）。
WB_LINUX_API void wb_linux_shortcut_set_callback(WbLinuxStrCallback callback);

// ---- 系统托盘（wb_tray_plugin.dart：4 符号）------------------------------
//
// 实现经 StatusNotifierItem / AppIndicator（libayatana-appindicator3，
// 运行时 dlopen；缺失时降级 GtkStatusIcon，再缺失返回 WB_ERR_UNSUPPORTED）。
// 菜单以 JSON 字符串传递，协议：数组，元素 {id,label,type,enabled,checked}，
// type ∈ {normal,separator,checkbox}（字段顺序与 Dart jsonEncode 一致）。
// 构建缺少 GTK3 时全部托盘调用返回 WB_ERR_UNSUPPORTED。

// 设置托盘图标（主题图标名或绝对路径）。
WB_LINUX_API int wb_linux_tray_set_icon(const char* icon);

// 设置悬停提示。
WB_LINUX_API int wb_linux_tray_set_tooltip(const char* tooltip);

// 设置右键菜单（整体替换；JSON 非法返回 WB_ERR_FAILED）。
WB_LINUX_API int wb_linux_tray_set_menu(const char* menu_json);

// 注册 / 清除菜单项点击回调（参数为菜单项 id；NULL 清除）。
WB_LINUX_API void wb_linux_tray_set_callback(WbLinuxStrCallback callback);

// ---- 屏幕捕获（wb_screen_capture.dart：3 符号）---------------------------
//
// X11 / XWayland：XGetImage 抓取 root window 的显示器矩形（RandR monitors
// 优先、Xinerama 兜底、再兜底整屏）；输出 BGRA、stride = width*4，
// 缓冲由 wb_linux_capture_free 释放；Wayland 原生：无抓屏协议
// （需 xdg-desktop-portal + PipeWire），返回 WB_ERR_UNSUPPORTED。

// 捕获显示器：display_id 为 -1 捕获主显示器；>= 0 为按 root 坐标
// （左→右、上→下）排序的显示器序号。成功时 *out_bytes 为 malloc 缓冲
// （须经 wb_linux_capture_free 释放），*out_len 为字节数。
WB_LINUX_API int wb_linux_capture_display(int display_id,
                                          unsigned char** out_bytes,
                                          int* out_len,
                                          int* out_width,
                                          int* out_height,
                                          int* out_stride);

// 释放 wb_linux_capture_display 返回的缓冲（NULL 安全）。
WB_LINUX_API void wb_linux_capture_free(unsigned char* bytes);

// 原生捕获能力是否可用（WB_OK 可用；Wayland / 无 X11 返回
// WB_ERR_UNSUPPORTED）。
WB_LINUX_API int wb_linux_capture_is_available(void);

#ifdef __cplusplus
}  // extern "C"
#endif

// ===========================================================================
// 以下为插件内部共享声明（各实现源文件使用，不属于对外 ABI）。
// ===========================================================================
#ifdef __cplusplus

#include <cstring>
#include <mutex>
#include <string>

namespace wb::platform::linux_ {

// ---- 通用工具与异常边界（window_plugin.cpp 实现）-------------------------

// 依序 dlopen 候选库名（RTLD_LAZY | RTLD_LOCAL），返回首个成功句柄，
// 全部失败返回 nullptr。候选数组示例见各实现文件（如
// {"libX11.so.6", "libX11.so"}）。
void* DlOpenFirst(const char* const* names, size_t count);

// dlsym 包装（handle 为空返回 nullptr；绝不抛异常）。
void* DlSym(void* handle, const char* symbol);

// dlsym 结果 → 函数指针（经 memcpy 转换，规避 -Wpedantic 下函数指针 / 对象
// 指针 reinterpret_cast 的可移植性告警；POSIX 平台两者尺寸一致，由
// static_assert 保证）。
template <typename Fn>
Fn DlSymAs(void* handle, const char* symbol) {
  void* address = DlSym(handle, symbol);
  Fn function = nullptr;
  static_assert(sizeof(function) == sizeof(address),
                "function pointer size mismatch");
  std::memcpy(&function, &address, sizeof(address));
  return function;
}

// 读取环境变量（未设置 / 空串 → ""）。
std::string EnvString(const char* name);

// 读取环境变量：未设置 / 空串时返回 fallback。
std::string EnvOrDefault(const char* name, const char* fallback);

// 大小写不敏感的 ASCII 子串匹配（needle 为空视为命中）。
bool ContainsCaseInsensitive(const std::string& text, const std::string& needle);

// 导出函数异常边界宏：-fno-exceptions 构建（__cpp_exceptions 未定义）下
// 退化为直通，保证两种构建模式均可编译。
#if defined(__cpp_exceptions)
#define WB_LINUX_TRY try
#define WB_LINUX_CATCH(status) \
  catch (...) {                \
    return (status);           \
  }
#define WB_LINUX_CATCH_VOID \
  catch (...) {}
#else
// 无异常构建：展开为单次执行的 do-while 块（宏后不加分号亦可编译），
// 函数体自带 return，异常路径宏参数被忽略。
#define WB_LINUX_TRY do
#define WB_LINUX_CATCH(status) while (false);
#define WB_LINUX_CATCH_VOID while (false);
#endif

// ---- 会话后端判定（window_plugin.cpp 实现）-------------------------------

// 进程当前图形会话后端：
//   * WB_LINUX_BACKEND=x11|wayland|none 环境变量可显式覆盖（测试 / 强制）；
//   * 进程内 GDK display 名称（":" 前缀 = X11，含 XWayland；"wayland"
//     前缀 = Wayland 原生）为最高优先级自动判据；
//   * 无 GTK（纯 headless / 测试）时按环境变量：DISPLAY 非空 → X11；
//     WAYLAND_DISPLAY / XDG_SESSION_TYPE=wayland → Wayland；否则 kNone。
// 判定结果进程内缓存。
enum class SessionBackend { kNone, kX11, kWayland };

SessionBackend ResolveSessionBackend();

// ---- GDK 探测（transparent_overlay_wayland.cpp 实现）---------------------

// 进程内 GDK display 后端种类（未加载 GTK / 未初始化 → kNone）。
// ResolveSessionBackend 在可用时采用该判据。
enum class GdkDisplayKind { kNone, kX11, kWayland };

GdkDisplayKind ProbeGdkDisplayKind();

// ---- Wayland（GDK）后端窗口操作（transparent_overlay_wayland.cpp 实现）--
//
// 全部在 Dart 主线程（GTK 主线程）调用；GDK 未就绪 / 目标窗口未找到时
// 返回 WB_ERR_FAILED，所需 GDK 原语缺失时返回 WB_ERR_UNSUPPORTED。
// 无 Wayland 构建支持（WB_LINUX_HAVE_WAYLAND 未定义）时全部返回降级码。

int WaylandWindowSetTransparent(bool transparent);
int WaylandWindowSetAlwaysOnTop(bool on_top);
int WaylandWindowSetIgnoreMouseEvents(bool ignore, bool forward);
int WaylandWindowSetFullscreen(bool fullscreen);
int WaylandWindowSetPosition(int x, int y);
int WaylandWindowSetSize(int width, int height);

// ---- X11 后端窗口操作（transparent_overlay_x11.cpp 实现）-----------------
//
// 同上：成功 WB_OK；无法连接 X / 主窗口未找到 / X 请求被拒 WB_ERR_FAILED；
// XShape 扩展缺失（穿透）返回 WB_ERR_UNSUPPORTED。无 X11 构建支持
// （WB_LINUX_HAVE_X11 未定义）时全部返回降级码。

int X11WindowSetTransparent(bool transparent);
int X11WindowSetAlwaysOnTop(bool on_top);
int X11WindowSetIgnoreMouseEvents(bool ignore, bool forward);
int X11WindowSetFullscreen(bool fullscreen);
int X11WindowSetPosition(int x, int y);
int X11WindowSetSize(int width, int height);

#if defined(WB_LINUX_HAVE_X11)

#include <X11/Xlib.h>

// libX11 / libXext(XShape) 运行时符号表：所有符号经 dlopen/dlsym 获取，
// 无链接期依赖；Load 失败时 X11 能力整体安全降级（不崩溃）。
struct X11Api {
  // ---- libX11 核心（Load 成功后 core == true）----
  Display* (*OpenDisplay)(const char*) = nullptr;
  int (*CloseDisplay)(Display*) = nullptr;
  Window (*DefaultRootWindow)(Display*) = nullptr;
  Status (*QueryTree)(Display*, Window, Window*, Window*, Window**, unsigned*) = nullptr;
  int (*Free)(void*) = nullptr;
  Atom (*InternAtom)(Display*, const char*, Bool) = nullptr;
  int (*GetWindowProperty)(Display*, Window, Atom, long, long, Bool, Atom, Atom*,
                           int*, unsigned long*, unsigned long*,
                           unsigned char**) = nullptr;
  int (*ChangeProperty)(Display*, Window, Atom, Atom, int, int,
                        const unsigned char*, int) = nullptr;
  int (*DeleteProperty)(Display*, Window, Atom) = nullptr;
  Status (*SendEvent)(Display*, Window, Bool, long, XEvent*) = nullptr;
  int (*Sync)(Display*, Bool) = nullptr;
  int (*Flush)(Display*) = nullptr;
  int (*MoveWindow)(Display*, Window, int, int) = nullptr;
  int (*ResizeWindow)(Display*, Window, unsigned, unsigned) = nullptr;
  int (*MoveResizeWindow)(Display*, Window, int, int, unsigned, unsigned) = nullptr;
  int (*RaiseWindow)(Display*, Window) = nullptr;
  Status (*GetWindowAttributes)(Display*, Window, XWindowAttributes*) = nullptr;
  KeySym (*StringToKeysym)(const char*) = nullptr;
  KeyCode (*KeysymToKeycode)(Display*, KeySym) = nullptr;
  int (*GrabKey)(Display*, int, unsigned, Window, Bool, int, int) = nullptr;
  int (*UngrabKey)(Display*, int, unsigned, Window) = nullptr;
  int (*SelectInput)(Display*, Window, long) = nullptr;
  int (*NextEvent)(Display*, XEvent*) = nullptr;
  int (*Pending)(Display*) = nullptr;
  int (*ConnectionNumber)(Display*) = nullptr;
  XErrorHandler (*SetErrorHandler)(XErrorHandler) = nullptr;
  XImage* (*GetImage)(Display*, Drawable, int, int, unsigned, unsigned,
                      unsigned long, int) = nullptr;
  int (*DestroyImage)(XImage*) = nullptr;
  // 可选（仅诊断用途；缺失不影响能力）。
  int (*GetErrorText)(Display*, int, char*, int) = nullptr;

  // ---- libXext / XShape 输入区域（可选；shape 指示可用性）----
  Bool (*ShapeQueryExtension)(Display*, int*, int*) = nullptr;
  void (*ShapeCombineRectangles)(Display*, Window, int, int, int, XRectangle*,
                                 int, int, int) = nullptr;

  bool core = false;
  bool shape = false;

  // 进程级单例（幂等加载；失败后允许重试）。
  static X11Api& Get();
};

// 主线程共享 X11 连接（窗口操作 / 截屏共用）：
//   * 懒打开（XOpenDisplay(nullptr)），进程生命周期内保持；失败返回
//     nullptr（后续调用重试，不做失败缓存）；
//   * 调用方必须持有 X11MainDisplayMutex()，同一连接的全部请求串行化。
Display* X11MainDisplay();
std::mutex& X11MainDisplayMutex();

// X 协议错误捕获（RAII，线程内串行使用）：
//   构造 → 进入捕获态；FinishAndCheck() → XSync 后返回是否发生错误
//   （true = 发生错误，调用方可据此把操作映射为 WB_ERR_FAILED）；
//   析构 → 未 Finish 时自动冲刷一次。
// 实现说明：Xlib 错误 handler 为进程级全局状态，本插件在 libX11 加载
// 成功后安装一次分流处理器——处于捕获态的本线程错误记录待查；其余
// 线程 / 时段转发链上的旧 handler；无旧 handler 时静默忽略（绝不触发
// Xlib 默认 handler 的 exit(1) 行为，任何异步 X 错误都不会终止宿主）。
class X11ErrorTrap {
 public:
  explicit X11ErrorTrap(Display* display);
  ~X11ErrorTrap();
  X11ErrorTrap(const X11ErrorTrap&) = delete;
  X11ErrorTrap& operator=(const X11ErrorTrap&) = delete;

  // XSync + 读取本线程捕获的错误码；幂等。返回 true 表示捕获到错误。
  bool FinishAndCheck();

  // 最近一次捕获的错误码（0 = 无；如 BadAccess=10）。
  unsigned char error_code() const { return error_code_; }

 private:
  Display* display_ = nullptr;
  bool finished_ = false;
  unsigned char error_code_ = 0;
};

#endif  // WB_LINUX_HAVE_X11

}  // namespace wb::platform::linux_

#endif  // __cplusplus
