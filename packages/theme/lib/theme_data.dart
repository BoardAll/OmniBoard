import 'package:flutter/material.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import 'theme_tokens.dart';

/// 完整主题模型（与 C++ theme 域 `BuildTheme` 输出结构对齐）。
///
/// JSON 形状：
/// ```json
/// {
///   "id": "clean-professional",
///   "name": "清爽专业",
///   "dark": false,
///   "colors": { "bg.canvas": "#F7F8FA", ... },
///   "radius": { "s": 4, "m": 8, "l": 12 },
///   "opacity": { "radial": 0.9, "toolbar": 0.95, "panel": 1.0 }
/// }
/// ```
class WbThemeData {
  const WbThemeData({
    required this.id,
    required this.name,
    this.dark = false,
    required this.colors,
    this.radius = WbRadiusTokens.standard,
    this.opacity = WbOpacityTokens.standard,
  });

  /// 稳定 id（与 C++ 主题 id 一致，如 `clean-professional`）。
  final String id;

  /// 显示名（中文）。
  final String name;

  /// 是否暗色主题。
  final bool dark;

  final WbThemeColors colors;
  final WbRadiusTokens radius;
  final WbOpacityTokens opacity;

  WbThemeData copyWith({
    String? id,
    String? name,
    bool? dark,
    WbThemeColors? colors,
    WbRadiusTokens? radius,
    WbOpacityTokens? opacity,
  }) {
    return WbThemeData(
      id: id ?? this.id,
      name: name ?? this.name,
      dark: dark ?? this.dark,
      colors: colors ?? this.colors,
      radius: radius ?? this.radius,
      opacity: opacity ?? this.opacity,
    );
  }

  /// 对应 C++ `BuildTheme` 的 JSON 结构。
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'dark': dark,
      'colors': colors.toJson(),
      'radius': radius.toJson(),
      'opacity': opacity.toJson(),
    };
  }

  factory WbThemeData.fromJson(Map<String, dynamic> json) {
    final Object? rawColors = json['colors'];
    final Object? rawRadius = json['radius'];
    final Object? rawOpacity = json['opacity'];
    return WbThemeData(
      id: json['id'] is String ? json['id'] as String : 'custom',
      name: json['name'] is String ? json['name'] as String : '自定义主题',
      dark: json['dark'] is bool ? json['dark'] as bool : false,
      colors: rawColors is Map
          ? WbThemeColors.fromJson(Map<String, dynamic>.from(rawColors))
          : WbThemeColors.lightDefaults,
      radius: rawRadius is Map
          ? WbRadiusTokens.fromJson(Map<String, dynamic>.from(rawRadius))
          : WbRadiusTokens.standard,
      opacity: rawOpacity is Map
          ? WbOpacityTokens.fromJson(Map<String, dynamic>.from(rawOpacity))
          : WbOpacityTokens.standard,
    );
  }

  /// 生成 Flutter [ThemeData]（并把完整 [WbThemeData] 挂进扩展，供 UI 取 token）。
  ThemeData toFlutterThemeData() {
    final Brightness brightness = dark ? Brightness.dark : Brightness.light;
    final Color onSurface = colors.icon;
    final Color onPrimary = WbColorUtils.contrastText(colors.primary);
    final ColorScheme scheme = ColorScheme(
      brightness: brightness,
      primary: colors.primary,
      onPrimary: onPrimary,
      secondary: colors.primary,
      onSecondary: onPrimary,
      error: const Color(0xFFF04438),
      onError: const Color(0xFFFFFFFF),
      surface: colors.elevated,
      onSurface: onSurface,
    );
    final TextTheme textTheme = TextTheme(
      bodySmall: WbTypography.caption.copyWith(color: onSurface),
      bodyMedium: WbTypography.body.copyWith(color: onSurface),
      labelMedium: WbTypography.label.copyWith(color: onSurface),
      titleMedium: WbTypography.title.copyWith(color: onSurface),
      titleLarge: WbTypography.heading.copyWith(color: onSurface),
      headlineMedium: WbTypography.display.copyWith(color: onSurface),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: WbTypography.fontFamily,
      fontFamilyFallback: WbTypography.fontFallback,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors.canvas,
      canvasColor: colors.canvas,
      dividerColor: colors.cardBorder,
      dividerTheme: DividerThemeData(
        color: colors.cardBorder,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: colors.toolbarIcon, size: WbIcon.defaultSize),
      textTheme: textTheme,
      extensions: <ThemeExtension<dynamic>>[WbThemeExtension(this)],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WbThemeData &&
      other.id == id &&
      other.name == name &&
      other.dark == dark &&
      other.colors.toJson().toString() == colors.toJson().toString() &&
      other.radius.toJson().toString() == radius.toJson().toString() &&
      other.opacity.toJson().toString() == opacity.toJson().toString();

  @override
  int get hashCode => Object.hash(id, name, dark, colors.toJson().toString());
}

/// 把 [WbThemeData] 挂到 [ThemeData.extensions]，UI 层可通过
/// `context.wbTheme`（见 theme.dart）直接取完整 token。
class WbThemeExtension extends ThemeExtension<WbThemeExtension> {
  const WbThemeExtension(this.theme);

  final WbThemeData theme;

  @override
  WbThemeExtension copyWith({WbThemeData? theme}) =>
      WbThemeExtension(theme ?? this.theme);

  @override
  WbThemeExtension lerp(ThemeExtension<WbThemeExtension>? other, double t) {
    if (other is! WbThemeExtension) {
      return this;
    }
    return t < 0.5 ? this : other;
  }
}
