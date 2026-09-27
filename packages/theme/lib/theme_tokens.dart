import 'package:flutter/material.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

/// 主题颜色 token（与 C++ theme 域的 `colors` 映射一一对应）。
///
/// 基础 7 值由内置主题定义；其余 token 默认派生，也可通过 [overrides]
/// 单独覆盖（key 与 C++ 一致，如 `'toolbar.bg'`）。
class WbThemeColors {
  const WbThemeColors({
    required this.canvas,
    required this.surface,
    required this.elevated,
    required this.primary,
    required this.icon,
    required this.hover,
    required this.border,
    this.overrides = const <String, Color>{},
  });

  /// 亮色默认集（clean-professional）。
  static const WbThemeColors lightDefaults = WbThemeColors(
    canvas: Color(0xFFF7F8FA),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFFFFF),
    primary: Color(0xFF3370FF),
    icon: Color(0xFF475467),
    hover: Color(0xFFF2F4F7),
    border: Color(0xFFE4E7EC),
  );

  /// 画布背景（`bg.canvas`）。
  final Color canvas;

  /// 侧栏/面板表面（`bg.surface`）。
  final Color surface;

  /// 悬浮层（`bg.elevated`）。
  final Color elevated;

  /// 主色（`primary`）。
  final Color primary;

  /// 图标/正文色（`toolbar.icon` 的基础值）。
  final Color icon;

  /// 悬停底色（`card.hover` 的基础值）。
  final Color hover;

  /// 描边色（`card.border` 的基础值）。
  final Color border;

  /// 派生 token 的显式覆盖（key 同 C++，如 `'radial.bg'`）。
  final Map<String, Color> overrides;

  Color _resolve(String key, Color fallback) => overrides[key] ?? fallback;

  /// 工具条背景（`toolbar.bg`）。
  Color get toolbarBackground => _resolve('toolbar.bg', elevated);

  /// 工具条图标色（`toolbar.icon`）。
  Color get toolbarIcon => _resolve('toolbar.icon', icon);

  /// 工具条激活色（`toolbar.active`）。
  Color get toolbarActive => _resolve('toolbar.active', primary);

  /// 圆盘背景（`radial.bg`）。
  Color get radialBackground => _resolve('radial.bg', elevated);

  /// 圆盘高亮（`radial.highlight`）。
  Color get radialHighlight => _resolve('radial.highlight', primary);

  /// 侧栏背景（`sidebar.bg`）。
  Color get sidebarBackground => _resolve('sidebar.bg', surface);

  /// 卡片背景（`card.bg`）。
  Color get cardBackground => _resolve('card.bg', elevated);

  /// 卡片悬停（`card.hover`）。
  Color get cardHover => _resolve('card.hover', hover);

  /// 卡片描边（`card.border`）。
  Color get cardBorder => _resolve('card.border', border);

  /// 对应 C++ JSON 的 `colors` 映射（14 键，值为十六进制字符串）。
  Map<String, String> toJson() {
    return <String, String>{
      'bg.canvas': WbColorUtils.toHex(canvas),
      'bg.surface': WbColorUtils.toHex(surface),
      'bg.elevated': WbColorUtils.toHex(elevated),
      'primary': WbColorUtils.toHex(primary),
      'toolbar.bg': WbColorUtils.toHex(toolbarBackground),
      'toolbar.icon': WbColorUtils.toHex(toolbarIcon),
      'toolbar.active': WbColorUtils.toHex(toolbarActive),
      'radial.bg': WbColorUtils.toHex(radialBackground),
      'radial.highlight': WbColorUtils.toHex(radialHighlight),
      'sidebar.bg': WbColorUtils.toHex(sidebarBackground),
      'card.bg': WbColorUtils.toHex(cardBackground),
      'card.hover': WbColorUtils.toHex(cardHover),
      'card.border': WbColorUtils.toHex(cardBorder),
    };
  }

  /// 从 C++ 风格的 `colors` 映射解析。
  ///
  /// 基础 7 键缺失时回退到 [lightDefaults] 对应值；派生键缺失时按默认规则派生；
  /// 全部 14 键中显式提供且与派生值不同的项进入 [overrides] 以便无损往返。
  factory WbThemeColors.fromJson(Map<String, dynamic> json) {
    const WbThemeColors d = lightDefaults;
    Color read(String key, Color fallback) {
      final Object? value = json[key];
      if (value is String && value.isNotEmpty) {
        return WbColorUtils.fromHex(value, fallback: fallback);
      }
      return fallback;
    }

    final Color canvas = read('bg.canvas', d.canvas);
    final Color surface = read('bg.surface', d.surface);
    final Color elevated = read('bg.elevated', d.elevated);
    final Color primary = read('primary', d.primary);
    final Color icon = read('toolbar.icon', d.icon);
    final Color hover = read('card.hover', d.hover);
    final Color border = read('card.border', d.border);

    final Map<String, Color> overrides = <String, Color>{};
    void capture(String key, Color derived) {
      final Object? value = json[key];
      if (value is String && value.isNotEmpty) {
        final Color explicit = WbColorUtils.fromHex(value, fallback: derived);
        if (explicit != derived) {
          overrides[key] = explicit;
        }
      }
    }

    capture('toolbar.bg', elevated);
    capture('toolbar.active', primary);
    capture('radial.bg', elevated);
    capture('radial.highlight', primary);
    capture('sidebar.bg', surface);
    capture('card.bg', elevated);

    return WbThemeColors(
      canvas: canvas,
      surface: surface,
      elevated: elevated,
      primary: primary,
      icon: icon,
      hover: hover,
      border: border,
      overrides: overrides,
    );
  }

  /// 亮/暗以 [icon] 亮度粗略判断（供 TreeView 等场景快速取反色用）。
  bool get isDark => !WbColorUtils.isLight(elevated);
}

/// 圆角 token（与 C++ `radius` 对齐：s=4 / m=8 / l=12）。
class WbRadiusTokens {
  const WbRadiusTokens({this.s = 4, this.m = 8, this.l = 12});

  final double s;
  final double m;
  final double l;

  /// 标准档（全部内置主题一致）。
  static const WbRadiusTokens standard = WbRadiusTokens();

  Map<String, dynamic> toJson() => <String, dynamic>{'s': s, 'm': m, 'l': l};

  factory WbRadiusTokens.fromJson(Map<String, dynamic> json) {
    double read(String key, double fallback) {
      final Object? value = json[key];
      if (value is num) {
        return value.toDouble();
      }
      return fallback;
    }

    return WbRadiusTokens(
      s: read('s', standard.s),
      m: read('m', standard.m),
      l: read('l', standard.l),
    );
  }
}

/// 透明度 token（与 C++ `opacity` 对齐）。
class WbOpacityTokens {
  const WbOpacityTokens({this.radial = 0.9, this.toolbar = 0.95, this.panel = 1.0});

  /// 圆盘可拖动背景透明度。
  final double radial;

  /// 悬浮工具条透明度。
  final double toolbar;

  /// 面板透明度。
  final double panel;

  /// 标准档（全部内置主题一致）。
  static const WbOpacityTokens standard = WbOpacityTokens();

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'radial': radial, 'toolbar': toolbar, 'panel': panel};

  factory WbOpacityTokens.fromJson(Map<String, dynamic> json) {
    double read(String key, double fallback) {
      final Object? value = json[key];
      if (value is num) {
        return value.toDouble();
      }
      return fallback;
    }

    return WbOpacityTokens(
      radial: read('radial', standard.radial),
      toolbar: read('toolbar', standard.toolbar),
      panel: read('panel', standard.panel),
    );
  }
}
