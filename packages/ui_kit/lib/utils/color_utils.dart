import 'package:flutter/material.dart';

/// 颜色处理工具（纯函数，无副作用）。
abstract final class WbColorUtils {
  /// 从十六进制字符串解析颜色。
  ///
  /// 支持 `#RGB`、`#RRGGBB`、`#AARRGGBB`（可省略 `#`）。
  /// 解析失败返回 [fallback]。
  static Color fromHex(String hex, {Color fallback = const Color(0xFF000000)}) {
    String value = hex.trim();
    if (value.startsWith('#')) {
      value = value.substring(1);
    }
    if (value.length == 3) {
      // #RGB → #RRGGBB
      value = value.split('').map((String c) => '$c$c').join();
    }
    if (value.length == 6) {
      final int? rgb = int.tryParse(value, radix: 16);
      return rgb == null ? fallback : Color(0xFF000000 | rgb);
    }
    if (value.length == 8) {
      final int? argb = int.tryParse(value, radix: 16);
      return argb == null ? fallback : Color(argb);
    }
    return fallback;
  }

  /// 颜色转 `#RRGGBB`（不含 alpha）；如 [withAlpha] 为 true 输出 `#AARRGGBB`。
  static String toHex(Color color, {bool withAlpha = false}) {
    String channel(double v) => (v * 255).round().toRadixString(16).padLeft(2, '0');
    final String rgb = '${channel(color.r)}${channel(color.g)}${channel(color.b)}'.toUpperCase();
    if (!withAlpha) {
      return '#$rgb';
    }
    return '#${channel(color.a)}$rgb'.toUpperCase();
  }

  /// 目测亮度是否偏高（0.5 阈值，近似感知亮度）。
  static bool isLight(Color color) => color.computeLuminance() > 0.5;

  /// 给定背景色返回合适的前景对比色（黑或白）。
  static Color contrastText(Color background) =>
      isLight(background) ? const Color(0xFF1D2939) : const Color(0xFFFFFFFF);

  /// 线性混合两色，[t] 为 0→[a]，1→[b]。
  static Color blend(Color a, Color b, double t) =>
      Color.lerp(a, b, t.clamp(0, 1)) ?? a;

  /// 调亮（[amount] 0~1）。
  static Color lighten(Color color, double amount) =>
      blend(color, const Color(0xFFFFFFFF), amount);

  /// 调暗（[amount] 0~1）。
  static Color darken(Color color, double amount) =>
      blend(color, const Color(0xFF000000), amount);

  /// 按比例调整透明度（在现有 alpha 基础上乘以 [fraction]）。
  static Color fade(Color color, double fraction) =>
      color.withValues(alpha: (color.a * fraction.clamp(0, 1)).clamp(0, 1));

  /// 将颜色转为 ARGB32 整数值（跨 FFI 传输用）。
  static int toArgb32(Color color) => color.toARGB32();

  /// 从 ARGB32 整数值构造颜色。
  static Color fromArgb32(int value) => Color(value);
}
