import 'package:flutter/material.dart';

import '../theme_data.dart';
import '../theme_tokens.dart';

/// 赛博（霓虹深色主题，与 C++ `kThemes[6]` 一致；C++ id 为 `cyber`）。
const WbThemeData kCyberpunkTheme = WbThemeData(
  id: 'cyber',
  name: '赛博',
  dark: true,
  colors: WbThemeColors(
    canvas: Color(0xFF0A0E27),
    surface: Color(0xFF111633),
    elevated: Color(0xFF1A2148),
    primary: Color(0xFF00E5FF),
    icon: Color(0xFF9BB8FF),
    hover: Color(0xFF232B5C),
    border: Color(0xFF2E3875),
  ),
);
