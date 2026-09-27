/// API 错误模型（《OpenAPI 规范》§4.4 / §4.10）。
library;

/// Open API 错误码（HTTP 状态 → 语义码）。
abstract final class WbApiErrorCodes {
  static const String invalidArgument = 'INVALID_ARGUMENT';
  static const String unauthenticated = 'UNAUTHENTICATED';
  static const String permissionDenied = 'PERMISSION_DENIED';
  static const String notFound = 'NOT_FOUND';
  static const String conflict = 'CONFLICT';
  static const String unprocessable = 'UNPROCESSABLE';
  static const String rateLimited = 'RATE_LIMITED';
  static const String internalError = 'INTERNAL_ERROR';
  static const String unavailable = 'UNAVAILABLE';

  /// HTTP 状态码 → 默认错误码（引擎未给 error.code 时兜底）。
  static String fromStatus(int statusCode) {
    switch (statusCode) {
      case 400:
        return invalidArgument;
      case 401:
        return unauthenticated;
      case 403:
        return permissionDenied;
      case 404:
        return notFound;
      case 409:
        return conflict;
      case 422:
        return unprocessable;
      case 429:
        return rateLimited;
      case 503:
        return unavailable;
      default:
        return statusCode >= 500 ? internalError : invalidArgument;
    }
  }
}

/// 服务端返回的业务错误（`{ok:false, error:{code,message,detail}}`）。
class WbApiException implements Exception {
  const WbApiException({
    required this.code,
    required this.message,
    this.detail,
    this.statusCode = 0,
    this.requestId = '',
  });

  /// 语义错误码，见 [WbApiErrorCodes]。
  final String code;
  final String message;

  /// 更细的说明（如 `scope element:write required`）。
  final String? detail;

  /// HTTP 状态码（0 表示非 HTTP 失败，如解析失败）。
  final int statusCode;

  /// 服务端请求 id（`meta.requestId`），便于排障。
  final String requestId;

  bool get isAuthError =>
      code == WbApiErrorCodes.unauthenticated ||
      code == WbApiErrorCodes.permissionDenied;

  bool get isNotFound => code == WbApiErrorCodes.notFound;

  bool get isRateLimited => code == WbApiErrorCodes.rateLimited;

  @override
  String toString() {
    final String suffix = detail == null || detail!.isEmpty ? '' : ' ($detail)';
    return 'WbApiException($statusCode $code): $message$suffix';
  }
}

/// 网络层失败（连接超时 / DNS / TLS 等，未收到 HTTP 响应）。
class WbNetworkException implements Exception {
  const WbNetworkException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'WbNetworkException: $message';
}
