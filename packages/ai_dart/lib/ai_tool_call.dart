/// AI 工具调用模型（《AI 助手与 MCP 设计》§5.3 / §3.3）。
library;

import 'dart:convert';

/// 工具调用状态（与 C++ `ai_tool_call` 契约一致）。
abstract final class AiToolCallStatus {
  static const String pending = 'pending';
  static const String success = 'success';
  static const String error = 'error';
  static const String cancelled = 'cancelled';
}

/// 确认级别（§3.3）：Auto 直接执行 / Preview 幽灵预览 / Confirm 弹窗确认。
abstract final class AiConfirmLevels {
  static const String auto = 'auto';
  static const String preview = 'preview';
  static const String confirm = 'confirm';
}

/// 一次工具调用（每个调用生成一个命令，可合并为事务）。
class AiToolCall {
  const AiToolCall({
    this.id = '',
    this.toolId = '',
    this.name = '',
    this.arguments = const <String, dynamic>{},
    this.result = const <String, dynamic>{},
    this.status = AiToolCallStatus.pending,
    this.error = '',
    this.preview = const <String, dynamic>{},
    this.confirmLevel = AiConfirmLevels.auto,
    this.confirmationId = '',
    this.timestamp,
  });

  /// 调用 id（模型侧生成，如 `call_abc`）。
  final String id;

  /// 工具 id（如 `element.create`）。
  final String toolId;

  /// 工具名（如 `element_create`，与 MCP 命名映射一致）。
  final String name;

  /// 调用参数。
  final Map<String, dynamic> arguments;

  /// 执行结果（成功时）。
  final Map<String, dynamic> result;

  /// pending / success / error / cancelled。
  final String status;

  /// 错误信息（失败时）。
  final String error;

  /// 预览数据（Dry Run / 幽灵预览）。
  final Map<String, dynamic> preview;

  /// 确认级别（auto / preview / confirm）。
  final String confirmLevel;

  /// 需确认时服务端下发的确认 id。
  final String confirmationId;

  final DateTime? timestamp;

  bool get isPending => status == AiToolCallStatus.pending;

  bool get isSuccess => status == AiToolCallStatus.success;

  bool get isError => status == AiToolCallStatus.error;

  /// 是否需用户确认（Preview / Confirm 级别且尚未执行）。
  bool get requiresConfirmation =>
      isPending &&
      (confirmLevel == AiConfirmLevels.preview ||
          confirmLevel == AiConfirmLevels.confirm);

  /// 参数 JSON 串（FFI 契约字段 `argsJson`）。
  String get argsJson => jsonEncode(arguments);

  /// 结果 JSON 串（FFI 契约字段 `resultJson`）。
  String get resultJson => jsonEncode(result);

  AiToolCall copyWith({
    String? status,
    Map<String, dynamic>? result,
    String? error,
    Map<String, dynamic>? preview,
    String? confirmationId,
  }) {
    return AiToolCall(
      id: id,
      toolId: toolId,
      name: name,
      arguments: arguments,
      result: result ?? this.result,
      status: status ?? this.status,
      error: error ?? this.error,
      preview: preview ?? this.preview,
      confirmLevel: confirmLevel,
      confirmationId: confirmationId ?? this.confirmationId,
      timestamp: timestamp,
    );
  }

  factory AiToolCall.fromJson(Map<String, dynamic> json) {
    String readStr(String key) =>
        json[key] is String ? json[key] as String : '';
    Map<String, dynamic> readMap(String key) =>
        json[key] is Map ? Map<String, dynamic>.from(json[key] as Map) : const <String, dynamic>{};
    // 兼容 `argsJson` / `resultJson` 字符串字段。
    Map<String, dynamic> readJsonStringOrMap(String key, String jsonKey) {
      final Object? direct = json[key];
      if (direct is Map) {
        return Map<String, dynamic>.from(direct);
      }
      final Object? raw = json[jsonKey];
      if (raw is String && raw.trim().isNotEmpty) {
        try {
          final Object? decoded = jsonDecode(raw);
          if (decoded is Map) {
            return Map<String, dynamic>.from(decoded);
          }
        } on FormatException {
          // 忽略无法解析的字符串。
        }
      }
      return const <String, dynamic>{};
    }

    final String toolId =
        readStr('toolId').isNotEmpty ? readStr('toolId') : readStr('tool_id');
    return AiToolCall(
      id: readStr('id'),
      toolId: toolId,
      name: readStr('name'),
      arguments: readJsonStringOrMap('arguments', 'argsJson'),
      result: readJsonStringOrMap('result', 'resultJson'),
      status: readStr('status').isNotEmpty
          ? readStr('status')
          : AiToolCallStatus.pending,
      error: readStr('error'),
      preview: readMap('preview'),
      confirmLevel: readStr('confirmLevel').isNotEmpty
          ? readStr('confirmLevel')
          : AiConfirmLevels.auto,
      confirmationId: readStr('confirmationId'),
      timestamp: _parseTimestamp(json['timestamp']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'toolId': toolId,
        'name': name,
        'arguments': arguments,
        'result': result,
        'status': status,
        if (error.isNotEmpty) 'error': error,
        if (preview.isNotEmpty) 'preview': preview,
        'confirmLevel': confirmLevel,
        if (confirmationId.isNotEmpty) 'confirmationId': confirmationId,
        if (timestamp != null) 'timestamp': timestamp!.toIso8601String(),
      };

  @override
  String toString() => 'AiToolCall($id, $name, $status)';
}

DateTime? _parseTimestamp(Object? value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value);
  }
  return null;
}
