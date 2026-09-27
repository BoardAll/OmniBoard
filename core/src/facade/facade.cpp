// facade/facade.cpp — thin C++ convenience layer (task package 1.2).
// Owns: core/src/facade. See facade.h.

#include "facade.h"

#include <nlohmann/json.hpp>

#include "wb/ffi/domain.h"

namespace wb::facade {

std::string call(const std::string& domain, const std::string& op,
                 const std::string& argsJson) {
  return invokeDomain(domain, op, argsJson.empty() ? "{}" : argsJson);
}

bool isOk(const std::string& response) {
  const auto parsed = nlohmann::json::parse(response, nullptr, false);
  return !parsed.is_discarded() && parsed.is_object() && parsed.value("ok", false);
}

Handle createBoard(const std::string& json) {
  const std::string response = call("board", "create", json.empty() ? "{}" : json);
  const auto parsed = nlohmann::json::parse(response, nullptr, false);
  if (parsed.is_discarded() || !parsed.value("ok", false)) {
    return kInvalidHandle;
  }
  const auto& result = parsed["result"];
  if (!result.is_object() || !result.contains("handle") || !result["handle"].is_number()) {
    return kInvalidHandle;
  }
  return result["handle"].get<uint64_t>();
}

std::string boardGet(Handle handle) {
  return call("board", "get", nlohmann::json{{"handle", handle}}.dump());
}

std::string boardDestroy(Handle handle) {
  return call("board", "destroy", nlohmann::json{{"handle", handle}}.dump());
}

std::string pageList(const BoardId& boardId) {
  return call("page", "list", nlohmann::json{{"boardId", boardId}}.dump());
}

std::string pageCreate(const BoardId& boardId, const std::string& pageJson) {
  nlohmann::json args;
  args["boardId"] = boardId;
  if (!pageJson.empty()) {
    args["page"] = nlohmann::json::parse(pageJson, nullptr, false);
  }
  return call("page", "create", args.dump());
}

std::string elementCreate(const PageId& pageId, const std::string& elementJson) {
  nlohmann::json args;
  args["pageId"] = pageId;
  if (!elementJson.empty()) {
    args["element"] = nlohmann::json::parse(elementJson, nullptr, false);
  }
  return call("element", "create", args.dump());
}

std::string elementList(const PageId& pageId) {
  return call("element", "list", nlohmann::json{{"pageId", pageId}}.dump());
}

std::string executeCommand(Handle handle, const std::string& commandJson) {
  nlohmann::json args;
  args["handle"] = handle;
  if (!commandJson.empty()) {
    args["command"] = nlohmann::json::parse(commandJson, nullptr, false);
  }
  return call("command", "execute", args.dump());
}

std::string executeTool(const ToolId& toolId, const std::string& argsJson) {
  nlohmann::json args;
  args["toolId"] = toolId;
  if (!argsJson.empty()) {
    args["args"] = nlohmann::json::parse(argsJson, nullptr, false);
  }
  return call("tool", "execute", args.dump());
}

}  // namespace wb::facade
