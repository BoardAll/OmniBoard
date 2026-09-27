"""pdf_converter 单元测试（假引擎，全离线）。"""

from __future__ import annotations

import io
import zipfile

import pytest

from conftest import PNG_MAGIC, FakeDoc
from src import pdf_converter

PDF_BYTES = b"%PDF-1.4 fake-payload"


def test_get_info_shape_and_engine_usage(fake_engine):
    doc = FakeDoc(page_count=2, metadata={"title": "T", "author": "", "producer": "wb"})
    engine = fake_engine(doc=doc)
    info = pdf_converter.get_info(PDF_BYTES)

    assert info["pageCount"] == 2
    assert info["pages"] == [
        {"index": 0, "width": 595.0, "height": 842.0},
        {"index": 1, "width": 595.0, "height": 842.0},
    ]
    assert info["metadata"] == {"title": "T", "producer": "wb"}  # 空值被过滤
    assert info["encrypted"] is False
    assert engine.open_calls[0]["stream"] == PDF_BYTES
    assert engine.open_calls[0]["filetype"] == "pdf"
    assert doc.closed is True  # 文档被关闭


def test_extract_text_all_pages_and_single_page(fake_engine):
    fake_engine(doc=FakeDoc(texts=["alpha", "beta", "gamma"]))
    everything = pdf_converter.extract_text(PDF_BYTES)
    assert [item["text"] for item in everything["pages"]] == ["alpha", "beta", "gamma"]
    assert everything["pageCount"] == 3

    single = pdf_converter.extract_text(PDF_BYTES, page=1)
    assert single["pages"] == [{"index": 1, "text": "beta"}]


def test_extract_text_out_of_range(fake_engine):
    fake_engine(doc=FakeDoc(page_count=2))
    with pytest.raises(pdf_converter.PdfConversionError) as ei:
        pdf_converter.extract_text(PDF_BYTES, page=2)
    assert "page index out of range" in str(ei.value)
    with pytest.raises(pdf_converter.PdfConversionError):
        pdf_converter.extract_text(PDF_BYTES, page=-1)


def test_render_page_png_and_dpi_validation(fake_engine):
    doc = FakeDoc(page_count=2)
    fake_engine(doc=doc)
    png = pdf_converter.render_page_png(PDF_BYTES, page=1, dpi=96)
    assert png.startswith(PNG_MAGIC)
    assert doc.pages[1].rendered_dpi == [96]

    with pytest.raises(pdf_converter.PdfConversionError):
        pdf_converter.render_page_png(PDF_BYTES, dpi=4)
    with pytest.raises(pdf_converter.PdfConversionError):
        pdf_converter.render_page_png(PDF_BYTES, dpi=pdf_converter.MAX_RENDER_DPI + 1)
    with pytest.raises(pdf_converter.PdfConversionError):
        pdf_converter.render_page_png(PDF_BYTES, page=5)


def test_pdf_to_text_merges_pages(fake_engine):
    fake_engine(doc=FakeDoc(texts=["first", "second"]))
    assert pdf_converter.pdf_to_text(PDF_BYTES) == "first\nsecond"


def test_pdf_to_png_zip_contains_numbered_pages(fake_engine):
    fake_engine(doc=FakeDoc(page_count=2))
    archive_bytes = pdf_converter.pdf_to_png_zip(PDF_BYTES, dpi=72)
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        assert archive.namelist() == ["page-001.png", "page-002.png"]
        assert archive.read("page-001.png").startswith(PNG_MAGIC)


def test_empty_payload_rejected(fake_engine):
    engine = fake_engine()
    with pytest.raises(pdf_converter.PdfConversionError) as ei:
        pdf_converter.get_info(b"")
    assert "empty" in str(ei.value)
    assert engine.open_calls == []  # 空载荷不触达引擎


def test_invalid_pdf_wrapped(fake_engine):
    fake_engine(open_error=RuntimeError("broken xref"))
    with pytest.raises(pdf_converter.PdfConversionError) as ei:
        pdf_converter.get_info(PDF_BYTES)
    assert "invalid pdf (RuntimeError)" in str(ei.value)


def test_password_protected_rejected(fake_engine):
    fake_engine(doc=FakeDoc(needs_pass=True))
    with pytest.raises(pdf_converter.PdfConversionError) as ei:
        pdf_converter.get_info(PDF_BYTES)
    assert "password" in str(ei.value)


def test_engine_unavailable_error_shape(fake_engine):
    error = pdf_converter.PdfEngineUnavailable("hint-text")
    assert error.status_code == 501
    assert error.code == "NotSupported"
    assert "hint-text" in str(error)
    assert error.details == {"engine": "pymupdf"}
