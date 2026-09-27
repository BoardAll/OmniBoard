import 'package:flutter/material.dart';

import '../theme_data.dart';
import '../theme_tokens.dart';

/// 暗夜（深色主题，与 C++ `kThemes[1]` 一致）。
const WbThemeData kDarkNightTheme = WbThemeData(
  id: 'dark-night',
  name: '暗夜',
  dark: true,
  colors: WbThemeColors(
    canvas: Color(0xFF121417),
    surface: Color(0xFF1A1D24),
    elevated: Color(0xFF23272F),
    primary: Color(0xFF4C88FF),
    icon: Color(0xFFAAB2C0),
    hover: Color(0xFF2C313B),
    border: Color(0xFF343A46),
  ),
);
