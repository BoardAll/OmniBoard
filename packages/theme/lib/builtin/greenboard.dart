import 'package:flutter/material.dart';

import '../theme_data.dart';
import '../theme_tokens.dart';

/// 绿板（深色教学主题，与 C++ `kThemes[3]` 一致）。
const WbThemeData kGreenboardTheme = WbThemeData(
  id: 'greenboard',
  name: '绿板',
  dark: true,
  colors: WbThemeColors(
    canvas: Color(0xFF1E3A2F),
    surface: Color(0xFF27493C),
    elevated: Color(0xFF2F5647),
    primary: Color(0xFFFFFFFF),
    icon: Color(0xFFD5E8DD),
    hover: Color(0xFF386354),
    border: Color(0xFF47755F),
  ),
);
