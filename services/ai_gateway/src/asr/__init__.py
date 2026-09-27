"""ASR 引擎接口定义。

实现见 ``whisper.WhisperASR``（函数级惰性导入 ``openai-whisper``；未安装 → 501）。
"""

from __future__ import annotations

from typing import Any, Protocol, runtime_checkable


@runtime_checkable
class ASREngine(Protocol):
    """ASR 统一接口（测试可注入 Fake）。"""

    name: str

    def availability(self) -> dict[str, Any]:
        """返回 {engine, installed, configured}。"""
        ...

    async def transcribe(
        self, audio: bytes, *, language: str | None = None, filename: str = "audio.wav"
    ) -> str: ...


__all__ = ["ASREngine"]
