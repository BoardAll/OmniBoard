# 05 · core-collab —— C++ 协同与安全

> 模块路径：`core/include/wb/{crdt, sync, permission}`（当前为空占位）、`core/src/{crdt, sync, permission}`、`core/src/audit`（audit **仅 src，无 include 目录**）、`core/tests/unit/{crdt, sync, permission, audit}`
> 维护 agent：`wb-core-collab-agent`
> 维护规则：本文件只描述本模块；文件结构变化时同步更新本文档，**不影响其他模块文档**。

## 1. 模块职责与边界

- **负责**：CRDT 文档复制与合并（op-based、LWW 寄存器语义、幂等/交换/结合合并）；同步协议实现（M1 起 Socket.IO 真实传输：连接状态机、离线队列、出站攒批/重试；M2 起锁通道与断线重连恢复；预留 provider 接口注册表）；权限 ACL（级别体系 Read < Write < Share < Admin）；审计日志（追加、条件过滤、JSON-lines 导出）。
- **不负责**：元素/页面数据模型（→ [02-core-model](02-core-model.md)）；AI/MCP 侧审计调用方（→ [06-core-ai](06-core-ai.md)，其 `tools/call` 写审计）；音视频/录制与 WebRTC/QUIC 等其余传输（后续 wave，《互动白板预留接口设计》M10.2+）；FFI 导出实现与域注册（→ [01-core-foundation](01-core-foundation.md)）。
- **地位**：协同与安全横切层；`audit` 域是工具层、`ai`/`mcp` 域的共同落点（约定 `invokeDomain("audit", "log", ...)` 在锁外调用，避免死锁）。

## 2. 功能 → 文件映射

| 功能 | 实现文件 | 测试 |
|---|---|---|
| crdt 域（`create`/`applyLocal`/`applyRemote`/`encodeState`/`decodeState`/`encodeUpdate`/`merge`/`list`；op `{actor,seq,key,value,timestamp,origin}`、LWW、tie-break 按 actor；M1 起 `applyLocal` 响应附完整 `op` 供 sync 转发） | `core/src/crdt/crdt.cpp` | `core/tests/unit/crdt/crdt_test.cpp` |
| sync 域（`connect`/`disconnect`/`status`/`setOffline`/`join`/`sendOperation`/`sendPreview`/`lock`/`interactive`/`sync`/`events`/`queue`/`capabilities`；离线队列由 `sync` 排空；M1 传输为真实 Socket.IO，M2 T2b 增锁通道（D2-C）与重连恢复（D2-D），M3 增交互通道（T3.2）与 checkpoint 引擎侧（T3.5），见 §6/§7/§8） | `core/src/sync/sync.cpp`、`core/src/sync/socketio_transport.{h,cpp}`、`core/src/sync/transport.{h,cpp}`、`core/src/sync/outbound_queue.h` | `core/tests/unit/sync/sync_test.cpp`、`core/tests/unit/sync/outbound_queue_test.cpp`、`core/tests/unit/sync/fake_transport.h`（测试缝）、`core/tests/integration/test_sync_socketio.cpp`（env-gated 真连） |
| 预留协作提供者接口（AVProvider / InteractiveProvider / Transport / RecordingProvider / PlaybackProvider 虚接口与 `ReservedProviders()` 描述表；M1 起 **Transport 已由 SocketIOTransport 实现**，其余只预留） | `core/src/sync/providers.h` | 经 `capabilities` op 被 `core/tests/unit/sync/sync_test.cpp` 间接覆盖 |
| permission 域（`check`/`grant`/`revoke`/`list`/`levels`；ACL 按 (boardId,userId) 存最高级别、grant 取最大、revoke 幂等） | `core/src/permission/permission.cpp` | `core/tests/unit/permission/permission_test.cpp` |
| audit 域（`log`/`query`/`export`/`clear`；`audit-N` 序号 + 毫秒时间戳、按 userId/toolId/fromAI/since/until/limit 过滤、JSONL 导出） | `core/src/audit/audit.cpp` | `core/tests/unit/audit/audit_test.cpp` |

## 3. 契约与依赖

- **对外契约（只读）**：`core/include/wb/wb.h` 的 Sync 段（控制面 4：`wb_sync_connect`/`wb_sync_disconnect`/`wb_sync_status`/`wb_sync_set_offline`；数据面薄转发 7：M1 的 `wb_sync_join`/`wb_sync_send_operation`/`wb_sync_flush`/`wb_sync_events`/`wb_sync_send_preview` 5 个 + M2 的 `wb_sync_lock` 1 个（T2d 已交付，args `{action, elementId}`，ack 经 `events` 下发）+ M3 的 `wb_sync_interactive` 1 个（F3/T3.2，args `{action, userId?, targetUserId?}`，9 action 白名单，ack 经 `events` 的 `interactiveAcks` 下发））、CRDT 段（2：`wb_crdt_create`/`wb_crdt_apply_local`）与 Permission/audit 段（`wb_permission_check`/`wb_audit_query`/`wb_audit_export`），协同面共 13 个符号（均 UTF-8 JSON 信封 + `wb_free` 释放，**不新增回调通道类符号**；M2 锁/重连均走既有 `events`/`status` 轮询面）；`wb_mcp_audit_query`/`wb_mcp_audit_export`（MCP 段）由 06 mcp 域转发到本模块 audit 域（`core/src/mcp/mcp.cpp:567-572`）。
- **被依赖**：06 `ai` 域与 `mcp` 域在工具执行后写审计（`fromAI` 标记，`core/src/mcp/mcp.cpp:220-226`）；01 工具注册表已注册 `crdt.*`/`sync.*`/`permission.*`/`audit.*` 工具；07 `packages/core_dart` 的 `wb_core_bindings.dart` 封装 `wb_sync_*`/`wb_permission_check`/`wb_audit_query`；`core/tests/integration/test_crdt_sync.cpp`、`test_permission_audit.cpp` 断言跨模块链路。
- **依赖**：01 契约基础层（`wb/ffi/domain.h`、`wb/platform/platform.h`）；third_party（nlohmann/json；桌面构建另有 sioxx/Socket.IO，wasm 不引入）。crdt/sync/audit/permission 均为进程内注册表模式（同 `SceneStore` 模式），**不依赖 02 数据模型**。
- **已知契约事实（回归依据）**：CRDT 合并为 (actor,seq) 集合去重 + LWW 重放，合并副本必须使用不同 actor 才能区分 op；permission 级别层级 Read < Write < Share < Admin，更高隐含满足更低，名称大小写不敏感、未知名称 `InvalidArgument`；audit 条目 id 形如 `audit-N`，`query` 按插入时序返回；`capabilities` 返回的 provider 默认全部 `implemented=false`（M1 起 `Transport` 为 `true`），transports 数组中仅 `socketio` 为 `true`，`"reserved":true` 保留。M2 补充：锁为会话态（`lock` op → `sendLock`，ack 经 `lock:reply`⇒`room.lockAcks`、广播 `lock:changed`⇒`room.locks` 对象 map，断线即弃、不进 CRDT）；重连水位 = per-actor 最大连续 seq，`Reconnecting→Connected` 跃迁触发自动 re-join（带 `lastSeenVersion`），先拉（差分）后推（pending flush），期间新 op 入队（`awaitingReplay`）。M3 补充：交互通道为会话态（9 action → `interactive:<action>`；ack `interactive:reply` ⇒ `events.interactiveAcks`；角色/模式/presenter/host/跟随/移除折叠进 room 快照）；checkpoint 为 `board:checkpointRequest` → 锁外 `crdt.encodeState` → `board:checkpoint {stateVector, payload}`，`checkpointStatus` `idle→requested→uploaded|failed`（超时合成失败应答）；join 快照仅在新成员本地无 crdt 文档时 `decodeState`（守卫，防覆盖本地未同步数据），水位重置为 `snapshot.stateVector` 且 `room.recovered=true`。

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
- 修改传输接口（`joinBoard` 水位参数 / `sendLock` / `sendInteractive` / `sendCheckpoint`）或 `events` 的 `room.lockAcks`/`room.locks`/`interactiveAcks`/`incomingFollows`/`removed` 折叠 → 07 Dart 封装、13 服务端 `lock:*`/`interactive:*`/checkpoint 事件表与桌面互动 UI（T3.2/T3.4）联动；`lock:changed`/`interactive:*`/checkpoint 载荷字段与《实时协同设计》§5.10/§6、`services/realtime/src/types.ts` 对齐。
- 修改 permission 级别体系或 `check` 语义 → 13 服务端 API 与 11 客户端权限 UI 可能失效；`grant`/`revoke` 语义变化需同步集成测试。
- 修改审计条目结构（字段名/`fromAI`/id 格式）→ 06 mcp `tools/call` 写入侧、`test_permission_audit.cpp`、以及导出 JSONL 的下游消费方联动。
- `core/src/audit` 无 include 目录、无公共头：审计的 FFI 面只有 `wb_audit_query`/`wb_audit_export`（+ MCP 转发），写入路径经工具/域调用；新增对外入口需走 01 决策。

## 6. M1 实现注记（T1.1 传输真实化 / T1.2 数据面 op）

- **传输与状态机（T1.1）**：`core/src/sync/socketio_transport.{h,cpp}` 基于 sioxx v0.3.0 实现 `wb::sync::Transport`（`transport.h` 对 `reserved::Transport` 的扩展），`transport.cpp` 的 `MakeTransport()` 装配生产实现（测试经 `SetTransportFactory` 注入 Fake）。自有 io_context + 25 ms pump 双线程：网络线程只做协议收发与队列搬运，**严禁调用 invokeDomain**（域调用一律在 FFI 调用线程）。状态机：`Disconnected → Connecting → Connected`，断线自动重连 → `Reconnecting`，握手失败 → `Failed`。wasm 构建不引入 sioxx（宏包裹 + `UnavailableTransport`），`connect` 明确返回 `NotSupported` 降级。
- **可靠性机制**：出站 100 ms 攒批（`outbound_queue.h`）；ack 超时 3 s、最多重发 3 次（首发 + 3 重发，≈12 s 后耗尽转离线队列，经 `drainFailures()` 由域在 op 入口回灌）；断线期间 emit 由 sioxx 内部缓冲保序、重连后自动 flush；预览走迟滞队列深度 1（新值覆盖未发送旧值）。端点归一化：裸 `host:port` 由实现补 `http://`（`transport.h` 契约）；`latencyMs` 取最近一次 ack RTT，亚毫秒下限钳到 1 ms（`0` 保留为未采样哨兵）。
- **入站**：`board:ops`/`presence:preview`/`board:joinAck` 进入 drain 队列；`board:joined`（join 快照：整体替换 `room.participants/mode/locks`）、`board:participants`（他人加入/离开增量：按 `socketId` 去重合并 / 移除）、`board:session`（服务端签发的本端 `userId`：存 `SyncState.selfUserId`，join 保全、connect/disconnect 清空）同样经 drain 队列在 `events` 折叠；`events` op 在 FFI 线程消费，逐条 `invokeDomain("crdt","applyRemote")` 过滤（仅 `applied=true` 进入应答；docId=当前 join 的 `boardId`）。
- **capabilities（D-B）**：`Transport` provider 与 `socketio` transport 标注 `implemented=true`，其余保持 `false`，`"reserved":true` 保留。
- **参与者名单与身份（交互改造修复）**：socketio_transport 订阅 `board:participants`（服务端 `socket.to(room)` 广播他人 joined/left 增量）并在 `events` 折叠进 room 缓存——修复「A 先入房、B 后入房时 A 端名单冻结（人数恒 1）」；`board:session` 透传的服务端本端身份（每连接唯一）输出为 `room.selfUserId`，客户端据此精确标记「我」（不再依赖「末位 = 本人」推断）；`JoinBoard` 载荷附 `lastSeenVersion` 水位（首 join 空对象触发全量回放，late-join 补课，CRDT (actor,seq) 去重保证幂等）。`sync_test.cpp` 用例 `sync tracks session identity and participant deltas` 覆盖（身份设置 / 增量去重 / left 移除 / re-join 保全 / disconnect 清空）。
- **FakeTransport 测试缝**：`core/tests/unit/sync/fake_transport.h`（`wb::sync::test::InstallFakeTransport()`，同步即时完成语义；catch_discover_tests 每 TEST_CASE 独立进程）。`outbound_queue_test.cpp` 以注入时钟覆盖攒批/重试/失败转移时间轴（不 sleep）。
- **真连集成用例（env-gated）**：`core/tests/integration/test_sync_socketio.cpp` 由 `WB_SIOXX_POC_ENDPOINT` 门控（未设即 SKIP，随 “socketio POC (env-gated)” ctest 条目执行）：域 `connect`/`join`/`sendOperation`/`sendPreview` 与裸 `SocketIOTransport` peer 同房互通，覆盖裸端点归一化、ack 延迟采样、`events` 的 applyRemote 过滤与 drain 语义、room 快照。
- **数据面 op 契约（T1.5 Dart 绑定依据）**：

| op | args | result | 错误码 |
|---|---|---|---|
| `join` | `{boardId, pageId?}`（传输层附 `lastSeenVersion` 水位：首 join `{}` → 全量回放；同板 re-join → `{actor:contiguousSeq}` 仅回放增量） | `{boardId, joined:true, pageId?}` | 缺 `boardId`→`InvalidArgument`；离线/未连接→`Conflict` |
| `sendOperation` | `{op}`（完整 op：actor/seq/key/value/timestamp/origin） | 在线 `{sent:true, pendingCount, syncedCount}`；否则 `{queued:true, sent:false, pendingCount, syncedCount}`（re-join 期间同样入队） | 缺 `op`/非对象→`InvalidArgument` |
| `sendPreview` | `{preview}`（须含 `kind`：transform/ink） | 在线 `{sent:true}`；未连接/离线 `{dropped:true}` | 缺 `kind`→`InvalidArgument` |
| `lock` | `{action, elementId}`（action ∈ acquire/release/renew；经传输 `sendLock` emit `lock:acquire/release/renew` + ack） | 在线 `{requested:true}`；未连接/离线/被拒 `{requested:false}`（恒 ok，结果异步经 `events`） | 缺任一/`action` 非法→`InvalidArgument` |
| `interactive`（M3 T3.2） | `{action, userId?, targetUserId?}`（action ∈ raiseHand/lowerHand/startPresent/stopPresent/grantControl/revokeControl/removeUser/follow/unfollow；经传输 `sendInteractive` emit `interactive:<action>` + ack） | 在线 `{requested:true}`；未连接/离线/被拒 `{requested:false}`（恒 ok，结果异步经 `events.interactiveAcks`） | 缺 action / action 非法 / 缺 action 所需字段→`InvalidArgument` |
| `events` | 无（drain 语义：逐调用清空） | `{ops:[已应用 op], previews:[透传], room:{participants,mode,locks,lockAcks,selfUserId,selfRole,presenterId,hostUserId,grantedWrite,checkpointStatus,recovered}, status:{…}, interactiveAcks:[…], incomingFollows:[…], removed:{…}}`；`locks` 为 `elementId→{userId,expiresAt}` 对象 map；`lockAcks` 为本调用内的 `lock:reply` 回执数组；M3：`interactiveAcks`=`[{action,ok,reason?}]`（本调用内 ack）、`incomingFollows`=`[{followerUserId,action}]`（仅投给本端）、`removed={reason}`（`room:removed` 一次性通知） | — |
| `status` 增量 | 无 | 新增 `transportState`/`latencyMs`/`participants`/`reconnectCount`；`transport` 值 `"socketio"` | — |
| `connect` 增量 | `{endpoint, token?, clientVersion?}`（`clientVersion` 默认 `"1.0.0"`） | 同 `status` | 已连接→`Conflict`；启动失败（含 wasm）→`NotSupported` |

## 7. M2 实现注记（T2b 锁通道 D2-C / 重连恢复 D2-D）

- **锁通道（D2-C）**：`Transport::sendLock({action,elementId})`（`transport.h` 纯虚；`socketio_transport` 按 action emit `lock:acquire/release/renew` 并挂 ack 回调，未连接返回 false；`UnavailableTransport`/Fake 同步对齐）。入站订阅 `lock:changed`（广播）与 `lock:reply`（ack 回执）。域 op `lock`：参数 `{action, elementId}`（缺任一或 action 非法 → `InvalidArgument`）；未连接/离线/传输被拒 → `{requested:false}`，在线转发成功 → `{requested:true}`。`events` 折叠：`lock:reply` → `room.lockAcks`（drain，逐调用清空、透传 `{ok,granted,elementId,holderUserId?,expiresAt?}`）；`lock:changed` acquired → `room.locks[elementId]={userId,expiresAt}`，released/expired → 删除；`board:joined.locks` 快照按对象 map 整体替换（旧数组形态归一为 `{}`）。锁为会话态，不进 CRDT。
- **重连水位（D2-D）**：`SyncState.watermarks = map<actor, {contiguousSeq, pendingSeqs}>`；推进源 = `sendOperation` 路径（op 自带 actor/seq）与 `events` 的 applyRemote 响应（含 duplicate / LWW 输方：已入日志即推进）；gap 入 `pendingSeqs`，连续后继循环吸收，`seq ≤ contiguousSeq` 的重放忽略（幂等）。join/re-join 序列化 `{actor: contiguousSeq}` 经 `transport->joinBoard(boardId, pageId, watermark)`（**签名 M2 起为 3 参**）；disconnect 清空，跨板 join 清空。
- **自动 re-join 与先拉后推**：`events` drain 时按快照检测 `Reconnecting→Connected` 跃迁（`lastTransportState`，Connect/Disconnect 重置；Failed / 手动断线 / 首连均不触发），触发即置 `awaitingReplay=true` 并 `joinBoard`（带水位）；期间 `sendOperation` 入 pending 不直发、`sync` op 返回 `Conflict` 推迟；收到 `board:joined` / `board:joinAck`(ok) 后清标记并自动 flush pending（同一次 drain 内先应用差分再推积压）；再次掉线由下一跃迁重触发。
- **测试**：`sync_test.cpp` 新增 4 用例（`sync lock op validates and forwards to the transport`、`sync events fold lock acks and lock:changed into the room`、`sync watermark tracks contiguous seqs across gaps and replays`、`sync rejoins after a passive reconnect and holds the backlog`）；`fake_transport.h` 增 `joinWatermarks`/`sentLocks`/`lockReplies`（`FakeQueueLockReply` 预置 ack）。真连 POC 用例（env-gated）同步为 3 参 `joinBoard`。

## 8. M3 实现注记（T3.2 交互通道 / T3.5 checkpoint 引擎侧 / F3 新符号）

- **F3 新符号**：`core/include/wb/wb.h` 增 `wb_sync_interactive(const char* argsJson)`（置于 `wb_sync_lock` 附近，协同面 12→13）；`core/src/ffi/ffi_api.cpp` 薄转发 `Call("sync","interactive",args)`；`ffi_collab_symbols_test.cpp` 增信封 / 离线 `{requested:false}` / 非法入参探针。
- **交互通道（T3.2）**：`Transport::sendInteractive({action,userId?,targetUserId?})`（`transport.h` 纯虚）。action→wire 映射为单一事实源 `InteractiveWireEvent`/`InteractiveWireField`（`transport.{h,cpp}`，真传输与 Fake、域校验共用）：raiseHand/lowerHand/startPresent/stopPresent → `interactive:<action>` 载荷 `{}`；grantControl/revokeControl/removeUser → 载荷 `{userId}`；follow/unfollow → 载荷 `{targetUserId}`。ack 回调推送 `interactive:reply` 并回填 `action`。`UnavailableTransport`（wasm）返回 false、Fake 同步对齐。域 op `interactive`：action 白名单 + 所需字段校验→`InvalidArgument`；未连接/离线/被拒→`{requested:false}`，在线转发成功→`{requested:true}`。
- **入站订阅（M3 增 7）/ emit 出口**：新增 `interactive:modeChanged`、`interactive:roleChanged`、`interactive:hostChanged`、`interactive:follow`、`interactive:unfollow`、`room:removed`、`board:checkpointRequest`（既有 `board:*`/`lock:*`/`presence:*` 不变）；新 emit 出口 `board:checkpoint`（checkpoint 上传）。
- **events 折叠（M3）**：room 快照扩展 `selfRole`（joined.role；`roleChanged` 单播按 `userId` 过滤更新）、`mode`（joined.mode + `modeChanged`）、`presenterId`（present 时=`by`，离开 present 清空）、`hostUserId`（`hostChanged.newHostId`）、`grantedWrite`（participants 自条目镜像）；`board:participants` 增量增 `updated` 数组（按 socketId 优先 / userId 兜底合并字段，未知名忽略）。drain 批次新增 `interactiveAcks`（`[{action,ok,reason?}]`，逐调用清空）、`incomingFollows`（仅投给本端的 `[{followerUserId,action}]`）、`removed`（`room:removed` 一次性 `{reason}`）。
- **checkpoint 引擎侧（T3.5）**：drain 内收到 `board:checkpointRequest` → 锁外取 per-actor 水位 + `invokeDomain("crdt","encodeState",{docId=boardId})` → `sendCheckpoint({stateVector, payload})` emit `board:checkpoint`；`checkpointStatus`：`requested`（在途）→ `uploaded`（ack ok）/ `failed`（ack 拒绝、socketio pump 3 s 死线超时合成 `{ok:false,reason:"timeout"}`、或本地 encode/传输被拒即失败）。**快照恢复守卫**：`board:joined.snapshot={stateVector,payload}` 仅当本地 crdt 文档不存在（`encodeState` 探测 `NotFound`）时 `crdt.create`+`decodeState` 并以 `snapshot.stateVector` 重置水位、置 `room.recovered=true`；本地已有文档一律跳过（`decodeState` 为整状态替换，防覆盖本地未同步数据）。
- **测试（M3 新增 5 + FFI 探针）**：`sync_test.cpp`：`sync interactive op validates and forwards actions`（9 action 映射 + 校验 + requested 流转）、`sync events fold interactive state and acks`、`sync answers a checkpoint request with the encoded state`（payload 与 `encodeState` 一致 / stateVector=水位 / 状态流转）、`sync restores a join snapshot for a new member`、`sync keeps an existing document when a snapshot arrives`（守卫两路径）；`fake_transport.h` 增 `sendInteractive`/`sendCheckpoint`、`sentInteractives`/`sentCheckpoints` 与 `FakeQueueInteractiveReply`/`FakeQueueCheckpointReply` 预置回复。
