# 05 · core-collab —— C++ 协同与安全

> 模块路径：`core/include/wb/{crdt, sync, permission}`（当前为空占位）、`core/src/{crdt, sync, permission}`、`core/src/audit`（audit **仅 src，无 include 目录**）、`core/tests/unit/{crdt, sync, permission, audit}`
> 维护 agent：`wb-core-collab-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：CRDT 文档复制与合并（op-based、LWW 寄存器语义、幂等/交换/结合合并）；同步协议占位实现（连接状态、离线队列、预留 provider 接口注册表）；权限 ACL（级别体系 Read < Write < Share < Admin）；审计日志（追加、条件过滤、JSON-lines 导出）。
- **不负责**：元素/页面数据模型（→ [02-core-model](02-core-model.md)）；AI/MCP 侧审计调用方（→ [06-core-ai](06-core-ai.md)，其 `tools/call` 写审计）；真实网络传输/音视频/录制（后续 wave，《互动白板预留接口设计》M10.2+）；FFI 导出实现与域注册（→ [01-core-foundation](01-core-foundation.md)）。
- **地位**：协同与安全横切层；`audit` 域是工具层、`ai`/`mcp` 域的共同落点（约定 `invokeDomain("audit", "log", ...)` 在锁外调用，避免死锁）。

## 2. 功能 → 文件映射

| 功能 | 实现文件 | 测试 |
|---|---|---|
| crdt 域（`create`/`applyLocal`/`applyRemote`/`encodeState`/`decodeState`/`encodeUpdate`/`merge`/`list`；op `{actor,seq,key,value,timestamp,origin}`、LWW、tie-break 按 actor） | `core/src/crdt/crdt.cpp` | `core/tests/unit/crdt/crdt_test.cpp` |
| sync 域（`connect`/`disconnect`/`status`/`setOffline`/`sendOperation`/`sync`/`queue`/`capabilities`；离线队列由 `sync` 排空，传输为占位） | `core/src/sync/sync.cpp` | `core/tests/unit/sync/sync_test.cpp` |
| 预留协作提供者接口（AVProvider / InteractiveProvider / Transport / RecordingProvider / PlaybackProvider 虚接口与 `ReservedProviders()` 描述表，**只预留不实现**） | `core/src/sync/providers.h` | 经 `capabilities` op 被 `core/tests/unit/sync/sync_test.cpp` 间接覆盖 |
| permission 域（`check`/`grant`/`revoke`/`list`/`levels`；ACL 按 (boardId,userId) 存最高级别、grant 取最大、revoke 幂等） | `core/src/permission/permission.cpp` | `core/tests/unit/permission/permission_test.cpp` |
| audit 域（`log`/`query`/`export`/`clear`；`audit-N` 序号 + 毫秒时间戳、按 userId/toolId/fromAI/since/until/limit 过滤、JSONL 导出） | `core/src/audit/audit.cpp` | `core/tests/unit/audit/audit_test.cpp` |

## 3. 契约与依赖

- **对外契约（只读）**：`core/include/wb/wb.h` 的 Sync 段（`wb_sync_connect`/`wb_sync_disconnect`/`wb_sync_status`/`wb_sync_set_offline`）与 Permission/audit 段（`wb_permission_check`/`wb_audit_query`/`wb_audit_export`）；`wb_mcp_audit_query`/`wb_mcp_audit_export`（MCP 段）由 06 mcp 域转发到本模块 audit 域（`core/src/mcp/mcp.cpp:567-572`）。
- **被依赖**：06 `ai` 域与 `mcp` 域在工具执行后写审计（`fromAI` 标记，`core/src/mcp/mcp.cpp:220-226`）；01 工具注册表已注册 `crdt.*`/`sync.*`/`permission.*`/`audit.*` 工具；07 `packages/core_dart` 的 `wb_core_bindings.dart` 封装 `wb_sync_*`/`wb_permission_check`/`wb_audit_query`；`core/tests/integration/test_crdt_sync.cpp`、`test_permission_audit.cpp` 断言跨模块链路。
- **依赖**：01 契约基础层（`wb/ffi/domain.h`、`wb/platform/platform.h`）；third_party（nlohmann/json）。crdt/sync/audit/permission 均为进程内注册表模式（同 `SceneStore` 模式），**不依赖 02 数据模型**。
- **已知契约事实（回归依据）**：CRDT 合并为 (actor,seq) 集合去重 + LWW 重放，合并副本必须使用不同 actor 才能区分 op；permission 级别层级 Read < Write < Share < Admin，更高隐含满足更低，名称大小写不敏感、未知名称 `InvalidArgument`；audit 条目 id 形如 `audit-N`，`query` 按插入时序返回；`capabilities` 返回的 provider 全部 `implemented=false`。

## 4. 常用命令

```powershell
# 构建（改动本模块后必须全量构建）
cmake --preset windows-x64; cmake --build build/windows-x64 --config Release

# 全量单测
ctest --test-dir build/windows-x64 -C Release --output-on-failure

# 只跑本模块相关用例（按名称过滤）
ctest --test-dir build/windows-x64 -C Release -R "crdt|sync|permission|audit" --output-on-failure
```

## 5. 变更影响提醒（改本模块时注意）

- 修改 CRDT op 结构或合并语义 → `test_crdt_sync.cpp` 与 06 的 MCP crdt 工具行为联动；编码输出（`encodeState`/`encodeUpdate`）是跨端协议雏形，改动需版本化评估。
- 修改 sync 状态机/离线队列语义 → 07 封装与 11 桌面端协作入口联动；`providers.h` 接口签名须与《互动白板预留接口设计》M10.1 对齐（后续 M10.2+ 真实实现以此为对接点）。
- 修改 permission 级别体系或 `check` 语义 → 13 服务端 API 与 11 客户端权限 UI 可能失效；`grant`/`revoke` 语义变化需同步集成测试。
- 修改审计条目结构（字段名/`fromAI`/id 格式）→ 06 mcp `tools/call` 写入侧、`test_permission_audit.cpp`、以及导出 JSONL 的下游消费方联动。
- `core/src/audit` 无 include 目录、无公共头：审计的 FFI 面只有 `wb_audit_query`/`wb_audit_export`（+ MCP 转发），写入路径经工具/域调用；新增对外入口需走 01 决策。
