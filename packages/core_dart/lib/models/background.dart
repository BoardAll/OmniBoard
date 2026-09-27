/// 画布背景模型（对齐 background 域的 preset JSON）。
///
/// JSON 形状（节选）：
/// ```json
/// { "preset": "grid", "type": "pattern", "color": "#F7F8FA", "grid": {...} }
/// ```
class WbBackground {
  const WbBackground({
    this.preset = '',
    this.type = '',
    this.color = '',
    this.raw = const <String, dynamic>{},
  });

  /// 预设 id（grid/dots/graph/...）。
  final String preset;

  /// 背景类型（color/pattern/image）。
  final String type;

  /// 底色（`#RRGGBB`）。
  final String color;

  final Map<String, dynamic> raw;

  factory WbBackground.fromJson(Map<String, dynamic> json) {
    String readStr(Object? value) => value is String ? value : '';
    return WbBackground(
      preset: readStr(json['preset']),
      type: readStr(json['type']),
      color: readStr(json['color']),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{'preset': preset, 'type': type, 'color': color};

  /// 解析预设列表（`background list` 的 presets 数组）。
  static List<WbBackground> listFromJson(Object? value) {
    if (value is! List) {
      return const <WbBackground>[];
    }
    return value
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> m) =>
            WbBackground.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  @override
  String toString() => 'WbBackground($preset, $type)';
}
