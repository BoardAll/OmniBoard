import 'package:flutter/material.dart';

import '../theme_data.dart';
import '../theme_tokens.dart';

/// 极简黑白（与 C++ `kThemes[4]` 一致）。
const WbThemeData kMinimalTheme = WbThemeData(
  id: 'minimal',
  name: '极简黑白',
  dark: false,
  colors: WbThemeColors(
    canvas: Color(0xFFFFFFFF),
    surface: Color(0xFFF7F7F7),
    elevated: Color(0xFFFFFFFF),
    primary: Color(0xFF000000),
    icon: Color(0xFF1A1A1A),
    hover: Color(0xFFEFEFEF),
    border: Color(0xFFD9D9D9),
  ),
);
