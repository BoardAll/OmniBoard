# Open API 规范 v1

- 文档版本：v1.0
- 状态：详细设计稿
- 所属文档：《白板软件设计文档 v0.5》《C++ 核心引擎接口设计 v1.0》《AI 助手与 MCP 设计 v1.0》
- 适用范围：白板平台、第三方开发者、AI 客户端、MCP
- 定位：Open API 是白板能力的对外统一入口，与内部 ToolRegistry 完全一致

---

## 1. 设计目标

1. **统一能力**：Open API 暴露的能力与内部 ToolRegistry 一致。
2. **权限一致**：API 调用与用户操作、AI 操作权限完全一致。
3. **REST + WebSocket + Webhook**：覆盖资源管理、实时协作、事件回调。
4. **OpenAPI 3.1**：标准规范描述，支持代码生成。
5. **MCP 兼容**：同一套工具可通过 MCP 暴露给 AI 客户端。
6. **安全合规**：OAuth 2.0、API Key、JWT、Scope、审计、速率限制。
7. **幂等性**：支持 Idempotency-Key，保证重试安全。
8. **可扩展**：新工具自动出现在 API 和 MCP 中。
9. **开发者友好**：清晰的错误码、分页、过滤、排序、SDK。
10. **企业级**：租户隔离、SSO、审计、私有化部署。

---

## 2. 整体架构

```text
┌──────────────────────────────────────────────────────────────┐
│ 第三方开发者 / AI 客户端 / 内部服务                          │
├──────────────────────────────────────────────────────────────┤
│ Open API Gateway                                             │
│ 认证 / 授权 / 限流 / 路由 / 审计 / 版本                      │
├──────────────────────────────────────────────────────────────┤
│ REST API          WebSocket API          Webhook             │
│ 资源 CRUD         实时事件               事件回调             │
├──────────────────────────────────────────────────────────────┤
│ C++ 核心 ToolRegistry                                        │
│ 工具定义 / 参数 Schema / 权限 / 确认级别 / 执行              │
├──────────────────────────────────────────────────────────────┤
│ 白板内核                                                     │
│ 元素 / 页面 / 3D / 函数 / 流程图 / 表格 / 思维导图            │
├──────────────────────────────────────────────────────────────┤
│ MCP Server                                                   │
│ 工具映射 / 认证 / 权限 / 审计 / 外部 AI 客户端                │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. 认证与授权

### 3.1 认证方式

| 方式 | 适用场景 | Header |
|---|---|---|
| OAuth 2.0 | 第三方应用 | `Authorization: Bearer <token>` |
| API Key | 服务端集成 | `X-API-Key: <key>` |
| JWT | 内部服务 | `Authorization: Bearer <jwt>` |
| SSO | 企业 | SAML / OIDC |

### 3.2 OAuth 2.0 流程

- Authorization Code + PKCE
- Client Credentials（服务端）
- Refresh Token
- Token 有效期：Access 1 小时，Refresh 30 天

### 3.3 Scope 列表

| Scope | 说明 |
|---|---|
| `board:read` | 读取白板 |
| `board:write` | 创建、修改、删除白板 |
| `board:share` | 分享白板、修改权限 |
| `page:read` | 读取页面 |
| `page:write` | 创建、修改、删除页面 |
| `element:read` | 读取元素 |
| `element:write` | 创建、修改、删除元素 |
| `connector:read` | 读取连线 |
| `connector:write` | 创建、修改、删除连线 |
| `comment:read` | 读取评论 |
| `comment:write` | 创建、回复、解决评论 |
| `export:read` | 导出白板 |
| `history:read` | 读取历史 |
| `history:write` | 撤销、重做 |
| `ai:invoke` | 调用 AI 工具 |
| `mcp:invoke` | 调用 MCP 工具 |
| `admin:read` | 管理只读 |
| `admin:write` | 管理读写 |

### 3.4 权限模型

- 白板级 ACL
- 页面级 ACL（可选）
- 元素级 ACL（可选）
- API Key 可绑定白板范围、IP、速率
- Token 可限制 Scope、白板、有效期
- 支持租户隔离

---

## 4. 基础约定

### 4.1 Base URL

```text
https://api.whiteboard.example.com/v1
```

### 4.2 版本

- URL 版本：`/v1`
- Header 版本：`X-API-Version: 1`
- 向后兼容，废弃接口提前 6 个月通知

### 4.3 请求格式

- `Content-Type: application/json`
- 字符集：UTF-8
- 时间：ISO 8601 UTC
- ID：字符串，全局唯一

### 4.4 响应格式

```json
{
  "ok": true,
  "data": { },
  "error": null,
  "meta": {
    "requestId": "req_123",
    "timestamp": "2026-09-25T10:00:00Z"
  }
}
```

错误：

```json
{
  "ok": false,
  "data": null,
  "error": {
    "code": "PERMISSION_DENIED",
    "message": "No permission to write this board",
    "detail": "scope element:write required"
  },
  "meta": {
    "requestId": "req_123",
    "timestamp": "2026-09-25T10:00:00Z"
  }
}
```

### 4.5 分页

- 参数：`limit`（默认 20，最大 100）、`cursor`
- 响应：

```json
{
  "data": [ ],
  "meta": {
    "nextCursor": "cursor_abc",
    "hasMore": true,
    "total": 123
  }
}
```

### 4.6 排序

- 参数：`sort=createdAt:desc`
- 支持字段：`createdAt`、`updatedAt`、`name`、`index`

### 4.7 过滤

- 参数：`filter=type:sticky,color:#FFE58F`
- 支持字段：`type`、`color`、`pageId`、`createdBy`

### 4.8 幂等性

- Header：`Idempotency-Key: <uuid>`
- 相同 Key + 相同请求体，24 小时内返回相同结果
- 适用于：创建、更新、删除

### 4.9 速率限制

- Header：
  - `X-RateLimit-Limit`
  - `X-RateLimit-Remaining`
  - `X-RateLimit-Reset`
- 超限返回 `429 Too Many Requests`
- 默认：1000 请求/分钟/用户
- 企业可自定义

### 4.10 错误码

| HTTP | 错误码 | 说明 |
|---|---|---|
| 400 | `INVALID_ARGUMENT` | 参数错误 |
| 401 | `UNAUTHENTICATED` | 未认证 |
| 403 | `PERMISSION_DENIED` | 无权限 |
| 404 | `NOT_FOUND` | 资源不存在 |
| 409 | `CONFLICT` | 冲突 |
| 422 | `UNPROCESSABLE` | 无法处理 |
| 429 | `RATE_LIMITED` | 速率限制 |
| 500 | `INTERNAL_ERROR` | 内部错误 |
| 503 | `UNAVAILABLE` | 服务不可用 |

---

## 5. 核心资源与接口

### 5.1 Boards

| 方法 | 路径 | 说明 | Scope |
|---|---|---|---|
| GET | `/boards` | 列出白板 | `board:read` |
| POST | `/boards` | 创建白板 | `board:write` |
| GET | `/boards/{boardId}` | 获取白板 | `board:read` |
| PATCH | `/boards/{boardId}` | 更新白板 | `board:write` |
| DELETE | `/boards/{boardId}` | 删除白板 | `board:write` |
| POST | `/boards/{boardId}/share` | 分享白板 | `board:share` |
| GET | `/boards/{boardId}/collaborators` | 获取协作者 | `board:read` |
| POST | `/boards/{boardId}/collaborators` | 添加协作者 | `board:share` |
| DELETE | `/boards/{boardId}/collaborators/{userId}` | 移除协作者 | `board:share` |

创建白板：

```http
POST /v1/boards
Authorization: Bearer <token>
Content-Type: application/json
Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000

{
  "name": "产品需求梳理",
  "description": "Q4 需求评审",
  "themeId": "clean-professional",
  "backgroundId": "whiteboard"
}
```

响应：

```json
{
  "ok": true,
  "data": {
    "id": "board_123",
    "name": "产品需求梳理",
    "description": "Q4 需求评审",
    "ownerId": "user_1",
    "themeId": "clean-professional",
    "backgroundId": "whiteboard",
    "createdAt": "2026-09-25T10:00:00Z",
    "updatedAt": "2026-09-25T10:00:00Z"
  }
}
```

### 5.2 Pages

| 方法 | 路径 | 说明 | Scope |
|---|---|---|---|
| GET | `/boards/{boardId}/pages` | 列出页面 | `page:read` |
| POST | `/boards/{boardId}/pages` | 创建页面 | `page:write` |
| GET | `/pages/{pageId}` | 获取页面 | `page:read` |
| PATCH | `/pages/{pageId}` | 更新页面 | `page:write` |
| DELETE | `/pages/{pageId}` | 删除页面 | `page:write` |
| POST | `/pages/{pageId}/duplicate` | 复制页面 | `page:write` |
| POST | `/pages/{pageId}/move` | 移动页面 | `page:write` |
| POST | `/pages/{pageId}/split` | 拆分页面 | `page:write` |
| POST | `/pages/merge` | 合并页面 | `page:write` |
| GET | `/pages/{pageId}/thumbnail` | 获取缩略图 | `page:read` |

创建页面：

```http
POST /v1/boards/board_123/pages
Authorization: Bearer <token>
Content-Type: application/json

{
  "name": "用户旅程",
  "backgroundId": "dots",
  "viewport": { "x": 0, "y": 0, "zoom": 1 }
}
```

### 5.3 Elements

| 方法 | 路径 | 说明 | Scope |
|---|---|---|---|
| GET | `/pages/{pageId}/elements` | 列出元素 | `element:read` |
| POST | `/pages/{pageId}/elements` | 创建元素 | `element:write` |
| GET | `/elements/{elementId}` | 获取元素 | `element:read` |
| PATCH | `/elements/{elementId}` | 更新元素 | `element:write` |
| DELETE | `/elements/{elementId}` | 删除元素 | `element:write` |
| POST | `/elements/batch` | 批量操作 | `element:write` |
| POST | `/elements/{elementId}/style` | 设置样式 | `element:write` |
| POST | `/elements/{elementId}/move` | 移动元素 | `element:write` |
| POST | `/elements/{elementId}/resize` | 缩放元素 | `element:write` |
| POST | `/elements/align` | 对齐 | `element:write` |
| POST | `/elements/distribute` | 分布 | `element:write` |
| POST | `/elements/group` | 分组 | `element:write` |
| POST | `/elements/ungroup` | 取消分组 | `element:write` |

创建元素：

```http
POST /v1/pages/page_123/elements
Authorization: Bearer <token>
Content-Type: application/json
Idempotency-Key: 550e8400-e29b-41d4-a716-446655440001

{
  "elements": [
    {
      "type": "sticky",
      "text": "用户痛点",
      "position": { "x": 100, "y": 200 },
      "size": { "width": 200, "height": 150 },
      "style": { "color": "#FFE58F" }
    }
  ],
  "dryRun": false
}
```

### 5.4 Connectors

| 方法 | 路径 | 说明 | Scope |
|---|---|---|---|
| GET | `/pages/{pageId}/connectors` | 列出连线 | `connector:read` |
| POST | `/pages/{pageId}/connectors` | 创建连线 | `connector:write` |
| GET | `/connectors/{connectorId}` | 获取连线 | `connector:read` |
| PATCH | `/connectors/{connectorId}` | 更新连线 | `connector:write` |
| DELETE | `/connectors/{connectorId}` | 删除连线 | `connector:write` |

创建连线：

```json
{
  "fromElementId": "elem_1",
  "toElementId": "elem_2",
  "fromAnchor": "right",
  "toAnchor": "left",
  "style": "orthogonal",
  "arrowEnd": "solid",
  "label": "是"
}
```

### 5.5 Comments

| 方法 | 路径 | 说明 | Scope |
|---|---|---|---|
| GET | `/boards/{boardId}/comments` | 列出评论 | `comment:read` |
| POST | `/comments` | 创建评论 | `comment:write` |
| GET | `/comments/{commentId}` | 获取评论 | `comment:read` |
| PATCH | `/comments/{commentId}` | 更新评论 | `comment:write` |
| DELETE | `/comments/{commentId}` | 删除评论 | `comment:write` |
| POST | `/comments/{commentId}/reply` | 回复 | `comment:write` |
| POST | `/comments/{commentId}/resolve` | 标记解决 | `comment:write` |

### 5.6 Exports

| 方法 | 路径 | 说明 | Scope |
|---|---|---|---|
| POST | `/boards/{boardId}/export` | 导出白板 | `export:read` |
| POST | `/pages/{pageId}/export` | 导出页面 | `export:read` |
| GET | `/exports/{exportId}` | 获取导出状态 | `export:read` |
| GET | `/exports/{exportId}/download` | 下载导出文件 | `export:read` |

导出请求：

```json
{
  "format": "pdf",
  "pages": ["page_1", "page_2"],
  "includeAnnotations": true,
  "quality": "high"
}
```

### 5.7 History

| 方法 | 路径 | 说明 | Scope |
|---|---|---|---|
| GET | `/boards/{boardId}/history` | 获取历史 | `history:read` |
| POST | `/boards/{boardId}/undo` | 撤销 | `history:write` |
| POST | `/boards/{boardId}/redo` | 重做 | `history:write` |
| POST | `/boards/{boardId}/snapshot` | 创建快照 | `history:write` |

### 5.8 AI

| 方法 | 路径 | 说明 | Scope |
|---|---|---|---|
| POST | `/ai/sessions` | 创建会话 | `ai:invoke` |
| GET | `/ai/sessions/{sessionId}` | 获取会话 | `ai:invoke` |
| POST | `/ai/sessions/{sessionId}/messages` | 发送消息 | `ai:invoke` |
| POST | `/ai/sessions/{sessionId}/audio` | 发送语音 | `ai:invoke` |
| GET | `/ai/sessions/{sessionId}/messages` | 获取消息 | `ai:invoke` |
| POST | `/ai/toolCalls/{toolCallId}/execute` | 执行工具调用 | `ai:invoke` |
| POST | `/ai/toolCalls/{toolCallId}/preview` | 预览工具调用 | `ai:invoke` |
| POST | `/ai/toolCalls/{toolCallId}/cancel` | 取消工具调用 | `ai:invoke` |

### 5.9 Tools

| 方法 | 路径 | 说明 | Scope |
|---|---|---|---|
| GET | `/tools` | 列出所有工具 | `admin:read` |
| GET | `/tools/{toolId}` | 获取工具定义 | `admin:read` |
| POST | `/tools/{toolId}/execute` | 执行工具 | 取决于工具 Scope |
| POST | `/tools/{toolId}/preview` | 预览工具 | 取决于工具 Scope |

### 5.10 MCP

| 方法 | 路径 | 说明 | Scope |
|---|---|---|---|
| GET | `/mcp/tools` | 列出 MCP 工具 | `mcp:invoke` |
| POST | `/mcp/tools/{toolName}/call` | 调用 MCP 工具 | `mcp:invoke` |
| GET | `/mcp/server` | MCP Server 信息 | `mcp:invoke` |

---

## 6. WebSocket 实时事件

### 6.1 连接

```text
wss://api.whiteboard.example.com/v1/ws?token=<jwt>&boardId=<boardId>
```

### 6.2 事件格式

```json
{
  "type": "element.created",
  "boardId": "board_123",
  "pageId": "page_1",
  "userId": "user_1",
  "timestamp": "2026-09-25T10:00:00Z",
  "data": { }
}
```

### 6.3 事件类型

| 事件 | 说明 |
|---|---|
| `board.created` | 白板创建 |
| `board.updated` | 白板更新 |
| `board.deleted` | 白板删除 |
| `page.created` | 页面创建 |
| `page.updated` | 页面更新 |
| `page.deleted` | 页面删除 |
| `page.moved` | 页面移动 |
| `element.created` | 元素创建 |
| `element.updated` | 元素更新 |
| `element.deleted` | 元素删除 |
| `connector.created` | 连线创建 |
| `connector.updated` | 连线更新 |
| `connector.deleted` | 连线删除 |
| `comment.created` | 评论创建 |
| `comment.resolved` | 评论解决 |
| `cursor.moved` | 光标移动 |
| `selection.changed` | 选区变化 |
| `user.joined` | 用户加入 |
| `user.left` | 用户离开 |
| `ai.session.completed` | AI 会话完成 |
| `export.completed` | 导出完成 |

### 6.4 订阅

```json
{
  "type": "subscribe",
  "events": ["element.created", "element.updated", "comment.created"],
  "boardId": "board_123"
}
```

---

## 7. Webhooks

### 7.1 配置

```http
POST /v1/webhooks
Authorization: Bearer <token>
Content-Type: application/json

{
  "url": "https://example.com/webhook",
  "events": ["board.created", "element.created", "export.completed"],
  "secret": "whsec_abc",
  "active": true
}
```

### 7.2 事件格式

```json
{
  "id": "evt_123",
  "type": "element.created",
  "createdAt": "2026-09-25T10:00:00Z",
  "data": {
    "boardId": "board_123",
    "pageId": "page_1",
    "elementId": "elem_1"
  }
}
```

### 7.3 签名

```text
X-Webhook-Signature: sha256=<hmac>
```

### 7.4 重试

- 失败重试 3 次
- 间隔：1s、10s、60s
- 事件 ID 去重
- 支持过滤条件

---

## 8. OpenAPI 3.1 片段

```yaml
openapi: 3.1.0
info:
  title: Whiteboard Open API
  version: 1.0.0
  description: 白板平台开放 API

servers:
  - url: https://api.whiteboard.example.com/v1

security:
  - OAuth2: []
  - ApiKey: []

paths:
  /boards:
    get:
      summary: 列出白板
      security:
        - OAuth2: [board:read]
      parameters:
        - name: limit
          in: query
          schema: { type: integer, default: 20, maximum: 100 }
        - name: cursor
          in: query
          schema: { type: string }
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/BoardList'
    post:
      summary: 创建白板
      security:
        - OAuth2: [board:write]
      parameters:
        - name: Idempotency-Key
          in: header
          schema: { type: string }
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CreateBoardRequest'
      responses:
        '201':
          description: Created
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Board'

  /boards/{boardId}:
    get:
      summary: 获取白板
      security:
        - OAuth2: [board:read]
      parameters:
        - name: boardId
          in: path
          required: true
          schema: { type: string }
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Board'

components:
  securitySchemes:
    OAuth2:
      type: oauth2
      flows:
        authorizationCode:
          authorizationUrl: https://auth.whiteboard.example.com/oauth/authorize
          tokenUrl: https://auth.whiteboard.example.com/oauth/token
          scopes:
            board:read: 读取白板
            board:write: 修改白板
            element:read: 读取元素
            element:write: 修改元素
            ai:invoke: 调用 AI
    ApiKey:
      type: apiKey
      in: header
      name: X-API-Key
```

---

## 9. 与 MCP 的关系

| 项 | Open API | MCP |
|---|---|---|
| 面向 | 开发者、第三方系统 | AI 客户端 |
| 协议 | REST / WebSocket | MCP |
| 工具来源 | ToolRegistry | ToolRegistry |
| 认证 | OAuth / API Key | OAuth / API Key |
| 权限 | Scope | Scope |
| 审计 | 支持 | 支持 |
| 确认级别 | 支持 | 支持 |
| 幂等性 | 支持 | 支持 |
| 速率限制 | 支持 | 支持 |

MCP 工具列表与 Open API 工具列表一致，通过 `/mcp/tools` 获取。

---

## 10. 安全与合规

- 所有请求 HTTPS
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

## 11. 错误码完整列表

| 错误码 | HTTP | 说明 |
|---|---|---|
| `INVALID_ARGUMENT` | 400 | 参数错误 |
| `UNAUTHENTICATED` | 401 | 未认证 |
| `PERMISSION_DENIED` | 403 | 无权限 |
| `NOT_FOUND` | 404 | 资源不存在 |
| `CONFLICT` | 409 | 冲突 |
| `UNPROCESSABLE` | 422 | 无法处理 |
| `RATE_LIMITED` | 429 | 速率限制 |
| `INTERNAL_ERROR` | 500 | 内部错误 |
| `UNAVAILABLE` | 503 | 服务不可用 |
| `TIMEOUT` | 504 | 超时 |
| `CANCELLED` | 499 | 取消 |
| `RESOURCE_EXHAUSTED` | 429 | 资源耗尽 |
| `NOT_SUPPORTED` | 501 | 不支持 |

---

## 12. 里程碑

### M5.1：REST API v1
- 认证
- Boards
- Pages
- Elements
- Connectors

### M5.2：评论与导出
- Comments
- Exports
- History

### M5.3：AI API
- AI 会话
- 消息
- 工具调用

### M5.4：WebSocket
- 实时事件
- 订阅

### M5.5：Webhooks
- 配置
- 签名
- 重试

### M5.6：MCP
- MCP Server
- 工具映射
- 认证

### M5.7：SDK
- TypeScript
- Python
- Go

### M5.8：企业能力
- SSO
- 审计
- 私有化
- 租户隔离

---

## 13. 最终确认清单

| 项 | 确认结果 |
|---|---|
| REST API | 支持 |
| WebSocket | 支持 |
| Webhook | 支持 |
| OpenAPI 3.1 | 支持 |
| OAuth 2.0 | 支持 |
| API Key | 支持 |
| JWT | 支持 |
| Scope | 支持 |
| 幂等性 | 支持 |
| 分页 | 支持 |
| 排序 | 支持 |
| 过滤 | 支持 |
| 速率限制 | 支持 |
| 审计 | 支持 |
| MCP | 支持 |
| SDK | 计划中 |
| 企业 SSO | 支持 |
| 租户隔离 | 支持 |
| 私有化 | 支持 |

---

## 14. 附录：工具与 API 映射表

| 工具 ID | REST 路径 | 方法 | Scope |
|---|---|---|---|
| `board.create` | `/boards` | POST | `board:write` |
| `board.get` | `/boards/{boardId}` | GET | `board:read` |
| `board.update` | `/boards/{boardId}` | PATCH | `board:write` |
| `board.delete` | `/boards/{boardId}` | DELETE | `board:write` |
| `board.share` | `/boards/{boardId}/share` | POST | `board:share` |
| `page.create` | `/boards/{boardId}/pages` | POST | `page:write` |
| `page.duplicate` | `/pages/{pageId}/duplicate` | POST | `page:write` |
| `page.delete` | `/pages/{pageId}` | DELETE | `page:write` |
| `page.move` | `/pages/{pageId}/move` | POST | `page:write` |
| `page.split` | `/pages/{pageId}/split` | POST | `page:write` |
| `page.merge` | `/pages/merge` | POST | `page:write` |
| `element.create` | `/pages/{pageId}/elements` | POST | `element:write` |
| `element.update` | `/elements/{elementId}` | PATCH | `element:write` |
| `element.delete` | `/elements/{elementId}` | DELETE | `element:write` |
| `element.list` | `/pages/{pageId}/elements` | GET | `element:read` |
| `connector.create` | `/pages/{pageId}/connectors` | POST | `connector:write` |
| `connector.update` | `/connectors/{connectorId}` | PATCH | `connector:write` |
| `connector.delete` | `/connectors/{connectorId}` | DELETE | `connector:write` |
| `comment.create` | `/comments` | POST | `comment:write` |
| `comment.reply` | `/comments/{commentId}/reply` | POST | `comment:write` |
| `comment.resolve` | `/comments/{commentId}/resolve` | POST | `comment:write` |
| `export.create` | `/boards/{boardId}/export` | POST | `export:read` |
| `export.download` | `/exports/{exportId}/download` | GET | `export:read` |
| `history.undo` | `/boards/{boardId}/undo` | POST | `history:write` |
| `history.redo` | `/boards/{boardId}/redo` | POST | `history:write` |
| `history.snapshot` | `/boards/{boardId}/snapshot` | POST | `history:write` |
| `ai.session.create` | `/ai/sessions` | POST | `ai:invoke` |
| `ai.sendMessage` | `/ai/sessions/{sessionId}/messages` | POST | `ai:invoke` |
| `ai.sendAudio` | `/ai/sessions/{sessionId}/audio` | POST | `ai:invoke` |
| `ai.executeToolCall` | `/ai/toolCalls/{toolCallId}/execute` | POST | `ai:invoke` |
| `mcp.listTools` | `/mcp/tools` | GET | `mcp:invoke` |
| `mcp.callTool` | `/mcp/tools/{toolName}/call` | POST | `mcp:invoke` |

---

以上是《Open API 规范 v1.0》完整内容。