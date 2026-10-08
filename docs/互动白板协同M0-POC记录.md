# 互动白板协同 M0（选型 POC）记录 —— 门 G0

- 关联计划：《互动白板实时协同开发计划》§2（M0 选型 POC）；门 G0 = POC 结论评审（是否锁定方案；回退判断）
- 关联设计：《互动白板实时协同设计文档》（v1.0 定稿，§2.2 选型 / §5.4 迟滞队列 / §6 消息契约 / §7 服务端 / §8.2 并发锁约定）
- 复核执行：wb-verify-agent（集成门 G0 实测）
- 复核日期：2026-09-30
- **复核结论：✅ 通过 —— sioxx 方案可行，无需回退；M1 按既定方案推进（socketio_transport 薄封装 + 应用层迟滞队列）**

> 数据口径：带【G0 实测】的条目为本次复核亲自执行的命令与原始输出；带【T0.x 记录】的条目来自任务包执行记录 + 构建产物/日志/时间戳旁证核验。测试结论统一以 “All tests passed + 日期” 为准，用例数仅为当日快照。

---

## 1. 复核结果总表

| # | 复核项 | 命令 | 结果 | 证据摘要 |
|---|---|---|---|---|
| 1 | C++ 全量构建 + ctest | `.\tools\scripts\build_cpp.ps1 -RunTests` | ✅ 通过 | exit=0；`100% tests passed, 0 tests failed out of 200`；`socketio POC (env-gated)` 未设环境变量时正确 Skipped（不失败）；产物 `wb_core.dll (1,640,960 bytes)` |
| 2 | realtime 服务单测 | `cd services\realtime; npm test` | ✅ 通过 | vitest v2.1.9：`Test Files 1 passed (1)` / `Tests 10 passed (10)`（2026-09-30） |
| 3 | Web 静态分析 | `cd apps\web; flutter analyze --no-pub` | ✅ 通过 | `No issues found! (ran in 2.9s)`（Flutter 3.47.5） |
| 4 | Web VM 桩测试 | `flutter test --no-pub test/socketio_js_vm_test.dart` | ✅ 通过 | `All tests passed!`（3 用例：加载失败异常 / 平台桩回调 / emitWithAck UnsupportedError） |
| 5 | Web 浏览器真连 POC | `flutter test --no-pub --platform chrome test/socketio_js_poc_test.dart`（CHROME_EXECUTABLE=Edge） | ✅ 通过 | `All tests passed!`（9 通过 + 1 跳过=可选 gated 拒连轮次；脚本幂等 / session / join+ping / echo / direct / volatile / websocket-only / polling-only / default 升级） |
| 6 | **C++ ↔ realtime 端到端真连**（G0 核心证据） | 起服务 → `ctest -R "socketio POC" -V`（`WB_SIOXX_POC_ENDPOINT=http://127.0.0.1:8790`） | ✅ 通过 | `5 | 4 passed + 1 skipped（reconnect 需显式开启）| 39 assertions 全过`；真实 userId / ack / 广播排除 / 单播 / 降级 / back-off 全部实测输出 |
| 7 | **断线重连端到端编排**（停/启服务） | `WB_SIOXX_POC_RECONNECT=1` + `wb_tests.exe "[poc_reconnect]"`，操作者 paced 停/启 node 服务 | ✅ 通过 | `service drop observed (closeCount=1)` → 重启后 `reconnected: connectCount=2 sessionCount=2` → `9 assertions` 全过；重连后 ping ack 往返成功 |
| 8 | 增量构建稳定性复核 | `build_cpp.ps1 -RunTests` 第二次（依赖全缓存） | ✅ 通过 | exit=0；**全链路 12.8s**（configure+build+ctest，ctest 3.48s）；幂等跳过拉取/OpenSSL 重建 |

---

## 2. T0.3 realtime 最小原型（services/realtime/）

### 2.1 文件清单

| 文件 | 说明 |
|---|---|
| `src/server.ts` | express + Socket.IO 装配；`GET /healthz`→`{ok:true}`；`PORT \|\| 8790`；优雅关闭（幂等，含 closeAllConnections） |
| `src/rooms.ts` | `/board` namespace 装配：认证中间件 + 最小事件集；房间约定 `board:<boardId>` / `user:<userId>` |
| `src/auth.ts` | 连接身份：JWT（HS256）验签取 `sub` → `authMode:'jwt'`；匿名回落 → `anon-*`；配了 token 但无 `WB_JWT_SECRET` → 警告 + 匿名回落；验签失败 → `connect_error(Unauthorized)` |
| `src/types.ts` | 事件契约类型（对齐设计 §6/§7 最小子集） |
| `tests/realtime.test.ts`、`tests/helpers.ts` | vitest 冒烟 10 用例（自起自停随机端口，全离线） |
| `package.json` | socket.io ^4.8.1 / express ^4.19.2 / jsonwebtoken ^9 / vitest ^2 / tsx；scripts：`dev`(tsx watch) / `start`(node dist) / `test`(vitest run) |
| `tsconfig.json`、`dist/`（构建产物） | `npm run build` = `tsc -p tsconfig.json` |

### 2.2 事件契约清单（M0 最小集）

**C→S（均可带 ack 回调）**

| 事件 | 载荷 | ack |
|---|---|---|
| `board:join` | `{boardId, pageId?}` | `{ok:true, boardId, participants, role:'Participant', mode:'free'} \| {ok:false,error:{code:'INVALID_ARGUMENT',...}}`；同时单发 `board:joined` |
| `board:ping` | `{clientTime}` | `{ok:true, serverTime}` |
| `board:echo` | `{payload}` | `{ok:true, echo}`；并向房间广播 `board:broadcast`（**排除发送者**） |
| `board:direct` | `{toUserId, payload}` | `{ok:true}`；向 `user:<toUserId>` 房间单播 `board:directed` |

**S→C**

| 事件 | 载荷 | 触发 |
|---|---|---|
| `board:session` | `{userId, authMode:'jwt'\|'anonymous'}` | 连接建立即单播（POC 自省，便利单播寻址） |
| `board:joined` | `{boardId, participants, role, mode}` | `board:join` 后 |
| `board:broadcast` | `{from, payload}` | `board:echo` 房间广播（`socket.to(room)`，排除发送者） |
| `board:directed` | `{from, toUserId, payload}` | `board:direct` 单播（`namespace.to(user:<id>)`） |

失败回执统一形状：`{ok:false, error:{code, message}}`（错误码沿用 §6 风格：`Unauthorized` / `INVALID_ARGUMENT` …）。范围声明：不含 op 日志 / 去重 / 水位 / 完整权限 / 审计（属 M1 T1.3）。

### 2.3 测试结果【G0 实测】

`npm test` → `Tests 10 passed (10)`（2026-09-30）。覆盖：healthz + 幂等关闭 / 匿名回落 / JWT 验签成功 / 验签失败拒连 / 无密钥警告回落 / join ack+joined / join 参数校验 / ping ack / echo ack+广播排除发送者 / direct 单播（含非目标与发送者零事件）。

---

## 3. T0.1 / T0.1b sioxx 构建集成与连通验证

### 3.1 集成方式（FetchContent tarball + SHA256）

落点：`core/third_party/CMakeLists.txt`（`if(NOT WB_BUILD_WASM)` 守卫段）+ `core/third_party/cmake/{build_openssl.ps1, Findnlohmann_json.cmake}`。全部走 FetchContent URL tarball（CMake 用 libcurl，绕开本机 git 代理故障）；优先 `find_package` 系统包。

| 依赖 | 版本 | 来源 | SHA256 | 备注 |
|---|---|---|---|---|
| sioxx | v0.3.0 | `codeload.github.com/jfayot/sioxx`（+github.com 兜底） | `f41e084f…52fdf` | 要求 CMake ≥ 3.28（低于则 FATAL 提示）；`SIOXX_USE_SYSTEM_JSON=ON` 复用仓库已抓的 nlohmann_json（`cmake/` shim 满足其版本查找） |
| Boost | 1.90.0 | `archives.boost.io`（+sourceforge 兜底） | `5e93d582…3eea9` | sioxx 内置 GitHub releases tarball 实测 75 KB/s（~22min），改为官方 tar.gz + `FETCHCONTENT_SOURCE_DIR_BOOST` 重定向（保持 `SIOXX_USE_SYSTEM_BOOST=OFF`，无需安装 Boost） |
| OpenSSL | 3.5.9 | gh-proxy 镜像（+github releases 兜底） | `603f5602…f859a` | 本机无系统 OpenSSL → 私有静态前缀 `build/…/third_party/openssl-install`（`build_openssl.ps1`，需 Perl+MSVC，一次性、幂等跳过）；`OPENSSL_USE_STATIC_LIBS=TRUE` |
| Threads | — | 系统 | — | sioxx 链接 `Threads::Threads`，预先 `find_package(Threads REQUIRED)` |

别名：`wb::sioxx`（供 tests 等链接）；可用时并入 `wb_third_party` 伞目标。**WASM 构建不拉取任何上述依赖**（整段在 `if(NOT WB_BUILD_WASM)` 内；POC 测试源码亦有 `#if !defined(__EMSCRIPTEN__)` 守卫）。

测试注册：`core/tests/CMakeLists.txt` —— 通用发现用 `TEST_SPEC "~[poc]"`（排除 POC），再显式 `add_test("socketio POC (env-gated)", wb_tests "[poc]")` + `SKIP_RETURN_CODE 4`（无环境变量时 Catch2 全 skip 退出码 4 映射为 Skipped 而非失败）+ `DISCOVERY_MODE PRE_TEST`。

### 3.2 构建耗时实测

**首次全量（T0.1a 记录 + 本次复核旁证核验）**：首次 configure 合计 **12m06s**（EXIT=0）【T0.1a 记录】。本次复核以构建产物时间戳/日志复核各段构成：

| 阶段 | 实测耗时 | 旁证（2026-09-30 时间戳） |
|---|---|---|
| Boost tarball 拉取（下载+解压） | **~2m16s**（报告口径 2m17.5s / 文档记录 2m18s） | `wb_boost-populate` stamp：01:17:27 → 01:19:43 |
| OpenSSL tarball 拉取 | ~22s | 01:19:43 → 01:20:05 |
| OpenSSL 私有构建（configure 22s + nmake build 8m41s + install 11s） | **9m14s**（报告口径 9m36.5s / 文档记录 9m36s） | `openssl-{configure,build,install}.log`：01:20:06 / 01:20:28 / 01:29:09 / 01:29:20 |
| sioxx tarball 拉取 | ~5s（报告口径 4.8s） | `sioxx-populate` stamp：01:29:20 → 01:29:25 |

> 说明：本机 build 目录已含全部缓存，首次全量无法在 G0 中重测（重测 >30min 且属 CI 场景）；上表为对 T0.1a 记录的时间戳/日志旁证核验，口径差异（如脚本前后处理）已在括号内标注。

**本次 G0 增量复核【G0 实测】**：第二次 `build_cpp.ps1 -RunTests`（依赖全缓存）**全链路 12.8s**（configure + build + ctest，exit=0），其中 ctest 3.48s。幂等行为确认：Boost/OpenSSL/sioxx **不再重新拉取或构建**（OpenSSL 前缀存在即跳过 `build_openssl.ps1`）。

### 3.3 POC 用例覆盖矩阵（`core/tests/integration/test_socketio_poc.cpp`，631 行 / 5 用例）

| # | 用例（tag） | 覆盖 | 门控 |
|---|---|---|---|
| 1 | `/board connect, session identity, ping and echo acks` | a) 连接 + auth 载荷 + `board:session` 身份快照；b) `board:ping`/`board:echo` ack 契约 | `WB_SIOXX_POC_ENDPOINT` |
| 2 | `same-room broadcast excludes the sender (two clients)` | c) 双客户端同房间，B 收到 `board:broadcast`，A（发送者）零事件 | 同上 |
| 3 | `direct message routes only to the target userId` | d) `board:direct` 按 userId 定向，仅目标收到 `board:directed`，发送者零事件 | 同上 |
| 4 | `unreachable endpoint fails bounded with back-off schedule` | e1) WS→polling 单向降级 + 有界失败 + 退避计划（attempt 递增、delay 不缩） | 同上（连 `127.0.0.1:1` 本地确定性失败） |
| 5 | `service restart triggers automatic reconnect and re-handshake` | e2) 停/启服务后的自动重连 + 重复 handshake + 重连后 ack 往返 | 上述 + `WB_SIOXX_POC_RECONNECT=1`（operator-paced） |
| — | 编译期哨兵（`static_assert`） | f) volatile：sioxx 0.3.0 无 `volatile_emit` 类 API；一旦上游引入则编译失败提醒重审迟滞队列兜底 | 编译期 |

### 3.4 真连实测（E2E，G0 核心证据）【G0 实测】

**编排**：`npm start`（services/realtime，:8790）→ `$env:WB_SIOXX_POC_ENDPOINT='http://127.0.0.1:8790'` → `ctest -R "socketio POC" -V`。

**运行 1（常规 4 用例 + 1 跳过）**：`5 | 4 passed | 1 skipped`，`39 assertions | 39 passed`，总耗时 14.02s。关键原始输出：

- 连接与身份：`[poc] session identity: userId=anon-3df55246 authMode=anonymous`
- ack 形状（**JSON 数组**）：`[poc] board:ping ack: [{"ok":true,"serverTime":1790710594406}]`；`[poc] board:echo ack: [{"echo":"T0.1b-poc","ok":true}]`
- 广播排除发送者：`[poc] B received board:broadcast [{"from":"anon-d419240a","payload":"T0.1b-c-broadcast"}]` + `[poc] A received 0 broadcasts (sender exclusion verified)`
- 单播定向：`[poc] A received board:directed [{"from":"anon-41d226f6","payload":"T0.1b-d-direct","toUserId":"anon-68712e93"}]` + `[poc] B received 0 directed messages (target-only verified)`
- **WS→polling 单向降级**：`[poc] error: WebSocket connection failed; switching to HTTP long-polling`（首连 WS 失败后自动降级，后续错误均来自 polling 传输）
- back-off 计划：`reconnect scheduled: attempt=0 delayMs=200 / 1 delayMs=400 / 2 delayMs=800`；`final opened=false failEvents=1`
- 用例 5 未开 `WB_SIOXX_POC_RECONNECT=1` → 显式 SKIP（不影响通过）

**运行 2（reconnect 编排）**：`WB_SIOXX_POC_RECONNECT=1` + `wb_tests.exe "[poc_reconnect]"`，按测试节奏操作者停止/重启服务：

1. `[poc-reconnect] connected; userId=anon-7f7a74b9 sessionCount=1`
2. `PHASE 1/2` → （复核者 `Stop-Process` 停服务）→ `service drop observed (closeCount=1 reason="远程主机强迫关闭了一个现有的连接。")`
3. `PHASE 2/2` → （复核者重启 `npm start`）→ 自动重连成功：`reconnected: connectCount=2 sessionCount=2`；`reconnect schedule entries=6 first=(0,451ms)`
4. 重连后 ping ack 往返成功 → `DONE: automatic reconnect + repeated handshake verified`
5. 结果：`All tests passed (9 assertions in 1 test case)`

**收尾**：服务进程已停止（8790 释放，无 node / wb_tests 残留），环境变量已清理。

---

## 4. T0.2 Web JS POC（apps/web/）

### 4.1 桥文件清单

| 文件 | 说明 |
|---|---|
| `lib/services/socketio_js.dart` | 统一入口：条件导入（web→js_interop 实现 / 否则 VM 桩）；`loadSocketIoClient(endpoint)` + `createWbSocketIoBridge()` |
| `lib/services/socketio_js_types.dart` | `WbSocketIoBridge` 抽象（connect/on/off/emit/emitWithAck/volatileEmit/disconnect + 连接状态回调 + `engineTransportName`/`supportsVolatile`）+ `WbSocketIoConnectOptions` + `WbSocketIoLoadException` |
| `lib/services/socketio_js_web.dart` | 浏览器实现：`dart:js_interop` externals 包装官方 JS 客户端（动态脚本注入 + globalThis.io 就绪判定 + dartify 载荷） |
| `lib/services/socketio_js_stub.dart` | VM 桩：不触 JS；连接以 `UnsupportedPlatform` 错误回调失败；其余 no-op |
| `test/socketio_js_vm_test.dart` | VM 3 用例（桥行为） |
| `test/socketio_js_poc_test.dart` | browser-only 10 用例（真连 :8790；gated 拒连为可选轮次） |

### 4.2 测试结果【G0 实测】

- `flutter analyze --no-pub` → `No issues found!`（2026-09-30）
- VM 桩：`All tests passed!`（3 用例；VM 下不加载 JS）
- 浏览器（Edge 兜底，`CHROME_EXECUTABLE=msedge.exe`）：`All tests passed!`（9 通过 + 1 跳过，跳过项=需 `WB_POC_BAD_TOKEN`+服务端 `WB_JWT_SECRET` 的可选 gated 轮次）。关键实测输出：
  - `load socket.io client x2 ok; second_call=0ms`（脚本加载幂等）
  - `connected id=… userId=anon-731328f2 authMode=anonymous transportAtConnect=websocket connect=13ms`
  - `join+ping ok` / `echo ok; selfBroadcasts=0` / `direct ok`
  - `volatile ok; board:joined received`（JS `socket.volatile.emit` 可达服务端，属**能力实测**而非仅 API 存在性）
  - `websocket-only: transportAtConnect=websocket connect=17ms`；`polling-only: transportAfter800ms=polling`（不升级）；`default: transportAtConnect=websocket upgraded=websocket upgradeWait=0ms`

> 浏览器用例可重跑（本次即重跑）；本次为 G0 亲自复现，非沿用 T0.2 结论。与 T0.2 记录“default 观测 polling→websocket 升级 10~35ms”的差异属升级时序竞争：本机 loopback 下升级在 connect 完成前已发生（wait=0ms），两轮均最终达 websocket——如实并存记录。

### 4.3 传输差异记录（供 M1 决策）

| 项 | 结论 |
|---|---|
| 动态脚本加载 | `{endpoint}/socket.io/socket.io.min.js` 由 socket.io@4 服务端自动托管：**零 npm 依赖、版本随服务端**；加载幂等（同 endpoint 复用同一 Future，实测 second_call 0ms）；失败抛 `WbSocketIoLoadException`（不阻塞 UI，可重试） |
| polling→WS 升级（Web） | 默认配置自动升级 websocket（实测连接即达或 10~35ms 内升级）；`transports:['polling']` 降级对照保持 polling；`['websocket']` 直连无升级阶段 |
| volatile 用法差异 | Web 官方客户端**原生支持** `socket.volatile.emit`（实测可达）；桌面 sioxx **无** volatile API → 应用层迟滞队列（见 §5） |
| CORS | 服务端 POC 阶段 `origin:'*'`，M1 按部署环境收紧（服务端范围，本模块不动） |
| Windows 平台注意 | 浏览器测试文件必须放 `test/` 根目录（子目录 `window.testSelector` 反斜杠转义问题）；运行依赖 `test/canvaskit/` 资源兜底（已 gitignore，可由 Flutter SDK 重建）；JS→Dart 回调用**可选位置参数** `([JSAny? _]) {...}`（DDC 严格校验实参个数） |

---

## 5. 关键 POC 结论（供 M1 使用，必须遵守）

1. **volatile 结论**：sioxx v0.3.0 **无 volatile（可丢）发送 API**（公共头无 `volatile_emit`；测试以 `static_assert` 哨兵固化此事实）。→ **M1 采用应用层迟滞队列**：每类预览消息仅保留最新一帧（队列深度 1，旧帧覆盖丢弃），对应设计 §5.4/§5.8 兜底表。Web 端原生 volatile 不受影响。
2. **WS→polling 单向降级**：首连 WS 失败会自动降级 HTTP long-polling 且**永不再升回 WS**（`activate_polling_fallback` 一次性置位；实测输出 “WebSocket connection failed; switching to HTTP long-polling”）。→ M1 若要“first-try-ws 失败后可恢复升级”，需显式重建连接（属应用层策略）。
3. **重连行为**：`reconnect_attempts` **默认 0（禁用）**，必须显式配置（client_options.hpp）；**重连调度仅在“已建立连接后 transport 关闭”时启动**（`on_engineio_close → schedule_reconnect`）——首连失败不会启动自动重连（走 fail/降级路径）。→ M1 配置示例：`reconnect_attempts=N`、`reconnect_delay`、`reconnect_delay_max`、`reconnect_randomization_factor`；重连计划可由 `set_reconnect_listener(attempt, delay_ms)` 观测。
4. **ack 语义**：sioxx 收到的 ack 载荷为 **JSON 数组**（如 `[{"ok":true,...}]`，取首元素对象）；**无超时 / 无自动重发**。→ 应用层实现 3s 超时 × 3 次重试（失败转离线队列），对应设计 §5.4；服务端 ack 形状统一 `{ok:true,…}` / `{ok:false,error:{code,message}}`。
5. **回调线程与安全**：生命周期/事件回调均在 sioxx 内部 worker 线程执行（io_context 线程 / polling 读写线程 / 心跳线程 / 重连线程——非调用者线程，测试侧共享状态一律 mutex/atomic 保护）；`socket::on` **同名事件覆盖语义**（后注册替换先注册；普通 listener 与 ack listener 分属两个注册表）；**回调内禁止 `sync_close()` / 析构**（worker 不能等待自身，官方注释明示；回调内改用 `close()`）。
6. **wasm 守卫已生效**：sioxx/Boost/OpenSSL 拉取全部在 `if(NOT WB_BUILD_WASM)` 段内；POC 测试有 `#if !defined(__EMSCRIPTEN__)` 守卫。WASM 构建不受影响（T0.1a 探针结论 + 本次代码复核确认）。→ M1 桌面专用代码路径（socketio_transport）保持同款守卫。

---

## 6. 回退判断

**结论：sioxx 可行，无需回退。**

依据：C++ 侧全矩阵真连通过（连接 / ack / 广播排除发送者 / 单播定向 / 断线重连 / WS→polling 降级 / back-off，5 用例 48 断言全过），Web 侧 9 用例真连通过；构建集成可复现（tarball + SHA256 固化，增量 12.8s），未发现阻断性问题。

**回退预案（仅当 M1 发现新阻断时启用）**：仅替换 `core/src/sync/socketio_transport.{h,cpp}` 的实现，对外接口（`reserved::Transport`）不变；候选 `socket.io-client-cpp`（注意其 EIO v3 旧协议，服务端需 `allowEIO3:true`，不推荐——设计 §2.2 已列为不采用）；服务端无接口变更（socket.io@4 / EIO v4 标准），回退不影响 realtime 与 Web 端。

---

## 7. 遗留风险与 M1 注意事项

| 项 | 说明 |
|---|---|
| BOOST_ASIO 线程数 | sioxx 每客户端自建 `io_context` 线程；polling 模式另有读写线程、心跳线程、重连线程。设计 §8.2 已定约：**网络线程只做协议收发与队列搬运，严禁直接 `invokeDomain`**；入站/出站均走队列（FFI 调用线程 drain）。M1 实现必须严格遵守 |
| `_deps` 缓存需求（CI，T1.4） | 首次 configure 需联网并构建 OpenSSL（本机实测 ~12 分钟）；CI windows job 无缓存时同样全量 → **建议为 CI 加依赖缓存或预装 OpenSSL/Boost**；本机二次构建 12.8s 证明缓存有效 |
| 重连参数 | `reconnect_attempts` 默认 0：M1 必须显式配置（连接建立后的断线重连才生效） |
| ack 兜底 | 无超时/重发 → 3s×3 应用层重试 + 离线队列（M1 出站队列一并实现） |
| 断线漏包 | 水位差分补洞（`lastSeenVersion` + `fetchOps`，§5.12）——M0 未验证，属 M1/T2.6 |
| realtime 服务范围 | 仍为最小原型（无 oplog/去重/水位/权限裁剪/审计）→ M1 T1.3 补全（vitest 逐事件过 §6 契约） |
| CORS | 服务端 `origin:'*'` 为 POC 联调放开；生产收紧（M1，服务端侧） |
| Web 测试窗口陷阱 | `test/` 根目录 + canvaskit 兜底 + 可选位置参数（§4.3），避免新用例踩坑 |

---

## 附录：G0 复核命令清单（可复现）

```powershell
# 1) C++ 构建 + ctest（POC 用例在未设环境变量时 Skipped，不算失败）
cd e:\code\whiteboard; .\tools\scripts\build_cpp.ps1 -RunTests

# 2) realtime 单测
cd e:\code\whiteboard\services\realtime; npm test

# 3) Web 分析 + VM 桩
cd e:\code\whiteboard\apps\web
flutter analyze --no-pub
flutter test --no-pub test/socketio_js_vm_test.dart

# 4) 端到端：起服务 → C++ POC 真连
cd e:\code\whiteboard\services\realtime; npm start                     # :8790（后台）
cd e:\code\whiteboard
$env:WB_SIOXX_POC_ENDPOINT = 'http://127.0.0.1:8790'
ctest --test-dir build/windows-x64 -C Release -R "socketio POC" --output-on-failure -V

# 5) 断线重连编排（需在 PHASE 1/2 时停服务、PHASE 2/2 时重启服务）
$env:WB_SIOXX_POC_RECONNECT = '1'
build\windows-x64\bin\Release\wb_tests.exe "[poc_reconnect]"

# 6) Web 浏览器真连（Edge 兜底）
$env:CHROME_EXECUTABLE = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
flutter test --no-pub --platform chrome test/socketio_js_poc_test.dart

# 收尾：停服务（Get-NetTCPConnection -LocalPort 8790 → Stop-Process）、清环境变量
```
