import 'package:flutter/material.dart';

import 'theme_data.dart';
import 'theme_pack.dart';

/// 主题管理器：持有当前主题，支持切换、注册自定义主题/主题包并通知监听者。
///
/// 典型接入：作为 `ChangeNotifier` 交给顶层 `ListenableBuilder`/状态库，
/// 把 [flutterThemeData] 传给 `MaterialApp.theme`；[onThemeChanged] 用于持久化。
class WbThemeManager extends ChangeNotifier {
  WbThemeManager({
    String? initialThemeId,
    List<WbThemeData> customThemes = const <WbThemeData>[],
  }) : _customThemes = List<WbThemeData>.of(customThemes) {
    _current = WbBuiltinThemes.byId(initialThemeId ?? WbBuiltinThemes.defaultId) ??
        _findCustom(initialThemeId) ??
        WbBuiltinThemes.defaultTheme;
  }

  final List<WbThemeData> _customThemes;
  late WbThemeData _current;

  /// 主题切换完成后的持久化回调（参数为新主题 id）。
  ValueChanged<String>? onThemeChanged;

  /// 当前主题。
  WbThemeData get current => _current;

  /// 当前主题对应的 Flutter [ThemeData]（直接用于 MaterialApp）。
  ThemeData get flutterThemeData => _current.toFlutterThemeData();

  /// 全部可用主题（内置在前，自定义在后；同 id 以自定义优先）。
  List<WbThemeData> get available {
    final List<WbThemeData> result = List<WbThemeData>.of(WbBuiltinThemes.all);
    for (final WbThemeData custom in _customThemes) {
      result.removeWhere((WbThemeData t) => t.id == custom.id);
      result.add(custom);
    }
    return result;
  }

  /// 已注册的自定义主题（不可变视图）。
  List<WbThemeData> get customThemes =>
      List<WbThemeData>.unmodifiable(_customThemes);

  /// 按 id 切换主题；id 未知时回退默认主题。
  void setTheme(String id) {
    apply(
      WbBuiltinThemes.byId(id) ??
          _findCustom(id) ??
          WbBuiltinThemes.defaultTheme,
    );
  }

  /// 直接应用主题对象。
  void apply(WbThemeData theme) {
    if (_current == theme) {
      return;
    }
    _current = theme;
    onThemeChanged?.call(theme.id);
    notifyListeners();
  }

  /// 注册自定义主题（同 id 覆盖）并立即应用。
  void registerCustom(WbThemeData theme) {
    _customThemes.removeWhere((WbThemeData t) => t.id == theme.id);
    _customThemes.add(theme);
    apply(theme);
  }

  /// 注册主题包内全部主题，并切到包内第一个主题（空包只通知）。
  void registerPack(WbThemePack pack) {
    for (final WbThemeData theme in pack.themes) {
      _customThemes.removeWhere((WbThemeData t) => t.id == theme.id);
      _customThemes.add(theme);
    }
    if (pack.themes.isEmpty) {
      notifyListeners();
      return;
    }
    apply(pack.themes.first);
  }

  /// 移除自定义主题；若移除的是当前主题则回退默认主题。
  ///
  /// 返回是否确实移除了一个主题。
  bool removeCustom(String id) {
    final int before = _customThemes.length;
    _customThemes.removeWhere((WbThemeData t) => t.id == id);
    if (_customThemes.length == before) {
      return false;
    }
    if (_current.id == id) {
      apply(WbBuiltinThemes.defaultTheme);
    } else {
      notifyListeners();
    }
    return true;
  }

  WbThemeData? _findCustom(String? id) {
    if (id == null) {
      return null;
    }
    for (final WbThemeData theme in _customThemes) {
      if (theme.id == id) {
        return theme;
      }
    }
    return null;
  }
}
