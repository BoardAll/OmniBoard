import 'package:flutter/material.dart';

import '../theme_data.dart';
import '../theme_tokens.dart';

/// 黑板（深色教学主题，与 C++ `kThemes[2]` 一致）。
const WbThemeData kBlackboardTheme = WbThemeData(
  id: 'blackboard',
  name: '黑板',
  dark: true,
  colors: WbThemeColors(
    canvas: Color(0xFF1A1D21),
    surface: Color(0xFF23272B),
    elevated: Color(0xFF2C3136),
    primary: Color(0xFFFFFFFF),
    icon: Color(0xFFD0D5DD),
    hover: Color(0xFF363C42),
    border: Color(0xFF454C54),
  ),
);
