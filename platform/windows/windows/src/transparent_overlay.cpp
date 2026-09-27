// transparent_overlay.cpp — 透明批注覆盖层能力封装（《透明批注模式技术方案》
// §3 / §4 / §7.1）：透明背景、穿透↔批注态切换、覆盖层整窗形态、forward 悬停伪造。
//
// 形态说明：覆盖层直接复用 Flutter 主窗口——进入覆盖层形态时把主窗口本身
// 改造为无边框 / topmost / 虚拟屏幕全屏 / 任务栏隐藏；退出时恢复。
// （独立原生覆盖窗口无法承载 Flutter 渲染树，故采用整窗改造方案。）
//
// 透明实现：动态调用 user32!SetWindowCompositionAttribute 的强调色策略
// （ACCENT_ENABLE_TRANSPARENTGRADIENT）交由 DWM 合成。注意不能用顶层
// WS_EX_LAYERED + SetLayeredWindowAttributes 方案——分层窗口不会合成
// Flutter（ANGLE/D3D）加速子窗口的内容，表现为整窗黑屏。
//
// 线程约束：所有方法必须在 UI 线程（创建窗口的线程）调用。

#include "window_plugin.h"

namespace wb::platform::windows {

namespace {

// 按位设置 / 清除 LONG_PTR 样式位。
LONG_PTR SetStyleBit(LONG_PTR value, LONG_PTR bit, bool on) {
  return on ? (value | bit) : (value & ~bit);
}

// ---- SetWindowCompositionAttribute 动态绑定（未文档化 API）----

// WINDOWCOMPOSITIONATTRIBDATA.Attrib 取值：WCA_ACCENT_POLICY（未文档化，
// 社区约定值 19）。
constexpr DWORD kWcaAccentPolicy = 19;

// ACCENT_POLICY.AccentState 取值（未文档化枚举）。
constexpr DWORD kAccentDisabled = 0;                  // 关闭，恢复默认外观
constexpr DWORD kAccentEnableTransparentGradient = 2;  // 透明渐变（全透明）

// ACCENT_POLICY（未文档化结构；布局与 Windows 内部约定一致，勿改字段）。
struct AccentPolicy {
  DWORD accent_state;
  DWORD accent_flags;
  DWORD gradient_color;  // ARGB 颜色
  DWORD animation_id;
};

// WINDOWCOMPOSITIONATTRIBDATA（未文档化结构）。
struct WindowCompositionAttributeData {
  DWORD attribute;
  PVOID data;
  SIZE_T size_of_data;
};

using SetWindowCompositionAttributeFn =
    BOOL(WINAPI*)(HWND, WindowCompositionAttributeData*);

// 解析并缓存 user32!SetWindowCompositionAttribute；返回 nullptr 表示当前
// 系统没有该导出（调用方返回失败，由 Dart 侧决策降级）。
SetWindowCompositionAttributeFn ResolveSetWindowCompositionAttribute() {
  static const SetWindowCompositionAttributeFn fn = []() {
    const HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32 == nullptr) {
      return static_cast<SetWindowCompositionAttributeFn>(nullptr);
    }
    return reinterpret_cast<SetWindowCompositionAttributeFn>(
        GetProcAddress(user32, "SetWindowCompositionAttribute"));
  }();
  return fn;
}

}  // namespace

TransparentOverlay::TransparentOverlay(HWND hwnd) : hwnd_(hwnd) {}

bool TransparentOverlay::ApplyExtendedStyles() {
  if (hwnd_ == nullptr || IsWindow(hwnd_) == FALSE) {
    return false;
  }
  // WS_EX_TRANSPARENT：命中测试跳过本窗口，鼠标事件送达下层窗口（穿透态）。
  // 注意：透明背景不再依赖 WS_EX_LAYERED（见 SetTransparent）。
  LONG_PTR ex_style = GetWindowLongPtrW(hwnd_, GWL_EXSTYLE);
  ex_style = SetStyleBit(ex_style, WS_EX_TRANSPARENT, penetrate_);
  SetWindowLongPtrW(hwnd_, GWL_EXSTYLE, ex_style);
  return true;
}

bool TransparentOverlay::SetTransparent(bool transparent) {
  if (hwnd_ == nullptr || IsWindow(hwnd_) == FALSE) {
    return false;
  }
  transparent_ = transparent;
  if (!ApplyExtendedStyles()) {
    return false;
  }
  // 动态解析 API：缺失（极旧系统 / 受限环境）时不视为设置成功。
  const SetWindowCompositionAttributeFn set_composition =
      ResolveSetWindowCompositionAttribute();
  if (set_composition == nullptr) {
    return false;
  }
  AccentPolicy accent = {};
  if (transparent) {
    // 透明渐变强调策略 + 全透明渐变色：DWM 按窗口表面自身 alpha 合成，
    // Flutter 透明区域透出桌面（替代分层窗口 + SetLayeredWindowAttributes）。
    accent.accent_state = kAccentEnableTransparentGradient;
    accent.accent_flags = 2;
    accent.gradient_color = 0x00000000;  // ARGB 全透明
    accent.animation_id = 0;
  } else {
    // 关闭强调策略：恢复系统默认合成，其余字段保持 0。
    accent.accent_state = kAccentDisabled;
  }
  WindowCompositionAttributeData data = {};
  data.attribute = kWcaAccentPolicy;
  data.data = &accent;
  data.size_of_data = sizeof(accent);
  // 调用失败同样返回 false：由 Dart 侧决定是否降级到截图背景。
  return set_composition(hwnd_, &data) != FALSE;
}

bool TransparentOverlay::SetPenetrate(bool penetrate, bool forward) {
  if (hwnd_ == nullptr || IsWindow(hwnd_) == FALSE) {
    return false;
  }
  penetrate_ = penetrate;
  forward_ = penetrate && forward;  // forward 仅在穿透态有意义
  if (!forward_) {
    last_forward_pt_ = POINT{LONG_MIN, LONG_MIN};
    forward_cursor_inside_ = false;
  }
  return ApplyExtendedStyles();
}

bool TransparentOverlay::Enter() {
  if (hwnd_ == nullptr || IsWindow(hwnd_) == FALSE) {
    return false;
  }
  if (entered_) {
    return true;
  }
  // 保存进入前状态，Exit() 恢复。
  saved_style_ = GetWindowLongPtrW(hwnd_, GWL_STYLE);
  saved_ex_style_ = GetWindowLongPtrW(hwnd_, GWL_EXSTYLE);
  saved_rect_ = RECT{};
  GetWindowRect(hwnd_, &saved_rect_);

  // 覆盖层形态（技术方案 §3.2）：无边框 + 工具窗口（隐藏任务栏项）。
  const LONG_PTR borderless =
      saved_style_ & ~static_cast<LONG_PTR>(WS_CAPTION | WS_THICKFRAME |
                                            WS_MINIMIZEBOX | WS_MAXIMIZEBOX |
                                            WS_SYSMENU);
  SetWindowLongPtrW(hwnd_, GWL_STYLE, borderless);
  const LONG_PTR ex_style = GetWindowLongPtrW(hwnd_, GWL_EXSTYLE);
  SetWindowLongPtrW(hwnd_, GWL_EXSTYLE, ex_style | WS_EX_TOOLWINDOW);

  // 覆盖虚拟屏幕（技术方案 §7.1 多显示器：SM_XVIRTUALSCREEN 等）。
  const int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (SetWindowPos(hwnd_, HWND_TOPMOST, x, y, width, height,
                   SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_SHOWWINDOW) ==
      FALSE) {
    return false;
  }
  entered_ = true;
  return true;
}

bool TransparentOverlay::Exit() {
  if (hwnd_ == nullptr || IsWindow(hwnd_) == FALSE) {
    return false;
  }
  if (!entered_) {
    return true;
  }
  SetWindowLongPtrW(hwnd_, GWL_STYLE, saved_style_);
  SetWindowLongPtrW(hwnd_, GWL_EXSTYLE, saved_ex_style_);
  const bool has_saved_rect = saved_rect_.right > saved_rect_.left &&
                              saved_rect_.bottom > saved_rect_.top;
  if (has_saved_rect) {
    // 退出后置为非 topmost；调用方如需保持置顶，请在退出后调用
    // window.setAlwaysOnTop(true)。
    SetWindowPos(hwnd_, HWND_NOTOPMOST, saved_rect_.left, saved_rect_.top,
                 saved_rect_.right - saved_rect_.left,
                 saved_rect_.bottom - saved_rect_.top,
                 SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  } else {
    SetWindowPos(hwnd_, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_NOACTIVATE);
  }
  entered_ = false;
  // 恢复的样式早于最近的透明 / 穿透设置，重新应用当前逻辑状态。
  ApplyExtendedStyles();
  return true;
}

void TransparentOverlay::OnForwardTick() {
  if (!forward_ || hwnd_ == nullptr || IsWindow(hwnd_) == FALSE) {
    return;
  }
  POINT cursor = {};
  if (GetCursorPos(&cursor) == FALSE) {
    return;
  }
  RECT bounds = {};
  if (GetWindowRect(hwnd_, &bounds) == FALSE) {
    return;
  }
  const bool inside = cursor.x >= bounds.left && cursor.x < bounds.right &&
                      cursor.y >= bounds.top && cursor.y < bounds.bottom;
  if (inside) {
    const bool moved =
        cursor.x != last_forward_pt_.x || cursor.y != last_forward_pt_.y;
    if (moved || !forward_cursor_inside_) {
      // 伪造悬停移动：PostMessage 直接投递，绕过穿透窗口的命中测试。
      POINT client = cursor;
      ScreenToClient(hwnd_, &client);
      PostMessageW(hwnd_, WM_MOUSEMOVE, 0,
                   MAKELPARAM(static_cast<WORD>(client.x),
                              static_cast<WORD>(client.y)));
      last_forward_pt_ = cursor;
      forward_cursor_inside_ = true;
    }
  } else if (forward_cursor_inside_) {
    // 光标移出窗口：伪发离开消息，让 Flutter 结束 hover 状态。
    PostMessageW(hwnd_, WM_MOUSELEAVE, 0, 0);
    last_forward_pt_ = POINT{LONG_MIN, LONG_MIN};
    forward_cursor_inside_ = false;
  }
}

}  // namespace wb::platform::windows
