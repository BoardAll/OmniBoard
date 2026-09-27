"""PDF 直接路由：/v1/pdf/info、/v1/pdf/text、/v1/pdf/render.png（假引擎）。"""

from __future__ import annotations

from conftest import PNG_MAGIC, FakeDoc

PDF_BYTES = b"%PDF-1.4 fake-payload"
UPLOAD = {"file": ("doc.pdf", PDF_BYTES, "application/pdf")}


def test_info_route(make_client, fake_engine):
    fake_engine(doc=FakeDoc(page_count=3))
    client = make_client()
    resp = client.post("/v1/pdf/info", files=UPLOAD)
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert body["data"]["pageCount"] == 3
    assert len(body["data"]["pages"]) == 3


def test_text_route_all_and_single_page(make_client, fake_engine):
    fake_engine(doc=FakeDoc(texts=["one", "two"]))
    client = make_client()

    resp = client.post("/v1/pdf/text", files=UPLOAD)
    assert resp.status_code == 200
    assert [item["text"] for item in resp.json()["data"]["pages"]] == ["one", "two"]

    resp = client.post("/v1/pdf/text", files=UPLOAD, data={"page": "1"})
    assert resp.status_code == 200
    assert resp.json()["data"]["pages"] == [{"index": 1, "text": "two"}]


def test_text_route_page_out_of_range_400(make_client, fake_engine):
    fake_engine(doc=FakeDoc(page_count=1))
    client = make_client()
    resp = client.post("/v1/pdf/text", files=UPLOAD, data={"page": "9"})
    assert resp.status_code == 400
    error = resp.json()["error"]
    assert error["code"] == "InvalidArgument"
    assert "out of range" in error["message"]


def test_text_route_invalid_page_value_400(make_client, fake_engine):
    fake_engine()
    client = make_client()
    resp = client.post("/v1/pdf/text", files=UPLOAD, data={"page": "abc"})
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "InvalidArgument"


def test_render_route_returns_png(make_client, fake_engine):
    doc = FakeDoc(page_count=1)
    fake_engine(doc=doc)
    client = make_client()
    resp = client.post("/v1/pdf/render.png", files=UPLOAD, data={"page": "0", "dpi": "96"})
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("image/png")
    assert resp.content.startswith(PNG_MAGIC)
    assert resp.headers["x-page"] == "0"
    assert resp.headers["x-dpi"] == "96"
    assert doc.pages[0].rendered_dpi == [96]


def test_render_route_dpi_out_of_range_400(make_client, fake_engine):
    fake_engine()
    client = make_client()
    resp = client.post("/v1/pdf/render.png", files=UPLOAD, data={"dpi": "5000"})
    assert resp.status_code == 400
    assert "dpi out of range" in resp.json()["error"]["message"]


def test_upload_empty_file_400(make_client, fake_engine):
    fake_engine()
    client = make_client()
    resp = client.post("/v1/pdf/info", files={"file": ("empty.pdf", b"", "application/pdf")})
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "InvalidArgument"


def test_upload_missing_file_400(make_client, fake_engine):
    fake_engine()
    client = make_client()
    resp = client.post("/v1/pdf/info")
    assert resp.status_code == 400
    assert resp.json()["error"]["message"] == "request validation failed"


def test_upload_too_large_413(make_client, fake_engine, monkeypatch):
    fake_engine()
    monkeypatch.setenv("WB_CONVERT_MAX_UPLOAD_MB", "1")
    client = make_client()
    oversized = b"%PDF" + b"0" * (2 * 1024 * 1024)
    resp = client.post("/v1/pdf/info", files={"file": ("big.pdf", oversized, "application/pdf")})
    assert resp.status_code == 413
    assert resp.json()["error"]["code"] == "ResourceExhausted"


def test_unknown_route_and_method_envelopes(make_client):
    client = make_client()
    resp = client.get("/v1/nope")
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NotFound"
    resp = client.delete("/health")
    assert resp.status_code == 405
    assert resp.json()["error"]["code"] == "InvalidArgument"
