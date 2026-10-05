import '../engine.dart';
import '../utils/json_codec.dart';

/// AI 服务：会话生命周期 / 消息 / 语音 / 工具调用确认（ai 域）。
///
/// 与用户操作共用同一工具箱（tool 域），工具调用天然带审计轨迹。
class WbAiService {
  const WbAiService(this.ffi);

  final WbEngineCaller ffi;

  /// 创建会话（返回 `{sessionId, boardId, userId, createdAt}`）。
  Map<String, dynamic> sessionCreate(String boardId, String userId) {
    final WbResponse response = WbResponse.parse(
      ffi.call2('wb_ai_session_create', boardId, userId),
    );
    return response.requireResult();
  }

  /// 关闭会话。
  Map<String, dynamic> sessionClose(String sessionId) {
    final WbResponse response = WbResponse.parse(
      ffi.call1('wb_ai_session_close', sessionId),
    );
    return response.requireResult();
  }

  /// 会话详情（含 messageCount / context / selection）。
  Map<String, dynamic> sessionGet(String sessionId) {
    final WbResponse response = WbResponse.parse(
      ffi.call1('wb_ai_session_get', sessionId),
    );
    return response.requireResult();
  }

  /// 发送文本消息（FFI 签名仅接受纯文本；toolCalls 由网关侧声明）。
  Map<String, dynamic> sendMessage(String sessionId, String message) {
    final WbResponse response = WbResponse.parse(
      ffi.call2('wb_ai_send_message', sessionId, message),
    );
    return response.requireResult();
  }

  /// 发送语音数据（引擎登记音频消息）。
  Map<String, dynamic> sendAudio(String sessionId, String audioData) {
    final WbResponse response = WbResponse.parse(
      ffi.call2('wb_ai_send_audio', sessionId, audioData),
    );
    return response.requireResult();
  }

  /// 会话消息列表。
  List<Map<String, dynamic>> listMessages(String sessionId) {
    final WbResponse response = WbResponse.parse(
      ffi.call1('wb_ai_list_messages', sessionId),
    );
    final Map<String, dynamic> result = response.requireResult();
    final List<dynamic> raw =
        result['messages'] is List ? result['messages'] as List<dynamic> : const <dynamic>[];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> item) =>
            item.map((dynamic k, dynamic v) => MapEntry<String, dynamic>('$k', v)))
        .toList(growable: false);
  }

  /// 执行待确认的工具调用。
  Map<String, dynamic> executeToolCall(String sessionId, String toolCallId) {
    final WbResponse response = WbResponse.parse(
      ffi.call2('wb_ai_execute_tool_call', sessionId, toolCallId),
    );
    return response.requireResult();
  }

  /// 预览工具调用效果（不落盘）。
  Map<String, dynamic> previewToolCall(String sessionId, String toolCallId) {
    final WbResponse response = WbResponse.parse(
      ffi.call2('wb_ai_preview_tool_call', sessionId, toolCallId),
    );
    return response.requireResult();
  }

  /// 取消工具调用。
  Map<String, dynamic> cancelToolCall(String sessionId, String toolCallId) {
    final WbResponse response = WbResponse.parse(
      ffi.call2('wb_ai_cancel_tool_call', sessionId, toolCallId),
    );
    return response.requireResult();
  }

  /// 更新会话上下文（页面 / 选区等）。
  Map<String, dynamic> setContext(
    String sessionId, [
    Map<String, dynamic> context = const <String, dynamic>{},
  ]) {
    final WbResponse response = WbResponse.parse(
      ffi.call2(
        'wb_ai_set_context',
        sessionId,
        WbJsonCodec.encode(context),
      ),
    );
    return response.requireResult();
  }
}
