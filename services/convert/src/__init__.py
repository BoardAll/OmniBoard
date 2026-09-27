"""Whiteboard Convert —— PDF 转换服务（Wave 2.9）。

包结构（docs/Flutter + C++ 工程结构设计.md §7）：

- ``pdf_converter``  PyMuPDF 转换逻辑（函数级惰性导入；未安装 → 结构化 501）
- ``app``            FastAPI 应用装配（/health、PDF 信息/文本/渲染、转换任务）
"""

SERVICE_NAME = "whiteboard-convert"
__version__ = "0.1.0"

__all__ = ["SERVICE_NAME", "__version__"]
