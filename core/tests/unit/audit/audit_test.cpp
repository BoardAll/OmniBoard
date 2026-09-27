// tests/unit/audit/audit_test.cpp — domain "audit" (1.7).
//
// catch_discover_tests runs every TEST_CASE in its own process, so the
// process-wide audit log starts fresh here each time. The export test
// writes a JSON-lines file into the test working directory and reads it
// back to verify the format.

#include <fstream>
#include <string>

#include <catch2/catch_test_macros.hpp>

#include "../support/scene_probe.h"

namespace {

std::string Log(const std::string& entryBody) {
  return wb::invokeDomain("audit", "log", "{\"entry\":" + entryBody + "}");
}

std::string LogEntry(const std::string& userId, const std::string& toolId,
                     const std::string& extra = "") {
  std::string body =
      "{\"userId\":\"" + userId + "\",\"toolId\":\"" + toolId + "\"";
  if (!extra.empty()) body += "," + extra;
  return Log(body + "}");
}

std::string Query(const std::string& filterBody) {
  return wb::invokeDomain("audit", "query", "{\"filter\":" + filterBody + "}");
}

}  // namespace

TEST_CASE("audit assigns monotonic ids and counts entries", "[audit]") {
  const std::string first = LogEntry("alice", "draw.stroke");
  REQUIRE(JsonBool(first, "ok", true));
  REQUIRE(JsonString(first, "id") == "audit-1");
  REQUIRE(JsonNumber(first, "count") == 1.0);
  REQUIRE(JsonNumber(first, "timestamp") > 0.0);

  const std::string second = LogEntry("bob", "ai.chat", "\"fromAI\":true");
  REQUIRE(JsonString(second, "id") == "audit-2");
  REQUIRE(JsonNumber(second, "count") == 2.0);

  const std::string all = Query("{}");
  REQUIRE(JsonNumber(all, "count") == 2.0);
  REQUIRE(JsonContains(all, "audit-1"));
  REQUIRE(JsonContains(all, "audit-2"));
}

TEST_CASE("audit query filters by user, tool, fromAI and time range",
          "[audit]") {
  LogEntry("alice", "draw.stroke", "\"timestamp\":100");
  LogEntry("alice", "ai.chat", "\"fromAI\":true,\"timestamp\":200");
  LogEntry("bob", "ai.chat", "\"fromAI\":true,\"timestamp\":300");

  REQUIRE(JsonNumber(Query("{\"userId\":\"alice\"}"), "count") == 2.0);
  REQUIRE(JsonNumber(Query("{\"toolId\":\"ai.chat\"}"), "count") == 2.0);
  REQUIRE(JsonNumber(Query("{\"fromAI\":true}"), "count") == 2.0);
  REQUIRE(JsonNumber(Query("{\"userId\":\"alice\",\"toolId\":\"ai.chat\"}"),
                     "count") == 1.0);
  REQUIRE(JsonNumber(Query("{\"since\":150,\"until\":250}"), "count") == 1.0);
  REQUIRE(JsonNumber(Query("{\"since\":150}"), "count") == 2.0);

  const std::string limited = Query("{\"limit\":2}");
  REQUIRE(JsonNumber(limited, "count") == 2.0);
  REQUIRE(JsonContains(limited, "audit-1"));
  REQUIRE(JsonContains(limited, "audit-2"));

  const std::string badLimit = Query("{\"limit\":0}");
  REQUIRE(JsonBool(badLimit, "ok", false));
  REQUIRE(JsonContains(badLimit, "InvalidArgument"));
}

TEST_CASE("audit export writes JSON lines", "[audit]") {
  LogEntry("alice", "tool.a", "\"argsJson\":\"{}\"");
  LogEntry("bob", "tool.b", "\"fromAI\":true");

  const std::string path = "audit_export_test.jsonl";
  const std::string exported =
      wb::invokeDomain("audit", "export", "{\"path\":\"" + path + "\"}");
  REQUIRE(JsonBool(exported, "ok", true));
  REQUIRE(JsonNumber(exported, "exported") == 2.0);
  REQUIRE(JsonNumber(exported, "bytes") > 0.0);

  std::ifstream file(path, std::ios::binary);
  REQUIRE(file.is_open());
  std::string line;
  std::string content;
  int lines = 0;
  while (std::getline(file, line)) {
    REQUIRE(!line.empty());
    REQUIRE(line.front() == '{');
    content += line;
    ++lines;
  }
  REQUIRE(lines == 2);
  REQUIRE(content.find("audit-1") != std::string::npos);
  REQUIRE(content.find("audit-2") != std::string::npos);

  const std::string missing = wb::invokeDomain("audit", "export", "{}");
  REQUIRE(JsonBool(missing, "ok", false));
  REQUIRE(JsonContains(missing, "InvalidArgument"));
}

TEST_CASE("audit validates log entries", "[audit]") {
  const std::string noEntry = wb::invokeDomain("audit", "log", "{}");
  REQUIRE(JsonBool(noEntry, "ok", false));
  REQUIRE(JsonContains(noEntry, "InvalidArgument"));

  const std::string noUser = Log("{\"toolId\":\"t\"}");
  REQUIRE(JsonBool(noUser, "ok", false));
  REQUIRE(JsonContains(noUser, "InvalidArgument"));

  const std::string noTool = Log("{\"userId\":\"u\"}");
  REQUIRE(JsonBool(noTool, "ok", false));
  REQUIRE(JsonContains(noTool, "InvalidArgument"));

  const std::string unknown = wb::invokeDomain("audit", "frobnicate", "{}");
  REQUIRE(JsonBool(unknown, "ok", false));
  REQUIRE(JsonContains(unknown, "NotFound"));
}
