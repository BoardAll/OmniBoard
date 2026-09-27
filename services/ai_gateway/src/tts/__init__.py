"""TTS 引擎接口定义。

实现见 ``azure.AzureTTS``（函数级惰性导入 azure SDK；未安装 → 501，
已装未配置 → 503）。
"""

from __future__ import annotations

from typing import Any, Protocol, runtime_checkable


@runtime_checkable
class TTSEngine(Protocol):
    """TTS 统一接口（测试可注入 Fake）。"""

    name: str

    def availability(self) -> dict[str, Any]:
        """返回 {engine, installed, configured}。"""
        ...

    async def synthesize(
        self, text: str, *, voice: str | None = None, locale: str | None = None
    ) -> bytes: ...


__all__ = ["TTSEngine"]
