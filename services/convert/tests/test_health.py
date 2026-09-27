"""健康检查（不触发 PyMuPDF 导入）。"""

from __future__ import annotations

import sys

from src import pdf_converter


def test_health_reports_service_and_engine(make_client):
    client = make_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True and body["error"] is None
    data = body["data"]
    assert data["status"] == "ok"
    assert data["name"] == "whiteboard-convert"
    assert data["version"]
    assert data["engine"]["name"] == "pymupdf"
    assert data["engine"]["installed"] == pdf_converter.engine_installed()
    assert data["jobs"] == 0
    assert set(data["operations"]) == {"text", "png", "info"}
    assert data["maxUploadMb"] >= 1


def test_health_does_not_import_engine(make_client):
    """健康检查不得触发重型引擎导入（惰性导入约束）。"""
    for module in ("pymupdf", "fitz"):
        sys.modules.pop(module, None)
    client = make_client()
    assert client.get("/health").status_code == 200
    assert "pymupdf" not in sys.modules
    assert "fitz" not in sys.modules
