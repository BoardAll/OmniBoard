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
  static const FontWeight weightRegular = FontWeight.w400;
  static const FontWeight weightMedium = FontWeight.w500;
  static const FontWeight weightSemiBold = FontWeight.w600;
  static const FontWeight weightBold = FontWeight.w700;

  // ---- 字体族回退（中文优先）----
  static const List<String> fontFallback = <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Hiragino Sans GB',
    'Noto Sans CJK SC',
    'Source Han Sans SC',
    'sans-serif',
  ];

  // ---- 预置文本样式 ----
  /// 辅助说明（最小号）。
  static const TextStyle caption = TextStyle(
    fontSize: fontSizeXs,
    height: lineHeightNormal,
    fontWeight: weightRegular,
  );

  /// 次级标签。
  static const TextStyle label = TextStyle(
    fontSize: fontSizeSm,
    height: lineHeightNormal,
    fontWeight: weightMedium,
  );

  /// 正文。
  static const TextStyle body = TextStyle(
    fontSize: fontSizeBase,
    height: lineHeightNormal,
    fontWeight: weightRegular,
  );

  /// 正文（中等字重，强调）。
  static const TextStyle bodyMedium = TextStyle(
    fontSize: fontSizeBase,
    height: lineHeightNormal,
    fontWeight: weightMedium,
  );

  /// 面板标题。
  static const TextStyle title = TextStyle(
    fontSize: fontSizeMd,
    height: lineHeightTight,
    fontWeight: weightSemiBold,
  );

  /// 区块标题。
  static const TextStyle heading = TextStyle(
    fontSize: fontSizeLg,
    height: lineHeightTight,
    fontWeight: weightSemiBold,
  );

  /// 页面大标题。
  static const TextStyle display = TextStyle(
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
