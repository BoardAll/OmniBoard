import 'package:flutter/material.dart';

/// 间距比例（4pt 网格）与常用 EdgeInsets 预设。
abstract final class WbSpacing {
  // ---- 基础比例 ----
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  // ---- 语义间距 ----
  /// 工具条图标间隙。
  static const double toolbarGap = xs;

  /// 面板内边距。
  static const double panelPadding = lg;

  /// 卡片内边距。
  static const double cardPadding = md;

  /// 列表项高度（紧凑）。
  static const double listItemHeight = 36;

  /// 工具条按钮尺寸。
  static const double toolbarButton = 36;

  /// 圆盘图标尺寸。
  static const double radialIconSize = 20;

  /// 触控最小命中尺寸。
  static const double minHitTarget = 32;

  // ---- EdgeInsets 预设 ----
  static const EdgeInsets allXs = EdgeInsets.all(xs);
  static const EdgeInsets allSm = EdgeInsets.all(sm);
  static const EdgeInsets allMd = EdgeInsets.all(md);
  static const EdgeInsets allLg = EdgeInsets.all(lg);
  static const EdgeInsets horizontalSm = EdgeInsets.symmetric(horizontal: sm);
  static const EdgeInsets horizontalMd = EdgeInsets.symmetric(horizontal: md);
  static const EdgeInsets horizontalLg = EdgeInsets.symmetric(horizontal: lg);
  static const EdgeInsets verticalSm = EdgeInsets.symmetric(vertical: sm);
  static const EdgeInsets verticalMd = EdgeInsets.symmetric(vertical: md);
  static const EdgeInsets card = EdgeInsets.all(cardPadding);
  static const EdgeInsets panel = EdgeInsets.all(panelPadding);
}
