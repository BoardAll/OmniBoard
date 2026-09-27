// tests/unit/crdt/crdt_test.cpp — domain "crdt" (1.7).
//
// catch_discover_tests runs every TEST_CASE in its own process, so the
// process-wide document registry starts fresh here each time. Operations
// carry explicit timestamps so the LWW register behaves deterministically
// regardless of wall-clock resolution.

#include <string>

#include <catch2/catch_test_macros.hpp>

#include "../support/scene_probe.h"

namespace {

std::string Create(const std::string& body = "") {
  return wb::invokeDomain("crdt", "create", body.empty() ? "{}" : body);
}

std::string ApplyLocal(const std::string& docId, const std::string& opBody) {
  return wb::invokeDomain("crdt", "applyLocal",
                          "{\"docId\":\"" + docId + "\",\"operation\":" +
                              opBody + "}");
}

std::string ApplyRemote(const std::string& docId, const std::string& opBody) {
  return wb::invokeDomain("crdt", "applyRemote",
                          "{\"docId\":\"" + docId + "\",\"operation\":" +
                              opBody + "}");
}

}  // namespace

TEST_CASE("crdt creates documents with generated and explicit ids", "[crdt]") {
  const std::string first = Create();
  REQUIRE(JsonBool(first, "ok", true));
  REQUIRE(JsonString(first, "docId") == "crdt-1");
  REQUIRE(JsonString(first, "actor") == "local");

  const std::string second = Create();
  REQUIRE(JsonString(second, "docId") == "crdt-2");

  const std::string explicitDoc = Create("{\"docId\":\"board-1\"}");
  REQUIRE(JsonString(explicitDoc, "docId") == "board-1");

  const std::string duplicate = Create("{\"docId\":\"board-1\"}");
  REQUIRE(JsonBool(duplicate, "ok", false));
  REQUIRE(JsonContains(duplicate, "Conflict"));

  const std::string list = wb::invokeDomain("crdt", "list", "{}");
  REQUIRE(JsonNumber(list, "count") == 3.0);
  REQUIRE(JsonContains(list, "\"docId\":\"board-1\""));
}

TEST_CASE("crdt local ops are last-writer-wins on timestamps", "[crdt]") {
  Create();

  const std::string a = ApplyLocal(
      "crdt-1", "{\"key\":\"title\",\"value\":\"A\",\"timestamp\":1000}");
  REQUIRE(JsonBool(a, "applied", true));
  REQUIRE(JsonNumber(a, "seq") == 1.0);
  REQUIRE(JsonNumber(a, "version") == 1.0);
  REQUIRE(JsonString(a, "origin") == "local");

  const std::string b = ApplyLocal(
      "crdt-1", "{\"key\":\"title\",\"value\":\"B\",\"timestamp\":2000}");
  REQUIRE(JsonBool(b, "applied", true));

  // An older timestamp is stored in the op log but does not move the
  // register.
  const std::string stale = ApplyLocal(
      "crdt-1", "{\"key\":\"title\",\"value\":\"C\",\"timestamp\":1500}");
  REQUIRE(JsonBool(stale, "ok", true));
  REQUIRE(JsonBool(stale, "applied", false));
  REQUIRE(JsonNumber(stale, "version") == 3.0);

  const std::string encoded = wb::invokeDomain(
      "crdt", "encodeState", "{\"docId\":\"crdt-1\"}");
  REQUIRE(JsonNumber(encoded, "keyCount") == 1.0);
  REQUIRE(JsonNumber(encoded, "version") == 3.0);
  // The serialized register still holds "B" (escaped inside the string).
  REQUIRE(JsonContains(encoded, "\\\"value\\\":\\\"B\\\""));
}

TEST_CASE("crdt remote ops deduplicate on actor and seq", "[crdt]") {
  Create();

  const std::string first = ApplyRemote(
      "crdt-1",
      "{\"actor\":\"bob\",\"seq\":5,\"key\":\"count\",\"value\":1,"
      "\"timestamp\":3000}");
  REQUIRE(JsonBool(first, "applied", true));
  REQUIRE(JsonNumber(first, "seq") == 5.0);
  REQUIRE(JsonString(first, "origin") == "remote");

  // Replaying the same (actor, seq) is a no-op.
  const std::string duplicate = ApplyRemote(
      "crdt-1",
      "{\"actor\":\"bob\",\"seq\":5,\"key\":\"count\",\"value\":2,"
      "\"timestamp\":4000}");
  REQUIRE(JsonBool(duplicate, "ok", true));
  REQUIRE(JsonBool(duplicate, "applied", false));
  REQUIRE(JsonBool(duplicate, "duplicate", true));
  REQUIRE(JsonNumber(duplicate, "version") == 1.0);

  // A missing seq is assigned max(actor)+1.
  const std::string autoSeq = ApplyRemote(
      "crdt-1",
      "{\"actor\":\"bob\",\"key\":\"count\",\"value\":7,\"timestamp\":5000}");
  REQUIRE(JsonNumber(autoSeq, "seq") == 6.0);
  REQUIRE(JsonBool(autoSeq, "applied", true));
}

TEST_CASE("crdt encodeUpdate returns ops newer than since", "[crdt]") {
  Create();
  ApplyLocal("crdt-1", "{\"key\":\"a\",\"value\":1,\"timestamp\":1000}");
  ApplyLocal("crdt-1", "{\"key\":\"b\",\"value\":2,\"timestamp\":1001}");
  ApplyLocal("crdt-1", "{\"key\":\"c\",\"value\":3,\"timestamp\":1002}");

  const std::string all = wb::invokeDomain(
      "crdt", "encodeUpdate", "{\"docId\":\"crdt-1\",\"since\":0}");
  REQUIRE(JsonNumber(all, "count") == 3.0);
  REQUIRE(JsonNumber(all, "version") == 3.0);

  const std::string tail = wb::invokeDomain(
      "crdt", "encodeUpdate", "{\"docId\":\"crdt-1\",\"since\":2}");
  REQUIRE(JsonNumber(tail, "count") == 1.0);
  REQUIRE(JsonContains(tail, "\"key\":\"c\""));

  const std::string negative = wb::invokeDomain(
      "crdt", "encodeUpdate", "{\"docId\":\"crdt-1\",\"since\":-1}");
  REQUIRE(JsonBool(negative, "ok", false));
  REQUIRE(JsonContains(negative, "InvalidArgument"));
}

TEST_CASE("crdt merge is a set union and idempotent", "[crdt]") {
  // Copies must use distinct actor ids; (actor, seq) is the op identity.
  Create("{\"docId\":\"doc-a\",\"actor\":\"alice\"}");
  Create("{\"docId\":\"doc-b\",\"actor\":\"bob\"}");
  ApplyLocal("doc-a", "{\"key\":\"x\",\"value\":\"A\",\"timestamp\":1000}");
  ApplyLocal("doc-b", "{\"key\":\"x\",\"value\":\"B\",\"timestamp\":2000}");
  ApplyLocal("doc-b", "{\"key\":\"y\",\"value\":\"only-b\",\"timestamp\":1500}");

  const std::string merge1 = wb::invokeDomain(
      "crdt", "merge", "{\"docId\":\"doc-a\",\"other\":\"doc-b\"}");
  REQUIRE(JsonBool(merge1, "ok", true));
  REQUIRE(JsonNumber(merge1, "merged") == 2.0);
  REQUIRE(JsonNumber(merge1, "version") == 3.0);  // 1 local + 2 merged
  REQUIRE(JsonNumber(merge1, "keyCount") == 2.0);  // x and y

  const std::string merge2 = wb::invokeDomain(
      "crdt", "merge", "{\"docId\":\"doc-a\",\"other\":\"doc-b\"}");
  REQUIRE(JsonNumber(merge2, "merged") == 0.0);  // already applied
  REQUIRE(JsonNumber(merge2, "version") == 3.0);

  // The merged register of x kept the newer "B".
  const std::string encoded = wb::invokeDomain(
      "crdt", "encodeState", "{\"docId\":\"doc-a\"}");
  REQUIRE(JsonContains(encoded, "\\\"value\\\":\\\"B\\\""));

  const std::string missing = wb::invokeDomain(
      "crdt", "merge", "{\"docId\":\"doc-a\",\"other\":\"nope\"}");
  REQUIRE(JsonBool(missing, "ok", false));
  REQUIRE(JsonContains(missing, "NotFound"));
}

TEST_CASE("crdt decodeState accepts objects and rejects garbage", "[crdt]") {
  Create("{\"docId\":\"dst\"}");
  const std::string decoded = wb::invokeDomain(
      "crdt", "decodeState",
      "{\"docId\":\"dst\",\"state\":{\"k1\":{\"actor\":\"local\","
      "\"timestamp\":100,\"value\":\"v1\"}}}");
  REQUIRE(JsonBool(decoded, "decoded", true));
  REQUIRE(JsonNumber(decoded, "keyCount") == 1.0);

  const std::string garbage = wb::invokeDomain(
      "crdt", "decodeState", "{\"docId\":\"dst\",\"state\":\"not-json\"}");
  REQUIRE(JsonBool(garbage, "ok", false));
  REQUIRE(JsonContains(garbage, "InvalidArgument"));

  const std::string missing = wb::invokeDomain(
      "crdt", "decodeState", "{\"docId\":\"dst\"}");
  REQUIRE(JsonBool(missing, "ok", false));
}

TEST_CASE("crdt reports unknown documents and arguments", "[crdt]") {
  const std::string missing = wb::invokeDomain(
      "crdt", "applyLocal",
      "{\"docId\":\"nope\",\"operation\":{\"key\":\"k\",\"value\":1}}");
  REQUIRE(JsonBool(missing, "ok", false));
  REQUIRE(JsonContains(missing, "NotFound"));

  Create();
  const std::string noOp = ApplyLocal("crdt-1", "{}");
  REQUIRE(JsonBool(noOp, "ok", false));
  REQUIRE(JsonContains(noOp, "InvalidArgument"));

  const std::string noKey = ApplyLocal("crdt-1", "{\"value\":1}");
  REQUIRE(JsonBool(noKey, "ok", false));

  const std::string unknown = wb::invokeDomain("crdt", "frobnicate", "{}");
  REQUIRE(JsonBool(unknown, "ok", false));
  REQUIRE(JsonContains(unknown, "NotFound"));
}
