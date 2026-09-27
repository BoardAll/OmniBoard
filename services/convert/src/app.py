"""Whiteboard Convert —— FastAPI 应用装配（Wave 2.9）。

职责：PDF 页数/文本提取/页面渲染 PNG/转换任务（PyMuPDF 惰性导入）。

端点点位
--------
- ``GET  /health``                       健康检查（不触发 PyMuPDF 导入）
- ``POST /v1/pdf/info``                  PDF 元信息（页数/页面尺寸/元数据）
- ``POST /v1/pdf/text``                  文本提取（可选 ``page``；缺省全部页面）
- ``POST /v1/pdf/render.png``            单页渲染 PNG（``page``/``dpi`` 可调，返回 image/png）
- ``POST /v1/convert/jobs``              创建转换任务（同步执行：text / png / info；201）
- ``GET  /v1/convert/jobs``              任务列表
- ``GET  /v1/convert/jobs/{id}``         任务详情
- ``GET  /v1/convert/jobs/{id}/result``  任务产物下载（text/plain 或 image/png）
- ``DELETE /v1/convert/jobs/{id}``       删除任务（幂等：重复删除返回 alreadyDeleted）

响应信封与错误码对齐 ``core/tools/schema/command.schema.json``（OpenAPI §4.4/§4.10）：

- 成功 ``{"ok": true, "data": ..., "error": null}``
- 失败 ``{"ok": false, "data": null, "error": {"code", "message", ["details"]}}``
- PyMuPDF 未安装 → 501 NotSupported；空载荷/损坏 PDF/越界 → 400 InvalidArgument；
  上传超限 → 413 ResourceExhausted；任务无产物 → 409 Conflict。

运行：``python -m src.app``（默认 ``0.0.0.0:8001``；``WB_CONVERT_HOST``/``WB_CONVERT_PORT``/``PORT`` 覆盖；
端口为自选值——《构建打包与发布设计》未对 convert 服务规定端口，ai_gateway 约定 8000，本服务取 8001）。
"""

from __future__ import annotations

import asyncio
import copy
import json
import logging
import os
import threading
import uuid
from datetime import datetime, timezone
from typing import Annotated, Any

from fastapi import FastAPI, File, Form, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from starlette.exceptions import HTTPException as StarletteHTTPException

from . import SERVICE_NAME, __version__
from . import pdf_converter
from .pdf_converter import PdfConversionError, PdfEngineUnavailable

logger = logging.getLogger("wb.convert")

# —— 错误码（command.schema.json 枚举子集 + OpenAPI 传输层扩展） ——

INVALID_ARGUMENT = "InvalidArgument"
NOT_FOUND = "NotFound"
CONFLICT = "Conflict"
INTERNAL_ERROR = "InternalError"
NOT_SUPPORTED = "NotSupported"
RESOURCE_EXHAUSTED = "ResourceExhausted"

OPERATIONS = ("text", "png", "info")

DEFAULT_MAX_UPLOAD_MB = 64


class ApiError(Exception):
    """业务/传输错误；由 app 层统一转换为 JSON 错误信封。"""

    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.details = details

    def to_error(self) -> dict[str, Any]:
        payload: dict[str, Any] = {"code": self.code, "message": self.message}
        if self.details is not None:
            payload["details"] = self.details
        return payload


def ok_body(data: Any) -> dict[str, Any]:
    return {"ok": True, "data": data, "error": None}


def error_body(error: ApiError) -> dict[str, Any]:
    return {"ok": False, "data": None, "error": error.to_error()}


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _max_upload_bytes() -> int:
    raw = os.environ.get("WB_CONVERT_MAX_UPLOAD_MB", str(DEFAULT_MAX_UPLOAD_MB))
    try:
        mb = int(raw)
    except ValueError:
        mb = DEFAULT_MAX_UPLOAD_MB
    return max(1, mb) * 1024 * 1024


# —— 转换任务存储（内存实现；同步执行，异步队列在后续 Wave 引入） ——


class JobStore:
    """内存转换任务存储（FIFO 驱逐，默认上限 256 个任务）。

    任务含内部字段 ``payload``（产物字节），对外序列化时剔除。
    """

    def __init__(self, *, max_jobs: int = 256) -> None:
        self._jobs: dict[str, dict[str, Any]] = {}
        self._order: list[str] = []
        self._lock = threading.RLock()
        self.max_jobs = max_jobs

    def add(
        self,
        *,
        operation: str,
        status: str,
        page: int | None = None,
        dpi: int | None = None,
        result: dict[str, Any] | None = None,
        error: dict[str, Any] | None = None,
        payload: bytes | None = None,
        payload_media_type: str | None = None,
    ) -> dict[str, Any]:
        with self._lock:
            while len(self._jobs) >= self.max_jobs and self._order:
                oldest = self._order.pop(0)
                self._jobs.pop(oldest, None)
            now = _utc_now_iso()
            job: dict[str, Any] = {
                "id": f"job_{uuid.uuid4().hex[:16]}",
                "operation": operation,
                "status": status,
                "createdAt": now,
                "updatedAt": now,
                "page": page,
                "dpi": dpi,
                "result": copy.deepcopy(result),
                "error": copy.deepcopy(error),
                "payloadMediaType": payload_media_type,
                "payload": payload,  # 内部字段，不对外序列化
            }
            self._jobs[job["id"]] = job
            self._order.append(job["id"])
            return copy.deepcopy(job)

    def get(self, job_id: str) -> dict[str, Any] | None:
        with self._lock:
            job = self._jobs.get(job_id)
            return copy.deepcopy(job) if job is not None else None

    def list(self) -> list[dict[str, Any]]:
        with self._lock:
            return [self.public(self._jobs[job_id]) for job_id in self._order]

    def delete(self, job_id: str) -> bool:
        """删除任务及其产物；返回是否实际删除（幂等：重复删除返回 False）。"""
        with self._lock:
            existed = self._jobs.pop(job_id, None) is not None
            if existed:
                try:
                    self._order.remove(job_id)
                except ValueError:  # pragma: no cover - 防御
                    pass
            return existed

    def count(self) -> int:
        with self._lock:
            return len(self._jobs)

    @staticmethod
    def public(job: dict[str, Any]) -> dict[str, Any]:
        """对外视图（剔除产物字节，仅保留元数据）。"""
        return {key: copy.deepcopy(value) for key, value in job.items() if key != "payload"}


def _execute_job(
    operation: str, data: bytes, page: int | None, dpi: int
) -> tuple[dict[str, Any], bytes | None, str | None]:
    """执行转换（同步，CPU 密集）；返回 (result, payload, payloadMediaType)。"""
    if operation == "info":
        return pdf_converter.get_info(data), None, None
    if operation == "text":
        extracted = pdf_converter.extract_text(data, page=page)
        text = "\n".join(item["text"] for item in extracted["pages"]).strip()
        result = {
            "pageCount": extracted["pageCount"],
            "page": page,
            "charCount": len(text),
            "text": text,
        }
        return result, text.encode("utf-8"), "text/plain"
    if operation == "png":
        target = page if page is not None else 0
        png = pdf_converter.render_page_png(data, page=target, dpi=dpi)
        return {"page": target, "dpi": dpi, "sizeBytes": len(png)}, png, "image/png"
    # 理论上不可达（入口已校验 operation）
    raise ApiError(400, INVALID_ARGUMENT, f"unknown operation: {operation}")  # pragma: no cover


def _status_code_for_http(status: int) -> str:
    return {
        400: INVALID_ARGUMENT,
        401: INVALID_ARGUMENT,
        403: "PermissionDenied",
        404: NOT_FOUND,
        405: INVALID_ARGUMENT,
        409: CONFLICT,
        413: RESOURCE_EXHAUSTED,
        422: INVALID_ARGUMENT,
        429: "RateLimited",
    }.get(status, INTERNAL_ERROR if status >= 500 else INVALID_ARGUMENT)


# —— 应用装配 ——


def create_app(*, jobs: JobStore | None = None) -> FastAPI:
    """装配 FastAPI 应用（JobStore 可注入，便于测试隔离）。"""
    store = jobs if jobs is not None else JobStore()

    app = FastAPI(title="Whiteboard Convert", version=__version__)
    app.state.jobs = store

    # —— 异常处理（统一信封） ——

    @app.exception_handler(ApiError)
    async def _api_error_handler(_request: Any, exc: ApiError) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content=error_body(exc))

    @app.exception_handler(PdfEngineUnavailable)
    async def _engine_missing_handler(_request: Any, exc: PdfEngineUnavailable) -> JSONResponse:
        return JSONResponse(status_code=501, content=error_body(ApiError(501, NOT_SUPPORTED, str(exc))))

    @app.exception_handler(PdfConversionError)
    async def _conversion_error_handler(_request: Any, exc: PdfConversionError) -> JSONResponse:
        return JSONResponse(status_code=400, content=error_body(ApiError(400, INVALID_ARGUMENT, str(exc))))

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
        # 服务端记录摘要（不含请求体/文件内容），客户端仅得到通用错误。
        logger.error("unhandled error: %s", type(exc).__name__)
        return JSONResponse(
            status_code=500,
            content=error_body(ApiError(500, INTERNAL_ERROR, "internal error")),
        )

    # —— 辅助 ——

    async def _read_upload(file: UploadFile) -> bytes:
        data = await file.read()
        if not data:
            raise ApiError(400, INVALID_ARGUMENT, "uploaded file is empty")
        limit = _max_upload_bytes()
        if len(data) > limit:
            raise ApiError(
                413,
                RESOURCE_EXHAUSTED,
                f"uploaded file exceeds limit ({len(data)} > {limit} bytes)",
            )
        return data

    def _job_or_404(job_id: str) -> dict[str, Any]:
        job = store.get(job_id)
        if job is None:
            raise ApiError(404, NOT_FOUND, f"job not found: {job_id}")
        return job

    # —— 健康检查 ——

    @app.get("/health")
    async def health() -> dict[str, Any]:
        return ok_body(
            {
                "status": "ok",
                "name": SERVICE_NAME,
                "version": __version__,
                "engine": {
                    "name": pdf_converter.ENGINE_NAME,
                    "installed": pdf_converter.engine_installed(),
                },
                "jobs": store.count(),
                "operations": list(OPERATIONS),
                "maxUploadMb": _max_upload_bytes() // (1024 * 1024),
            }
        )

    # —— PDF 直接操作 ——

    @app.post("/v1/pdf/info")
    async def pdf_info(file: Annotated[UploadFile, File()]) -> dict[str, Any]:
        data = await _read_upload(file)
        return ok_body(await asyncio.to_thread(pdf_converter.get_info, data))

    @app.post("/v1/pdf/text")
    async def pdf_text(
        file: Annotated[UploadFile, File()],
        page: Annotated[int | None, Form()] = None,
    ) -> dict[str, Any]:
        data = await _read_upload(file)
        return ok_body(await asyncio.to_thread(pdf_converter.extract_text, data, page=page))

    @app.post("/v1/pdf/render.png")
    async def pdf_render(
        file: Annotated[UploadFile, File()],
        page: Annotated[int, Form()] = 0,
        dpi: Annotated[int, Form()] = pdf_converter.DEFAULT_RENDER_DPI,
    ) -> Response:
        data = await _read_upload(file)
        png = await asyncio.to_thread(pdf_converter.render_page_png, data, page=page, dpi=dpi)
        return Response(
            content=png,
            media_type="image/png",
            headers={"X-Page": str(page), "X-Dpi": str(dpi)},
        )

    # —— 转换任务 ——

    @app.post("/v1/convert/jobs", status_code=201)
    async def create_job(
        file: Annotated[UploadFile, File()],
        operation: Annotated[str, Form()] = "text",
        page: Annotated[int | None, Form()] = None,
        dpi: Annotated[int, Form()] = pdf_converter.DEFAULT_RENDER_DPI,
    ) -> dict[str, Any]:
        data = await _read_upload(file)
        if operation not in OPERATIONS:
            raise ApiError(
                400, INVALID_ARGUMENT, f"unknown operation: {operation} (expect {'|'.join(OPERATIONS)})"
            )
        if operation == "png" and not 8 <= dpi <= pdf_converter.MAX_RENDER_DPI:
            raise ApiError(
                400, INVALID_ARGUMENT, f"dpi out of range: {dpi} (expect 8-{pdf_converter.MAX_RENDER_DPI})"
            )

        try:
            result, payload, media_type = await asyncio.to_thread(_execute_job, operation, data, page, dpi)
        except PdfEngineUnavailable:
            # 引擎缺失不落任务记录（装上引擎后可直接重试）→ 501
            raise
        except PdfConversionError as exc:
            job = store.add(
                operation=operation,
                status="failed",
                page=page,
                dpi=dpi if operation == "png" else None,
                error={"code": exc.code, "message": str(exc)},
            )
            return ok_body(JobStore.public(job))

        job = store.add(
            operation=operation,
            status="succeeded",
            page=page,
            dpi=dpi if operation == "png" else None,
            result=result,
            payload=payload,
            payload_media_type=media_type,
        )
        return ok_body(JobStore.public(job))

    @app.get("/v1/convert/jobs")
    async def list_jobs() -> dict[str, Any]:
        jobs = store.list()
        return ok_body({"jobs": jobs, "total": len(jobs)})

    @app.get("/v1/convert/jobs/{job_id}")
    async def get_job(job_id: str) -> dict[str, Any]:
        return ok_body(JobStore.public(_job_or_404(job_id)))

    @app.get("/v1/convert/jobs/{job_id}/result")
    async def get_job_result(job_id: str) -> Response:
        job = _job_or_404(job_id)
        if job["status"] != "succeeded" or job["payload"] is None:
            raise ApiError(
                409,
                CONFLICT,
                f"job {job_id} has no downloadable result (status={job['status']})",
            )
        return Response(
            content=job["payload"],
            media_type=job["payloadMediaType"] or "application/octet-stream",
            headers={"Content-Disposition": f'attachment; filename="{job_id}.out"'},
        )

    @app.delete("/v1/convert/jobs/{job_id}")
    async def delete_job(job_id: str) -> dict[str, Any]:
        # 幂等删除：无论此前是否存在均返回 200，deleted 指示是否实际删除。
        deleted = store.delete(job_id)
        return ok_body({"jobId": job_id, "deleted": deleted, "alreadyDeleted": not deleted})

    return app


# 模块级应用（供 `uvicorn src.app:app` / 容器入口使用）。
app = create_app()


def _main() -> None:  # pragma: no cover - 进程入口
    import uvicorn

    host = os.environ.get("WB_CONVERT_HOST", "0.0.0.0")
    port = int(os.environ.get("WB_CONVERT_PORT") or os.environ.get("PORT") or "8001")
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":  # pragma: no cover
    _main()
