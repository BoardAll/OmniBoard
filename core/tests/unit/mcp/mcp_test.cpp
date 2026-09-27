// tests/unit/mcp/mcp_test.cpp — domain "mcp" (task package 1.8).
//
// catch_discover_tests runs every TEST_CASE in its own process, so the
// process-wide MCP server state starts fresh on entry ("running" is always
// false). Tools are bridged from the shared ToolRegistry; "theme_list" is
// the MCP spelling of the internal tool id "theme.list".

#include <string>

#include <catch2/catch_test_macros.hpp>

#include "../support/scene_probe.h"

namespace {

std::string Start(const std::string& config = "{}") {
  return wb::invokeDomain("mcp", "start", "{\"config\":" + config + "}");
}

std::string CreateSession(const std::string& token,
                          const std::string& allowedBoards = "") {
  std::string body = "{\"token\":\"" + token + "\"";
  if (!allowedBoards.empty()) body += ",\"allowedBoards\":" + allowedBoards;
  return wb::invokeDomain("mcp", "sessionCreate", body + "}");
}

/// Wraps a JSON-RPC request for handleRequest.
std::string Request(const std::string& method, const std::string& params = "{}",
                    const std::string& id = "1",
                    const std::string& sessionId = "") {
  std::string body = "{\"request\":{\"jsonrpc\":\"2.0\",\"id\":" + id +
                     ",\"method\":\"" + method + "\",\"params\":" + params +
                     "}";
  if (!sessionId.empty()) body += ",\"sessionId\":\"" + sessionId + "\"";
  return wb::invokeDomain("mcp", "handleRequest", body + "}");
}

}  // namespace

TEST_CASE("mcp start, isRunning and stop", "[mcp]") {
  // Stopped on entry: requests are refused with a domain-level conflict.
  REQUIRE(JsonBool(wb::invokeDomain("mcp", "isRunning", "{}"), "running",
                   false));
  REQUIRE(JsonContains(Request("ping"), "Conflict"));

  const std::string started = Start("{\"transport\":\"stdio\"}");
  REQUIRE(JsonBool(started, "ok", true));
  REQUIRE(JsonBool(started, "running", true));
  REQUIRE(JsonNumber(started, "port") == 8765.0);
  REQUIRE(JsonString(started, "transport") == "stdio");
  REQUIRE(JsonString(started, "serverName") == "whiteboard-mcp");
  REQUIRE(JsonString(started, "version") == "1.0.0");

  // Double start conflicts; unsupported transports are rejected.
  REQUIRE(JsonContains(Start(), "Conflict"));
  REQUIRE(JsonContains(Start("{\"transport\":\"carrier-pigeon\"}"),
                       "InvalidArgument"));

  REQUIRE(JsonBool(wb::invokeDomain("mcp", "isRunning", "{}"), "running",
                   true));

  const std::string stopped = wb::invokeDomain("mcp", "stop", "{}");
  REQUIRE(JsonBool(stopped, "ok", true));
  REQUIRE(JsonBool(stopped, "running", false));
  REQUIRE(JsonBool(wb::invokeDomain("mcp", "isRunning", "{}"), "running",
                   false));

  // Sessions require a running server.
  REQUIRE(JsonContains(CreateSession("tok"), "Conflict"));
}

TEST_CASE("mcp sessions enforce tokens and lifecycle", "[mcp]") {
  Start();

  REQUIRE(JsonContains(CreateSession(""), "InvalidArgument"));
  REQUIRE(JsonContains(CreateSession("invalid"), "PermissionDenied"));

  const std::string created = CreateSession("tok-1");
  REQUIRE(JsonBool(created, "ok", true));
  REQUIRE(JsonString(created, "sessionId") == "mcp-1");
  REQUIRE(JsonString(created, "userId") == "mcp:tok-1");
  REQUIRE(JsonContains(created, "\"scopes\":[\"*\"]"));

  const std::string got =
      wb::invokeDomain("mcp", "sessionGet", "{\"sessionId\":\"mcp-1\"}");
  REQUIRE(JsonBool(got, "ok", true));
  REQUIRE(JsonBool(got, "initialized", false));
  REQUIRE(JsonString(got, "userId") == "mcp:tok-1");
  REQUIRE(JsonString(got, "protocolVersion") == "2025-06-18");

  const std::string closed =
      wb::invokeDomain("mcp", "sessionClose", "{\"sessionId\":\"mcp-1\"}");
  REQUIRE(JsonBool(closed, "ok", true));
  REQUIRE(JsonBool(closed, "closed", true));
  REQUIRE(JsonContains(wb::invokeDomain("mcp", "sessionGet",
                                        "{\"sessionId\":\"mcp-1\"}"),
                       "NotFound"));

  REQUIRE(JsonContains(wb::invokeDomain("mcp", "sessionGet", "{}"),
                       "InvalidArgument"));

  // Unknown sessions in handleRequest answer with JSON-RPC 32003.
  REQUIRE(JsonContains(Request("ping", "{}", "1", "mcp-404"), "-32003"));
}

TEST_CASE("mcp handleRequest initializes the protocol", "[mcp]") {
  Start();
  CreateSession("tok-1");

  const std::string init = Request(
      "initialize",
      "{\"protocolVersion\":\"2025-06-18\","
      "\"clientInfo\":{\"name\":\"test-client\",\"version\":\"1.0\"}}",
      "1", "mcp-1");
  REQUIRE(JsonBool(init, "ok", true));
  REQUIRE(JsonString(init, "protocolVersion") == "2025-06-18");
  REQUIRE(JsonContains(init, "whiteboard-mcp"));
  REQUIRE(JsonContains(init, "\"subscribe\":true"));
  REQUIRE(JsonContains(init, "\"listChanged\":true"));
  REQUIRE(JsonContains(init, "instructions"));

  // Unsupported versions answer -32602 with the supported list.
  const std::string bad = Request(
      "initialize", "{\"protocolVersion\":\"1999-01-01\"}", "2", "mcp-1");
  REQUIRE(JsonBool(bad, "ok", true));  // domain ok, RPC-level error
  REQUIRE(JsonContains(bad, "-32602"));
  REQUIRE(JsonContains(bad, "2024-11-05"));

  // notifications/initialized flips the session flag.
  const std::string notified = Request("notifications/initialized", "{}", "3",
                                       "mcp-1");
  REQUIRE(JsonContains(notified, "\"ok\":true"));
  const std::string got =
      wb::invokeDomain("mcp", "sessionGet", "{\"sessionId\":\"mcp-1\"}");
  REQUIRE(JsonBool(got, "initialized", true));
  REQUIRE(JsonString(got, "clientName") == "test-client");
}

TEST_CASE("mcp tools list from the registry and call tool", "[mcp]") {
  Start();

  const std::string listed = Request("tools/list");
  REQUIRE(JsonBool(listed, "ok", true));
  REQUIRE(JsonContains(listed, "element_create"));
  REQUIRE(JsonContains(listed, "theme_list"));
  REQUIRE(JsonContains(listed, "nextCursor"));

  const std::string called = Request(
      "tools/call", "{\"name\":\"theme_list\",\"arguments\":{}}", "2", "");
  REQUIRE(JsonBool(called, "ok", true));
  REQUIRE(JsonContains(called, "\"isError\":false"));

  REQUIRE(JsonContains(Request("tools/call",
                               "{\"name\":\"nope_nope\",\"arguments\":{}}",
                               "3", ""),
                       "-32003"));

  // Top-level convenience wrapper behaves the same.
  const std::string direct = wb::invokeDomain(
      "mcp", "callTool", "{\"toolName\":\"theme_list\",\"args\":{}}");
  REQUIRE(JsonBool(direct, "ok", true));
  REQUIRE(JsonBool(direct, "isError", false));
  REQUIRE(JsonString(direct, "toolId") == "theme.list");
  REQUIRE(JsonContains(wb::invokeDomain("mcp", "callTool",
                                        "{\"toolName\":\"nope\"}"),
                       "NotFound"));
  REQUIRE(JsonContains(wb::invokeDomain("mcp", "callTool", "{}"),
                       "InvalidArgument"));

  // Both calls are audited with fromAI=true.
  const std::string audited = wb::invokeDomain(
      "mcp", "auditQuery",
      "{\"filter\":{\"toolId\":\"theme.list\",\"fromAI\":true}}");
  REQUIRE(JsonNumber(audited, "count") >= 2.0);
}

TEST_CASE("mcp resources expand the session boards", "[mcp]") {
  Start();
  std::string boardResponse;
  SceneNewBoard(&boardResponse);
  const std::string boardId = SceneBoardId(boardResponse);
  const std::string pageId = SceneFirstPageId(boardResponse);
  REQUIRE(!boardId.empty());
  REQUIRE(!pageId.empty());

  // Anonymous listing exposes only the board catalog entry.
  const std::string anon = wb::invokeDomain("mcp", "listResources", "{}");
  REQUIRE(JsonBool(anon, "ok", true));
  REQUIRE(JsonNumber(anon, "count") == 1.0);
  REQUIRE(JsonContains(anon, "whiteboard://boards"));

  const std::string created = CreateSession("tok-2", "[\"" + boardId + "\"]");
  const std::string sessionId = JsonString(created, "sessionId");
  REQUIRE(sessionId == "mcp-1");

  const std::string listed = wb::invokeDomain(
      "mcp", "listResources", "{\"sessionId\":\"" + sessionId + "\"}");
  REQUIRE(JsonBool(listed, "ok", true));
  REQUIRE(JsonNumber(listed, "count") >= 7.0);  // 1 + 4 board + 2 per page
  REQUIRE(JsonContains(listed, "whiteboard://boards/" + boardId + "/pages"));
  REQUIRE(JsonContains(listed,
                       "whiteboard://boards/" + boardId + "/pages/" + pageId));
  REQUIRE(JsonContains(listed, "/elements"));

  const std::string pages = wb::invokeDomain(
      "mcp", "readResource",
      "{\"uri\":\"whiteboard://boards/" + boardId + "/pages\",\"sessionId\":\"" +
          sessionId + "\"}");
  REQUIRE(JsonBool(pages, "ok", true));
  REQUIRE(JsonContains(pages, "contents"));
  REQUIRE(JsonContains(pages, "\"mimeType\":\"application/json\""));

  // JSON-RPC resources/read returns a text content envelope.
  const std::string read = Request("resources/read",
                                   "{\"uri\":\"whiteboard://boards\"}", "1",
                                   sessionId);
  REQUIRE(JsonBool(read, "ok", true));
  REQUIRE(JsonContains(read, "whiteboard://boards"));

  REQUIRE(JsonContains(wb::invokeDomain("mcp", "readResource",
                                        "{\"uri\":\"whiteboard://nope\"}"),
                       "NotFound"));
  REQUIRE(JsonContains(wb::invokeDomain("mcp", "readResource", "{}"),
                       "InvalidArgument"));
}

TEST_CASE("mcp prompts render templates", "[mcp]") {
  Start();

  const std::string listed = Request("prompts/list");
  REQUIRE(JsonBool(listed, "ok", true));
  REQUIRE(JsonContains(listed, "brainstorm"));
  REQUIRE(JsonContains(listed, "userJourney"));
  REQUIRE(JsonContains(listed, "kanban"));

  const std::string got = Request(
      "prompts/get",
      "{\"name\":\"brainstorm\",\"arguments\":{\"topic\":\"AI 助手\","
      "\"count\":\"5\"}}",
      "2", "");
  REQUIRE(JsonBool(got, "ok", true));
  REQUIRE(JsonContains(got, "AI 助手"));
  REQUIRE(JsonContains(got, "\"role\":\"user\""));
  REQUIRE(JsonContains(got, "\"type\":\"text\""));

  // Missing required arguments answer -32602 naming the argument.
  const std::string missing = Request(
      "prompts/get", "{\"name\":\"brainstorm\",\"arguments\":{}}", "3", "");
  REQUIRE(JsonContains(missing, "-32602"));
  REQUIRE(JsonContains(missing, "topic"));

  REQUIRE(JsonContains(Request("prompts/get",
                               "{\"name\":\"nope\",\"arguments\":{}}", "4",
                               ""),
                       "-32003"));

  // FFI-style wrapper.
  const std::string direct = wb::invokeDomain(
      "mcp", "getPrompt", "{\"name\":\"swot\",\"args\":{\"topic\":\"产品\"}}");
  REQUIRE(JsonBool(direct, "ok", true));
  REQUIRE(JsonContains(direct, "产品"));
  REQUIRE(JsonContains(wb::invokeDomain("mcp", "getPrompt",
                                        "{\"name\":\"swot\"}"),
                       "InvalidArgument"));
}

TEST_CASE("mcp JSON-RPC error paths and subscriptions", "[mcp]") {
  Start();

  REQUIRE(JsonContains(Request("no/such", "{}", "1", ""), "-32601"));

  const std::string noMethod = wb::invokeDomain(
      "mcp", "handleRequest", "{\"request\":{\"jsonrpc\":\"2.0\",\"id\":1}}");
  REQUIRE(JsonContains(noMethod, "-32600"));

  REQUIRE(JsonContains(wb::invokeDomain(
                           "mcp", "handleRequest", "{\"request\":\"nope\"}"),
                       "-32600"));

  // ping answers an empty result envelope.
  const std::string ping = Request("ping", "{}", "3", "");
  REQUIRE(JsonBool(ping, "ok", true));
  REQUIRE(JsonContains(ping, "\"result\":{}"));

  // Resource subscriptions are recorded and can be removed.
  const std::string sub = Request(
      "resources/subscribe", "{\"uri\":\"whiteboard://boards\"}", "4", "");
  REQUIRE(JsonBool(sub, "subscribed", true));
  const std::string unsub = Request(
      "resources/unsubscribe", "{\"uri\":\"whiteboard://boards\"}", "5", "");
  REQUIRE(JsonBool(unsub, "subscribed", false));

  REQUIRE(JsonContains(wb::invokeDomain("mcp", "frobnicate", "{}"),
                       "NotFound"));
}
