# MCP Server 详细设计

- 文档版本：v1.0
- 状态：详细设计稿
- 所属文档：《AI 助手与 MCP 设计 v1.0》《Open API 规范 v1.0》《C++ 核心引擎接口设计 v1.0》
- 适用范围：白板平台、外部 AI 客户端、MCP 生态
- 定位：MCP Server 让外部 AI 客户端（Claude Desktop、Cursor、其他 MCP 客户端）直接调用白板工具，与内部 AI 共用同一套 ToolRegistry

---

## 1. 设计目标

1. **协议标准**：遵循 MCP（Model Context Protocol）规范，支持 Tools / Resources / Prompts。
2. **工具一致**：MCP 工具与内部 ToolRegistry、Open API 完全一致。
3. **权限一致**：MCP 调用与用户操作、AI 操作权限完全一致。
4. **确认级别**：Auto / Preview / Confirm 与内部一致。
5. **审计完整**：所有 MCP 调用写审计日志。
6. **多传输**：支持 stdio、SSE、HTTP（Streamable HTTP）。
7. **多客户端**：支持 Claude Desktop、Cursor、其他 MCP 客户端。
8. **多租户**：支持租户隔离、白板范围限制。
9. **安全合规**：OAuth、API Key、JWT、Scope、速率限制。
10. **可扩展**：新工具自动出现在 MCP 工具列表。

---

## 2. MCP 协议概述

### 2.1 协议基础

- 基于 JSON-RPC 2.0
- 客户端与服务端双向通信
- 支持请求、响应、通知
- 版本协商在初始化阶段完成

### 2.2 三种能力

| 能力 | 说明 | 白板对应 |
|---|---|---|
| Tools | 可调用的函数 | 白板所有操作 |
| Resources | 可读取的资源 | 白板、页面、元素、评论 |
| Prompts | 预定义提示模板 | 白板常用指令模板 |

### 2.3 传输方式

| 传输 | 适用场景 | 说明 |
|---|---|---|
| stdio | 本地客户端 | 标准输入输出 |
| SSE | 远程客户端 | Server-Sent Events |
| Streamable HTTP | 远程客户端 | HTTP 流式 |

### 2.4 生命周期

```text
1. 客户端连接
2. 初始化握手（initialize）
3. 能力协商
4. 客户端发送 initialized 通知
5. 正常通信（tools/list、tools/call、resources/read 等）
6. 关闭连接
```

---

## 3. 整体架构

```text
┌──────────────────────────────────────────────────────────────┐
│ 外部 AI 客户端                                               │
│ Claude Desktop / Cursor / 其他 MCP 客户端                    │
├──────────────────────────────────────────────────────────────┤
│ 传输层                                                       │
│ stdio / SSE / Streamable HTTP                                │
├──────────────────────────────────────────────────────────────┤
│ MCP Server                                                   │
│ 协议处理 / 会话管理 / 能力协商 / 请求路由                    │
├──────────────────────────────────────────────────────────────┤
│ MCP 认证与权限                                               │
│ OAuth / API Key / JWT / Scope / 白板范围                     │
├──────────────────────────────────────────────────────────────┤
│ MCP 工具注册表                                               │
│ 从 ToolRegistry 生成 / Schema 转换 / 确认级别                │
├──────────────────────────────────────────────────────────────┤
│ MCP 资源注册表                                               │
│ 白板 / 页面 / 元素 / 评论 / 历史                             │
├──────────────────────────────────────────────────────────────┤
│ MCP 提示模板                                                 │
│ 常用指令 / 模板 / 上下文                                     │
├──────────────────────────────────────────────────────────────┤
│ C++ 核心 ToolRegistry                                        │
│ 与内部 AI、Open API 共用同一套工具                           │
├──────────────────────────────────────────────────────────────┤
│ 白板内核                                                     │
│ 元素 / 页面 / 3D / 函数 / 流程图 / 表格 / 思维导图            │
├──────────────────────────────────────────────────────────────┤
│ 审计日志                                                     │
│ 所有 MCP 调用写入审计                                        │
└──────────────────────────────────────────────────────────────┘
```

---

## 4. 传输层

### 4.1 stdio

适用于本地 MCP 客户端（如 Claude Desktop）。

```text
客户端 <--stdin/stdout--> MCP Server
```

特点：

- 无需网络
- 无需认证（本地信任）
- 启动快
- 适合桌面集成

配置示例（Claude Desktop）：

```json
{
  "mcpServers": {
    "whiteboard": {
      "command": "whiteboard-mcp",
      "args": ["--board", "board_123"],
      "env": {
        "WB_API_KEY": "wbp_xxx"
      }
    }
  }
}
```

### 4.2 SSE

适用于远程 MCP 客户端。

```text
客户端 <--SSE--> MCP Server
客户端 --HTTP POST--> MCP Server
```

特点：

- 服务端推送
- 客户端 POST 请求
- 需要认证
- 适合 Web 客户端

### 4.3 Streamable HTTP

MCP 新版传输方式。

```text
客户端 <--HTTP 流--> MCP Server
```

特点：

- 单端点
- 支持流式
- 支持无状态
- 适合云部署

### 4.4 传输选择

| 场景 | 传输 |
|---|---|
| 本地桌面客户端 | stdio |
| 远程 Web 客户端 | SSE |
| 云服务 | Streamable HTTP |
| 企业内部 | Streamable HTTP + mTLS |

---

## 5. 初始化握手

### 5.1 initialize 请求

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "roots": { "listChanged": true },
      "sampling": {}
    },
    "clientInfo": {
      "name": "Claude Desktop",
      "version": "1.0.0"
    }
  }
}
```

### 5.2 initialize 响应

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "tools": { "listChanged": true },
      "resources": { "subscribe": true, "listChanged": true },
      "prompts": { "listChanged": true },
      "logging": {}
    },
    "serverInfo": {
      "name": "whiteboard-mcp",
      "version": "1.0.0"
    },
    "instructions": "白板 MCP Server，支持元素、页面、3D、函数、流程图等操作。"
  }
}
```

### 5.3 initialized 通知

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/initialized"
}
```

### 5.4 版本协商

- 客户端发送支持的协议版本
- 服务端返回支持的版本
- 不支持则返回错误
- 当前支持：`2025-06-18`、`2024-11-05`

---

## 6. Tools

### 6.1 tools/list

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list",
  "params": {
    "cursor": null
  }
}
```

响应：

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "element_create",
        "description": "在白板上创建一个或多个元素，如便签、文本、形状、图片",
        "inputSchema": {
          "type": "object",
          "properties": {
            "boardId": { "type": "string" },
            "pageId": { "type": "string" },
            "elements": {
              "type": "array",
              "items": { "$ref": "#/definitions/Element" }
            },
            "dryRun": { "type": "boolean", "default": false }
          },
          "required": ["boardId", "pageId", "elements"]
        }
      }
    ],
    "nextCursor": null
  }
}
```

### 6.2 tools/call

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "element_create",
    "arguments": {
      "boardId": "board_123",
      "pageId": "page_1",
      "elements": [
        {
          "type": "sticky",
          "text": "用户痛点",
          "position": { "x": 100, "y": 200 },
          "size": { "width": 200, "height": 150 },
          "style": { "color": "#FFE58F" }
        }
      ]
    }
  }
}
```

响应：

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "已创建 1 个便签，ID: elem_1"
      }
    ],
    "isError": false,
    "structuredContent": {
      "elementIds": ["elem_1"],
      "affectedElements": ["elem_1"]
    }
  }
}
```

### 6.3 工具命名

MCP 工具名使用下划线，映射内部点号：

| 内部 Tool ID | MCP 工具名 |
|---|---|
| `element.create` | `element_create` |
| `element.update` | `element_update` |
| `element.delete` | `element_delete` |
| `page.create` | `page_create` |
| `page.duplicate` | `page_duplicate` |
| `flowchart.create` | `flowchart_create` |
| `flowchart.autoLayout` | `flowchart_auto_layout` |
| `render.3d.create` | `render_3d_create` |
| `render.3d.setFaceColor` | `render_3d_set_face_color` |
| `render.function.setStyle` | `render_function_set_style` |

规则：点号转下划线，驼峰转下划线。

### 6.4 工具分类

| 分类 | 工具数量 | 说明 |
|---|---|---|
| 白板 | 8 | board.* |
| 页面 | 12 | page.* |
| 元素 | 15 | element.* |
| 连线 | 5 | connector.* |
| 评论 | 6 | comment.* |
| 导出 | 4 | export.* |
| 历史 | 3 | history.* |
| 模板 | 2 | template.* |
| 思维导图 | 6 | mindmap.* |
| 表格 | 6 | table.* |
| 流程图 | 12 | flowchart.* |
| 函数 | 5 | render.function.* |
| 3D | 8 | render.3d.* |
| 2D | 3 | render.2d.* |
| 文档 | 3 | document.* |
| 批注 | 6 | annotate.* |
| AI | 4 | ai.* |
| 协作 | 3 | presence.* |

### 6.5 工具确认级别

MCP 调用时，确认级别影响返回：

| 级别 | MCP 行为 |
|---|---|
| Auto | 直接执行，返回结果 |
| Preview | 返回预览，等待客户端确认后执行 |
| Confirm | 返回确认请求，等待客户端确认 |

对于 Preview 和 Confirm，MCP Server 返回：

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "此操作需要确认：删除 5 个元素"
      }
    ],
    "isError": false,
    "structuredContent": {
      "requiresConfirmation": true,
      "confirmationId": "conf_123",
      "preview": { }
    }
  }
}
```

客户端确认后，调用：

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "tools/call",
  "params": {
    "name": "confirm_operation",
    "arguments": {
      "confirmationId": "conf_123",
      "approved": true
    }
  }
}
```

### 6.6 工具变更通知

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/tools/list_changed"
}
```

---

## 7. Resources

### 7.1 resources/list

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "resources/list",
  "params": { "cursor": null }
}
```

响应：

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "resources": [
      {
        "uri": "whiteboard://boards/board_123",
        "name": "产品需求梳理",
        "description": "白板元数据",
        "mimeType": "application/json"
      },
      {
        "uri": "whiteboard://boards/board_123/pages/page_1",
        "name": "用户旅程",
        "description": "页面内容",
        "mimeType": "application/json"
      },
      {
        "uri": "whiteboard://boards/board_123/pages/page_1/elements",
        "name": "元素列表",
        "description": "页面所有元素",
        "mimeType": "application/json"
      },
      {
        "uri": "whiteboard://boards/board_123/comments",
        "name": "评论",
        "description": "白板评论",
        "mimeType": "application/json"
      }
    ],
    "nextCursor": null
  }
}
```

### 7.2 resources/read

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "resources/read",
  "params": {
    "uri": "whiteboard://boards/board_123/pages/page_1/elements"
  }
}
```

响应：

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "result": {
    "contents": [
      {
        "uri": "whiteboard://boards/board_123/pages/page_1/elements",
        "mimeType": "application/json",
        "text": "{ \"elements\": [ ... ] }"
      }
    ]
  }
}
```

### 7.3 资源 URI 方案

| URI | 说明 |
|---|---|
| `whiteboard://boards/{boardId}` | 白板元数据 |
| `whiteboard://boards/{boardId}/pages` | 页面列表 |
| `whiteboard://boards/{boardId}/pages/{pageId}` | 页面详情 |
| `whiteboard://boards/{boardId}/pages/{pageId}/elements` | 页面元素 |
| `whiteboard://boards/{boardId}/pages/{pageId}/thumbnail` | 页面缩略图 |
| `whiteboard://boards/{boardId}/comments` | 评论 |
| `whiteboard://boards/{boardId}/history` | 历史 |
| `whiteboard://boards/{boardId}/collaborators` | 协作者 |
| `whiteboard://boards/{boardId}/templates` | 模板 |

### 7.4 资源订阅

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "resources/subscribe",
  "params": {
    "uri": "whiteboard://boards/board_123/pages/page_1/elements"
  }
}
```

资源变更通知：

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/resources/updated",
  "params": {
    "uri": "whiteboard://boards/board_123/pages/page_1/elements"
  }
}
```

---

## 8. Prompts

### 8.1 prompts/list

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "prompts/list"
}
```

响应：

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "result": {
    "prompts": [
      {
        "name": "brainstorm",
        "description": "头脑风暴：生成便签并分组",
        "arguments": [
          { "name": "topic", "required": true },
          { "name": "count", "required": false }
        ]
      },
      {
        "name": "flowchart",
        "description": "生成流程图",
        "arguments": [
          { "name": "process", "required": true }
        ]
      },
      {
        "name": "summarize",
        "description": "总结当前白板",
        "arguments": []
      }
    ]
  }
}
```

### 8.2 prompts/get

```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "method": "prompts/get",
  "params": {
    "name": "brainstorm",
    "arguments": {
      "topic": "用户痛点",
      "count": "10"
    }
  }
}
```

响应：

```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "result": {
    "description": "头脑风暴：生成便签并分组",
    "messages": [
      {
        "role": "user",
        "content": {
          "type": "text",
          "text": "请围绕“用户痛点”生成 10 个便签，并按主题分组。"
        }
      }
    ]
  }
}
```

### 8.3 内置提示模板

| 模板 | 说明 |
|---|---|
| brainstorm | 头脑风暴 |
| flowchart | 生成流程图 |
| mindmap | 生成思维导图 |
| summarize | 总结白板 |
| cluster | 聚类整理 |
| vote | 投票 |
| userJourney | 用户旅程 |
| swot | SWOT 分析 |
| retrospective | 回顾 |
| kanban | 看板 |

---

## 9. 认证与权限

### 9.1 认证方式

| 方式 | 适用 | 说明 |
|---|---|---|
| API Key | stdio / HTTP | Header 或环境变量 |
| OAuth 2.0 | SSE / HTTP | Bearer Token |
| JWT | 内部 | Bearer Token |
| mTLS | 企业 | 双向证书 |

### 9.2 stdio 认证

- 通过环境变量传入 API Key
- 或配置文件
- 本地信任，无需网络认证

```json
{
  "env": {
    "WB_API_KEY": "wbp_xxx",
    "WB_BOARD_ID": "board_123"
  }
}
```

### 9.3 HTTP 认证

```http
Authorization: Bearer <token>
X-API-Key: <key>
```

### 9.4 Scope 校验

每个工具调用校验 Scope：

```cpp
bool checkScope(const std::string& toolId, const std::vector<std::string>& scopes) {
  auto tool = ToolRegistry::instance().getTool(toolId);
  return std::find(scopes.begin(), scopes.end(), tool->scope) != scopes.end();
}
```

### 9.5 白板范围

Token 可限制白板范围：

```json
{
  "scopes": ["element:write", "page:read"],
  "boards": ["board_123", "board_456"],
  "rateLimit": 1000,
  "expiresAt": "2026-12-31T23:59:59Z"
}
```

### 9.6 速率限制

- 默认 1000 请求/分钟/Token
- 企业可自定义
- 超限返回错误

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "error": {
    "code": -32000,
    "message": "Rate limited",
    "data": {
      "retryAfter": 60
    }
  }
}
```

---

## 10. 审计

### 10.1 审计字段

```cpp
struct MCPAuditEntry {
  std::string id;
  Timestamp timestamp;
  std::string userId;
  std::string clientName;
  std::string clientVersion;
  std::string toolId;
  std::string argsJson;
  std::string resultJson;
  bool fromAI;
  std::string ip;
  std::string userAgent;
  std::string boardId;
};
```

### 10.2 审计内容

- 所有 tools/call
- 所有 resources/read
- 认证成功/失败
- 权限拒绝
- 速率限制
- 确认操作

### 10.3 审计导出

- 支持导出 JSON / CSV
- 支持按时间、用户、工具筛选
- 支持企业审计报告

---

## 11. C++ 核心实现

### 11.1 模块

```text
core/
  mcp/
    mcp_server.h            MCP 服务
    mcp_server.cpp
    mcp_session.h           MCP 会话
    mcp_session.cpp
    mcp_protocol.h          MCP 协议
    mcp_protocol.cpp
    mcp_tool_registry.h     MCP 工具注册
    mcp_tool_registry.cpp
    mcp_resource_registry.h MCP 资源注册
    mcp_resource_registry.cpp
    mcp_prompt_registry.h   MCP 提示注册
    mcp_prompt_registry.cpp
    mcp_auth.h              MCP 认证
    mcp_auth.cpp
    mcp_transport.h         传输抽象
    mcp_transport.cpp
    mcp_stdio_transport.h   stdio 传输
    mcp_stdio_transport.cpp
    mcp_sse_transport.h     SSE 传输
    mcp_sse_transport.cpp
    mcp_http_transport.h    HTTP 传输
    mcp_http_transport.cpp
    mcp_audit.h             MCP 审计
    mcp_audit.cpp
```

### 11.2 MCP Server

```cpp
class MCPServer {
public:
  MCPServer();
  ~MCPServer();

  Result<void> start(const MCPConfig& config);
  void stop();

  bool isRunning() const;

  void setAuthProvider(std::shared_ptr<MCPAuth> auth);
  void setToolRegistry(std::shared_ptr<MCPToolRegistry> registry);
  void setResourceRegistry(std::shared_ptr<MCPResourceRegistry> registry);
  void setPromptRegistry(std::shared_ptr<MCPPromptRegistry> registry);

  std::string handleRequest(const std::string& requestJson, const MCPSession& session);

private:
  MCPConfig config_;
  std::atomic<bool> running_{false};
  std::shared_ptr<MCPAuth> auth_;
  std::shared_ptr<MCPToolRegistry> toolRegistry_;
  std::shared_ptr<MCPResourceRegistry> resourceRegistry_;
  std::shared_ptr<MCPPromptRegistry> promptRegistry_;
  std::unordered_map<std::string, MCPSession> sessions_;
  std::mutex mutex_;
};
```

### 11.3 MCP 会话

```cpp
struct MCPClientInfo {
  std::string name;
  std::string version;
};

struct MCPSession {
  std::string id;
  std::string userId;
  std::string token;
  std::vector<std::string> scopes;
  std::vector<std::string> allowedBoards;
  MCPClientInfo clientInfo;
  std::string protocolVersion;
  Timestamp createdAt;
  Timestamp lastActiveAt;
  bool initialized = false;
};
```

### 11.4 MCP 协议处理

```cpp
class MCPProtocol {
public:
  std::string handleInitialize(const std::string& requestJson, MCPSession& session);
  std::string handleInitialized(const std::string& requestJson, MCPSession& session);

  std::string handleToolsList(const std::string& requestJson, const MCPSession& session);
  std::string handleToolsCall(const std::string& requestJson, const MCPSession& session);

  std::string handleResourcesList(const std::string& requestJson, const MCPSession& session);
  std::string handleResourcesRead(const std::string& requestJson, const MCPSession& session);
  std::string handleResourcesSubscribe(const std::string& requestJson, const MCPSession& session);

  std::string handlePromptsList(const std::string& requestJson, const MCPSession& session);
  std::string handlePromptsGet(const std::string& requestJson, const MCPSession& session);

  std::string handlePing(const std::string& requestJson);
  std::string handleShutdown(const std::string& requestJson);

  std::string makeError(int id, int code, const std::string& message, const std::string& data = "");
  std::string makeResult(int id, const std::string& resultJson);
};
```

### 11.5 MCP 工具注册

```cpp
class MCPToolRegistry {
public:
  void buildFromToolRegistry(const ToolRegistry& registry);

  std::string listTools(const MCPSession& session) const;
  std::string callTool(const std::string& toolName, const std::string& argsJson, const MCPSession& session);

  std::string mapToolName(const std::string& internalId) const;
  std::string unmapToolName(const std::string& mcpName) const;

private:
  std::unordered_map<std::string, std::string> nameMap_;
  std::unordered_map<std::string, MCPToolDefinition> tools_;
  std::mutex mutex_;
};

struct MCPToolDefinition {
  std::string name;
  std::string description;
  std::string inputSchema;
  std::string internalToolId;
  std::string scope;
  ConfirmationLevel confirmation;
};
```

### 11.6 MCP 资源注册

```cpp
class MCPResourceRegistry {
public:
  std::string listResources(const MCPSession& session) const;
  std::string readResource(const std::string& uri, const MCPSession& session);

  void subscribe(const std::string& uri, const std::string& sessionId);
  void unsubscribe(const std::string& uri, const std::string& sessionId);
  void notifyUpdate(const std::string& uri);

private:
  std::unordered_map<std::string, std::vector<std::string>> subscriptions_;
  std::mutex mutex_;
};
```

### 11.7 MCP 提示注册

```cpp
class MCPPromptRegistry {
public:
  void registerPrompt(const MCPPrompt& prompt);
  std::string listPrompts() const;
  std::string getPrompt(const std::string& name, const std::string& argsJson);

private:
  std::unordered_map<std::string, MCPPrompt> prompts_;
  std::mutex mutex_;
};

struct MCPPrompt {
  std::string name;
  std::string description;
  std::vector<MCPPromptArgument> arguments;
  std::function<std::string(const std::string&)> handler;
};

struct MCPPromptArgument {
  std::string name;
  std::string description;
  bool required;
};
```

### 11.8 MCP 认证

```cpp
class MCPAuth {
public:
  virtual ~MCPAuth() = default;
  virtual bool validateToken(const std::string& token) = 0;
  virtual std::string getUserId(const std::string& token) = 0;
  virtual std::vector<std::string> getScopes(const std::string& token) = 0;
  virtual std::vector<std::string> getAllowedBoards(const std::string& token) = 0;
  virtual int getRateLimit(const std::string& token) = 0;
};

class APIKeyAuth : public MCPAuth { /* ... */ };
class OAuthAuth : public MCPAuth { /* ... */ };
class JWTAuth : public MCPAuth { /* ... */ };
```

### 11.9 MCP 传输

```cpp
class MCPTransport {
public:
  virtual ~MCPTransport() = default;
  virtual void start() = 0;
  virtual void stop() = 0;
  virtual void send(const std::string& message) = 0;
  virtual void onMessage(std::function<void(const std::string&)> callback) = 0;
};

class StdioTransport : public MCPTransport { /* ... */ };
class SSETransport : public MCPTransport { /* ... */ };
class HTTPTransport : public MCPTransport { /* ... */ };
```

### 11.10 FFI 接口

```cpp
extern "C" {
  // MCP Server
  const char* wb_mcp_start(const char* configJson);
  const char* wb_mcp_stop();
  const char* wb_mcp_is_running();
  const char* wb_mcp_handle_request(const char* requestJson, const char* sessionId);

  // MCP 会话
  const char* wb_mcp_session_create(const char* token);
  const char* wb_mcp_session_get(const char* sessionId);
  const char* wb_mcp_session_close(const char* sessionId);

  // MCP 工具
  const char* wb_mcp_list_tools(const char* sessionId);
  const char* wb_mcp_call_tool(const char* toolName, const char* argsJson, const char* sessionId);

  // MCP 资源
  const char* wb_mcp_list_resources(const char* sessionId);
  const char* wb_mcp_read_resource(const char* uri, const char* sessionId);

  // MCP 提示
  const char* wb_mcp_list_prompts(const char* sessionId);
  const char* wb_mcp_get_prompt(const char* name, const char* argsJson, const char* sessionId);

  // MCP 审计
  const char* wb_mcp_audit_query(const char* filterJson);
  const char* wb_mcp_audit_export(const char* path);
}
```

### 11.11 Tool Registry 扩展

```text
mcp.start
mcp.stop
mcp.isRunning
mcp.handleRequest

mcp.session.create
mcp.session.get
mcp.session.close

mcp.listTools
mcp.callTool

mcp.listResources
mcp.readResource

mcp.listPrompts
mcp.getPrompt

mcp.audit.query
mcp.audit.export
```

---

## 12. 部署模式

### 12.1 本地模式（stdio）

```text
Claude Desktop <--stdio--> whiteboard-mcp <--FFI--> wb_core
```

- 无需网络
- 无需服务端
- 适合单机使用

### 12.2 云模式（Streamable HTTP）

```text
Cursor <--HTTPS--> MCP Server (云) <--FFI--> wb_core
```

- 多租户
- OAuth 认证
- 适合团队

### 12.3 私有化模式

```text
企业客户端 <--HTTPS/mTLS--> MCP Server (私有) <--FFI--> wb_core
```

- 数据不出内网
- 支持 SSO
- 支持审计

### 12.4 混合模式

```text
本地客户端 <--stdio--> 本地 MCP Server <--HTTPS--> 云白板
```

- 本地工具调用
- 云端数据同步

---

## 13. 交互流程

### 13.1 客户端调用工具

```text
1. 客户端连接 MCP Server
2. 初始化握手
3. 客户端请求 tools/list
4. 服务端返回工具列表
5. 客户端选择工具并调用 tools/call
6. 服务端校验 Token 和 Scope
7. 服务端调用 C++ 核心 Tool
8. 返回结果
9. 写入审计日志
```

### 13.2 高风险操作确认

```text
1. 客户端调用 tools/call（删除元素）
2. 服务端检测确认级别为 Confirm
3. 返回确认请求
4. 客户端展示确认
5. 用户确认
6. 客户端调用 confirm_operation
7. 服务端执行
8. 返回结果
```

### 13.3 资源订阅

```text
1. 客户端请求 resources/subscribe
2. 服务端记录订阅
3. 资源变更时
4. 服务端发送 notifications/resources/updated
5. 客户端重新读取资源
```

---

## 14. 安全与合规

- 所有 HTTP 传输使用 TLS
- Token 加密存储
- API Key 可绑定白板、IP、速率
- 支持租户隔离
- 支持 SSO / SCIM
- 支持审计日志
- 支持数据脱敏
- 支持数据不训练
- 支持企业关闭云 AI
- 支持私有化部署
- 支持 GDPR / SOC 2 / ISO 27001

---

## 15. 错误码

MCP 使用 JSON-RPC 错误码：

| 错误码 | 说明 |
|---|---|
| -32700 | Parse error |
| -32600 | Invalid Request |
| -32601 | Method not found |
| -32602 | Invalid params |
| -32603 | Internal error |
| -32000 | Server error |
| -32001 | Rate limited |
| -32002 | Permission denied |
| -32003 | Not found |
| -32004 | Conflict |
| -32005 | Confirmation required |
| -32006 | Cancelled |

错误响应：

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "error": {
    "code": -32002,
    "message": "Permission denied",
    "data": {
      "scope": "element:write",
      "toolId": "element.create"
    }
  }
}
```

---

## 16. 里程碑

### M5.6.1：MCP 协议基础
- JSON-RPC 2.0
- 初始化握手
- 版本协商
- 能力协商

### M5.6.2：Tools
- tools/list
- tools/call
- 工具映射
- 确认级别

### M5.6.3：Resources
- resources/list
- resources/read
- resources/subscribe
- 资源变更通知

### M5.6.4：Prompts
- prompts/list
- prompts/get
- 内置模板

### M5.6.5：认证与权限
- API Key
- OAuth
- JWT
- Scope
- 白板范围
- 速率限制

### M5.6.6：传输
- stdio
- SSE
- Streamable HTTP

### M5.6.7：审计
- 审计字段
- 审计日志
- 审计导出

### M5.6.8：部署
- 本地模式
- 云模式
- 私有化模式
- 混合模式

### M5.6.9：客户端集成
- Claude Desktop
- Cursor
- 其他 MCP 客户端

---

## 17. 最终确认清单

| 项 | 确认结果 |
|---|---|
| MCP 协议 | 支持 |
| JSON-RPC 2.0 | 支持 |
| Tools | 支持 |
| Resources | 支持 |
| Prompts | 支持 |
| stdio | 支持 |
| SSE | 支持 |
| Streamable HTTP | 支持 |
| API Key | 支持 |
| OAuth 2.0 | 支持 |
| JWT | 支持 |
| Scope | 支持 |
| 白板范围 | 支持 |
| 速率限制 | 支持 |
| 确认级别 | 支持 |
| 审计 | 支持 |
| 多租户 | 支持 |
| 私有化 | 支持 |
| 工具与内部一致 | 支持 |
| 权限与用户一致 | 支持 |

---

## 18. 附录：MCP 方法列表

| 方法 | 说明 |
|---|---|
| `initialize` | 初始化 |
| `notifications/initialized` | 初始化完成 |
| `ping` | 心跳 |
| `tools/list` | 列出工具 |
| `tools/call` | 调用工具 |
| `notifications/tools/list_changed` | 工具列表变更 |
| `resources/list` | 列出资源 |
| `resources/read` | 读取资源 |
| `resources/subscribe` | 订阅资源 |
| `resources/unsubscribe` | 取消订阅 |
| `notifications/resources/updated` | 资源更新 |
| `notifications/resources/list_changed` | 资源列表变更 |
| `prompts/list` | 列出提示 |
| `prompts/get` | 获取提示 |
| `notifications/prompts/list_changed` | 提示列表变更 |
| `logging/setLevel` | 设置日志级别 |
| `notifications/message` | 日志消息 |
| `completion/complete` | 补全 |
| `shutdown` | 关闭 |

---

## 19. 附录：MCP 工具完整列表

### 白板

- `board_create`
- `board_get`
- `board_update`
- `board_delete`
- `board_share`
- `board_list_collaborators`
- `board_add_collaborator`
- `board_remove_collaborator`

### 页面

- `page_list`
- `page_create`
- `page_get`
- `page_update`
- `page_delete`
- `page_duplicate`
- `page_move`
- `page_rename`
- `page_lock`
- `page_hide`
- `page_set_background`
- `page_thumbnail`
- `page_split`
- `page_merge`

### 元素

- `element_list`
- `element_create`
- `element_get`
- `element_update`
- `element_delete`
- `element_batch`
- `element_set_style`
- `element_move`
- `element_resize`
- `element_align`
- `element_distribute`
- `element_group`
- `element_ungroup`
- `element_bring_forward`
- `element_send_backward`

### 连线

- `connector_list`
- `connector_create`
- `connector_get`
- `connector_update`
- `connector_delete`

### 评论

- `comment_list`
- `comment_create`
- `comment_get`
- `comment_update`
- `comment_delete`
- `comment_reply`
- `comment_resolve`

### 导出

- `export_create`
- `export_get`
- `export_download`
- `export_page`

### 历史

- `history_list`
- `history_undo`
- `history_redo`
- `history_snapshot`

### 思维导图

- `mindmap_create`
- `mindmap_add_node`
- `mindmap_remove_node`
- `mindmap_set_layout`
- `mindmap_set_style`
- `mindmap_export`

### 表格

- `table_create`
- `table_set_cell`
- `table_set_formula`
- `table_sort`
- `table_filter`
- `table_set_style`

### 流程图

- `flowchart_create`
- `flowchart_add_node`
- `flowchart_remove_node`
- `flowchart_connect`
- `flowchart_add_swimlane`
- `flowchart_remove_swimlane`
- `flowchart_auto_layout`
- `flowchart_partial_layout`
- `flowchart_relayout`
- `flowchart_to_swimlane`
- `flowchart_label_branches`
- `flowchart_template_apply`

### 函数

- `render_function_create`
- `render_function_set_style`
- `render_function_add`
- `render_function_analyze`
- `render_function_export`

### 3D

- `render_3d_create`
- `render_3d_render`
- `render_3d_pick_surface`
- `render_3d_set_face_color`
- `render_3d_set_material`
- `render_3d_transform`
- `render_3d_set_light`
- `render_3d_export`

### 2D

- `render_2d_create`
- `render_2d_set_style`
- `render_2d_annotate`

### 文档

- `document_embed`
- `document_goto_page`
- `document_extract_text`

### 批注

- `annotate_enter_transparent`
- `annotate_exit_transparent`
- `annotate_set_penetrate`
- `annotate_toggle_mode`
- `annotate_add_stroke`
- `annotate_save_to_board`

### AI

- `ai_session_create`
- `ai_send_message`
- `ai_send_audio`
- `ai_execute_tool_call`

### 协作

- `presence_get`
- `follow_user`
- `present_start`

---

以上是《MCP Server 详细设计 v1.0》完整内容。