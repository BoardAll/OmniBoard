// whiteboard_windows 插件宿主实现：注册 'whiteboard/windows' 方法通道，
// 分发 window.* / dialog.* / shortcut.* / tray.* / capture.* 调用到各子插件，
// 并经 UI 线程任务执行器（UiTaskRunner）回传 'shortcut.triggered' /
// 'tray.clicked' 事件（《Flutter + C++ 工程结构设计》§6.1 / §6.5）。
//
// 线程模型：Flutter 引擎保证方法通道回调在平台线程（本插件注册所在线程，
// 即 UI 线程）执行；所有窗口操作、RegisterHotKey、Shell_NotifyIcon 调用
// 均在该线程完成。UiTaskRunner 为异步事件与周期任务提供 UI 线程保证。

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <whiteboard_windows/whiteboard_windows_plugin.h>

#include "window_plugin.h"

namespace wb::platform::windows {

namespace {

// 方法通道名（与 Dart 侧 WindowsWindowPlugin.channelName 一致，冻结）。
constexpr char kChannelName[] = "whiteboard/windows";

// 内部消息窗口类名（进程内唯一）。
constexpr wchar_t kTaskRunnerClass[] = L"WhiteboardWindows.TaskRunner";

// 任务队列唤醒消息（仅内部使用）。
constexpr UINT kTaskRunnerMessage = WM_APP + 0x40;

// ---- 方法参数提取工具（Dart StandardMessageCodec 解码后的 EncodableMap） ----

bool GetBoolArgument(const flutter::EncodableMap* args, const char* key,
                     bool* out) {
  if (args == nullptr) {
    return false;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return false;
  }
  if (const bool* value = std::get_if<bool>(&it->second)) {
    *out = *value;
    return true;
  }
  return false;
}

bool GetIntArgument(const flutter::EncodableMap* args, const char* key,
                    int64_t* out) {
  if (args == nullptr) {
    return false;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return false;
  }
  // Dart int 按取值范围编码为 int32_t 或 int64_t，两者都要接受。
  if (const int32_t* value = std::get_if<int32_t>(&it->second)) {
    *out = *value;
    return true;
  }
  if (const int64_t* value = std::get_if<int64_t>(&it->second)) {
    *out = *value;
    return true;
  }
  return false;
}

bool GetStringArgument(const flutter::EncodableMap* args, const char* key,
                       std::string* out) {
  if (args == nullptr) {
    return false;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return false;
  }
  if (const std::string* value = std::get_if<std::string>(&it->second)) {
    *out = *value;
    return true;
  }
  return false;
}

// 捕获帧 → 方法通道载荷（bytes / width / height / stride，与 Dart 侧
// WbCaptureFrame 字段对齐；captureDisplay / captureVirtualScreen 共用）。
flutter::EncodableValue CapturedFrameToPayload(CapturedFrame frame) {
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("bytes")] =
      flutter::EncodableValue(std::move(frame.bytes));
  payload[flutter::EncodableValue("width")] =
      flutter::EncodableValue(static_cast<int64_t>(frame.width));
  payload[flutter::EncodableValue("height")] =
      flutter::EncodableValue(static_cast<int64_t>(frame.height));
  payload[flutter::EncodableValue("stride")] =
      flutter::EncodableValue(static_cast<int64_t>(frame.stride));
  return flutter::EncodableValue(std::move(payload));
}

}  // namespace

// ===== UiTaskRunner：UI 线程任务派发 =====

UiTaskRunner::UiTaskRunner() : ui_thread_id_(GetCurrentThreadId()) {
  const HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = &UiTaskRunner::WindowProcThunk;
  window_class.hInstance = instance;
  window_class.lpszClassName = kTaskRunnerClass;
  // 类同名注册失败（ERROR_CLASS_ALREADY_EXISTS）时复用既有类，行为等价。
  RegisterClassW(&window_class);
  window_ = CreateWindowExW(0, kTaskRunnerClass, L"", 0, 0, 0, 0, 0,
                            HWND_MESSAGE, nullptr, instance, this);
}

UiTaskRunner::~UiTaskRunner() {
  // 析构须发生在创建线程（UI 线程）：插件由 registrar 在平台线程销毁。
  if (window_ != nullptr) {
    for (const auto& entry : timers_) {
      KillTimer(window_, entry.first);
    }
    timers_.clear();
    DestroyWindow(window_);
    window_ = nullptr;
  }
}

void UiTaskRunner::Post(std::function<void()> task) {
  if (!task) {
    return;
  }
  if (IsUiThread()) {
    // 已在 UI 线程：同步执行，保持调用顺序。
    task();
    return;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    queue_.push_back(std::move(task));
  }
  if (window_ != nullptr) {
    PostMessageW(window_, kTaskRunnerMessage, 0, 0);
  } else {
    // 消息窗口创建失败（极端情况）：就地执行，尽力而为。
    DrainQueue();
  }
}

UINT_PTR UiTaskRunner::SetRepeatingTimer(UINT interval_ms,
                                         std::function<void()> callback) {
  if (!IsUiThread() || window_ == nullptr || !callback) {
    return 0;
  }
  // 选取未占用的定时器 id：hWnd 非空时 SetTimer 要求非零 id（0 的自动
  // 分配语义仅对 hWnd == NULL 定义），故本执行器自行维护唯一 id。
  UINT_PTR timer_id = 1;
  while (timers_.count(timer_id) != 0) {
    ++timer_id;
  }
  if (SetTimer(window_, timer_id, interval_ms, nullptr) == 0) {
    return 0;
  }
  timers_[timer_id] = std::move(callback);
  return timer_id;
}

void UiTaskRunner::KillRepeatingTimer(UINT_PTR timer_id) {
  if (timer_id == 0 || window_ == nullptr) {
    return;
  }
  KillTimer(window_, timer_id);
  timers_.erase(timer_id);
}

LRESULT CALLBACK UiTaskRunner::WindowProcThunk(HWND hwnd, UINT message,
                                               WPARAM wparam, LPARAM lparam) {
  UiTaskRunner* self = reinterpret_cast<UiTaskRunner*>(
      GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    self = static_cast<UiTaskRunner*>(create->lpCreateParams);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(self));
  }
  if (self != nullptr) {
    return self->HandleMessage(hwnd, message, wparam, lparam);
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT UiTaskRunner::HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
  switch (message) {
    case kTaskRunnerMessage:
      DrainQueue();
      return 0;
    case WM_TIMER: {
      // 先拷贝回调，允许回调内部注销自身定时器。
      std::function<void()> callback;
      const auto it = timers_.find(static_cast<UINT_PTR>(wparam));
      if (it != timers_.end()) {
        callback = it->second;
      }
      if (callback) {
        callback();
      }
      return 0;
    }
    case WM_CLOSE:
      // 消息窗口生命周期由 UiTaskRunner 析构控制，不响应关闭。
      return 0;
    default:
      break;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

void UiTaskRunner::DrainQueue() {
  std::vector<std::function<void()>> pending;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    pending.swap(queue_);
  }
  for (auto& task : pending) {
    if (task) {
      task();
    }
  }
}

// ===== 宿主插件 =====

// FlutterPlugin 实现：持有通道与全部子插件，生命周期由 registrar 管理。
class WhiteboardWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit WhiteboardWindowsPlugin(flutter::PluginRegistrarWindows* registrar);
  ~WhiteboardWindowsPlugin() override;

  WhiteboardWindowsPlugin(const WhiteboardWindowsPlugin&) = delete;
  WhiteboardWindowsPlugin& operator=(const WhiteboardWindowsPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  // 回传原生事件（'shortcut.triggered' / 'tray.clicked'）。
  void EmitEvent(const std::string& method, const std::string& id);
  // 解析 Flutter 主窗口 HWND（见 .h 注释）。
  HWND ResolveMainWindow() const;

  flutter::PluginRegistrarWindows* registrar_ = nullptr;  // 非持有
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  UiTaskRunner task_runner_;  // 声明在子插件之前：先构造、后析构
  WindowPlugin window_plugin_;
  ShortcutPlugin shortcut_plugin_;
  TrayPlugin tray_plugin_;
  ScreenCapturePlugin screen_capture_plugin_;
};

void WhiteboardWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<WhiteboardWindowsPlugin>(registrar));
}

WhiteboardWindowsPlugin::WhiteboardWindowsPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance())),
      window_plugin_(&task_runner_,
                     [this]() { return ResolveMainWindow(); }),
      shortcut_plugin_([this](const std::string& method,
                              const std::string& id) { EmitEvent(method, id); }),
      tray_plugin_([this](const std::string& method, const std::string& id) {
        EmitEvent(method, id);
      }) {
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

WhiteboardWindowsPlugin::~WhiteboardWindowsPlugin() {
  // 先摘除通道回调，避免析构期间的迟到消息进入已失效对象。
  if (channel_ != nullptr) {
    channel_->SetMethodCallHandler(nullptr);
  }
}

HWND WhiteboardWindowsPlugin::ResolveMainWindow() const {
  // 首选 Flutter 官方路径：registrar → implicit view → 原生 HWND。
  // Flutter 桌面应用在注册插件前已创建 view；每次调用重新查询以兼容
  // 窗口重建场景。
  if (flutter::FlutterView* view = registrar_->GetView()) {
    if (HWND hwnd = view->GetNativeWindow()) {
      return hwnd;
    }
  }
  // 兜底：当前（平台）线程创建的顶层窗口（见 window_plugin.cpp）。
  return FindAppTopLevelWindow();
}

void WhiteboardWindowsPlugin::EmitEvent(const std::string& method,
                                        const std::string& id) {
  // 统一经执行器派发：事件产生点（消息窗口 WndProc）本就在 UI 线程，
  // Post() 将同步执行；若未来从其他线程触发，则投递回 UI 线程保证
  // 通道调用线程一致。
  task_runner_.Post([this, method, id]() {
    if (channel_ == nullptr) {
      return;
    }
    flutter::EncodableMap payload;
    payload[flutter::EncodableValue("id")] = flutter::EncodableValue(id);
    channel_->InvokeMethod(method,
                           std::make_unique<flutter::EncodableValue>(payload));
  });
}

void WhiteboardWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* args =
      std::get_if<flutter::EncodableMap>(call.arguments());

  // ---- 窗口 ----

  if (method == "window.setTransparent") {
    bool transparent = false;
    if (!GetBoolArgument(args, "transparent", &transparent)) {
      result->Error("invalid-arguments", "missing bool 'transparent'");
      return;
    }
    std::string error;
    const bool applied = window_plugin_.SetTransparent(transparent, &error);
    // 契约：结果透传 bool（false = 原生 API 缺失 / 调用失败），由 Dart 侧
    // 决定是否降级到截图背景；失败不再回 FlutterError。
    result->Success(flutter::EncodableValue(applied));
    return;
  }

  if (method == "window.setAlwaysOnTop") {
    bool on_top = false;
    if (!GetBoolArgument(args, "onTop", &on_top)) {
      result->Error("invalid-arguments", "missing bool 'onTop'");
      return;
    }
    std::string error;
    if (!window_plugin_.SetAlwaysOnTop(on_top, &error)) {
      result->Error("window-operation-failed", error);
      return;
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "window.setIgnoreMouseEvents") {
    bool ignore = false;
    bool forward = false;
    if (!GetBoolArgument(args, "ignore", &ignore)) {
      result->Error("invalid-arguments", "missing bool 'ignore'");
      return;
    }
    // forward 可选，缺省 false。
    GetBoolArgument(args, "forward", &forward);
    std::string error;
    if (!window_plugin_.SetIgnoreMouseEvents(ignore, forward, &error)) {
      result->Error("window-operation-failed", error);
      return;
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "window.setFullscreen") {
    bool fullscreen = false;
    if (!GetBoolArgument(args, "fullscreen", &fullscreen)) {
      result->Error("invalid-arguments", "missing bool 'fullscreen'");
      return;
    }
    std::string error;
    if (!window_plugin_.SetFullscreen(fullscreen, &error)) {
      result->Error("window-operation-failed", error);
      return;
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "window.setPosition") {
    int64_t x = 0;
    int64_t y = 0;
    if (!GetIntArgument(args, "x", &x) || !GetIntArgument(args, "y", &y)) {
      result->Error("invalid-arguments", "missing int 'x' or 'y'");
      return;
    }
    std::string error;
    if (!window_plugin_.SetPosition(x, y, &error)) {
      result->Error("window-operation-failed", error);
      return;
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "window.setSize") {
    int64_t width = 0;
    int64_t height = 0;
    if (!GetIntArgument(args, "width", &width) ||
        !GetIntArgument(args, "height", &height)) {
      result->Error("invalid-arguments", "missing int 'width' or 'height'");
      return;
    }
    std::string error;
    if (!window_plugin_.SetSize(width, height, &error)) {
      result->Error("window-operation-failed", error);
      return;
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  // ---- 文件对话框 ----

  if (method == "dialog.openImage") {
    std::string path;
    std::string error;
    const FileDialogOutcome outcome =
        window_plugin_.OpenImageDialog(&path, &error);
    if (outcome == FileDialogOutcome::kSelected) {
      result->Success(flutter::EncodableValue(path));
    } else if (outcome == FileDialogOutcome::kCancelled) {
      // 契约：用户取消返回 null。
      result->Success(flutter::EncodableValue());
    } else {
      result->Error("dialog-failed", error);
    }
    return;
  }

  if (method == "dialog.openBoard") {
    std::string path;
    std::string error;
    const FileDialogOutcome outcome =
        window_plugin_.OpenBoardDialog(&path, &error);
    if (outcome == FileDialogOutcome::kSelected) {
      result->Success(flutter::EncodableValue(path));
    } else if (outcome == FileDialogOutcome::kCancelled) {
      // 契约：用户取消返回 null。
      result->Success(flutter::EncodableValue());
    } else {
      result->Error("dialog-failed", error);
    }
    return;
  }

  if (method == "dialog.saveBoard") {
    // suggestedPath 可选：缺失视为空（仅用于预填初始文件名）。
    std::string suggested_path;
    GetStringArgument(args, "suggestedPath", &suggested_path);
    std::string path;
    std::string error;
    const FileDialogOutcome outcome =
        window_plugin_.SaveBoardDialog(&path, suggested_path, &error);
    if (outcome == FileDialogOutcome::kSelected) {
      result->Success(flutter::EncodableValue(path));
    } else if (outcome == FileDialogOutcome::kCancelled) {
      // 契约：用户取消返回 null。
      result->Success(flutter::EncodableValue());
    } else {
      result->Error("dialog-failed", error);
    }
    return;
  }

  // ---- 全局快捷键 ----

  if (method == "shortcut.register") {
    std::string accelerator;
    std::string id;
    if (!GetStringArgument(args, "accelerator", &accelerator) ||
        !GetStringArgument(args, "id", &id)) {
      result->Error("invalid-arguments", "missing 'accelerator' or 'id'");
      return;
    }
    std::string error_code;
    std::string error_message;
    if (!shortcut_plugin_.Register(accelerator, id, &error_code,
                                   &error_message)) {
      result->Error(error_code.empty() ? "register-failed" : error_code,
                    error_message);
      return;
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "shortcut.unregister") {
    std::string id;
    if (!GetStringArgument(args, "id", &id)) {
      result->Error("invalid-arguments", "missing 'id'");
      return;
    }
    shortcut_plugin_.Unregister(id);
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "shortcut.unregisterAll") {
    shortcut_plugin_.UnregisterAll();
    result->Success(flutter::EncodableValue());
    return;
  }

  // ---- 托盘 ----

  if (method == "tray.setIcon") {
    std::string icon_path;
    if (!GetStringArgument(args, "iconPath", &icon_path)) {
      result->Error("invalid-arguments", "missing 'iconPath'");
      return;
    }
    std::string error_message;
    if (!tray_plugin_.SetIcon(icon_path, &error_message)) {
      result->Error("icon-load-failed", error_message);
      return;
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "tray.setTooltip") {
    std::string tooltip;
    if (!GetStringArgument(args, "tooltip", &tooltip)) {
      result->Error("invalid-arguments", "missing 'tooltip'");
      return;
    }
    std::string error_message;
    if (!tray_plugin_.SetTooltip(tooltip, &error_message)) {
      result->Error("tray-operation-failed", error_message);
      return;
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "tray.setMenu") {
    const flutter::EncodableMap* map_args =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (map_args == nullptr) {
      result->Error("invalid-arguments", "missing 'items'");
      return;
    }
    const auto it = map_args->find(flutter::EncodableValue("items"));
    if (it == map_args->end()) {
      result->Error("invalid-arguments", "missing 'items'");
      return;
    }
    const auto* items = std::get_if<flutter::EncodableList>(&it->second);
    if (items == nullptr) {
      result->Error("invalid-arguments", "'items' must be a list");
      return;
    }
    std::vector<TrayMenuItem> parsed;
    parsed.reserve(items->size());
    for (const flutter::EncodableValue& item_value : *items) {
      const auto* item = std::get_if<flutter::EncodableMap>(&item_value);
      if (item == nullptr) {
        continue;  // 跳过非法项，保持其余菜单可用
      }
      TrayMenuItem parsed_item;
      GetStringArgument(item, "id", &parsed_item.id);
      GetStringArgument(item, "label", &parsed_item.label);
      std::string type;
      if (GetStringArgument(item, "type", &type)) {
        if (type == "separator") {
          parsed_item.type = TrayMenuItemType::kSeparator;
        } else if (type == "checkbox") {
          parsed_item.type = TrayMenuItemType::kCheckbox;
        } else {
          parsed_item.type = TrayMenuItemType::kNormal;
        }
      }
      GetBoolArgument(item, "enabled", &parsed_item.enabled);
      GetBoolArgument(item, "checked", &parsed_item.checked);
      parsed.push_back(std::move(parsed_item));
    }
    std::string error_message;
    if (!tray_plugin_.SetMenu(std::move(parsed), &error_message)) {
      result->Error("tray-operation-failed", error_message);
      return;
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  // ---- 屏幕捕获 ----

  if (method == "capture.captureDisplay") {
    int64_t display_id = -1;
    if (!GetIntArgument(args, "displayId", &display_id)) {
      result->Error("invalid-arguments", "missing int 'displayId'");
      return;
    }
    CapturedFrame frame;
    if (!screen_capture_plugin_.CaptureDisplay(display_id, &frame)) {
      // 契约：失败 / 不可用返回 null。
      result->Success(flutter::EncodableValue());
      return;
    }
    result->Success(CapturedFrameToPayload(std::move(frame)));
    return;
  }

  if (method == "capture.captureVirtualScreen") {
    CapturedFrame frame;
    // 自身窗口排除句柄沿用宿主既有解析路径（registrar → view → HWND，
    // 含兜底顶层窗口查找）。
    if (!screen_capture_plugin_.CaptureVirtualScreen(ResolveMainWindow(),
                                                     &frame)) {
      // 契约：失败返回 null。
      result->Success(flutter::EncodableValue());
      return;
    }
    result->Success(CapturedFrameToPayload(std::move(frame)));
    return;
  }

  if (method == "capture.isAvailable") {
    result->Success(
        flutter::EncodableValue(ScreenCapturePlugin::IsAvailable()));
    return;
  }

  result->NotImplemented();
}

}  // namespace wb::platform::windows

// ===== C 接口导出（Flutter 工具生成的注册代码入口）=====

void WhiteboardWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  wb::platform::windows::WhiteboardWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
