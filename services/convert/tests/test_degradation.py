"""惰性导入降级路径：引擎缺失 → 501，且模块可安全 import。"""

from __future__ import annotations

import builtins
import subprocess
import sys
from pathlib import Path

import pytest

from src import pdf_converter

ROOT = Path(__file__).resolve().parents[1]


def test_load_fitz_blocked_import_raises_engine_unavailable(monkeypatch):
    """拦截 import 模拟「PyMuPDF 未安装」：_load_fitz 抛 501 结构化错误。"""
    real_import = builtins.__import__

    def blocked(name, *args, **kwargs):
        if name in ("pymupdf", "fitz"):
            raise ImportError(f"blocked: {name}")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", blocked)
    with pytest.raises(pdf_converter.PdfEngineUnavailable) as ei:
        pdf_converter._load_fitz()
    assert ei.value.status_code == 501
    assert ei.value.code == "NotSupported"
    assert "pymupdf" in str(ei.value)
    assert ei.value.details == {"engine": "pymupdf"}


def test_module_imports_and_degrades_in_engine_less_subprocess():
    """未安装 PyMuPDF 时模块仍可 import 且调用抛 501（子进程隔离验证）。

    说明：不在本进程内 reload ``src.pdf_converter``——reload 会产生新的异常
    类对象，使 app 层已注册的异常处理器按旧类无法命中，从而污染其它用例。
    """
    script = "\n".join(
        [
            "import sys",
            "sys.path.insert(0, sys.argv[1])",
            "class _Blocker:",
            "    def find_spec(self, name, path=None, target=None):",
            "        if name in ('pymupdf', 'fitz'):",
            "            raise ImportError('blocked: ' + name)",
            "        return None",
            "sys.meta_path.insert(0, _Blocker())",
            "import src.pdf_converter as m",
            "assert m.engine_installed() is False",
            "try:",
            "    m.get_info(b'%PDF-1.4 fake')",
            "except m.PdfEngineUnavailable as e:",
            "    assert e.status_code == 501",
            "else:",
            "    raise AssertionError('expected PdfEngineUnavailable')",
            "print('ok')",
        ]
    )
    proc = subprocess.run(
        [sys.executable, "-c", script, str(ROOT)],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert proc.returncode == 0, f"stderr:\n{proc.stderr}"
    assert "ok" in proc.stdout


@pytest.fixture
def engine_raiser(monkeypatch):
    def raiser():
        raise pdf_converter.PdfEngineUnavailable("pip install pymupdf")

    monkeypatch.setattr(pdf_converter, "_load_fitz", raiser)
    return raiser


def test_info_route_501_when_engine_missing(make_client, engine_raiser):
    client = make_client()
    resp = client.post("/v1/pdf/info", files={"file": ("a.pdf", b"%PDF-1.4 fake", "application/pdf")})
    assert resp.status_code == 501
    error = resp.json()["error"]
    assert error["code"] == "NotSupported"
    assert "pymupdf (PyMuPDF) is not installed" in error["message"]


def test_text_and_render_routes_501_when_engine_missing(make_client, engine_raiser):
    client = make_client()
    resp = client.post("/v1/pdf/text", files={"file": ("a.pdf", b"%PDF-1.4 fake", "application/pdf")})
    assert resp.status_code == 501
    resp = client.post("/v1/pdf/render.png", files={"file": ("a.pdf", b"%PDF-1.4 fake", "application/pdf")})
    assert resp.status_code == 501
    assert resp.json()["error"]["code"] == "NotSupported"


def test_job_route_501_when_engine_missing(make_client, engine_raiser):
    client = make_client()
    resp = client.post(
        "/v1/convert/jobs",
        files={"file": ("a.pdf", b"%PDF-1.4 fake", "application/pdf")},
        data={"operation": "text"},
    )
    assert resp.status_code == 501
    assert resp.json()["error"]["code"] == "NotSupported"
    # 引擎缺失不落任务记录
    assert client.get("/v1/convert/jobs").json()["data"]["total"] == 0


def test_conversion_error_maps_to_400(make_client, fake_engine):
    """损坏 PDF（引擎 open 抛错）→ 400 InvalidArgument（直接路由）。"""
    fake_engine(open_error=RuntimeError("not a pdf"))
    client = make_client()
    resp = client.post("/v1/pdf/info", files={"file": ("bad.pdf", b"%PDF-1.4 broken", "application/pdf")})
    assert resp.status_code == 400
    error = resp.json()["error"]
    assert error["code"] == "InvalidArgument"
    assert "invalid pdf (RuntimeError)" in error["message"]
