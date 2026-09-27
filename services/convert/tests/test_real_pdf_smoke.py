"""真实 PyMuPDF 冒烟：现场生成小 PDF 走完整转换管线（本地、离线）。

仅在 PyMuPDF 安装成功时执行；未安装环境自动跳过（降级路径由 test_degradation 覆盖）。
"""

from __future__ import annotations

import io
import zipfile

import pytest

from conftest import requires_engine
from src import pdf_converter

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def _make_pdf_bytes(text: str = "Hello Whiteboard") -> bytes:
    pymupdf = pytest.importorskip("pymupdf")
    doc = pymupdf.open()
    try:
        page = doc.new_page(width=200.0, height=100.0)
        page.insert_text((20, 50), text, fontsize=14)
        return doc.tobytes()
    finally:
        doc.close()


@requires_engine
def test_real_pdf_info_text_render_zip():
    data = _make_pdf_bytes()
    info = pdf_converter.get_info(data)
    assert info["pageCount"] == 1
    assert info["pages"][0]["width"] == pytest.approx(200.0, abs=1.0)

    extracted = pdf_converter.extract_text(data)
    assert "Hello Whiteboard" in extracted["pages"][0]["text"]

    merged = pdf_converter.pdf_to_text(data)
    assert "Hello Whiteboard" in merged

    png = pdf_converter.render_page_png(data, dpi=72)
    assert png.startswith(PNG_MAGIC)
    assert len(png) > 100

    archive_bytes = pdf_converter.pdf_to_png_zip(data, dpi=72)
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        assert archive.namelist() == ["page-001.png"]
        assert archive.read("page-001.png").startswith(PNG_MAGIC)


@requires_engine
def test_real_pdf_http_flow(make_client):
    data = _make_pdf_bytes("Route smoke")
    client = make_client()  # 默认装配真实引擎

    resp = client.post("/v1/pdf/info", files={"file": ("smoke.pdf", data, "application/pdf")})
    assert resp.status_code == 200
    assert resp.json()["data"]["pageCount"] == 1

    job = client.post(
        "/v1/convert/jobs",
        files={"file": ("smoke.pdf", data, "application/pdf")},
        data={"operation": "text"},
    ).json()["data"]
    assert job["status"] == "succeeded"
    assert "Route smoke" in job["result"]["text"]

    download = client.get(f"/v1/convert/jobs/{job['id']}/result")
    assert download.status_code == 200
    assert "Route smoke" in download.text

    render = client.post(
        "/v1/pdf/render.png",
        files={"file": ("smoke.pdf", data, "application/pdf")},
        data={"dpi": "72"},
    )
    assert render.status_code == 200
    assert render.content.startswith(PNG_MAGIC)


@requires_engine
def test_real_invalid_bytes_rejected():
    with pytest.raises(pdf_converter.PdfConversionError):
        pdf_converter.get_info(b"%PDF-1.4 definitely-not-a-pdf")
