"""pytest 共享配置（convert）：路径注入、假 PyMuPDF 引擎、应用工厂。

所有测试完全离线：
- 单元/路由测试注入假引擎（不触达 PyMuPDF）；
- 真实引擎冒烟仅在 PyMuPDF 已安装时执行（现场生成小 PDF，不访问网络）。
"""

from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
TESTS_DIR = Path(__file__).resolve().parent
for _path in (ROOT, TESTS_DIR):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

from src import pdf_converter  # noqa: E402
from src.app import create_app  # noqa: E402

#: PyMuPDF 在本环境是否可用（控制真实引擎冒烟测试的跳过）
ENGINE_INSTALLED = pdf_converter.engine_installed()
requires_engine = pytest.mark.skipif(not ENGINE_INSTALLED, reason="PyMuPDF 未安装（降级路径已被其它用例覆盖）")

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


class FakePixmap:
    """假渲染位图（含 PNG magic，便于断言）。"""

    def __init__(self, payload: bytes) -> None:
        self._payload = payload

    def tobytes(self, fmt: str = "png") -> bytes:
        assert fmt == "png"
        return PNG_MAGIC + self._payload


class FakePage:
    def __init__(self, index: int, text: str = "", width: float = 595.0, height: float = 842.0) -> None:
        self.index = index
        self._text = text
        self.rect = SimpleNamespace(width=width, height=height)
        self.rendered_dpi: list[int] = []

    def get_text(self, kind: str = "text") -> str:
        assert kind == "text"
        return self._text

    def get_pixmap(self, dpi: int = 144) -> FakePixmap:
        self.rendered_dpi.append(dpi)
        return FakePixmap(f"page-{self.index}-at-{dpi}".encode())


class FakeDoc:
    """假 PDF 文档（等价于 fitz.Document 的被用子集）。

    ``page_count`` 未显式给出时：有 ``texts`` 则取 ``len(texts)``，否则默认 2 页。
    """

    def __init__(
        self,
        *,
        page_count: int | None = None,
        texts: list[str] | None = None,
        metadata: dict | None = None,
        needs_pass: bool = False,
    ) -> None:
        if page_count is None:
            page_count = len(texts) if texts is not None else 2
        self.page_count = page_count
        self.metadata = metadata if metadata is not None else {"title": "fake", "producer": "wb-test"}
        self.needs_pass = needs_pass
        self.closed = False
        resolved = list(texts) if texts is not None else [f"page {index} text" for index in range(page_count)]
        while len(resolved) < page_count:  # 防御：texts 少于页数时补齐空串
            resolved.append("")
        self.pages = [FakePage(index, text=resolved[index]) for index in range(page_count)]

    def load_page(self, index: int) -> FakePage:
        return self.pages[index]

    def close(self) -> None:
        self.closed = True


class FakeEngine:
    """假 PyMuPDF 模块：``open(stream=..., filetype="pdf")`` 记录调用。"""

    def __init__(self, *, doc: FakeDoc | None = None, open_error: Exception | None = None) -> None:
        self.doc = doc if doc is not None else FakeDoc()
        self.open_error = open_error
        self.open_calls: list[dict] = []

    def open(self, **kwargs) -> FakeDoc:
        self.open_calls.append(kwargs)
        if self.open_error is not None:
            raise self.open_error
        return self.doc


@pytest.fixture
def fake_engine(monkeypatch):
    """安装假引擎（monkeypatch ``pdf_converter._load_fitz``）；返回引擎实例。"""

    def install(*, doc: FakeDoc | None = None, open_error: Exception | None = None) -> FakeEngine:
        engine = FakeEngine(doc=doc, open_error=open_error)
        monkeypatch.setattr(pdf_converter, "_load_fitz", lambda: engine)
        return engine

    return install


@pytest.fixture
def make_client():
    """convert 应用 TestClient 工厂（默认使用真实引擎装配，测试自行注入假引擎）。"""
    clients: list[TestClient] = []

    def factory(*, jobs=None) -> TestClient:
        app = create_app(jobs=jobs)
        client = TestClient(app)
        clients.append(client)
        return client

    yield factory

    for client in clients:  # pragma: no cover - 清理
        client.close()
