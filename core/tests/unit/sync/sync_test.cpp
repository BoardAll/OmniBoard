// tests/unit/sync/sync_test.cpp — domain "sync" (1.7 / M1 T1.1 + T1.2 /
// M2 T2b / M3 T3.2 + T3.5).
//
// catch_discover_tests runs every TEST_CASE in its own process, so the
// process-wide transport state starts fresh here each time. M1 cases install
// a synchronous FakeTransport (fake_transport.h): connectBoard succeeds and
// lands "Connected" immediately, sends are accepted and queues drain
// instantly — this keeps the pre-M1 placeholder-transport assertion
// semantics intact. M2 cases add the software-lock pass-through (D2-C) and
// the passive-reconnect recovery: watermark advance / re-join / pull-before-
// push (D2-D). M3 cases add the interactive channel (T3.2: the `interactive`
// forward, ack / room-state folds) and the checkpoint engine side (T3.5:
// board:checkpointRequest -> encodeState -> board:checkpoint, plus the
// guarded join-snapshot restore).

#include <cstddef>
#include <string>

#include <catch2/catch_test_macros.hpp>

#include <nlohmann/json.hpp>

#include "fake_transport.h"

#include "../support/scene_probe.h"

namespace {

using wb::sync::InteractiveWireEvent;
using wb::sync::InteractiveWireField;
using wb::sync::test::FakePushInbound;
using wb::sync::test::FakeQueueCheckpointReply;
using wb::sync::test::FakeQueueFailure;
using wb::sync::test::FakeQueueInteractiveReply;
using wb::sync::test::FakeQueueLockReply;
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

std::string Lock(const std::string& action, const std::string& elementId) {
  return wb::invokeDomain("sync", "lock",
                          "{\"action\":\"" + action + "\",\"elementId\":\"" +
                              elementId + "\"}");
}

std::string Interactive(const std::string& argsBody) {
  return wb::invokeDomain("sync", "interactive", argsBody);
}

/// Valid crdt op (unique key per seq) for inbound replay / watermark tests.
nlohmann::json MakeRemoteOp(const std::string& actor, int seq,
                            const std::string& key) {
  return nlohmann::json::object({{"actor", actor},
                                 {"seq", seq},
                                 {"key", key},
                                 {"value", "v" + std::to_string(seq)},
                                 {"timestamp", 1000 + seq}});
}

/// One passive drop → auto-reconnect cycle: observe Reconnecting, then the
/// Connected edge (which auto re-joins); returns the re-join watermark.
nlohmann::json RejoinWatermark() {
  FakeState().state = wb::reserved::TransportState::Reconnecting;
  Events();  // observe the drop
  FakeState().state = wb::reserved::TransportState::Connected;
  Events();  // edge -> automatic re-join
  return FakeState().joinWatermarks.back();
}

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
  // The first join carries an empty watermark (full-replay semantics).
  REQUIRE(FakeState().joinWatermarks.size() == 1u);
  REQUIRE(FakeState().joinWatermarks[0].empty());

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

// --- M2 additions ------------------------------------------------------------

TEST_CASE("sync lock op validates and forwards to the transport", "[sync]") {
  InstallFakeTransport();

  // Argument validation first: action and elementId are both required and
  // the action set is closed.
  const std::string noAction =
      wb::invokeDomain("sync", "lock", "{\"elementId\":\"e1\"}");
  REQUIRE(JsonBool(noAction, "ok", false));
  REQUIRE(JsonContains(noAction, "InvalidArgument"));

  const std::string noElement =
      wb::invokeDomain("sync", "lock", "{\"action\":\"acquire\"}");
  REQUIRE(JsonBool(noElement, "ok", false));
  REQUIRE(JsonContains(noElement, "InvalidArgument"));

  const std::string badAction = wb::invokeDomain(
      "sync", "lock", "{\"action\":\"steal\",\"elementId\":\"e1\"}");
  REQUIRE(JsonBool(badAction, "ok", false));
  REQUIRE(JsonContains(badAction, "InvalidArgument"));

  // No transport: the request degrades quietly (never Conflict).
  const std::string offline0 = Lock("acquire", "e1");
  REQUIRE(JsonBool(offline0, "ok", true));
  REQUIRE(JsonBool(offline0, "requested", false));
  REQUIRE(FakeState().sentLocks.empty());

  REQUIRE(JsonBool(Connect(), "connected", true));

  // Offline mode defers lock requests the same way.
  REQUIRE(JsonBool(SetOffline(true), "offline", true));
  REQUIRE(JsonBool(Lock("acquire", "e1"), "requested", false));
  REQUIRE(FakeState().sentLocks.empty());
  REQUIRE(JsonBool(SetOffline(false), "offline", false));

  // Online: forwarded verbatim as {action, elementId}.
  const std::string acquire = Lock("acquire", "e1");
  REQUIRE(JsonBool(acquire, "ok", true));
  REQUIRE(JsonBool(acquire, "requested", true));
  REQUIRE(FakeState().sentLocks.size() == 1u);
  REQUIRE(FakeState().sentLocks[0]["action"] == "acquire");
  REQUIRE(FakeState().sentLocks[0]["elementId"] == "e1");

  REQUIRE(JsonBool(Lock("renew", "e1"), "requested", true));
  REQUIRE(JsonBool(Lock("release", "e1"), "requested", true));
  REQUIRE(FakeState().sentLocks.size() == 3u);
  REQUIRE(FakeState().sentLocks[1]["action"] == "renew");
  REQUIRE(FakeState().sentLocks[2]["action"] == "release");

  // A dropped link refuses the request without touching the transport.
  FakeState().state = wb::reserved::TransportState::Reconnecting;
  REQUIRE(JsonBool(Lock("acquire", "e3"), "requested", false));
  REQUIRE(FakeState().sentLocks.size() == 3u);
  FakeState().state = wb::reserved::TransportState::Connected;

  // A transport-side refusal (race) degrades the same way.
  FakeState().lockAccepted = false;
  const std::string refused = Lock("acquire", "e2");
  REQUIRE(JsonBool(refused, "ok", true));
  REQUIRE(JsonBool(refused, "requested", false));
  REQUIRE(FakeState().sentLocks.size() == 3u);
}

TEST_CASE("sync events fold lock acks and lock:changed into the room",
          "[sync]") {
  InstallFakeTransport();
  REQUIRE(JsonBool(Connect(), "connected", true));
  REQUIRE(JsonBool(Join("board-locks", "page-1"), "joined", true));

  // Two preloaded acks (granted + denied): the fake injects them as
  // lock:reply the moment the domain forwards each request.
  FakeQueueLockReply(nlohmann::json::object(
      {{"ok", true}, {"granted", true}, {"elementId", "e1"},
       {"expiresAt", 123}}));
  REQUIRE(JsonBool(Lock("acquire", "e1"), "requested", true));
  FakeQueueLockReply(nlohmann::json::object(
      {{"ok", true}, {"granted", false}, {"holderUserId", "u9"}}));
  REQUIRE(JsonBool(Lock("acquire", "e2"), "requested", true));

  // Another member's lock broadcast lands in the same drain.
  FakePushInbound("lock:changed",
                  nlohmann::json::object({{"elementId", "e2"},
                                          {"userId", "u2"},
                                          {"action", "acquired"},
                                          {"expiresAt", 5000}}));

  const std::string events = Events();
  REQUIRE(JsonBool(events, "ok", true));
  // Ack passthrough, in request order (drain semantics: surfaced once).
  REQUIRE(JsonContains(
      events,
      "\"lockAcks\":[{\"elementId\":\"e1\",\"expiresAt\":123,"
      "\"granted\":true,\"ok\":true},"
      "{\"granted\":false,\"holderUserId\":\"u9\",\"ok\":true}]"));
  // Broadcast folded into the object-map lock table.
  REQUIRE(JsonContains(
      events, "\"locks\":{\"e2\":{\"expiresAt\":5000,\"userId\":\"u2\"}}"));

  // Drain semantics: the next call carries no acks, the lock stays cached.
  const std::string drained = Events();
  REQUIRE(JsonContains(drained, "\"lockAcks\":[]"));
  REQUIRE(JsonContains(drained, "\"locks\":{\"e2\":"));

  // released removes the entry.
  FakePushInbound("lock:changed",
                  nlohmann::json::object({{"elementId", "e2"},
                                          {"userId", "u2"},
                                          {"action", "released"}}));
  REQUIRE(JsonContains(Events(), "\"locks\":{}"));

  // acquired then expired (TTL) also nets out to an empty table.
  FakePushInbound("lock:changed",
                  nlohmann::json::object({{"elementId", "e1"},
                                          {"userId", "u1"},
                                          {"action", "acquired"},
                                          {"expiresAt", 9000}}));
  REQUIRE(JsonContains(
      Events(), "\"locks\":{\"e1\":{\"expiresAt\":9000,\"userId\":\"u1\"}}"));
  FakePushInbound("lock:changed",
                  nlohmann::json::object({{"elementId", "e1"},
                                          {"userId", "u1"},
                                          {"action", "expired"}}));
  REQUIRE(JsonContains(Events(), "\"locks\":{}"));
}

TEST_CASE("sync watermark tracks contiguous seqs across gaps and replays",
          "[sync]") {
  InstallFakeTransport();
  REQUIRE(JsonBool(Connect(), "connected", true));
  REQUIRE(JsonBool(Join("board-wm", "page-1"), "joined", true));
  REQUIRE(FakeState().joinWatermarks.size() == 1u);
  REQUIRE(FakeState().joinWatermarks[0].empty());

  // Contiguous run: 1..3 advance the watermark to 3.
  FakePushInbound("board:ops", nlohmann::json::array(
      {MakeRemoteOp("ra", 1, "k1"), MakeRemoteOp("ra", 2, "k2"),
       MakeRemoteOp("ra", 3, "k3")}));
  Events();
  REQUIRE(RejoinWatermark().value("ra", 0) == 3);

  // Gap: 5 parks in the pending set while 4 is missing.
  FakePushInbound("board:ops", nlohmann::json::array(
      {MakeRemoteOp("ra", 5, "k5")}));
  Events();
  REQUIRE(RejoinWatermark().value("ra", 0) == 3);

  // Out-of-order fill: 4 closes the gap and absorbs the buffered 5.
  FakePushInbound("board:ops", nlohmann::json::array(
      {MakeRemoteOp("ra", 4, "k4")}));
  Events();
  REQUIRE(RejoinWatermark().value("ra", 0) == 5);

  // Replay of 5 (crdt duplicate): ignored, the watermark stays put.
  FakePushInbound("board:ops", nlohmann::json::array(
      {MakeRemoteOp("ra", 5, "k5")}));
  Events();
  REQUIRE(RejoinWatermark().value("ra", 0) == 5);

  // One initial join + one re-join per stage.
  REQUIRE(FakeState().joinWatermarks.size() == 5u);
}

TEST_CASE("sync rejoins after a passive reconnect and holds the backlog",
          "[sync]") {
  InstallFakeTransport();
  REQUIRE(JsonBool(Connect(), "connected", true));
  REQUIRE(JsonBool(Join("board-rejoin", "page-2"), "joined", true));
  REQUIRE(FakeState().joinCalls == 1);
  REQUIRE(FakeState().joinWatermarks[0].empty());

  // One op goes out online before the drop; it advances the own watermark.
  const std::string first = Send(
      "{\"actor\":\"me\",\"seq\":1,\"key\":\"k1\",\"value\":\"v1\","
      "\"timestamp\":1000}");
  REQUIRE(JsonBool(first, "sent", true));
  REQUIRE(FakeState().sentOps.size() == 1u);

  // Passive drop, then recovery: the Reconnecting→Connected edge re-joins
  // with the watermark (own actor at seq 1).
  FakeState().state = wb::reserved::TransportState::Reconnecting;
  Events();  // observe the drop
  FakeState().state = wb::reserved::TransportState::Connected;
  const std::string reconnectEvents = Events();
  REQUIRE(JsonBool(reconnectEvents, "ok", true));
  REQUIRE(FakeState().joinCalls == 2);
  REQUIRE(FakeState().lastJoinedBoard == "board-rejoin");
  REQUIRE(FakeState().lastJoinedPage == "page-2");
  REQUIRE(FakeState().joinWatermarks.size() == 2u);
  REQUIRE(FakeState().joinWatermarks[1].value("me", 0) == 1);

  // Pull-before-push: while the replay is in flight, new ops queue instead
  // of going out.
  const std::string held = Send(
      "{\"actor\":\"me\",\"seq\":2,\"key\":\"k2\",\"value\":\"v2\","
      "\"timestamp\":2000}");
  REQUIRE(JsonBool(held, "queued", true));
  REQUIRE(JsonBool(held, "sent", false));
  REQUIRE(JsonNumber(held, "pendingCount") == 1.0);
  REQUIRE(FakeState().sentOps.size() == 1u);  // only the pre-drop op

  // The re-join replay lands (joined → ops): the hold clears and the
  // backlog is flushed strictly after the replayed delta.
  FakePushInbound("board:joined",
                  nlohmann::json::object(
                      {{"ok", true},
                       {"participants", nlohmann::json::array()},
                       {"mode", "free"}}));
  FakePushInbound("board:ops",
                  nlohmann::json::array({MakeRemoteOp("ra", 1, "kr")}));
  const std::string replayEvents = Events();
  REQUIRE(JsonContains(replayEvents, "\"key\":\"kr\""));
  REQUIRE(JsonNumber(replayEvents, "pendingCount") == 0.0);
  REQUIRE(JsonNumber(replayEvents, "syncedCount") == 2.0);
  REQUIRE(FakeState().sentOps.size() == 2u);
  REQUIRE(FakeState().sentOps[1]["seq"] == 2);

  // Both actors now sit in the watermark: the flushed own op and the
  // replayed delta.
  const nlohmann::json finalWatermark = RejoinWatermark();
  REQUIRE(finalWatermark.value("me", 0) == 2);
  REQUIRE(finalWatermark.value("ra", 0) == 1);
}

// --- M3 additions (T3.2 interactive / T3.5 checkpoint) -----------------------

TEST_CASE("sync interactive op validates and forwards actions", "[sync]") {
  InstallFakeTransport();

  // The action -> wire-event mapping is the single source of truth shared by
  // the real transport, the fake and this test.
  REQUIRE(std::string(InteractiveWireEvent("raiseHand")) ==
          "interactive:raiseHand");
  REQUIRE(std::string(InteractiveWireEvent("lowerHand")) ==
          "interactive:lowerHand");
  REQUIRE(std::string(InteractiveWireEvent("startPresent")) ==
          "interactive:startPresent");
  REQUIRE(std::string(InteractiveWireEvent("stopPresent")) ==
          "interactive:stopPresent");
  REQUIRE(std::string(InteractiveWireEvent("grantControl")) ==
          "interactive:grantControl");
  REQUIRE(std::string(InteractiveWireEvent("revokeControl")) ==
          "interactive:revokeControl");
  REQUIRE(std::string(InteractiveWireEvent("removeUser")) ==
          "interactive:removeUser");
  REQUIRE(std::string(InteractiveWireEvent("follow")) ==
          "interactive:follow");
  REQUIRE(std::string(InteractiveWireEvent("unfollow")) ==
          "interactive:unfollow");
  REQUIRE(std::string(InteractiveWireEvent("steal")) == "");

  REQUIRE(std::string(InteractiveWireField("grantControl")) == "userId");
  REQUIRE(std::string(InteractiveWireField("revokeControl")) == "userId");
  REQUIRE(std::string(InteractiveWireField("removeUser")) == "userId");
  REQUIRE(std::string(InteractiveWireField("follow")) == "targetUserId");
  REQUIRE(std::string(InteractiveWireField("unfollow")) == "targetUserId");
  REQUIRE(std::string(InteractiveWireField("raiseHand")).empty());
  REQUIRE(InteractiveWireField("steal") == nullptr);

  // Validation first: action and the per-action extra field are required.
  const std::string noAction = Interactive("{}");
  REQUIRE(JsonBool(noAction, "ok", false));
  REQUIRE(JsonContains(noAction, "InvalidArgument"));

  const std::string badAction = Interactive("{\"action\":\"steal\"}");
  REQUIRE(JsonBool(badAction, "ok", false));
  REQUIRE(JsonContains(badAction, "InvalidArgument"));
  REQUIRE(JsonContains(badAction, "raiseHand|lowerHand"));

  const std::string noUser = Interactive("{\"action\":\"grantControl\"}");
  REQUIRE(JsonBool(noUser, "ok", false));
  REQUIRE(JsonContains(noUser, "InvalidArgument"));

  const std::string noTarget = Interactive("{\"action\":\"follow\"}");
  REQUIRE(JsonBool(noTarget, "ok", false));
  REQUIRE(JsonContains(noTarget, "InvalidArgument"));

  // No transport: the request degrades quietly (never Conflict).
  const std::string early = Interactive("{\"action\":\"raiseHand\"}");
  REQUIRE(JsonBool(early, "ok", true));
  REQUIRE(JsonBool(early, "requested", false));
  REQUIRE(FakeState().sentInteractives.empty());

  REQUIRE(JsonBool(Connect(), "connected", true));

  // Offline mode defers interactive requests the same way.
  REQUIRE(JsonBool(SetOffline(true), "offline", true));
  REQUIRE(JsonBool(Interactive("{\"action\":\"raiseHand\"}"), "requested",
                   false));
  REQUIRE(FakeState().sentInteractives.empty());
  REQUIRE(JsonBool(SetOffline(false), "offline", false));

  // Online: every action maps onto its exact wire payload.
  REQUIRE(JsonBool(Interactive("{\"action\":\"raiseHand\"}"), "requested",
                   true));
  REQUIRE(JsonBool(Interactive("{\"action\":\"lowerHand\"}"), "requested",
                   true));
  REQUIRE(JsonBool(Interactive("{\"action\":\"startPresent\"}"), "requested",
                   true));
  REQUIRE(JsonBool(Interactive("{\"action\":\"stopPresent\"}"), "requested",
                   true));
  REQUIRE(JsonBool(
      Interactive("{\"action\":\"grantControl\",\"userId\":\"u5\"}"),
      "requested", true));
  REQUIRE(JsonBool(
      Interactive("{\"action\":\"revokeControl\",\"userId\":\"u6\"}"),
      "requested", true));
  REQUIRE(JsonBool(
      Interactive("{\"action\":\"removeUser\",\"userId\":\"u7\"}"),
      "requested", true));
  REQUIRE(JsonBool(
      Interactive("{\"action\":\"follow\",\"targetUserId\":\"u8\"}"),
      "requested", true));
  REQUIRE(JsonBool(
      Interactive("{\"action\":\"unfollow\",\"targetUserId\":\"u9\"}"),
      "requested", true));

  REQUIRE(FakeState().sentInteractives.size() == 9u);
  const std::vector<nlohmann::json>& sent = FakeState().sentInteractives;
  REQUIRE(sent[0]["action"] == "raiseHand");
  REQUIRE(sent[0].count("userId") == 0u);
  REQUIRE(sent[0].count("targetUserId") == 0u);
  REQUIRE(sent[1]["action"] == "lowerHand");
  REQUIRE(sent[2]["action"] == "startPresent");
  REQUIRE(sent[3]["action"] == "stopPresent");
  REQUIRE(sent[4]["action"] == "grantControl");
  REQUIRE(sent[4]["userId"] == "u5");
  REQUIRE(sent[5]["action"] == "revokeControl");
  REQUIRE(sent[5]["userId"] == "u6");
  REQUIRE(sent[6]["action"] == "removeUser");
  REQUIRE(sent[6]["userId"] == "u7");
  REQUIRE(sent[7]["action"] == "follow");
  REQUIRE(sent[7]["targetUserId"] == "u8");
  REQUIRE(sent[7].count("userId") == 0u);
  REQUIRE(sent[8]["action"] == "unfollow");
  REQUIRE(sent[8]["targetUserId"] == "u9");

  // A dropped link refuses the request without touching the transport.
  FakeState().state = wb::reserved::TransportState::Reconnecting;
  REQUIRE(JsonBool(Interactive("{\"action\":\"raiseHand\"}"), "requested",
                   false));
  REQUIRE(FakeState().sentInteractives.size() == 9u);
  FakeState().state = wb::reserved::TransportState::Connected;

  // A transport-side refusal (race) degrades the same way: the request
  // surface stays {requested}, never an error.
  FakeState().interactiveAccepted = false;
  const std::string refused = Interactive("{\"action\":\"raiseHand\"}");
  REQUIRE(JsonBool(refused, "ok", true));
  REQUIRE(JsonBool(refused, "requested", false));
  REQUIRE(FakeState().sentInteractives.size() == 9u);
}

TEST_CASE("sync events fold interactive state and acks", "[sync]") {
  InstallFakeTransport();
  REQUIRE(JsonBool(Connect(), "connected", true));
  REQUIRE(JsonBool(Join("board-int", "page-1"), "joined", true));

  // Join snapshot + handshake identity: own role / mode land in the room.
  FakePushInbound(
      "board:joined",
      nlohmann::json::object(
          {{"ok", true},
           {"participants",
            nlohmann::json::array({nlohmann::json::object(
                {{"userId", "anon-me"},
                 {"socketId", "s-me"},
                 {"role", "Participant"}})})},
           {"mode", "free"},
           {"role", "Participant"}}));
  FakePushInbound("board:session",
                  nlohmann::json::object({{"userId", "anon-me"}}));

  // Two preloaded acks (granted + denied): the fake injects them as
  // interactive:reply the moment the domain forwards each request.
  FakeQueueInteractiveReply(nlohmann::json::object({{"ok", true}}));
  REQUIRE(JsonBool(Interactive("{\"action\":\"raiseHand\"}"), "requested",
                   true));
  FakeQueueInteractiveReply(nlohmann::json::object(
      {{"ok", false}, {"reason", "notAllowed"}}));
  REQUIRE(JsonBool(Interactive("{\"action\":\"startPresent\"}"), "requested",
                   true));

  std::string events = Events();
  REQUIRE(JsonBool(events, "ok", true));
  REQUIRE(JsonContains(
      events,
      "\"interactiveAcks\":[{\"action\":\"raiseHand\",\"ok\":true},"
      "{\"action\":\"startPresent\",\"ok\":false,\"reason\":"
      "\"notAllowed\"}]"));
  REQUIRE(JsonContains(events, "\"selfRole\":\"Participant\""));
  REQUIRE(JsonContains(events, "\"mode\":\"free\""));
  REQUIRE(JsonContains(events, "\"selfUserId\":\"anon-me\""));

  // Drain semantics: the next call carries no acks; the room stays cached.
  const std::string drained = Events();
  REQUIRE(JsonContains(drained, "\"interactiveAcks\":[]"));

  // roleChanged is a unicast: the own role updates, other targets ignore.
  FakePushInbound("interactive:roleChanged",
                  nlohmann::json::object(
                      {{"userId", "anon-me"}, {"role", "Writer"}}));
  FakePushInbound("interactive:roleChanged",
                  nlohmann::json::object(
                      {{"userId", "anon-other"}, {"role", "Ghost"}}));
  // modeChanged pins the presenter; hostChanged moves the host.
  FakePushInbound("interactive:modeChanged",
                  nlohmann::json::object(
                      {{"mode", "present"}, {"by", "anon-me"}}));
  FakePushInbound("interactive:hostChanged",
                  nlohmann::json::object({{"newHostId", "anon-h9"}}));
  // Follow dynamics: only this target's own incoming events count.
  FakePushInbound(
      "interactive:follow",
      nlohmann::json::object(
          {{"followerUserId", "f1"}, {"targetUserId", "anon-me"}}));
  FakePushInbound(
      "interactive:follow",
      nlohmann::json::object(
          {{"followerUserId", "f2"}, {"targetUserId", "anon-x"}}));
  FakePushInbound(
      "interactive:unfollow",
      nlohmann::json::object(
          {{"followerUserId", "f1"}, {"targetUserId", "anon-me"}}));
  // The server removed this client from the room.
  FakePushInbound("room:removed",
                  nlohmann::json::object({{"reason", "kicked"}}));

  events = Events();
  REQUIRE(JsonContains(events, "\"selfRole\":\"Writer\""));
  REQUIRE(!JsonContains(events, "\"Ghost\""));
  REQUIRE(JsonContains(events, "\"mode\":\"present\""));
  REQUIRE(JsonContains(events, "\"presenterId\":\"anon-me\""));
  REQUIRE(JsonContains(events, "\"hostUserId\":\"anon-h9\""));
  REQUIRE(JsonContains(
      events,
      "\"incomingFollows\":[{\"action\":\"follow\","
      "\"followerUserId\":\"f1\"},{\"action\":\"unfollow\","
      "\"followerUserId\":\"f1\"}]"));
  REQUIRE(!JsonContains(events, "\"f2\""));
  REQUIRE(JsonContains(events, "\"removed\":{\"reason\":\"kicked\"}"));

  // A present session ending clears the presenter pin; the removal notice
  // drains once.
  FakePushInbound("interactive:modeChanged",
                  nlohmann::json::object({{"mode", "free"}}));
  events = Events();
  REQUIRE(JsonContains(events, "\"presenterId\":\"\""));
  REQUIRE(JsonContains(events, "\"removed\":{}"));

  // grantedWrite rides on participant updates and mirrors at room level.
  FakePushInbound(
      "board:participants",
      nlohmann::json::object(
          {{"updated", nlohmann::json::array({nlohmann::json::object(
                           {{"socketId", "s-me"}, {"grantedWrite", true}})})}}));
  const nlohmann::json granted =
      nlohmann::json::parse(Events(), nullptr, false);
  REQUIRE(granted["result"]["room"]["grantedWrite"] == true);
  REQUIRE(granted["result"]["room"]["participants"][0]["grantedWrite"] ==
          true);
  REQUIRE(granted["result"]["status"]["participants"] == 1);

  FakePushInbound(
      "board:participants",
      nlohmann::json::object(
          {{"updated", nlohmann::json::array({nlohmann::json::object(
                           {{"socketId", "s-me"}, {"grantedWrite", false}})})}}));
  const nlohmann::json revoked =
      nlohmann::json::parse(Events(), nullptr, false);
  REQUIRE(revoked["result"]["room"]["grantedWrite"] == false);
}

TEST_CASE("sync answers a checkpoint request with the encoded state",
          "[sync]") {
  InstallFakeTransport();
  REQUIRE(JsonBool(Connect(), "connected", true));
  REQUIRE(JsonBool(Join("board-cp", "page-1"), "joined", true));

  // Build the local document + watermark the editor would hold: two local
  // ops applied through crdt and forwarded through the sync domain.
  REQUIRE(JsonBool(
      wb::invokeDomain("crdt", "create",
                       "{\"docId\":\"board-cp\",\"actor\":\"me\"}"),
      "ok", true));
  const nlohmann::json first = nlohmann::json::parse(
      wb::invokeDomain("crdt", "applyLocal",
                       "{\"docId\":\"board-cp\",\"operation\":{\"key\":"
                       "\"k1\",\"value\":\"v1\",\"timestamp\":1000}}"),
      nullptr, false);
  REQUIRE(first.value("ok", false));
  REQUIRE(JsonBool(Send(first["result"]["op"].dump()), "sent", true));
  const nlohmann::json second = nlohmann::json::parse(
      wb::invokeDomain("crdt", "applyLocal",
                       "{\"docId\":\"board-cp\",\"operation\":{\"key\":"
                       "\"k2\",\"value\":\"v2\",\"timestamp\":2000}}"),
      nullptr, false);
  REQUIRE(second.value("ok", false));
  REQUIRE(JsonBool(Send(second["result"]["op"].dump()), "sent", true));

  // The exact payload the crdt domain would encode right now.
  const nlohmann::json encoded = nlohmann::json::parse(
      wb::invokeDomain("crdt", "encodeState", "{\"docId\":\"board-cp\"}"),
      nullptr, false);
  REQUIRE(encoded.value("ok", false));
  const std::string expectedPayload =
      encoded["result"]["state"].get<std::string>();

  // The server asks for a checkpoint; a preloaded ack accepts the upload.
  FakeQueueCheckpointReply(nlohmann::json::object({{"ok", true}}));
  FakePushInbound("board:checkpointRequest",
                  nlohmann::json::object({{"requestId", "req-1"}}));

  std::string events = Events();
  REQUIRE(JsonBool(events, "ok", true));
  // The upload carries the encoded state + this client's watermark.
  REQUIRE(FakeState().sentCheckpoints.size() == 1u);
  REQUIRE(FakeState().sentCheckpoints[0]["stateVector"]["me"] == 2);
  REQUIRE(FakeState().sentCheckpoints[0]["payload"].get<std::string>() ==
          expectedPayload);
  // In flight: 'requested' until the ack drains.
  REQUIRE(JsonContains(events, "\"checkpointStatus\":\"requested\""));

  // The ack (queued above) settles the upload.
  events = Events();
  REQUIRE(JsonContains(events, "\"checkpointStatus\":\"uploaded\""));

  // Failure path: a rejected upload settles at 'failed'.
  FakeQueueCheckpointReply(
      nlohmann::json::object({{"ok", false}, {"reason", "quota"}}));
  FakePushInbound("board:checkpointRequest", nlohmann::json::object());
  REQUIRE(JsonContains(Events(), "\"checkpointStatus\":\"requested\""));
  REQUIRE(JsonContains(Events(), "\"checkpointStatus\":\"failed\""));

  // A transport-side refusal (race) settles at 'failed' right away.
  FakeState().checkpointAccepted = false;
  FakePushInbound("board:checkpointRequest", nlohmann::json::object());
  events = Events();
  REQUIRE(JsonContains(events, "\"checkpointStatus\":\"failed\""));
  REQUIRE(FakeState().sentCheckpoints.size() == 2u);
}

TEST_CASE("sync restores a join snapshot for a new member", "[sync]") {
  InstallFakeTransport();
  REQUIRE(JsonBool(Connect(), "connected", true));
  REQUIRE(JsonBool(Join("board-snap", "page-1"), "joined", true));

  // The server's snapshot: state from another replica + its watermark.
  const std::string snapshotState =
      "{\"k1\":{\"actor\":\"ra\",\"timestamp\":100,\"value\":\"v1\"},"
      "\"k2\":{\"actor\":\"ra\",\"timestamp\":200,\"value\":\"v2\"}}";
  FakePushInbound(
      "board:joined",
      nlohmann::json::object(
          {{"ok", true},
           {"participants", nlohmann::json::array()},
           {"mode", "free"},
           {"snapshot",
            nlohmann::json::object(
                {{"stateVector", nlohmann::json::object({{"ra", 2}})},
                 {"payload", snapshotState}})}}));

  const std::string events = Events();
  REQUIRE(JsonBool(events, "ok", true));
  REQUIRE(JsonContains(events, "\"recovered\":true"));

  // The document was created and decoded from the snapshot verbatim.
  const nlohmann::json encoded = nlohmann::json::parse(
      wb::invokeDomain("crdt", "encodeState", "{\"docId\":\"board-snap\"}"),
      nullptr, false);
  REQUIRE(encoded.value("ok", false));
  REQUIRE(encoded["result"]["keyCount"] == 2);
  REQUIRE(encoded["result"]["state"].get<std::string>() == snapshotState);

  // Increments after the snapshot replay on top of the restored state and
  // build on its watermark baseline (2 -> 3).
  FakePushInbound("board:ops",
                  nlohmann::json::array({MakeRemoteOp("ra", 3, "k3")}));
  REQUIRE(JsonContains(Events(), "\"key\":\"k3\""));
  const nlohmann::json grown = nlohmann::json::parse(
      wb::invokeDomain("crdt", "encodeState", "{\"docId\":\"board-snap\"}"),
      nullptr, false);
  REQUIRE(grown.value("ok", false));
  REQUIRE(grown["result"]["keyCount"] == 3);
  REQUIRE(RejoinWatermark().value("ra", 0) == 3);
}

TEST_CASE("sync keeps an existing document when a snapshot arrives",
          "[sync]") {
  InstallFakeTransport();
  REQUIRE(JsonBool(Connect(), "connected", true));
  REQUIRE(JsonBool(Join("board-guard", "page-1"), "joined", true));

  // A local document already exists with local-only content.
  REQUIRE(JsonBool(
      wb::invokeDomain("crdt", "create",
                       "{\"docId\":\"board-guard\",\"actor\":\"me\"}"),
      "ok", true));
  const nlohmann::json applied = nlohmann::json::parse(
      wb::invokeDomain("crdt", "applyLocal",
                       "{\"docId\":\"board-guard\",\"operation\":{\"key\":"
                       "\"local\",\"value\":\"mine\",\"timestamp\":50}}"),
      nullptr, false);
  REQUIRE(applied.value("ok", false));
  REQUIRE(JsonBool(Send(applied["result"]["op"].dump()), "sent", true));

  // A late snapshot must NOT be decoded over the existing document
  // (decodeState is a whole-state replacement; the guard skips it).
  FakePushInbound(
      "board:joined",
      nlohmann::json::object(
          {{"ok", true},
           {"participants", nlohmann::json::array()},
           {"mode", "free"},
           {"snapshot",
            nlohmann::json::object(
                {{"stateVector", nlohmann::json::object({{"ra", 9}})},
                 {"payload",
                  "{\"remote\":{\"actor\":\"ra\",\"timestamp\":900,"
                  "\"value\":\"theirs\"}}"}})}}));

  const std::string events = Events();
  REQUIRE(JsonBool(events, "ok", true));
  REQUIRE(JsonContains(events, "\"recovered\":false"));

  // The local state survived untouched: only the local key remains.
  const nlohmann::json kept = nlohmann::json::parse(
      wb::invokeDomain("crdt", "encodeState", "{\"docId\":\"board-guard\"}"),
      nullptr, false);
  REQUIRE(kept.value("ok", false));
  REQUIRE(kept["result"]["keyCount"] == 1);
  const std::string keptState = kept["result"]["state"].get<std::string>();
  REQUIRE(JsonContains(keptState, "\"local\""));
  REQUIRE(!JsonContains(keptState, "theirs"));

  // Neither did the snapshot touch the watermark: the re-join vector still
  // holds the local op (me at seq 1) and nothing from ra.
  const nlohmann::json watermark = RejoinWatermark();
  REQUIRE(watermark.value("me", 0) == 1);
  REQUIRE(watermark.value("ra", 0) == 0);
}
