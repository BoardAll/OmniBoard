"""会话 CRUD / 消息 / 工具调用编排（离线 Fake Provider + 本地工具 handler）。"""

from __future__ import annotations

from conftest import FakeASR, FakeProvider
from src.tools.executor import ToolExecutor
from src.tools.registry import ToolRegistry


def _create_session(client, **overrides):
    payload = {"boardId": "board-1", "userId": "user-1", **overrides}
    resp = client.post("/v1/sessions", json=payload)
    assert resp.status_code == 201
    return resp.json()["data"]


def test_session_crud_roundtrip(make_client):
    client = make_client()
    session = _create_session(client, pageId="page-1", selection=["e1"], context={"topic": "math"})
    assert session["id"].startswith("sess_")
    assert session["contextJson"] == '{"topic": "math"}'
    assert session["messages"] == []

    fetched = client.get(f"/v1/sessions/{session['id']}").json()["data"]
    assert fetched["pageId"] == "page-1"
    assert fetched["selection"] == ["e1"]

    listed = client.get("/v1/sessions", params={"boardId": "board-1"}).json()["data"]
    assert listed["total"] == 1
    assert listed["sessions"][0]["messageCount"] == 0
    assert "messages" not in listed["sessions"][0]

    deleted = client.delete(f"/v1/sessions/{session['id']}").json()["data"]
    assert deleted == {"sessionId": session["id"], "deleted": True, "alreadyDeleted": False}
    again = client.delete(f"/v1/sessions/{session['id']}").json()["data"]
    assert again == {"sessionId": session["id"], "deleted": False, "alreadyDeleted": True}
    assert client.get(f"/v1/sessions/{session['id']}").status_code == 404


def test_session_list_filters_by_user_and_board(make_client):
    client = make_client()
    _create_session(client, boardId="board-1", userId="user-1")
    _create_session(client, boardId="board-2", userId="user-1")
    _create_session(client, boardId="board-1", userId="user-2")

    by_board = client.get("/v1/sessions", params={"boardId": "board-1"}).json()["data"]
    assert len(by_board["sessions"]) == 2
    by_user = client.get("/v1/sessions", params={"userId": "user-2"}).json()["data"]
    assert len(by_user["sessions"]) == 1
    assert by_user["total"] == 3  # total 是会话总数


def test_session_patch_sentinel_semantics(make_client):
    client = make_client()
    session = _create_session(client, pageId="page-1", selection=["e1"], context={"a": 1})

    patched = client.patch(f"/v1/sessions/{session['id']}", json={"pageId": None}).json()["data"]
    assert patched["pageId"] is None
    assert patched["selection"] == ["e1"]  # 未提供的字段保持原值

    patched = client.patch(f"/v1/sessions/{session['id']}", json={"selection": ["e2"]}).json()["data"]
    assert patched["selection"] == ["e2"]
    assert patched["pageId"] is None

    patched = client.patch(f"/v1/sessions/{session['id']}", json={"context": {"b": 2}}).json()["data"]
    assert patched["context"] == {"b": 2}
    assert patched["contextJson"] == '{"b": 2}'


def test_session_patch_unknown_404(make_client):
    client = make_client()
    resp = client.patch("/v1/sessions/missing", json={"pageId": "x"})
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NotFound"


def test_send_message_uses_provider_and_stores_history(make_client):
    provider = FakeProvider()
    client = make_client(providers={"fake": provider})
    session = _create_session(client)

    resp = client.post(f"/v1/sessions/{session['id']}/messages", json={"content": "hello"})
    assert resp.status_code == 201
    data = resp.json()["data"]
    assert data["provider"] == "fake"
    assert data["message"]["role"] == "assistant"
    assert data["message"]["content"] == "Hello from fake provider"

    request = provider.calls[-1][1]
    assert [message.role for message in request.messages] == ["user"]
    assert request.messages[0].content == "hello"

    messages = client.get(f"/v1/sessions/{session['id']}/messages").json()["data"]["messages"]
    assert [message["role"] for message in messages] == ["user", "assistant"]
    assert all(message["timestamp"] for message in messages)


def test_send_message_unknown_session_404(make_client):
    client = make_client()
    resp = client.post("/v1/sessions/missing/messages", json={"content": "hi"})
    assert resp.status_code == 404


def test_provider_tool_calls_become_pending(make_client):
    provider = FakeProvider(
        tool_calls=[{"id": "call_1", "name": "element.create", "arguments": '{"boardId": "b1"}'}]
    )
    client = make_client(providers={"fake": provider})
    session = _create_session(client)
    client.post(f"/v1/sessions/{session['id']}/messages", json={"content": "create a note"})

    messages = client.get(f"/v1/sessions/{session['id']}/messages").json()["data"]["messages"]
    call = messages[-1]["toolCalls"][0]
    assert call["id"].startswith("tc_")
    assert call["toolId"] == "element.create"
    assert call["args"] == {"boardId": "b1"}
    assert call["status"] == "pending"
    assert call["timestamp"]


# —— 工具调用编排 ——


def _setup_tool_call(
    make_client,
    *,
    handler,
    tool_id: str = "element.create",
    confirmation: str = "auto",
    arguments: str = '{"boardId": "b1"}',
):
    registry = ToolRegistry()
    registry.register(tool_id, name="测试工具", category="element", confirmation=confirmation, handler=handler)
    executor = ToolExecutor(registry)
    provider = FakeProvider(tool_calls=[{"id": "call_1", "name": tool_id, "arguments": arguments}])
    client = make_client(providers={"fake": provider}, tool_registry=registry, tool_executor=executor)
    session = _create_session(client, boardId="b1", userId="user-7")
    client.post(f"/v1/sessions/{session['id']}/messages", json={"content": "go"})
    messages = client.get(f"/v1/sessions/{session['id']}/messages").json()["data"]["messages"]
    tool_call = messages[-1]["toolCalls"][0]
    return client, session, tool_call, executor


def test_tool_call_preview_then_execute(make_client):
    seen: list[dict] = []

    def handler(args):
        seen.append(args)
        return {"created": ["e1"]}

    client, session, call, executor = _setup_tool_call(make_client, handler=handler)
    base = f"/v1/sessions/{session['id']}/toolCalls/{call['id']}"

    preview = client.post(f"{base}/preview").json()["data"]
    assert preview["preview"]["executed"] is False
    assert preview["preview"]["result"]["plan"] == {"tool": "element.create", "args": {"boardId": "b1"}}
    assert seen == []  # dry-run 不触达 handler

    executed = client.post(f"{base}/execute").json()["data"]
    assert executed["execution"]["executed"] is True
    assert executed["toolCall"]["status"] == "success"
    assert executed["toolCall"]["result"] == {"created": ["e1"]}
    assert seen == [{"boardId": "b1"}]
    assert executor.audit.entries()[-1]["user"] == "user-7"


def test_tool_call_requires_confirmation(make_client):
    calls: list[dict] = []

    def handler(args):
        calls.append(args)
        return {"deleted": args.get("elementIds", [])}

    client, session, call, _ = _setup_tool_call(
        make_client,
        handler=handler,
        tool_id="element.delete",
        confirmation="confirm",
        arguments='{"boardId": "b1", "elementIds": ["e1"]}',
    )
    base = f"/v1/sessions/{session['id']}/toolCalls/{call['id']}"

    first = client.post(f"{base}/execute").json()["data"]
    assert first["execution"]["executed"] is False
    assert first["execution"]["confirmation"]["level"] == "Confirm"
    assert first["toolCall"]["status"] == "pending"
    assert calls == []

    second = client.post(f"{base}/execute", json={"confirm": True}).json()["data"]
    assert second["execution"]["executed"] is True
    assert second["toolCall"]["status"] == "success"
    assert second["toolCall"]["result"] == {"deleted": ["e1"]}
    assert calls == [{"boardId": "b1", "elementIds": ["e1"]}]


def test_tool_call_cancel_idempotent_then_conflict(make_client):
    client, session, call, _ = _setup_tool_call(make_client, handler=lambda args: {"ok": True})
    base = f"/v1/sessions/{session['id']}/toolCalls/{call['id']}"

    cancelled = client.post(f"{base}/cancel").json()["data"]
    assert cancelled["toolCall"]["status"] == "cancelled"
    again = client.post(f"{base}/cancel").json()["data"]
    assert again["toolCall"]["status"] == "cancelled"  # 幂等

    resp = client.post(f"{base}/execute")
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "Conflict"


def test_tool_call_execution_error_recorded(make_client):
    def boom(args):
        raise RuntimeError("kaboom")

    client, session, call, _ = _setup_tool_call(make_client, handler=boom)
    base = f"/v1/sessions/{session['id']}/toolCalls/{call['id']}"

    resp = client.post(f"{base}/execute")
    assert resp.status_code == 500
    messages = client.get(f"/v1/sessions/{session['id']}/messages").json()["data"]["messages"]
    recorded = messages[-1]["toolCalls"][0]
    assert recorded["status"] == "error"
    assert recorded["result"]["ok"] is False
    assert recorded["result"]["error"]["code"] == "InternalError"


def test_tool_call_unknown_404(make_client):
    client = make_client()
    session = _create_session(client)
    resp = client.post(f"/v1/sessions/{session['id']}/toolCalls/tc_missing/execute")
    assert resp.status_code == 404


def test_session_audio_endpoint_appends_message(make_client):
    client = make_client(asr=FakeASR("transcribed!"))
    session = _create_session(client)
    resp = client.post(
        f"/v1/sessions/{session['id']}/audio", files={"file": ("clip.wav", b"RIFF", "audio/wav")}
    )
    assert resp.status_code == 201
    data = resp.json()["data"]
    assert data["text"] == "transcribed!"
    assert data["message"]["role"] == "user"
    messages = client.get(f"/v1/sessions/{session['id']}/messages").json()["data"]["messages"]
    assert len(messages) == 1
