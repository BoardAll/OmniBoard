/// 全局快捷键加速键的纯 Dart 解析与归一。
///
/// 语法：修饰键段用 `+` 连接，其中恰好一个段为主键。示例：
/// `Ctrl+Shift+J`、`Alt+F4`、`Cmd+Space`。
///
/// 归一规则：
///
///   - 修饰键别名不区分大小写：`ctrl` / `control`、`shift`、`alt` /
///     `option`、`cmd` / `command` / `super` / `win` / `meta` / `⌘`
///     （统一归一为 Super，字段名 [WbAccelerator.superKey] 规避
///     Dart 保留字 `super`）；
///   - 主键：字母统一大写（`j` → `J`），数字 `0`…`9`，功能键
///     `F1`…`F24`，常见命名键（`Space` / `Tab` / `Escape` / `Return` /
///     `PageUp` / `PageDown` / `Arrow` 系列等）。
///
/// 解析失败（空串、缺主键、多个主键、未知键名、重复修饰键等）返回 null，
/// 绝不抛异常。解析结果供 UI 展示与校验；原生侧（X11 XGrabKey）按同一
/// 键名集合解析传入的字符串。
library;

/// 归一化后的加速键描述。
class WbAccelerator {
  /// 构造（通常经 [parse] 得到）。
  const WbAccelerator({
    required this.ctrl,
    required this.shift,
    required this.alt,
    required this.superKey,
    required this.key,
  });

  /// 是否包含 Ctrl 修饰键。
  final bool ctrl;

  /// 是否包含 Shift 修饰键。
  final bool shift;

  /// 是否包含 Alt 修饰键。
  final bool alt;

  /// 是否包含 Super 修饰键（`⌘` / `Cmd` / `Win` / `Meta`）。
  ///
  /// 字段名为 `superKey`，规避 Dart 保留字 `super`。
  final bool superKey;

  /// 归一化主键：`A`…`Z`、`0`…`9`、`F1`…`F24` 或命名键名（如 `Space`）。
  final String key;

  /// 解析加速键字符串；语法非法时返回 null（不抛异常）。
  static WbAccelerator? parse(String accelerator) {
    final String trimmed = accelerator.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    bool ctrl = false;
    bool shift = false;
    bool alt = false;
    bool superKey = false;
    String? key;
    for (final String rawToken in trimmed.split('+')) {
      final String token = rawToken.trim();
      if (token.isEmpty) {
        return null;
      }
      final String lower = token.toLowerCase();
      switch (lower) {
        case 'ctrl':
        case 'control':
          if (ctrl) {
            return null;
          }
          ctrl = true;
        case 'shift':
          if (shift) {
            return null;
          }
          shift = true;
        case 'alt':
        case 'option':
        case 'opt':
          if (alt) {
            return null;
          }
          alt = true;
        case 'cmd':
        case 'command':
        case 'super':
        case 'win':
        case 'meta':
        case '⌘':
          if (superKey) {
            return null;
          }
          superKey = true;
        default:
          if (key != null) {
            return null;
          }
          final String? normalized = _normalizeKey(token);
          if (normalized == null) {
            return null;
          }
          key = normalized;
      }
    }
    if (key == null) {
      return null;
    }
    return WbAccelerator(
      ctrl: ctrl,
      shift: shift,
      alt: alt,
      superKey: superKey,
      key: key,
    );
  }

  /// 归一化字符串（如 `Ctrl+Shift+J`）。
  @override
  String toString() {
    final List<String> parts = <String>[
      if (ctrl) 'Ctrl',
      if (shift) 'Shift',
      if (alt) 'Alt',
      if (superKey) 'Super',
      key,
    ];
    return parts.join('+');
  }
}

/// 主键归一：单字符字母 / 数字、`F1`…`F24`、常见命名键。
///
/// 返回 null 表示非法键名。
String? _normalizeKey(String token) {
  if (token.length == 1) {
    final String upper = token.toUpperCase();
    final int code = upper.codeUnitAt(0);
    final bool isLetter = code >= 0x41 && code <= 0x5A;
    final bool isDigit = code >= 0x30 && code <= 0x39;
    return isLetter || isDigit ? upper : null;
  }
  final String upper = token.toUpperCase();
  if (upper.length <= 3 && upper.startsWith('F')) {
    final int? digits = int.tryParse(upper.substring(1));
    if (digits != null && digits >= 1 && digits <= 24) {
      return 'F$digits';
    }
  }
  return _namedKeys[token.toLowerCase()];
}

/// 常见命名键归一表（键：小写别名；值：规范键名，与原生键名解析对齐）。
const Map<String, String> _namedKeys = <String, String>{
  'space': 'Space',
  'tab': 'Tab',
  'escape': 'Escape',
  'esc': 'Escape',
  'enter': 'Return',
  'return': 'Return',
  'backspace': 'Backspace',
  'delete': 'Delete',
  'del': 'Delete',
  'insert': 'Insert',
  'ins': 'Insert',
  'home': 'Home',
  'end': 'End',
  'pageup': 'PageUp',
  'page_up': 'PageUp',
  'pgup': 'PageUp',
  'pagedown': 'PageDown',
  'page_down': 'PageDown',
  'pgdn': 'PageDown',
  'left': 'Left',
  'arrowleft': 'Left',
  'right': 'Right',
  'arrowright': 'Right',
  'up': 'Up',
  'arrowup': 'Up',
  'down': 'Down',
  'arrowdown': 'Down',
};
