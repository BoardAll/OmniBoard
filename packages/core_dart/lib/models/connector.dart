/// 连接线模型（对齐流程图/连接器 JSON：`from` / `to` 引用元素 id）。
class WbConnector {
  const WbConnector({
    required this.id,
    this.fromElementId = '',
    this.toElementId = '',
    this.style = const <String, dynamic>{},
    this.label = '',
    this.raw = const <String, dynamic>{},
  });

  final String id;

  /// 起点元素 id（JSON 键 `from`）。
  final String fromElementId;

  /// 终点元素 id（JSON 键 `to`）。
  final String toElementId;

  /// 线型样式（箭头/虚线/颜色等）。
  final Map<String, dynamic> style;

  /// 标注文字（分支标签等）。
  final String label;

  final Map<String, dynamic> raw;

  factory WbConnector.fromJson(Map<String, dynamic> json) {
    final Object? style = json['style'];
    String readRef(Object? value) {
      if (value is String) {
        return value;
      }
      // 兼容 {"from": {"elementId": ...}} 形式。
      if (value is Map && value['elementId'] is String) {
        return value['elementId'] as String;
      }
      return '';
    }

    return WbConnector(
      id: json['id'] is String ? json['id'] as String : '',
      fromElementId: readRef(json['from']),
      toElementId: readRef(json['to']),
      style: style is Map
          ? Map<String, dynamic>.from(style)
          : const <String, dynamic>{},
      label: json['label'] is String ? json['label'] as String : '',
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'id': id,
          'from': fromElementId,
          'to': toElementId,
          'style': style,
          'label': label,
        };

  @override
  String toString() => 'WbConnector($id: $fromElementId -> $toElementId)';
}
