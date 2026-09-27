import 'page.dart';

/// 白板模型（对齐 C++ `wb_board_get` / board summary JSON）。
///
/// JSON 形状：
/// ```json
/// {
///   "id": "board-1", "handle": 1, "name": "未命名白板", "createdAt": 0,
///   "pageCount": 1, "pages": [{ "id": "page-1", ... }]
/// }
/// ```
class WbBoard {
  const WbBoard({
    required this.id,
    this.handle = 0,
    this.name = '',
    this.createdAt = 0,
    this.pages = const <WbPage>[],
  });

  final String id;

  /// 引擎侧 uint64 句柄（0 表示未从引擎加载）。
  final int handle;
  final String name;
  final int createdAt;

  /// 页面摘要列表。
  final List<WbPage> pages;

  /// 页面数量（优先取 `pageCount`，缺失时用 [pages] 长度）。
  int get pageCount => pages.length;

  factory WbBoard.fromJson(Map<String, dynamic> json) {
    return WbBoard(
      id: json['id'] is String ? json['id'] as String : '',
      handle: json['handle'] is num ? (json['handle'] as num).toInt() : 0,
      name: json['name'] is String ? json['name'] as String : '',
      createdAt: json['createdAt'] is num ? (json['createdAt'] as num).toInt() : 0,
      pages: json['pages'] is List
          ? (json['pages'] as List<dynamic>)
              .whereType<Map<dynamic, dynamic>>()
              .map((Map<dynamic, dynamic> m) =>
                  WbPage.fromJson(Map<String, dynamic>.from(m)))
              .toList()
          : const <WbPage>[],
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'handle': handle,
        'name': name,
        'createdAt': createdAt,
        'pageCount': pages.length,
        'pages': pages.map((WbPage p) => p.toJson()).toList(),
      };

  WbBoard copyWith({String? name, List<WbPage>? pages}) {
    return WbBoard(
      id: id,
      handle: handle,
      name: name ?? this.name,
      createdAt: createdAt,
      pages: pages ?? this.pages,
    );
  }

  @override
  String toString() => 'WbBoard($id, $name, ${pages.length} pages)';
}
