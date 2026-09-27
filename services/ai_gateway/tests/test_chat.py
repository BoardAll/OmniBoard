"""聊天端点：非流式 / 流式 SSE / 错误收敛（全部离线，经 Fake Provider）。"""

from __future__ import annotations

import json

from conftest import ExplodingProvider, FakeProvider, FakeTextOnlyProvider, read_sse_events


def _chat_payload(**overrides) -> dict:
    payload = {"messages": [{"role": "user", "content": "hi"}]}
    payload.update(overrides)
    return payload


def test_chat_non_stream(make_client):
    client = make_client()
    resp = client.post("/v1/chat/completions", json=_chat_payload())
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True and body["error"] is None
    data = body["data"]
    assert data["id"].startswith("chatcmpl_")
    assert data["provider"] == "fake"
    assert data["model"] == "fake-1"
    assert data["message"] == {
        "role": "assistant",
        "content": "Hello from fake provider",
        "toolCalls": [],
    }
    assert data["finishReason"] == "stop"
    assert data["usage"] == {"promptTokens": 3, "completionTokens": 5, "totalTokens": 8}


def test_chat_passes_through_options(make_client):
    provider = FakeProvider()
    client = make_client(providers={"fake": provider})
    tools = [
        {
            "type": "function",
            "function": {"name": "element.create", "parameters": {"type": "object", "properties": {}}},
        }
    ]
    resp = client.post(
        "/v1/chat/completions",
        json=_chat_payload(tools=tools, temperature=0.25, max_tokens=64, model="picked-model"),
    )
    assert resp.status_code == 200
    request = provider.calls[-1][1]
    assert request.tools == tools
    assert request.temperature == 0.25
    assert request.max_tokens == 64
    assert request.model == "picked-model"


def test_chat_unknown_provider_404(make_client):
    client = make_client()
    resp = client.post("/v1/chat/completions", json=_chat_payload(provider="nope"))
    assert resp.status_code == 404
    error = resp.json()["error"]
    assert error["code"] == "NotFound"
    assert "nope" in error["message"]
    assert error["details"]["available"] == ["fake"]


def test_chat_provider_failure_502(make_client):
    client = make_client(providers={"boom": ExplodingProvider()}, default_provider="boom")
    resp = client.post("/v1/chat/completions", json=_chat_payload())
    assert resp.status_code == 502
    error = resp.json()["error"]
    assert error["code"] == "InternalError"
    assert "RuntimeError" in error["message"]


def test_chat_stream_sse(make_client):
    client = make_client()
    status, lines = read_sse_events(client, "/v1/chat/completions", _chat_payload(stream=True))
    assert status == 200
    assert lines[-1] == "data: [DONE]"
    events = [json.loads(line[len("data: ") :]) for line in lines[:-1]]
    assert [event["type"] for event in events] == ["chunk", "chunk", "chunk", "done"]
    assert [event["delta"] for event in events[:2]] == ["Hel", "lo"]
    assert events[2]["finishReason"] == "stop"
    assert events[3] == {"type": "done", "finishReason": "stop"}


def test_chat_stream_error_event(make_client):
    client = make_client(providers={"boom": ExplodingProvider()}, default_provider="boom")
    status, lines = read_sse_events(client, "/v1/chat/completions", _chat_payload(stream=True))
    assert status == 200  # 流已开始，错误以事件形式下发
    assert lines[-1] == "data: [DONE]"
    events = [json.loads(line[len("data: ") :]) for line in lines[:-1]]
    assert [event["type"] for event in events] == ["chunk", "error"]
    assert events[0]["delta"] == "par"
    assert events[1]["error"]["code"] == "Unavailable"
    assert "config missing" in events[1]["error"]["message"]


def test_embeddings_success(make_client):
    provider = FakeProvider()
    client = make_client(providers={"fake": provider})
    resp = client.post("/v1/embeddings", json={"input": ["a", "b"]})
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["provider"] == "fake"
    assert data["embeddings"] == [[0.1] * 4, [0.1] * 4]
    assert provider.calls[-1][1].input == ["a", "b"]


def test_embeddings_not_supported_501(make_client):
    client = make_client(providers={"textonly": FakeTextOnlyProvider()}, default_provider="textonly")
    resp = client.post("/v1/embeddings", json={"input": "hello"})
    assert resp.status_code == 501
    error = resp.json()["error"]
    assert error["code"] == "NotSupported"
    assert "textonly" in error["message"]
