"""Provider 层：惰性导入、降级路径（501/503）、SDK 消息映射（离线 Stub / MockTransport）。

不得触达真实网络：
- openai / anthropic 通过 monkeypatch 注入假 SDK 模块；
- custom（OpenAI 兼容端点）通过 ``httpx.MockTransport`` 拦截全部 HTTP。
"""

from __future__ import annotations

import asyncio
import json
from types import SimpleNamespace

import httpx
import pytest

from src.errors import ProviderNotConfigured, ProviderNotInstalled, UpstreamError
from src.providers import ChatMessage, ChatRequest, EmbeddingRequest, sdk_installed
from src.providers import anthropic as anthropic_module
from src.providers import openai as openai_module
from src.providers.anthropic import AnthropicProvider
from src.providers.custom import CustomProvider
from src.providers.openai import OpenAIProvider

OPENAI_MISSING = pytest.mark.skipif(sdk_installed("openai"), reason="openai SDK 已安装（本 venv 预期未装）")
ANTHROPIC_MISSING = pytest.mark.skipif(
    sdk_installed("anthropic"), reason="anthropic SDK 已安装（本 venv 预期未装）"
)


def _req(text: str = "hi", **kwargs: object) -> ChatRequest:
    return ChatRequest(messages=[ChatMessage(role="user", content=text)], **kwargs)


async def _collect(agen):
    return [chunk async for chunk in agen]


class _AsyncCursor:
    """异步迭代器桩（模拟 SDK 流对象）。"""

    def __init__(self, items: list) -> None:
        self._items = list(items)

    def __aiter__(self):
        return self

    async def __anext__(self):
        if not self._items:
            raise StopAsyncIteration
        return self._items.pop(0)


def _transport_factory(handler):
    def factory() -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=httpx.MockTransport(handler))

    return factory


# —— 通用 ——


def test_sdk_installed_detects_missing_module():
    assert sdk_installed("wb_definitely_missing_module_xyz") is False


def test_openai_availability_shape_without_importing():
    report = OpenAIProvider().availability()
    assert report["provider"] == "openai"
    assert report["installed"] == sdk_installed("openai")
    assert report["configured"] is False  # autouse fixture 已清空 OPENAI_API_KEY


# —— OpenAI ——


@OPENAI_MISSING
def test_openai_missing_sdk_raises_501():
    provider = OpenAIProvider()
    with pytest.raises(ProviderNotInstalled) as ei:
        asyncio.run(provider.chat(_req()))
    assert ei.value.status_code == 501
    assert ei.value.code == "NotSupported"
    assert ei.value.details["sdk"] == "openai"


@OPENAI_MISSING
def test_openai_stream_missing_sdk_raises_501():
    provider = OpenAIProvider()
    with pytest.raises(ProviderNotInstalled):
        asyncio.run(_collect(provider.stream_chat(_req())))


def test_openai_fake_sdk_without_key_503(monkeypatch):
    monkeypatch.setattr(openai_module, "_load_sdk", lambda: SimpleNamespace(AsyncOpenAI=object))
    provider = openai_module.OpenAIProvider()
    with pytest.raises(ProviderNotConfigured) as ei:
        asyncio.run(provider.chat(_req()))
    assert ei.value.status_code == 503
    assert "OPENAI_API_KEY" in ei.value.message


def test_openai_chat_maps_response_and_payload(monkeypatch):
    sdk_calls: list[dict] = []
    response = SimpleNamespace(
        choices=[
            SimpleNamespace(
                message=SimpleNamespace(
                    content="mapped!",
                    tool_calls=[
                        SimpleNamespace(
                            id="call_1",
                            function=SimpleNamespace(name="element.create", arguments='{"boardId": "b1"}'),
                        )
                    ],
                ),
                finish_reason="tool_calls",
            )
        ],
        usage=SimpleNamespace(prompt_tokens=10, completion_tokens=2, total_tokens=12),
        model="gpt-4o-mini",
    )

    class _Completions:
        async def create(self, **kwargs):
            sdk_calls.append(kwargs)
            return response

    class _SDK:
        def __init__(self, **kwargs):
            sdk_calls.append({"client": kwargs})
            self.chat = SimpleNamespace(completions=_Completions())

    monkeypatch.setattr(openai_module, "_load_sdk", lambda: SimpleNamespace(AsyncOpenAI=_SDK))
    provider = openai_module.OpenAIProvider(api_key="unit-key", model="gpt-x")
    request = _req(tools=[{"name": "element.create", "parameters": {"type": "object", "properties": {}}}])
    result = asyncio.run(provider.chat(request))

    assert sdk_calls[0]["client"] == {"api_key": "unit-key"}
    payload = sdk_calls[-1]
    assert payload["model"] == "gpt-x"
    assert payload["stream"] is False
    assert payload["messages"] == [{"role": "user", "content": "hi"}]
    assert payload["tools"] == [
        {"type": "function", "function": {"name": "element.create", "parameters": {"type": "object", "properties": {}}}}
    ]
    assert result.content == "mapped!"
    assert result.finish_reason == "tool_calls"
    assert result.tool_calls == [
        {"id": "call_1", "name": "element.create", "arguments": '{"boardId": "b1"}'}
    ]
    assert result.usage == {"promptTokens": 10, "completionTokens": 2, "totalTokens": 12}


def test_openai_stream_maps_chunks(monkeypatch):
    events = [
        SimpleNamespace(choices=[SimpleNamespace(delta=SimpleNamespace(content="Hel"), finish_reason=None)]),
        SimpleNamespace(choices=[SimpleNamespace(delta=SimpleNamespace(content="lo"), finish_reason=None)]),
        SimpleNamespace(choices=[SimpleNamespace(delta=SimpleNamespace(content=None), finish_reason="stop")]),
    ]

    class _Completions:
        async def create(self, **kwargs):
            assert kwargs["stream"] is True
            return _AsyncCursor(events)

    class _SDK:
        def __init__(self, **kwargs):
            self.chat = SimpleNamespace(completions=_Completions())

    monkeypatch.setattr(openai_module, "_load_sdk", lambda: SimpleNamespace(AsyncOpenAI=_SDK))
    provider = openai_module.OpenAIProvider(api_key="unit-key")
    chunks = asyncio.run(_collect(provider.stream_chat(_req())))
    assert [chunk.delta for chunk in chunks] == ["Hel", "lo", ""]
    assert chunks[-1].finish_reason == "stop"


def test_openai_embedding_maps_vectors(monkeypatch):
    calls: list[dict] = []

    class _Embeddings:
        async def create(self, **kwargs):
            calls.append(kwargs)
            return SimpleNamespace(
                data=[SimpleNamespace(embedding=[0.5, 0.25])],
                model="text-embedding-3-small",
                usage=SimpleNamespace(prompt_tokens=4, completion_tokens=0, total_tokens=4),
            )

    class _SDK:
        def __init__(self, **kwargs):
            self.embeddings = _Embeddings()

    monkeypatch.setattr(openai_module, "_load_sdk", lambda: SimpleNamespace(AsyncOpenAI=_SDK))
    provider = openai_module.OpenAIProvider(api_key="unit-key")
    result = asyncio.run(provider.embedding(EmbeddingRequest(input="hello")))
    assert result.embeddings == [[0.5, 0.25]]
    assert result.model == "text-embedding-3-small"
    assert calls[-1] == {"model": "text-embedding-3-small", "input": "hello"}


# —— Anthropic ——


@ANTHROPIC_MISSING
def test_anthropic_missing_sdk_raises_501():
    provider = AnthropicProvider()
    with pytest.raises(ProviderNotInstalled) as ei:
        asyncio.run(provider.chat(_req()))
    assert ei.value.status_code == 501
    assert ei.value.details["sdk"] == "anthropic"


def test_anthropic_fake_sdk_without_key_503(monkeypatch):
    monkeypatch.setattr(anthropic_module, "_load_sdk", lambda: SimpleNamespace(AsyncAnthropic=object))
    provider = anthropic_module.AnthropicProvider()
    with pytest.raises(ProviderNotConfigured) as ei:
        asyncio.run(provider.chat(_req()))
    assert ei.value.status_code == 503
    assert "ANTHROPIC_API_KEY" in ei.value.message


def test_anthropic_chat_hoists_system_and_maps_tools(monkeypatch):
    sdk_calls: list[dict] = []
    response = SimpleNamespace(
        content=[
            SimpleNamespace(type="text", text="Hello "),
            SimpleNamespace(type="text", text="world"),
            SimpleNamespace(type="tool_use", id="tu_1", name="element.create", input={"boardId": "b1"}),
        ],
        stop_reason="tool_use",
        usage=SimpleNamespace(input_tokens=7, output_tokens=3),
        model="claude-unit",
    )

    class _Messages:
        async def create(self, **kwargs):
            sdk_calls.append(kwargs)
            return response

        def stream(self, **kwargs):  # pragma: no cover - 本用例不触达
            raise AssertionError("unexpected stream call")

    class _SDK:
        def __init__(self, **kwargs):
            self.messages = _Messages()

    monkeypatch.setattr(anthropic_module, "_load_sdk", lambda: SimpleNamespace(AsyncAnthropic=_SDK))
    provider = anthropic_module.AnthropicProvider(api_key="unit-key", model="claude-x")
    request = ChatRequest(
        messages=[
            ChatMessage(role="system", content="be nice"),
            ChatMessage(role="user", content="hi"),
        ],
        tools=[{"name": "element.create", "description": "d", "parameters": {"type": "object", "properties": {}}}],
    )
    result = asyncio.run(provider.chat(request))

    payload = sdk_calls[-1]
    assert payload["system"] == "be nice"
    assert payload["messages"] == [{"role": "user", "content": "hi"}]
    assert payload["model"] == "claude-x"
    assert payload["tools"][0]["input_schema"] == {"type": "object", "properties": {}}
    assert result.content == "Hello world"
    assert result.tool_calls == [
        {"id": "tu_1", "name": "element.create", "arguments": json.dumps({"boardId": "b1"})}
    ]
    assert result.finish_reason == "tool_use"
    assert result.usage == {"promptTokens": 7, "completionTokens": 3, "totalTokens": 10}


def test_anthropic_stream_maps_chunks(monkeypatch):
    payloads: list[dict] = []

    class _StreamCtx:
        def __init__(self) -> None:
            self.text_stream = _AsyncCursor(["Cl", "aude"])

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return False

        async def get_final_message(self):
            return SimpleNamespace(stop_reason="end_turn")

    class _Messages:
        def stream(self, **kwargs):
            payloads.append(kwargs)
            return _StreamCtx()

        async def create(self, **kwargs):  # pragma: no cover - 本用例不触达
            raise AssertionError("unexpected create call")

    class _SDK:
        def __init__(self, **kwargs):
            self.messages = _Messages()

    monkeypatch.setattr(anthropic_module, "_load_sdk", lambda: SimpleNamespace(AsyncAnthropic=_SDK))
    provider = anthropic_module.AnthropicProvider(api_key="unit-key")
    chunks = asyncio.run(_collect(provider.stream_chat(_req())))
    assert [chunk.delta for chunk in chunks] == ["Cl", "aude", ""]
    assert chunks[-1].finish_reason == "end_turn"
    assert payloads[-1]["max_tokens"] == 1024


def test_anthropic_has_no_embedding_capability():
    assert getattr(AnthropicProvider(), "embedding", None) is None


# —— Custom（OpenAI 兼容端点，MockTransport 全离线） ——


def test_custom_availability_requires_base_url():
    assert CustomProvider().availability()["configured"] is False
    assert CustomProvider(base_url="http://local.unit/v1").availability()["configured"] is True


def test_custom_unconfigured_503():
    provider = CustomProvider()
    with pytest.raises(ProviderNotConfigured) as ei:
        asyncio.run(provider.chat(_req()))
    assert ei.value.status_code == 503
    assert "WB_CUSTOM_LLM_BASE_URL" in ei.value.message


def test_custom_chat_roundtrip():
    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["path"] = request.url.path
        seen["auth"] = request.headers.get("authorization")
        seen["payload"] = json.loads(request.content)
        return httpx.Response(
            200,
            json={
                "model": "local-1",
                "choices": [
                    {
                        "message": {
                            "content": "hi from custom",
                            "tool_calls": [{"id": "c1", "function": {"name": "element.create", "arguments": "{}"}}],
                        },
                        "finish_reason": "stop",
                    }
                ],
                "usage": {"prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3},
            },
        )

    provider = CustomProvider(
        base_url="http://unit.local/v1/", api_key="unit-key", client_factory=_transport_factory(handler)
    )
    result = asyncio.run(provider.chat(_req()))
    assert seen["path"] == "/v1/chat/completions"
    assert seen["auth"] == "Bearer unit-key"
    assert seen["payload"]["stream"] is False
    assert result.content == "hi from custom"
    assert result.tool_calls == [{"id": "c1", "name": "element.create", "arguments": "{}"}]
    assert result.usage == {"promptTokens": 1, "completionTokens": 2, "totalTokens": 3}


def test_custom_stream_parses_sse():
    sse_body = (
        'data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}\n\n'
        'data: {"choices":[{"delta":{"content":"!"},"finish_reason":"stop"}]}\n\n'
        "data: [DONE]\n\n"
    )

    def handler(request: httpx.Request) -> httpx.Response:
        assert json.loads(request.content)["stream"] is True
        return httpx.Response(200, content=sse_body.encode(), headers={"content-type": "text/event-stream"})

    provider = CustomProvider(base_url="http://unit.local/v1", client_factory=_transport_factory(handler))
    chunks = asyncio.run(_collect(provider.stream_chat(_req())))
    assert [chunk.delta for chunk in chunks] == ["Hi", "!"]
    assert chunks[-1].finish_reason == "stop"


def test_custom_embedding_roundtrip():
    def handler(request: httpx.Request) -> httpx.Response:
        assert json.loads(request.content)["input"] == ["a", "b"]
        return httpx.Response(
            200, json={"model": "local-embed", "data": [{"embedding": [0.1]}, {"embedding": [0.2]}]}
        )

    provider = CustomProvider(base_url="http://unit.local/v1", client_factory=_transport_factory(handler))
    result = asyncio.run(provider.embedding(EmbeddingRequest(input=["a", "b"])))
    assert result.embeddings == [[0.1], [0.2]]


def test_custom_upstream_http_error_502():
    provider = CustomProvider(
        base_url="http://unit.local/v1",
        client_factory=_transport_factory(lambda request: httpx.Response(500, json={"error": "boom"})),
    )
    with pytest.raises(UpstreamError) as ei:
        asyncio.run(provider.chat(_req()))
    assert ei.value.status_code == 502
    assert "HTTP 500" in ei.value.message
