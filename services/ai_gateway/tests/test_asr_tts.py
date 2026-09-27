"""ASR / TTS：501 降级路径、Fake 引擎、注入假 SDK（离线，不装重依赖）。"""

from __future__ import annotations

import asyncio
import os
from types import SimpleNamespace

import pytest

from src.asr import whisper as whisper_module
from src.asr.whisper import WhisperASR
from src.errors import ProviderNotInstalled
from src.providers import sdk_installed
from src.tts import azure as azure_module
from src.tts.azure import AzureTTS

WHISPER_MISSING = pytest.mark.skipif(sdk_installed("whisper"), reason="whisper 已安装（本 venv 预期未装）")
AZURE_MISSING = pytest.mark.skipif(
    sdk_installed("azure.cognitiveservices.speech"), reason="azure speech SDK 已安装（本 venv 预期未装）"
)


# —— ASR ——


@WHISPER_MISSING
def test_asr_route_501_when_whisper_missing(make_client):
    client = make_client(asr=None)  # 使用真实 WhisperASR（默认装配）
    resp = client.post("/v1/asr/transcribe", files={"file": ("a.wav", b"RIFF0000", "audio/wav")})
    assert resp.status_code == 501
    error = resp.json()["error"]
    assert error["code"] == "NotSupported"
    assert "openai-whisper is not installed" in error["message"]
    assert error["details"]["sdk"] == "openai-whisper"


@WHISPER_MISSING
def test_asr_direct_501_when_whisper_missing():
    with pytest.raises(ProviderNotInstalled) as ei:
        asyncio.run(WhisperASR().transcribe(b"RIFF", filename="a.wav"))
    assert ei.value.status_code == 501


def test_asr_fake_whisper_transcribes_and_cleans_temp(monkeypatch, make_client):
    seen: dict = {}

    class _FakeModel:
        def transcribe(self, path, language=None):
            seen["path"] = path
            seen["language"] = language
            assert os.path.exists(path)
            return {"text": "  hello world  "}

    class _FakeWhisper:
        def __init__(self) -> None:
            self.loaded: list[str] = []

        def load_model(self, name):
            self.loaded.append(name)
            return _FakeModel()

    fake = _FakeWhisper()
    monkeypatch.setattr(whisper_module, "_load_whisper", lambda: fake)

    client = make_client(asr=None)
    resp = client.post(
        "/v1/asr/transcribe",
        files={"file": ("clip.wav", b"RIFF0000", "audio/wav")},
        data={"language": "en"},
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["text"] == "hello world"
    assert data["engine"] == "whisper"
    assert fake.loaded == ["base"]
    assert seen["language"] == "en"
    assert not os.path.exists(seen["path"])  # 临时文件已清理


def test_asr_empty_file_400(make_client):
    client = make_client()
    resp = client.post("/v1/asr/transcribe", files={"file": ("a.wav", b"", "audio/wav")})
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "InvalidArgument"


def test_asr_binds_message_to_session(make_client):
    client = make_client()
    session = client.post("/v1/sessions", json={"boardId": "b1", "userId": "u1"}).json()["data"]
    resp = client.post(
        "/v1/asr/transcribe",
        files={"file": ("a.wav", b"RIFF", "audio/wav")},
        data={"sessionId": session["id"]},
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["sessionId"] == session["id"]
    messages = client.get(f"/v1/sessions/{session['id']}/messages").json()["data"]["messages"]
    assert messages[-1]["content"] == "fake transcript"
    assert messages[-1]["role"] == "user"
    assert messages[-1]["id"] == data["messageId"]


def test_asr_unknown_session_404(make_client):
    client = make_client()
    resp = client.post(
        "/v1/asr/transcribe",
        files={"file": ("a.wav", b"RIFF", "audio/wav")},
        data={"sessionId": "nope"},
    )
    assert resp.status_code == 404


# —— TTS ——


@AZURE_MISSING
def test_tts_route_501_when_azure_missing(make_client):
    client = make_client(tts=None)  # 使用真实 AzureTTS（默认装配）
    resp = client.post("/v1/tts/synthesize", json={"text": "你好"})
    assert resp.status_code == 501
    error = resp.json()["error"]
    assert error["code"] == "NotSupported"
    assert "azure-cognitiveservices-speech is not installed" in error["message"]


@AZURE_MISSING
def test_tts_azure_direct_501():
    with pytest.raises(ProviderNotInstalled) as ei:
        asyncio.run(AzureTTS().synthesize("hi"))
    assert ei.value.status_code == 501


def test_tts_fake_engine_returns_audio(make_client):
    client = make_client()
    resp = client.post("/v1/tts/synthesize", json={"text": "hi", "voice": "v1"})
    assert resp.status_code == 200
    assert resp.content == b"RIFF-fake-audio"
    assert resp.headers["content-type"].startswith("audio/wav")
    assert resp.headers["x-tts-engine"] == "fake-tts"


def test_tts_empty_text_400(make_client):
    client = make_client()
    resp = client.post("/v1/tts/synthesize", json={"text": ""})
    assert resp.status_code == 400


def test_tts_azure_fake_sdk_synthesizes(monkeypatch, make_client):
    calls: dict = {}

    class _FakeSpeechConfig:
        def __init__(self, subscription=None, region=None):
            calls["subscription"] = subscription
            calls["region"] = region
            self.speech_synthesis_language = None
            self.speech_synthesis_voice_name = None

    class _FakeResult:
        reason = 2  # ResultReason.SynthesizingAudioCompleted
        audio_data = b"WAVE-BYTES"

    class _FakeSynthesizer:
        def __init__(self, speech_config=None):
            calls["config"] = speech_config

        def speak_text_async(self, text):
            calls["text"] = text
            return SimpleNamespace(get=lambda: _FakeResult())

    fake_sdk = SimpleNamespace(
        SpeechConfig=_FakeSpeechConfig,
        SpeechSynthesizer=_FakeSynthesizer,
        ResultReason=SimpleNamespace(SynthesizingAudioCompleted=2),
    )
    monkeypatch.setattr(azure_module, "_load_speechsdk", lambda: fake_sdk)
    monkeypatch.setenv("AZURE_SPEECH_KEY", "unit-key")
    monkeypatch.setenv("AZURE_SPEECH_REGION", "unit-region")

    client = make_client(tts=None)
    resp = client.post(
        "/v1/tts/synthesize",
        json={"text": "你好", "voice": "zh-CN-YunxiNeural", "locale": "zh-CN"},
    )
    assert resp.status_code == 200
    assert resp.content == b"WAVE-BYTES"
    assert resp.headers["x-tts-engine"] == "azure"
    assert calls["subscription"] == "unit-key" and calls["region"] == "unit-region"
    assert calls["text"] == "你好"
    assert calls["config"].speech_synthesis_language == "zh-CN"
    assert calls["config"].speech_synthesis_voice_name == "zh-CN-YunxiNeural"


def test_tts_azure_missing_config_503(monkeypatch, make_client):
    monkeypatch.setattr(azure_module, "_load_speechsdk", lambda: SimpleNamespace())
    client = make_client(tts=None)
    resp = client.post("/v1/tts/synthesize", json={"text": "hi"})
    assert resp.status_code == 503
    error = resp.json()["error"]
    assert error["code"] == "Unavailable"
    assert "AZURE_SPEECH_KEY" in error["message"]
