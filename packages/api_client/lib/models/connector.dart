/// 连线模型（Open API §5.4）。
class WbApiConnector {
  const WbApiConnector({
    required this.id,
    this.pageId = '',
    this.fromElementId = '',
    this.toElementId = '',
    this.fromAnchor = '',
    this.toAnchor = '',
    this.style = '',
    this.arrowEnd = '',
    this.label = '',
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String pageId;
  final String fromElementId;
  final String toElementId;

  /// 起点锚点（top / right / bottom / left / center）。
  final String fromAnchor;

  /// 终点锚点。
  final String toAnchor;

  /// 线型（straight / orthogonal / curve）。
  final String style;

  /// 终点箭头（none / solid / open）。
  final String arrowEnd;

  /// 连线标签（如分支标注「是 / 否」）。
  final String label;

  final Map<String, dynamic> raw;

  factory WbApiConnector.fromJson(Map<String, dynamic> json) {
    String readStr(String key) => json[key] is String ? json[key] as String : '';
    return WbApiConnector(
      id: readStr('id'),
      pageId: readStr('pageId'),
      fromElementId: readStr('fromElementId'),
      toElementId: readStr('toElementId'),
      fromAnchor: readStr('fromAnchor'),
      toAnchor: readStr('toAnchor'),
      style: readStr('style'),
      arrowEnd: readStr('arrowEnd'),
      label: readStr('label'),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'id': id,
          'pageId': pageId,
          'fromElementId': fromElementId,
          'toElementId': toElementId,
          'fromAnchor': fromAnchor,
          'toAnchor': toAnchor,
          'style': style,
          'arrowEnd': arrowEnd,
          'label': label,
        };

  @override
  String toString() => 'WbApiConnector($id, $fromElementId->$toElementId)';
}

/// 创建连线请求体（`POST /pages/{pageId}/connectors`）。
class WbApiConnectorDraft {
  const WbApiConnectorDraft({
    required this.fromElementId,
    required this.toElementId,
    this.fromAnchor = '',
    this.toAnchor = '',
    this.style = '',
    this.arrowEnd = '',
    this.label = '',
  });

  final String fromElementId;
  final String toElementId;
  final String fromAnchor;
  final String toAnchor;
  final String style;
  final String arrowEnd;
  final String label;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'fromElementId': fromElementId,
        'toElementId': toElementId,
        if (fromAnchor.isNotEmpty) 'fromAnchor': fromAnchor,
        if (toAnchor.isNotEmpty) 'toAnchor': toAnchor,
        if (style.isNotEmpty) 'style': style,
        if (arrowEnd.isNotEmpty) 'arrowEnd': arrowEnd,
        if (label.isNotEmpty) 'label': label,
      };
}
