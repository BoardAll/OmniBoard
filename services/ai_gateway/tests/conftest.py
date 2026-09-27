"""pytest 共享配置：路径注入、环境清理、离线 Fake 实现。

所有测试必须完全离线：
- 环境变量清空（即使开发机存在真实 key，也不影响降级路径断言）；
- Provider / ASR / TTS 全部使用 Fake 注入；
- 真实 SDK 调用路径仅在「未安装 → 501」降级测试中被触达（安装检测优先）。
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
TESTS_DIR = Path(__file__).resolve().parent
for _path in (ROOT, TESTS_DIR):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

from src.app import create_app  # noqa: E402
from src.providers import ChatChunk, ChatResponse, EmbeddingResponse  # noqa: E402

#: 所有测试前清空的环境变量（保证「未配置 → 503」路径确定性）
CLEAN_ENV = [
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "AZURE_SPEECH_KEY",
    "AZURE_SPEECH_REGION",
    "WB_CUSTOM_LLM_BASE_URL",
    "WB_CUSTOM_LLM_API_KEY",
    "WB_CUSTOM_LLM_MODEL",
    "WB_BOARD_API_URL",
    "WB_AI_DEFAULT_PROVIDER",
]

#: 哨兵：工厂中显式传入 None 表示「使用默认 Fake」，用该对象区分「未提供」
_DEFAULT = object()


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in CLEAN_ENV:
        monkeypatch.delenv(name, raising=False)


class FakeProvider:
    """离线 Fake Provider（chat / stream / embedding 均可配置）。"""

    name = "fake"

    def __init__(
        self,
        *,
        content: str = "Hello from fake provider",
        chunks: tuple[str, ...] = ("Hel", "lo"),
        tool_calls: list[dict] | None = None,
        model: str = "fake-1",
        embed_dim: int = 4,
    ) -> None:
        self.content = content
        self.chunks = chunks
        self.tool_calls = list(tool_calls or [])
        self.model = model
        self.embed_dim = embed_dim
        self.calls: list[tuple[str, object]] = []

    def availability(self) -> dict:
        return {"provider": self.name, "installed": True, "configured": True}

    async def chat(self, request):
        self.calls.append(("chat", request))
        return ChatResponse(
            content=self.content,
            finish_reason="stop",
            tool_calls=list(self.tool_calls),
            usage={"promptTokens": 3, "completionTokens": 5, "totalTokens": 8},
            model=self.model,
        )

    async def stream_chat(self, request):
        self.calls.append(("stream", request))
        for piece in self.chunks:
            yield ChatChunk(delta=piece)
        yield ChatChunk(delta="", finish_reason="stop")

    async def embedding(self, request):
        self.calls.append(("embed", request))
        inputs = request.input if isinstance(request.input, list) else [request.input]
        return EmbeddingResponse(
            embeddings=[[0.1] * self.embed_dim for _ in inputs],
            model="fake-embed",
            usage={"promptTokens": 1, "completionTokens": 0, "totalTokens": 1},
        )


class FakeTextOnlyProvider:
    """无 embedding 能力（验证 501 能力降级）。"""

    name = "textonly"

    def availability(self) -> dict:
        return {"provider": self.name, "installed": True, "configured": True}

    async def chat(self, request):
        return ChatResponse(content="text only", model="textonly-1")

    async def stream_chat(self, request):
        yield ChatChunk(delta="text")
        yield ChatChunk(delta="", finish_reason="stop")


class ExplodingProvider:
    """chat 抛异常（→502）；stream 中途抛 ProviderNotConfigured（→SSE error 事件）。"""

    name = "boom"

    def availability(self) -> dict:
        return {"provider": self.name, "installed": True, "configured": False}

    async def chat(self, request):
        raise RuntimeError("provider blew up")

    async def stream_chat(self, request):
        from src.errors import ProviderNotConfigured

        yield ChatChunk(delta="par")
        raise ProviderNotConfigured("boom", "FAKE_ENV", "config missing")


class FakeASR:
    """离线 Fake ASR。"""

    name = "fake-asr"

    def __init__(self, text: str = "fake transcript") -> None:
        self.text = text
        self.calls: list[dict] = []

    def availability(self) -> dict:
        return {"engine": self.name, "installed": True, "configured": True}

    async def transcribe(self, audio, *, language=None, filename="audio.wav"):
        self.calls.append({"size": len(audio), "language": language, "filename": filename})
        return self.text


class FakeTTS:
    """离线 Fake TTS。"""

    name = "fake-tts"

    def __init__(self, audio: bytes = b"RIFF-fake-audio") -> None:
        self.audio = audio
        self.calls: list[dict] = []

    def availability(self) -> dict:
        return {"engine": self.name, "installed": True, "configured": True}

    async def synthesize(self, text, *, voice=None, locale=None):
        self.calls.append({"text": text, "voice": voice, "locale": locale})
        return self.audio


@pytest.fixture
def fake_provider() -> FakeProvider:
    return FakeProvider()


@pytest.fixture
def fake_asr() -> FakeASR:
    return FakeASR()


@pytest.fixture
def fake_tts() -> FakeTTS:
    return FakeTTS()


@pytest.fixture
def make_client():
    """构建注入 Fake 的 TestClient 工厂（返回 client；默认 provider=fake）。"""
    clients: list[TestClient] = []

    def factory(
        *,
        providers=_DEFAULT,
        default_provider: str = "fake",
        asr=_DEFAULT,
        tts=_DEFAULT,
        tool_registry=None,
        tool_executor=None,
        sessions=None,
    ) -> TestClient:
        resolved_providers = {"fake": FakeProvider()} if providers is _DEFAULT else providers
        app = create_app(
            providers=resolved_providers,
            default_provider=default_provider,
            asr=FakeASR() if asr is _DEFAULT else asr,
            tts=FakeTTS() if tts is _DEFAULT else tts,
            tool_registry=tool_registry,
            tool_executor=tool_executor,
            sessions=sessions,
        )
        client = TestClient(app)
        clients.append(client)
        return client

    yield factory

    for client in clients:  # pragma: no cover - 清理
        client.close()


def read_sse_events(client: TestClient, path: str, payload: dict) -> tuple[int, list[str]]:
    """读取 SSE 响应：返回 (status, data 行原始字符串列表，含 [DONE])。"""
    with client.stream("POST", path, json=payload) as response:
        lines = [line for line in response.iter_lines() if line.startswith("data: ")]
        return response.status_code, lines
