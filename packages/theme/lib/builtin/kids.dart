import 'package:flutter/material.dart';

import '../theme_data.dart';
import '../theme_tokens.dart';

/// 儿童（明亮粉色主题，与 C++ `kThemes[7]` 一致）。
const WbThemeData kKidsTheme = WbThemeData(
  id: 'kids',
  name: '儿童',
  dark: false,
  colors: WbThemeColors(
    canvas: Color(0xFFFFF9E6),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFFFFF),
    primary: Color(0xFFFF6B9D),
    icon: Color(0xFF8A6D3B),
    hover: Color(0xFFFFF0F5),
    border: Color(0xFFFFD9E5),
  ),
);
