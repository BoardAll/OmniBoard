"""工具注册表。

工具定义形状对齐契约 ``core/tools/schema/tool.schema.json``：
``id``（点命名，如 ``element.create``）/ ``name`` / ``description`` /
``category`` / ``parameters``（JSON Schema）/ ``confirmation``（auto|confirm|forbidden）/
``undoable`` / ``requiresPermission`` / ``returns`` / ``examples``。

``handler`` 为运行时字段（本地执行），不参与序列化；未注册 handler 的工具由
执行器转发到板端 API（见 ``executor.ToolExecutor``）。
"""

from __future__ import annotations

import re
from typing import Any, Awaitable, Callable, Iterable

from pydantic import BaseModel, Field

from ..errors import ApiError, INVALID_ARGUMENT

#: tool id 点命名规则（contract: `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$`）
TOOL_ID_PATTERN = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$")

#: 工具分类（tool.schema.json）
CATEGORIES = frozenset(
    {"board", "page", "element", "render", "theme", "ai", "mcp", "sync", "admin", "other"}
)

#: 确认级别（tool.schema.json）
CONFIRMATIONS = frozenset({"auto", "confirm", "forbidden"})

ToolHandler = Callable[[dict[str, Any]], Any | Awaitable[Any]]

_EMPTY_SCHEMA: dict[str, Any] = {"type": "object", "properties": {}}


class ToolDefinition(BaseModel):
    """工具定义（含运行时 handler，handler 不参与 model_dump）。"""

    id: str
    name: str
    description: str = ""
    category: str = "other"
    parameters: dict[str, Any] = Field(default_factory=lambda: dict(_EMPTY_SCHEMA))
    confirmation: str = "auto"
    undoable: bool = True
    requiresPermission: str | None = None
    returns: str | None = None
    examples: list[dict[str, Any]] = Field(default_factory=list)

    #: 本地执行器（可选）；不参与序列化。
    handler: ToolHandler | None = Field(default=None, exclude=True)

    model_config = {"arbitrary_types_allowed": True}


class ToolRegistry:
    """内存工具注册表（按 id 索引；重复注册 = 覆盖，幂等）。"""

    def __init__(self, tools: Iterable[ToolDefinition] | None = None) -> None:
        self._tools: dict[str, ToolDefinition] = {}
        for tool in tools or ():
            self.register(tool)

    def register(
        self,
        tool: ToolDefinition | str,
        handler: ToolHandler | None = None,
        **kwargs: Any,
    ) -> ToolDefinition:
        """注册（或覆盖）工具。

        支持两种形式：
        - ``register(ToolDefinition(...), handler)``
        - ``register("element.create", handler, name="...", category="element", ...)``
        """
        if isinstance(tool, str):
            definition = ToolDefinition(id=tool, name=kwargs.pop("name", tool), handler=handler, **kwargs)
        else:
            definition = tool
            if handler is not None:
                definition.handler = handler

        self._validate(definition)
        self._tools[definition.id] = definition
        return definition

    def unregister(self, tool_id: str) -> bool:
        return self._tools.pop(tool_id, None) is not None

    def get(self, tool_id: str) -> ToolDefinition | None:
        return self._tools.get(tool_id)

    def list(self) -> list[ToolDefinition]:
        return [self._tools[key] for key in sorted(self._tools)]

    def __len__(self) -> int:
        return len(self._tools)

    def __contains__(self, tool_id: object) -> bool:
        return tool_id in self._tools

    # —— 内部 ——

    @staticmethod
    def _validate(definition: ToolDefinition) -> None:
        if not TOOL_ID_PATTERN.match(definition.id):
            raise ApiError(
                400, INVALID_ARGUMENT, f"invalid tool id: {definition.id!r} (expect dot-namespaced)"
            )
        if definition.category not in CATEGORIES:
            raise ApiError(400, INVALID_ARGUMENT, f"invalid category: {definition.category!r}")
        if definition.confirmation not in CONFIRMATIONS:
            raise ApiError(400, INVALID_ARGUMENT, f"invalid confirmation: {definition.confirmation!r}")
        if not isinstance(definition.parameters, dict) or definition.parameters.get("type") not in (
            None,
            "object",
        ):
            raise ApiError(400, INVALID_ARGUMENT, "tool parameters must be a JSON Schema object")


async def _echo_handler(args: dict[str, Any]) -> dict[str, Any]:
    """内置调试工具：回显参数（用于连通性冒烟与测试）。"""
    return {"echo": args}


def create_default_registry() -> ToolRegistry:
    """内置工具集（映射《AI 助手与 MCP 设计》§12 的常用白板工具）。

    白板本体工具默认无本地 handler，由执行器转发板端 API（未配置 → 503）；
    ``ai.echo`` 为本地调试工具。
    """
    return ToolRegistry(
        [
            ToolDefinition(
                id="board.get",
                name="获取白板",
                description="读取白板元数据与页面列表",
                category="board",
                parameters={
                    "type": "object",
                    "properties": {"boardId": {"type": "string"}},
                    "required": ["boardId"],
                },
                requiresPermission="board.read",
                returns="board 元数据",
            ),
            ToolDefinition(
                id="element.create",
                name="创建元素",
                description="在白板上创建一个或多个元素，如便签、文本、形状、图片",
                category="element",
                parameters={
                    "type": "object",
                    "properties": {
                        "boardId": {"type": "string"},
                        "elements": {"type": "array", "items": {"type": "object"}},
                        "dryRun": {"type": "boolean", "default": False},
                    },
                    "required": ["boardId", "elements"],
                },
                requiresPermission="element.write",
                returns="创建的元素 id 列表",
            ),
            ToolDefinition(
                id="element.delete",
                name="删除元素",
                description="删除一个或多个元素（高风险，需确认）",
                category="element",
                confirmation="confirm",
                parameters={
                    "type": "object",
                    "properties": {
                        "boardId": {"type": "string"},
                        "elementIds": {"type": "array", "items": {"type": "string"}},
                    },
                    "required": ["boardId", "elementIds"],
                },
                requiresPermission="element.write",
                returns="删除结果",
            ),
            ToolDefinition(
                id="page.create",
                name="创建页面",
                description="在白板中新建页面",
                category="page",
                parameters={
                    "type": "object",
                    "properties": {"boardId": {"type": "string"}, "name": {"type": "string"}},
                    "required": ["boardId"],
                },
                requiresPermission="page.write",
                returns="页面元数据",
            ),
            ToolDefinition(
                id="history.undo",
                name="撤销",
                description="撤销最近一次操作",
                category="board",
                undoable=False,
                parameters={"type": "object", "properties": {"boardId": {"type": "string"}}},
                requiresPermission="history.write",
                returns="撤销结果",
            ),
            ToolDefinition(
                id="ai.echo",
                name="回显（调试）",
                description="回显请求参数，用于连通性检查",
                category="ai",
                parameters={"type": "object", "properties": {}},
                undoable=False,
                handler=_echo_handler,
                returns="参数回显",
            ),
        ]
    )


__all__ = [
    "TOOL_ID_PATTERN",
    "CATEGORIES",
    "CONFIRMATIONS",
    "ToolHandler",
    "ToolDefinition",
    "ToolRegistry",
    "create_default_registry",
]
