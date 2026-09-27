/// 文本处理工具（纯函数，无副作用）。
abstract final class WbTextUtils {
  /// 按字符数截断并追加省略号（按 Unicode 字符而非 UTF-16 码元计数，兼容中文/emoji）。
  static String ellipsis(String text, int maxChars, {String suffix = '…'}) {
    final List<int> runes = text.runes.toList();
    if (runes.length <= maxChars) {
      return text;
    }
    if (maxChars <= suffix.length) {
      return suffix;
    }
    return '${String.fromCharCodes(runes.take(maxChars - suffix.length))}$suffix';
  }

  /// 提取名称首字母/首字（头像占位）。
  ///
  /// 中文取首字；英文取首个单词首字母（最多 2 个单词）。
  static String initials(String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      return '?';
    }
    final int first = trimmed.runes.first;
    final bool isAscii = first < 0x80;
    if (!isAscii) {
      return String.fromCharCode(first);
    }
    final List<String> words = trimmed.split(RegExp(r'\s+')).where((String w) => w.isNotEmpty).toList();
    if (words.isEmpty) {
      return '?';
    }
    final StringBuffer buffer = StringBuffer(words.first.substring(0, 1).toUpperCase());
    if (words.length > 1) {
      buffer.write(words[1].substring(0, 1).toUpperCase());
    }
    return buffer.toString();
  }

  /// 是否包含 CJK 字符。
  static bool hasCjk(String text) =>
      text.runes.any((int r) => (r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x3000 && r <= 0x30FF));

  /// 估算文本渲染宽度（无上下文场景的近似值）。
  ///
  /// CJK 字符按 1.0 倍字号、ASCII 按 0.55 倍字号估算。
  static double estimateWidth(String text, double fontSize) {
    double width = 0;
    for (final int r in text.runes) {
      final bool wide = r >= 0x1100 && (r <= 0x115F || (r >= 0x2E80 && r <= 0xA4CF) || (r >= 0xAC00 && r <= 0xD7A3) || (r >= 0xF900 && r <= 0xFAFF) || (r >= 0xFF00 && r <= 0xFF60));
      width += wide ? fontSize : fontSize * 0.55;
    }
    return width;
  }

  /// 数字千分位格式化（如 1234567 → `1,234,567`）。
  static String thousands(int value) {
    final bool negative = value < 0;
    final String digits = value.abs().toString();
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(digits[i]);
    }
    return negative ? '-$buffer' : buffer.toString();
  }
}
