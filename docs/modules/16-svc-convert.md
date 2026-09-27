# 16 · svc-convert —— 文档转换服务

> 模块路径：`services/convert`（`src/{app.py, pdf_converter.py, __init__.py}`、`tests`、`requirements.txt`、`Dockerfile`）
> 维护 agent：`wb-svc-convert-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：PDF 转换（《Flutter + C++ 工程结构设计》§7）——元信息 / 文本提取 / 单页渲染 PNG / 同步转换任务（`text` / `png` / `info`）；PyMuPDF **函数级惰性导入**（`engine_installed` 仅探测、`_load_fitz` 函数级导入；未装 → 501 NotSupported）；上传校验（64MB 上限 → 413、空载荷 / 损坏 / 越界 → 400、无产物 → 409）；删除幂等；容器镜像（Dockerfile，共 9 个端点）。
- **不负责**：导出编排与业务数据（→ [13-svc-api](13-svc-api.md) `exportService`，Wave 4 接入本服务）；AI 模型 / ASR / TTS（→ [15-svc-ai-gateway](15-svc-ai-gateway.md)）；MCP 协议（→ [14-svc-mcp](14-svc-mcp.md)）；音视频 / 互动白板（`services/sfu` 当前为**空目录，预留**，无实现文件，与本服务无依赖关系）。
- **地位**：独立文档转换微服务（默认端口 8001）；13-svc-api 导出任务（Wave 4）的对接上游。

## 2. 功能 → 文件映射

### 2.1 应用与转换核心

| 功能 | 实现文件 | 测试 |
|---|---|---|
| FastAPI 应用装配与 9 端点（`/health`、`/v1/pdf/{info,text,render.png}`、`/v1/convert/jobs` CRUD + result；上传 413 / 输入 400 / 冲突 409） | `src/app.py` | `tests/test_health.py`、`tests/test_pdf_routes.py`、`tests/test_jobs.py` |
| PyMuPDF 转换逻辑（函数级惰性导入；`get_info` / `extract_text` / `pdf_to_text` / `render_page_png` / `pdf_to_png_zip`；DPI 默认 144、上限 600；`PdfEngineUnavailable` / `PdfConversionError`） | `src/pdf_converter.py` | `tests/test_pdf_converter.py`、`tests/test_degradation.py` |
| 包元数据（`SERVICE_NAME` / version）与包结构声明 | `src/__init__.py` | — |

### 2.2 交付与测试

| 功能 | 实现文件 | 测试 |
|---|---|---|
| 容器镜像（python:3.13-slim、非 root uid 10001、EXPOSE 8001、HEALTHCHECK、`python -m src.app` 启动） | `Dockerfile` | — |
| 依赖锁定（fastapi / uvicorn / pydantic / python-multipart + pymupdf；pikepdf / Pillow 暂未被源码引用） | `requirements.txt` | — |
| 测试辅助（TestClient、假 PyMuPDF 引擎、`requires_engine` 跳过标记） | `tests/conftest.py` | — |
| 用例分布（共 39） | — | health 2 / pdf_routes 10 / jobs 8 / pdf_converter 10 / degradation 6 / real_pdf_smoke 3 |

## 3. 契约与依赖

- **对外契约（只读）**：《Flutter + C++ 工程结构设计》§7（包结构）；`core/tools/schema/command.schema.json`（error.code 子集：InvalidArgument / NotFound / Conflict / InternalError / NotSupported / ResourceExhausted）；《构建打包与发布设计》（未对 convert 规定端口——本服务自选 8001）。
- **端口**：默认 `0.0.0.0:8001`（`WB_CONVERT_HOST` / `WB_CONVERT_PORT` / `PORT` 覆盖；Dockerfile 内同为 8001）。
- **认证**：无（内网服务，由调用方 / 网关侧控制）。
- **被依赖**：13-svc-api `exportService`（Wave 4 接入评估对象）；`Dockerfile` 用于部署编排。
- **依赖**：`requirements.txt` 已锁定；PyMuPDF 为惰性导入——无引擎环境下核心端点以降级 501 运行（`tests/test_degradation.py` 覆盖）。
- **已知契约事实（回归依据）**：`DEFAULT_RENDER_DPI=144` / `MAX_RENDER_DPI=600`；任务操作 `operations=("text","png","info")`；错误语义 501 / 400 / 413 / 409；DELETE 幂等（重复删除返回 `alreadyDeleted`）；PNG 返回 `image/png`（验收按 PNG magic）；`/health` 不触发 PyMuPDF 导入。

## 4. 常用命令

```powershell
Set-Location services\convert

# 虚拟环境与依赖安装（pip 失败时追加 -i https://pypi.tuna.tsinghua.edu.cn/simple）
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt

# 测试（pytest，39 用例，全部离线；真实 PDF 冒烟在引擎未装时自动跳过）
.venv\Scripts\python -m pytest -q

# 运行（默认 0.0.0.0:8001）
.venv\Scripts\python -m src.app

# 容器镜像
docker build -t whiteboard-convert:0.1.0 .
docker run --rm -p 8001:8001 whiteboard-convert:0.1.0
```

## 5. 变更影响提醒（改本模块时注意）

- 错误码 / 降级语义（501 / 400 / 413 / 409）变化 → **13-svc-api** `exportService`（Wave 4 对接）与前端下载流程评估。
- 端点形状（`/v1/pdf/*`、`/v1/convert/jobs/*`）变化 → 与 **13-svc-api** 导出任务对接、《Flutter + C++ 工程结构设计》§7 同步。
- DPI 常量与上传上限（64MB）变化 → **13-svc-api** `exportService` 与 **12-app-web** 评估。
- Dockerfile / 端口 8001（自选值）变化 → 部署文档与编排脚本同步（对齐《构建打包与发布设计》）。
- 引入 `services/sfu`（音视频 / 互动白板）实现时 → 需在模块文档体系补编号模块，并评估与本服务的边界。
