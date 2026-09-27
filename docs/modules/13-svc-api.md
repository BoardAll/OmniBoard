# 13 · svc-api —— 后端 API 服务

> 模块路径：`services/api`（`src/{app.ts, db, lib, middleware, routes, services, types}`、`tests`）
> 维护 agent：`wb-svc-api-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：Whiteboard Open API（《OpenAPI规范.md》）的 REST 实现——白板/页面/元素/连线/评论/导出/历史/AI 会话/MCP 桥接 9 组路由（共 63 个端点 + `/healthz`）；认证（Bearer JWT / `X-API-Key`）与 18 项 Scope 授权；限流（IP/用户/端点类别）；审计与脱敏（who/what/when/target/result + PII 掩码）；幂等（`Idempotency-Key`）；输入守卫；安全响应头；统一错误中间件；内存数据仓库（Wave 4 迁移真实 DB）。
- **不负责**：MCP 协议服务端（JSON-RPC 编排、stdio/SSE/HTTP 传输 → [14-svc-mcp](14-svc-mcp.md)）；模型/ASR/TTS 调用（→ [15-svc-ai-gateway](15-svc-ai-gateway.md)）；PDF 转换（→ [16-svc-convert](16-svc-convert.md)）。
- **地位**：Open API 的唯一 HTTP 入口；14-svc-mcp 的工具执行/资源读取经 `WB_API_BASE_URL` 桥接到本服务 `POST /v1/mcp/tools/{toolName}/call`（30 个工具的桥接目录）。

## 2. 功能 → 文件映射

### 2.1 应用装配与基础设施

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 应用装配与启动（中间件链、9 组路由挂载 `/v1`、404、统一错误处理、`WB_API_PORT`/`PORT`） | `src/app.ts` | `tests/foundation.test.ts` |
| 实体类型与请求校验 schema、Scope/角色常量（对齐 element/command schema） | `src/db/schema.ts` | 经各路由测试间接校验 |
| 内存数据仓库（`DataStore` 接口 + `createMemoryStore`） | `src/db/memory.ts` | 间接校验 |
| 数据库迁移占位（Wave 4 → PostgreSQL/Redis/对象存储） | `src/db/migrations/index.ts` | — |
| 错误模型（`ApiError`、错误码 → HTTP 状态映射、`confirmationRequired` 422） | `src/lib/errors.ts` | `tests/foundation.test.ts`、`tests/security-hardening.test.ts` |
| 路由公共工具（`handle` 异步捕获、`respond`/`respondList`、`requireConfirm`） | `src/lib/handlers.ts` | 经各路由测试间接校验 |
| 不透明 ID 生成（`board_*` / `req_*` 前缀 + base64url） | `src/lib/ids.ts` | 间接校验 |
| 分页/排序/过滤解析（cursor/limit/sort/filter） | `src/lib/query.ts` | `tests/boards.test.ts`、`tests/elements.test.ts` |
| 响应信封 `{ok, data, error, meta}` | `src/lib/response.ts` | `tests/foundation.test.ts` |
| 请求体 zod 校验（issues → `INVALID_ARGUMENT` 400） | `src/lib/validate.ts` | `tests/foundation.test.ts` |
| Express 请求扩展（`req.principal` / `req.requestId`） | `src/types/express.d.ts` | 间接校验 |

### 2.2 中间件

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 认证与授权（Bearer JWT HS256/RS256/ES256、`X-API-Key`、`requireScope`；凭据仅环境变量 `WB_JWT_SECRET`/`WB_JWT_PUBLIC_KEY`/`WB_API_KEYS`） | `src/middleware/auth.ts` | `tests/security.test.ts`、`tests/security-hardening.test.ts` |
| 审计（who/what/when/target/result + `summariseArgs` 敏感键脱敏 + `maskPii` 值级掩码） | `src/middleware/audit.ts` | `tests/security.test.ts`、`tests/security-hardening.test.ts` |
| 幂等（`Idempotency-Key` 同键同体重放 / 同键异体 409） | `src/middleware/idempotency.ts` | `tests/security.test.ts` |
| 输入守卫（Content-Type 415、查询串控制字符 400、超长 414） | `src/middleware/inputGuard.ts` | `tests/security-hardening.test.ts` |
| 限流（滑动窗口：IP 认证前 5000/min、用户 1000/min、AI/MCP 类别配额；429 + Retry-After） | `src/middleware/rateLimit.ts` | `tests/security.test.ts`、`tests/security-hardening.test.ts` |
| 请求 ID（`X-Request-Id` 生成与回写） | `src/middleware/requestId.ts` | `tests/foundation.test.ts` |
| 安全响应头（§22.1 九项）与 CORS 白名单（`WB_CORS_ORIGINS`） | `src/middleware/security.ts` | `tests/security-hardening.test.ts` |

### 2.3 业务服务层

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 访问控制（`hasScope`、Token 白板范围 `assertBoardInRange`） | `src/services/access.ts` | 经各服务测试间接校验 |
| 白板 CRUD / 分享 / 协作者 | `src/services/boardService.ts` | `tests/boards.test.ts` |
| 页面 CRUD / 复制 / 移动 / 拆分 / 合并 / 缩略图 | `src/services/pageService.ts` | `tests/elements.test.ts` |
| 元素 CRUD / 批量 / 对齐 / 分布 / 编组 / 移动 / 缩放 / 样式 | `src/services/elementService.ts` | `tests/elements.test.ts` |
| 连线 CRUD（两端元素同页校验） | `src/services/connectorService.ts` | —（无直接用例；工具目录断言见 `tests/mcp.test.ts`） |
| 评论 CRUD / 回复 / 解决（作者或白板所有者可删） | `src/services/commentService.ts` | —（无直接用例；工具目录断言见 `tests/mcp.test.ts`） |
| 导出任务（内存同步完成，download 返回内联内容；Wave 4 接 16-svc-convert） | `src/services/exportService.ts` | —（无直接用例；工具目录断言见 `tests/mcp.test.ts`） |
| 历史 / 撤销 / 重做 / 快照（内存命令栈 applied/undone 状态机） | `src/services/historyService.ts` | —（无直接用例；工具目录断言见 `tests/mcp.test.ts`） |
| AI 会话与工具调用状态机（可注入 `AIProvider`，默认 `StubAIProvider`） | `src/services/aiService.ts` | `tests/security-hardening.test.ts` |
| MCP 桥接（30 个工具目录、scope/确认级别校验、`getServerInfo`） | `src/services/mcpService.ts` | `tests/mcp.test.ts` |

### 2.4 路由（均挂载于 `/v1`）

| 功能 | 实现文件 | 测试 |
|---|---|---|
| Boards 路由（9 端点；DELETE 需 `?confirm=true`） | `src/routes/boards.ts` | `tests/boards.test.ts` |
| Pages 路由（10 端点；含 split/merge/thumbnail） | `src/routes/pages.ts` | `tests/elements.test.ts` |
| Elements 路由（13 端点；含 batch/align/distribute/group/ungroup） | `src/routes/elements.ts` | `tests/elements.test.ts` |
| Connectors 路由（5 端点） | `src/routes/connectors.ts` | — |
| Comments 路由（7 端点；含 reply/resolve） | `src/routes/comments.ts` | — |
| Exports 路由（4 端点；download 返回内联内容） | `src/routes/exports.ts` | — |
| History 路由（4 端点；undo/redo/snapshot） | `src/routes/history.ts` | — |
| AI 路由（8 端点；会话/消息/语音/工具调用 preview/execute/cancel） | `src/routes/ai.ts` | `tests/security-hardening.test.ts` |
| MCP 桥接路由（3 端点；工具列表/调用（含 422 确认）/Server 信息） | `src/routes/mcp.ts` | `tests/mcp.test.ts` |

### 2.5 测试布局

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 基础契约（`/healthz`、404、错误信封、请求体校验、CORS/版本响应头） | — | `tests/foundation.test.ts`（6） |
| Boards CRUD / 分页 / 过滤 / 确认 / 权限 | — | `tests/boards.test.ts`（8） |
| Pages & Elements 流程（含 dryRun 提案、静态路由顺序） | — | `tests/elements.test.ts`（6） |
| MCP 桥接（目录 30 工具、调用、确认、scope、`fromAI` 审计） | — | `tests/mcp.test.ts`（7） |
| 认证边界 / 限流 / 幂等 / 审计脱敏 | — | `tests/security.test.ts`（7） |
| 安全加固（安全头、CORS、输入守卫、IP/类别限流、PII 掩码、错误不泄漏） | — | `tests/security-hardening.test.ts`（17） |
| 测试辅助（临时 HTTP 服务器、JWT 签名、请求工具、`ALL_SCOPES`） | `tests/helpers.ts` | — |

## 3. 契约与依赖

- **对外契约（只读）**：《OpenAPI规范.md》§3-§5（认证/Scope/资源）与 §4/§8/§10/§11（信封/限流/审计/错误码）；`core/tools/schema/{command,element}.schema.json`（错误与元素形状）；《安全与合规设计》§3/§4/§8/§14/§22。
- **端口**：默认 `8080`（`WB_API_PORT` 或 `PORT` 覆盖）；健康检查 `GET /healthz`（免认证、不写审计）。
- **认证**：`Authorization: Bearer <JWT>`（HS256/RS256/ES256）或 `X-API-Key`；凭据仅经环境变量注入，生产缺失拒绝启动（开发缺失仅生成临时密钥 + 警告，绝不打印密钥）。
- **被依赖**：14-svc-mcp（`WB_API_BASE_URL` → `POST /v1/mcp/tools/{toolName}/call`）；09-dart-client（`packages/api_client`）；12-app-web（Web 端 API 客户端）。
- **依赖**：`express@4` / `zod` / `jsonwebtoken` / `cors`（`package.json` 已锁定）；Wave 4 计划 PostgreSQL + Redis + 对象存储（`src/db/migrations/` 占位）。
- **已知契约事实（回归依据）**：错误信封 `{ ok: false, data: null, error: { code, message, detail? }, meta }`；破坏性操作需 `?confirm=true`（缺失 → 422 `UNPROCESSABLE` / `detail.confirmationRequired`）；限流 429 带 `Retry-After` 与 `X-RateLimit-*`；幂等重放带 `Idempotency-Replay: true`；响应带 `X-API-Version: 1`。

## 4. 常用命令

```powershell
Set-Location services\api

# 依赖安装（npm 网络失败时追加 --registry=https://registry.npmmirror.com）
npm install

# 类型检查（tsc --noEmit）
npm run lint

# 测试（vitest run，51 用例，全部离线自起临时服务器）
npm test

# 构建与服务启动（产物 dist/；默认 8080）
npm run build; npm start
# 开发热更
npm run dev
```

## 5. 变更影响提醒（改本模块时注意）

- 修改响应信封/错误码 → 影响 **09-dart-client**（`api_client`）与 **14-svc-mcp**（桥接错误码映射 `API_CODE_TO_TOOL_ERROR`）。
- 修改 MCP 桥接工具目录（30 个）或确认级别 → 需与 **14-svc-mcp** `src/tools/registry.ts`（113 个工具目录，重叠工具保持一致）核对；共同上游为 **06-core-ai** ToolRegistry。
- 修改 Scope 清单（18 项）→ 与 **14-svc-mcp** `src/auth/types.ts`（逐项一致）、**15-svc-ai-gateway** 工具 `requiresPermission` 同步评估。
- 修改 `WB_API_KEYS` JSON 形状（`{userId, scopes, boards, tenantId, rateLimit}`）→ **14-svc-mcp** `loadApiKeysFromEnv` 保持同形状。
- 破坏性端点（DELETE / batch 含删除）语义变化 → 同步 `tests/security*` 与 MCP 确认流程（`confirm_operation`，对齐 §6.5）。
- 新增端点须先更新《OpenAPI规范.md》与本文档映射表；本模块是 Open API 对外契约的实现方，签名以规范文档为准。
