# 模块文档索引 —— 功能 → 文件 映射体系

> 本目录每份文档对应**一个功能模块**，独立维护、互不影响。
> 每模块配一个专家 agent（`.qoder/agents/wb-*-agent.md`）：后续开发**哪块的问题就用哪个 agent**。
> 模块文档是"功能 → 文件"映射的**权威来源**，agent 与开发者都先查文档再定位代码。

## 模块总表（18 个）

| # | 模块文档 | 模块名 | 目录范围（权威边界） | 专家 agent |
|---|---|---|---|---|
| 01 | [01-core-foundation.md](01-core-foundation.md) | C++ 契约基础层 | `core/include/wb/{wb.h,base,ffi,serialization,platform}`、`core/src/{base,ffi,serialization,platform,command,tool,facade}`、`core/tools/schema` | wb-core-foundation-agent |
| 02 | [02-core-model.md](02-core-model.md) | C++ 数据模型层 | `core/{include/wb,src}/{model,element,page,geometry,layout}` | wb-core-model-agent |
| 03 | [03-core-render.md](03-core-render.md) | C++ 渲染与界面元数据 | `core/{include/wb,src}/{render,render2d,render3d,theme,background,radial,toolbar,sidebar}` | wb-core-render-agent |
| 04 | [04-core-domain.md](04-core-domain.md) | C++ 领域模块 | `core/{include/wb,src}/{flowchart,mindmap,table,function,document,annotation}` | wb-core-domain-agent |
| 05 | [05-core-collab.md](05-core-collab.md) | C++ 协同与安全 | `core/{include/wb,src}/{crdt,sync,permission}`、`core/src/audit` | wb-core-collab-agent |
| 06 | [06-core-ai.md](06-core-ai.md) | C++ AI 与 MCP | `core/{include/wb,src}/{ai,mcp}` | wb-core-ai-agent |
| 07 | [07-dart-core.md](07-dart-core.md) | Dart FFI 封装包 | `packages/core_dart` | wb-dart-core-agent |
| 08 | [08-dart-ui.md](08-dart-ui.md) | Dart UI 基础库 | `packages/{ui_kit,icons,theme,ui,fonts}` | wb-dart-ui-agent |
| 09 | [09-dart-client.md](09-dart-client.md) | Dart 服务客户端包 | `packages/{ai_dart,api_client,mcp_client}` | wb-dart-client-agent |
| 10 | [10-dart-platform.md](10-dart-platform.md) | 平台插件包 | `platform/{windows,macos,linux,web}`（android/ios 预留） | wb-dart-platform-agent |
| 11 | [11-app-desktop.md](11-app-desktop.md) | 桌面应用 | `apps/desktop` | wb-app-desktop-agent |
| 12 | [12-app-web.md](12-app-web.md) | Web 应用 | `apps/web`（`apps/mobile` 预留） | wb-app-web-agent |
| 13 | [13-svc-api.md](13-svc-api.md) | 后端 API 服务 | `services/api` | wb-svc-api-agent |
| 14 | [14-svc-mcp.md](14-svc-mcp.md) | MCP Server 服务 | `services/mcp_server` | wb-svc-mcp-agent |
| 15 | [15-svc-ai-gateway.md](15-svc-ai-gateway.md) | AI 网关服务 | `services/ai_gateway` | wb-svc-ai-gateway-agent |
| 16 | [16-svc-convert.md](16-svc-convert.md) | 文档转换服务 | `services/convert`（`services/sfu` 预留） | wb-svc-convert-agent |
| 17 | [17-build-release.md](17-build-release.md) | 构建打包与发布 | `tools/{scripts,packaging}`、`.github/workflows`、`CMakePresets.json`、`VERSION`、根 `CMakeLists.txt` | wb-build-release-agent |
| 18 | [18-qa-testing.md](18-qa-testing.md) | 测试与质量体系 | `core/tests`、`core/benchmarks`、`tests/{e2e,fixture,perf}`、各包测试规范 | wb-qa-testing-agent |

> 全局验证/集成门（跨模块全链路验证）由 **wb-verify-agent** 负责，不属于任何单一模块。

## 模块依赖方向（速查）

```
01 契约基础层（最底层：所有模块依赖它）
 └─ 02 数据模型  ─┬─ 03 渲染与界面元数据
                  ├─ 04 领域模块（流程/导图/表格/函数/文档/批注）
                  ├─ 05 协同与安全（crdt/sync/permission/audit）
                  └─ 06 AI 与 MCP
（以上 C++ 层）→ 07 Dart FFI 封装 → 08/09 UI 库与服务客户端 → 10 平台插件 → 11/12 应用
（服务端独立）13/14/15/16；17/18 为全仓工程化支撑
```

## 维护规则（重要）

1. **独立性**：每份模块文档只描述自己范围；涉及其他模块只写"依赖/影响"并链接对方文档，不复制对方内容。
2. **同步更新**：模块内文件新增/删除/移动时，同步更新本模块文档的映射表；其他模块文档不动。
3. **新增模块**：新开编号文档 + 新 agent + 更新本索引三件套，不改动既有文档。
4. **agent 对照**：agent 名与模块一一对应（`wb-<domain>-<module>-agent`）；agent 正文的"模块文档"字段必须指向本目录对应文件。
5. **权威性**：代码路径与本文档不一致时，以代码为准并**立即修正文档**。

## 全局常用命令

```powershell
# C++ 构建与测试
cmake --preset windows-x64; cmake --build build/windows-x64 --config Release
ctest --test-dir build/windows-x64 -C Release --output-on-failure

# Flutter 全仓
E:\code\flutter-sdk\flutter\bin\flutter.bat analyze
E:\code\flutter-sdk\flutter\bin\flutter.bat test

# 一键构建编排（构建/打包/版本/校验/签名）
powershell -File tools\scripts\build_all.ps1
```
