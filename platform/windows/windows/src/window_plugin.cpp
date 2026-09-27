// window_plugin.cpp — 'window.*' / 'dialog.*' 能力实现：透明 / 置顶 / 鼠标
// 穿透 / 全屏 / 位置 / 尺寸 / 图片与白板文件对话框；含 UTF-8/UTF-16 转换
// 工具与兜底顶层窗口查找（Win32 / C++20）。
//
// 线程约束：全部接口必须在 UI 线程（平台线程）调用——由方法通道回调
// （whiteboard_windows_plugin.cpp）保证；周期任务经 UiTaskRunner 派发。

#include "window_plugin.h"

#include <flutter_windows.h>

#include <cmath>
#include <string>
#include <utility>
#include <vector>

// GetOpenFileNameW / CommDlgExtendedError（需链接 comdlg32.lib）。
#include <commdlg.h>

namespace wb::platform::windows {

// ===== 编码工具 =====

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      wide.data(), length);
  return wide;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int length = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                         static_cast<int>(wide.size()), nullptr,
                                         0, nullptr, nullptr);
  if (length <= 0) {
    return std::string();
  }
  std::string utf8(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      utf8.data(), length, nullptr, nullptr);
  return utf8;
}

// ===== 兜底顶层窗口查找 =====

namespace {

struct FindWindowContext {
  HWND best = nullptr;      // 可见且带标题栏（WS_CAPTION）的候选
  HWND fallback = nullptr;  // 首个合格候选
};

// EnumThreadWindows 回调：筛选当前线程创建的应用主窗口。
// 过滤规则：跳过子窗口与 owned 窗口（对话框 / 工具窗）；优先带标题栏
// 且可见的窗口（Flutter 主窗口在插件注册阶段——窗口 WM_CREATE 期间——
// 可能尚未显示，故可见性仅作偏好而非硬性条件）。
BOOL CALLBACK EnumThreadWindowProc(HWND hwnd, LPARAM lparam) {
  auto* context = reinterpret_cast<FindWindowContext*>(lparam);
  const LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
  if ((style & WS_CHILD) != 0) {
    return TRUE;  // 子窗口跳过
  }
  if (GetWindow(hwnd, GW_OWNER) != nullptr) {
    return TRUE;  // owned 窗口跳过（对话框 / 工具窗口）
  }
  const bool has_caption = (style & WS_CAPTION) == WS_CAPTION;
  if (has_caption && IsWindowVisible(hwnd) != FALSE) {
    context->best = hwnd;
    return FALSE;  // 已找到最佳候选，提前结束枚举
  }
  if (context->fallback == nullptr) {
    context->fallback = hwnd;
  }
  return TRUE;
}

}  // namespace

HWND FindAppTopLevelWindow() {
  FindWindowContext context;
  EnumThreadWindows(GetCurrentThreadId(), &EnumThreadWindowProc,
                    reinterpret_cast<LPARAM>(&context));
  return context.best != nullptr ? context.best : context.fallback;
}

// ===== WindowPlugin =====

WindowPlugin::WindowPlugin(UiTaskRunner* task_runner,
                           std::function<HWND()> window_locator)
    : task_runner_(task_runner), window_locator_(std::move(window_locator)) {}

WindowPlugin::~WindowPlugin() {
  StopForwardTimer();
}

HWND WindowPlugin::ResolveWindow() const {
  if (!window_locator_) {
    return nullptr;
  }
  return window_locator_();
}

bool WindowPlugin::EnsureOverlay(std::string* error) {
  const HWND hwnd = ResolveWindow();
  if (hwnd == nullptr) {
    if (error != nullptr) {
      *error = "无法解析应用主窗口句柄";
    }
    return false;
  }
  // 窗口重建（新 HWND）时重新绑定并复位轮询。
  if (overlay_ == nullptr || overlay_hwnd_ != hwnd) {
    StopForwardTimer();
    overlay_ = std::make_unique<TransparentOverlay>(hwnd);
    overlay_hwnd_ = hwnd;
  }
  return true;
}

double WindowPlugin::ScaleFactor(HWND hwnd) const {
  // Dart 侧坐标为逻辑像素；Win32 窗口 API 使用物理像素。
  // 使用引擎提供的 FlutterDesktopGetDpiForHWND，保证与 Flutter 内部
  // 同一 DPI 口径（见 flutter_windows.h 该函数注释）。
  const UINT dpi = FlutterDesktopGetDpiForHWND(hwnd);
  return dpi > 0 ? static_cast<double>(dpi) / 96.0 : 1.0;
}

bool WindowPlugin::SetTransparent(bool transparent, std::string* error) {
  if (!EnsureOverlay(error)) {
    return false;
  }
  // 透明结果（含 API 缺失 / 调用失败）透传给方法通道，由 Dart 侧决定
  // 是否降级到截图背景；*error 仅用于诊断。
  if (!overlay_->SetTransparent(transparent)) {
    if (error != nullptr) {
      *error = "设置窗口透明失败";
    }
    return false;
  }
  return true;
}

bool WindowPlugin::SetAlwaysOnTop(bool on_top, std::string* error) {
  const HWND hwnd = ResolveWindow();
  if (hwnd == nullptr) {
    if (error != nullptr) {
      *error = "无法解析应用主窗口句柄";
    }
    return false;
  }
  // 《透明批注模式技术方案》§7.1：HWND_TOPMOST / HWND_NOTOPMOST。
  if (SetWindowPos(hwnd, on_top ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE) == FALSE) {
    if (error != nullptr) {
      *error = "SetWindowPos(置顶) 失败，错误码 " +
               std::to_string(GetLastError());
    }
    return false;
  }
  return true;
}

bool WindowPlugin::SetIgnoreMouseEvents(bool ignore, bool forward,
                                        std::string* error) {
  if (!EnsureOverlay(error)) {
    return false;
  }
  if (!overlay_->SetPenetrate(ignore, forward)) {
    if (error != nullptr) {
      *error = "切换鼠标穿透失败";
    }
    return false;
  }
  if (ignore && forward) {
    // Windows 无原生 forward 语义（对照 macOS ignoresMouseEvents）：由宿主
    // 定时器驱动光标轮询，向窗口伪发悬停消息，使上层 UI 仍可获得 hover 反馈；
    // 限制说明见 TransparentOverlay::OnForwardTick。
    if (forward_timer_ == 0 && task_runner_ != nullptr) {
      forward_timer_ = task_runner_->SetRepeatingTimer(16, [this]() {
        if (overlay_ != nullptr) {
          overlay_->OnForwardTick();
        }
      });
    }
    // 定时器创建失败仅降级 hover 反馈；窗口穿透本身已生效，不视为错误。
  } else {
    StopForwardTimer();
  }
  return true;
}

void WindowPlugin::StopForwardTimer() {
  if (forward_timer_ != 0 && task_runner_ != nullptr) {
    task_runner_->KillRepeatingTimer(forward_timer_);
  }
  forward_timer_ = 0;
}

bool WindowPlugin::SetFullscreen(bool fullscreen, std::string* error) {
  const HWND hwnd = ResolveWindow();
  if (hwnd == nullptr) {
    if (error != nullptr) {
      *error = "无法解析应用主窗口句柄";
    }
    return false;
  }
  // 窗口句柄变化（窗口被重建）时，旧样式随旧窗口销毁，重置状态。
  if (fullscreen_hwnd_ != nullptr && fullscreen_hwnd_ != hwnd) {
    fullscreen_ = false;
    fullscreen_hwnd_ = nullptr;
  }
  if (fullscreen == fullscreen_) {
    return true;  // 幂等
  }
  if (fullscreen) {
    // 保存进入前状态用于退出恢复。
    saved_style_ = GetWindowLongPtrW(hwnd, GWL_STYLE);
    saved_rect_ = RECT{};
    GetWindowRect(hwnd, &saved_rect_);

    // 去边框：移除标题栏 / 可调边框 / 系统菜单（保留其余状态位）。
    const LONG_PTR borderless =
        saved_style_ & ~static_cast<LONG_PTR>(WS_CAPTION | WS_THICKFRAME |
                                              WS_MINIMIZEBOX |
                                              WS_MAXIMIZEBOX | WS_SYSMENU);
    SetWindowLongPtrW(hwnd, GWL_STYLE, borderless);

    // 贴合目标显示器物理边界（rcMonitor，含任务栏区域）。
    MONITORINFO monitor_info = {};
    monitor_info.cbSize = sizeof(MONITORINFO);
    const HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    if (monitor != nullptr &&
        GetMonitorInfoW(monitor, &monitor_info) != FALSE) {
      SetWindowPos(hwnd, nullptr, monitor_info.rcMonitor.left,
                   monitor_info.rcMonitor.top,
                   monitor_info.rcMonitor.right - monitor_info.rcMonitor.left,
                   monitor_info.rcMonitor.bottom - monitor_info.rcMonitor.top,
                   SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED |
                       SWP_SHOWWINDOW);
    }
    fullscreen_ = true;
    fullscreen_hwnd_ = hwnd;
  } else {
    if (fullscreen_ && fullscreen_hwnd_ == hwnd && IsWindow(hwnd) != FALSE) {
      SetWindowLongPtrW(hwnd, GWL_STYLE, saved_style_);
      const bool has_saved_rect = saved_rect_.right > saved_rect_.left &&
                                  saved_rect_.bottom > saved_rect_.top;
      if (has_saved_rect) {
        SetWindowPos(hwnd, nullptr, saved_rect_.left, saved_rect_.top,
                     saved_rect_.right - saved_rect_.left,
                     saved_rect_.bottom - saved_rect_.top,
                     SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED |
                         SWP_SHOWWINDOW);
      } else {
        SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                         SWP_FRAMECHANGED);
      }
      // 进入全屏前处于最大化状态时恢复最大化。
      if ((saved_style_ & WS_MAXIMIZE) != 0) {
        ShowWindow(hwnd, SW_MAXIMIZE);
      }
    }
    fullscreen_ = false;
    fullscreen_hwnd_ = nullptr;
  }
  return true;
}

bool WindowPlugin::SetPosition(int64_t x, int64_t y, std::string* error) {
  const HWND hwnd = ResolveWindow();
  if (hwnd == nullptr) {
    if (error != nullptr) {
      *error = "无法解析应用主窗口句柄";
    }
    return false;
  }
  const double scale = ScaleFactor(hwnd);
  const int physical_x =
      static_cast<int>(std::lround(static_cast<double>(x) * scale));
  const int physical_y =
      static_cast<int>(std::lround(static_cast<double>(y) * scale));
  if (SetWindowPos(hwnd, nullptr, physical_x, physical_y, 0, 0,
                   SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE) == FALSE) {
    if (error != nullptr) {
      *error = "SetWindowPos(位置) 失败，错误码 " +
               std::to_string(GetLastError());
    }
    return false;
  }
  return true;
}

bool WindowPlugin::SetSize(int64_t width, int64_t height, std::string* error) {
  const HWND hwnd = ResolveWindow();
  if (hwnd == nullptr) {
    if (error != nullptr) {
      *error = "无法解析应用主窗口句柄";
    }
    return false;
  }
  if (width <= 0 || height <= 0) {
    if (error != nullptr) {
      *error = "窗口尺寸必须为正数";
    }
    return false;
  }
  const double scale = ScaleFactor(hwnd);
  const int physical_width =
      static_cast<int>(std::lround(static_cast<double>(width) * scale));
  const int physical_height =
      static_cast<int>(std::lround(static_cast<double>(height) * scale));
  if (SetWindowPos(hwnd, nullptr, 0, 0, physical_width, physical_height,
                   SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE) == FALSE) {
    if (error != nullptr) {
      *error = "SetWindowPos(尺寸) 失败，错误码 " +
               std::to_string(GetLastError());
    }
    return false;
  }
  return true;
}

FileDialogOutcome WindowPlugin::OpenImageDialog(std::string* path,
                                               std::string* error) {
  // owner 沿用本文件既有的主窗口解析路径（见 ResolveWindow）；解析失败时
  // 以 nullptr owner 打开（系统按默认 owner 处理），不阻断对话框。
  const HWND owner = ResolveWindow();

  // 路径缓冲：为长路径预留足量空间（Windows 路径上限 32767 个宽字符），
  // 并保证以 NUL 填充（OPENFILENAMEW 要求可写缓冲）。
  std::vector<wchar_t> file_buffer(32768, L'\0');
  OPENFILENAMEW dialog = {};
  dialog.lStructSize = sizeof(dialog);
  dialog.hwndOwner = owner;
  // 过滤器：显示文本 \0 模式列表（末尾双 NUL 由字符串字面量语义保证）。
  dialog.lpstrFilter =
      L"图片文件 (*.png;*.jpg;*.jpeg;*.webp;*.bmp;*.gif)\0"
      L"*.png;*.jpg;*.jpeg;*.webp;*.bmp;*.gif\0";
  dialog.lpstrFile = file_buffer.data();
  dialog.nMaxFile = static_cast<DWORD>(file_buffer.size());
  dialog.lpstrTitle = L"选择图片";
  // 仅接受已存在文件；OFN_NOCHANGEDIR 避免对话框改动进程当前目录。
  dialog.Flags =
      OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_EXPLORER | OFN_NOCHANGEDIR;

  // 模态对话框：本调用在 UI 线程阻塞至用户选择 / 取消（方法通道回调
  // 本就运行在平台线程，符合 Win32 对话框要求）。
  if (GetOpenFileNameW(&dialog) == FALSE) {
    const DWORD extended_error = CommDlgExtendedError();
    if (extended_error == 0) {
      return FileDialogOutcome::kCancelled;  // 用户取消（关闭对话框）
    }
    if (error != nullptr) {
      *error =
          "文件对话框打开失败，错误码 " + std::to_string(extended_error);
    }
    return FileDialogOutcome::kFailed;
  }
  if (path != nullptr) {
    // 选中结果已是完整路径（OFN_EXPLORER 语义），直接转 UTF-8 回传。
    *path = WideToUtf8(file_buffer.data());
  }
  return FileDialogOutcome::kSelected;
}

FileDialogOutcome WindowPlugin::OpenBoardDialog(std::string* path,
                                                std::string* error) {
  const HWND owner = ResolveWindow();

  // 路径缓冲：为长路径预留足量空间（Windows 路径上限 32767 个宽字符）。
  std::vector<wchar_t> file_buffer(32768, L'\0');
  OPENFILENAMEW dialog = {};
  dialog.lStructSize = sizeof(dialog);
  dialog.hwndOwner = owner;
  // 过滤器：白板文件（.wbd）。
  dialog.lpstrFilter = L"白板文件 (*.wbd)\0*.wbd\0";
  dialog.lpstrFile = file_buffer.data();
  dialog.nMaxFile = static_cast<DWORD>(file_buffer.size());
  dialog.lpstrTitle = L"打开白板";
  // 仅接受已存在文件；OFN_NOCHANGEDIR 避免对话框改动进程当前目录。
  dialog.Flags =
      OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_EXPLORER | OFN_NOCHANGEDIR;

  if (GetOpenFileNameW(&dialog) == FALSE) {
    const DWORD extended_error = CommDlgExtendedError();
    if (extended_error == 0) {
      return FileDialogOutcome::kCancelled;  // 用户取消（关闭对话框）
    }
    if (error != nullptr) {
      *error =
          "文件对话框打开失败，错误码 " + std::to_string(extended_error);
    }
    return FileDialogOutcome::kFailed;
  }
  if (path != nullptr) {
    *path = WideToUtf8(file_buffer.data());
  }
  return FileDialogOutcome::kSelected;
}

FileDialogOutcome WindowPlugin::SaveBoardDialog(
    std::string* path, const std::string& suggested_path, std::string* error) {
  const HWND owner = ResolveWindow();

  std::vector<wchar_t> file_buffer(32768, L'\0');
  // 预填建议文件名（完整路径；超出缓冲上限时截断）。
  if (!suggested_path.empty()) {
    const std::wstring wide = Utf8ToWide(suggested_path);
    const size_t max_chars = file_buffer.size() - 1;
    const size_t copy_chars =
        wide.size() < max_chars ? wide.size() : max_chars;
    for (size_t i = 0; i < copy_chars; ++i) {
      file_buffer[i] = wide[i];
    }
  }

  OPENFILENAMEW dialog = {};
  dialog.lStructSize = sizeof(dialog);
  dialog.hwndOwner = owner;
  dialog.lpstrFilter = L"白板文件 (*.wbd)\0*.wbd\0";
  dialog.lpstrFile = file_buffer.data();
  dialog.nMaxFile = static_cast<DWORD>(file_buffer.size());
  dialog.lpstrTitle = L"保存白板";
  dialog.lpstrDefExt = L"wbd";
  // 覆盖确认；OFN_NOCHANGEDIR 避免对话框改动进程当前目录。
  dialog.Flags =
      OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_EXPLORER | OFN_NOCHANGEDIR;

  if (GetSaveFileNameW(&dialog) == FALSE) {
    const DWORD extended_error = CommDlgExtendedError();
    if (extended_error == 0) {
      return FileDialogOutcome::kCancelled;  // 用户取消（关闭对话框）
    }
    if (error != nullptr) {
      *error =
          "保存对话框打开失败，错误码 " + std::to_string(extended_error);
    }
    return FileDialogOutcome::kFailed;
  }
  if (path != nullptr) {
    *path = WideToUtf8(file_buffer.data());
  }
  return FileDialogOutcome::kSelected;
}

}  // namespace wb::platform::windows
