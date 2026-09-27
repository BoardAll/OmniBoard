/// 主题规格模型（`wb_theme_list` / `wb_theme_current` 的 JSON 视图）。
///
/// 与 packages/theme 的 `WbThemeData` 对应但保持独立：core_dart 只做
/// 原始 JSON 的类型化读取，不依赖 Flutter 主题包。
///
/// JSON 形状：
/// ```json
/// {
///   "id": "clean-professional", "name": "清爽专业", "dark": false,
///   "colors": { "bg.canvas": "#F7F8FA", "primary": "#3370FF", ... }
/// }
/// ```
class WbThemeSpec {
  const WbThemeSpec({
    required this.id,
    this.name = '',
    this.dark = false,
    this.colors = const <String, String>{},
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String name;
  final bool dark;

  /// 颜色 token（键与 C++ 一致，值形如 `#RRGGBB`）。
  final Map<String, String> colors;

  final Map<String, dynamic> raw;

  factory WbThemeSpec.fromJson(Map<String, dynamic> json) {
    final Object? colors = json['colors'];
    final Map<String, String> parsed = <String, String>{};
    if (colors is Map) {
      colors.forEach((Object? key, Object? value) {
        if (key is String && value is String) {
          parsed[key] = value;
        }
      });
    }
    return WbThemeSpec(
      id: json['id'] is String ? json['id'] as String : '',
      name: json['name'] is String ? json['name'] as String : '',
      dark: json['dark'] is bool ? json['dark'] as bool : false,
      colors: parsed,
      raw: json,
    );
  }

  /// 取序内颜色 token（缺失返回 null）。
  String? colorOf(String key) => colors[key];

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'id': id,
          'name': name,
          'dark': dark,
          'colors': colors,
        };

  /// 解析主题列表（`wb_theme_list` 的 themes 数组）。
  static List<WbThemeSpec> listFromJson(Object? value) {
    if (value is! List) {
      return const <WbThemeSpec>[];
    }
    return value
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> m) =>
            WbThemeSpec.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  @override
  String toString() => 'WbThemeSpec($id, $name, dark=$dark)';
}
