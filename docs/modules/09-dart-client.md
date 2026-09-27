# 09 · dart-client —— Dart 服务客户端包

> 模块路径：`packages/{ai_dart, api_client, mcp_client}`
> 维护 agent：`wb-dart-client-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：三类 Flutter 端协议/网络客户端——AI Provider 客户端（ai_dart：会话 / 消息 / 上下文 / 工具调用 / 语音 + OpenAI / Anthropic / 自定义端点）、REST Open API 客户端（api_client：认证 / 分页 / 多域 API / 模型 / 错误）、MCP 客户端（mcp_client：JSON-RPC 2.0 协议 + Tools / Resources / Prompts + 多传输）。
- **不负责**：AI / MCP 的 C++ 引擎域（→ [06-core-ai](06-core-ai.md)）；对应服务端实现（→ [13-svc-api](13-svc-api.md)、[14-svc-mcp](14-svc-mcp.md)、[15-svc-ai-gateway](15-svc-ai-gateway.md)）；FFI 调用（→ [07-dart-core](07-dart-core.md)）；应用内装配与状态（→ [11-app-desktop](11-app-desktop.md)）。
- **地位**：纯 Dart 客户端包（无 FFI、无平台通道），可完全离线单测；11 应用经 path 依赖引用。
- **现状（如实标注）**：11 app-desktop 当前源码仅实际引用 `whiteboard_ai`（AI 面板与设置链路）；`whiteboard_api_client`、`whiteboard_mcp_client` 已固化 path 依赖但**尚无源码引用点**。

## 2. 功能 → 文件映射

### 2.1 ai_dart —— AI 客户端（21 用例）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 门面：`AiProvider` 抽象、`AiClient`、请求/响应模型（`AiChatRequest`/`AiChatResponse`/`AiUsage`/`AiToolDefinition`）、流式事件（`AiStreamEvent`：TextDelta/ToolCallDelta/Done/Error）、`AiProviderException` | `packages/ai_dart/lib/ai_client.dart` | `packages/ai_dart/test/ai_dart_test.dart`（AiClient 门面组） |
| 会话 / 消息 / 上下文 / 工具调用模型 | `packages/ai_dart/lib/{ai_session,ai_message,ai_context,ai_tool_call}.dart` | 同上（模型层组） |
| 语音模型与流式音频通道 | `packages/ai_dart/lib/ai_audio.dart` | 同上 |
| Providers：OpenAI（及兼容端点）/ Anthropic Claude / 自定义自托管端点 | `packages/ai_dart/lib/providers/{openai,anthropic,custom}_provider.dart` | 同上（OpenAiProvider / AnthropicProvider / CustomProvider 三组） |

### 2.2 api_client —— REST API 客户端（28 用例）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 客户端核心（URI 构建 / 响应信封与错误 / 认证头 / 分页） | `packages/api_client/lib/{api_client,auth,errors,pagination}.dart` | `packages/api_client/test/api_client_test.dart`（URI 构建 / 信封与错误 / 请求头与认证 / 分页 四组） |
| 域 API：boards / pages / elements / connectors / comments / exports / history / ai / mcp | `packages/api_client/lib/{boards,pages,elements,connectors,comments,exports,history,ai,mcp}_api.dart`（9 文件） | 同上（API 服务组） |
| 模型：board / page / element / connector / comment / export_job / history / session | `packages/api_client/lib/models/*.dart`（8 文件） | 同上（模型解析组） |

### 2.3 mcp_client —— MCP 客户端（32 用例）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 客户端门面：协议握手、Tools / Resources / Prompts 调用 | `packages/mcp_client/lib/mcp_client.dart` | `packages/mcp_client/test/mcp_client_test.dart`（McpClient 初始化 / Tools 等组） |
| 传输层（4 文件）：抽象 `McpTransport` + stdio / SSE / Streamable HTTP 三实现 | `packages/mcp_client/lib/{mcp_transport,mcp_stdio_transport,mcp_sse_transport,mcp_http_transport}.dart` | 同上 |
| 协议基础：JSON-RPC 2.0 消息模型、错误码、方法常量、SSE 解码（`McpJsonRpc` / `McpErrorCodes` / `McpError` / `McpException` / `McpSseDecoder`） | `packages/mcp_client/lib/mcp_protocol.dart` | 同上（McpJsonRpc / 错误码与异常 / McpSseDecoder 组） |
| 能力模型：Tools / Resources / Prompts | `packages/mcp_client/lib/{mcp_tools,mcp_resources,mcp_prompts}.dart` | 同上（Tools 等组） |

## 3. 契约与依赖

- **依赖**：ai_dart → `http` ^1.2.0、`web_socket_channel` ^3.0.0；api_client → `http` ^1.2.0；mcp_client → `http` ^1.2.0。三包互相独立、无交叉依赖。
- **被依赖**：11 app-desktop（`whiteboard_ai` / `whiteboard_api_client` / `whiteboard_mcp_client` 三包均已在 pubspec 声明；实际引用见模块 1 的"现状"）。
- **对端契约（只读）**：`docs/OpenAPI规范.md`（api_client 的端点/信封/错误码依据）；`docs/AI 助手与 MCP 设计.md`（ai_dart）；`docs/MCP_Server详细设计.md`（mcp_client 传输与能力面）。
- **已知契约事实（回归依据）**：
  - 三包均为纯 Dart 客户端，测试可完全离线运行（无 DLL / 无平台依赖）；
  - mcp_client 传输以"抽象 + 3 实现（stdio / SSE / Streamable HTTP）"组织，新增传输须实现 `McpTransport` 契约；
  - mcp_j 协议面覆盖 JSON-RPC 编解码、标准错误码映射、SSE 事件解码；
  - 测试规模：ai_dart 21 + api_client 28 + mcp_client 32 = **81 个用例**。

## 4. 常用命令

```powershell
# 三个包各自独立测试（进入各自目录）
Set-Location packages\ai_dart; E:\code\flutter-sdk\flutter\bin\flutter.bat pub get; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub
Set-Location ..\api_client; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub
Set-Location ..\mcp_client; E:\code\flutter-sdk\flutter\bin\flutter.bat test --no-pub

# 全仓静态分析（仓库根）
E:\code\flutter-sdk\flutter\bin\flutter.bat analyze
```

## 5. 变更影响提醒（改本模块时注意）

- 改 api_client 信封/错误模型 → 影响 11 的接入点（`lib/services/ai_service.dart` 等）与后续 Web/移动端消费方；服务端（13）接口变更时同步更新端点与模型。
- 改 ai_dart Provider 适配 / 流式事件 → 影响 11 的 `lib/state/ai_state.dart`、`lib/widgets/ai_panel.dart`、`pages/settings_page.dart` 与 AI 测试组。
- 改 mcp_client 协议或传输 → 与 14-svc-mcp（MCP Server）对端契约同步；协议版本升级需两边一起动。
- 三包互不依赖：如发生跨包复用需求，先评估是否应下沉为公共依赖，禁止简单复制代码。
- 新增/删除 `lib/**` 文件 → 同步更新本文档 2.x 映射表。
