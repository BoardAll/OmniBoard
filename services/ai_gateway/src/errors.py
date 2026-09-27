"""统一错误模型与响应信封（Wave 2.9）。

所有 HTTP 响应均为 JSON：

- 成功：``{"ok": true, "data": ..., "error": null}``
- 失败：``{"ok": false, "data": null, "error": {"code": ..., "message": ..., ["details": {...}]}}``

``error.code`` 对齐契约 ``core/tools/schema/command.schema.json`` 的枚举：

    Ok / InvalidArgument / NotFound / PermissionDenied / Conflict /
    InternalError / NotSupported / Timeout / Cancelled / ResourceExhausted

并按《OpenAPI规范》§4.10（503 ``UNAVAILABLE``）补充传输层扩展码 ``Unavailable``(503)
与 ``RateLimited``(429)。

降级语义：
- SDK 未安装（惰性导入失败）        → 501 NotSupported（ProviderNotInstalled）
- SDK 已装但缺少配置（key/endpoint）→ 503 Unavailable（ProviderNotConfigured）
"""

from __future__ import annotations

from typing import Any

# —— command.schema.json error.code 枚举 ——
OK = "Ok"
INVALID_ARGUMENT = "InvalidArgument"
NOT_FOUND = "NotFound"
PERMISSION_DENIED = "PermissionDenied"
CONFLICT = "Conflict"
INTERNAL_ERROR = "InternalError"
NOT_SUPPORTED = "NotSupported"
TIMEOUT = "Timeout"
CANCELLED = "Cancelled"
RESOURCE_EXHAUSTED = "ResourceExhausted"
# —— 传输层扩展码（OpenAPI §4.10） ——
UNAVAILABLE = "Unavailable"
RATE_LIMITED = "RateLimited"


class ApiError(Exception):
    """业务/传输错误；由 app 层统一转换为 JSON 错误信封。"""

    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.details = details

    def to_error(self) -> dict[str, Any]:
        payload: dict[str, Any] = {"code": self.code, "message": self.message}
        if self.details is not None:
            payload["details"] = self.details
        return payload


class ProviderError(ApiError):
    """Provider / ASR / TTS 依赖不可用或未配置。"""


class ProviderNotInstalled(ProviderError):
    """SDK 未安装（惰性导入失败）→ 501 NotSupported。"""

    def __init__(self, sdk: str, hint: str = "") -> None:
        message = f"{sdk} is not installed"
        if hint:
            message = f"{message}; {hint}"
        super().__init__(501, NOT_SUPPORTED, message, {"sdk": sdk})


class ProviderNotConfigured(ProviderError):
    """SDK 已安装但缺少配置（API key / endpoint）→ 503 Unavailable。"""

    def __init__(self, name: str, missing: str, hint: str = "") -> None:
        message = f"{name} is not configured: missing {missing}"
        if hint:
            message = f"{message}; {hint}"
        super().__init__(503, UNAVAILABLE, message, {"missing": missing})


class UpstreamError(ApiError):
    """调用上游服务（Provider HTTP 端点 / 板端 API）失败 → 502。"""

    def __init__(self, name: str, reason: str) -> None:
        super().__init__(502, INTERNAL_ERROR, f"upstream {name} request failed ({reason})")


def ok_body(data: Any) -> dict[str, Any]:
    """成功信封（OpenAPI §4.4）。"""
    return {"ok": True, "data": data, "error": None}


def error_body(error: ApiError) -> dict[str, Any]:
    """失败信封（OpenAPI §4.4）。"""
    return {"ok": False, "data": None, "error": error.to_error()}


__all__ = [
    "OK",
    "INVALID_ARGUMENT",
    "NOT_FOUND",
    "PERMISSION_DENIED",
    "CONFLICT",
    "INTERNAL_ERROR",
    "NOT_SUPPORTED",
    "TIMEOUT",
    "CANCELLED",
    "RESOURCE_EXHAUSTED",
    "UNAVAILABLE",
    "RATE_LIMITED",
    "ApiError",
    "ProviderError",
    "ProviderNotInstalled",
    "ProviderNotConfigured",
    "UpstreamError",
    "ok_body",
    "error_body",
]
