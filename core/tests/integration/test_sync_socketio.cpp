// test_sync_socketio.cpp — env-gated live round trip for the sync domain over
// the real Socket.IO transport (M1 T1.1/T1.2).
//
// Set WB_SIOXX_POC_ENDPOINT (e.g. "localhost:8790") to run against a live
// realtime service; otherwise the case SKIPs. Tagged [poc] so it joins the
// explicit "socketio POC (env-gated)" CTest entry and stays out of the
// generic discovery set (catch_discover_tests TEST_SPEC "~[poc]").
//
// Covered:
//   1. sync connect with a bare host:port (transport endpoint normalization)
//      followed by status polling until transportState == "connected";
//   2. sync join {boardId, pageId} -> joined:true;
//   3. sync sendOperation -> sent:true; the 100 ms batch is acknowledged and
//      the round trip shows up as latencyMs > 0 in status;
//   4. sync sendPreview -> sent:true (volatile; the server fans presence:*
//      out in M2/M3, so only the local send path is asserted);
//   5. a raw SocketIOTransport peer joins the same board, drains its
//      "board:joinAck", sends one op with a fresh actor id and samples its
//      own ack latency;
//   6. polling sync events until the peer op is applied through
//      crdt.applyRemote (ops array carries the peer actor) and the room
//      section carries the joinAck snapshot (participants >= 1);
//   7. teardown: peer.disconnect() + sync disconnect.
//
// Desktop-only: WASM builds do not fetch sioxx (see third_party/CMakeLists.txt).
#if !defined(__EMSCRIPTEN__)

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <catch2/catch_test_macros.hpp>

#include <nlohmann/json.hpp>

#include "../../src/sync/socketio_transport.h"

#include "support/test_probe.h"

namespace {

using namespace std::chrono_literals;

std::string GetEnv(const char* name) {
  const char* raw = std::getenv(name);
  return raw != nullptr ? std::string(raw) : std::string();
}

bool IsBlank(const std::string& value) {
  return value.find_first_not_of(" \t\r\n") == std::string::npos;
}

std::string SyncOp(const std::string& op, const std::string& args) {
  return wb::invokeDomain("sync", op, args);
}

/// Polls `done` until it returns true or the timeout expires (bounded waits).
template <typename Predicate>
bool WaitFor(Predicate done, std::chrono::milliseconds timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (!done()) {
    if (std::chrono::steady_clock::now() >= deadline) {
      return false;
    }
    std::this_thread::sleep_for(50ms);
  }
  return true;
}

/// Unique per run: the service tracks (actor, seq) continuity per actor, so a
/// fresh actor id keeps seq=1 valid across repeated runs on one service.
std::string RunTag() {
  return std::to_string(std::chrono::duration_cast<std::chrono::milliseconds>(
                            std::chrono::steady_clock::now().time_since_epoch())
                            .count());
}

/// Fresh-actor op in the §6 wire shape (actor/seq/key/value/timestamp/origin).
std::string MakeOp(const std::string& actor, const std::string& key,
                   const std::string& value, const std::string& timestamp) {
  return "{\"actor\":\"" + actor + "\",\"seq\":1,\"key\":\"" + key +
         "\",\"value\":\"" + value + "\",\"timestamp\":" + timestamp +
         ",\"origin\":\"it-sync\"}";
}

}  // namespace

TEST_CASE("sync socketio: live connect/join/sendOperation/events round trip",
          "[integration][socketio][poc]") {
  const std::string endpoint = GetEnv("WB_SIOXX_POC_ENDPOINT");
  if (endpoint.empty() || IsBlank(endpoint)) {
    SKIP("WB_SIOXX_POC_ENDPOINT is not set - skipping live sync round trip");
  }
  const std::string tag = RunTag();
  const std::string boardId = "m1-sync-live";
  std::cout << "[poc-sync] endpoint=" << endpoint << " run=" << tag
            << " board=" << boardId << std::endl;

  // --- 1) domain connect: bare host:port exercises normalization ------------
  const std::string connect = SyncOp(
      "connect",
      "{\"endpoint\":\"" + endpoint + "\",\"clientVersion\":\"it-sync-m1\"}");
  REQUIRE(JsonBool(connect, "ok", true));
  REQUIRE(JsonString(connect, "transport") == "socketio");
  REQUIRE(WaitFor(
      [&] {
        return JsonString(SyncOp("status", "{}"), "transportState") ==
               "connected";
      },
      15s));
  std::cout << "[poc-sync] transportState=connected" << std::endl;

  // --- 2) join ---------------------------------------------------------------
  const std::string join =
      SyncOp("join", "{\"boardId\":\"" + boardId + "\",\"pageId\":\"p1\"}");
  REQUIRE(JsonBool(join, "ok", true));
  REQUIRE(JsonBool(join, "joined", true));

  // --- 3) sendOperation: 100 ms batch -> server ack -> latency sample -------
  const std::string domainActor = "it-sync-dom-" + tag;
  const std::string sent = SyncOp(
      "sendOperation",
      "{\"op\":" + MakeOp(domainActor, "k-dom", "v-dom", tag) + "}");
  REQUIRE(JsonBool(sent, "ok", true));
  REQUIRE(JsonBool(sent, "sent", true));
  REQUIRE(WaitFor(
      [&] { return JsonNumber(SyncOp("status", "{}"), "latencyMs") > 0.0; },
      10s));
  std::cout << "[poc-sync] status after ack: " << SyncOp("status", "{}")
            << std::endl;

  // --- 4) sendPreview: volatile local send path ------------------------------
  const std::string preview = SyncOp(
      "sendPreview",
      "{\"preview\":{\"kind\":\"transform\",\"x\":1,\"y\":2}}");
  REQUIRE(JsonBool(preview, "ok", true));
  REQUIRE(JsonBool(preview, "sent", true));

  // --- 5) raw transport peer joins the same board and emits one op ----------
  wb::sync::SocketIOTransport peer;
  REQUIRE(peer.connectBoard(endpoint, "", boardId, "it-sync-peer"));
  REQUIRE(WaitFor(
      [&] {
        return peer.getState() == wb::reserved::TransportState::Connected;
      },
      15s));
  REQUIRE(peer.joinBoard(boardId, "p1", nlohmann::json::object()));

  bool joinAckSeen = false;
  std::vector<std::string> peerEvents;
  REQUIRE(WaitFor(
      [&] {
        for (const wb::sync::InboundEvent& event : peer.drainInbound()) {
          peerEvents.push_back(event.event);
          if (event.event == "board:joinAck") joinAckSeen = true;
        }
        return joinAckSeen;
      },
      5s));

  const std::string peerActor = "it-sync-peer-" + tag;
  REQUIRE(peer.sendReliable(
      nlohmann::json::parse(MakeOp(peerActor, "k-peer", "v-peer", tag))));
  REQUIRE(WaitFor([&] { return peer.latencyMs() > 0; }, 10s));

  // --- 6) domain events: applied op + room snapshot (drain semantics) -------
  std::string events;
  const bool applied = WaitFor(
      [&] {
        events = SyncOp("events", "{}");
        return JsonContains(events, peerActor);
      },
      15s);
  REQUIRE(applied);
  std::cout << "[poc-sync] events: " << events << std::endl;
  REQUIRE(JsonArrayLength(events, "ops") >= 1u);
  REQUIRE(JsonContains(events, "\"key\":\"k-peer\""));
  REQUIRE(JsonContains(events, "\"value\":\"v-peer\""));
  REQUIRE(JsonArrayLength(events, "participants") >= 1u);
  REQUIRE(JsonNumber(SyncOp("status", "{}"), "participants") >= 1.0);

  // Drain semantics: the op was consumed by the matching call, a fresh call
  // must not hand it out again.
  const std::string drained = SyncOp("events", "{}");
  REQUIRE_FALSE(JsonContains(drained, peerActor));

  // --- 7) teardown ------------------------------------------------------------
  peer.disconnect();
  const std::string off = SyncOp("disconnect", "{}");
  REQUIRE(JsonBool(off, "ok", true));
  REQUIRE(JsonBool(off, "connected", false));
  std::cout << "[poc-sync] DONE: domain + peer round trip verified (peer "
               "events: ";
  for (std::size_t i = 0; i < peerEvents.size(); ++i) {
    std::cout << (i == 0 ? "" : ",") << peerEvents[i];
  }
  std::cout << ")" << std::endl;
}

#endif  // !defined(__EMSCRIPTEN__)
