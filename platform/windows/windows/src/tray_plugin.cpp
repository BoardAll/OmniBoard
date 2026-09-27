// tray_plugin.cpp — 系统托盘：Shell_NotifyIconW（NIM_ADD / NIM_MODIFY /
// NIM_DELETE）+ 右键 TrackPopupMenu 上下文菜单，选中项回发 'tray.clicked'。
//
// 窗口选择：使用隐藏顶层窗口（而非 HWND_MESSAGE）——TrackPopupMenu 需要
// owner 窗口可被设为前台（SetForegroundWindow），消息窗口无法成为前台窗口。
//
// 线程约束：全部接口必须在 UI 线程调用；explorer 重启由 TaskbarCreated
// 注册消息触发重新注册。

#include "window_plugin.h"

#include <shellapi.h>  // NOTIFYICONDATAW / Shell_NotifyIconW（LEAN 模式需显式包含）

#include <string>
#include <utility>
#include <vector>

namespace wb::platform::windows {

namespace {

// 托盘窗口类名（进程内唯一）。
constexpr wchar_t kTrayWindowClass[] = L"WhiteboardWindows.Tray";

// 托盘回调消息（Shell_NotifyIcon 的 uCallbackMessage）。
constexpr UINT kTrayCallbackMessage = WM_APP + 0x271;

// 菜单命令 id 起始值（TrackPopupMenu 约定使用 0x8000 以上避免冲突）。
constexpr UINT kMenuCommandBase = 0x8000;

}  // namespace

TrayPlugin::TrayPlugin(EventEmitter emitter) : emitter_(std::move(emitter)) {
  // explorer 重启广播消息（"TaskbarCreated"），用于重新注册图标。
  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
}

TrayPlugin::~TrayPlugin() {
  if (window_ != nullptr) {
    if (icon_added_) {
      Notify(NIM_DELETE);
    }
    if (icon_ != nullptr) {
      DestroyIcon(icon_);
      icon_ = nullptr;
    }
    DestroyWindow(window_);
    window_ = nullptr;
  } else if (icon_ != nullptr) {
    DestroyIcon(icon_);
    icon_ = nullptr;
  }
}

bool TrayPlugin::EnsureWindow(std::string* error_message) {
  if (window_ != nullptr && IsWindow(window_) != FALSE) {
    return true;
  }
  const HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = &TrayPlugin::WindowProcThunk;
  window_class.hInstance = instance;
  window_class.lpszClassName = kTrayWindowClass;
  // 类已注册（ERROR_CLASS_ALREADY_EXISTS）时复用既有类。
  RegisterClassW(&window_class);
  // 隐藏顶层窗口：创建后不显示；Shell 通知消息需要真实窗口投递。
  window_ = CreateWindowExW(WS_EX_TOOLWINDOW, kTrayWindowClass, L"", WS_POPUP,
                            0, 0, 0, 0, nullptr, nullptr, instance, this);
  if (window_ == nullptr) {
    if (error_message != nullptr) {
      *error_message = "创建托盘窗口失败（错误码 " +
                       std::to_string(GetLastError()) + "）";
    }
    return false;
  }
  return true;
}

bool TrayPlugin::Notify(DWORD flags) {
  if (window_ == nullptr) {
    return false;
  }
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(NOTIFYICONDATAW);
  data.hWnd = window_;
  data.uID = kIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kTrayCallbackMessage;
  data.hIcon = icon_;
  if (!tooltip_.empty()) {
    // szTip 固定 128 宽字符，_TRUNCATE 超长安全截断。
    wcsncpy_s(data.szTip, tooltip_.c_str(), _TRUNCATE);
  }
  if (Shell_NotifyIconW(flags, &data) != FALSE) {
    icon_added_ = flags != NIM_DELETE;
    return true;
  }
  // NIM_ADD 因图标已存在（explorer 重启竞态）失败时回退 NIM_MODIFY，反之亦然。
  if (flags == NIM_ADD) {
    if (Shell_NotifyIconW(NIM_MODIFY, &data) != FALSE) {
      icon_added_ = true;
      return true;
    }
    return false;
  }
  if (flags == NIM_MODIFY) {
    if (Shell_NotifyIconW(NIM_ADD, &data) != FALSE) {
      icon_added_ = true;
      return true;
    }
    return false;
  }
  // NIM_DELETE：失败视为已被清理（explorer 重启等场景），清空状态即可。
  icon_added_ = false;
  return true;
}

bool TrayPlugin::SetIcon(const std::string& icon_path,
                         std::string* error_message) {
  if (!EnsureWindow(error_message)) {
    return false;
  }
  const std::wstring wide_path = Utf8ToWide(icon_path);
  if (wide_path.empty()) {
    if (error_message != nullptr) {
      *error_message = "托盘图标路径为空或编码无效";
    }
    return false;
  }
  const int width = GetSystemMetrics(SM_CXSMICON);
  const int height = GetSystemMetrics(SM_CYSMICON);
  HICON new_icon = static_cast<HICON>(LoadImageW(
      nullptr, wide_path.c_str(), IMAGE_ICON, width, height, LR_LOADFROMFILE));
  if (new_icon == nullptr) {
    if (error_message != nullptr) {
      *error_message = "加载托盘图标失败：" + icon_path;
    }
    return false;
  }
  HICON old_icon = icon_;
  icon_ = new_icon;
  // 已有图标 → NIM_MODIFY 原位替换；否则 NIM_ADD 新增。
  if (!(icon_added_ ? Notify(NIM_MODIFY) : Notify(NIM_ADD))) {
    icon_ = old_icon;  // 推送失败回滚，避免状态错位
    DestroyIcon(new_icon);
    if (error_message != nullptr) {
      *error_message = "Shell_NotifyIcon 更新图标失败";
    }
    return false;
  }
  if (old_icon != nullptr) {
    DestroyIcon(old_icon);
  }
  return true;
}

bool TrayPlugin::SetTooltip(const std::string& tooltip,
                            std::string* error_message) {
  tooltip_ = Utf8ToWide(tooltip);
  if (icon_added_) {
    if (!Notify(NIM_MODIFY)) {
      if (error_message != nullptr) {
        *error_message = "Shell_NotifyIcon 更新提示失败";
      }
      return false;
    }
  }
  // 图标尚未设置时仅缓存，随 NIM_ADD 一并生效。
  return true;
}

bool TrayPlugin::SetMenu(std::vector<TrayMenuItem> items,
                         std::string* error_message) {
  if (!EnsureWindow(error_message)) {
    return false;
  }
  // 菜单在弹出时（ShowContextMenu）按当前缓存动态构建。
  menu_items_ = std::move(items);
  return true;
}

LRESULT CALLBACK TrayPlugin::WindowProcThunk(HWND hwnd, UINT message,
                                             WPARAM wparam, LPARAM lparam) {
  TrayPlugin* self =
      reinterpret_cast<TrayPlugin*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    self = static_cast<TrayPlugin*>(create->lpCreateParams);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (self != nullptr) {
    return self->HandleMessage(hwnd, message, wparam, lparam);
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT TrayPlugin::HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) {
  // explorer 重启（任务栏重建）后需重新注册图标。
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    icon_added_ = false;
    if (icon_ != nullptr) {
      Notify(NIM_ADD);
    }
    return 0;
  }
  if (message == kTrayCallbackMessage) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
      case WM_RBUTTONUP:
      case WM_CONTEXTMENU:
        // 契约未定义图标单击事件；左右键均弹出菜单（可发现性优先）。
        ShowContextMenu();
        return 0;
      default:
        break;
    }
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

void TrayPlugin::ShowContextMenu() {
  if (menu_items_.empty()) {
    return;  // 未配置菜单：点击无操作
  }
  POINT cursor = {};
  if (GetCursorPos(&cursor) == FALSE) {
    return;
  }
  const HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  UINT command_id = kMenuCommandBase;
  std::vector<std::string> command_ids;  // 命令 id → 业务 id 映射
  for (const TrayMenuItem& item : menu_items_) {
    if (item.type == TrayMenuItemType::kSeparator) {
      // separator → MF_SEPARATOR（无 id / 无文本）。
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      continue;
    }
    UINT flags = MF_STRING;
    if (item.type == TrayMenuItemType::kCheckbox && item.checked) {
      // checkbox 且勾选 → MF_CHECKED。
      flags |= MF_CHECKED;
    }
    if (!item.enabled) {
      // !enabled → MF_DISABLED | MF_GRAYED。
      flags |= MF_DISABLED | MF_GRAYED;
    }
    const std::wstring label = Utf8ToWide(item.label);
    AppendMenuW(menu, flags, command_id, label.c_str());
    command_ids.push_back(item.id);
    ++command_id;
  }
  // 关键系统要求：菜单弹出前 owner 窗口须为前台，否则菜单无法正常关闭
  // （点击菜单外部时不会被系统取消）。
  SetForegroundWindow(window_);
  const UINT selected = TrackPopupMenu(
      menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY, cursor.x,
      cursor.y, 0, window_, nullptr);
  DestroyMenu(menu);
  // 菜单关闭后向窗口投递空消息，规避系统菜单的焦点残留问题（通行做法）。
  PostMessageW(window_, WM_NULL, 0, 0);
  if (selected >= kMenuCommandBase) {
    const size_t index = selected - kMenuCommandBase;
    if (index < command_ids.size() && emitter_) {
      emitter_("tray.clicked", command_ids[index]);
    }
  }
}

}  // namespace wb::platform::windows
