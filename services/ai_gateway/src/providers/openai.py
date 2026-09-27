"""OpenAI Provider（``openai`` SDK 函数级惰性导入）。

- SDK 未安装 → ``ProviderNotInstalled``（HTTP 501 / NotSupported）
- 已装但缺少 ``OPENAI_API_KEY`` → ``ProviderNotConfigured``（HTTP 503 / Unavailable）
- 本模块 import 不触碰 openai SDK。
"""

from __future__ import annotations

import json
import os
from typing import Any, AsyncIterator

from ..errors import ProviderNotConfigured, ProviderNotInstalled
from . import (
    ChatChunk,
    ChatMessage,
    ChatRequest,
    ChatResponse,
    EmbeddingRequest,
    EmbeddingResponse,
    sdk_installed,
)

DEFAULT_MODEL = "gpt-4o-mini"
DEFAULT_EMBEDDING_MODEL = "text-embedding-3-small"
API_KEY_ENV = "OPENAI_API_KEY"


def _load_sdk() -> Any:
    """函数级惰性导入 openai（测试可 monkeypatch 注入假 SDK）。"""
    try:
        import openai  # type: ignore[import-not-found]  # noqa: PLC0415
    except ImportError as exc:
        raise ProviderNotInstalled("openai", "pip install openai==1.51.0") from exc
    return openai


def _get(obj: Any, name: str, default: Any = None) -> Any:
    """兼容 dict / 属性两种形态的取值（SDK 模型与测试 Stub 通用）。"""
    if obj is None:
        return default
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


class OpenAIProvider:
    """OpenAI Chat Completions / Embeddings。"""

    name = "openai"

    def __init__(
        self,
        *,
        api_key: str | None = None,
        api_key_env: str = API_KEY_ENV,
        model: str | None = None,
        embedding_model: str | None = None,
        base_url: str | None = None,
    ) -> None:
        self.api_key = api_key
        self.api_key_env = api_key_env
        self.model = model or os.environ.get("WB_AI_OPENAI_MODEL") or DEFAULT_MODEL
        self.embedding_model = (
            embedding_model or os.environ.get("WB_AI_OPENAI_EMBEDDING_MODEL") or DEFAULT_EMBEDDING_MODEL
        )
        self.base_url = base_url or os.environ.get("OPENAI_BASE_URL") or None

    # —— 配置与可用性 ——

    def resolve_api_key(self) -> str | None:
        """凭据仅从显式参数或环境变量读取；绝不记录。"""
        return self.api_key or os.environ.get(self.api_key_env) or None

    def availability(self) -> dict[str, Any]:
        return {
            "provider": self.name,
            "installed": sdk_installed("openai"),
            "configured": self.resolve_api_key() is not None,
        }

    def _client(self) -> Any:
        # 先探测安装（501），再校验配置（503），保证降级路径确定。
        sdk = _load_sdk()
        key = self.resolve_api_key()
        if not key:
            raise ProviderNotConfigured(self.name, self.api_key_env, "set OPENAI_API_KEY")
        kwargs: dict[str, Any] = {"api_key": key}
        if self.base_url:
            kwargs["base_url"] = self.base_url
        return sdk.AsyncOpenAI(**kwargs)

    # —— 对话 ——

    def _payload(self, request: ChatRequest, *, stream: bool) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": request.model or self.model,
            "messages": [self._wire_message(message) for message in request.messages],
            "stream": stream,
        }
        if request.temperature is not None:
            payload["temperature"] = request.temperature
        if request.max_tokens is not None:
            payload["max_tokens"] = request.max_tokens
        if request.tools:
            payload["tools"] = [self._wire_tool(tool) for tool in request.tools]
        return payload

    @staticmethod
    def _wire_message(message: ChatMessage) -> dict[str, Any]:
        wire: dict[str, Any] = {"role": message.role}
        if message.content is not None:
            wire["content"] = message.content
        if message.name:
            wire["name"] = message.name
        if message.tool_call_id:
            wire["tool_call_id"] = message.tool_call_id
        if message.tool_calls:
            wire["tool_calls"] = message.tool_calls
        if message.role == "tool" and message.content is None:
            wire["content"] = ""
        return wire

    @staticmethod
    def _wire_tool(tool: dict[str, Any]) -> dict[str, Any]:
        """兼容两种入参：已 OpenAI 形状（含 type）或 {name, description, parameters}。"""
        if tool.get("type") == "function":
            return tool
        return {"type": "function", "function": tool}

    async def chat(self, request: ChatRequest) -> ChatResponse:
        client = self._client()
        response = await client.chat.completions.create(**self._payload(request, stream=False))
        choices = _get(response, "choices", []) or []
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
            usage=self._wire_usage(_get(response, "usage")),
            model=_get(response, "model") or self.model,
        )

    async def stream_chat(self, request: ChatRequest) -> AsyncIterator[ChatChunk]:  # type: ignore[override]
        client = self._client()
        stream = await client.chat.completions.create(**self._payload(request, stream=True))
        last_finish: str | None = None
        async for event in stream:
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
        response = await client.embeddings.create(
            model=request.model or self.embedding_model,
            input=request.input,
        )
        data = _get(response, "data", []) or []
        embeddings = [list(_get(item, "embedding", []) or []) for item in data]
        return EmbeddingResponse(
            embeddings=embeddings,
            model=_get(response, "model") or self.embedding_model,
            usage=self._wire_usage(_get(response, "usage")),
        )

    # —— 内部 ——

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


__all__ = ["OpenAIProvider", "DEFAULT_MODEL", "DEFAULT_EMBEDDING_MODEL", "API_KEY_ENV"]
