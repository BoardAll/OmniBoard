"""AI 会话管理（内存实现；Wave 4 可替换持久化实现）。

结构对齐《AI 助手与 MCP 设计》§5.3：

- AISession: id / userId / boardId / pageId / selection / contextJson /
  createdAt / updatedAt / messages
- AIMessage: id / role / content / audioUrl / toolCalls / timestamp
- ToolCall:  id / toolId / args / result / status(pending|success|error|cancelled) / timestamp

说明：C++ 侧以字符串存 ``argsJson`` / ``resultJson``，本服务面向 HTTP JSON，
直接暴露解析后的对象（``args`` / ``result``），同时保留 ``contextJson`` 字符串字段对齐契约。
所有读写返回深拷贝，避免调用方意外改动内部状态；操作加锁，兼容多线程测试客户端。
"""

from __future__ import annotations

import copy
import json
import threading
import uuid
from datetime import datetime, timezone
from typing import Any, Iterable

from ..errors import ApiError, NOT_FOUND

#: PATCH 语义哨兵：区分「未提供字段」与「显式置 null」。
UNSET: Any = object()


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:16]}"


class SessionManager:
    """内存会话管理器（FIFO 驱逐，默认上限 256 个会话）。"""

    def __init__(self, *, max_sessions: int = 256) -> None:
        self._sessions: dict[str, dict[str, Any]] = {}
        self._order: list[str] = []
        self._lock = threading.RLock()
        self.max_sessions = max_sessions

    # —— 会话 ——

    def create(
        self,
        board_id: str,
        user_id: str,
        *,
        page_id: str | None = None,
        selection: Iterable[str] | None = None,
        context: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        with self._lock:
            while len(self._sessions) >= self.max_sessions and self._order:
                oldest = self._order.pop(0)
                self._sessions.pop(oldest, None)
            session_id = new_id("sess")
            now = utc_now_iso()
            session: dict[str, Any] = {
                "id": session_id,
                "userId": user_id,
                "boardId": board_id,
                "pageId": page_id,
                "selection": list(selection or []),
                "context": copy.deepcopy(context),
                "contextJson": json.dumps(context, ensure_ascii=False) if context is not None else None,
                "createdAt": now,
                "updatedAt": now,
                "messages": [],
            }
            self._sessions[session_id] = session
            self._order.append(session_id)
            return copy.deepcopy(session)

    def get(self, session_id: str) -> dict[str, Any] | None:
        with self._lock:
            session = self._sessions.get(session_id)
            return copy.deepcopy(session) if session is not None else None

    def require(self, session_id: str) -> dict[str, Any]:
        session = self.get(session_id)
        if session is None:
            raise ApiError(404, NOT_FOUND, f"session not found: {session_id}")
        return session

    def list_summaries(
        self, *, user_id: str | None = None, board_id: str | None = None
    ) -> list[dict[str, Any]]:
        """会话摘要（不含 messages，含 messageCount）。"""
        with self._lock:
            summaries: list[dict[str, Any]] = []
            for session in self._sessions.values():
                if user_id and session["userId"] != user_id:
                    continue
                if board_id and session["boardId"] != board_id:
                    continue
                summary = {
                    key: copy.deepcopy(value) for key, value in session.items() if key != "messages"
                }
                summary["messageCount"] = len(session["messages"])
                summaries.append(summary)
            summaries.sort(key=lambda item: item["createdAt"])
            return summaries

    def update(
        self,
        session_id: str,
        *,
        page_id: Any = UNSET,
        selection: Any = UNSET,
        context: Any = UNSET,
    ) -> dict[str, Any]:
        with self._lock:
            session = self._require_locked(session_id)
            if page_id is not UNSET:
                session["pageId"] = page_id
            if selection is not UNSET:
                session["selection"] = list(selection or [])
            if context is not UNSET:
                session["context"] = copy.deepcopy(context)
                session["contextJson"] = (
                    json.dumps(context, ensure_ascii=False) if context is not None else None
                )
            session["updatedAt"] = utc_now_iso()
            return copy.deepcopy(session)

    def delete(self, session_id: str) -> bool:
        """删除会话；返回是否实际删除（幂等：重复删除返回 False）。"""
        with self._lock:
            existed = self._sessions.pop(session_id, None) is not None
            if existed:
                try:
                    self._order.remove(session_id)
                except ValueError:  # pragma: no cover - 防御
                    pass
            return existed

    def count(self) -> int:
        with self._lock:
            return len(self._sessions)

    # —— 消息 ——

    def add_message(
        self,
        session_id: str,
        *,
        role: str,
        content: str | None = None,
        audio_url: str | None = None,
        tool_calls: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        with self._lock:
            session = self._require_locked(session_id)
            timestamp = utc_now_iso()
            calls = copy.deepcopy(tool_calls or [])
            for call in calls:
                # ToolCall 结构要求 timestamp；Provider 侧未给出时以消息时间补齐。
                if call.get("timestamp") is None:
                    call["timestamp"] = timestamp
            message: dict[str, Any] = {
                "id": new_id("msg"),
                "role": role,
                "content": content,
                "audioUrl": audio_url,
                "toolCalls": calls,
                "timestamp": timestamp,
            }
            session["messages"].append(message)
            session["updatedAt"] = timestamp
            return copy.deepcopy(message)

    def list_messages(self, session_id: str) -> list[dict[str, Any]]:
        with self._lock:
            session = self._require_locked(session_id)
            return copy.deepcopy(session["messages"])

    # —— 工具调用 ——

    def find_tool_call(self, session_id: str, tool_call_id: str) -> dict[str, Any] | None:
        with self._lock:
            session = self._require_locked(session_id)
            for message in session["messages"]:
                for call in message.get("toolCalls", []):
                    if call["id"] == tool_call_id:
                        return copy.deepcopy(call)
            return None

    def update_tool_call(
        self,
        session_id: str,
        tool_call_id: str,
        *,
        status: str | None = None,
        result: Any = UNSET,
    ) -> dict[str, Any]:
        with self._lock:
            session = self._require_locked(session_id)
            for message in session["messages"]:
                for call in message.get("toolCalls", []):
                    if call["id"] == tool_call_id:
                        if status is not None:
                            call["status"] = status
                        if result is not UNSET:
                            call["result"] = copy.deepcopy(result)
                        session["updatedAt"] = utc_now_iso()
                        return copy.deepcopy(call)
            raise ApiError(404, NOT_FOUND, f"tool call not found: {tool_call_id}")

    # —— 内部 ——

    def _require_locked(self, session_id: str) -> dict[str, Any]:
        session = self._sessions.get(session_id)
        if session is None:
            raise ApiError(404, NOT_FOUND, f"session not found: {session_id}")
        return session


__all__ = ["SessionManager", "UNSET", "new_id", "utc_now_iso"]
