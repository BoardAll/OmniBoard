/// 元素模型（Open API `data` 对象；`raw` 保留类型专属字段）。
class WbApiElement {
  const WbApiElement({
    required this.id,
    required this.type,
    this.pageId = '',
    this.x = 0,
    this.y = 0,
    this.width = 0,
    this.height = 0,
    this.zIndex = 0,
    this.rotation = 0,
    this.groupId = '',
    this.raw = const <String, dynamic>{},
  });

  final String id;

  /// 元素类型：sticky / shape / text / image / connector / flowchart 等。
  final String type;
  final String pageId;
  final double x;
  final double y;
  final double width;
  final double height;
  final int zIndex;
  final double rotation;

  /// 所属分组（空表示未分组）。
  final String groupId;

  final Map<String, dynamic> raw;

  factory WbApiElement.fromJson(Map<String, dynamic> json) {
    final Object? position = json['position'];
    final Object? size = json['size'];
    double readMap(Object? map, String key) {
      if (map is Map && map[key] is num) {
        return (map[key] as num).toDouble();
      }
      return 0;
    }

    return WbApiElement(
      id: json['id'] is String ? json['id'] as String : '',
      type: json['type'] is String ? json['type'] as String : '',
      pageId: json['pageId'] is String ? json['pageId'] as String : '',
      x: readMap(position, 'x'),
      y: readMap(position, 'y'),
      width: readMap(size, 'width'),
      height: readMap(size, 'height'),
      zIndex: json['zIndex'] is num ? (json['zIndex'] as num).toInt() : 0,
      rotation:
          json['rotation'] is num ? (json['rotation'] as num).toDouble() : 0,
      groupId: json['groupId'] is String ? json['groupId'] as String : '',
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'id': id,
          'type': type,
          'pageId': pageId,
          'position': <String, double>{'x': x, 'y': y},
          'size': <String, double>{'width': width, 'height': height},
          'zIndex': zIndex,
          'rotation': rotation,
          if (groupId.isNotEmpty) 'groupId': groupId,
        };

  /// 读取类型专属字段（缺失返回 null）。
  Object? operator [](String key) => raw[key];

  @override
  String toString() => 'WbApiElement($id, $type)';
}

/// 批量化元素操作（`POST /elements/batch` 的单条 op）。
class WbApiElementOp {
  const WbApiElementOp({
    required this.op,
    required this.elementId,
    this.patch = const <String, dynamic>{},
  });

  /// just `create` / `update` / `delete` / `move`。
  final String op;
  final String elementId;
  final Map<String, dynamic> patch;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'op': op,
        'elementId': elementId,
        if (patch.isNotEmpty) 'patch': patch,
      };
}
