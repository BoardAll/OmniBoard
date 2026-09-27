"""Provider 统一接口与数据模型。

统一接口（《AI 助手与 MCP 设计》§5.1）：

- ``chat(request)``        非流式对话
- ``stream_chat(request)`` 流式对话（异步迭代 ``ChatChunk``）
- ``embedding(request)``   可选能力（未实现的 Provider 由路由层 → 501）
- ``availability()``       安装/配置状态（仅探测，绝不触发 SDK 导入）

所有厂商 SDK（openai / anthropic）必须在本包内部**函数级惰性导入**；
本模块 import 不得触碰任何第三方依赖。
"""

from __future__ import annotations

import importlib.util
from typing import Any, AsyncIterator, Protocol, runtime_checkable

from pydantic import BaseModel, Field


class ChatMessage(BaseModel):
    """对话消息（role: system / user / assistant / tool）。"""

    role: str
    content: str | None = None
    name: str | None = None
    tool_call_id: str | None = None
    tool_calls: list[dict[str, Any]] | None = None


class ChatRequest(BaseModel):
    """统一 chat 请求。"""

    messages: list[ChatMessage]
    model: str | None = None
    temperature: float | None = None
    max_tokens: int | None = None
    tools: list[dict[str, Any]] | None = None
    metadata: dict[str, Any] | None = None


class ChatChunk(BaseModel):
    """流式增量。"""

    delta: str = ""
    finish_reason: str | None = None


class ChatResponse(BaseModel):
    """统一 chat 响应。"""

    content: str = ""
    finish_reason: str = "stop"
    tool_calls: list[dict[str, Any]] = Field(default_factory=list)
    usage: dict[str, int] | None = None
    model: str | None = None


class EmbeddingRequest(BaseModel):
    """统一 embedding 请求。"""

    input: str | list[str]
    model: str | None = None


class EmbeddingResponse(BaseModel):
    """统一 embedding 响应（向量列表，顺序与 input 对齐）。"""

    embeddings: list[list[float]]
    model: str | None = None
    usage: dict[str, int] | None = None


def sdk_installed(module: str) -> bool:
    """探测第三方模块是否可导入（不触发实际导入）。"""
    try:
        return importlib.util.find_spec(module) is not None
    except (ImportError, ValueError):
        return False


@runtime_checkable
class Provider(Protocol):
    """Provider 统一接口（结构化鸭子类型，测试可注入 Fake）。"""

    name: str

    def availability(self) -> dict[str, Any]:
        """返回 {provider, installed, configured}；不得泄露凭据。"""
        ...

    async def chat(self, request: ChatRequest) -> ChatResponse: ...

    def stream_chat(self, request: ChatRequest) -> AsyncIterator[ChatChunk]: ...


__all__ = [
    "ChatMessage",
    "ChatRequest",
    "ChatChunk",
    "ChatResponse",
    "EmbeddingRequest",
    "EmbeddingResponse",
    "Provider",
    "sdk_installed",
]
