/// 主题系统主入口：完整主题模型、token、9 个内置主题、包加载与管理器。
library;

import 'package:flutter/material.dart';

import 'theme_data.dart';
import 'theme_pack.dart';
import 'theme_tokens.dart';

export 'builtin/blackboard.dart';
export 'builtin/clean_professional.dart';
export 'builtin/cyberpunk.dart';
export 'builtin/dark_night.dart';
export 'builtin/enterprise.dart';
export 'builtin/greenboard.dart';
export 'builtin/hand_drawn.dart';
export 'builtin/kids.dart';
export 'builtin/minimal.dart';
export 'theme_data.dart';
export 'theme_loader.dart';
export 'theme_manager.dart';
export 'theme_pack.dart';
export 'theme_tokens.dart';

/// 上下文扩展：快速取当前完整主题 token。
extension WbThemeContext on BuildContext {
  /// 完整 [WbThemeData]（未挂载 [WbThemeExtension] 时回退默认主题）。
  WbThemeData get wbTheme {
    final WbThemeExtension? ext = Theme.of(this).extension<WbThemeExtension>();
    return ext?.theme ?? WbBuiltinThemes.defaultTheme;
  }

  /// 颜色 token 快捷方式。
  WbThemeColors get wbColors => wbTheme.colors;
}
