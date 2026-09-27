import 'package:flutter/material.dart';

import '../theme_data.dart';
import '../theme_tokens.dart';

/// 清爽专业（默认亮色主题，与 C++ `kThemes[0]` 一致）。
const WbThemeData kCleanProfessionalTheme = WbThemeData(
  id: 'clean-professional',
  name: '清爽专业',
  dark: false,
  colors: WbThemeColors(
    canvas: Color(0xFFF7F8FA),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFFFFF),
    primary: Color(0xFF3370FF),
    icon: Color(0xFF475467),
    hover: Color(0xFFF2F4F7),
    border: Color(0xFFE4E7EC),
  ),
);
