"""Anthropic Provider（``anthropic`` SDK 函数级惰性导入）。

- SDK 未安装 → ``ProviderNotInstalled``（HTTP 501 / NotSupported）
- 已装但缺少 ``ANTHROPIC_API_KEY`` → ``ProviderNotConfigured``（HTTP 503 / Unavailable）
- Anthropic 无 embedding 能力（不定义 ``embedding``，路由层 → 501）
- 本模块 import 不触碰 anthropic SDK。
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
    sdk_installed,
)

DEFAULT_MODEL = "claude-3-5-sonnet-latest"
DEFAULT_MAX_TOKENS = 1024
API_KEY_ENV = "ANTHROPIC_API_KEY"


def _load_sdk() -> Any:
    """函数级惰性导入 anthropic（测试可 monkeypatch 注入假 SDK）。"""
    try:
        import anthropic  # type: ignore[import-not-found]  # noqa: PLC0415
    except ImportError as exc:
        raise ProviderNotInstalled("anthropic", "pip install anthropic==0.34.2") from exc
    return anthropic


def _get(obj: Any, name: str, default: Any = None) -> Any:
    if obj is None:
        return default
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


class AnthropicProvider:
    """Anthropic Messages API。"""

    name = "anthropic"

    def __init__(
        self,
        *,
        api_key: str | None = None,
        api_key_env: str = API_KEY_ENV,
        model: str | None = None,
        max_tokens: int | None = None,
    ) -> None:
        self.api_key = api_key
        self.api_key_env = api_key_env
        self.model = model or os.environ.get("WB_AI_ANTHROPIC_MODEL") or DEFAULT_MODEL
        self.max_tokens = max_tokens or DEFAULT_MAX_TOKENS

    # —— 配置与可用性 ——

    def resolve_api_key(self) -> str | None:
        return self.api_key or os.environ.get(self.api_key_env) or None

    def availability(self) -> dict[str, Any]:
        return {
            "provider": self.name,
            "installed": sdk_installed("anthropic"),
            "configured": self.resolve_api_key() is not None,
        }

    def _client(self) -> Any:
        sdk = _load_sdk()
        key = self.resolve_api_key()
        if not key:
            raise ProviderNotConfigured(self.name, self.api_key_env, "set ANTHROPIC_API_KEY")
        return sdk.AsyncAnthropic(api_key=key)

    # —— 对话 ——

    def _payload(self, request: ChatRequest) -> dict[str, Any]:
        system_parts: list[str] = []
        wire_messages: list[dict[str, Any]] = []
        for message in request.messages:
            if message.role == "system":
                if message.content:
                    system_parts.append(message.content)
                continue
            role = message.role if message.role in ("user", "assistant") else "user"
            wire_messages.append({"role": role, "content": message.content or ""})
        payload: dict[str, Any] = {
            "model": request.model or self.model,
            "max_tokens": request.max_tokens or self.max_tokens,
            "messages": wire_messages,
        }
        if system_parts:
            payload["system"] = "\n\n".join(system_parts)
        if request.temperature is not None:
            payload["temperature"] = request.temperature
        if request.tools:
            payload["tools"] = [self._wire_tool(tool) for tool in request.tools]
        return payload

    @staticmethod
    def _wire_tool(tool: dict[str, Any]) -> dict[str, Any]:
        """兼容两种入参：已 Anthropic 形状（含 input_schema）或 {name, parameters}。"""
        if "input_schema" in tool:
            return tool
        return {
            "name": tool.get("name"),
            "description": tool.get("description", ""),
            "input_schema": tool.get("parameters") or {"type": "object", "properties": {}},
        }

    async def chat(self, request: ChatRequest) -> ChatResponse:
        client = self._client()
        response = await client.messages.create(**self._payload(request))
        texts: list[str] = []
        tool_calls: list[dict[str, Any]] = []
        for block in _get(response, "content", []) or []:
            block_type = _get(block, "type")
            if block_type == "text":
                texts.append(_get(block, "text", "") or "")
            elif block_type == "tool_use":
                tool_calls.append(
                    {
                        "id": _get(block, "id"),
                        "name": _get(block, "name"),
                        "arguments": json.dumps(_get(block, "input", {}) or {}, ensure_ascii=False),
                    }
                )
        return ChatResponse(
            content="".join(texts),
            finish_reason=_get(response, "stop_reason", "stop") or "stop",
            tool_calls=tool_calls,
            usage=self._wire_usage(_get(response, "usage")),
            model=_get(response, "model") or self.model,
        )

    async def stream_chat(self, request: ChatRequest) -> AsyncIterator[ChatChunk]:  # type: ignore[override]
        client = self._client()
        async with client.messages.stream(**self._payload(request)) as stream:
            async for text in stream.text_stream:
                yield ChatChunk(delta=text)
            finish = "stop"
            get_final = getattr(stream, "get_final_message", None)
            if callable(get_final):
                try:
                    final = await get_final()
                    finish = _get(final, "stop_reason", None) or "stop"
                except Exception:  # noqa: BLE001 - 结束原因不阻断流
                    finish = "stop"
            yield ChatChunk(delta="", finish_reason=finish)

    # —— 内部 ——

    @staticmethod
    def _wire_usage(usage: Any) -> dict[str, int] | None:
        if usage is None:
            return None
        input_tokens = _get(usage, "input_tokens")
        output_tokens = _get(usage, "output_tokens")
        if input_tokens is None and output_tokens is None:
            return None
        input_tokens = input_tokens or 0
        output_tokens = output_tokens or 0
        return {
            "promptTokens": input_tokens,
            "completionTokens": output_tokens,
            "totalTokens": input_tokens + output_tokens,
        }


__all__ = ["AnthropicProvider", "DEFAULT_MODEL", "DEFAULT_MAX_TOKENS", "API_KEY_ENV"]
