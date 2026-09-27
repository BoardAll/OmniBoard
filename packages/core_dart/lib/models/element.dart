/// 元素模型（对齐 C++ scene 元素 JSON；保留 [raw] 供类型专属字段透传）。
///
/// JSON 形状（节选）：
/// ```json
/// {
///   "id": "element-1", "type": "note",
///   "position": { "x": 0.0, "y": 0.0 },
///   "size": { "width": 200.0, "height": 120.0 },
///   "zIndex": 0, "rotation": 0.0, "locked": false, "visible": true
/// }
/// ```
class WbElement {
  const WbElement({
    required this.id,
    required this.type,
    this.x = 0,
    this.y = 0,
    this.width = 0,
    this.height = 0,
    this.zIndex = 0,
    this.rotation = 0,
    this.locked = false,
    this.visible = true,
    this.raw = const <String, dynamic>{},
  });

  final String id;

  /// 元素类型（note/shape/image/connector/flowchart/table/3d/function 等）。
  final String type;
  final double x;
  final double y;
  final double width;
  final double height;
  final int zIndex;

  /// 旋转弧度（0 表示不旋转）。
  final double rotation;
  final bool locked;
  final bool visible;

  /// 完整原始 JSON（含类型专属字段，如文本、样式、points）。
  final Map<String, dynamic> raw;

  factory WbElement.fromJson(Map<String, dynamic> json) {
    final Object? position = json['position'];
    final Object? size = json['size'];
    double readMap(Object? map, String key) {
      if (map is Map && map[key] is num) {
        return (map[key] as num).toDouble();
      }
      return 0;
    }

    return WbElement(
      id: json['id'] is String ? json['id'] as String : '',
      type: json['type'] is String ? json['type'] as String : '',
      x: readMap(position, 'x'),
      y: readMap(position, 'y'),
      width: readMap(size, 'width'),
      height: readMap(size, 'height'),
      zIndex: json['zIndex'] is num ? (json['zIndex'] as num).toInt() : 0,
      rotation: json['rotation'] is num ? (json['rotation'] as num).toDouble() : 0,
      locked: json['locked'] is bool ? json['locked'] as bool : false,
      visible: json['visible'] is bool ? json['visible'] as bool : true,
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'id': id,
          'type': type,
          'position': <String, double>{'x': x, 'y': y},
          'size': <String, double>{'width': width, 'height': height},
          'zIndex': zIndex,
          'rotation': rotation,
          'locked': locked,
          'visible': visible,
        };

  /// 读取类型专属字段（缺失返回 null）。
  Object? operator [](String key) => raw[key];

  @override
  String toString() => 'WbElement($id, $type, ${width}x$height)';
}
