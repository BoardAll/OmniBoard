/// 页面模型（Open API `data` 对象）。
class WbApiPage {
  const WbApiPage({
    required this.id,
    this.boardId = '',
    this.name = '',
    this.backgroundId = '',
    this.index = 0,
    this.createdAt = '',
    this.updatedAt = '',
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String boardId;
  final String name;
  final String backgroundId;

  /// 页面序号（列表顺序）。
  final int index;
  final String createdAt;
  final String updatedAt;

  final Map<String, dynamic> raw;

  factory WbApiPage.fromJson(Map<String, dynamic> json) {
    String readStr(String key) => json[key] is String ? json[key] as String : '';
    return WbApiPage(
      id: readStr('id'),
      boardId: readStr('boardId'),
      name: readStr('name'),
      backgroundId: readStr('backgroundId'),
      index: json['index'] is num ? (json['index'] as num).toInt() : 0,
      createdAt: readStr('createdAt'),
      updatedAt: readStr('updatedAt'),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'id': id,
          'boardId': boardId,
          'name': name,
          'backgroundId': backgroundId,
          'index': index,
          'createdAt': createdAt,
          'updatedAt': updatedAt,
        };

  @override
  String toString() => 'WbApiPage($id, $name)';
}

/// 页面视口（创建页面时可选）。
class WbApiViewport {
  const WbApiViewport({this.x = 0, this.y = 0, this.zoom = 1});

  final double x;
  final double y;
  final double zoom;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'x': x, 'y': y, 'zoom': zoom};

  factory WbApiViewport.fromJson(Map<String, dynamic> json) {
    double readNum(String key) =>
        json[key] is num ? (json[key] as num).toDouble() : 0;
    return WbApiViewport(
      x: readNum('x'),
      y: readNum('y'),
      zoom: json['zoom'] is num ? (json['zoom'] as num).toDouble() : 1,
    );
  }
}
