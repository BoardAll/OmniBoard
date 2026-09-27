"""健康检查与能力上报（全程不触发第三方 SDK 导入）。"""

from __future__ import annotations

import importlib.util
import sys

from fastapi.testclient import TestClient

from src.app import create_app


def _sdk_present(module: str) -> bool:
    try:
        return importlib.util.find_spec(module) is not None
    except (ImportError, ValueError):
        return False


def test_health_reports_service_and_capabilities() -> None:
    client = TestClient(create_app())
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True
    assert body["error"] is None
    data = body["data"]
    assert data["status"] == "ok"
    assert data["name"] == "whiteboard-ai-gateway"
    assert data["version"]

    assert set(data["providers"]) == {"openai", "anthropic", "custom"}
    for name, report in data["providers"].items():
        assert report["provider"] == name
        assert isinstance(report["installed"], bool)
        assert isinstance(report["configured"], bool)

    assert data["asr"]["engine"] == "whisper"
    assert data["tts"]["engine"] == "azure"
    assert data["tools"] >= 1
    assert data["sessions"] == 0


def test_health_matches_actual_sdk_install_state() -> None:
    client = TestClient(create_app())
    data = client.get("/health").json()["data"]
    assert data["asr"]["installed"] == _sdk_present("whisper")
    assert data["tts"]["installed"] == _sdk_present("azure.cognitiveservices.speech")
    assert data["providers"]["openai"]["installed"] == _sdk_present("openai")
    assert data["providers"]["anthropic"]["installed"] == _sdk_present("anthropic")


def test_health_does_not_import_heavy_sdks() -> None:
    """健康检查不得触发重依赖导入（惰性导入约束）。"""
    for module in ("whisper", "openai", "anthropic", "azure.cognitiveservices.speech", "fitz"):
        sys.modules.pop(module, None)
    client = TestClient(create_app())
    assert client.get("/health").status_code == 200
    assert "whisper" not in sys.modules
    assert "openai" not in sys.modules
    assert "anthropic" not in sys.modules
    assert "azure.cognitiveservices.speech" not in sys.modules


def test_providers_endpoint_lists_fakes(make_client) -> None:
    client = make_client()
    response = client.get("/v1/providers")
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["default"] == "fake"
    assert any(report["provider"] == "fake" for report in data["providers"])
