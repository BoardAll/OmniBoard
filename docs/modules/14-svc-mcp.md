# 14 · svc-mcp —— MCP Server 服务

> 模块路径：`services/mcp_server`（`src/{server, dispatcher, session, audit, log}.ts`、`src/{auth, protocol, tools, resources, prompts, transport}`、`tests`）
> 维护 agent：`wb-svc-mcp-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：MCP（Model Context Protocol）服务端实现（《MCP_Server详细设计.md》）——JSON-RPC 2.0 编解码（自研，协议正确性不依赖 SDK）、initialize 握手与版本/能力协商、tools/resources/prompts 三类原语、stdio / SSE / Streamable HTTP 三种传输、认证（API Key / JWT / OAuth 内省 / 本地信任）、会话、审计、速率限制与确认流程。
- **不负责**：REST API 与业务数据（工具执行/资源读取经 `WB_API_BASE_URL` 桥接 → [13-svc-api](13-svc-api.md)）；模型与 ASR/TTS 调用（→ [15-svc-ai-gateway](15-svc-ai-gateway.md)）；C++ ToolRegistry 本体（→ [06-core-ai](06-core-ai.md)）。
- **地位**：外部 AI 客户端（Claude Desktop、Cursor 等）接入白板的协议入口；工具目录（113 个）与 13 的 MCP 桥接目录（30 个）在重叠部分保持一致（确认级别、Scope 逐项对齐）。

## 2. 功能 → 文件映射

### 2.1 入口与核心

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 主入口（装配、CLI/env 解析 `WB_MCP_*`、传输选择、启动安全默认） | `src/server.ts` | `tests/server.test.ts` |
| 请求分发（方法路由、批量、通知、错误路径、请求级限流） | `src/dispatcher.ts` | `tests/dispatcher.test.ts` |
| 会话管理（stdio 进程级单会话 / HTTP 按 `Mcp-Session-Id`） | `src/session.ts` | `tests/server.test.ts`、`tests/transports.test.ts` |
| 审计（时间/用户/动作/目标/结果 + 客户端标识，不含参数原文） | `src/audit.ts` | `tests/security.test.ts` |
| stderr 日志（stdio 下 stdout 只留协议消息；不打印凭据） | `src/log.ts` | 间接校验 |

### 2.2 协议层

| 功能 | 实现文件 | 测试 |
|---|---|---|
| JSON-RPC 2.0 编解码（请求/通知/响应/批量；-32700 ~ -32603 + -32001 ~ -32006 错误码） | `src/protocol/jsonrpc.ts` | `tests/jsonrpc.test.ts` |
| 初始化握手与版本/能力协商（2025-06-18 / 2024-11-05） | `src/protocol/initialize.ts` | `tests/initialize.test.ts` |

### 2.3 工具 / 资源 / 提示

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 工具注册表（113 个工具：下划线↔点号命名映射、确认级别、scope） | `src/tools/registry.ts` | `tests/tools.test.ts` |
| 工具执行管线（inputSchema 校验 → scope → 确认 → 执行 → 审计） | `src/tools/executor.ts` | `tests/tools.test.ts`、`tests/security.test.ts` |
| JSON Schema 子集校验器（tools/call 入参校验，不引入 ajv） | `src/tools/jsonschema.ts` | `tests/tools.test.ts` |
| 工具执行后端桥接（转发 13 的 `POST /v1/mcp/tools/{toolName}/call`；未配置 → -32000） | `src/tools/bridge.ts` | —（测试经 `tests/helpers.ts` 注入 fake invoker） |
| 资源注册表（10 个 URI 模板、list/read/subscribe；默认读取器桥接 13 或显式占位） | `src/resources/registry.ts` | `tests/resources.test.ts` |
| 提示模板注册表（10 个内置模板：brainstorm/flowchart/…/kanban） | `src/prompts/registry.ts` | `tests/prompts.test.ts` |

### 2.4 认证与限流

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 认证装配（`CompositeAuthenticator` / 本地信任 / `loadAuthFromEnv`） | `src/auth/index.ts` | `tests/auth.test.ts` |
| API Key 认证（`X-API-Key` / `Bearer wbp_*`；限流键用 SHA-256 摘要） | `src/auth/apiKey.ts` | `tests/auth.test.ts` |
| JWT / OAuth 校验（HS256/RS256/ES256、内省端点、iss/aud/长度上限） | `src/auth/oauth.ts` | `tests/auth.test.ts`、`tests/security.test.ts` |
| 速率限制（固定窗口 1000 请求/分钟 → -32001，data.retryAfter） | `src/auth/rateLimit.ts` | `tests/dispatcher.test.ts`、`tests/security.test.ts` |
| 认证公共类型（`Principal` / `AuthError` / `assertScope`、18 项 Scope） | `src/auth/types.ts` | `tests/auth.test.ts` |

### 2.5 传输层

| 功能 | 实现文件 | 测试 |
|---|---|---|
| stdio 传输（换行分隔 JSON、串行队列、stdout 只写协议） | `src/transport/stdio.ts` | `tests/transports.test.ts` |
| SSE 传输（`GET /sse` 事件流 + `POST /messages`；`event: endpoint`） | `src/transport/sse.ts` | `tests/transports.test.ts` |
| Streamable HTTP（`/mcp` 单端点、`Mcp-Session-Id`、202/204 语义） | `src/transport/http.ts` | `tests/transports.test.ts`、`tests/security.test.ts` |
| 传输公共辅助（§22.1 安全头、认证中间件、统一错误封套） | `src/transport/shared.ts` | `tests/security.test.ts` |

### 2.6 测试布局

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 测试辅助（fixtures、fake invoker、HTTP 工具、内存桥接传输） | `tests/{helpers,fixtures,http-utils}.ts` | — |
| SDK 兼容性冒烟（官方 SDK 可用时全链路验证，缺失自动跳过） | — | `tests/sdk-compat.test.ts`（1） |
| 用例分布（共 109） | — | jsonrpc 10 / initialize 9 / tools 19 / resources 13 / prompts 7 / auth 10 / security 12 / dispatcher 12 / server 11 / transports 5 / sdk-compat 1 |

## 3. 契约与依赖

- **对外契约（只读）**：《MCP_Server详细设计.md》§2-§11/§15/§19（协议、工具目录、错误码、确认流程）；桥接契约 `services/api/src/routes/mcp.ts`（`{ arguments, confirm? }` → `{ content, isError, structuredContent }`）；《安全与合规设计》§22.1 安全头模板。
- **端口**：HTTP 传输默认 `127.0.0.1:8788`（`WB_MCP_PORT` / `WB_MCP_HOST` 覆盖）；stdio 为进程级（无端口）。
- **认证**：`X-API-Key` / `Authorization: Bearer`（JWT 或 `wbp_` Key）；HTTP 未配置任何凭据（`WB_API_KEYS`/`WB_JWT_SECRET`）时拒绝启动（除非显式 `--allow-anonymous`）；stdio 无 `WB_MCP_API_KEY` 时进入本地信任模式（全 Scope，仅本机进程）。
- **协议版本**：`2025-06-18` / `2024-11-05`；扩展错误码：-32001 限流 / -32002 权限拒绝 / -32003 未找到 / -32004 冲突 / -32005 需确认 / -32006 已取消。
- **依赖**：`express` / `zod` / `@modelcontextprotocol/sdk`（`package.json` 已锁定）。SDK 仅用于可选的兼容性冒烟测试（`tests/sdk-compat.test.ts`）；协议正确性由自研 `src/protocol/jsonrpc.ts` 保证——SDK 缺失或安装失败时相关测试自动跳过，不影响其余功能与测试。
- **桥接方向**：本服务是 13-svc-api 的下游消费者——`WB_API_BASE_URL` 指向 API 服务，出站凭据为 `WB_API_KEY`（不复用外部客户端 token）。

## 4. 常用命令

```powershell
Set-Location services\mcp_server

# 依赖安装（npm 网络失败时追加 --registry=https://registry.npmmirror.com）
npm install

# 类型检查（tsc --noEmit）
npm run lint

# 测试（vitest run，109 用例，全部离线；sdk-compat 在 SDK 缺失时自动跳过）
npm test

# 构建与运行（默认 stdio；HTTP 传输 127.0.0.1:8788）
npm run build
$env:WB_MCP_TRANSPORT='stdio'; npm start
node dist/server.js --transport http --port 8788
```

## 5. 变更影响提醒（改本模块时注意）

- 工具目录 / 确认级别 / Scope 调整 → 与 **13-svc-api** `src/services/mcpService.ts` 桥接目录（30 个重叠工具）保持一致；共同上游为 **06-core-ai** ToolRegistry。
- Scope 清单（18 项）变化 → **13-svc-api** `SCOPES` 与 **15-svc-ai-gateway** 工具 `requiresPermission` 同步评估。
- 桥接调用形状（`WB_API_BASE_URL`、`{ arguments, confirm? }`、错误码映射）变化 → **13-svc-api** `src/routes/mcp.ts` 与 `mcpService.ts`。
- 协议版本 / 错误码语义变化 → **09-dart-client**（`packages/mcp_client`）与《MCP_Server详细设计.md》同步。
- 确认流程（-32005/-32006、`confirm_operation`）变化 → 与 **13** 的 `confirmationRequired`（422）语义对齐；**15** 的 `confirm`/`forbidden` 工具确认同步评估。
