// shortcut_plugin.cpp — 全局快捷键：加速键字符串解析（'Ctrl+Shift+J' →
// MOD_* + VK_*）、RegisterHotKey / UnregisterHotKey / UnregisterAll、
// HWND_MESSAGE 消息窗口接收 WM_HOTKEY 并回发 'shortcut.triggered' 事件。
//
// 线程约束：全部接口必须在 UI 线程调用；热键绑定到本插件私有消息窗口，
// 插件析构时统一注销。

#include "window_plugin.h"

#include <algorithm>
#include <cctype>
#include <string>
#include <utility>

namespace wb::platform::windows {

namespace {

// 消息窗口类名（进程内唯一）。
constexpr wchar_t kShortcutWindowClass[] = L"WhiteboardWindows.Shortcut";

// 去除首尾 ASCII 空白。
std::string TrimAscii(const std::string& text) {
  size_t begin = 0;
  size_t end = text.size();
  while (begin < end &&
         std::isspace(static_cast<unsigned char>(text[begin])) != 0) {
    ++begin;
  }
  while (end > begin &&
         std::isspace(static_cast<unsigned char>(text[end - 1])) != 0) {
    --end;
  }
  return text.substr(begin, end - begin);
}

// ASCII 转小写（非 ASCII 字节原样保留，用于命名键不区分大小写比较）。
std::string ToLowerAscii(std::string text) {
  std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return text;
}

// 命名单键表（按小写比较）。
struct NamedKey {
  const char* name;
  UINT virtual_key;
};

constexpr NamedKey kNamedKeys[] = {
    {"up", VK_UP},
    {"down", VK_DOWN},
    {"left", VK_LEFT},
    {"right", VK_RIGHT},
    {"home", VK_HOME},
    {"end", VK_END},
    {"pageup", VK_PRIOR},
    {"pgup", VK_PRIOR},
    {"prior", VK_PRIOR},
    {"pagedown", VK_NEXT},
    {"pgdn", VK_NEXT},
    {"next", VK_NEXT},
    {"insert", VK_INSERT},
    {"ins", VK_INSERT},
    {"delete", VK_DELETE},
    {"del", VK_DELETE},
    {"space", VK_SPACE},
    {"spacebar", VK_SPACE},
    {"tab", VK_TAB},
    {"escape", VK_ESCAPE},
    {"esc", VK_ESCAPE},
    {"enter", VK_RETURN},
    {"return", VK_RETURN},
    {"backspace", VK_BACK},
    {"back", VK_BACK},
    {"capslock", VK_CAPITAL},
    {"numlock", VK_NUMLOCK},
    {"scrolllock", VK_SCROLL},
    {"printscreen", VK_SNAPSHOT},
    {"prtsc", VK_SNAPSHOT},
    {"pause", VK_PAUSE},
    {"menu", VK_APPS},
    {"plus", VK_OEM_PLUS},
    {"minus", VK_OEM_MINUS},
    {"comma", VK_OEM_COMMA},
    {"period", VK_OEM_PERIOD},
    {"slash", VK_OEM_2},
    {"semicolon", VK_OEM_1},
    {"quote", VK_OEM_7},
    {"backquote", VK_OEM_3},
    {"bracketleft", VK_OEM_4},
    {"bracketright", VK_OEM_6},
    {"backslash", VK_OEM_5},
};

// 解析单个主键：A-Z / 0-9 / F1-F24 / 命名键（不区分大小写）。
std::optional<UINT> ParseKeyToken(const std::string& token) {
  const std::string lower = ToLowerAscii(token);
  // 单字符主键：字母 → VK 同码值；数字 → 同码值。
  if (lower.size() == 1) {
    const char c = lower[0];
    if (c >= 'a' && c <= 'z') {
      return static_cast<UINT>('A' + (c - 'a'));
    }
    if (c >= '0' && c <= '9') {
      return static_cast<UINT>('0' + (c - '0'));
    }
    return std::nullopt;
  }
  // F1 - F24（VK_F1 起与序号连续，最多两位数字）。
  if (lower.size() >= 2 && lower.size() <= 3 && lower[0] == 'f') {
    bool all_digits = true;
    int number = 0;
    for (size_t i = 1; i < lower.size(); ++i) {
      if (lower[i] < '0' || lower[i] > '9') {
        all_digits = false;
        break;
      }
      number = number * 10 + (lower[i] - '0');
    }
    if (all_digits) {
      if (number >= 1 && number <= 24) {
        return static_cast<UINT>(VK_F1 + (number - 1));
      }
      return std::nullopt;
    }
  }
  for (const NamedKey& named : kNamedKeys) {
    if (lower == named.name) {
      return named.virtual_key;
    }
  }
  return std::nullopt;
}

}  // namespace

std::optional<Accelerator> ParseAccelerator(const std::string& accelerator,
                                            std::string* error) {
  const auto fail = [error](const std::string& message)
      -> std::optional<Accelerator> {
    if (error != nullptr) {
      *error = message;
    }
    return std::nullopt;
  };
  if (accelerator.empty()) {
    return fail("加速键为空");
  }
  // 键位表（大小写不敏感，'+' 分隔；修饰键可任意组合，主键恰一个）：
  //   修饰键：Ctrl / Control、Shift、Alt、Win / Super / Meta / Cmd /
  //           Command / Windows / ⌘（U+2318，跨端统一写法时映射 Win 键）
  //   主键： A-Z、0-9、F1-F24、方向键（Up/Down/Left/Right）、
  //           Home / End / PageUp(PgUp/Prior) / PageDown(PgDn/Next) /
  //           Insert(Ins) / Delete(Del) / Space / Tab / Escape(Esc) /
  //           Enter(Return) / Backspace(Back) / CapsLock / NumLock /
  //           ScrollLock / PrintScreen(PrtSc) / Pause / Menu 及常见
  //           符号键名（Plus/Minus/Comma/Period/Slash/Semicolon 等）
  UINT modifiers = 0;
  UINT virtual_key = 0;
  bool has_key = false;
  size_t start = 0;
  while (start <= accelerator.size()) {
    const size_t plus = accelerator.find('+', start);
    const size_t end = plus == std::string::npos ? accelerator.size() : plus;
    const std::string token = TrimAscii(accelerator.substr(start, end - start));
    if (token.empty()) {
      return fail("加速键 '" + accelerator +
                  "' 含空段（请形如 Ctrl+Shift+J）");
    }
    const std::string lower = ToLowerAscii(token);
    if (lower == "ctrl" || lower == "control") {
      modifiers |= MOD_CONTROL;
    } else if (lower == "shift") {
      modifiers |= MOD_SHIFT;
    } else if (lower == "alt") {
      modifiers |= MOD_ALT;
    } else if (lower == "win" || lower == "super" || lower == "meta" ||
               lower == "cmd" || lower == "command" || lower == "windows") {
      modifiers |= MOD_WIN;
    } else if (token == "\xE2\x8C\x98") {  // '⌘' U+2318 → Win 键
      modifiers |= MOD_WIN;
    } else {
      if (has_key) {
        return fail("加速键 '" + accelerator + "' 含多个主键");
      }
      const std::optional<UINT> key = ParseKeyToken(token);
      if (!key) {
        return fail("加速键 '" + accelerator + "' 含未知按键 '" + token +
                    "'");
      }
      virtual_key = *key;
      has_key = true;
    }
    if (plus == std::string::npos) {
      break;
    }
    start = plus + 1;
  }
  if (!has_key) {
    return fail("加速键 '" + accelerator + "' 缺少主键");
  }
  Accelerator result;
  result.modifiers = modifiers;
  result.virtual_key = virtual_key;
  return result;
}

// ===== ShortcutPlugin =====

ShortcutPlugin::ShortcutPlugin(EventEmitter emitter)
    : emitter_(std::move(emitter)) {}

ShortcutPlugin::~ShortcutPlugin() {
  UnregisterAll();
  if (window_ != nullptr) {
    DestroyWindow(window_);
    window_ = nullptr;
  }
}

bool ShortcutPlugin::EnsureWindow(std::string* error_message) {
  if (window_ != nullptr && IsWindow(window_) != FALSE) {
    return true;
  }
  const HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = &ShortcutPlugin::WindowProcThunk;
  window_class.hInstance = instance;
  window_class.lpszClassName = kShortcutWindowClass;
  // 类已注册（ERROR_CLASS_ALREADY_EXISTS）时复用既有类。
  RegisterClassW(&window_class);
  // 消息窗口（HWND_MESSAGE）：无 UI、不占任务栏，仅用于接收 WM_HOTKEY。
  window_ = CreateWindowExW(0, kShortcutWindowClass, L"", 0, 0, 0, 0, 0,
                            HWND_MESSAGE, nullptr, instance, this);
  if (window_ == nullptr) {
    if (error_message != nullptr) {
      *error_message = "创建热键消息窗口失败（错误码 " +
                       std::to_string(GetLastError()) + "）";
    }
    return false;
  }
  return true;
}

bool ShortcutPlugin::Register(const std::string& accelerator,
                              const std::string& id, std::string* error_code,
                              std::string* error_message) {
  const auto fail = [error_code, error_message](const std::string& code,
                                                const std::string& message) {
    if (error_code != nullptr) {
      *error_code = code;
    }
    if (error_message != nullptr) {
      *error_message = message;
    }
    return false;
  };
  if (id.empty()) {
    return fail("register-failed", "快捷键业务 id 不能为空");
  }
  std::string parse_error;
  const std::optional<Accelerator> parsed =
      ParseAccelerator(accelerator, &parse_error);
  if (!parsed) {
    // 契约：解析失败 → FlutterError code 'invalid-accelerator'。
    return fail("invalid-accelerator", parse_error);
  }
  if (!EnsureWindow(error_message)) {
    if (error_code != nullptr) {
      *error_code = "register-failed";
    }
    return false;
  }
  // 同一业务 id 重复注册：先注销旧绑定（更新语义，幂等）。
  Unregister(id);
  // 分配热键 id（1..0xBFFF 为应用程序预留区间）。
  int hotkey_id = 0;
  for (int candidate = next_hotkey_id_; candidate <= 0xBFFF; ++candidate) {
    if (entries_.find(candidate) == entries_.end()) {
      hotkey_id = candidate;
      break;
    }
  }
  if (hotkey_id == 0) {
    for (int candidate = 1; candidate < next_hotkey_id_; ++candidate) {
      if (entries_.find(candidate) == entries_.end()) {
        hotkey_id = candidate;
        break;
      }
    }
  }
  if (hotkey_id == 0) {
    return fail("register-failed", "热键 id 已耗尽");
  }
  next_hotkey_id_ = hotkey_id >= 0xBFFF ? 1 : hotkey_id + 1;

  // MOD_NOREPEAT：按住不放只触发一次（Windows 7+）。
  if (RegisterHotKey(window_, hotkey_id, parsed->modifiers | MOD_NOREPEAT,
                     parsed->virtual_key) == FALSE) {
    const DWORD last_error = GetLastError();
    if (last_error == ERROR_HOTKEY_ALREADY_REGISTERED) {
      return fail("register-failed",
                  "快捷键 '" + accelerator + "' 已被占用（系统或其它应用）");
    }
    return fail("register-failed",
                "RegisterHotKey 失败（错误码 " + std::to_string(last_error) +
                    "）");
  }
  Entry entry;
  entry.id = id;
  entry.accelerator = accelerator;
  entries_[hotkey_id] = std::move(entry);
  by_business_id_[id] = hotkey_id;
  return true;
}

bool ShortcutPlugin::Unregister(const std::string& id) {
  const auto it = by_business_id_.find(id);
  if (it == by_business_id_.end()) {
    return true;  // 未注册视为成功（幂等）
  }
  const int hotkey_id = it->second;
  if (window_ != nullptr) {
    UnregisterHotKey(window_, hotkey_id);
  }
  entries_.erase(hotkey_id);
  by_business_id_.erase(it);
  return true;
}

void ShortcutPlugin::UnregisterAll() {
  if (window_ != nullptr) {
    for (const auto& pair : entries_) {
      UnregisterHotKey(window_, pair.first);
    }
  }
  entries_.clear();
  by_business_id_.clear();
}

LRESULT CALLBACK ShortcutPlugin::WindowProcThunk(HWND hwnd, UINT message,
                                                 WPARAM wparam, LPARAM lparam) {
  ShortcutPlugin* self = reinterpret_cast<ShortcutPlugin*>(
      GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    self = static_cast<ShortcutPlugin*>(create->lpCreateParams);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (self != nullptr) {
    return self->HandleMessage(hwnd, message, wparam, lparam);
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT ShortcutPlugin::HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) {
  if (message == WM_HOTKEY) {
    HandleHotKey(static_cast<int>(wparam));  // wparam = 注册时的热键 id
    return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

void ShortcutPlugin::HandleHotKey(int hotkey_id) {
  const auto it = entries_.find(hotkey_id);
  if (it == entries_.end()) {
    return;
  }
  if (emitter_) {
    emitter_("shortcut.triggered", it->second.id);
  }
}

}  // namespace wb::platform::windows
