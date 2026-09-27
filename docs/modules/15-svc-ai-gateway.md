# 15 · svc-ai-gateway —— AI 网关服务

> 模块路径：`services/ai_gateway`（`src/{app.py, errors.py, __init__.py}`、`src/{providers, tools, asr, tts, session}`、`tests`、`requirements.txt`）
> 维护 agent：`wb-svc-ai-gateway-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：多 AI Provider 网关（《AI 助手与 MCP 设计》§5.1）——OpenAI / Anthropic / Custom（OpenAI 兼容端点）统一接口（chat / stream_chat / embedding / availability）；统一 Tool Calling（tool.schema.json 形状、auto/confirm/forbidden 确认级别、脱敏审计）；ASR / TTS（**函数级惰性导入**：未安装 → 501 NotSupported、已装未配置 → 503 Unavailable）；会话上下文（内存实现）；统一响应信封与错误码（19 个端点）。
- **不负责**：白板业务 REST 与数据仓库（→ [13-svc-api](13-svc-api.md)）；MCP 协议服务端（→ [14-svc-mcp](14-svc-mcp.md)）；PDF 转换（→ [16-svc-convert](16-svc-convert.md)）；C++ 侧 AI 编排与 ToolRegistry 本体（→ [06-core-ai](06-core-ai.md)）。
- **地位**：13-svc-api `/v1/ai/*`（8 端点）与 14-svc-mcp 的模型/工具能力上游；工具定义形状的共同上游为 `core/tools/schema/tool.schema.json`。

## 2. 功能 → 文件映射

### 2.1 应用与错误模型

| 功能 | 实现文件 | 测试 |
|---|---|---|
| FastAPI 应用装配（19 端点、请求模型、统一错误信封、SSE 流式、`WB_AI_HOST`/`WB_AI_PORT`/`PORT`） | `src/app.py` | `tests/test_health.py`、`tests/test_chat.py` |
| 统一错误模型（command.schema.json 枚举 + `Unavailable`/`RateLimited` 扩展；`ProviderNotInstalled` 501 / `ProviderNotConfigured` 503 / `UpstreamError` 502） | `src/errors.py` | `tests/test_errors.py` |
| 包元数据、服务名与「第三方 SDK 必须惰性导入」约束声明 | `src/__init__.py` | — |

### 2.2 Provider 层

| 功能 | 实现文件 | 测试 |
|---|---|---|
| Provider 统一接口与数据模型（chat / stream_chat / embedding / availability；`sdk_installed` 仅探测不导入） | `src/providers/__init__.py` | `tests/test_providers.py` |
| OpenAI Provider（函数级惰性导入 `openai`；默认 `gpt-4o-mini` / `text-embedding-3-small`） | `src/providers/openai.py` | `tests/test_providers.py`、`tests/test_chat.py` |
| Anthropic Provider（惰性导入 `anthropic`；默认 `claude-3-5-sonnet-latest`；无 embedding 能力 → 501） | `src/providers/anthropic.py` | `tests/test_providers.py` |
| Custom Provider（OpenAI 兼容端点 Ollama / vLLM / 自托管；httpx + 可注入 `client_factory`；`WB_CUSTOM_LLM_BASE_URL`） | `src/providers/custom.py` | `tests/test_providers.py` |

### 2.3 工具层

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 工具注册表（tool.schema.json 形状：点命名 / category / confirmation / requiresPermission；`handler` 为运行时字段不参与序列化） | `src/tools/registry.py` | `tests/test_tools.py` |
| 工具执行器与脱敏审计（本地 handler / 转发板端 API `WB_BOARD_API_URL`；confirm 与 dryRun；审计仅时间/用户/动作/目标/结果/来源） | `src/tools/executor.py` | `tests/test_tools.py` |

### 2.4 ASR / TTS / 会话

| 功能 | 实现文件 | 测试 |
|---|---|---|
| ASR 统一接口（`ASREngine` Protocol，测试可注入 Fake） | `src/asr/__init__.py` | `tests/test_asr_tts.py` |
| Whisper ASR（惰性导入 `openai-whisper`；未装 → 501） | `src/asr/whisper.py` | `tests/test_asr_tts.py` |
| TTS 统一接口（`TTSEngine` Protocol） | `src/tts/__init__.py` | `tests/test_asr_tts.py` |
| Azure TTS（惰性导入 azure SDK；未装 → 501、未配置 → 503） | `src/tts/azure.py` | `tests/test_asr_tts.py` |
| 会话管理（内存；AISession / AIMessage / ToolCall；深拷贝 + 锁；`UNSET` 哨兵区分未提供与显式 null） | `src/session/manager.py` | `tests/test_sessions.py` |

### 2.5 测试布局

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 用例分布（共 76） | — | health 4 / providers 19 / chat 8 / tools 15 / sessions 13 / asr_tts 12 / errors 5 |
| 测试辅助（TestClient、环境变量清空 `CLEAN_ENV`、Fake Provider/ASR/TTS、`httpx.MockTransport`） | `tests/conftest.py` | — |

## 3. 契约与依赖

- **对外契约（只读）**：《AI 助手与 MCP 设计》§5.1/§5.3（网关与会话）；`core/tools/schema/tool.schema.json`（工具形状）；`core/tools/schema/command.schema.json`（error.code 枚举）；《OpenAPI规范》§4.4/§4.10（信封 / 503 UNAVAILABLE）。
- **端口**：默认 `0.0.0.0:8000`（`WB_AI_HOST` / `WB_AI_PORT` / `PORT` 覆盖）。
- **认证**：服务自身不校验用户 token（内网信任域，调用方控制）；凭据（`OPENAI_API_KEY` / `ANTHROPIC_API_KEY` / `WB_CUSTOM_LLM_*` / `AZURE_SPEECH_*`）仅经环境变量读取，绝不打印/记录；测试前清空环境变量以保证降级路径确定性。
- **被依赖**：13-svc-api（`/v1/ai/*` 8 端点，含 audio 接入点）；14-svc-mcp（模型/工具执行的桥接评估对象）。
- **依赖**：`requirements.txt` 锁定（fastapi / uvicorn / httpx / pydantic / python-multipart / websockets + openai / anthropic；openai-whisper / azure-cognitiveservices-speech 为重依赖，**惰性导入**，未装不影响其余功能与测试）。
- **已知契约事实（回归依据）**：SSE 格式 `data: {"type":"chunk","delta",...}` → `data: {"type":"done","finishReason"}` → `data: [DONE]`，出错 `data: {"type":"error","error":{code,message}}`；SDK 未安装 → 501 `NotSupported`（`details.sdk`）、已装未配置 → 503 `Unavailable`（`details.missing`）；响应信封 `{ok, data, error[, details]}`。

## 4. 常用命令

```powershell
Set-Location services\ai_gateway

# 虚拟环境与依赖安装（pip 失败时追加 -i https://pypi.tuna.tsinghua.edu.cn/simple）
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt

# 测试（pytest，76 用例，全部离线）
.venv\Scripts\python -m pytest -q

# 运行（默认 0.0.0.0:8000）
.venv\Scripts\python -m src.app
```

## 5. 变更影响提醒（改本模块时注意）

- 错误码 / 降级语义（501/503）变化 → 评估 **13-svc-api** `src/services/aiService.ts` 与 **09-dart-client** AI 客户端的错误映射。
- 工具定义形状（tool.schema.json 字段）变化 → 与 **14-svc-mcp** 工具注册表（113 个）及 **06-core-ai** ToolRegistry 同步评估。
- SSE 事件格式变化 → **09-dart-client** 流式对话解析与《AI 助手与 MCP 设计》§5.1 同步。
- 会话结构（AISession / AIMessage / ToolCall 字段）变化 → **13-svc-api** ai 路由与《AI 助手与 MCP 设计》§5.3 对齐评估。
- 端口与 `WB_AI_*` 环境变量变化 → **13-svc-api** 接入配置与部署脚本同步。
- 新增 Provider 或调整惰性导入规则（未装必须可降级为 501）→ 更新 `requirements.txt` 与本文档映射表。
