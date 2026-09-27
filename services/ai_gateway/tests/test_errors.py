"""统一错误信封：404 / 405 / 校验 400 / 未捕获 500（全程离线）。"""

from __future__ import annotations

from fastapi.testclient import TestClient

from src.app import create_app


def test_unknown_route_404_envelope(make_client):
    client = make_client()
    resp = client.get("/v1/does-not-exist")
    assert resp.status_code == 404
    body = resp.json()
    assert body["ok"] is False and body["data"] is None
    assert body["error"]["code"] == "NotFound"


def test_method_not_allowed_405_envelope(make_client):
    client = make_client()
    resp = client.delete("/health")
    assert resp.status_code == 405
    assert resp.json()["error"]["code"] == "InvalidArgument"


def test_request_validation_400_envelope(make_client):
    client = make_client()
    resp = client.post("/v1/chat/completions", json={"messages": []})
    assert resp.status_code == 400
    error = resp.json()["error"]
    assert error["code"] == "InvalidArgument"
    assert error["message"] == "request validation failed"
    errors = error["details"]["errors"]
    assert errors
    assert "loc" in errors[0] and "reason" in errors[0]


def test_malformed_json_400_envelope(make_client):
    client = make_client()
    resp = client.post(
        "/v1/chat/completions",
        content=b"{not-json",
        headers={"content-type": "application/json"},
    )
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "InvalidArgument"


def test_unhandled_error_500_envelope():
    class BrokenProvider:
        name = "broken"

        def availability(self) -> dict:
            raise RuntimeError("availability exploded")

    app = create_app(providers={"broken": BrokenProvider()})
    with TestClient(app, raise_server_exceptions=False) as client:
        resp = client.get("/health")
    assert resp.status_code == 500
    assert resp.json() == {
        "ok": False,
        "data": None,
        "error": {"code": "InternalError", "message": "internal error"},
    }
