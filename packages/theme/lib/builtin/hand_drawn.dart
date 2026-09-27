import 'package:flutter/material.dart';

import '../theme_data.dart';
import '../theme_tokens.dart';

/// 手绘（暖色纸张质感，与 C++ `kThemes[5]` 一致）。
const WbThemeData kHandDrawnTheme = WbThemeData(
  id: 'hand-drawn',
  name: '手绘',
  dark: false,
  colors: WbThemeColors(
    canvas: Color(0xFFFDF6E3),
    surface: Color(0xFFFBF0D9),
    elevated: Color(0xFFFFF9EC),
    primary: Color(0xFF8B5A2B),
    icon: Color(0xFF6B4F2A),
    hover: Color(0xFFF6E9CC),
    border: Color(0xFFE3D5B5),
  ),
);
