import 'dart:convert';

import 'theme_data.dart';
import 'theme_pack.dart';

/// 主题 JSON 加载器。
///
/// 支持的输入形状：
/// - 单主题：`{"id": ..., "colors": {...}}`；
/// - 包裹形式：`{"theme": {...}}`；
/// - 主题包：`{"pack": {...}}` 或直接含 `themes` 数组的对象。
abstract final class WbThemeLoader {
  /// 解析单主题 JSON（失败返回 null）。
  static WbThemeData? parse(String source) {
    final Map<String, dynamic>? map = _decodeObject(source);
    if (map == null) {
      return null;
    }
    return fromMap(map);
  }

  /// 从 map 解析单主题（自动解包 `theme` 字段）。
  static WbThemeData fromMap(Map<String, dynamic> map) {
    final Object? wrapped = map['theme'];
    if (wrapped is Map) {
      return WbThemeData.fromJson(Map<String, dynamic>.from(wrapped));
    }
    return WbThemeData.fromJson(map);
  }

  /// 解析主题包 JSON（需含 `themes` 数组，失败返回 null）。
  static WbThemePack? parsePack(String source) {
    final Map<String, dynamic>? map = _decodeObject(source);
    if (map == null) {
      return null;
    }
    final Object? wrapped = map['pack'];
    final Map<String, dynamic> target =
        wrapped is Map ? Map<String, dynamic>.from(wrapped) : map;
    if (target['themes'] is! List) {
      return null;
    }
    return WbThemePack.fromJson(target);
  }

  /// 序列化单主题为 JSON 字符串。
  static String serialize(WbThemeData theme, {bool pretty = false}) {
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(theme.toJson())
        : jsonEncode(theme.toJson());
  }

  /// 序列化主题包为 JSON 字符串。
  static String serializePack(WbThemePack pack, {bool pretty = false}) {
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(pack.toJson())
        : jsonEncode(pack.toJson());
  }

  static Map<String, dynamic>? _decodeObject(String source) {
    try {
      final Object? decoded = jsonDecode(source);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return null;
    } on FormatException {
      return null;
    }
  }
}
