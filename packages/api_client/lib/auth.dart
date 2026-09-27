/// 认证与授权（《OpenAPI 规范》§3）。
library;

/// 认证方式。
enum WbAuthMode {
  /// `Authorization: Bearer <token>`（OAuth 2.0 / JWT）。
  bearer,

  /// `X-API-Key: <key>`（服务端集成）。
  apiKey,
}

/// 认证凭据：Bearer token 或 API Key。
class WbAuth {
  const WbAuth.bearer(this.credential, {this.refreshToken, this.expiresAt})
      : mode = WbAuthMode.bearer;

  const WbAuth.apiKey(this.credential)
      : mode = WbAuthMode.apiKey,
        refreshToken = null,
        expiresAt = null;

  final WbAuthMode mode;
  final String credential;

  /// OAuth refresh token（Access 1 小时 / Refresh 30 天）。
  final String? refreshToken;

  /// Access token 过期时间（null 表示未知）。
  final DateTime? expiresAt;

  /// 是否已过期（未知过期时间视为未过期）。
  bool get isExpired =>
      expiresAt != null && DateTime.now().isAfter(expiresAt!);

  /// 生成请求头。
  Map<String, String> toHeaders() => mode == WbAuthMode.bearer
      ? <String, String>{'Authorization': 'Bearer $credential'}
      : <String, String>{'X-API-Key': credential};

  @override
  String toString() => 'WbAuth(${mode.name}, ${credential.length} chars)';
}

/// Scope 常量（《OpenAPI 规范》§3.3）。
abstract final class WbScopes {
  static const String boardRead = 'board:read';
  static const String boardWrite = 'board:write';
  static const String boardShare = 'board:share';
  static const String pageRead = 'page:read';
  static const String pageWrite = 'page:write';
  static const String elementRead = 'element:read';
  static const String elementWrite = 'element:write';
  static const String connectorRead = 'connector:read';
  static const String connectorWrite = 'connector:write';
  static const String commentRead = 'comment:read';
  static const String commentWrite = 'comment:write';
  static const String exportRead = 'export:read';
  static const String historyRead = 'history:read';
  static const String historyWrite = 'history:write';
  static const String aiInvoke = 'ai:invoke';
  static const String mcpInvoke = 'mcp:invoke';
  static const String adminRead = 'admin:read';
  static const String adminWrite = 'admin:write';
}
