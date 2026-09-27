import 'package:flutter/material.dart';

/// 圆角比例与常用 BorderRadius 预设。
///
/// 基础三档（s/m/l）与 C++ 主题域的 radius token（4/8/12）对齐。
abstract final class WbRadius {
  // ---- 基础比例 ----
  static const double none = 0;
  static const double s = 4;
  static const double m = 8;
  static const double l = 12;
  static const double xl = 16;
  static const double full = 999;

  // ---- BorderRadius 预设 ----
  static const BorderRadius allS = BorderRadius.all(Radius.circular(s));
  static const BorderRadius allM = BorderRadius.all(Radius.circular(m));
  static const BorderRadius allL = BorderRadius.all(Radius.circular(l));
  static const BorderRadius allXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius allFull = BorderRadius.all(Radius.circular(full));

  /// 顶部圆角（弹出面板/底部抽屉）。
  static const BorderRadius topL = BorderRadius.vertical(top: Radius.circular(l));

  /// 底部圆角。
  static const BorderRadius bottomL = BorderRadius.vertical(bottom: Radius.circular(l));

  /// 按半径值构造全圆角。
  static BorderRadius circular(double value) => BorderRadius.all(Radius.circular(value));
}
