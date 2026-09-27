"""Custom Provider —— OpenAI 兼容端点（Ollama / vLLM / 自托管网关）。

- 不依赖厂商 SDK，使用 ``httpx``（服务基础依赖，同样函数级惰性导入）。
- 未配置端点（``WB_CUSTOM_LLM_BASE_URL``）→ ``ProviderNotConfigured``（HTTP 503）。
- ``client_factory`` 可注入（测试用 ``httpx.MockTransport`` 全离线覆盖）。
- API Key 可选（本地端点常无鉴权）；存在时以 ``Authorization: Bearer`` 发送，绝不记录。
"""

from __future__ import annotations

import json
import os
from typing import Any, AsyncIterator, Callable

from ..errors import ProviderNotConfigured, ProviderNotInstalled, UpstreamError
from . import (
    ChatChunk,
    ChatRequest,
    ChatResponse,
    EmbeddingRequest,
    EmbeddingResponse,
    sdk_installed,
)

DEFAULT_MODEL = "default"
BASE_URL_ENV = "WB_CUSTOM_LLM_BASE_URL"
API_KEY_ENV = "WB_CUSTOM_LLM_API_KEY"

ClientFactory = Callable[[], Any]


def _get(obj: Any, name: str, default: Any = None) -> Any:
    if obj is None:
        return default
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


class CustomProvider:
    """OpenAI 兼容 HTTP 端点 Provider。"""

    name = "custom"

    def __init__(
        self,
        *,
        base_url: str | None = None,
        api_key: str | None = None,
        model: str | None = None,
        base_url_env: str = BASE_URL_ENV,
        api_key_env: str = API_KEY_ENV,
        client_factory: ClientFactory | None = None,
        timeout: float = 60.0,
    ) -> None:
        self._base_url = base_url
        self._api_key = api_key
        self.base_url_env = base_url_env
        self.api_key_env = api_key_env
        self.model = model or os.environ.get("WB_CUSTOM_LLM_MODEL") or DEFAULT_MODEL
        self._client_factory = client_factory
        self.timeout = timeout

    # —— 配置与可用性 ——

    @property
    def base_url(self) -> str:
        return (self._base_url or os.environ.get(self.base_url_env) or "").rstrip("/")

    def resolve_api_key(self) -> str | None:
        return self._api_key or os.environ.get(self.api_key_env) or None

    def availability(self) -> dict[str, Any]:
        return {
            "provider": self.name,
            "installed": sdk_installed("httpx"),
            "configured": bool(self.base_url),
        }

    def _client(self) -> Any:
        if not sdk_installed("httpx"):
            raise ProviderNotInstalled("httpx")
        if not self.base_url:
            raise ProviderNotConfigured(
                self.name, self.base_url_env, "set the OpenAI-compatible endpoint base URL"
            )
        if self._client_factory is not None:
            return self._client_factory()
        import httpx  # noqa: PLC0415 - 函数级惰性导入

        return httpx.AsyncClient(timeout=self.timeout)

    def _headers(self) -> dict[str, str]:
        key = self.resolve_api_key()
        return {"Authorization": f"Bearer {key}"} if key else {}

    # —— 对话 ——

    def _payload(self, request: ChatRequest, *, stream: bool) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": request.model or self.model,
            "messages": [message.model_dump(exclude_none=True) for message in request.messages],
            "stream": stream,
        }
        if request.temperature is not None:
            payload["temperature"] = request.temperature
        if request.max_tokens is not None:
            payload["max_tokens"] = request.max_tokens
        if request.tools:
            payload["tools"] = request.tools
        return payload

    async def chat(self, request: ChatRequest) -> ChatResponse:
        client = self._client()
        async with client as http:
            response = await http.post(
                f"{self.base_url}/chat/completions",
                json=self._payload(request, stream=False),
                headers=self._headers(),
            )
            self._ensure_success(response)
            body = response.json()
        choices = _get(body, "choices", []) or []
        choice = choices[0] if choices else None
        message = _get(choice, "message")
        tool_calls: list[dict[str, Any]] = []
        for call in _get(message, "tool_calls", []) or []:
            function = _get(call, "function")
            tool_calls.append(
                {
                    "id": _get(call, "id"),
                    "name": _get(function, "name"),
                    "arguments": _get(function, "arguments") or "{}",
                }
            )
        return ChatResponse(
            content=_get(message, "content") or "",
            finish_reason=_get(choice, "finish_reason", "stop") or "stop",
            tool_calls=tool_calls,
            usage=self._wire_usage(_get(body, "usage")),
            model=_get(body, "model") or self.model,
        )

    async def stream_chat(self, request: ChatRequest) -> AsyncIterator[ChatChunk]:  # type: ignore[override]
        client = self._client()
        async with client as http:
            async with http.stream(
                "POST",
                f"{self.base_url}/chat/completions",
                json=self._payload(request, stream=True),
                headers=self._headers(),
            ) as response:
                self._ensure_success(response)
                last_finish: str | None = None
                async for line in response.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    data = line[len("data:") :].strip()
                    if data == "[DONE]":
                        break
                    try:
                        event = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    choices = _get(event, "choices", []) or []
                    if not choices:
                        continue
                    choice = choices[0]
                    delta = _get(_get(choice, "delta"), "content")
                    finish = _get(choice, "finish_reason")
                    if finish:
                        last_finish = finish
                    if delta or finish:
                        yield ChatChunk(delta=delta or "", finish_reason=finish)
        if last_finish is None:
            yield ChatChunk(delta="", finish_reason="stop")

    # —— Embedding ——

    async def embedding(self, request: EmbeddingRequest) -> EmbeddingResponse:
        client = self._client()
        async with client as http:
            response = await http.post(
                f"{self.base_url}/embeddings",
                json={"model": request.model or self.model, "input": request.input},
                headers=self._headers(),
            )
            self._ensure_success(response)
            body = response.json()
        data = _get(body, "data", []) or []
        embeddings = [list(_get(item, "embedding", []) or []) for item in data]
        return EmbeddingResponse(
            embeddings=embeddings,
            model=_get(body, "model") or self.model,
            usage=self._wire_usage(_get(body, "usage")),
        )

    # —— 内部 ——

    @staticmethod
    def _ensure_success(response: Any) -> None:
        status = int(getattr(response, "status_code", 0))
        if status >= 400:
            raise UpstreamError("custom", f"HTTP {status}")

    @staticmethod
    def _wire_usage(usage: Any) -> dict[str, int] | None:
        if usage is None:
            return None
        prompt = _get(usage, "prompt_tokens")
        completion = _get(usage, "completion_tokens")
        total = _get(usage, "total_tokens")
        if prompt is None and completion is None and total is None:
            return None
        prompt = prompt or 0
        completion = completion or 0
        return {
            "promptTokens": prompt,
            "completionTokens": completion,
            "totalTokens": total if total is not None else prompt + completion,
        }


__all__ = ["CustomProvider", "DEFAULT_MODEL", "BASE_URL_ENV", "API_KEY_ENV"]
