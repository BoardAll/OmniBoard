// tests/unit/permission/permission_test.cpp — domain "permission" (1.7).
//
// catch_discover_tests runs every TEST_CASE in its own process, so the
// process-wide ACL starts fresh here each time.

#include <string>

#include <catch2/catch_test_macros.hpp>

#include "../support/scene_probe.h"

namespace {

std::string Grant(const std::string& user, const std::string& board,
                  const std::string& perm) {
  return wb::invokeDomain(
      "permission", "grant",
      "{\"userId\":\"" + user + "\",\"boardId\":\"" + board +
          "\",\"permission\":\"" + perm + "\"}");
}

std::string Revoke(const std::string& user, const std::string& board,
                   const std::string& perm) {
  return wb::invokeDomain(
      "permission", "revoke",
      "{\"userId\":\"" + user + "\",\"boardId\":\"" + board +
          "\",\"permission\":\"" + perm + "\"}");
}

std::string Check(const std::string& user, const std::string& board,
                  const std::string& perm) {
  return wb::invokeDomain(
      "permission", "check",
      "{\"userId\":\"" + user + "\",\"boardId\":\"" + board +
          "\",\"permission\":\"" + perm + "\"}");
}

}  // namespace

TEST_CASE("permission levels imply lower permissions", "[permission]") {
  const std::string grant = Grant("alice", "board-1", "admin");
  REQUIRE(JsonBool(grant, "ok", true));
  REQUIRE(JsonBool(grant, "granted", true));
  REQUIRE(JsonBool(grant, "raised", true));
  REQUIRE(JsonString(grant, "level") == "admin");

  REQUIRE(JsonBool(Check("alice", "board-1", "write"), "allowed", true));
  REQUIRE(JsonBool(Check("alice", "board-1", "read"), "allowed", true));
  REQUIRE(JsonBool(Check("alice", "board-1", "admin"), "allowed", true));

  // Granting a lower level never lowers the held level.
  const std::string lower = Grant("alice", "board-1", "read");
  REQUIRE(JsonBool(lower, "granted", true));
  REQUIRE(JsonBool(lower, "raised", false));
  REQUIRE(JsonString(lower, "level") == "admin");

  // Users without a grant are denied.
  const std::string denied = Check("bob", "board-1", "read");
  REQUIRE(JsonBool(denied, "ok", true));
  REQUIRE(JsonBool(denied, "allowed", false));
  REQUIRE(JsonString(denied, "level") == "none");
}

TEST_CASE("permission revoke removes covering grants only", "[permission]") {
  Grant("carol", "board-2", "write");
  const std::string revoked = Revoke("carol", "board-2", "write");
  REQUIRE(JsonBool(revoked, "ok", true));
  REQUIRE(JsonBool(revoked, "revoked", true));
  REQUIRE(JsonBool(Check("carol", "board-2", "write"), "allowed", false));

  // Idempotent: nothing left to revoke.
  REQUIRE(JsonBool(Revoke("carol", "board-2", "write"), "revoked", false));

  // Held level below the requested one -> no-op.
  Grant("dave", "board-2", "read");
  const std::string below = Revoke("dave", "board-2", "admin");
  REQUIRE(JsonBool(below, "ok", true));
  REQUIRE(JsonBool(below, "revoked", false));
  REQUIRE(JsonBool(Check("dave", "board-2", "read"), "allowed", true));

  // A higher held level covers the requested revoke -> removes the grant.
  Grant("erin", "board-2", "share");
  REQUIRE(JsonBool(Revoke("erin", "board-2", "write"), "revoked", true));
  REQUIRE(JsonBool(Check("erin", "board-2", "write"), "allowed", false));
}

TEST_CASE("permission names are case-insensitive and validated",
          "[permission]") {
  REQUIRE(JsonBool(Grant("frank", "board-3", "ADMIN"), "ok", true));
  REQUIRE(JsonBool(Check("frank", "board-3", "Read"), "allowed", true));

  const std::string unknown = Grant("frank", "board-3", "owner");
  REQUIRE(JsonBool(unknown, "ok", false));
  REQUIRE(JsonContains(unknown, "InvalidArgument"));

  const std::string noUser = wb::invokeDomain(
      "permission", "check",
      "{\"boardId\":\"board-3\",\"permission\":\"read\"}");
  REQUIRE(JsonBool(noUser, "ok", false));
  REQUIRE(JsonContains(noUser, "InvalidArgument"));

  const std::string noBoard = wb::invokeDomain(
      "permission", "check", "{\"userId\":\"frank\",\"permission\":\"read\"}");
  REQUIRE(JsonBool(noBoard, "ok", false));

  const std::string noPerm = wb::invokeDomain(
      "permission", "grant", "{\"userId\":\"frank\",\"boardId\":\"board-3\"}");
  REQUIRE(JsonBool(noPerm, "ok", false));
  REQUIRE(JsonContains(noPerm, "InvalidArgument"));
}

TEST_CASE("permission list filters by board and user", "[permission]") {
  Grant("alice", "board-a", "read");
  Grant("bob", "board-a", "write");
  Grant("alice", "board-b", "admin");

  const std::string all = wb::invokeDomain("permission", "list", "{}");
  REQUIRE(JsonNumber(all, "count") == 3.0);

  const std::string boardA =
      wb::invokeDomain("permission", "list", "{\"boardId\":\"board-a\"}");
  REQUIRE(JsonNumber(boardA, "count") == 2.0);

  const std::string alice =
      wb::invokeDomain("permission", "list", "{\"userId\":\"alice\"}");
  REQUIRE(JsonNumber(alice, "count") == 2.0);

  const std::string levels =
      wb::invokeDomain("permission", "levels", "{}");
  REQUIRE(JsonContains(levels, "\"name\":\"admin\""));
  REQUIRE(JsonContains(levels, "\"name\":\"read\""));
  REQUIRE(JsonContains(levels, "\"value\":4"));
}
