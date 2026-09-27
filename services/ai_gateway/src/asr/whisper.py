"""OpenAI Whisper ASR（函数级惰性导入；未安装 → 501 NotSupported）。

- 模块 import 不触碰 ``whisper``（音频重依赖）。
- 模型加载与转写为阻塞操作，经 ``asyncio.to_thread`` 执行，避免阻塞事件循环。
- 转写临时文件用后即删；不记录音频内容与路径。
"""

from __future__ import annotations

import asyncio
import os
import tempfile
from pathlib import Path
from typing import Any

from ..errors import ApiError, INVALID_ARGUMENT, ProviderNotInstalled
from ..providers import sdk_installed
from . import ASREngine  # noqa: F401 - 保证接口与实现同包导出

DEFAULT_MODEL = "base"


def _load_whisper() -> Any:
    """函数级惰性导入 whisper（测试可 monkeypatch 注入假模块）。"""
    try:
        import whisper  # type: ignore[import-not-found]  # noqa: PLC0415
    except ImportError as exc:
        raise ProviderNotInstalled(
            "openai-whisper", "pip install openai-whisper (heavy dependency, optional)"
        ) from exc
    return whisper


class WhisperASR:
    """Whisper 本地转写引擎。"""

    name = "whisper"

    def __init__(self, *, model_name: str | None = None) -> None:
        self.model_name = model_name or os.environ.get("WB_WHISPER_MODEL") or DEFAULT_MODEL
        self._model: Any = None

    def availability(self) -> dict[str, Any]:
        return {"engine": self.name, "installed": sdk_installed("whisper"), "configured": True}

    async def transcribe(
        self, audio: bytes, *, language: str | None = None, filename: str = "audio.wav"
    ) -> str:
        if not audio:
            raise ApiError(400, INVALID_ARGUMENT, "audio payload is empty")
        return await asyncio.to_thread(self._transcribe_sync, audio, language, filename)

    # —— 同步实现（在线程中执行）——

    def _transcribe_sync(self, audio: bytes, language: str | None, filename: str) -> str:
        whisper = _load_whisper()
        model = self._model
        if model is None:
            model = whisper.load_model(self.model_name)
            self._model = model

        suffix = Path(filename).suffix or ".wav"
        handle, tmp_path = tempfile.mkstemp(prefix="wb_asr_", suffix=suffix)
        os.close(handle)
        try:
            with open(tmp_path, "wb") as stream:
                stream.write(audio)
            result = model.transcribe(tmp_path, language=language)
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

        text: Any
        if isinstance(result, dict):
            text = result.get("text")
        else:
            text = getattr(result, "text", "")
        return str(text or "").strip()


__all__ = ["WhisperASR", "DEFAULT_MODEL"]
