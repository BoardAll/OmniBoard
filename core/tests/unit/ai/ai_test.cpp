// tests/unit/ai/ai_test.cpp — domain "ai" (task package 1.8).
//
// catch_discover_tests runs every TEST_CASE in its own process, so the
// process-wide AI session registry starts fresh here each time. Tool calls
// are executed through the shared ToolRegistry ("theme.list" is a
// deterministic read-only tool), and every execution must leave an audit
// entry with fromAI=true behind.

#include <string>

#include <catch2/catch_test_macros.hpp>

#include "../support/scene_probe.h"

namespace {

std::string CreateSession(const std::string& boardId = "board-1",
                          const std::string& userId = "alice") {
  return wb::invokeDomain("ai", "sessionCreate",
                          "{\"boardId\":\"" + boardId + "\",\"userId\":\"" +
                              userId + "\"}");
}

/// Sends one user message carrying a single pending tool call.
std::string SendWithCall(const std::string& sessionId,
                         const std::string& toolId) {
  return wb::invokeDomain(
      "ai", "sendMessage",
      "{\"sessionId\":\"" + sessionId + "\",\"message\":\"hello\","
      "\"toolCalls\":[{\"toolId\":\"" + toolId + "\",\"argsJson\":\"{}\"}]}");
}

std::string ExecuteCall(const std::string& sessionId,
                        const std::string& callId) {
  return wb::invokeDomain("ai", "executeToolCall",
                          "{\"sessionId\":\"" + sessionId +
                              "\",\"toolCallId\":\"" + callId + "\"}");
}

std::string CallArgs(const std::string& sessionId, const std::string& callId) {
  return "{\"sessionId\":\"" + sessionId + "\",\"toolCallId\":\"" + callId +
         "\"}";
}

}  // namespace

TEST_CASE("ai sessions create, get and close", "[ai]") {
  const std::string created = CreateSession();
  REQUIRE(JsonBool(created, "ok", true));
  REQUIRE(JsonString(created, "sessionId") == "ai-1");
  REQUIRE(JsonString(created, "boardId") == "board-1");
  REQUIRE(JsonString(created, "userId") == "alice");

  const std::string got =
      wb::invokeDomain("ai", "sessionGet", "{\"sessionId\":\"ai-1\"}");
  REQUIRE(JsonBool(got, "ok", true));
  REQUIRE(JsonNumber(got, "messageCount") == 0.0);
  REQUIRE(JsonString(got, "boardId") == "board-1");

  const std::string closed =
      wb::invokeDomain("ai", "sessionClose", "{\"sessionId\":\"ai-1\"}");
  REQUIRE(JsonBool(closed, "ok", true));
  REQUIRE(JsonBool(closed, "closed", true));

  const std::string gone =
      wb::invokeDomain("ai", "sessionGet", "{\"sessionId\":\"ai-1\"}");
  REQUIRE(JsonBool(gone, "ok", false));
  REQUIRE(JsonContains(gone, "NotFound"));

  // Required args.
  REQUIRE(JsonContains(wb::invokeDomain("ai", "sessionCreate",
                                        "{\"userId\":\"a\"}"),
                       "InvalidArgument"));
  REQUIRE(JsonContains(wb::invokeDomain("ai", "sessionCreate",
                                        "{\"boardId\":\"b\"}"),
                       "InvalidArgument"));
  REQUIRE(JsonContains(wb::invokeDomain("ai", "sessionGet", "{}"),
                       "InvalidArgument"));
}

TEST_CASE("ai sendMessage stores user messages and tool calls", "[ai]") {
  CreateSession();
  const std::string sent = SendWithCall("ai-1", "theme.list");
  REQUIRE(JsonBool(sent, "ok", true));
  REQUIRE(JsonNumber(sent, "messageCount") == 1.0);
  REQUIRE(JsonBool(sent, "stub", true));
  REQUIRE(JsonString(sent, "messageId") == "msg-1");

  const std::string listed = wb::invokeDomain(
      "ai", "listMessages", "{\"sessionId\":\"ai-1\"}");
  REQUIRE(JsonNumber(listed, "count") == 1.0);
  REQUIRE(JsonContains(listed, "\"role\":\"user\""));
  REQUIRE(JsonContains(listed, "\"id\":\"call-1\""));
  REQUIRE(JsonContains(listed, "theme.list"));
  REQUIRE(JsonContains(listed, "\"status\":\"pending\""));

  // Empty message and missing tool id are rejected.
  REQUIRE(JsonContains(wb::invokeDomain(
                           "ai", "sendMessage",
                           "{\"sessionId\":\"ai-1\",\"message\":\"\"}"),
                       "InvalidArgument"));
  REQUIRE(JsonContains(wb::invokeDomain(
                           "ai", "sendMessage",
                           "{\"sessionId\":\"ai-1\",\"message\":\"x\","
                           "\"toolCalls\":[{\"argsJson\":\"{}\"}]}"),
                       "InvalidArgument"));
}

TEST_CASE("ai sendAudio records a message", "[ai]") {
  CreateSession();
  const std::string sent = wb::invokeDomain(
      "ai", "sendAudio",
      "{\"sessionId\":\"ai-1\",\"audioData\":\"base64-xyz\"}");
  REQUIRE(JsonBool(sent, "ok", true));
  REQUIRE(JsonBool(sent, "stub", true));
  REQUIRE(JsonString(sent, "transcription") == "");

  const std::string listed = wb::invokeDomain(
      "ai", "listMessages", "{\"sessionId\":\"ai-1\"}");
  REQUIRE(JsonNumber(listed, "count") == 1.0);
  REQUIRE(JsonContains(listed, "base64-xyz"));

  REQUIRE(JsonContains(wb::invokeDomain("ai", "sendAudio",
                                        "{\"sessionId\":\"ai-1\"}"),
                       "InvalidArgument"));
}

TEST_CASE("ai executeToolCall runs the registry tool and audits it", "[ai]") {
  CreateSession();
  SendWithCall("ai-1", "theme.list");
  const std::string executed = ExecuteCall("ai-1", "call-1");
  REQUIRE(JsonBool(executed, "ok", true));
  REQUIRE(JsonBool(executed, "succeeded", true));
  REQUIRE(JsonString(executed, "toolId") == "theme.list");
  REQUIRE(JsonString(executed, "toolCallId") == "call-1");
  // The raw tool.execute response is echoed back inside "response".
  REQUIRE(JsonContains(executed, "\"response\":{\"ok\":true"));

  // The call record flips to success.
  const std::string listed = wb::invokeDomain(
      "ai", "listMessages", "{\"sessionId\":\"ai-1\"}");
  REQUIRE(JsonContains(listed, "\"status\":\"success\""));

  // Audited with fromAI=true and the session user.
  const std::string audited = wb::invokeDomain(
      "audit", "query",
      "{\"filter\":{\"fromAI\":true,\"toolId\":\"theme.list\"}}");
  REQUIRE(JsonNumber(audited, "count") >= 1.0);
  REQUIRE(JsonContains(audited, "alice"));

  // Re-executing a finished call conflicts.
  const std::string again = ExecuteCall("ai-1", "call-1");
  REQUIRE(JsonBool(again, "ok", false));
  REQUIRE(JsonContains(again, "Conflict"));

  // Unknown call ids are NotFound.
  REQUIRE(JsonContains(ExecuteCall("ai-1", "call-9"), "NotFound"));
  REQUIRE(JsonContains(ExecuteCall("ai-1", ""), "InvalidArgument"));
}

TEST_CASE("ai preview and cancel tool calls", "[ai]") {
  CreateSession();
  SendWithCall("ai-1", "theme.list");

  const std::string preview =
      wb::invokeDomain("ai", "previewToolCall", CallArgs("ai-1", "call-1"));
  REQUIRE(JsonBool(preview, "ok", true));
  REQUIRE(JsonBool(preview, "preview", true));
  REQUIRE(JsonContains(preview, "\"status\":\"pending\""));
  REQUIRE(JsonString(preview, "toolId") == "theme.list");

  const std::string cancelled =
      wb::invokeDomain("ai", "cancelToolCall", CallArgs("ai-1", "call-1"));
  REQUIRE(JsonBool(cancelled, "ok", true));
  REQUIRE(JsonBool(cancelled, "cancelled", true));
  REQUIRE(JsonContains(cancelled, "\"status\":\"cancelled\""));

  // A cancelled call can neither run nor be cancelled twice.
  REQUIRE(JsonContains(ExecuteCall("ai-1", "call-1"), "Conflict"));
  REQUIRE(JsonContains(wb::invokeDomain("ai", "cancelToolCall",
                                        CallArgs("ai-1", "call-1")),
                       "Conflict"));
}

TEST_CASE("ai setContext merges keys and validates", "[ai]") {
  CreateSession();
  const std::string first = wb::invokeDomain(
      "ai", "setContext",
      "{\"sessionId\":\"ai-1\",\"context\":{\"mode\":\"brainstorm\"}}");
  REQUIRE(JsonBool(first, "ok", true));
  REQUIRE(JsonContains(first, "brainstorm"));

  const std::string second = wb::invokeDomain(
      "ai", "setContext",
      "{\"sessionId\":\"ai-1\",\"context\":{\"count\":3}}");
  REQUIRE(JsonContains(second, "brainstorm"));  // shallow merge keeps keys
  REQUIRE(JsonContains(second, "\"count\":3"));

  REQUIRE(JsonContains(wb::invokeDomain("ai", "setContext",
                                        "{\"sessionId\":\"ai-1\"}"),
                       "InvalidArgument"));
  REQUIRE(JsonContains(wb::invokeDomain(
                           "ai", "setContext",
                           "{\"sessionId\":\"ai-1\",\"context\":\"nope\"}"),
                       "InvalidArgument"));
  REQUIRE(JsonContains(wb::invokeDomain("ai", "sessionGet",
                                        "{\"sessionId\":\"nope\"}"),
                       "NotFound"));
  REQUIRE(JsonContains(wb::invokeDomain("ai", "frobnicate", "{}"),
                       "NotFound"));
}
