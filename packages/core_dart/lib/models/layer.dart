/// 图层模型（侧栏图层区使用；对齐 layer 域 JSON）。
class WbLayer {
  const WbLayer({
    required this.id,
    this.name = '',
    this.visible = true,
    this.locked = false,
    this.order = 0,
    this.elementIds = const <String>[],
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String name;
  final bool visible;
  final bool locked;

  /// 叠放顺序（越大越靠上）。
  final int order;

  /// 图层内元素 id 列表。
  final List<String> elementIds;

  final Map<String, dynamic> raw;

  factory WbLayer.fromJson(Map<String, dynamic> json) {
    final Object? elementIds = json['elementIds'];
    final List<String> ids = elementIds is List
        ? elementIds.whereType<String>().toList()
        : const <String>[];
    return WbLayer(
      id: json['id'] is String ? json['id'] as String : '',
      name: json['name'] is String ? json['name'] as String : '',
      visible: json['visible'] is bool ? json['visible'] as bool : true,
      locked: json['locked'] is bool ? json['locked'] as bool : false,
      order: json['order'] is num ? (json['order'] as num).toInt() : 0,
      elementIds: ids,
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'id': id,
          'name': name,
          'visible': visible,
          'locked': locked,
          'order': order,
          'elementIds': elementIds,
        };

  @override
  String toString() => 'WbLayer($id, $name, ${elementIds.length} elements)';
}
