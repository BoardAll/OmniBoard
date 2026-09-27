"""工具注册表 / 执行器 / 脱敏审计（离线；转发路径用 MockTransport）。"""

from __future__ import annotations

import json

import httpx
import pytest

from src.errors import ApiError
from src.tools.executor import AuditLog, ToolExecutor
from src.tools.registry import (
    CATEGORIES,
    CONFIRMATIONS,
    TOOL_ID_PATTERN,
    ToolRegistry,
    create_default_registry,
)


def test_default_registry_matches_contract_shape():
    registry = create_default_registry()
    tools = registry.list()
    assert tools  # 默认注册表非空
    ids = [tool.id for tool in tools]
    assert "board.get" in ids and "element.create" in ids and "ai.echo" in ids
    for tool in tools:
        assert TOOL_ID_PATTERN.match(tool.id)
        assert tool.category in CATEGORIES
        assert tool.confirmation in CONFIRMATIONS
        assert tool.parameters["type"] == "object"


def test_registry_rejects_invalid_ids_and_enums():
    registry = ToolRegistry()
    with pytest.raises(ApiError) as ei:
        registry.register("noDots", name="x")
    assert ei.value.status_code == 400
    with pytest.raises(ApiError):
        registry.register("ok.tool", name="x", category="nope")
    with pytest.raises(ApiError):
        registry.register("ok.tool", name="x", confirmation="maybe")
    assert "ok.tool" not in registry


def test_registry_duplicate_register_overrides():
    registry = ToolRegistry()
    first = registry.register("ai.echo", name="first", category="ai")
    second = registry.register("ai.echo", name="second", category="ai")
    assert first.name == "first"
    assert len(registry) == 1
    assert registry.get("ai.echo").name == second.name == "second"
    assert registry.unregister("ai.echo") is True
    assert registry.unregister("ai.echo") is False


def test_tools_endpoint_lists_contract_shape(make_client):
    client = make_client()
    tools = client.get("/v1/tools").json()["data"]["tools"]
    assert tools
    for tool in tools:
        assert "handler" not in tool  # 运行时字段不参与序列化
        assert TOOL_ID_PATTERN.match(tool["id"])
    sample = next(tool for tool in tools if tool["id"] == "element.delete")
    assert sample["confirmation"] == "confirm"


def test_execute_local_tool_and_audit(make_client):
    client = make_client()
    resp = client.post("/v1/tools/execute", json={"tool": "ai.echo", "args": {"k": "v"}, "user": "u-1"})
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["executed"] is True
    assert data["dryRun"] is False
    assert data["confirmation"] is None
    assert data["result"] == {"echo": {"k": "v"}}

    entries = client.app.state.audit.entries()
    assert entries[-1]["action"] == "ai.echo"
    assert entries[-1]["user"] == "u-1"
    assert entries[-1]["result"] == "ok"
    assert set(entries[-1]) == {"timestamp", "user", "action", "target", "result", "source"}


def test_execute_unknown_tool_404(make_client):
    client = make_client()
    resp = client.post("/v1/tools/execute", json={"tool": "nope.missing"})
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NotFound"


def test_confirm_level_returns_confirmation_request(make_client):
    client = make_client()
    resp = client.post(
        "/v1/tools/execute",
        json={"tool": "element.delete", "args": {"boardId": "b1", "elementIds": ["e1"]}},
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["executed"] is False
    assert data["confirmation"]["level"] == "Confirm"
    assert data["result"] is None
    assert client.app.state.audit.entries()[-1]["result"] == "confirmation_required"


def test_confirm_level_executes_after_confirmation(make_client):
    calls: list[dict] = []

    def handler(args: dict) -> dict:
        calls.append(args)
        return {"deleted": args["elementIds"]}

    registry = ToolRegistry()
    registry.register("element.delete", name="删除元素", category="element", confirmation="confirm", handler=handler)
    executor = ToolExecutor(registry)
    client = make_client(tool_registry=registry, tool_executor=executor)

    resp = client.post(
        "/v1/tools/execute",
        json={
            "tool": "element.delete",
            "args": {"boardId": "b1", "elementIds": ["e1"]},
            "confirm": True,
            "user": "u-2",
            "sessionId": "sess-9",
        },
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["executed"] is True
    assert data["result"] == {"deleted": ["e1"]}
    assert calls == [{"boardId": "b1", "elementIds": ["e1"]}]
    assert executor.audit.entries()[-1]["target"] == "sess-9"


def test_forbidden_tool_403(make_client):
    registry = ToolRegistry()
    registry.register("admin.shutdown", name="shutdown", category="admin", confirmation="forbidden")
    client = make_client(tool_registry=registry)
    resp = client.post("/v1/tools/execute", json={"tool": "admin.shutdown"})
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "PermissionDenied"
    assert client.app.state.audit.entries()[-1]["result"] == "denied"


def test_dry_run_local_tool_returns_plan(make_client):
    client = make_client()
    resp = client.post("/v1/tools/execute", json={"tool": "ai.echo", "args": {"a": 1}, "dryRun": True})
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["executed"] is False
    assert data["dryRun"] is True
    assert data["result"] == {"dryRun": True, "plan": {"tool": "ai.echo", "args": {"a": 1}}}


def test_handler_failure_collapses_to_500(make_client):
    def boom(args: dict):
        raise ValueError("nope")

    registry = ToolRegistry()
    registry.register("ai.boom", name="boom", category="ai", handler=boom)
    client = make_client(tool_registry=registry)
    resp = client.post("/v1/tools/execute", json={"tool": "ai.boom"})
    assert resp.status_code == 500
    body = resp.json()
    assert body["error"]["code"] == "InternalError"
    assert "ValueError" in body["error"]["message"]
    assert client.app.state.audit.entries()[-1]["result"] == "error"


def test_unwired_forward_503(make_client):
    client = make_client()  # board.get 无本地 handler，且 WB_BOARD_API_URL 未配置
    resp = client.post("/v1/tools/execute", json={"tool": "board.get", "args": {"boardId": "b1"}})
    assert resp.status_code == 503
    error = resp.json()["error"]
    assert error["code"] == "Unavailable"
    assert "WB_BOARD_API_URL" in error["message"]


def test_forward_success_uses_board_api(make_client):
    recorded: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        recorded["url"] = str(request.url)
        recorded["json"] = json.loads(request.content)
        return httpx.Response(200, json={"ok": True, "data": {"boardId": "b1", "pages": 2}})

    registry = ToolRegistry()
    registry.register("board.get", name="获取白板", category="board")
    executor = ToolExecutor(
        registry,
        forward_base_url="http://board.unit",
        client_factory=lambda: httpx.AsyncClient(transport=httpx.MockTransport(handler)),
    )
    client = make_client(tool_registry=registry, tool_executor=executor)
    resp = client.post(
        "/v1/tools/execute",
        json={"tool": "board.get", "args": {"boardId": "b1"}, "dryRun": True, "user": "u-9", "sessionId": "sess-1"},
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["executed"] is False  # dryRun 不真正执行
    assert data["result"] == {"boardId": "b1", "pages": 2}
    assert recorded["url"] == "http://board.unit/v1/tools/execute"
    assert recorded["json"] == {"tool": "board.get", "args": {"boardId": "b1"}, "dryRun": True, "user": "u-9"}


def test_forward_upstream_error_502(make_client):
    registry = ToolRegistry()
    registry.register("board.get", name="获取白板", category="board")
    executor = ToolExecutor(
        registry,
        forward_base_url="http://board.unit",
        client_factory=lambda: httpx.AsyncClient(
            transport=httpx.MockTransport(lambda request: httpx.Response(503, json={"ok": False}))
        ),
    )
    client = make_client(tool_registry=registry, tool_executor=executor)
    resp = client.post("/v1/tools/execute", json={"tool": "board.get", "args": {"boardId": "b1"}})
    assert resp.status_code == 502
    assert "HTTP 503" in resp.json()["error"]["message"]


def test_audit_log_is_sanitized():
    audit = AuditLog()
    entry = audit.record(action="element.create", user="u1", target="board-1", source="ai")
    assert set(entry) == set(AuditLog.FIELDS)
    assert "args" not in entry and "token" not in json.dumps(entry)
    assert len(audit) == 1
    audit.clear()
    assert len(audit) == 0
