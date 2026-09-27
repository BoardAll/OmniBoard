import 'package:flutter/material.dart';

/// 基础调色板（与主题无关的通用颜色 token）。
///
/// 具体主题色（bg/accent/card 等）由 `whiteboard_theme` 包的主题数据提供；
/// 本类只沉淀跨主题复用的中性色阶、语义色与透明度常量。
abstract final class WbColors {
  // ---- 中性色阶 ----
  static const Color gray50 = Color(0xFFF9FAFB);
  static const Color gray100 = Color(0xFFF2F4F7);
  static const Color gray200 = Color(0xFFE4E7EC);
  static const Color gray300 = Color(0xFFD0D5DD);
  static const Color gray400 = Color(0xFF98A2B3);
  static const Color gray500 = Color(0xFF667085);
  static const Color gray600 = Color(0xFF475467);
  static const Color gray700 = Color(0xFF344054);
  static const Color gray800 = Color(0xFF1D2939);
  static const Color gray900 = Color(0xFF101828);

  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF000000);
  static const Color transparent = Color(0x00000000);

  // ---- 语义色（基准蓝与 C++ 默认主题 accent 对齐：#3370FF）----
  static const Color primary = Color(0xFF3370FF);
  static const Color primaryHover = Color(0xFF2860E8);
  static const Color primaryActive = Color(0xFF1F4FCB);
  static const Color primarySubtle = Color(0xFFEAF1FF);

  static const Color success = Color(0xFF12B76A);
  static const Color successSubtle = Color(0xFFECFDF3);

  static const Color warning = Color(0xFFF79009);
  static const Color warningSubtle = Color(0xFFFFFAEB);

  static const Color danger = Color(0xFFF04438);
  static const Color dangerSubtle = Color(0xFFFEF3F2);

  static const Color info = Color(0xFF0BA5EC);
  static const Color infoSubtle = Color(0xFFF0F9FF);

  // ---- 画布基础色 ----
  static const Color canvasBackground = Color(0xFFF7F8FA);
  static const Color canvasPage = Color(0xFFFFFFFF);
  static const Color canvasGrid = Color(0x14000000);
  static const Color canvasSelection = primary;
  static const Color canvasGuide = Color(0xFFFF4D4F);

  // ---- 暗色基准（供暗色主题引用）----
  static const Color darkBackground = Color(0xFF16181D);
  static const Color darkSurface = Color(0xFF1E2128);
  static const Color darkBorder = Color(0xFF2E323B);

  // ---- 透明度常量 ----
  /// 禁用态不透明度。
  static const double opacityDisabled = 0.38;

  /// 次级信息不透明度。
  static const double opacityMedium = 0.6;

  /// 强调信息不透明度。
  static const double opacityStrong = 0.87;

  /// hover 叠加层不透明度。
  static const double opacityHover = 0.08;

  /// 遮罩层（弹窗蒙层）不透明度。
  static const double opacityScrim = 0.45;
}
