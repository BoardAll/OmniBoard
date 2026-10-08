// whiteboard_windows 插件内部共享头：子插件声明、加速键解析、事件回调类型、
// UTF-8/UTF-16 转换工具与 UI 线程任务派发（C++20 / Win32）。
//
// 仅插件内部源文件使用；对外契约以 include/whiteboard_windows/*.h 与
// Dart 侧 'whiteboard/windows' 方法通道为准。
#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace wb::platform::windows {

// ===== 编码工具 =====

// UTF-8 字符串 → UTF-16 宽字符串（转换失败返回空串）。
std::wstring Utf8ToWide(const std::string& utf8);

// UTF-16 宽字符串 → UTF-8 字符串（转换失败返回空串）。
std::string WideToUtf8(const std::wstring& wide);

// ===== 事件回传（原生 → Dart）=====

// 原生事件回调：method 为 'shortcut.triggered' / 'tray.clicked'，
// id 为业务标识（UTF-8，与 Dart 侧注册 id / 菜单项 id 一致）。
using EventEmitter = std::function<void(const std::string& method,
                                        const std::string& id)>;

// ===== 加速键解析（shortcut_plugin.cpp 实现）=====

// RegisterHotKey 绑定参数。
struct Accelerator {
  UINT modifiers = 0;    // MOD_CONTROL / MOD_SHIFT / MOD_ALT / MOD_WIN 位或
  UINT virtual_key = 0;  // VK_*（A-Z、0-9、F1-F24、方向键等，见 .cpp 键位表）
};

// 解析 'Ctrl+Shift+J' 形式加速键字符串；失败返回 nullopt 并以 UTF-8
// 文本填充 *error（原因描述，用于 FlutterError message）。
std::optional<Accelerator> ParseAccelerator(const std::string& accelerator,
                                            std::string* error);

// ===== UI 线程任务派发（whiteboard_windows_plugin.cpp 实现）=====

// 记录创建线程（Flutter 平台线程即 UI 线程）ID 的任务执行器。
// Post() 语义：
//   * 调用线程 == UI 线程 → 立刻同步执行（零开销，保证顺序）；
//   * 其他线程 → 入队并 PostMessage 唤醒 UI 线程消息泵后取出执行。
// SetRepeatingTimer() 供窗口穿透 forward 轮询等周期任务使用，回调在
// UI 线程触发。
class UiTaskRunner {
 public:
  UiTaskRunner();
  ~UiTaskRunner();
  UiTaskRunner(const UiTaskRunner&) = delete;
  UiTaskRunner& operator=(const UiTaskRunner&) = delete;

  // 内部消息窗口是否创建成功（仅 UI 线程有效）。
  bool IsValid() const { return window_ != nullptr; }

  // 当前线程是否为创建本执行器的 UI 线程。
  bool IsUiThread() const { return GetCurrentThreadId() == ui_thread_id_; }

  // 派发任务到 UI 线程（见类注释语义）。
  void Post(std::function<void()> task);

  // 注册周期定时器（仅 UI 线程调用）；返回定时器 id，0 表示失败。
  UINT_PTR SetRepeatingTimer(UINT interval_ms,
                             std::function<void()> callback);

  // 取消周期定时器（仅 UI 线程调用）。
  void KillRepeatingTimer(UINT_PTR timer_id);

  // 内部消息窗口句柄（HWND_MESSAGE 窗口，仅 UI 线程访问）。
  HWND window() const { return window_; }

 private:
  static LRESULT CALLBACK WindowProcThunk(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam);
  LRESULT HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  void DrainQueue();

  HWND window_ = nullptr;
  DWORD ui_thread_id_ = 0;
  std::mutex mutex_;
  std::vector<std::function<void()>> queue_;
  std::map<UINT_PTR, std::function<void()>> timers_;
};

// ===== 透明批注覆盖层（transparent_overlay.cpp 实现）=====

// 封装《透明批注模式技术方案》§3 / §4 所需窗口能力：
//   * 透明背景（SetWindowCompositionAttribute 强调色策略，DWM 合成；
//     规避顶层 WS_EX_LAYERED 不合成 Flutter 加速内容导致的整窗黑屏）；
//   * 穿透态 ↔ 批注态（WS_EX_TRANSPARENT 切换；forward 轮询转发悬停）；
//   * 覆盖层形态（无边框 + topmost + 全屏覆盖虚拟屏幕 + 任务栏隐藏）。
//
// 所有方法必须在 UI 线程（创建窗口的线程）调用。
class TransparentOverlay {
 public:
  explicit TransparentOverlay(HWND hwnd);

  // 透明背景开关：动态调用 user32!SetWindowCompositionAttribute 设置
  // 强调色策略。成功返回 true；API 缺失（旧系统）或调用失败返回 false，
  // 由 Dart 侧决定降级方案（如改用截图背景）。
  bool SetTransparent(bool transparent);
  bool IsTransparent() const { return transparent_; }

  // 穿透态（penetrate=true，鼠标事件交给系统）与批注态（false，窗口接收
  // 鼠标）切换。forward 仅在穿透态有效：由宿主定时器驱动 OnForwardTick
  // 伪造悬停消息（Windows 无原生 forward 语义，限制见 .cpp 注释）。
  bool SetPenetrate(bool penetrate, bool forward);
  bool IsPenetrating() const { return penetrate_; }

  // 进入覆盖层形态（保存原样式/位置 → 无边框 + topmost + 覆盖虚拟屏幕
  // 全屏 + WS_EX_TOOLWINDOW 隐藏任务栏项）。
  bool Enter();
  // 退出覆盖层形态（恢复进入前保存的样式与位置）。
  bool Exit();
  bool IsEntered() const { return entered_; }

  // 穿透态 forward 轮询（宿主定时器每帧调用）：光标位置变化时向窗口
  // PostMessage 伪造 WM_MOUSEMOVE / WM_MOUSELEAVE，供 Flutter hover 使用。
  void OnForwardTick();

 private:
  // 依据 penetrate_ 状态同步 WS_EX_TRANSPARENT。
  bool ApplyExtendedStyles();

  HWND hwnd_ = nullptr;
  bool transparent_ = false;
  bool penetrate_ = false;
  bool forward_ = false;
  bool entered_ = false;

  // Enter() 保存的原状；Exit() 恢复。
  LONG_PTR saved_style_ = 0;
  LONG_PTR saved_ex_style_ = 0;
  RECT saved_rect_{};

  // forward 轮询状态。
  POINT last_forward_pt_{LONG_MIN, LONG_MIN};
  bool forward_cursor_inside_ = false;
};

// ===== 窗口控制（window_plugin.cpp 实现）=====

// 文件对话框（'dialog.openImage' / 'dialog.openBoard' / 'dialog.saveBoard'）
// 的结果（三态：选中 / 取消 / 失败）。
enum class FileDialogOutcome {
  kSelected,   // 用户选中文件（*path 已填充为绝对路径）
  kCancelled,  // 用户取消（未选择文件）
  kFailed,     // 对话框打开失败（*error 已填充原因）
};

// 'window.*' / 'dialog.*' 方法通道能力实现（置顶 / 全屏 / 位置 / 尺寸 /
// 透明 / 穿透 / 图片与白板文件对话框）。task_runner 用于周期任务；
// window_locator 每次调用重新解析主窗口 HWND（Flutter view HWND，兜底为
// 进程顶层窗口），保证窗口重建后可用。
class WindowPlugin {
 public:
  WindowPlugin(UiTaskRunner* task_runner, std::function<HWND()> window_locator);
  ~WindowPlugin();
  WindowPlugin(const WindowPlugin&) = delete;
  WindowPlugin& operator=(const WindowPlugin&) = delete;

  // 以下操作成功返回 true；失败返回 false 并以 UTF-8 文本填充 *error。
  bool SetTransparent(bool transparent, std::string* error);
  bool SetAlwaysOnTop(bool on_top, std::string* error);
  bool SetIgnoreMouseEvents(bool ignore, bool forward, std::string* error);
  bool SetFullscreen(bool fullscreen, std::string* error);
  bool SetPosition(int64_t x, int64_t y, std::string* error);   // 逻辑像素
  bool SetSize(int64_t width, int64_t height, std::string* error);  // 逻辑像素

  // 弹出模态「选择图片」文件对话框（GetOpenFileNameW）。
  // owner 窗口沿用 ResolveWindow()（窗口重建后依然有效；无法解析时以
  // 系统默认 owner 打开，不阻断对话框）。返回 kSelected 时 *path 为选中
  // 文件绝对路径；kFailed 时 *error 为失败原因（UTF-8）；kCancelled 时
  // 两个输出参数不变。
  FileDialogOutcome OpenImageDialog(std::string* path, std::string* error);

  // 弹出模态「选择组件」文件对话框（GetOpenFileNameW，过滤 SVG / 图片）；
  // 语义同 [OpenImageDialog]。
  FileDialogOutcome OpenComponentDialog(std::string* path, std::string* error);

  // 弹出模态「打开白板」文件对话框（GetOpenFileNameW，过滤 .wbd）；
  // 语义同 [OpenImageDialog]。
  FileDialogOutcome OpenBoardDialog(std::string* path, std::string* error);

  // 弹出模态「保存白板」文件对话框（GetSaveFileNameW，默认扩展名 .wbd，
  // 覆盖确认）。suggested_path 非空时作为初始文件名预填（完整路径）；
  // 语义同 [OpenImageDialog]。
  FileDialogOutcome SaveBoardDialog(std::string* path,
                                    const std::string& suggested_path,
                                    std::string* error);

 private:
  // 解析主窗口；失败返回 nullptr。
  HWND ResolveWindow() const;
  // 确保 overlay_ 绑定到当前主窗口（窗口重建时自动重绑）。
  bool EnsureOverlay(std::string* error);
  // 逻辑像素 → 物理像素缩放系数（dpi / 96）。
  double ScaleFactor(HWND hwnd) const;
  void StopForwardTimer();

  UiTaskRunner* task_runner_ = nullptr;
  std::function<HWND()> window_locator_;
  HWND overlay_hwnd_ = nullptr;
  std::unique_ptr<TransparentOverlay> overlay_;

  // 全屏状态（保存进入前样式 / 位置）。
  HWND fullscreen_hwnd_ = nullptr;
  bool fullscreen_ = false;
  LONG_PTR saved_style_ = 0;
  RECT saved_rect_{};

  // forward 轮询定时器。
  UINT_PTR forward_timer_ = 0;
};

// 兜底窗口查找：当前线程（平台线程）创建的第一个非子窗口顶层窗口。
// 首选路径为 registrar->GetView()->GetNativeWindow()，本函数仅在
// Flutter view 尚未就绪时兜底。
HWND FindAppTopLevelWindow();

// ===== 全局快捷键（shortcut_plugin.cpp 实现）=====

// RegisterHotKey / UnregisterHotKey 封装：HWND_MESSAGE 消息窗口接收
// WM_HOTKEY 并回发 'shortcut.triggered' 事件。
class ShortcutPlugin {
 public:
  explicit ShortcutPlugin(EventEmitter emitter);
  ~ShortcutPlugin();
  ShortcutPlugin(const ShortcutPlugin&) = delete;
  ShortcutPlugin& operator=(const ShortcutPlugin&) = delete;

  // 注册全局快捷键。解析失败 *error_code = 'invalid-accelerator'，
  // 系统注册失败（如冲突）*error_code = 'register-failed'。
  bool Register(const std::string& accelerator, const std::string& id,
                std::string* error_code, std::string* error_message);
  // 注销单个快捷键（id 未注册视为成功）。
  bool Unregister(const std::string& id);
  // 注销全部快捷键。
  void UnregisterAll();

 private:
  struct Entry {
    std::string id;           // 业务 id（UTF-8）
    std::string accelerator;  // 原始加速键文本（诊断用）
  };

  static LRESULT CALLBACK WindowProcThunk(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam);
  LRESULT HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  bool EnsureWindow(std::string* error_message);
  void HandleHotKey(int hotkey_id);

  HWND window_ = nullptr;
  EventEmitter emitter_;
  int next_hotkey_id_ = 1;
  std::map<int, Entry> entries_;  // 热键 id → 注册项
  std::map<std::string, int, std::less<>> by_business_id_;  // 业务 id → 热键 id
};

// ===== 系统托盘（tray_plugin.cpp 实现）=====

// 托盘菜单项类型（与 Dart WbTrayMenuItemType 对应）。
enum class TrayMenuItemType {
  kNormal,
  kSeparator,
  kCheckbox,
};

struct TrayMenuItem {
  std::string id;     // 业务 id（UTF-8，点击事件回传）
  std::string label;  // 显示文本（UTF-8）
  TrayMenuItemType type = TrayMenuItemType::kNormal;
  bool enabled = true;
  bool checked = false;
};

// Shell_NotifyIconW（NIM_ADD / NIM_MODIFY / NIM_DELETE）+ TrackPopupMenu 封装：
// 右键弹出菜单，选中项回发 'tray.clicked' 事件。
class TrayPlugin {
 public:
  explicit TrayPlugin(EventEmitter emitter);
  ~TrayPlugin();
  TrayPlugin(const TrayPlugin&) = delete;
  TrayPlugin& operator=(const TrayPlugin&) = delete;

  // 设置托盘图标（.ico 绝对路径）；失败填充 *error_message。
  bool SetIcon(const std::string& icon_path, std::string* error_message);
  // 设置悬停提示。
  bool SetTooltip(const std::string& tooltip, std::string* error_message);
  // 整体替换右键菜单（弹出时动态构建，本调用仅缓存）。
  bool SetMenu(std::vector<TrayMenuItem> items, std::string* error_message);

 private:
  static constexpr UINT kIconId = 1;

  static LRESULT CALLBACK WindowProcThunk(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam);
  LRESULT HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  bool EnsureWindow(std::string* error_message);
  // 将当前 icon_ / tooltip_ 状态推送到 Shell（首次自动 NIM_ADD）。
  bool Notify(DWORD flags);
  // 右键菜单显示（TrackPopupMenu，返回选中项并回发事件）。
  void ShowContextMenu();

  HWND window_ = nullptr;
  EventEmitter emitter_;
  bool icon_added_ = false;
  HICON icon_ = nullptr;  // 由本插件 LoadImage 创建，需 DestroyIcon
  std::wstring tooltip_;
  std::vector<TrayMenuItem> menu_items_;
  UINT taskbar_created_message_ = 0;  // RegisterWindowMessageW("TaskbarCreated")
};

// ===== 屏幕捕获（screen_capture.cpp 实现）=====

// 捕获帧（BGRA 自上而下，stride = width * 4）。
struct CapturedFrame {
  std::vector<uint8_t> bytes;
  int32_t width = 0;
  int32_t height = 0;
  int32_t stride = 0;
};

// GDI BitBlt 屏幕捕获。调用前应确认已获得用户授权（《安全与合规设计》）。
class ScreenCapturePlugin {
 public:
  ScreenCapturePlugin() = default;

  // 捕获显示器画面：display_id 为 -1 时捕获主显示器；>= 0 为按虚拟桌面
  // 位置（左→右、上→下）排序的显示器序号。失败返回 false。
  bool CaptureDisplay(int64_t display_id, CapturedFrame* out) const;

  // 捕获整虚拟桌面（SM_XVIRTUALSCREEN 等；多显示器拼接，坐标可为负）。
  // exclude_window 非空时：抓取前将其从截屏中排除
  // （SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)，失败忽略），抓取后
  // 恢复 WDA_NONE，防止把应用自身覆盖层截入画面。失败返回 false。
  bool CaptureVirtualScreen(HWND exclude_window, CapturedFrame* out) const;

  // 原生捕获能力探测（GDI 恒可用）。
  static bool IsAvailable() { return true; }
};

}  // namespace wb::platform::windows
