import 'package:flutter/material.dart';

/// 动效时长与缓动曲线。
abstract final class WbDuration {
  /// 无动画。
  static const Duration instant = Duration.zero;

  /// 微交互（按钮反馈、hover）。
  static const Duration fast = Duration(milliseconds: 100);

  /// 白板常用交互（工具切换、选中反馈）。
  static const Duration normal = Duration(milliseconds: 150);

  /// 通用过渡（面板展开、淡入淡出）。
  static const Duration medium = Duration(milliseconds: 200);

  /// 较大过渡（页面切换、弹窗）。
  static const Duration slow = Duration(milliseconds: 300);

  /// 强调动效（引导提示）。
  static const Duration slower = Duration(milliseconds: 500);

  // ---- 交互系统时延 ----
  /// 长按触发延迟（圆盘子工具展开）。
  static const Duration longPressDelay = Duration(milliseconds: 500);

  /// 双击判定间隔。
  static const Duration doubleTapDelay = Duration(milliseconds: 250);

  /// tooltip 显示延迟。
  static const Duration tooltipDelay = Duration(milliseconds: 600);
}

/// 动效缓动曲线。
abstract final class WbCurves {
  /// 标准缓动（进场退出通用）。
  static const Curve standard = Curves.easeInOut;

  /// 减速（进场为主）。
  static const Curve decelerate = Curves.easeOut;

  /// 加速（退场为主）。
  static const Curve accelerate = Curves.easeIn;

  /// 强调缓动（Material 3 风格）。
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;

  /// 弹性（拖动回弹）。
  static const Curve spring = Curves.elasticOut;
}
