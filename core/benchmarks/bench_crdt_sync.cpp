// benchmarks/bench_crdt_sync.cpp — CRDT 增量写与同步队列基准（Wave 4.1）。
//
// 对齐《测试方案设计》§10.1/§10.2：协同编辑的增量写与同步链路吞吐。
//   1. CRDT applyLocal：LWW 寄存器本地写入（seq 自增，键 k0..k15 轮换）。
//   2. CRDT applyRemote 新操作：含 (actor, seq) 去重扫描后应用。
//   3. CRDT applyRemote 重复操作：重放已应用 seq 的纯去重判定（命中基线
//      日志中部，日志不增长，采样稳定）。
//   4. CRDT encodeUpdate 增量导出：固定 256 条日志取 since=192 的最新 64 条。
//   5. sync.sendOperation 在线直发（单条操作提交）。
//   6. sync 离线批量入队 32 条 → 上线 sync 排空。
//
// 说明：CRDT / sync 均无独立 FFI，统一走 wb::invokeDomain；时间戳固定
// 递增，不依赖系统时间。sync 为进程级单例，本文件内按声明顺序执行、
// 每个采样自平衡（入队即排空）。
// 注：applyRemote 的去重扫描 HasOp 为 O(日志长度)，基线日志 128 条；
// "新操作"基准中日志随采样增长但被成本自限（约数千条量级），均值
// 已含该特征，报告中注明。

#include <catch2/benchmark/catch_benchmark.hpp>
#include <catch2/catch_test_macros.hpp>

#include <string>

#include "support/bench_util.h"

namespace {

constexpr int kRemoteBaseline = 128;  // applyRemote 基线日志条数
constexpr int kUpdateLogSize = 256;   // 增量导出文档的固定日志长度
constexpr int kUpdateSince = 192;     // 每次导出最新 64 条（256 - 192）
constexpr int kOfflineBatch = 32;     // 离线批量入队条数

std::string CrdtCreate(const std::string& docId, const std::string& actor) {
  return wb::invokeDomain("crdt", "create",
                          "{\"docId\":\"" + docId + "\",\"actor\":\"" + actor +
                              "\"}");
}

std::string CrdtApplyLocal(const std::string& docId, const std::string& key,
                           const std::string& value, long long timestamp) {
  return wb::invokeDomain(
      "crdt", "applyLocal",
      "{\"docId\":\"" + docId + "\",\"operation\":{\"key\":\"" + key +
          "\",\"value\":\"" + value +
          "\",\"timestamp\":" + std::to_string(timestamp) + "}}");
}

std::string CrdtApplyRemote(const std::string& docId, const std::string& actor,
                            int seq, const std::string& key,
                            const std::string& value, long long timestamp) {
  return wb::invokeDomain(
      "crdt", "applyRemote",
      "{\"docId\":\"" + docId + "\",\"operation\":{\"actor\":\"" + actor +
          "\",\"seq\":" + std::to_string(seq) + ",\"key\":\"" + key +
          "\",\"value\":\"" + value +
          "\",\"timestamp\":" + std::to_string(timestamp) + "}}");
}

std::string SyncSend(const std::string& type) {
  return wb::invokeDomain("sync", "sendOperation",
                          "{\"operation\":{\"type\":\"" + type + "\"}}");
}

}  // namespace

TEST_CASE("CRDT 增量写基准", "[bench][crdt]") {
  // --- applyLocal：本地写入（时间戳单调递增、键轮换）。 -------------------
  const std::string docLocal = "bench-crdt-local";
  REQUIRE(JsonBool(CrdtCreate(docLocal, "bench"), "ok", true));
  long long localTs = 0;

  BENCHMARK("CRDT applyLocal（LWW 本地写入）") {
    localTs += 1;
    return CrdtApplyLocal(docLocal, "k" + std::to_string(localTs % 16), "v",
                          localTs);
  };

  // --- applyRemote：基线 128 条（actor=peer），再做新操作 / 重复重放。 ----
  const std::string docRemote = "bench-crdt-remote";
  REQUIRE(JsonBool(CrdtCreate(docRemote, "bench"), "ok", true));
  for (int i = 1; i <= kRemoteBaseline; ++i) {
    REQUIRE(JsonBool(CrdtApplyRemote(docRemote, "peer", i,
                                     "baseline" + std::to_string(i % 16), "v",
                                     1000 + i),
                     "applied", true));
  }
  int remoteSeq = kRemoteBaseline;

  BENCHMARK("CRDT applyRemote 新操作（去重扫描 + 应用）") {
    remoteSeq += 1;
    return CrdtApplyRemote(docRemote, "peer", remoteSeq,
                           "k" + std::to_string(remoteSeq % 16), "v",
                           100000 + remoteSeq);
  };

  BENCHMARK("CRDT applyRemote 重复操作（重放 seq=127 去重判定）") {
    // 基线第 127 条（actor=peer, seq=127, key=baseline15, ts=1127）原样重放：
    // HasOp 扫描命中后返回 duplicate=true，日志不增长，采样成本稳定。
    return CrdtApplyRemote(docRemote, "peer", 127, "baseline15", "v", 1127);
  };

  // --- encodeUpdate：固定 256 条日志，增量导出最新 64 条。 -----------------
  const std::string docUpdate = "bench-crdt-update";
  REQUIRE(JsonBool(CrdtCreate(docUpdate, "bench"), "ok", true));
  for (int i = 1; i <= kUpdateLogSize; ++i) {
    REQUIRE(JsonBool(
                CrdtApplyLocal(docUpdate, "k" + std::to_string(i % 16), "v", i),
                "applied", true));
  }
  REQUIRE(JsonNumber(wb::invokeDomain(
                         "crdt", "encodeUpdate",
                         "{\"docId\":\"" + docUpdate + "\",\"since\":0}"),
                     "count") == static_cast<double>(kUpdateLogSize));

  BENCHMARK("CRDT encodeUpdate 增量导出（256 条日志 → 最新 64 条）") {
    return wb::invokeDomain(
        "crdt", "encodeUpdate",
        "{\"docId\":\"" + docUpdate +
            "\",\"since\":" + std::to_string(kUpdateSince) + "}");
  };
}

TEST_CASE("同步链路基准", "[bench][sync]") {
  const std::string connected =
      TakeAndFree(wb_sync_connect("ws://bench.local:9000", "bench-token"));
  REQUIRE(JsonBool(connected, "ok", true));
  REQUIRE(JsonBool(connected, "connected", true));

  // 冒烟：离线入队 → 上线排空链路可用（断言在 BENCHMARK 之外）。
  wb_free(wb_sync_set_offline(1));
  SyncSend("element.update");
  wb_free(wb_sync_set_offline(0));
  REQUIRE(JsonNumber(wb::invokeDomain("sync", "sync", "{}"), "pendingCount") ==
          0.0);

  BENCHMARK("sync.sendOperation 在线直发（单条操作提交）") {
    return SyncSend("element.update");
  };

  BENCHMARK("sync 离线批量入队 32 条 → 上线 sync 排空") {
    wb_free(wb_sync_set_offline(1));
    for (int i = 0; i < kOfflineBatch; ++i) {
      SyncSend("element.update");
    }
    wb_free(wb_sync_set_offline(0));
    return wb::invokeDomain("sync", "sync", "{}");
  };
}
