// whiteboard_linux 插件 · 全局快捷键实现（X11 XGrabKey + worker 线程）。
//
// 覆盖《透明批注模式技术方案》§7.3 的全局快捷键通路：
//   * X11 / XWayland：XGrabKey 抓取（同一组合的 Lock / Mod2 共 4 个变体，
//     覆盖 CapsLock / NumLock 状态），专属 worker 线程持有独立 X11 连接
//     读取 KeyPress 并经回调投递；
//   * Wayland 原生会话无全局快捷键协议：注册返回 WB_ERR_UNSUPPORTED
//     （应用侧按设计降级为应用内快捷键）；注销返回 WB_OK（幂等清理）；
//   * 无 X11 构建（WB_LINUX_HAVE_X11 未定义）：注册返回 UNSUPPORTED，
//     注销返回 OK，回调注册为 no-op。
//
// 加速键解析与 Dart 侧 WbAccelerator 归一规则完全一致（大小写不敏感
// 别名：Ctrl / Control、Shift、Alt / Option / Opt、Cmd / Command /
// Super / Win / Meta / ⌘；主键 A-Z、0-9、F1-F24、命名键 Space / Tab /
// Escape / Return / Backspace / Delete / Insert / Home / End / PageUp /
// PageDown / 方向键及其小写别名），解析失败返回 WB_ERR_FAILED。
//
// 线程模型（关键设计）：
//   * ShortcutEngine 为进程单例（function-local static；进程退出时停止
//     worker 并 join）；
//   * worker 线程：XOpenDisplay 专属连接 → 命令队列处理（Grab / Ungrab，
//     经 X11ErrorTrap 隔离 BadAccess 等错误）→ poll（X fd + 自唤醒 pipe）
//     读取 KeyPress → 匹配注册表 → 回调；
//   * 公开 API（register / unregister / unregisterAll）提交命令并限时
//     等待 worker 应答（1500ms 上限，绝不挂起调用方）；命令状态经
//     shared_ptr 持有，超时后迟到完成亦安全（无 use-after-free）；
//   * set_callback 不经队列：加锁直接更新回调槽——worker 在持锁状态下
//     调用回调，两者严格串行，保证 set_callback(NULL) 返回后不再有任何
//     在途回调（与 Dart dispose 顺序契约一致）。回调实现（Dart
//     NativeCallable.listener）异步投递、不得同步重入本插件 API；
//   * 命令提交经自唤醒 pipe 即时通知 worker；pipe 创建失败时退化为
//     100ms poll 节拍（功能不受影响）。
//
// 依赖策略：全部 libX11 符号经 dlopen/dlsym（无链接期依赖，代码防御空
// 指针）；X 错误经分流处理器隔离，任何异步错误都不会终止宿主进程。

#include "window_plugin.h"

#if defined(WB_LINUX_HAVE_X11)

#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace wb::platform::linux_ {

namespace {

// ===== 通用常量 =====

// X11 修饰键掩码（X.h 协议值；常量内联避免额外头文件依赖）。
constexpr unsigned int kShiftMask = 1u << 0;    // ShiftMask
constexpr unsigned int kLockMask = 1u << 1;     // LockMask（CapsLock 位）
constexpr unsigned int kControlMask = 1u << 2;  // ControlMask
constexpr unsigned int kMod1Mask = 1u << 3;     // Mod1Mask（传统 Alt）
constexpr unsigned int kMod2Mask = 1u << 4;     // Mod2Mask（NumLock 位）
constexpr unsigned int kMod4Mask = 1u << 6;     // Mod4Mask（传统 Super）

// GrabModeAsync（X.h）。
constexpr int kGrabModeAsync = 1;

// 命令应答等待上限（毫秒）：超时返回 WB_ERR_FAILED（不挂起调用方）。
constexpr int kCommandWaitMs = 1500;

// worker 空闲 poll 节拍（毫秒）；自唤醒 pipe 可用时仅作兜底（检查停止位）。
constexpr int kPollTimeoutMs = 100;

// ===== 字符串工具（镜像 Dart WbAccelerator 归一规则）=====

bool IsAsciiSpace(char c) {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' ||
         c == '\v';
}

char LowerAscii(char c) {
  return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
}

char UpperAscii(char c) {
  return (c >= 'a' && c <= 'z') ? static_cast<char>(c - 'a' + 'A') : c;
}

std::string LowerCopy(const std::string& text) {
  std::string out = text;
  for (char& c : out) {
    c = LowerAscii(c);
  }
  return out;
}

// 以 separator 切分并按 ASCII 空白 trim 每个 token（镜像 Dart
// split('+') + 逐段 trim；空 token 保留，由调用方触发失败判定）。
std::vector<std::string> SplitAndTrim(const std::string& text, char separator) {
  std::vector<std::string> tokens;
  std::string current;
  for (size_t i = 0; i <= text.size(); ++i) {
    if (i == text.size() || text[i] == separator) {
      size_t begin = 0;
      size_t end = current.size();
      while (begin < end && IsAsciiSpace(current[begin])) {
        ++begin;
      }
      while (end > begin && IsAsciiSpace(current[end - 1])) {
        --end;
      }
      tokens.push_back(current.substr(begin, end - begin));
      current.clear();
    } else {
      current.push_back(text[i]);
    }
  }
  return tokens;
}

// 规范主键名（镜像 Dart _normalizeKey）：A-Z / 0-9 / F1-F24 / 命名键及
// 小写别名。返回空串表示非法键名（与 Dart 返回 null 对应）。
std::string NormalizeKeyName(const std::string& token) {
  if (token.size() == 1) {
    const char upper = UpperAscii(token[0]);
    const bool is_letter = upper >= 'A' && upper <= 'Z';
    const bool is_digit = upper >= '0' && upper <= '9';
    if (is_letter || is_digit) {
      return std::string(1, upper);
    }
    return std::string();
  }
  if (token.size() >= 2 && token.size() <= 3 && UpperAscii(token[0]) == 'F') {
    int value = 0;
    bool digits_ok = true;
    for (size_t i = 1; i < token.size(); ++i) {
      if (token[i] < '0' || token[i] > '9') {
        digits_ok = false;
        break;
      }
      value = value * 10 + (token[i] - '0');
    }
    if (digits_ok && value >= 1 && value <= 24) {
      char buffer[8];
      std::snprintf(buffer, sizeof(buffer), "F%d", value);
      return std::string(buffer);
    }
  }
  static const std::pair<const char*, const char*> kNamedKeys[] = {
      {"space", "Space"},
      {"tab", "Tab"},
      {"escape", "Escape"},
      {"esc", "Escape"},
      {"enter", "Return"},
      {"return", "Return"},
      {"backspace", "Backspace"},
      {"delete", "Delete"},
      {"del", "Delete"},
      {"insert", "Insert"},
      {"ins", "Insert"},
      {"home", "Home"},
      {"end", "End"},
      {"pageup", "PageUp"},
      {"page_up", "PageUp"},
      {"pgup", "PageUp"},
      {"pagedown", "PageDown"},
      {"page_down", "PageDown"},
      {"pgdn", "PageDown"},
      {"left", "Left"},
      {"arrowleft", "Left"},
      {"right", "Right"},
      {"arrowright", "Right"},
      {"up", "Up"},
      {"arrowup", "Up"},
      {"down", "Down"},
      {"arrowdown", "Down"},
  };
  const std::string lower = LowerCopy(token);
  for (const auto& [alias, canonical] : kNamedKeys) {
    if (lower == alias) {
      return canonical;
    }
  }
  return std::string();
}

// ===== 加速键解析（镜像 Dart WbAccelerator.parse）=====

// ⌘（U+2318 的 UTF-8 编码；该字符无大小写，直接字节比较）。
constexpr char kCommandSign[] = "\xE2\x8C\x98";

struct ParsedAccelerator {
  bool ok = false;
  unsigned int modifiers = 0;  // kControlMask | kShiftMask | kMod1Mask | kMod4Mask
  std::string key_name;        // 规范主键名（如 "J" / "F1" / "Space"）
};

// 解析加速键；语法非法时 ok = false（不抛异常）。
ParsedAccelerator ParseAccelerator(const char* text) {
  ParsedAccelerator result;
  if (text == nullptr) {
    return result;
  }
  const std::vector<std::string> tokens = SplitAndTrim(text, '+');
  if (tokens.empty()) {
    return result;
  }
  bool ctrl = false;
  bool shift = false;
  bool alt = false;
  bool super = false;
  std::string key;
  for (const std::string& token : tokens) {
    if (token.empty()) {
      return result;  // 空段（如 "Ctrl++A" / 结尾加号）：失败
    }
    const std::string lower = LowerCopy(token);
    if (lower == "ctrl" || lower == "control") {
      if (ctrl) {
        return result;  // 重复修饰键：失败
      }
      ctrl = true;
    } else if (lower == "shift") {
      if (shift) {
        return result;
      }
      shift = true;
    } else if (lower == "alt" || lower == "option" || lower == "opt") {
      if (alt) {
        return result;
      }
      alt = true;
    } else if (lower == "cmd" || lower == "command" || lower == "super" ||
               lower == "win" || lower == "meta" || lower == kCommandSign) {
      if (super) {
        return result;
      }
      super = true;
    } else {
      if (!key.empty()) {
        return result;  // 多个主键：失败
      }
      const std::string normalized = NormalizeKeyName(token);
      if (normalized.empty()) {
        return result;  // 未知键名：失败
      }
      key = normalized;
    }
  }
  if (key.empty()) {
    return result;  // 缺主键：失败
  }
  result.ok = true;
  if (ctrl) {
    result.modifiers |= kControlMask;
  }
  if (shift) {
    result.modifiers |= kShiftMask;
  }
  if (alt) {
    result.modifiers |= kMod1Mask;
  }
  if (super) {
    result.modifiers |= kMod4Mask;
  }
  result.key_name = key;
  return result;
}

// ===== keysym / keycode 查找（worker 线程内，需有效 display）=====

// 规范名 → X keysym 名（与 Dart 侧注释一致：Space → "space"、
// Backspace → "BackSpace"、PageUp → "Prior"、PageDown → "Next"、
// 字母 → 小写，其余同名）。
std::string KeysymNameOf(const std::string& canonical) {
  if (canonical == "Space") {
    return "space";
  }
  if (canonical == "Backspace") {
    return "BackSpace";
  }
  if (canonical == "PageUp") {
    return "Prior";
  }
  if (canonical == "PageDown") {
    return "Next";
  }
  if (canonical.size() == 1 && canonical[0] >= 'A' && canonical[0] <= 'Z') {
    return std::string(1, LowerAscii(canonical[0]));
  }
  return canonical;
}

// 规范名 → 物理键 keycode；查无返回 0（该键不在当前键盘映射中）。
// 字母先按小写 keysym（键位 level 0）查找，失败再试大写名兜底。
KeyCode LookupKeycode(Display* display, const std::string& canonical) {
  X11Api& api = X11Api::Get();
  if (!api.core) {
    return 0;
  }
  const std::string primary = KeysymNameOf(canonical);
  KeySym keysym = api.StringToKeysym(primary.c_str());
  if (keysym != 0) {
    const KeyCode code = api.KeysymToKeycode(display, keysym);
    if (code != 0) {
      return code;
    }
  }
  if (primary != canonical) {
    keysym = api.StringToKeysym(canonical.c_str());
    if (keysym != 0) {
      return api.KeysymToKeycode(display, keysym);
    }
  }
  return 0;
}

// ===== 快捷键引擎（worker 线程 + 命令队列）=====

class ShortcutEngine {
 public:
  // 进程单例（懒启动：首个命令提交时创建 worker；进程退出时停止并 join）。
  static ShortcutEngine& Get();

  ShortcutEngine(const ShortcutEngine&) = delete;
  ShortcutEngine& operator=(const ShortcutEngine&) = delete;

  // 公开 API。Worker 未就绪 / 已终止时的语义见各实现。
  int Register(const std::string& accelerator, const std::string& id);
  int Unregister(const std::string& id);
  int UnregisterAll();
  void SetCallback(WbLinuxStrCallback callback);

 private:
  ShortcutEngine();
  ~ShortcutEngine();

  // worker 命令（register / unregister / unregisterAll 经此串行执行）。
  struct Command {
    enum class Kind { kRegister, kUnregister, kUnregisterAll };

    Kind kind = Kind::kRegister;
    std::string accelerator;
    std::string id;
    int result = WB_ERR_FAILED;
    bool done = false;
    std::mutex mutex;
    std::condition_variable cv;
  };

  struct Registration {
    // 回调 id 的持久副本（堆分配）：保证「已投递但 Dart 尚未读取」
    // 的回调指针在注销后依然有效（见实现处退役池说明）。
    std::shared_ptr<const std::string> id;
    unsigned int modifiers = 0;  // 不含 Lock / Mod2 变体
    KeyCode keycode = 0;
  };

  // ---- worker 生命周期 ----
  void WorkerMain();
  void Stop();
  int Submit(const std::shared_ptr<Command>& command);
  void WakeWorker();

  // ---- 命令与事件（仅 worker 线程）----
  void ProcessCommands(Display* display);
  int ExecuteCommand(Display* display, Command& command);
  void WaitAndHandleEvents(Display* display);
  void HandleKeyPress(const XKeyEvent& event);
  void UngrabVariants(Display* display, const Registration& registration);
  void UngrabAll(Display* display);

  // ---- 共享状态（mutex_ 保护）----
  std::mutex mutex_;
  std::deque<std::shared_ptr<Command>> queue_;
  bool stop_ = false;   // 析构请求停止
  bool dead_ = false;   // worker 不再接受命令（终态：启动失败 / 已退出）
  bool alive_ = false;  // worker 已就绪（display 打开成功）
  WbLinuxStrCallback callback_ = nullptr;

  std::thread worker_;
  int wake_read_ = -1;   // 自唤醒 pipe 读端（-1 = 不可用）
  int wake_write_ = -1;  // 自唤醒 pipe 写端

  // ---- 仅 worker 线程访问 ----
  std::map<std::string, Registration> registrations_;
  // 已注销 id 的「退役池」：回调经 NativeCallable.listener 异步投递给
  // Dart，字符串须存活至 Dart 实际读取（可能晚于注销）；超上限时
  // FIFO 淘汰（见实现处说明）。
  std::deque<std::shared_ptr<const std::string>> retired_ids_;
  Window root_ = None;
};

}  // namespace

// ===== 实现：四变体抓取辅助与退役池常量 =====

namespace {

// 退役池容量上限（FIFO 淘汰最老条目）：仅在「Dart 侧极端积压未读取的
// 回调消息 + 高频注销」的不可达场景下触发，防御性封顶内存占用。
constexpr size_t kRetiredIdLimit = 512;

// 对 (keycode, modifiers) 抓取 {无, Lock, Mod2, Lock|Mod2} 四变体（覆盖
// CapsLock / NumLock 状态）；任一变体被拒（BadAccess）时回滚已抓变体。
bool GrabWithVariants(Display* display, Window root, KeyCode keycode,
                      unsigned int modifiers) {
  X11Api& api = X11Api::Get();
  const unsigned int variants[4] = {0u, kLockMask, kMod2Mask,
                                    kLockMask | kMod2Mask};
  for (int i = 0; i < 4; ++i) {
    X11ErrorTrap trap(display);
    api.GrabKey(display, static_cast<int>(keycode), modifiers | variants[i],
                root, False, kGrabModeAsync, kGrabModeAsync);
    if (trap.FinishAndCheck()) {
      // 回滚已抓变体（尽力而为）。
      for (int j = 0; j < i; ++j) {
        X11ErrorTrap rollback(display);
        api.UngrabKey(display, static_cast<int>(keycode),
                      modifiers | variants[j], root);
        (void)rollback.FinishAndCheck();
      }
      return false;
    }
  }
  return true;
}

}  // namespace

// ===== ShortcutEngine：生命周期 =====

ShortcutEngine& ShortcutEngine::Get() {
  // function-local static：进程单例；进程退出时析构 → Stop() 停止并
  // join worker。X11Api 为另一翻译单元的同型单例（POD，析构无操作），
  // 函数指针在整个退出序列内保持有效，无跨翻译单元析构顺序问题。
  static ShortcutEngine engine;
  return engine;
}

ShortcutEngine::ShortcutEngine() = default;

ShortcutEngine::~ShortcutEngine() { Stop(); }

void ShortcutEngine::Stop() {
  std::thread worker;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!worker_.joinable()) {
      return;  // 从未启动（懒启动设计）：无事可做。
    }
    stop_ = true;
    dead_ = true;
    // 残留命令不再执行：全部标记失败并唤醒等待者。
    for (auto& command : queue_) {
      std::lock_guard<std::mutex> command_lock(command->mutex);
      command->result = WB_ERR_FAILED;
      command->done = true;
      command->cv.notify_all();
    }
    queue_.clear();
    worker = std::move(worker_);
  }
  WakeWorker();
  worker.join();
  // worker 已退出：关闭自唤醒 pipe（此后无并发写入者）。
  std::lock_guard<std::mutex> lock(mutex_);
  if (wake_read_ >= 0) {
    close(wake_read_);
    wake_read_ = -1;
  }
  if (wake_write_ >= 0) {
    close(wake_write_);
    wake_write_ = -1;
  }
}

int ShortcutEngine::Submit(const std::shared_ptr<Command>& command) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (dead_) {
      return WB_ERR_FAILED;
    }
    queue_.push_back(command);
    if (!worker_.joinable()) {
      // 懒启动：首个命令时创建自唤醒 pipe 并启动 worker（set_callback
      // 与无 X11 会话的清理路径不创建线程）。
      int wake_pipe[2] = {-1, -1};
      if (pipe(wake_pipe) == 0) {
        wake_read_ = wake_pipe[0];
        wake_write_ = wake_pipe[1];
        // 读端非阻塞（清空不阻塞）；写端非阻塞（唤醒信号可丢弃）。
        const int read_flags = fcntl(wake_read_, F_GETFL, 0);
        if (read_flags >= 0) {
          (void)fcntl(wake_read_, F_SETFL, read_flags | O_NONBLOCK);
        }
        const int write_flags = fcntl(wake_write_, F_GETFL, 0);
        if (write_flags >= 0) {
          (void)fcntl(wake_write_, F_SETFL, write_flags | O_NONBLOCK);
        }
      }
      bool thread_started = true;
#if defined(__cpp_exceptions)
      try {
        worker_ = std::thread(&ShortcutEngine::WorkerMain, this);
      } catch (...) {
        thread_started = false;
      }
#else
      worker_ = std::thread(&ShortcutEngine::WorkerMain, this);
#endif
      if (!thread_started) {
        queue_.pop_back();
        if (wake_read_ >= 0) {
          close(wake_read_);
          wake_read_ = -1;
        }
        if (wake_write_ >= 0) {
          close(wake_write_);
          wake_write_ = -1;
        }
        return WB_ERR_FAILED;
      }
    }
  }
  WakeWorker();
  std::unique_lock<std::mutex> lock(command->mutex);
  const bool finished = command->cv.wait_for(
      lock, std::chrono::milliseconds(kCommandWaitMs),
      [&command] { return command->done; });
  if (finished) {
    return command->result;
  }
  // 等待超时（X 服务器失去响应等）：尽力从队列撤回命令；worker 已取
  // 走的命令无法撤回（迟到执行，结果不再回传，由调用方按失败处理）。
  {
    std::lock_guard<std::mutex> queue_lock(mutex_);
    for (auto it = queue_.begin(); it != queue_.end(); ++it) {
      if (it->get() == command.get()) {
        queue_.erase(it);
        break;
      }
    }
  }
  return WB_ERR_FAILED;
}

void ShortcutEngine::WakeWorker() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (wake_write_ < 0) {
    return;  // pipe 不可用：退化为 100ms poll 节拍（功能不受影响）。
  }
  const char byte = 0;
  const ssize_t written = write(wake_write_, &byte, 1);
  (void)written;
}

// ===== ShortcutEngine：worker 主循环 =====

void ShortcutEngine::WorkerMain() {
  X11Api& api = X11Api::Get();
  Display* display = nullptr;
  if (api.core) {
    display = api.OpenDisplay(nullptr);
  }
  if (display == nullptr) {
    // 无可用 X11（库缺失 / XOpenDisplay 失败）：worker 进入终态。
    std::lock_guard<std::mutex> lock(mutex_);
    dead_ = true;
    for (auto& command : queue_) {
      std::lock_guard<std::mutex> command_lock(command->mutex);
      command->result = WB_ERR_FAILED;
      command->done = true;
      command->cv.notify_all();
    }
    queue_.clear();
    return;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    alive_ = true;
    root_ = api.DefaultRootWindow(display);
  }
  while (true) {
#if defined(__cpp_exceptions)
    try {
#endif
      ProcessCommands(display);
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stop_) {
          break;
        }
      }
      WaitAndHandleEvents(display);
#if defined(__cpp_exceptions)
    } catch (...) {
      // 防御：worker 内任何异常都不得逃逸线程（std::terminate）。
      break;
    }
#endif
  }
  // 退出清理：连接关闭前主动 ungrab（连接断开场景下请求安全失败）。
  UngrabAll(display);
  (void)api.CloseDisplay(display);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    alive_ = false;
    dead_ = true;
  }
}

void ShortcutEngine::ProcessCommands(Display* display) {
  while (true) {
    std::shared_ptr<Command> command;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stop_ || queue_.empty()) {
        return;
      }
      command = queue_.front();
      queue_.pop_front();
    }
    const int result = ExecuteCommand(display, *command);
    {
      std::lock_guard<std::mutex> lock(command->mutex);
      command->result = result;
      command->done = true;
    }
    command->cv.notify_all();
  }
}

int ShortcutEngine::ExecuteCommand(Display* display, Command& command) {
  // 注销的 id 移入退役池（不销毁）：回调经 NativeCallable.listener
  // 异步投递给 Dart，指针可能晚于注销才被读取，须保持有效。
  auto retire = [this](std::shared_ptr<const std::string>&& id) {
    if (id == nullptr) {
      return;
    }
    retired_ids_.push_back(std::move(id));
    while (retired_ids_.size() > kRetiredIdLimit) {
      retired_ids_.pop_front();
    }
  };

  switch (command.kind) {
    case Command::Kind::kRegister: {
      const ParsedAccelerator parsed =
          ParseAccelerator(command.accelerator.c_str());
      if (!parsed.ok) {
        return WB_ERR_FAILED;
      }
      const KeyCode keycode = LookupKeycode(display, parsed.key_name);
      if (keycode == 0) {
        return WB_ERR_FAILED;
      }
      // 组合占用检查：同一组合只允许一个 id（排除自身；同 id = 替换）。
      for (const auto& entry : registrations_) {
        if (entry.first == command.id) {
          continue;
        }
        if (entry.second.keycode == keycode &&
            entry.second.modifiers == parsed.modifiers) {
          return WB_ERR_FAILED;
        }
      }
      // 替换语义：先撤销同 id 的旧抓取（旧 id 退役供在途回调使用）。
      const auto existing = registrations_.find(command.id);
      if (existing != registrations_.end()) {
        UngrabVariants(display, existing->second);
        retire(std::move(existing->second.id));
        registrations_.erase(existing);
      }
      if (!GrabWithVariants(display, root_, keycode, parsed.modifiers)) {
        return WB_ERR_FAILED;
      }
      Registration registration;
      registration.id = std::make_shared<const std::string>(command.id);
      registration.modifiers = parsed.modifiers;
      registration.keycode = keycode;
      registrations_[command.id] = std::move(registration);
      return WB_OK;
    }
    case Command::Kind::kUnregister: {
      const auto existing = registrations_.find(command.id);
      if (existing == registrations_.end()) {
        return WB_OK;  // 未注册视为成功（幂等）。
      }
      UngrabVariants(display, existing->second);
      retire(std::move(existing->second.id));
      registrations_.erase(existing);
      return WB_OK;
    }
    case Command::Kind::kUnregisterAll: {
      for (auto& entry : registrations_) {
        UngrabVariants(display, entry.second);
        retire(std::move(entry.second.id));
      }
      registrations_.clear();
      return WB_OK;
    }
  }
  return WB_ERR_FAILED;
}

void ShortcutEngine::WaitAndHandleEvents(Display* display) {
  X11Api& api = X11Api::Get();
  pollfd descriptors[2] = {};
  int descriptor_count = 0;
  int x_index = -1;
  int wake_index = -1;
  const int x_fd = api.ConnectionNumber(display);
  if (x_fd >= 0) {
    descriptors[descriptor_count].fd = x_fd;
    descriptors[descriptor_count].events = POLLIN;
    x_index = descriptor_count;
    ++descriptor_count;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (wake_read_ >= 0) {
      descriptors[descriptor_count].fd = wake_read_;
      descriptors[descriptor_count].events = POLLIN;
      wake_index = descriptor_count;
      ++descriptor_count;
    }
  }
  if (descriptor_count == 0) {
    // 理论上不可达（活动 X 连接必有 fd）：退化为节拍休眠。
    std::this_thread::sleep_for(std::chrono::milliseconds(kPollTimeoutMs));
    return;
  }
  const int ready = poll(descriptors, static_cast<nfds_t>(descriptor_count),
                         kPollTimeoutMs);
  if (ready <= 0) {
    return;  // 超时或 EINTR：回到主循环检查停止位。
  }
  if (wake_index >= 0 && (descriptors[wake_index].revents & POLLIN) != 0) {
    // 清空唤醒字节（非阻塞读；读空即 EAGAIN，退出循环）。
    char buffer[64];
    while (read(wake_read_, buffer, sizeof(buffer)) > 0) {
    }
  }
  if (x_index < 0) {
    return;
  }
  const short x_revents = descriptors[x_index].revents;
  if ((x_revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
    // X 连接断开（服务器消失 / XWayland 退出）：无法恢复。置停止位，
    // 由主循环走统一退出路径；连接上的后续请求由 I/O 错误处理器防御。
    std::lock_guard<std::mutex> lock(mutex_);
    stop_ = true;
    return;
  }
  if ((x_revents & POLLIN) != 0) {
    while (api.Pending(display) > 0) {
      XEvent event{};
      api.NextEvent(display, &event);
      if (event.type == KeyPress) {
        HandleKeyPress(event.xkey);
      }
    }
  }
}

void ShortcutEngine::HandleKeyPress(const XKeyEvent& event) {
  const unsigned int clean_state = event.state & ~(kLockMask | kMod2Mask);
  const Registration* hit = nullptr;
  for (const auto& entry : registrations_) {
    const Registration& registration = entry.second;
    if (registration.keycode == event.keycode &&
        registration.modifiers == clean_state) {
      hit = &registration;
      break;
    }
  }
  if (hit == nullptr) {
    return;
  }
  // 持锁调用回调，与 set_callback 严格串行：保证 set_callback(NULL)
  // 返回后不再有任何在途回调（Dart dispose 顺序契约）。回调实现
  // （Dart NativeCallable.listener）异步投递并立即返回，不得同步重入。
  std::lock_guard<std::mutex> lock(mutex_);
  if (callback_ != nullptr && hit->id != nullptr) {
    callback_(hit->id->c_str());
  }
}

void ShortcutEngine::UngrabVariants(Display* display,
                                    const Registration& registration) {
  X11Api& api = X11Api::Get();
  const unsigned int variants[4] = {0u, kLockMask, kMod2Mask,
                                    kLockMask | kMod2Mask};
  for (const unsigned int variant : variants) {
    X11ErrorTrap trap(display);
    api.UngrabKey(display, static_cast<int>(registration.keycode),
                  registration.modifiers | variant, root_);
    (void)trap.FinishAndCheck();
  }
}

void ShortcutEngine::UngrabAll(Display* display) {
  // 仅撤销抓取、不清空注册表：worker 退出路径上可能有「已投递但
  // Dart 未读取」的回调指针仍指向表中字符串，保持其存活（进程退出
  // 后随地址空间一并回收）。
  for (const auto& entry : registrations_) {
    UngrabVariants(display, entry.second);
  }
}

// ===== ShortcutEngine：公开 API =====

int ShortcutEngine::Register(const std::string& accelerator,
                             const std::string& id) {
  auto command = std::make_shared<Command>();
  command->kind = Command::Kind::kRegister;
  command->accelerator = accelerator;
  command->id = id;
  return Submit(command);
}

int ShortcutEngine::Unregister(const std::string& id) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!worker_.joinable() || dead_) {
      return WB_OK;  // 从未启动 / 已终止：注册表为空，幂等成功。
    }
  }
  auto command = std::make_shared<Command>();
  command->kind = Command::Kind::kUnregister;
  command->id = id;
  return Submit(command);
}

int ShortcutEngine::UnregisterAll() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!worker_.joinable() || dead_) {
      return WB_OK;
    }
  }
  auto command = std::make_shared<Command>();
  command->kind = Command::Kind::kUnregisterAll;
  return Submit(command);
}

void ShortcutEngine::SetCallback(WbLinuxStrCallback callback) {
  std::lock_guard<std::mutex> lock(mutex_);
  callback_ = callback;
}

// ===== 对外 ABI：4 个快捷键符号 =====

extern "C" WB_LINUX_API int wb_linux_shortcut_register(const char* accelerator,
                                                       const char* id) {
  WB_LINUX_TRY {
    if (accelerator == nullptr || id == nullptr) {
      return WB_ERR_FAILED;
    }
    switch (ResolveSessionBackend()) {
      case SessionBackend::kX11:
        return ShortcutEngine::Get().Register(accelerator, id);
      case SessionBackend::kWayland:
        // Wayland 原生会话无全局快捷键协议（应用内快捷键降级）。
        return WB_ERR_UNSUPPORTED;
      case SessionBackend::kNone:
        break;
    }
  }
  WB_LINUX_CATCH(WB_ERR_FAILED)
  return WB_ERR_FAILED;
}

extern "C" WB_LINUX_API int wb_linux_shortcut_unregister(const char* id) {
  WB_LINUX_TRY {
    if (id == nullptr) {
      return WB_OK;
    }
    switch (ResolveSessionBackend()) {
      case SessionBackend::kX11:
        return ShortcutEngine::Get().Unregister(id);
      case SessionBackend::kWayland:
      case SessionBackend::kNone:
        break;  // 无注册表：幂等成功（cleanup 路径必须可用）。
    }
  }
  WB_LINUX_CATCH(WB_OK)
  return WB_OK;
}

extern "C" WB_LINUX_API int wb_linux_shortcut_unregister_all(void) {
  WB_LINUX_TRY {
    switch (ResolveSessionBackend()) {
      case SessionBackend::kX11:
        return ShortcutEngine::Get().UnregisterAll();
      case SessionBackend::kWayland:
      case SessionBackend::kNone:
        break;
    }
  }
  WB_LINUX_CATCH(WB_OK)
  return WB_OK;
}

extern "C" WB_LINUX_API void wb_linux_shortcut_set_callback(
    WbLinuxStrCallback callback) {
  // 回调槽的更新 / 清理路径（Dart dispose）必须始终可用：不判定后端，
  // 直接更新槽位；懒启动设计下不触发 worker 或 X11 连接。
  WB_LINUX_TRY {
    ShortcutEngine::Get().SetCallback(callback);
  }
  WB_LINUX_CATCH_VOID
}

}  // namespace wb::platform::linux_

#else  // !WB_LINUX_HAVE_X11

// 无 X11 头文件的构建：快捷键能力整体安全降级（无任何 Xlib 依赖）。
namespace wb::platform::linux_ {

extern "C" WB_LINUX_API int wb_linux_shortcut_register(
    const char* /*accelerator*/, const char* /*id*/) {
  return WB_ERR_UNSUPPORTED;
}

extern "C" WB_LINUX_API int wb_linux_shortcut_unregister(const char* /*id*/) {
  return WB_OK;
}

extern "C" WB_LINUX_API int wb_linux_shortcut_unregister_all(void) {
  return WB_OK;
}

extern "C" WB_LINUX_API void wb_linux_shortcut_set_callback(
    WbLinuxStrCallback /*callback*/) {}

}  // namespace wb::platform::linux_

#endif  // WB_LINUX_HAVE_X11
