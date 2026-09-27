import 'package:flutter/material.dart';

import 'colors.dart';

/// 阴影层级与 BoxShadow 生成。
abstract final class WbElevation {
  // ---- 层级 ----
  static const double none = 0;
  static const double low = 1;
  static const double medium = 2;
  static const double high = 3;
  static const double highest = 4;

  /// 生成指定层级的阴影列表。
  ///
  /// [level] ≤ 0 返回空列表；超过 [highest] 按 [highest] 处理。
  static List<BoxShadow> shadows(double level) {
    if (level <= none) {
      return const <BoxShadow>[];
    }
    final int lv = level > highest ? highest.toInt() : level.round();
    switch (lv) {
      case 1:
        return <BoxShadow>[
          BoxShadow(
            color: WbColors.black.withValues(alpha: 0.06),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
          BoxShadow(
            color: WbColors.black.withValues(alpha: 0.04),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ];
      case 2:
        return <BoxShadow>[
          BoxShadow(
            color: WbColors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
          BoxShadow(
            color: WbColors.black.withValues(alpha: 0.04),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ];
      case 3:
        return <BoxShadow>[
          BoxShadow(
            color: WbColors.black.withValues(alpha: 0.10),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: WbColors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ];
      default:
        return <BoxShadow>[
          BoxShadow(
            color: WbColors.black.withValues(alpha: 0.14),
            blurRadius: 28,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: WbColors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ];
    }
  }

  /// 层级 1 阴影（悬浮工具条/按钮）。
  static List<BoxShadow> get lowShadows => shadows(low);

  /// 层级 2 阴影（面板/菜单）。
  static List<BoxShadow> get mediumShadows => shadows(medium);

  /// 层级 3 阴影（对话框/弹出层）。
  static List<BoxShadow> get highShadows => shadows(high);
}
