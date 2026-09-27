import 'package:flutter/material.dart';

import '../theme_data.dart';
import '../theme_tokens.dart';

/// 企业（沉稳蓝色商务主题，与 C++ `kThemes[8]` 一致）。
const WbThemeData kEnterpriseTheme = WbThemeData(
  id: 'enterprise',
  name: '企业',
  dark: false,
  colors: WbThemeColors(
    canvas: Color(0xFFF5F7FA),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFFFFF),
    primary: Color(0xFF1E5AA8),
    icon: Color(0xFF40536B),
    hover: Color(0xFFEEF2F8),
    border: Color(0xFFDCE3EE),
  ),
);
