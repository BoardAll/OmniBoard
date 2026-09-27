# AI 助手与 MCP 设计

- 文档版本：v1.0
- 状态：详细设计稿
- 所属文档：《白板软件设计文档 v0.5》《C++ 核心引擎接口设计 v1.0》《可扩展工具栏设计 v1.0》
- 适用范围：Flutter UI + C++ 核心 + 云端 AI + MCP
- 定位：AI 助手是白板的一等公民，支持文字与语音；MCP 让外部 AI 客户端直接调用白板工具

---

## 1. 设计目标

1. **AI 与用户一致**：AI 调用与用户操作走同一套命令层，权限、确认、撤销、审计一致。
2. **文字 + 语音**：两种一级入口，语音支持流式 ASR、TTS、打断。
3. **上下文感知**：AI 知道当前选区、页面、Frame、白板范围。
4. **执行可控**：支持 Dry Run、幽灵预览、执行卡片、批量撤销。
5. **可扩展**：所有白板工具自动成为 AI 工具，无需单独适配。
6. **MCP 支持**：提供 MCP Server，外部 AI 客户端可调用白板工具。
7. **安全合规**：云端 AI 优先，支持数据脱敏、审计、企业关闭云 AI。
8. **默认收起**：AI 面板默认收起，不干扰画布。

---

## 2. 整体架构

```text
┌──────────────────────────────────────────────────────────────┐
│ 用户输入层                                                   │
│ 文字 / 语音 / 选中对象 / 命令面板 / 快捷键                   │
├──────────────────────────────────────────────────────────────┤
│ Flutter AI 面板                                              │
│ 对话流 / 执行卡片 / 上下文 / 输入框 / 麦克风                 │
├──────────────────────────────────────────────────────────────┤
│ AI Gateway（云端）                                           │
│ 意图理解 / 任务规划 / Tool Calling / ASR / TTS / 会话管理     │
├──────────────────────────────────────────────────────────────┤
│ C++ 核心 ToolRegistry                                        │
│ 工具定义 / 权限 / Dry Run / 事务 / 撤销 / 审计               │
├──────────────────────────────────────────────────────────────┤
│ 白板内核                                                     │
│ 元素 / 页面 / 3D / 函数 / 流程图 / 表格 / 思维导图            │
├──────────────────────────────────────────────────────────────┤
│ MCP Server                                                   │
│ 工具映射 / 认证 / 权限 / 审计 / 外部 AI 客户端接入            │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. 核心原则

### 3.1 统一命令层

- 所有白板能力注册为 Tool。
- AI、用户 UI、Open API、MCP 都调用同一套 Tool。
- Tool 定义包含：名称、描述、JSON Schema、权限 Scope、确认级别、幂等策略、撤销策略、审计字段。
- 禁止给 AI 单独开后门 API。

### 3.2 权限一致

- AI 操作与用户权限完全一致。
- AI 不能绕过 ACL。
- API Key / MCP Token 可限制白板范围、操作类型、速率。
- 支持租户隔离。

### 3.3 确认级别

| 级别 | 行为 | 示例 |
|---|---|---|
| Auto | 直接执行 | 创建便签、修改颜色、移动、对齐 |
| Preview | 显示幽灵预览，用户确认后执行 | 批量移动、自动布局 |
| Confirm | 弹窗确认 | 删除、分享、权限变更、批量删除 |

### 3.4 撤销与事务

- 每个 Tool 调用生成一个命令。
- 多个命令可合并为一个事务。
- AI 批量操作合并为一个事务，一次撤销。
- 事务记录到历史栈。
- 执行卡片提供“撤销”按钮。

### 3.5 审计

- 所有 AI 操作写审计日志。
- 审计字段：时间、用户、工具 ID、参数、结果、是否来自 AI、IP、User-Agent。
- 支持导出审计报告。
- 支持企业关闭云 AI。

---

## 4. AI 助手

### 4.1 入口

| 入口 | 方式 |
|---|---|
| 左侧栏 AI 图标 | 点击展开 AI 面板 |
| 圆盘“更多” | 点击 AI |
| 快捷键 | `Cmd/Ctrl + Shift + A` |
| 命令面板 | `Cmd/Ctrl + K` |
| 语音 | 按住 `Alt + Space` |
| 画布右键 | “问 AI” |

### 4.2 默认状态

- 默认收起。
- 有未读消息时显示小红点。
- 语音进行中显示波形。
- 展开后从左侧栏展开，或作为独立右侧面板。

### 4.3 AI 面板结构

```text
┌──────────────────────────────┐
│  🤖 AI 助手         ⚙️  ✕   │
├──────────────────────────────┤
│  上下文：选中 3 个便签       │
├──────────────────────────────┤
│  🧑 帮我把这些便签按主题分组 │
│                              │
│  🤖 好的，我计划：           │
│     1. 按主题分 3 组         │
│     2. 移动便签              │
│     3. 创建连线              │
│                              │
│  ┌────────────────────────┐  │
│  │  预览 │ 执行 │ 取消   │  │
│  └────────────────────────┘  │
│                              │
│  ┌────────────────────────┐  │
│  │ ✓ 已创建 2 条连线      │  │
│  │   ↶ 撤销               │  │
│  └────────────────────────┘  │
│                              │
├──────────────────────────────┤
│  ┌────────────────────────┐  │
│  │ 输入...                │  │
│  │ @引用  #Frame  /命令   │  │
│  │ 🎤   ➤                │  │
│  └────────────────────────┘  │
└──────────────────────────────┘
```

### 4.4 上下文控制

用户必须知道 AI 在操作什么：

- 当前选区
- 当前 Frame
- 当前页面
- 整个白板
- 手动选择范围
- 是否允许 AI 读取评论
- 是否允许 AI 读取图片 OCR

上下文显示在 AI 面板顶部，可点击修改。

### 4.5 文字接入

支持：

- 自然语言：“帮我把这些便签按优先级排序”
- 命令式：“创建 5 个黄色便签，主题是用户痛点”
- 上下文式：“总结我选中的内容”
- 追问式：“再按角色分组”
- 模板式：“用用户旅程模板创建一个 Frame”

输入框：

- `@` 引用元素
- `#` 引用 Frame
- `/` 快捷指令
- 显示当前上下文
- 支持多行、Shift+Enter 换行

### 4.6 语音接入

语音链路：

```text
麦克风 -> VAD -> 流式 ASR -> LLM -> Tool Calls -> 白板执行 -> TTS / 文字反馈
```

语音交互：

- 按住 `Alt + Space` 说话，松开执行
- 或点击麦克风，持续聆听
- 支持唤醒词（默认关闭）
- 实时显示转写文字
- 支持打断：用户说话时停止 TTS
- 支持多语言
- 高风险操作必须文字/视觉确认
- 嘈杂环境提示切换文字

语音状态视觉：

| 状态 | 颜色 | 表现 |
|---|---|---|
| 聆听 | 绿色 | 波形条 |
| 思考 | 橙色 | 呼吸点 |
| 执行 | 蓝色 | 进度条 |
| 完成 | 绿色 | 对勾 |
| 错误 | 红色 | 错误提示 |
| 等待确认 | 紫色 | 确认卡片 |

### 4.7 AI 操作反馈

- 相关对象高亮
- 移动/创建前显示幽灵预览
- AI 光标与人类光标区分
- 操作完成后短暂动画
- 侧栏显示执行卡片：调用了什么工具、影响多少对象、可撤销
- 支持“只执行这一步”“全部执行”“取消”

---

## 5. AI Gateway（云端）

### 5.1 职责

- 统一接入 OpenAI / Anthropic / 其他云端模型
- 统一 Tool Calling
- 管理 ASR / TTS
- 会话上下文
- 权限校验
- 审计
- 速率限制
- 敏感词与数据脱敏

### 5.2 模型路由

- 支持多模型
- 按任务类型路由：文本、代码、图像、语音
- 支持降级
- 支持企业指定模型

### 5.3 会话管理

```cpp
struct AISession {
  std::string id;
  std::string userId;
  std::string boardId;
  std::string pageId;
  std::vector<std::string> selection;
  std::string contextJson;
  Timestamp createdAt;
  Timestamp updatedAt;
  std::vector<AIMessage> messages;
};

struct AIMessage {
  std::string id;
  std::string role; // user / assistant / system / tool
  std::string content;
  std::string audioUrl;
  std::vector<ToolCall> toolCalls;
  Timestamp timestamp;
};

struct ToolCall {
  std::string id;
  std::string toolId;
  std::string argsJson;
  std::string resultJson;
  std::string status; // pending / success / error
  Timestamp timestamp;
};
```

### 5.4 安全与合规

- 数据不训练
- 敏感内容脱敏
- 支持企业关闭云 AI
- 支持本地模型
- 支持审计导出
- 支持租户隔离
- 支持 SSO / SCIM

---

## 6. MCP 设计

### 6.1 目标

提供 MCP Server，让外部 AI 客户端（如 Claude Desktop、Cursor、其他 MCP 客户端）直接调用白板工具。

### 6.2 MCP 架构

```text
┌──────────────────────────────────────────────┐
│ 外部 AI 客户端                               │
│ Claude / Cursor / 其他 MCP 客户端            │
├──────────────────────────────────────────────┤
│ MCP Server                                   │
│ 工具列表 / 工具调用 / 认证 / 权限 / 审计     │
├──────────────────────────────────────────────┤
│ C++ 核心 ToolRegistry                        │
│ 与内部 AI 共用同一套工具                     │
├──────────────────────────────────────────────┤
│ 白板内核                                     │
└──────────────────────────────────────────────┘
```

### 6.3 MCP 工具映射

- MCP 工具列表与 ToolRegistry 一致
- 工具名称、描述、JSON Schema 自动生成
- 权限 Scope 与 Open API 一致
- 确认级别与内部 AI 一致

### 6.4 MCP 认证

支持：

- OAuth 2.0
- API Key
- JWT
- 企业 SSO

Token 可限制：

- 白板范围
- 操作类型
- 速率
- 有效期

### 6.5 MCP 工具调用流程

```text
1. 外部 AI 客户端请求工具列表
2. MCP Server 从 ToolRegistry 生成列表
3. 客户端选择工具并调用
4. MCP Server 校验 Token 和权限
5. 调用 C++ 核心 Tool
6. 返回结果
7. 写入审计日志
```

### 6.6 MCP 工具示例

```json
{
  "name": "element.create",
  "description": "在白板上创建一个或多个元素，如便签、文本、形状、图片",
  "inputSchema": {
    "type": "object",
    "properties": {
      "boardId": { "type": "string" },
      "elements": {
        "type": "array",
        "items": { "$ref": "#/definitions/Element" }
      },
      "dryRun": { "type": "boolean", "default": false }
    },
    "required": ["boardId", "elements"]
  }
}
```

### 6.7 MCP 与 Open API 关系

| 项 | Open API | MCP |
|---|---|---|
| 面向 | 开发者、第三方系统 | AI 客户端 |
| 协议 | REST / WebSocket | MCP |
| 工具来源 | ToolRegistry | ToolRegistry |
| 权限 | Scope / OAuth | OAuth / API Key |
| 审计 | 支持 | 支持 |
| 确认级别 | 支持 | 支持 |

---

## 7. C++ 核心扩展

### 7.1 新增模块

```text
core/
  ai/
    ai_facade.h             AI 门面
    ai_facade.cpp
    ai_session.h            AI 会话
    ai_session.cpp
    ai_message.h            AI 消息
    ai_message.cpp
    ai_tool_call.h          AI 工具调用
    ai_tool_call.cpp
  mcp/
    mcp_server.h            MCP 服务
    mcp_server.cpp
    mcp_tool_registry.h     MCP 工具注册
    mcp_tool_registry.cpp
    mcp_auth.h              MCP 认证
    mcp_auth.cpp
```

### 7.2 AI Facade

```cpp
namespace wb {

class AIFacade {
public:
  std::string createSession(const std::string& boardId, const std::string& userId);
  void closeSession(const std::string& sessionId);

  std::string sendMessage(const std::string& sessionId, const std::string& message);
  std::string sendAudio(const std::string& sessionId, const std::string& audioData);

  std::string getSession(const std::string& sessionId);
  std::vector<AIMessage> listMessages(const std::string& sessionId);

  std::string executeToolCall(const std::string& sessionId, const std::string& toolCallId);
  std::string previewToolCall(const std::string& sessionId, const std::string& toolCallId);
  void cancelToolCall(const std::string& sessionId, const std::string& toolCallId);

  void setContext(const std::string& sessionId, const std::string& contextJson);

private:
  std::unordered_map<std::string, AISession> sessions_;
  std::mutex mutex_;
};

}
```

### 7.3 MCP Server

```cpp
namespace wb {

class MCPServer {
public:
  void start(int port);
  void stop();

  std::string listTools();
  std::string callTool(const std::string& toolName, const std::string& argsJson, const std::string& token);

  void setAuthProvider(std::shared_ptr<MCPAuth> auth);

private:
  std::unique_ptr<MCPToolRegistry> toolRegistry_;
  std::shared_ptr<MCPAuth> auth_;
  std::atomic<bool> running_{false};
};

}
```

### 7.4 MCP 认证

```cpp
namespace wb {

class MCPAuth {
public:
  virtual ~MCPAuth() = default;
  virtual bool validateToken(const std::string& token) = 0;
  virtual std::string getUserId(const std::string& token) = 0;
  virtual std::vector<std::string> getScopes(const std::string& token) = 0;
  virtual std::vector<std::string> getAllowedBoards(const std::string& token) = 0;
};

}
```

### 7.5 FFI 接口

```cpp
extern "C" {
  // AI 会话
  const char* wb_ai_session_create(const char* boardId, const char* userId);
  const char* wb_ai_session_close(const char* sessionId);
  const char* wb_ai_session_get(const char* sessionId);
  const char* wb_ai_send_message(const char* sessionId, const char* message);
  const char* wb_ai_send_audio(const char* sessionId, const char* audioData);
  const char* wb_ai_list_messages(const char* sessionId);
  const char* wb_ai_execute_tool_call(const char* sessionId, const char* toolCallId);
  const char* wb_ai_preview_tool_call(const char* sessionId, const char* toolCallId);
  const char* wb_ai_cancel_tool_call(const char* sessionId, const char* toolCallId);
  const char* wb_ai_set_context(const char* sessionId, const char* contextJson);

  // MCP
  const char* wb_mcp_start(int port);
  const char* wb_mcp_stop();
  const char* wb_mcp_list_tools();
  const char* wb_mcp_call_tool(const char* toolName, const char* argsJson, const char* token);
}
```

### 7.6 Tool Registry 扩展

```text
ai.session.create
ai.session.close
ai.session.get
ai.sendMessage
ai.sendAudio
ai.listMessages
ai.executeToolCall
ai.previewToolCall
ai.cancelToolCall
ai.setContext

mcp.start
mcp.stop
mcp.listTools
mcp.callTool
```

---

## 8. 交互设计

### 8.1 命令面板

```text
┌──────────────────────────────────────────────┐
│  🔍 输入命令或自然语言...                    │
├──────────────────────────────────────────────┤
│  /创建便签                                   │
│  /画流程图                                   │
│  /生成 3D 长方体                             │
│  /总结选中的内容                             │
│  /切换到画笔工具                             │
├──────────────────────────────────────────────┤
│  最近使用                                    │
│  创建 5 个便签                               │
│  按主题分组                                  │
└──────────────────────────────────────────────┘
```

快捷键：`Cmd/Ctrl + K`

### 8.2 执行卡片

```text
┌──────────────────────────────────────────────┐
│  🤖 执行计划                                 │
│  1. 按主题分 3 组                            │
│  2. 移动便签                                 │
│  3. 创建连线                                 │
├──────────────────────────────────────────────┤
│  预览 │ 执行 │ 取消                          │
└──────────────────────────────────────────────┘
```

执行完成后：

```text
┌──────────────────────────────────────────────┐
│  ✓ 已创建 2 条连线                           │
│  影响 5 个元素                               │
│  ↶ 撤销                                      │
└──────────────────────────────────────────────┘
```

### 8.3 幽灵预览

- AI 计划的操作在画布上显示半透明预览
- 用户可确认或取消
- 预览不改变实际数据

### 8.4 高亮

- AI 操作时相关对象高亮
- AI 光标与人类光标区分
- 操作完成后短暂动画

---

## 9. 安全与合规

- AI 操作与用户权限完全一致
- Open API 必须 Scope 校验
- API Key 可绑定白板、IP、速率
- 所有 AI 操作写审计日志
- 支持企业关闭云 AI
- 支持本地模型
- 支持数据不训练
- 支持敏感内容脱敏
- 支持导出审计报告
- 支持租户隔离
- 支持 SSO / SCIM

---

## 10. 里程碑

### M3.1：AI 文字助手
- AI 面板
- 命令面板
- Tool Calling
- Dry Run
- 执行卡片
- 撤销事务

### M3.2：语音助手
- 流式 ASR
- TTS
- 语音状态视觉
- 打断机制
- 高风险确认

### M3.3：MCP 支持
- MCP Server
- 工具映射
- 认证
- 权限
- 审计

### M3.4：企业能力
- SSO
- 审计
- 私有化
- 本地模型
- 数据合规

---

## 11. 最终确认清单

| 项 | 确认结果 |
|---|---|
| AI 助手 | 支持 |
| 文字接入 | 支持 |
| 语音接入 | 支持 |
| 默认状态 | 收起 |
| 上下文 | 显示，可修改 |
| 执行确认 | Auto / Preview / Confirm |
| 撤销 | 支持 |
| 审计 | 支持 |
| 云端 AI | 优先 |
| 本地模型 | 可选 |
| MCP | 支持 |
| Open API | 支持 |
| 权限一致 | 支持 |
| 数据脱敏 | 支持 |
| 多租户 | 支持 |

---

## 12. 附录：AI 工具分类

| 分类 | 工具示例 |
|---|---|
| 白板 | board.create、board.get、board.update、board.share |
| 元素 | element.create、element.update、element.delete、element.list |
| 选择 | selection.get、selection.set、selection.clear |
| 视口 | viewport.get、viewport.set、viewport.zoomToFit |
| 连线 | connector.create、connector.update、connector.delete |
| Frame | frame.create、frame.update、frame.focus |
| 评论 | comment.create、comment.reply、comment.resolve |
| 导出 | export.create、export.download |
| 历史 | history.undo、history.redo、history.snapshot |
| 模板 | template.list、template.apply |
| 协作 | presence.get、follow.user、present.start |
| 互动 | vote.start、timer.start、poll.create |
| 页面 | page.create、page.duplicate、page.delete、page.move |
| 图层 | layer.list、layer.select、layer.toggleVisible |
| 思维导图 | mindmap.create、mindmap.addNode、mindmap.setLayout |
| 表格 | table.create、table.setCell、table.setFormula |
| 流程图 | flowchart.create、flowchart.autoLayout、flowchart.toSwimlane |
| 函数 | render.function.create、render.function.setStyle、render.function.analyze |
| 3D | render.3d.create、render.3d.setFaceColor、render.3d.transform |
| 2D | render.2d.create、render.2d.annotate |
| 文档 | document.embed、document.gotoPage |
| 批注 | annotate.enterTransparent、annotate.exitTransparent、annotate.saveToBoard |
| AI | ai.summarize、ai.cluster、ai.plan、ai.generate |

---

以上是《AI 助手与 MCP 设计 v1.0》完整内容。