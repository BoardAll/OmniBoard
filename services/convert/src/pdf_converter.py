"""PyMuPDF PDF 转换逻辑（函数级惰性导入；未安装 → 结构化 501）。

惰性导入约束
------------
本模块 import 不触碰 PyMuPDF（重依赖），未安装时模块可正常 import：

- ``engine_installed()``  仅探测（``importlib.util.find_spec``，不触发导入），用于 /health 上报；
- ``_load_fitz()``        函数级惰性导入（测试可 monkeypatch 注入假引擎），未安装抛
                          ``PdfEngineUnavailable``（→ HTTP 501 NotSupported）。

PyMuPDF ≥ 1.24 推荐 ``import pymupdf``；兼容旧入口 ``import fitz``（本模块按序尝试）。

错误模型（由 app 层映射为统一 JSON 信封）
-----------------------------------------
- ``PdfEngineUnavailable`` → 501 NotSupported（引擎未安装）
- ``PdfConversionError``   → 400 InvalidArgument（空载荷 / 损坏 PDF / 加密 / 页码或 dpi 越界）
"""

from __future__ import annotations

import contextlib
import importlib.util
import zipfile
from io import BytesIO
from typing import Any, Iterator

#: 默认渲染 DPI（与 docs 渲染约定一致的中等清晰度）
DEFAULT_RENDER_DPI = 144
#: 渲染 DPI 上限（防止超大位图耗尽内存）
MAX_RENDER_DPI = 600
#: 健康检查上报的引擎名
ENGINE_NAME = "pymupdf"


class PdfEngineUnavailable(RuntimeError):
    """PyMuPDF 引擎未安装（惰性导入失败）→ 501 NotSupported。"""

    status_code = 501
    code = "NotSupported"

    def __init__(self, hint: str = "") -> None:
        message = "pymupdf (PyMuPDF) is not installed"
        if hint:
            message = f"{message}; {hint}"
        super().__init__(message)
        self.details: dict[str, Any] = {"engine": ENGINE_NAME}


class PdfConversionError(ValueError):
    """PDF 输入/转换失败 → 400 InvalidArgument。"""

    status_code = 400
    code = "InvalidArgument"


def engine_installed() -> bool:
    """探测 PyMuPDF 是否可导入（不触发实际导入）。"""
    for module in ("pymupdf", "fitz"):
        try:
            if importlib.util.find_spec(module) is not None:
                return True
        except (ImportError, ValueError):
            continue
    return False


def _load_fitz() -> Any:
    """函数级惰性导入 PyMuPDF（测试可 monkeypatch 注入假引擎）。"""
    try:
        import pymupdf as fitz  # type: ignore[import-not-found]  # noqa: PLC0415
    except ImportError:
        try:
            import fitz  # type: ignore[import-not-found]  # noqa: PLC0415
        except ImportError as exc:
            raise PdfEngineUnavailable("pip install pymupdf") from exc
    return fitz


@contextlib.contextmanager
def _open_pdf(data: bytes) -> Iterator[Any]:
    """打开内存 PDF（统一错误收敛 + 确保关闭）。"""
    fitz = _load_fitz()
    if not data:
        raise PdfConversionError("pdf payload is empty")
    doc = None
    try:
        doc = fitz.open(stream=data, filetype="pdf")
        if getattr(doc, "needs_pass", False):
            raise PdfConversionError("pdf is password protected")
        yield doc
    except PdfConversionError:
        raise
    except Exception as exc:  # noqa: BLE001 - 统一收敛为可读转换错误
        raise PdfConversionError(f"invalid pdf ({type(exc).__name__})") from exc
    finally:
        if doc is not None:
            with contextlib.suppress(Exception):
                doc.close()


def _require_page(doc: Any, page: int) -> int:
    count = int(doc.page_count)
    if page < 0 or page >= count:
        raise PdfConversionError(f"page index out of range: {page} (pageCount={count})")
    return count


def _validate_dpi(dpi: int) -> None:
    if dpi < 8 or dpi > MAX_RENDER_DPI:
        raise PdfConversionError(f"dpi out of range: {dpi} (expect 8-{MAX_RENDER_DPI})")


def get_info(data: bytes) -> dict[str, Any]:
    """页数 / 页面尺寸 / 元数据。"""
    with _open_pdf(data) as doc:
        count = int(doc.page_count)
        pages: list[dict[str, Any]] = []
        for index in range(count):
            rect = doc.load_page(index).rect
            pages.append(
                {
                    "index": index,
                    "width": round(float(rect.width), 2),
                    "height": round(float(rect.height), 2),
                }
            )
        metadata = {
            str(key): str(value)
            for key, value in dict(getattr(doc, "metadata", None) or {}).items()
            if value
        }
        return {"pageCount": count, "pages": pages, "metadata": metadata, "encrypted": False}


def extract_text(data: bytes, *, page: int | None = None) -> dict[str, Any]:
    """逐页文本提取（``page=None`` → 全部页面）。"""
    with _open_pdf(data) as doc:
        count = int(doc.page_count)
        if page is not None:
            _require_page(doc, page)
            indexes = [page]
        else:
            indexes = list(range(count))
        pages = [
            {"index": index, "text": doc.load_page(index).get_text("text") or ""}
            for index in indexes
        ]
        return {"pageCount": count, "pages": pages}


def pdf_to_text(data: bytes) -> str:
    """合并全部页面文本（供转换任务 text 操作使用）。"""
    with _open_pdf(data) as doc:
        parts = [
            doc.load_page(index).get_text("text") or ""
            for index in range(int(doc.page_count))
        ]
        return "\n".join(parts).strip()


def render_page_png(data: bytes, *, page: int = 0, dpi: int = DEFAULT_RENDER_DPI) -> bytes:
    """渲染单页为 PNG 字节。"""
    _validate_dpi(dpi)
    with _open_pdf(data) as doc:
        _require_page(doc, page)
        png = doc.load_page(page).get_pixmap(dpi=dpi).tobytes("png")
        if not png:
            raise PdfConversionError("render produced no output")
        return bytes(png)


def pdf_to_png_zip(data: bytes, *, dpi: int = DEFAULT_RENDER_DPI) -> bytes:
    """全部页面渲染为 PNG 并打包 zip（``page-001.png`` 起编号）。"""
    _validate_dpi(dpi)
    with _open_pdf(data) as doc:
        buffer = BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            for index in range(int(doc.page_count)):
                pixmap = doc.load_page(index).get_pixmap(dpi=dpi)
                archive.writestr(f"page-{index + 1:03d}.png", pixmap.tobytes("png"))
        return buffer.getvalue()


__all__ = [
    "DEFAULT_RENDER_DPI",
    "MAX_RENDER_DPI",
    "ENGINE_NAME",
    "PdfEngineUnavailable",
    "PdfConversionError",
    "engine_installed",
    "get_info",
    "extract_text",
    "pdf_to_text",
    "render_page_png",
    "pdf_to_png_zip",
]
