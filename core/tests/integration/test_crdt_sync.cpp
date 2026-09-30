// tests/integration/test_crdt_sync.cpp — 集成链路：CRDT 双副本 × 同步队列
// （《测试方案设计》§7.1 清单第 6 项）。
//
// 覆盖链路：
//   1. CRDT 双副本同步收敛：A 端 applyLocal → encodeUpdate → B 端
//      applyRemote（含重复去重）→ encodeState 逐字节一致。
//   2. LWW 时序冲突：时间戳大者胜、平局按 actor 字典序决胜（输方
//      applied=false 且状态不变）。
//   3. merge 交换律 + 幂等；encodeState/decodeState 状态往返一致。
//   4. SyncManager 队列链路：连接 → 离线排队 → queue 查看 → 离线同步
//      被拒 → 恢复在线 → sync 排空 → 状态归零 → 断开（M1 用
//      FakeTransport 测试替身，立即握手成功，语义与 M0 占位传输一致）。
//
// 注：crdt 无 FFI 导出，全部走 wb::invokeDomain；sync 混合 FFI 与
// invokeDomain。同步状态是进程级单例，本文件仅一个用例触碰 sync，
// 每个 TEST_CASE 在 ctest 下独立进程运行。
// nlohmann 按键字典序 dump：encodeState 的 state 为内嵌转义字符串，
// 用 JsonEscapedString 保持转义形态逐字节比较。

#include <catch2/catch_test_macros.hpp>

#include <string>

#include "../unit/sync/fake_transport.h"
#include "support/test_probe.h"

namespace {

std::string CrdtCreate(const std::string& docId, const std::string& actor) {
  return wb::invokeDomain("crdt", "create",
                          "{\"docId\":\"" + docId + "\",\"actor\":\"" + actor +
                              "\"}");
}

/// applyLocal：{docId, operation:{key, value, timestamp}}。
std::string CrdtApplyLocal(const std::string& docId, const std::string& key,
                           const std::string& value, long long timestamp) {
  return wb::invokeDomain(
      "crdt", "applyLocal",
      "{\"docId\":\"" + docId + "\",\"operation\":{\"key\":\"" + key +
          "\",\"value\":\"" + value + "\",\"timestamp\":" +
          std::to_string(timestamp) + "}}");
}

/// applyRemote：{docId, operation:{actor, seq, key, value, timestamp}}。
std::string CrdtApplyRemote(const std::string& docId,
                            const std::string& actor, int seq,
                            const std::string& key, const std::string& value,
                            long long timestamp) {
  return wb::invokeDomain(
      "crdt", "applyRemote",
      "{\"docId\":\"" + docId + "\",\"operation\":{\"actor\":\"" + actor +
          "\",\"seq\":" + std::to_string(seq) + ",\"key\":\"" + key +
          "\",\"value\":\"" + value + "\",\"timestamp\":" +
          std::to_string(timestamp) + "}}");
}

std::string CrdtState(const std::string& docId) {
  return wb::invokeDomain("crdt", "encodeState",
                          "{\"docId\":\"" + docId + "\"}");
}

}  // namespace

TEST_CASE("crdt: two replicas converge with dedupe and LWW",
          "[integration][crdt][sync]") {
  const std::string docA = "it-crdt-a1";
  const std::string docB = "it-crdt-b1";
  REQUIRE(JsonBool(CrdtCreate(docA, "alice"), "ok", true));
  REQUIRE(JsonBool(CrdtCreate(docB, "bob"), "ok", true));

  // 1) A 端本地两次写入同一 key（LWW 寄存器后写覆盖先写）。
  const std::string local1 = CrdtApplyLocal(docA, "title", "Hello", 1000);
  REQUIRE(JsonBool(local1, "applied", true));
  REQUIRE(JsonNumber(local1, "seq") == 1.0);
  REQUIRE(JsonNumber(local1, "version") == 1.0);
  REQUIRE(JsonString(local1, "origin") == "local");
  const std::string local2 = CrdtApplyLocal(docA, "title", "World", 2000);
  REQUIRE(JsonBool(local2, "applied", true));
  REQUIRE(JsonNumber(local2, "version") == 2.0);

  // 2) 增量导出：since=0 得到全部 2 条操作。
  const std::string update = wb::invokeDomain(
      "crdt", "encodeUpdate", "{\"docId\":\"" + docA + "\",\"since\":0}");
  REQUIRE(JsonBool(update, "ok", true));
  REQUIRE(JsonNumber(update, "count") == 2.0);
  REQUIRE(JsonArrayLength(update, "update") == 2);
  REQUIRE(JsonNumber(update, "version") == 2.0);

  // 3) B 端应用：正常应用 → 重复应用去重。
  const std::string remote1 =
      CrdtApplyRemote(docB, "alice", 1, "title", "Hello", 1000);
  REQUIRE(JsonBool(remote1, "applied", true));
  REQUIRE(JsonNumber(remote1, "version") == 1.0);
  REQUIRE(JsonString(remote1, "origin") == "remote");
  const std::string duplicate =
      CrdtApplyRemote(docB, "alice", 1, "title", "Hello", 1000);
  REQUIRE(JsonBool(duplicate, "duplicate", true));
  REQUIRE(JsonBool(duplicate, "applied", false));
  REQUIRE(JsonNumber(duplicate, "version") == 1.0);

  const std::string remote2 =
      CrdtApplyRemote(docB, "alice", 2, "title", "World", 2000);
  REQUIRE(JsonBool(remote2, "applied", true));
  REQUIRE(JsonNumber(remote2, "version") == 2.0);

  // 4) 收敛：双副本 state 逐字节一致。
  const std::string stateA = CrdtState(docA);
  const std::string stateB = CrdtState(docB);
  REQUIRE(JsonNumber(stateA, "keyCount") == 1.0);
  REQUIRE(JsonEscapedString(stateA, "state") ==
          JsonEscapedString(stateB, "state"));
  REQUIRE(JsonContains(stateA, "World"));

  // 5) LWW 平局：timestamp 相同（2000），actor 字典序大者（bob）胜。
  const std::string bobWins = CrdtApplyLocal(docB, "title", "BobWins", 2000);
  REQUIRE(JsonBool(bobWins, "applied", true));
  REQUIRE(JsonNumber(bobWins, "version") == 3.0);
  const std::string bobToA =
      CrdtApplyRemote(docA, "bob", 1, "title", "BobWins", 2000);
  REQUIRE(JsonBool(bobToA, "applied", true));
  REQUIRE(JsonNumber(bobToA, "version") == 3.0);

  // 输方（actor 字典序小者）应用被拒且不改变状态。
  const std::string adam = CrdtApplyRemote(docA, "adam", 1, "title", "Adam",
                                           2000);
  REQUIRE(JsonBool(adam, "applied", false));
  REQUIRE(JsonNumber(adam, "version") == 4.0);  // 操作入日志但寄存器不动
  const std::string stateA2 = CrdtState(docA);
  const std::string stateB2 = CrdtState(docB);
  REQUIRE(JsonContains(stateA2, "BobWins"));
  REQUIRE_FALSE(JsonContains(stateA2, "Adam"));
  REQUIRE(JsonEscapedString(stateA2, "state") ==
          JsonEscapedString(stateB2, "state"));
}

TEST_CASE("crdt: merge commutative, idempotent, state roundtrip",
          "[integration][crdt]") {
  const std::string docA = "it-crdt-a2";
  const std::string docB = "it-crdt-b2";
  REQUIRE(JsonBool(CrdtCreate(docA, "alice"), "ok", true));
  REQUIRE(JsonBool(CrdtCreate(docB, "bob"), "ok", true));
  REQUIRE(JsonBool(CrdtApplyLocal(docA, "k1", "v1", 100), "applied", true));
  REQUIRE(JsonBool(CrdtApplyLocal(docB, "k2", "v2", 200), "applied", true));

  // 1) A merge B：各取所长，版本数为操作并集大小。
  const std::string merged = wb::invokeDomain(
      "crdt", "merge", "{\"docId\":\"" + docA + "\",\"other\":\"" + docB +
                           "\"}");
  REQUIRE(JsonBool(merged, "ok", true));
  REQUIRE(JsonNumber(merged, "merged") == 1.0);
  REQUIRE(JsonNumber(merged, "keyCount") == 2.0);
  REQUIRE(JsonNumber(merged, "version") == 2.0);

  // 2) 幂等：重复 merge 无新增操作。
  const std::string again = wb::invokeDomain(
      "crdt", "merge", "{\"docId\":\"" + docA + "\",\"other\":\"" + docB +
                           "\"}");
  REQUIRE(JsonNumber(again, "merged") == 0.0);
  REQUIRE(JsonNumber(again, "version") == 2.0);

  // 3) 交换律：B merge A 后双方状态一致。
  const std::string reverse = wb::invokeDomain(
      "crdt", "merge", "{\"docId\":\"" + docB + "\",\"other\":\"" + docA +
                           "\"}");
  REQUIRE(JsonNumber(reverse, "merged") == 1.0);
  REQUIRE(JsonNumber(reverse, "keyCount") == 2.0);
  REQUIRE(JsonEscapedString(CrdtState(docA), "state") ==
          JsonEscapedString(CrdtState(docB), "state"));

  // 4) 状态编解码往返：state 导出 → 第三副本 decodeState → 状态一致。
  const std::string docC = "it-crdt-c2";
  REQUIRE(JsonBool(CrdtCreate(docC, "carol"), "ok", true));
  const std::string encoded = JsonEscapedString(CrdtState(docA), "state");
  REQUIRE_FALSE(encoded.empty());
  const std::string decoded = wb::invokeDomain(
      "crdt", "decodeState",
      "{\"docId\":\"" + docC + "\",\"state\":\"" + encoded + "\"}");
  REQUIRE(JsonBool(decoded, "ok", true));
  REQUIRE(JsonBool(decoded, "decoded", true));
  REQUIRE(JsonNumber(decoded, "keyCount") == 2.0);
  REQUIRE(JsonEscapedString(CrdtState(docC), "state") == encoded);
}

TEST_CASE("sync: offline queue drains after reconnect",
          "[integration][sync]") {
  // 1) 连接（M1：FakeTransport 测试替身立即握手成功，语义与 M0 占位
  //    传输一致；真实 Socket.IO 链路见 socketio_transport + POC 用例）。
  wb::sync::test::InstallFakeTransport();
  const std::string connected =
      TakeAndFree(wb_sync_connect("ws://localhost:9000", "token-it"));
  REQUIRE(JsonBool(connected, "ok", true));
  REQUIRE(JsonBool(connected, "connected", true));
  REQUIRE(JsonString(connected, "endpoint") == "ws://localhost:9000");
  REQUIRE(JsonString(connected, "transport") == "socketio");

  // 2) 离线：操作进入本地队列，sync 被推迟。
  REQUIRE(JsonBool(TakeAndFree(wb_sync_set_offline(1)), "offline", true));
  const std::string queued1 = wb::invokeDomain(
      "sync", "sendOperation",
      "{\"operation\":{\"type\":\"element.create\",\"elementId\":\"e1\"}}");
  REQUIRE(JsonBool(queued1, "queued", true));
  REQUIRE(JsonBool(queued1, "sent", false));
  REQUIRE(JsonNumber(queued1, "pendingCount") == 1.0);
  const std::string queued2 = wb::invokeDomain(
      "sync", "sendOperation",
      "{\"operation\":{\"type\":\"element.update\",\"elementId\":\"e2\"}}");
  REQUIRE(JsonNumber(queued2, "pendingCount") == 2.0);

  const std::string queue =
      wb::invokeDomain("sync", "queue", "{}");
  REQUIRE(JsonBool(queue, "ok", true));
  REQUIRE(JsonNumber(queue, "pendingCount") == 2.0);
  REQUIRE(JsonArrayLength(queue, "operations") == 2);
  REQUIRE(JsonContains(queue, "element.update"));

  const std::string deferred = wb::invokeDomain("sync", "sync", "{}");
  REQUIRE(JsonBool(deferred, "ok", false));
  REQUIRE(JsonContains(deferred, "offline"));

  // 3) 恢复在线：sync 排空队列，状态计数联动。
  REQUIRE(JsonBool(TakeAndFree(wb_sync_set_offline(0)), "offline", false));
  const std::string drained = wb::invokeDomain("sync", "sync", "{}");
  REQUIRE(JsonBool(drained, "ok", true));
  REQUIRE(JsonNumber(drained, "synced") == 2.0);
  REQUIRE(JsonNumber(drained, "pendingCount") == 0.0);
  REQUIRE(JsonNumber(drained, "syncedCount") == 2.0);

  const std::string status = TakeAndFree(wb_sync_status());
  REQUIRE(JsonBool(status, "connected", true));
  REQUIRE(JsonNumber(status, "pendingCount") == 0.0);
  REQUIRE(JsonNumber(status, "syncedCount") == 2.0);

  // 4) 断开：连接状态复位。
  const std::string disconnected = TakeAndFree(wb_sync_disconnect());
  REQUIRE(JsonBool(disconnected, "connected", false));
}
