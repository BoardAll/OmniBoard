# 06 · core-ai —— C++ AI 与 MCP

> 模块路径：`core/include/wb/{ai, mcp}`（当前为空占位）、`core/src/{ai, mcp}`、`core/tests/unit/{ai, mcp}`
> 维护 agent：`wb-core-ai-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：AI 会话域（会话创建/关闭/读取、消息收发簿记、工具调用的执行/预览/取消、上下文设置）；MCP 协议服务端（JSON-RPC 2.0 单消息处理、服务启停与会话、工具桥接与命名规范、resources/prompts、审计入口）。核心原则：AI 与用户操作一致——工具调用统一走共享 `ToolRegistry`（tool 域 `execute`），并写审计。
- **AI 工具调用注册（协作点）**：AI/MCP 可见工具来自 01 的工具注册表 `core/src/tool/tool_registry.cpp`（01 范围，**本模块仅消费**）；`mindmap.*`/`table.*`/`crdt.*` 等工具集已在该表中补全（`core/src/tool/tool_registry.cpp:108-134`），MCP 侧按命名规范逐一桥接，见 `core/tests/unit/mcp/mcp_test.cpp` 的桥接断言。
- **不负责**：工具注册表实现与 FFI 导出（→ [01-core-foundation](01-core-foundation.md)）；具体领域工具的算法实现（→ [04-core-domain](04-core-domain.md)、[05-core-collab](05-core-collab.md)）；数据模型（→ [02-core-model](02-core-model.md)）；渲染（→ [03-core-render](03-core-render.md)）；真实模型推理（AI Gateway，后续 wave；本域只做确定性簿记）。
- **地位**：顶层编排模块；锁约定：AI/MCP 互斥锁只保护各域内部状态（会话/运行标志），所有 `invokeDomain()`（工具执行、页面/元素读取、审计）一律**在锁外**调用。

## 2. 功能 → 文件映射

| 功能 | 实现文件 | 测试 |
|---|---|---|
| ai 域（`sessionCreate`/`sessionClose`/`sessionGet`/`sendMessage`/`sendAudio`/`listMessages`/`executeToolCall`/`previewToolCall`/`cancelToolCall`/`setContext`；会话注册表、用户消息本地落账、工具调用经 tool 域执行并写审计；FFI：`wb_ai_*` 共 10 个） | `core/src/ai/ai.cpp`（约 507 行） | `core/tests/unit/ai/ai_test.cpp` |
| mcp 域（`start`/`stop`/`isRunning`/`handleRequest`/`sessionCreate`/`sessionGet`/`sessionClose`/`listTools`/`callTool`/`listResources`/`readResource`/`listPrompts`/`getPrompt`/`auditQuery`/`auditExport`；JSON-RPC 2.0、工具桥接命名转换、审计转发；FFI：`wb_mcp_*` 共 15 个） | `core/src/mcp/mcp.cpp`（约 1228 行） | `core/tests/unit/mcp/mcp_test.cpp` |

## 3. 契约与依赖

- **对外契约（只读）**：`core/include/wb/wb.h` 的 AI sessions 段（`wb_ai_session_create` … `wb_ai_set_context`）与 MCP server 段（`wb_mcp_start` … `wb_mcp_audit_export`）。
- **被依赖**：07 `packages/core_dart` 封装 `wb_ai_*`/`wb_mcp_*`（`wb_core_bindings.dart`；服务文件如 `lib/services/ai_service.dart`）；09 `packages/{ai_dart, mcp_client}` 与本模块的协议面（JSON-RPC 2.0 消息、工具 snake_case 命名）对齐。
- **依赖**：01 契约基础层（`wb/ffi/domain.h` 注册宏、`wb/platform/platform.h`；工具注册表与工具执行器 `tool.execute`）；05 audit 域（`invokeDomain("audit", "log", ...)`，`fromAI=true`，默认 userId `mcp:anonymous`；`auditQuery`/`auditExport` 转发至 `audit` 域的 `query`/`export`，`core/src/mcp/mcp.cpp:567-572`）；02 数据模型（经域调用读取页面/元素资源）；third_party（nlohmann/json）。
- **已知契约事实（回归依据）**：MCP 工具命名规则 §6.3——内部 tool id（点号 + camelCase）转 snake_case 小写（如 `theme.list` → `theme_list`）；`handleRequest` 处理 initialize / notifications/initialized / ping / tools/* / resources/* / prompts/* 并返回 JSON-RPC 响应；每次 `tools/call` 写审计；`start` 只翻转运行状态并记录配置（stdio/SSE/HTTP 传输属后续 wave）；AI 会话为进程内注册表（同 CRDT/SceneStore 模式）。

## 4. 常用命令

```powershell
# 构建（改动本模块后必须全量构建）
cmake --preset windows-x64; cmake --build build/windows-x64 --config Release

# 全量单测
ctest --test-dir build/windows-x64 -C Release --output-on-failure

# 只跑本模块相关用例（按名称过滤）
ctest --test-dir build/windows-x64 -C Release -R "ai|mcp" --output-on-failure
```

## 5. 变更影响提醒（改本模块时注意）

- 修改 MCP 工具命名转换或 `tools/call` 行为 → 09 `packages/mcp_client` 与外部 MCP 客户端兼容性；`core/tests/unit/mcp/mcp_test.cpp` 全量重跑（case 在独立进程运行，MCP 状态每次从零开始）。
- 修改 AI 会话消息结构/工具调用响应 → 07 `ai_service.dart`、09 `packages/ai_dart` 与 11 桌面端 AI 面板联动。
- 新增/改名工具 → 05 审计条目中的 `toolId`、01 工具注册表与 MCP 名称映射需三者一致；否则 MCP `tools/list` 与审计回溯断裂。
- 修改审计写入点（`tools/call` 强制落审计）→ 05 `test_permission_audit.cpp` 与合规要求（《安全与合规设计》）联动。
- 锁约定（互斥锁只护内部状态、`invokeDomain` 锁外）是防死锁关键：改动 handleRequest/callTool 流程时必须保持。
