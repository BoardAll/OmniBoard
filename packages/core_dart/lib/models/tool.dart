import 'dart:convert';

/// 工具描述模型（对齐 tool_registry 的 `tools` 数组项）。
class WbTool {
  const WbTool({
    required this.id,
    this.name = '',
    this.category = '',
    this.description = '',
    this.icon = '',
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String name;

  /// 工具分组（edit/view/insert/...）。
  final String category;
  final String description;
  final String icon;

  final Map<String, dynamic> raw;

  factory WbTool.fromJson(Map<String, dynamic> json) {
    String readStr(Object? value) => value is String ? value : '';
    return WbTool(
      id: readStr(json['id']),
      name: readStr(json['name']),
      category: readStr(json['category']),
      description: readStr(json['description']),
      icon: readStr(json['icon']),
      raw: json,
    );
  }

  /// 解析 `wb_tool_list` 返回的 tools 数组。
  static List<WbTool> listFromJson(Object? value) {
    if (value is! List) {
      return const <WbTool>[];
    }
    return value
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> m) =>
            WbTool.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'id': id,
          'name': name,
          'category': category,
          'description': description,
          'icon': icon,
        };

  @override
  String toString() => 'WbTool($id, $name)';
}

/// 工具参数 schema 的轻量包装（`wb_tool_get` 的 argsSchema 字段）。
class WbToolSchema {
  const WbToolSchema({required this.tool, this.argsSchema = const {}});

  final WbTool tool;
  final Map<String, dynamic> argsSchema;

  factory WbToolSchema.fromJson(Map<String, dynamic> json) {
    final Object? schema = json['argsSchema'] ?? json['schema'];
    return WbToolSchema(
      tool: WbTool.fromJson(json),
      argsSchema: schema is Map
          ? Map<String, dynamic>.from(schema)
          : <String, dynamic>{},
    );
  }

  /// 便于把 schema 转成 JSON Schema 字符串（调试/文档用）。
  String encodeSchema() => jsonEncode(argsSchema);
}
