import 'dart:convert';

/// JSON 编解码封装（C++ FFI 的全部输入/输出均为 UTF-8 JSON 字符串）。
abstract final class WbJsonCodec {
  /// 编码为 JSON 字符串。
  static String encode(Map<String, dynamic> data) => jsonEncode(data);

  /// 解码 JSON 对象（顶层必须是对象）。
  static Map<String, dynamic> decode(String json) {
    final Object? decoded = jsonDecode(json);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw const WbCoreException('InvalidJson', 'expected a JSON object');
  }

  /// 宽容解码：失败返回 null。
  static Map<String, dynamic>? tryDecode(String? json) {
    if (json == null || json.isEmpty) {
      return null;
    }
    try {
      return decode(json);
    } on FormatException {
      return null;
    } on WbCoreException {
      return null;
    }
  }

  /// 解码并映射为模型对象。
  static T decodeAs<T>(String json, T Function(Map<String, dynamic>) fromJson) =>
      fromJson(decode(json));

  /// 从 JSON 数组中提取对象列表（宽容：非列表返回空）。
  static List<Map<String, dynamic>> extractList(Object? value) {
    if (value is! List) {
      return const <Map<String, dynamic>>[];
    }
    return value
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> m) => Map<String, dynamic>.from(m))
        .toList();
  }

  /// 从 `{key: {...}}` 外包中取出内层对象（缺失或非对象时原样返回）。
  ///
  /// 引擎多个域以 `{"page": {...}}` / `{"element": {...}}` / `{"theme": {...}}`
  /// 形式包裹实体，这里统一解包。
  static Map<String, dynamic> unwrap(Map<String, dynamic> data, String key) {
    final Object? inner = data[key];
    return inner is Map ? Map<String, dynamic>.from(inner) : data;
  }
}

/// 引擎统一响应信封：`{"ok":true,"result":{...}}` / `{"ok":false,"error":{...}}`。
class WbResponse {
  const WbResponse({required this.ok, this.result, this.code, this.message});

  final bool ok;

  /// 成功时的 `result` 对象（可能为空 map）。
  final Map<String, dynamic>? result;

  /// 失败时的错误码（对齐 wb::ErrorCode，如 `NotFound`）。
  final String? code;

  /// 失败时的错误信息。
  final String? message;

  /// 解析引擎返回的 JSON 信封（宽容：非信封结构按成功对象处理）。
  factory WbResponse.parse(String json) {
    final Map<String, dynamic>? map = WbJsonCodec.tryDecode(json);
    if (map == null) {
      return const WbResponse(
        ok: false,
        code: 'InvalidJson',
        message: 'engine returned invalid JSON',
      );
    }
    final Object? ok = map['ok'];
    if (ok is! bool) {
      // 兼容非信封返回（老版本或直接 result）。
      return WbResponse(ok: true, result: map);
    }
    final Object? error = map['error'];
    final Object? result = map['result'];
    return WbResponse(
      ok: ok,
      result: result is Map ? Map<String, dynamic>.from(result) : null,
      code: error is Map && error['code'] is String
          ? error['code'] as String
          : null,
      message: error is Map && error['message'] is String
          ? error['message'] as String
          : null,
    );
  }

  /// 成功时返回 `result`（空则 `{}`），失败时抛出 [WbCoreException]。
  Map<String, dynamic> requireResult() {
    if (!ok) {
      throw WbCoreException(code ?? 'Internal', message ?? 'engine error');
    }
    return result ?? const <String, dynamic>{};
  }

  /// 返回 `result[key]` 的对象列表（宽容：缺失返回空）。
  List<Map<String, dynamic>> listAt(String key) =>
      WbJsonCodec.extractList(requireResult()[key]);

  @override
  String toString() => ok
      ? 'WbResponse(ok, ${result?.length ?? 0} keys)'
      : 'WbResponse(error: ${code ?? 'Internal'}: ${message ?? ''})';
}

/// 引擎调用异常（携带 wb::ErrorCode 与消息）。
class WbCoreException implements Exception {
  const WbCoreException(this.code, this.message);

  /// 错误码，如 `NotFound` / `InvalidArgument`。
  final String code;
  final String message;

  @override
  String toString() => 'WbCoreException($code): $message';
}
