// tests/unit/sync/sync_test.cpp — domain "sync" (1.7 / M1 T1.1 + T1.2).
//
// catch_discover_tests runs every TEST_CASE in its own process, so the
// process-wide transport state starts fresh here each time. M1 cases install
// a synchronous FakeTransport (fake_transport.h): connectBoard succeeds and
// lands "Connected" immediately, sends are accepted and queues drain
// instantly — this keeps the pre-M1 placeholder-transport assertion
// semantics intact.

#include <cstddef>
#include <string>

#include <catch2/catch_test_macros.hpp>

#include <nlohmann/json.hpp>

#include "fake_transport.h"

#include "../support/scene_probe.h"

namespace {

using wb::sync::test::FakePushInbound;
using wb::sync::test::FakeQueueFailure;
using wb::sync::test::FakeState;
using wb::sync::test::InstallFakeTransport;

std::string Connect(const std::string& endpoint = "ws://localhost:9000") {
  return wb::invokeDomain("sync", "connect",
                          "{\"endpoint\":\"" + endpoint + "\"}");
}

std::string Status() { return wb::invokeDomain("sync", "status", "{}"); }

std::string SetOffline(bool offline) {
  return wb::invokeDomain(
      "sync", "setOffline",
      std::string("{\"offline\":") + (offline ? "true" : "false") + "}");
}

std::string Send(const std::string& opBody) {
  return wb::invokeDomain("sync", "sendOperation",
                          "{\"operation\":" + opBody + "}");
}

std::string Join(const std::string& boardId,
                 const std::string& pageId = std::string()) {
  std::string args = "{\"boardId\":\"" + boardId + "\"";
  if (!pageId.empty()) args += ",\"pageId\":\"" + pageId + "\"";
  return wb::invokeDomain("sync", "join", args + "}");
}

std::string Events() { return wb::invokeDomain("sync", "events", "{}"); }

/// Non-overlapping occurrence count (scene_probe.h has no counting probe).
int CountNeedle(const std::string& json, const std::string& needle) {
  int count = 0;
  std::size_t pos = 0;
  while ((pos = json.find(needle, pos)) != std::string::npos) {
    ++count;
    pos += needle.size();
  }
  return count;
}

}  // namespace

TEST_CASE("sync starts disconnected with an empty queue", "[sync]") {
  InstallFakeTransport();
  const std::string status = Status();
  REQUIRE(JsonBool(status, "ok", true));
  REQUIRE(JsonBool(status, "connected", false));
  REQUIRE(JsonBool(status, "offline", false));
  REQUIRE(JsonNumber(status, "pendingCount") == 0.0);
  REQUIRE(JsonNumber(status, "sentCount") == 0.0);
  REQUIRE(JsonNumber(status, "syncedCount") == 0.0);
  // D-B: the M1 transport is Socket.IO (sioxx).
  REQUIRE(JsonString(status, "transport") == "socketio");
  REQUIRE(JsonString(status, "transportState") == "disconnected");
  REQUIRE(JsonNumber(status, "latencyMs") == 0.0);
  REQUIRE(JsonNumber(status, "reconnectCount") == 0.0);
  REQUIRE(JsonNumber(status, "participants") == 0.0);
}

TEST_CASE("sync connects once and disconnects idempotently", "[sync]") {
  InstallFakeTransport();
  const std::string on = Connect();
  REQUIRE(JsonBool(on, "connected", true));
  REQUIRE(JsonString(on, "transportState") == "connected");
  REQUIRE(JsonString(Status(), "endpoint") == "ws://localhost:9000");

  const std::string duplicate = Connect("ws://other:1234");
  REQUIRE(JsonBool(duplicate, "ok", false));
  REQUIRE(JsonContains(duplicate, "Conflict"));

  const std::string noEndpoint = wb::invokeDomain("sync", "connect", "{}");
  REQUIRE(JsonBool(noEndpoint, "ok", false));
  REQUIRE(JsonContains(noEndpoint, "InvalidArgument"));

  const std::string off = wb::invokeDomain("sync", "disconnect", "{}");
  REQUIRE(JsonBool(off, "connected", false));
  REQUIRE(JsonString(off, "transportState") == "disconnected");
  const std::string again = wb::invokeDomain("sync", "disconnect", "{}");
  REQUIRE(JsonBool(again, "ok", true));
  REQUIRE(JsonBool(again, "connected", false));
}

TEST_CASE("sync sends immediately while online", "[sync]") {
  InstallFakeTransport();
  Connect();
  const std::string sent = Send("{\"kind\":\"op\",\"n\":1}");
  REQUIRE(JsonBool(sent, "sent", true));
  REQUIRE(JsonNumber(sent, "pendingCount") == 0.0);
  REQUIRE(JsonNumber(sent, "syncedCount") == 1.0);

  // The transport saw the exact op payload.
  REQUIRE(FakeState().sentOps.size() == 1u);
  REQUIRE(FakeState().sentOps[0]["kind"] == "op");
  REQUIRE(FakeState().sentOps[0]["n"] == 1);

  const std::string status = Status();
  REQUIRE(JsonNumber(status, "sentCount") == 1.0);
  REQUIRE(JsonNumber(status, "syncedCount") == 1.0);
}

TEST_CASE("sync queues operations offline and drains on sync", "[sync]") {
  InstallFakeTransport();
  Connect();
  REQUIRE(JsonBool(SetOffline(true), "offline", true));

  const std::string first = Send("{\"kind\":\"op\",\"n\":1}");
  REQUIRE(JsonBool(first, "queued", true));
  REQUIRE(JsonBool(first, "sent", false));
  REQUIRE(JsonNumber(first, "pendingCount") == 1.0);

  Send("{\"kind\":\"op\",\"n\":2}");
  const std::string queue = wb::invokeDomain("sync", "queue", "{}");
  REQUIRE(JsonNumber(queue, "pendingCount") == 2.0);

  const std::string blocked = wb::invokeDomain("sync", "sync", "{}");
  REQUIRE(JsonBool(blocked, "ok", false));
  REQUIRE(JsonContains(blocked, "Conflict"));

  REQUIRE(JsonBool(SetOffline(false), "offline", false));
  const std::string flushed = wb::invokeDomain("sync", "sync", "{}");
  REQUIRE(JsonNumber(flushed, "synced") == 2.0);
  REQUIRE(JsonNumber(flushed, "pendingCount") == 0.0);
  REQUIRE(JsonNumber(flushed, "syncedCount") == 2.0);
  REQUIRE(JsonNumber(Status(), "pendingCount") == 0.0);
}

TEST_CASE("sync defers without a transport connection", "[sync]") {
  InstallFakeTransport();
  const std::string queued = Send("{\"kind\":\"op\"}");
  REQUIRE(JsonBool(queued, "queued", true));
  REQUIRE(JsonNumber(queued, "pendingCount") == 1.0);

  const std::string blocked = wb::invokeDomain("sync", "sync", "{}");
  REQUIRE(JsonBool(blocked, "ok", false));
  REQUIRE(JsonContains(blocked, "Conflict"));

  const std::string noOp = wb::invokeDomain("sync", "sendOperation", "{}");
  REQUIRE(JsonBool(noOp, "ok", false));
  REQUIRE(JsonContains(noOp, "InvalidArgument"));
}

TEST_CASE("sync validates setOffline arguments", "[sync]") {
  InstallFakeTransport();
  const std::string missing = wb::invokeDomain("sync", "setOffline", "{}");
  REQUIRE(JsonBool(missing, "ok", false));
  REQUIRE(JsonContains(missing, "InvalidArgument"));

  const std::string bad =
      wb::invokeDomain("sync", "setOffline", "{\"offline\":\"yes\"}");
  REQUIRE(JsonBool(bad, "ok", false));

  const std::string numeric =
      wb::invokeDomain("sync", "setOffline", "{\"offline\":1}");
  REQUIRE(JsonBool(numeric, "ok", true));
  REQUIRE(JsonBool(numeric, "offline", true));
}

TEST_CASE("sync capabilities report reserved providers", "[sync]") {
  InstallFakeTransport();
  const std::string caps = wb::invokeDomain("sync", "capabilities", "{}");
  REQUIRE(JsonBool(caps, "ok", true));
  REQUIRE(JsonNumber(caps, "providerCount") == 5.0);
  REQUIRE(JsonBool(caps, "reserved", true));
  REQUIRE(JsonContains(caps, "AVProvider"));
  REQUIRE(JsonContains(caps, "InteractiveProvider"));
  REQUIRE(JsonContains(caps, "PlaybackProvider"));
  REQUIRE(JsonContains(caps, "webrtc"));
  REQUIRE(JsonContains(caps, "\"implemented\":false"));
  // D-B: the Socket.IO transport and its provider seam are live; everything
  // else stays reserved-and-false.
  REQUIRE(CountNeedle(caps, "\"implemented\":true") == 2);
  REQUIRE(JsonContains(caps, "\"type\":\"socketio\""));
}

// --- M1 additions ------------------------------------------------------------

TEST_CASE("sync surfaces transport state transitions", "[sync]") {
  InstallFakeTransport();
  REQUIRE(JsonBool(Connect(), "connected", true));

  // A link drop observed by the transport is reflected verbatim.
  FakeState().state = wb::reserved::TransportState::Reconnecting;
  const std::string reconnecting = Status();
  REQUIRE(JsonBool(reconnecting, "connected", false));
  REQUIRE(JsonString(reconnecting, "transportState") == "reconnecting");

  // Back-off exhausted: permanent failure until a fresh connect replaces it.
  FakeState().state = wb::reserved::TransportState::Failed;
  REQUIRE(JsonString(Status(), "transportState") == "failed");

  REQUIRE(JsonBool(Connect("ws://localhost:9001"), "connected", true));
  REQUIRE(JsonString(Status(), "transportState") == "connected");
  REQUIRE(FakeState().connectCalls == 2);

  const std::string off = wb::invokeDomain("sync", "disconnect", "{}");
  REQUIRE(JsonString(off, "transportState") == "disconnected");
}

TEST_CASE("sync connect failure surfaces NotSupported", "[sync]") {
  InstallFakeTransport();
  FakeState().connectSucceeds = false;
  const std::string failed = Connect();
  REQUIRE(JsonBool(failed, "ok", false));
  REQUIRE(JsonContains(failed, "NotSupported"));
  // No transport was installed: the domain stays disconnected.
  REQUIRE(JsonBool(Status(), "connected", false));
}

TEST_CASE("sync join sends board:join and validates arguments", "[sync]") {
  InstallFakeTransport();
  const std::string early = Join("board-1");
  REQUIRE(JsonBool(early, "ok", false));
  REQUIRE(JsonContains(early, "not connected"));

  REQUIRE(JsonBool(Connect(), "connected", true));
  const std::string missing = wb::invokeDomain("sync", "join", "{}");
  REQUIRE(JsonBool(missing, "ok", false));
  REQUIRE(JsonContains(missing, "InvalidArgument"));

  const std::string joined = Join("board-1", "page-7");
  REQUIRE(JsonBool(joined, "joined", true));
  REQUIRE(JsonString(joined, "boardId") == "board-1");
  REQUIRE(JsonString(joined, "pageId") == "page-7");
  REQUIRE(FakeState().joinCalls == 1);
  REQUIRE(FakeState().lastJoinedBoard == "board-1");
  REQUIRE(FakeState().lastJoinedPage == "page-7");

  // Offline mode defers joins even while connected.
  REQUIRE(JsonBool(SetOffline(true), "offline", true));
  const std::string deferred = Join("board-2");
  REQUIRE(JsonBool(deferred, "ok", false));
  REQUIRE(JsonContains(deferred, "offline"));
}

TEST_CASE("sync events drain ops, previews and room state", "[sync]") {
  InstallFakeTransport();
  REQUIRE(JsonBool(Connect(), "connected", true));
  REQUIRE(JsonBool(Join("board-events", "page-1"), "joined", true));

  // Remote ops (applied through crdt.applyRemote with the joined board as
  // docId — the document is lazily created on first contact).
  const nlohmann::json op1 = nlohmann::json::object(
      {{"actor", "ra"}, {"seq", 1}, {"key", "k1"}, {"value", "v1"},
       {"timestamp", 1000}});
  const nlohmann::json op2 = nlohmann::json::object(
      {{"actor", "rb"}, {"seq", 2}, {"key", "k2"}, {"value", "v2"},
       {"timestamp", 2000}});
  FakePushInbound("board:ops", nlohmann::json::array({op1, op2}));
  FakePushInbound("presence:preview",
                  nlohmann::json::object({{"kind", "transform"}, {"x", 5}}));
  FakePushInbound("board:joined",
                  nlohmann::json::object(
                      {{"ok", true},
                       {"participants", nlohmann::json::array({"u1", "u2"})},
                       {"mode", "free"}}));

  const std::string events = Events();
  REQUIRE(JsonBool(events, "ok", true));
  REQUIRE(JsonContains(events, "\"key\":\"k1\""));
  REQUIRE(JsonContains(events, "\"key\":\"k2\""));
  REQUIRE(JsonContains(events, "\"kind\":\"transform\""));
  REQUIRE(JsonContains(events, "\"participants\":[\"u1\",\"u2\"]"));
  REQUIRE(JsonContains(events, "\"mode\":\"free\""));

  // The ops landed in the crdt document keyed by the board id (D-D).
  const std::string state = wb::invokeDomain(
      "crdt", "encodeState", "{\"docId\":\"board-events\"}");
  REQUIRE(JsonNumber(state, "keyCount") == 2.0);

  // Drain semantics: the next call is empty, but the room is cached.
  const std::string drained = Events();
  REQUIRE(JsonContains(drained, "\"ops\":[]"));
  REQUIRE(JsonContains(drained, "\"previews\":[]"));
  REQUIRE(JsonContains(drained, "\"participants\":[\"u1\",\"u2\"]"));

  // A replayed (actor, seq) is filtered out: crdt reports applied=false.
  FakePushInbound("board:ops", nlohmann::json::array({op1}));
  REQUIRE(JsonContains(Events(), "\"ops\":[]"));
}

TEST_CASE("sync tracks session identity and participant deltas", "[sync]") {
  InstallFakeTransport();
  REQUIRE(JsonBool(Connect(), "connected", true));
  REQUIRE(JsonBool(Join("board-people"), "joined", true));

  // Own join snapshot + handshake identity: room.selfUserId pinpoints the
  // local member (the UI marks "me" by it instead of roster order).
  const nlohmann::json me = nlohmann::json::object(
      {{"userId", "anon-me"}, {"socketId", "s-me"}, {"role", "Participant"}});
  FakePushInbound("board:joined",
                  nlohmann::json::object(
                      {{"ok", true},
                       {"participants", nlohmann::json::array({me})},
                       {"mode", "free"}}));
  FakePushInbound("board:session",
                  nlohmann::json::object(
                      {{"userId", "anon-me"}, {"authMode", "anonymous"}}));

  std::string events = Events();
  REQUIRE(JsonContains(events, "\"selfUserId\":\"anon-me\""));
  REQUIRE(JsonNumber(Status(), "participants") == 1.0);

  // Another member joins: the delta appends to the cached roster — this is
  // the "A never sees B" fix; the status count and room snapshot move
  // together with it.
  const nlohmann::json peer = nlohmann::json::object(
      {{"userId", "anon-peer"},
       {"socketId", "s-peer4"},
       {"role", "Participant"}});
  FakePushInbound(
      "board:participants",
      nlohmann::json::object({{"joined", nlohmann::json::array({peer})}}));
  events = Events();
  REQUIRE(JsonNumber(Status(), "participants") == 2.0);
  REQUIRE(JsonContains(events, "\"userId\":\"anon-peer\""));

  // A duplicate delta (same socketId) must not double-count.
  FakePushInbound(
      "board:participants",
      nlohmann::json::object({{"joined", nlohmann::json::array({peer})}}));
  Events();
  REQUIRE(JsonNumber(Status(), "participants") == 2.0);

  // The peer leaves: the delta removes it by socketId.
  FakePushInbound(
      "board:participants",
      nlohmann::json::object({{"left", nlohmann::json::array({peer})}}));
  events = Events();
  REQUIRE(JsonNumber(Status(), "participants") == 1.0);
  REQUIRE(CountNeedle(events, "\"userId\":\"anon-peer\"") == 0);

  // Identity survives a board re-join within the session.
  REQUIRE(JsonBool(Join("board-other"), "joined", true));
  REQUIRE(JsonContains(Events(), "\"selfUserId\":\"anon-me\""));

  // ...but dies with the session (disconnect resets identity and room).
  const std::string off = wb::invokeDomain("sync", "disconnect", "{}");
  REQUIRE(JsonBool(off, "connected", false));
  REQUIRE(JsonContains(Events(), "\"selfUserId\":\"\""));
}

TEST_CASE("sync sendOperation accepts the op key and validates payloads",
          "[sync]") {
  InstallFakeTransport();
  REQUIRE(JsonBool(Connect(), "connected", true));

  const std::string sent = wb::invokeDomain(
      "sync", "sendOperation",
      "{\"op\":{\"actor\":\"a\",\"seq\":1,\"key\":\"k\",\"value\":1}}");
  REQUIRE(JsonBool(sent, "sent", true));
  REQUIRE(FakeState().sentOps.size() == 1u);
  REQUIRE(FakeState().sentOps[0]["key"] == "k");

  const std::string emptyOp =
      wb::invokeDomain("sync", "sendOperation", "{\"op\":{}}");
  REQUIRE(JsonBool(emptyOp, "ok", false));
  REQUIRE(JsonContains(emptyOp, "InvalidArgument"));
}

TEST_CASE("sync sendPreview is best-effort and validated", "[sync]") {
  InstallFakeTransport();

  const std::string missing = wb::invokeDomain("sync", "sendPreview", "{}");
  REQUIRE(JsonBool(missing, "ok", false));
  REQUIRE(JsonContains(missing, "InvalidArgument"));

  const std::string noKind =
      wb::invokeDomain("sync", "sendPreview", "{\"preview\":{\"x\":1}}");
  REQUIRE(JsonBool(noKind, "ok", false));

  // No transport yet: previews are droppable by design.
  const std::string dropped = wb::invokeDomain(
      "sync", "sendPreview", "{\"preview\":{\"kind\":\"transform\",\"x\":1}}");
  REQUIRE(JsonBool(dropped, "ok", true));
  REQUIRE(JsonBool(dropped, "dropped", true));

  // Connected: the transport owns the hysteresis slot.
  REQUIRE(JsonBool(Connect(), "connected", true));
  const std::string sent = wb::invokeDomain(
      "sync", "sendPreview", "{\"preview\":{\"kind\":\"transform\",\"x\":2}}");
  REQUIRE(JsonBool(sent, "sent", true));
  REQUIRE(FakeState().sentPreviews.size() == 1u);

  // A refused preview is reported as dropped.
  FakeState().previewAccepted = false;
  const std::string refused = wb::invokeDomain(
      "sync", "sendPreview", "{\"preview\":{\"kind\":\"ink\",\"p\":1}}");
  REQUIRE(JsonBool(refused, "dropped", true));

  // Offline mode drops previews even while connected.
  FakeState().previewAccepted = true;
  REQUIRE(JsonBool(SetOffline(true), "offline", true));
  const std::string offline = wb::invokeDomain(
      "sync", "sendPreview", "{\"preview\":{\"kind\":\"ink\",\"p\":2}}");
  REQUIRE(JsonBool(offline, "dropped", true));
}

TEST_CASE("sync reclaims failed deliveries into the pending queue", "[sync]") {
  InstallFakeTransport();
  REQUIRE(JsonBool(Connect(), "connected", true));

  // The transport exhausted its 3 s x3 resend budget: the op lands in the
  // failure list and the next domain call reclaims it into `pending`.
  const nlohmann::json op =
      nlohmann::json::object({{"actor", "ra"}, {"seq", 9}});
  FakeQueueFailure(op);
  REQUIRE(JsonNumber(Status(), "pendingCount") == 1.0);

  // Reclaimed ops are older than locally queued ones: they go to the front.
  REQUIRE(JsonBool(SetOffline(true), "offline", true));
  const std::string queued = Send("{\"kind\":\"op\",\"n\":1}");
  REQUIRE(JsonNumber(queued, "pendingCount") == 2.0);

  const std::string queue = wb::invokeDomain("sync", "queue", "{}");
  const std::size_t failedPos = queue.find("\"seq\":9");
  const std::size_t queuedPos = queue.find("\"n\":1");
  REQUIRE(failedPos != std::string::npos);
  REQUIRE(queuedPos != std::string::npos);
  REQUIRE(failedPos < queuedPos);
}

TEST_CASE("sync disconnect reclaims unacknowledged work", "[sync]") {
  InstallFakeTransport();
  REQUIRE(JsonBool(Connect(), "connected", true));
  const std::string sent = Send("{\"kind\":\"op\",\"n\":7}");
  REQUIRE(JsonBool(sent, "sent", true));

  // The transport reports the op as unacknowledged during teardown; the
  // disconnect flow keeps it in `pending` (nothing is silently dropped).
  FakeQueueFailure(nlohmann::json::object({{"kind", "op"}, {"n", 7}}));
  const std::string off = wb::invokeDomain("sync", "disconnect", "{}");
  REQUIRE(JsonBool(off, "connected", false));
  REQUIRE(JsonNumber(off, "pendingCount") == 1.0);

  // A later reconnect drains the queue through the fresh transport.
  REQUIRE(JsonBool(Connect(), "connected", true));
  const std::string flushed = wb::invokeDomain("sync", "sync", "{}");
  REQUIRE(JsonNumber(flushed, "synced") == 1.0);
  REQUIRE(JsonNumber(flushed, "pendingCount") == 0.0);
}
