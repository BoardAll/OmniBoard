/// 页面模型（对齐 C++ scene::PageRec 的 pageSummary JSON）。
///
/// JSON 形状：
/// ```json
/// {
///   "id": "page-1", "name": "页面 1", "locked": false, "hidden": false,
///   "background": {}, "elementCount": 0, "createdAt": 0
/// }
/// ```
class WbPage {
  const WbPage({
    required this.id,
    this.name = '',
    this.locked = false,
    this.hidden = false,
    this.background = const <String, dynamic>{},
    this.elementCount = 0,
    this.createdAt = 0,
  });

  final String id;
  final String name;
  final bool locked;
  final bool hidden;

  /// 背景配置原始 JSON（preset/color/grid 等，见 background 域）。
  final Map<String, dynamic> background;

  /// 元素数量（页面列表摘要用）。
  final int elementCount;

  /// 创建时间（毫秒时间戳）。
  final int createdAt;

  factory WbPage.fromJson(Map<String, dynamic> json) {
    final Object? background = json['background'];
    return WbPage(
      id: json['id'] is String ? json['id'] as String : '',
      name: json['name'] is String ? json['name'] as String : '',
      locked: json['locked'] is bool ? json['locked'] as bool : false,
      hidden: json['hidden'] is bool ? json['hidden'] as bool : false,
      background: background is Map
          ? Map<String, dynamic>.from(background)
          : const <String, dynamic>{},
      elementCount:
          json['elementCount'] is num ? (json['elementCount'] as num).toInt() : 0,
      createdAt: json['createdAt'] is num ? (json['createdAt'] as num).toInt() : 0,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'locked': locked,
        'hidden': hidden,
        'background': background,
        'elementCount': elementCount,
        'createdAt': createdAt,
      };

  WbPage copyWith({
    String? name,
    bool? locked,
    bool? hidden,
    Map<String, dynamic>? background,
    int? elementCount,
  }) {
    return WbPage(
      id: id,
      name: name ?? this.name,
      locked: locked ?? this.locked,
      hidden: hidden ?? this.hidden,
      background: background ?? this.background,
      elementCount: elementCount ?? this.elementCount,
      createdAt: createdAt,
    );
  }

  @override
  String toString() => 'WbPage($id, $name)';
}
