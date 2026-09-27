// tests/unit/command/command_test.cpp — CommandBus (task package 1.2).
// Tags: [command]

#include <catch2/catch_test_macros.hpp>

#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "wb/ffi/domain.h"

namespace {

std::mutex g_mutex;
std::vector<std::string> g_log;

void AppendLog(const std::string& entry) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_log.push_back(entry);
}

void ClearLog() {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_log.clear();
}

std::vector<std::string> Snapshot() {
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_log;
}

std::string ExtractString(const std::string& json, const std::string& key) {
  const std::string needle = "\"" + key + "\":\"";
  const auto pos = json.find(needle);
  if (pos == std::string::npos) return std::string();
  const auto begin = pos + needle.size();
  const auto end = json.find('"', begin);
  if (end == std::string::npos) return std::string();
  return json.substr(begin, end - begin);
}

bool Contains(const std::string& haystack, const std::string& needle) {
  return haystack.find(needle) != std::string::npos;
}

// Fake target domain exercised through the CommandBus.
class CmdTestDomain : public wb::DomainHandler {
 public:
  std::string name() const override { return "cmdtest"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    if (op == "create") {
      AppendLog("create");
      return "{\"ok\":true,\"result\":{\"elementId\":\"e-1\",\"pageId\":\"p-1\"}}";
    }
    if (op == "delete") {
      const std::string id = ExtractString(argsJson, "elementId");
      if (id.empty()) {
        return "{\"ok\":false,\"error\":{\"code\":\"InvalidArgument\","
               "\"message\":\"elementId required\"}}";
      }
      AppendLog("delete:" + id);
      if (id == "missing") {
        return "{\"ok\":false,\"error\":{\"code\":\"NotFound\","
               "\"message\":\"no such element\"}}";
      }
      return "{\"ok\":true,\"result\":{\"elementId\":\"" + id +
             "\",\"deleted\":{\"id\":\"" + id + "\"}}}";
    }
    if (op == "update") {
      const std::string id = ExtractString(argsJson, "elementId");
      AppendLog("update:" + id);
      return "{\"ok\":true,\"result\":{\"elementId\":\"" + id +
             "\",\"previous\":{\"style\":{\"fill\":\"#111111FF\"}}}}";
    }
    return "{\"ok\":false,\"error\":{\"code\":\"NotFound\",\"message\":"
           "\"unknown op\"}}";
  }
};

void EnsureRegistered() { wb::registerDomain(std::make_unique<CmdTestDomain>()); }

}  // namespace

TEST_CASE("command execute forwards and records history", "[command]") {
  EnsureRegistered();
  ClearLog();

  const std::string response = wb::invokeDomain(
      "command", "execute",
      R"({"handle":101,"command":{"type":"cmdtest.create","params":{}}})");
  REQUIRE(Contains(response, "\"ok\":true"));
  REQUIRE(Snapshot() == std::vector<std::string>{"create"});

  const std::string history =
      wb::invokeDomain("command", "history", R"({"handle":101})");
  REQUIRE(Contains(history, "\"undoCount\":1"));
  REQUIRE(Contains(history, "\"redoCount\":0"));
}

TEST_CASE("undo uses inferred inverse delete, redo re-applies", "[command]") {
  EnsureRegistered();
  ClearLog();

  REQUIRE(Contains(wb::invokeDomain(
                      "command", "execute",
                      R"({"handle":102,"command":{"type":"cmdtest.create","params":{}}})"),
                  "\"ok\":true"));

  const std::string undo = wb::invokeDomain("command", "undo", R"({"handle":102})");
  REQUIRE(Contains(undo, "\"ok\":true"));

  const auto log = Snapshot();
  REQUIRE(log == std::vector<std::string>{"create", "delete:e-1"});

  std::string history = wb::invokeDomain("command", "history", R"({"handle":102})");
  REQUIRE(Contains(history, "\"undoCount\":0"));
  REQUIRE(Contains(history, "\"redoCount\":1"));

  const std::string redo = wb::invokeDomain("command", "redo", R"({"handle":102})");
  REQUIRE(Contains(redo, "\"ok\":true"));
  REQUIRE(Snapshot().back() == "create");

  history = wb::invokeDomain("command", "history", R"({"handle":102})");
  REQUIRE(Contains(history, "\"undoCount\":1"));
}

TEST_CASE("undo with empty stack and bad commands fail cleanly", "[command]") {
  REQUIRE(Contains(wb::invokeDomain("command", "undo", R"({"handle":103})"),
                   "\"code\":\"NotFound\""));
  REQUIRE(Contains(wb::invokeDomain("command", "redo", R"({"handle":103})"),
                   "\"code\":\"NotFound\""));

  // Unknown target domain -> error, nothing recorded.
  const std::string unknown = wb::invokeDomain(
      "command", "execute",
      R"({"handle":103,"command":{"type":"no_such_domain_qq.op","params":{}}})");
  REQUIRE(Contains(unknown, "\"ok\":false"));

  // Type without a dot is structurally invalid.
  REQUIRE(Contains(wb::invokeDomain(
                       "command", "execute",
                       R"({"handle":103,"command":{"type":"nodot","params":{}}})"),
                   "\"code\":\"InvalidArgument\""));

  // Missing handle.
  REQUIRE(Contains(wb::invokeDomain(
                       "command", "execute",
                       R"({"command":{"type":"cmdtest.create"}})"),
                   "\"code\":\"InvalidArgument\""));

  // Unknown op on the command domain itself.
  REQUIRE(Contains(wb::invokeDomain("command", "explode", R"({"handle":103})"),
                   "\"code\":\"NotFound\""));
}

TEST_CASE("batch failure rolls back executed ops in reverse order", "[command]") {
  EnsureRegistered();
  ClearLog();

  const std::string response = wb::invokeDomain(
      "command", "execute",
      R"({"handle":104,"command":{"type":"batch","params":{"ops":[
          {"type":"cmdtest.create","params":{}},
          {"type":"cmdtest.update","params":{"elementId":"e-1"}},
          {"type":"cmdtest.delete","params":{"elementId":"missing"}}
      ]}}})");
  REQUIRE(Contains(response, "\"ok\":false"));
  REQUIRE(Contains(response, "\"code\":\"Conflict\""));
  REQUIRE(Contains(response, "\"failedIndex\":2"));

  // create, update, failed delete, rollback of update, rollback of create.
  const std::vector<std::string> expected = {
      "create", "update:e-1", "delete:missing", "update:e-1", "delete:e-1"};
  REQUIRE(Snapshot() == expected);

  // Nothing recorded in history after a failed batch.
  const std::string history =
      wb::invokeDomain("command", "history", R"({"handle":104})");
  REQUIRE(Contains(history, "\"undoCount\":0"));
}

TEST_CASE("batch success records each op for individual undo", "[command]") {
  EnsureRegistered();
  ClearLog();

  const std::string response = wb::invokeDomain(
      "command", "execute",
      R"({"handle":105,"command":{"type":"batch","params":{"ops":[
          {"type":"cmdtest.create","params":{}},
          {"type":"cmdtest.update","params":{"elementId":"e-2"}}
      ]}}})");
  REQUIRE(Contains(response, "\"ok\":true"));
  REQUIRE(Contains(response, "\"executed\":2"));

  std::string history = wb::invokeDomain("command", "history", R"({"handle":105})");
  REQUIRE(Contains(history, "\"undoCount\":2"));

  // Undo pops in reverse order: update first, then create.
  REQUIRE(Contains(wb::invokeDomain("command", "undo", R"({"handle":105})"),
                   "\"ok\":true"));
  REQUIRE(Contains(wb::invokeDomain("command", "undo", R"({"handle":105})"),
                   "\"ok\":true"));
  const auto log = Snapshot();
  REQUIRE(log.size() >= 4);
  REQUIRE(log[log.size() - 2] == "update:e-2");
  REQUIRE(log[log.size() - 1] == "delete:e-1");
}
