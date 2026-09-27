// tests/unit/sync/sync_test.cpp — domain "sync" (1.7).
//
// catch_discover_tests runs every TEST_CASE in its own process, so the
// process-wide transport state starts fresh here each time.

#include <string>

#include <catch2/catch_test_macros.hpp>

#include "../support/scene_probe.h"

namespace {

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

}  // namespace

TEST_CASE("sync starts disconnected with an empty queue", "[sync]") {
  const std::string status = Status();
  REQUIRE(JsonBool(status, "ok", true));
  REQUIRE(JsonBool(status, "connected", false));
  REQUIRE(JsonBool(status, "offline", false));
  REQUIRE(JsonNumber(status, "pendingCount") == 0.0);
  REQUIRE(JsonNumber(status, "sentCount") == 0.0);
  REQUIRE(JsonNumber(status, "syncedCount") == 0.0);
  REQUIRE(JsonString(status, "transport") == "websocket");
}

TEST_CASE("sync connects once and disconnects idempotently", "[sync]") {
  REQUIRE(JsonBool(Connect(), "connected", true));
  REQUIRE(JsonString(Status(), "endpoint") == "ws://localhost:9000");

  const std::string duplicate = Connect("ws://other:1234");
  REQUIRE(JsonBool(duplicate, "ok", false));
  REQUIRE(JsonContains(duplicate, "Conflict"));

  const std::string noEndpoint = wb::invokeDomain("sync", "connect", "{}");
  REQUIRE(JsonBool(noEndpoint, "ok", false));
  REQUIRE(JsonContains(noEndpoint, "InvalidArgument"));

  const std::string off = wb::invokeDomain("sync", "disconnect", "{}");
  REQUIRE(JsonBool(off, "connected", false));
  const std::string again = wb::invokeDomain("sync", "disconnect", "{}");
  REQUIRE(JsonBool(again, "ok", true));
  REQUIRE(JsonBool(again, "connected", false));
}

TEST_CASE("sync sends immediately while online", "[sync]") {
  Connect();
  const std::string sent = Send("{\"kind\":\"op\",\"n\":1}");
  REQUIRE(JsonBool(sent, "sent", true));
  REQUIRE(JsonNumber(sent, "pendingCount") == 0.0);
  REQUIRE(JsonNumber(sent, "syncedCount") == 1.0);

  const std::string status = Status();
  REQUIRE(JsonNumber(status, "sentCount") == 1.0);
  REQUIRE(JsonNumber(status, "syncedCount") == 1.0);
}

TEST_CASE("sync queues operations offline and drains on sync", "[sync]") {
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
  const std::string caps = wb::invokeDomain("sync", "capabilities", "{}");
  REQUIRE(JsonBool(caps, "ok", true));
  REQUIRE(JsonNumber(caps, "providerCount") == 5.0);
  REQUIRE(JsonBool(caps, "reserved", true));
  REQUIRE(JsonContains(caps, "AVProvider"));
  REQUIRE(JsonContains(caps, "InteractiveProvider"));
  REQUIRE(JsonContains(caps, "PlaybackProvider"));
  REQUIRE(JsonContains(caps, "webrtc"));
  REQUIRE(JsonContains(caps, "\"implemented\":false"));
}
