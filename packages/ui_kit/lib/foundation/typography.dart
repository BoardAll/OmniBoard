import 'package:flutter/material.dart';

/// 字体比例、字重与预置文本样式。
///
/// 字号基于桌面白板场景（信息密度较高），基准字号 13。
abstract final class WbTypography {
  // ---- 字号 ----
  static const double fontSizeXs = 11;
  static const double fontSizeSm = 12;
  static const double fontSizeBase = 13;
  static const double fontSizeMd = 14;
  static const double fontSizeLg = 16;
  static const double fontSizeXl = 18;
  static const double fontSizeXxl = 24;
  static const double fontSizeDisplay = 32;

  // ---- 行高（倍数）----
  static const double lineHeightTight = 1.2;
  static const double lineHeightNormal = 1.5;
  static const double lineHeightRelaxed = 1.7;

  // ---- 字重 ----
  static const FontWeight weightRegular = FontWeight.w500;
  static const FontWeight weightMedium = FontWeight.w600;
  static const FontWeight weightSemiBold = FontWeight.w600;
  static const FontWeight weightBold = FontWeight.w700;

  /// 界面主字体。
  ///
  /// Windows 上 Flutter 使用灰度抗锯齿，微软雅黑 UI 按 ClearType 微调，
  /// 小字号笔画发灰。Segoe UI 是系统界面字体，西文更实。
  static const String fontFamily = 'Segoe UI';

  /// 缺字回退。中文优先等线（DengXian），它比微软雅黑 UI 在灰度抗锯齿下更清晰。
  static const List<String> fontFallback = <String>[
    'DengXian',
    '等线',
    'Microsoft YaHei',
    'PingFang SC',
    'Hiragino Sans GB',
    'Noto Sans CJK SC',
    'Source Han Sans SC',
    'sans-serif',
  ];

  /// 给未指定字体的样式补上界面字体；已指定 [TextStyle.fontFamily] 的保持不变。
  static TextStyle apply(TextStyle style) {
    if (style.fontFamily != null) {
      return style.copyWith(
        fontFamilyFallback: style.fontFamilyFallback ?? fontFallback,
        fontWeight: style.fontWeight ?? weightRegular,
      );
    }
    return style.copyWith(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFallback,
      fontWeight: style.fontWeight ?? weightRegular,
    );
  }

  // ---- 预置文本样式 ----
  /// 辅助说明（最小号）。
  static const TextStyle caption = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFallback,
    fontSize: fontSizeXs,
    height: lineHeightNormal,
    fontWeight: weightRegular,
  );

  /// 次级标签。
  static const TextStyle label = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFallback,
    fontSize: fontSizeSm,
    height: lineHeightNormal,
    fontWeight: weightMedium,
  );

  /// 正文。
  static const TextStyle body = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFallback,
    fontSize: fontSizeBase,
    height: lineHeightNormal,
    fontWeight: weightRegular,
  );

  /// 正文（中等字重，强调）。
  static const TextStyle bodyMedium = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFallback,
    fontSize: fontSizeBase,
    height: lineHeightNormal,
    fontWeight: weightMedium,
  );

  /// 面板标题。
  static const TextStyle title = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFallback,
    fontSize: fontSizeMd,
    height: lineHeightTight,
    fontWeight: weightSemiBold,
  );

  /// 区块标题。
  static const TextStyle heading = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFallback,
    fontSize: fontSizeLg,
    height: lineHeightTight,
    fontWeight: weightSemiBold,
  );

  /// 页面大标题。
  static const TextStyle display = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFallback,
    fontSize: fontSizeXxl,
    height: lineHeightTight,
    fontWeight: weightBold,
  );

  // ---- 等宽字体（公式/代码场景）----
  static const List<String> monoFallback = <String>[
    'Consolas',
    'Menlo',
    'DejaVu Sans Mono',
    'monospace',
  ];
}
