"""工具执行器与脱敏审计。

执行策略：
1. 工具带本地 ``handler`` → 直接调用（同步/异步均支持）。
2. 无 handler → 转发板端 API（``WB_BOARD_API_URL`` / 构造参数注入）；
   未配置 → 503 Unavailable。
3. ``confirmation="confirm"`` 且未 ``confirmed`` → 返回确认诉求（不执行）。
4. ``confirmation="forbidden"`` → 403 PermissionDenied。
5. ``dry_run`` → 本地工具返回执行计划（不调用 handler）；转发时携带 ``dryRun`` 标志。

审计：仅记录 时间 / 用户 / 动作 / 目标 / 结果 / 来源（对齐《AI 助手与 MCP 设计》§3.5），
绝不记录参数与凭据。
"""

from __future__ import annotations

import inspect
import os
from collections import deque
from datetime import datetime, timezone
from typing import Any, Callable

from ..errors import (
    ApiError,
    INTERNAL_ERROR,
    NOT_FOUND,
    PERMISSION_DENIED,
    UNAVAILABLE,
    UpstreamError,
)
from .registry import ToolHandler, ToolRegistry

HTTPClientFactory = Callable[[], Any]


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class AuditLog:
    """内存审计日志（脱敏：仅保留固定字段，不含参数/body/凭据）。"""

    FIELDS = ("timestamp", "user", "action", "target", "result", "source")

    def __init__(self, maxlen: int = 1000) -> None:
        self._entries: deque[dict[str, Any]] = deque(maxlen=maxlen)

    def record(
        self,
        *,
        action: str,
        user: str | None = None,
        target: str | None = None,
        result: str = "ok",
        source: str = "ai",
    ) -> dict[str, Any]:
        entry = {
            "timestamp": _utc_now_iso(),
            "user": user,
            "action": action,
            "target": target,
            "result": result,
            "source": source,
        }
        self._entries.append(entry)
        return dict(entry)

    def entries(self) -> list[dict[str, Any]]:
        return [dict(entry) for entry in self._entries]

    def clear(self) -> None:
        self._entries.clear()

    def __len__(self) -> int:
        return len(self._entries)


class ToolExecutor:
    """工具执行器（本地 handler 优先，否则转发板端 API）。"""

    def __init__(
        self,
        registry: ToolRegistry,
        *,
        forward_base_url: str | None = None,
        audit: AuditLog | None = None,
        client_factory: HTTPClientFactory | None = None,
        timeout: float = 30.0,
    ) -> None:
        self.registry = registry
        self.audit = audit or AuditLog()
        self._forward_base_url = forward_base_url
        self._client_factory = client_factory
        self.timeout = timeout

    @property
    def forward_base_url(self) -> str:
        return (self._forward_base_url or os.environ.get("WB_BOARD_API_URL") or "").rstrip("/")

    async def execute(
        self,
        tool_id: str,
        args: dict[str, Any] | None = None,
        *,
        dry_run: bool = False,
        confirmed: bool = False,
        user: str | None = None,
        source: str = "ai",
        session_id: str | None = None,
    ) -> dict[str, Any]:
        """执行工具；返回执行数据（由路由层包装成功信封）。

        抛 ``ApiError``：404 未注册 / 403 forbidden / 503 未接线 / 500 执行失败。
        """
        tool = self.registry.get(tool_id)
        if tool is None:
            raise ApiError(404, NOT_FOUND, f"tool not registered: {tool_id}")
        arguments = args or {}
        target = session_id or tool_id

        if tool.confirmation == "forbidden":
            self.audit.record(action=tool_id, user=user, target=target, result="denied", source=source)
            raise ApiError(403, PERMISSION_DENIED, f"tool {tool_id} is forbidden for AI execution")

        if tool.confirmation == "confirm" and not confirmed:
            self.audit.record(
                action=tool_id, user=user, target=target, result="confirmation_required", source=source
            )
            return {
                "tool": tool_id,
                "executed": False,
                "dryRun": dry_run,
                "confirmation": {
                    "level": "Confirm",
                    "prompt": f"tool {tool_id} requires explicit confirmation before execution",
                },
                "result": None,
            }

        try:
            if tool.handler is not None:
                if dry_run:
                    result: Any = {"dryRun": True, "plan": {"tool": tool_id, "args": arguments}}
                else:
                    result = await self._invoke(tool.handler, arguments)
            else:
                result = await self._forward(tool_id, arguments, dry_run=dry_run, user=user)
        except ApiError:
            self.audit.record(action=tool_id, user=user, target=target, result="error", source=source)
            raise
        except Exception as exc:  # noqa: BLE001 - 统一收敛为工具执行失败
            self.audit.record(action=tool_id, user=user, target=target, result="error", source=source)
            raise ApiError(
                500, INTERNAL_ERROR, f"tool {tool_id} execution failed ({type(exc).__name__})"
            ) from exc

        self.audit.record(action=tool_id, user=user, target=target, result="ok", source=source)
        return {
            "tool": tool_id,
            "executed": not dry_run,
            "dryRun": dry_run,
            "confirmation": None,
            "result": result,
        }

    # —— 内部 ——

    @staticmethod
    async def _invoke(handler: ToolHandler, args: dict[str, Any]) -> Any:
        result = handler(args)
        if inspect.isawaitable(result):
            result = await result
        return result

    async def _forward(
        self, tool_id: str, args: dict[str, Any], *, dry_run: bool, user: str | None
    ) -> Any:
        base = self.forward_base_url
        if not base:
            raise ApiError(
                503,
                UNAVAILABLE,
                f"tool {tool_id} has no local handler and WB_BOARD_API_URL is not configured",
            )
        payload = {"tool": tool_id, "args": args, "dryRun": dry_run, "user": user}
        client = self._make_client()
        try:
            async with client as http:
                response = await http.post(f"{base}/v1/tools/execute", json=payload)
        except ApiError:
            raise
        except Exception as exc:  # noqa: BLE001 - 上游网络错误收敛为 502
            raise UpstreamError("board-api", type(exc).__name__) from exc
        status = int(getattr(response, "status_code", 0))
        if status >= 400:
            raise UpstreamError("board-api", f"HTTP {status}")
        body = response.json()
        if isinstance(body, dict) and "data" in body:
            return body["data"]
        return body

    def _make_client(self) -> Any:
        if self._client_factory is not None:
            return self._client_factory()
        import httpx  # noqa: PLC0415 - 函数级惰性导入

        return httpx.AsyncClient(timeout=self.timeout)


__all__ = ["AuditLog", "ToolExecutor", "HTTPClientFactory"]
