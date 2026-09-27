"""工具注册表与执行器（AI Gateway 视角）。

- ``registry``：工具定义（对齐 ``core/tools/schema/tool.schema.json``）
- ``executor``：执行工具（本地 handler 或转发板端 API）＋脱敏审计
"""

from .executor import AuditLog, ToolExecutor
from .registry import ToolDefinition, ToolRegistry, create_default_registry

__all__ = ["AuditLog", "ToolExecutor", "ToolDefinition", "ToolRegistry", "create_default_registry"]
