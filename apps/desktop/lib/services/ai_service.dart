/// AI 应用服务：组合 Dart 侧 AI SDK 与引擎侧 AI 域。
library;

import 'package:whiteboard_ai/ai_client.dart';

import 'ai_tools.dart';
import 'ffi_service.dart';

/// AI 服务装配器。
///
/// - Dart 侧：[AiClient] 负责模型路由 / 流式对话 / 工具调用草稿；
/// - 引擎侧：`WbAiService`（FFI）负责会话登记与工具执行确认（审计）。
///
/// 未 [configure] 提供商时 [isConfigured] 为 false，UI 应展示配置引导。
class WbAiAppService {
  WbAiAppService({required WbFfiService ffi}) : _ffi = ffi;

  /// 默认系统提示（《AI 助手与 MCP 设计》§3.3 确认级别由引擎工具元数据驱动）。
  ///
  /// 明确要求以工具调用完成白板编辑，避免模型将坐标 / JSON 数据直接
  /// 输出到对话正文（工具未注册时会出现该降级行为）。
  static const String defaultSystemPrompt =
      '你是白板 AI 助手。所有白板编辑（创建 / 修改 / 移动 / 删除元素）'
      '必须通过工具调用完成，不要在回复正文中输出坐标、JSON 或绘图数据；'
      '无法用工具完成的请求应如实说明。危险操作必须先给出预览并等待用户确认。';

  final WbFfiService _ffi;
  AiProvider? _provider;
  AiClient? _client;

  /// 当前提供商（未配置返回 null）。
  AiProvider? get provider => _provider;

  /// 是否已配置模型提供商。
  bool get isConfigured => _client != null;

  /// 当前会话客户端（未配置返回 null）。
  AiClient? get client => _client;

  /// 引擎侧 AI 域是否可用（会话登记走 FFI 时需要）。
  bool get engineAvailable => _ffi.isAvailable;

  /// 配置模型提供商（OpenAI / Anthropic / 自定义网关）。
  ///
  /// 同时注册白板内置工具（[WbBoardTools.definitions]），模型据此返回
  /// 结构化工具调用而非正文坐标文本。
  void configure(
    AiProvider provider, {
    String systemPrompt = defaultSystemPrompt,
  }) {
    _provider = provider;
    _client = AiClient(
      provider: provider,
      systemPrompt: systemPrompt,
      tools: WbBoardTools.definitions,
    );
  }

  /// 发送一条消息（非流式）；返回助手回复。
  ///
  /// 未配置提供商时抛 [StateError]。
  Future<AiMessage> send(String text) {
    final AiClient client = _require();
    return client.send(text);
  }

  /// 发送一条消息（流式事件）；未配置提供商时抛 [StateError]。
  Stream<AiStreamEvent> stream(String text) => _require().stream(text);

  /// 更新会话上下文（页面 / 选区范围，§4.4）。
  void updateContext(AiContext context) => _client?.updateContext(context);

  /// 登记引擎侧 AI 会话（引擎不可用时返回 null）。
  Map<String, dynamic>? openEngineSession(
    String boardId, {
    String userId = 'local-user',
  }) {
    if (!_ffi.isAvailable) {
      return null;
    }
    return _ffi.ai.sessionCreate(boardId, userId);
  }

  /// 关闭引擎侧 AI 会话（引擎不可用 / 无会话时 no-op）。
  void closeEngineSession(String sessionId) {
    if (!_ffi.isAvailable || sessionId.isEmpty) {
      return;
    }
    _ffi.ai.sessionClose(sessionId);
  }

  /// 重置对话（保留提供商配置）。
  void reset() => _client?.reset();

  AiClient _require() {
    final AiClient? client = _client;
    if (client == null) {
      throw StateError('AI 提供商未配置，请先在设置中配置模型服务');
    }
    return client;
  }
}
