"""Whiteboard AI Gateway —— FastAPI 应用装配（Wave 2.9）。

职责（《AI 助手与 MCP 设计》§5.1）：统一接入 OpenAI / Anthropic / 自定义
OpenAI 兼容端点；统一 Tool Calling；ASR / TTS；会话上下文；审计。

端点点位
--------
- ``GET  /health``                          健康检查 + 能力可用性（不触发 SDK 导入）
- ``GET  /v1/providers``                    Provider 列表及安装/配置状态
- ``POST /v1/chat/completions``             对话（``stream=true`` → SSE）
- ``POST /v1/embeddings``                   向量（Provider 可选能力，未实现 → 501）
- ``GET  /v1/tools``                        工具列表（tool.schema.json 形状）
- ``POST /v1/tools/execute``                工具执行（dryRun / confirm）
- ``POST /v1/asr/transcribe``               语音转写（Whisper 惰性导入，未装 → 501）
- ``POST /v1/tts/synthesize``               语音合成（Azure 惰性导入；成功返回音频字节）
- ``POST /v1/sessions``                     创建会话
- ``GET  /v1/sessions``                     会话列表（?userId=&boardId=）
- ``GET|PATCH|DELETE /v1/sessions/{id}``    会话读取 / 上下文更新 / 关闭（幂等）
- ``GET|POST /v1/sessions/{id}/messages``   消息列表 / 发送消息（经 Provider）
- ``POST /v1/sessions/{id}/audio``          发送语音（先 ASR 再入库）
- ``POST /v1/sessions/{id}/toolCalls/{tcId}/execute|preview|cancel``  工具调用操作

响应信封（统一）
----------------
成功 ``{"ok": true, "data": ..., "error": null}``；
失败 ``{"ok": false, "data": null, "error": {"code", "message", ["details"]}}``。
``error.code`` 对齐 ``core/tools/schema/command.schema.json`` 枚举（扩展 Unavailable/
RateLimited，见 ``errors.py``）。SDK 未安装 → 501 NotSupported；已装未配置 → 503 Unavailable。

SSE 格式（``POST /v1/chat/completions``, ``stream=true``）
----------------------------------------------------------
``data: {"type":"chunk","delta":"...","finishReason":null}`` 逐块；
``data: {"type":"done","finishReason":"stop"}``；``data: [DONE]`` 终止；
出错：``data: {"type":"error","error":{"code","message"}}`` 后接 ``[DONE]``。

运行：``python -m src.app``（默认 ``0.0.0.0:8000``；``WB_AI_HOST``/``WB_AI_PORT``/``PORT`` 覆盖）。
"""

from __future__ import annotations

import json
import logging
import os
import uuid
from typing import Annotated, Any, AsyncIterator, Mapping

from fastapi import FastAPI, File, Form, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response, StreamingResponse
from pydantic import BaseModel, Field
from starlette.exceptions import HTTPException as StarletteHTTPException

from . import SERVICE_NAME, __version__
from .asr import ASREngine
from .asr.whisper import WhisperASR
from .errors import (
    ApiError,
    CONFLICT,
    INTERNAL_ERROR,
    INVALID_ARGUMENT,
    NOT_FOUND,
    NOT_SUPPORTED,
    PERMISSION_DENIED,
    RATE_LIMITED,
    UpstreamError,
    error_body,
    ok_body,
)
from .providers import ChatMessage, ChatRequest, EmbeddingRequest, Provider
from .providers.anthropic import AnthropicProvider
from .providers.custom import CustomProvider
from .providers.openai import OpenAIProvider
from .session.manager import SessionManager, UNSET
from .tools.executor import ToolExecutor
from .tools.registry import ToolRegistry, create_default_registry
from .tts import TTSEngine
from .tts.azure import AzureTTS

logger = logging.getLogger("wb.ai_gateway")

# —— 请求模型（camelCase，对齐 OpenAPI 文档风格）——


class ChatCompletionRequest(BaseModel):
    messages: list[ChatMessage] = Field(min_length=1)
    model: str | None = None
    provider: str | None = None
    stream: bool = False
    temperature: float | None = None
    max_tokens: int | None = None
    tools: list[dict[str, Any]] | None = None


class EmbeddingBody(BaseModel):
    input: str | list[str]
    model: str | None = None
    provider: str | None = None


class ToolExecuteBody(BaseModel):
    tool: str
    args: dict[str, Any] = Field(default_factory=dict)
    dryRun: bool = False
    confirm: bool = False
    user: str | None = None
    sessionId: str | None = None


class SessionCreateBody(BaseModel):
    boardId: str
    userId: str
    pageId: str | None = None
    selection: list[str] = Field(default_factory=list)
    context: dict[str, Any] | None = None


class SessionUpdateBody(BaseModel):
    pageId: str | None = None
    selection: list[str] | None = None
    context: dict[str, Any] | None = None


class MessageBody(BaseModel):
    content: str = Field(min_length=1)
    provider: str | None = None
    model: str | None = None


class TTSPayload(BaseModel):
    text: str = Field(min_length=1)
    voice: str | None = None
    locale: str | None = None


class ToolCallActionBody(BaseModel):
    confirm: bool = False


# —— 工具函数 ——


def _parse_tool_arguments(raw: Any) -> dict[str, Any]:
    """Provider 返回的 tool 参数（JSON 字符串或对象）→ dict。"""
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            return {"raw": raw}
        return parsed if isinstance(parsed, dict) else {"value": parsed}
    return {}


def _provider_messages(messages: list[dict[str, Any]]) -> list[ChatMessage]:
    """会话消息 → Provider 消息（assistant 的 toolCalls 以 OpenAI 形状回填）。"""
    out: list[ChatMessage] = []
    for message in messages:
        item = ChatMessage(role=message["role"], content=message.get("content"))
        calls = message.get("toolCalls") or []
        if calls:
            item.tool_calls = [
                {
                    "id": call["id"],
                    "type": "function",
                    "function": {
                        "name": call["toolId"],
                        "arguments": json.dumps(call.get("args") or {}, ensure_ascii=False),
                    },
                }
                for call in calls
            ]
        out.append(item)
    return out


def _tool_calls_from_response(tool_calls: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Provider 响应 toolCalls → 会话 ToolCall 结构（status=pending）。"""
    return [
        {
            "id": f"tc_{uuid.uuid4().hex[:16]}",
            "toolId": call.get("name") or "unknown",
            "args": _parse_tool_arguments(call.get("arguments")),
            "result": None,
            "status": "pending",
            "timestamp": None,  # 由 SessionManager.add_message 补齐时间戳
        }
        for call in tool_calls
    ]


def _status_code_for_http(status: int) -> str:
    return {
        400: INVALID_ARGUMENT,
        401: INVALID_ARGUMENT,
        403: PERMISSION_DENIED,
        404: NOT_FOUND,
        405: INVALID_ARGUMENT,
        409: CONFLICT,
        422: INVALID_ARGUMENT,
        429: RATE_LIMITED,
    }.get(status, INTERNAL_ERROR if status >= 500 else INVALID_ARGUMENT)


# —— 应用装配 ——


def create_app(
    *,
    providers: Mapping[str, Provider] | None = None,
    default_provider: str | None = None,
    asr: ASREngine | None = None,
    tts: TTSEngine | None = None,
    tool_registry: ToolRegistry | None = None,
    tool_executor: ToolExecutor | None = None,
    sessions: SessionManager | None = None,
) -> FastAPI:
    """装配 FastAPI 应用（全部依赖可注入，测试用 Fake 覆盖，全程离线）。"""
    provider_map: dict[str, Provider] = (
        dict(providers)
        if providers is not None
        else {
            "openai": OpenAIProvider(),
            "anthropic": AnthropicProvider(),
            "custom": CustomProvider(),
        }
    )
    resolved_default = default_provider or os.environ.get("WB_AI_DEFAULT_PROVIDER") or "openai"
    registry = tool_registry if tool_registry is not None else create_default_registry()
    executor = tool_executor if tool_executor is not None else ToolExecutor(registry)
    session_manager = sessions if sessions is not None else SessionManager()
    asr_engine: ASREngine = asr if asr is not None else WhisperASR()
    tts_engine: TTSEngine = tts if tts is not None else AzureTTS()

    app = FastAPI(title="Whiteboard AI Gateway", version=__version__)
    app.state.providers = provider_map
    app.state.default_provider = resolved_default
    app.state.tool_registry = registry
    app.state.tool_executor = executor
    app.state.audit = executor.audit
    app.state.sessions = session_manager
    app.state.asr = asr_engine
    app.state.tts = tts_engine

    # —— 异常处理（统一信封）——

    @app.exception_handler(ApiError)
    async def _api_error_handler(_request: Any, exc: ApiError) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content=error_body(exc))

    @app.exception_handler(RequestValidationError)
    async def _validation_error_handler(_request: Any, exc: RequestValidationError) -> JSONResponse:
        errors = [
            {
                "loc": ".".join(str(part) for part in error.get("loc", ())),
                "reason": str(error.get("msg", "invalid")),
            }
            for error in exc.errors()
        ]
        return JSONResponse(
            status_code=400,
            content=error_body(
                ApiError(400, INVALID_ARGUMENT, "request validation failed", {"errors": errors})
            ),
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http_error_handler(_request: Any, exc: StarletteHTTPException) -> JSONResponse:
        message = exc.detail if isinstance(exc.detail, str) else "http error"
        return JSONResponse(
            status_code=exc.status_code,
            content=error_body(ApiError(exc.status_code, _status_code_for_http(exc.status_code), message)),
        )

    @app.exception_handler(Exception)
    async def _unhandled_error_handler(_request: Any, exc: Exception) -> JSONResponse:
        # 服务端记录摘要（不含请求体/凭据），客户端仅得到通用错误。
        logger.error("unhandled error: %s", type(exc).__name__)
        return JSONResponse(
            status_code=500,
            content=error_body(ApiError(500, INTERNAL_ERROR, "internal error")),
        )

    # —— 辅助 ——

    def _resolve_provider(name: str | None) -> Provider:
        key = name or app.state.default_provider
        provider = app.state.providers.get(key)
        if provider is None:
            raise ApiError(
                404, NOT_FOUND, f"provider not registered: {key}", {"available": sorted(app.state.providers)}
            )
        return provider

    # —— 健康检查 ——

    @app.get("/health")
    async def health() -> dict[str, Any]:
        return ok_body(
            {
                "status": "ok",
                "name": SERVICE_NAME,
                "version": __version__,
                "providers": {
                    name: provider.availability()
                    for name, provider in app.state.providers.items()
                },
                "defaultProvider": app.state.default_provider,
                "asr": app.state.asr.availability(),
                "tts": app.state.tts.availability(),
                "tools": len(app.state.tool_registry.list()),
                "sessions": app.state.sessions.count(),
            }
        )

    @app.get("/v1/providers")
    async def list_providers() -> dict[str, Any]:
        return ok_body(
            {
                "default": app.state.default_provider,
                "providers": [p.availability() for p in app.state.providers.values()],
            }
        )

    # —— Chat ——

    @app.post("/v1/chat/completions")
    async def chat_completions(body: ChatCompletionRequest) -> Any:
        provider = _resolve_provider(body.provider)
        request = ChatRequest(
            messages=body.messages,
            model=body.model,
            temperature=body.temperature,
            max_tokens=body.max_tokens,
            tools=body.tools,
        )
        if body.stream:
            return StreamingResponse(
                _sse_stream(provider, request),
                media_type="text/event-stream",
                headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
            )

        try:
            result = await provider.chat(request)
        except ApiError:
            raise
        except Exception as exc:  # noqa: BLE001 - 上游/Provider 异常收敛
            raise UpstreamError(provider.name, type(exc).__name__) from exc

        return ok_body(
            {
                "id": f"chatcmpl_{uuid.uuid4().hex[:16]}",
                "provider": provider.name,
                "model": result.model or request.model,
                "message": {
                    "role": "assistant",
                    "content": result.content,
                    "toolCalls": result.tool_calls,
                },
                "finishReason": result.finish_reason,
                "usage": result.usage,
            }
        )

    async def _sse_stream(provider: Provider, request: ChatRequest) -> AsyncIterator[str]:
        try:
            last_finish: str | None = None
            async for chunk in provider.stream_chat(request):
                if chunk.finish_reason:
                    last_finish = chunk.finish_reason
                payload = {
                    "type": "chunk",
                    "delta": chunk.delta,
                    "finishReason": chunk.finish_reason,
                }
                yield f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"
            done = {"type": "done", "finishReason": last_finish or "stop"}
            yield f"data: {json.dumps(done, ensure_ascii=False)}\n\n"
        except ApiError as exc:
            payload = {"type": "error", "error": exc.to_error()}
            yield f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"
        except Exception as exc:  # noqa: BLE001 - 流中断也要以事件形式告知
            payload = {
                "type": "error",
                "error": {"code": INTERNAL_ERROR, "message": f"stream failed ({type(exc).__name__})"},
            }
            yield f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"
        finally:
            yield "data: [DONE]\n\n"

    # —— Embedding ——

    @app.post("/v1/embeddings")
    async def embeddings(body: EmbeddingBody) -> dict[str, Any]:
        provider = _resolve_provider(body.provider)
        embed = getattr(provider, "embedding", None)
        if not callable(embed):
            raise ApiError(501, NOT_SUPPORTED, f"provider {provider.name} does not support embeddings")
        try:
            result = await embed(EmbeddingRequest(input=body.input, model=body.model))
        except ApiError:
            raise
        except Exception as exc:  # noqa: BLE001
            raise UpstreamError(provider.name, type(exc).__name__) from exc
        return ok_body(
            {
                "provider": provider.name,
                "model": result.model,
                "embeddings": result.embeddings,
                "usage": result.usage,
            }
        )

    # —— 工具 ——

    @app.get("/v1/tools")
    async def list_tools() -> dict[str, Any]:
        return ok_body({"tools": [tool.model_dump() for tool in app.state.tool_registry.list()]})

    @app.post("/v1/tools/execute")
    async def execute_tool(body: ToolExecuteBody) -> dict[str, Any]:
        data = await app.state.tool_executor.execute(
            body.tool,
            body.args,
            dry_run=body.dryRun,
            confirmed=body.confirm,
            user=body.user,
            session_id=body.sessionId,
        )
        return ok_body(data)

    # —— ASR / TTS ——

    @app.post("/v1/asr/transcribe")
    async def transcribe(
        file: Annotated[UploadFile, File()],
        language: Annotated[str | None, Form()] = None,
        sessionId: Annotated[str | None, Form()] = None,
    ) -> dict[str, Any]:
        data = await file.read()
        if not data:
            raise ApiError(400, INVALID_ARGUMENT, "audio file is empty")
        text = await app.state.asr.transcribe(
            data, language=language, filename=file.filename or "audio.wav"
        )
        payload: dict[str, Any] = {"text": text, "engine": getattr(app.state.asr, "name", "unknown")}
        if sessionId:
            app.state.sessions.require(sessionId)
            message = app.state.sessions.add_message(sessionId, role="user", content=text)
            payload["sessionId"] = sessionId
            payload["messageId"] = message["id"]
        return ok_body(payload)

    @app.post("/v1/tts/synthesize")
    async def synthesize(body: TTSPayload) -> Response:
        audio = await app.state.tts.synthesize(body.text, voice=body.voice, locale=body.locale)
        return Response(
            content=audio,
            media_type="audio/wav",
            headers={"X-TTS-Engine": str(getattr(app.state.tts, "name", "unknown"))},
        )

    # —— 会话 CRUD ——

    @app.post("/v1/sessions", status_code=201)
    async def create_session(body: SessionCreateBody) -> dict[str, Any]:
        session = app.state.sessions.create(
            body.boardId,
            body.userId,
            page_id=body.pageId,
            selection=body.selection,
            context=body.context,
        )
        return ok_body(session)

    @app.get("/v1/sessions")
    async def list_sessions(userId: str | None = None, boardId: str | None = None) -> dict[str, Any]:
        return ok_body(
            {
                "sessions": app.state.sessions.list_summaries(user_id=userId, board_id=boardId),
                "total": app.state.sessions.count(),
            }
        )

    @app.get("/v1/sessions/{session_id}")
    async def get_session(session_id: str) -> dict[str, Any]:
        return ok_body(app.state.sessions.require(session_id))

    @app.patch("/v1/sessions/{session_id}")
    async def update_session(session_id: str, body: SessionUpdateBody) -> dict[str, Any]:
        fields = body.model_fields_set
        session = app.state.sessions.update(
            session_id,
            page_id=body.pageId if "pageId" in fields else UNSET,
            selection=body.selection if "selection" in fields else UNSET,
            context=body.context if "context" in fields else UNSET,
        )
        return ok_body(session)

    @app.delete("/v1/sessions/{session_id}")
    async def delete_session(session_id: str) -> dict[str, Any]:
        # 幂等关闭：无论此前是否存在均返回 200，deleted 指示是否实际删除。
        deleted = app.state.sessions.delete(session_id)
        return ok_body({"sessionId": session_id, "deleted": deleted, "alreadyDeleted": not deleted})

    # —— 会话消息 ——

    @app.get("/v1/sessions/{session_id}/messages")
    async def list_messages(session_id: str) -> dict[str, Any]:
        app.state.sessions.require(session_id)
        return ok_body(
            {"sessionId": session_id, "messages": app.state.sessions.list_messages(session_id)}
        )

    @app.post("/v1/sessions/{session_id}/messages", status_code=201)
    async def send_message(session_id: str, body: MessageBody) -> dict[str, Any]:
        app.state.sessions.require(session_id)
        app.state.sessions.add_message(session_id, role="user", content=body.content)

        provider = _resolve_provider(body.provider)
        history = app.state.sessions.list_messages(session_id)
        request = ChatRequest(messages=_provider_messages(history), model=body.model)
        try:
            result = await provider.chat(request)
        except ApiError:
            raise
        except Exception as exc:  # noqa: BLE001
            raise UpstreamError(provider.name, type(exc).__name__) from exc

        tool_calls = _tool_calls_from_response(result.tool_calls)
        assistant = app.state.sessions.add_message(
            session_id, role="assistant", content=result.content, tool_calls=tool_calls
        )
        return ok_body(
            {"sessionId": session_id, "provider": provider.name, "model": result.model, "message": assistant}
        )

    @app.post("/v1/sessions/{session_id}/audio", status_code=201)
    async def send_audio(
        session_id: str,
        file: Annotated[UploadFile, File()],
        language: Annotated[str | None, Form()] = None,
    ) -> dict[str, Any]:
        app.state.sessions.require(session_id)
        data = await file.read()
        if not data:
            raise ApiError(400, INVALID_ARGUMENT, "audio file is empty")
        text = await app.state.asr.transcribe(
            data, language=language, filename=file.filename or "audio.wav"
        )
        message = app.state.sessions.add_message(session_id, role="user", content=text)
        return ok_body({"sessionId": session_id, "text": text, "message": message})

    # —— 会话工具调用 ——

    def _require_tool_call(session_id: str, tool_call_id: str) -> dict[str, Any]:
        app.state.sessions.require(session_id)
        call = app.state.sessions.find_tool_call(session_id, tool_call_id)
        if call is None:
            raise ApiError(404, NOT_FOUND, f"tool call not found: {tool_call_id}")
        return call

    @app.post("/v1/sessions/{session_id}/toolCalls/{tool_call_id}/execute")
    async def execute_tool_call(
        session_id: str,
        tool_call_id: str,
        body: ToolCallActionBody | None = None,
    ) -> dict[str, Any]:
        session = app.state.sessions.require(session_id)
        call = _require_tool_call(session_id, tool_call_id)
        if call["status"] == "cancelled":
            raise ApiError(409, CONFLICT, f"tool call {tool_call_id} was cancelled")
        confirmed = bool(body.confirm) if body else False

        try:
            data = await app.state.tool_executor.execute(
                call["toolId"],
                call["args"],
                confirmed=confirmed,
                user=session["userId"],
                session_id=session_id,
            )
        except ApiError as exc:
            app.state.sessions.update_tool_call(
                session_id, tool_call_id, status="error", result={"ok": False, "error": exc.to_error()}
            )
            raise

        if data["executed"]:
            updated = app.state.sessions.update_tool_call(
                session_id, tool_call_id, status="success", result=data.get("result")
            )
        else:
            updated = app.state.sessions.find_tool_call(session_id, tool_call_id)
        return ok_body({"sessionId": session_id, "toolCall": updated, "execution": data})

    @app.post("/v1/sessions/{session_id}/toolCalls/{tool_call_id}/preview")
    async def preview_tool_call(session_id: str, tool_call_id: str) -> dict[str, Any]:
        session = app.state.sessions.require(session_id)
        call = _require_tool_call(session_id, tool_call_id)
        data = await app.state.tool_executor.execute(
            call["toolId"],
            call["args"],
            dry_run=True,
            user=session["userId"],
            session_id=session_id,
        )
        return ok_body({"sessionId": session_id, "toolCall": call, "preview": data})

    @app.post("/v1/sessions/{session_id}/toolCalls/{tool_call_id}/cancel")
    async def cancel_tool_call(session_id: str, tool_call_id: str) -> dict[str, Any]:
        app.state.sessions.require(session_id)
        call = _require_tool_call(session_id, tool_call_id)
        if call["status"] == "pending":
            updated = app.state.sessions.update_tool_call(session_id, tool_call_id, status="cancelled")
        elif call["status"] == "cancelled":
            updated = call  # 幂等：重复取消返回相同结果
        else:
            raise ApiError(409, CONFLICT, f"tool call {tool_call_id} is already {call['status']}")
        return ok_body({"sessionId": session_id, "toolCall": updated})

    return app


# 模块级应用（供 `uvicorn src.app:app` / 容器入口使用）。
app = create_app()


def _main() -> None:  # pragma: no cover - 进程入口
    import uvicorn

    host = os.environ.get("WB_AI_HOST", "0.0.0.0")
    port = int(os.environ.get("WB_AI_PORT") or os.environ.get("PORT") or "8000")
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":  # pragma: no cover
    _main()
