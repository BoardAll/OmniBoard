/// 自定义 / 自托管端点 Provider（《AI 助手与 MCP 设计》§5.2、
/// 企业本地模型与 AI Gateway 接入）。
///
/// 复用 OpenAI 兼容线协议，仅替换基地址、身份头与默认模型，例如：
///
/// ```dart
/// final provider = CustomProvider(
///   baseUrl: 'http://localhost:8080/v1',   // 白板 AI Gateway
///   headers: {'X-WB-Token': token},
///   model: 'internal-large',
/// );
/// ```
library;

import 'openai_provider.dart';

/// OpenAI 兼容的自定义端点 Provider。
class CustomProvider extends OpenAiProvider {
  CustomProvider({
    required super.baseUrl,
    String id = 'custom',
    super.apiKey,
    super.model,
    super.organization,
    super.headers,
    super.transcriptionModel,
    super.speechModel,
    super.speechVoice,
    super.httpClient,
  }) : _id = id;

  final String _id;

  @override
  String get id => _id;
}
