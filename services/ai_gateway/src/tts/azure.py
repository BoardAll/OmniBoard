"""Azure Speech TTS（函数级惰性导入；未安装 → 501，已装未配置 → 503）。

- 模块 import 不触碰 ``azure.cognitiveservices.speech``（重依赖）。
- 合成（阻塞）经 ``asyncio.to_thread`` 执行，避免阻塞事件循环。
- 凭据仅从环境变量 ``AZURE_SPEECH_KEY`` / ``AZURE_SPEECH_REGION`` 读取，绝不记录。
"""

from __future__ import annotations

import asyncio
import os
from typing import Any

from ..errors import ApiError, INTERNAL_ERROR, INVALID_ARGUMENT, ProviderNotConfigured, ProviderNotInstalled
from ..providers import sdk_installed
from . import TTSEngine  # noqa: F401 - 保证接口与实现同包导出

DEFAULT_VOICE = "zh-CN-XiaoxiaoNeural"
KEY_ENV = "AZURE_SPEECH_KEY"
REGION_ENV = "AZURE_SPEECH_REGION"

_SDK_MODULE = "azure.cognitiveservices.speech"


def _load_speechsdk() -> Any:
    """函数级惰性导入 azure speech SDK（测试可 monkeypatch 注入假模块）。"""
    try:
        import azure.cognitiveservices.speech as speechsdk  # type: ignore[import-not-found]  # noqa: PLC0415
    except ImportError as exc:
        raise ProviderNotInstalled(
            "azure-cognitiveservices-speech",
            "pip install azure-cognitiveservices-speech (heavy dependency, optional)",
        ) from exc
    return speechsdk


class AzureTTS:
    """Azure Speech 语音合成引擎。"""

    name = "azure"

    def __init__(
        self,
        *,
        speech_key: str | None = None,
        region: str | None = None,
        voice: str | None = None,
    ) -> None:
        self._speech_key = speech_key
        self._region = region
        self.voice = voice or os.environ.get("WB_AZURE_TTS_VOICE") or DEFAULT_VOICE

    # —— 配置与可用性 ——

    def resolve_key(self) -> str | None:
        return self._speech_key or os.environ.get(KEY_ENV) or None

    def resolve_region(self) -> str | None:
        return self._region or os.environ.get(REGION_ENV) or None

    def availability(self) -> dict[str, Any]:
        return {
            "engine": self.name,
            "installed": sdk_installed(_SDK_MODULE),
            "configured": bool(self.resolve_key() and self.resolve_region()),
        }

    async def synthesize(
        self, text: str, *, voice: str | None = None, locale: str | None = None
    ) -> bytes:
        if not text or not text.strip():
            raise ApiError(400, INVALID_ARGUMENT, "text must be non-empty")
        return await asyncio.to_thread(self._synthesize_sync, text, voice, locale)

    # —— 同步实现（在线程中执行）——

    def _synthesize_sync(self, text: str, voice: str | None, locale: str | None) -> bytes:
        speechsdk = _load_speechsdk()
        key = self.resolve_key()
        region = self.resolve_region()
        if not key or not region:
            raise ProviderNotConfigured(
                "azure-speech", f"{KEY_ENV}/{REGION_ENV}", "set both environment variables"
            )

        speech_config = speechsdk.SpeechConfig(subscription=key, region=region)
        selected_voice = voice or self.voice
        if locale:
            speech_config.speech_synthesis_language = locale
        if selected_voice:
            speech_config.speech_synthesis_voice_name = selected_voice

        synthesizer = speechsdk.SpeechSynthesizer(speech_config=speech_config)
        result = synthesizer.speak_text_async(text).get()
        reason = getattr(result, "reason", None)
        completed = getattr(getattr(speechsdk, "ResultReason", None), "SynthesizingAudioCompleted", None)
        if completed is not None and reason != completed:
            raise ApiError(502, INTERNAL_ERROR, "azure speech synthesis did not complete")
        audio = getattr(result, "audio_data", None)
        if not audio:
            raise ApiError(502, INTERNAL_ERROR, "azure speech synthesis returned no audio")
        return bytes(audio)


__all__ = ["AzureTTS", "DEFAULT_VOICE", "KEY_ENV", "REGION_ENV"]
