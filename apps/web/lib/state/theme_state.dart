/// Web 主题状态：包装 [WbThemeManager] 为可监听状态。
///
/// 骨架阶段主题偏好仅保存在内存（进程内）；浏览器持久化
/// （localStorage）在 Wave 4 接入，对外契约（[select] / [flutterThemeData]）
/// 保持不变（与 apps/desktop 的 `WbThemeState` 同形）。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_theme/theme.dart';

/// 主题状态（ChangeNotifier），供 `ChangeNotifierProvider` 挂载。
class WbWebThemeState extends ChangeNotifier {
  /// 创建主题状态；[initialThemeId] 为空时使用内置默认主题
  /// （`clean-professional`）。
  WbWebThemeState({String initialThemeId = ''})
      : _manager = WbThemeManager(
          initialThemeId: initialThemeId.isEmpty ? null : initialThemeId,
        ) {
    _manager.addListener(_onThemeChanged);
  }

  final WbThemeManager _manager;

  /// 当前主题。
  WbThemeData get current => _manager.current;

  /// 全部可用主题（9 内置 + 自定义）。
  List<WbThemeData> get available => _manager.available;

  /// 当前主题对应的 Flutter [ThemeData]（直接用于 MaterialApp）。
  ThemeData get flutterThemeData => _manager.flutterThemeData;

  /// 切换主题（未知 id 回退默认主题）。
  void select(String themeId) => _manager.setTheme(themeId);

  void _onThemeChanged() => notifyListeners();

  @override
  void dispose() {
    _manager.removeListener(_onThemeChanged);
    _manager.dispose();
    super.dispose();
  }
}
