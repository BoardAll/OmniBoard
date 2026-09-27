// command/command_bus.cpp — CommandBus: execution, transactions, undo/redo
// (task package 1.2). Owns: core/src/command.
//
// Domain "command" ops:
//   execute {handle, command:{type:"domain.op", params?, ...}}
//       -> forwards to invokeDomain(domain, op, params); records undo entry
//          carrying an inferred inverse when the result allows it.
//       -> type "batch" executes params.ops in order; on failure rolls back
//          already-executed ops in reverse order.
//   undo    {handle} -> pops one undo entry, invokes its inverse
//   redo    {handle} -> re-applies the last undone entry
//   history {handle} -> {"undo":[...], "redo":[...], "undoCount", "redoCount"}
//
// Inverse protocol: a module may return {"inverse":{"domain","op","args"}}
// inside its result; otherwise a generic suffix table is applied
// (create->delete, delete->create via result.deleted, update->update via
// result.previous, move->move via result.previousIndex).

#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "wb/base/log.h"
#include "wb/ffi/domain.h"

namespace wb {
namespace {

constexpr const char* kTag = "command";

std::string MapDomain(const std::string& prefix) {
  if (prefix == "3d") return "render3d";
  return prefix;
}

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

struct Entry {
  std::string type;
  std::string domain;
  std::string op;
  nlohmann::json args;      // forward args
  nlohmann::json inverse;   // {"domain","op","args"} or null (not undoable)
};

struct BoardHistory {
  std::deque<Entry> undo;
  std::deque<Entry> redo;
};

std::mutex& HistoryMutex() {
  static std::mutex mutex;
  return mutex;
}

std::map<uint64_t, BoardHistory>& Histories() {
  static std::map<uint64_t, BoardHistory> histories;
  return histories;
}

// --- Inverse inference -------------------------------------------------------

nlohmann::json MakeCall(const std::string& domain, const std::string& op,
                        nlohmann::json args) {
  nlohmann::json call;
  call["domain"] = domain;
  call["op"] = op;
  call["args"] = std::move(args);
  return call;
}

std::string PickIdKey(const nlohmann::json& result, const nlohmann::json& args) {
  for (const char* key : {"elementId", "pageId", "boardId"}) {
    if (result.contains(key) && result[key].is_string()) return key;
    if (args.contains(key) && args[key].is_string()) return key;
  }
  return std::string();
}

nlohmann::json InferInverse(const std::string& domain, const std::string& op,
                            const nlohmann::json& args, const nlohmann::json& result) {
  if (result.is_object() && result.contains("inverse") && result["inverse"].is_object()) {
    return result["inverse"];
  }
  const std::string idKey = PickIdKey(result, args);
  const std::string idValue = idKey.empty() ? std::string() : result.value(idKey, args.value(idKey, std::string()));

  if (op == "create" && !idKey.empty()) {
    return MakeCall(domain, "delete", {{idKey, idValue}});
  }
  if (op == "delete" && result.contains("deleted") && result["deleted"].is_object()) {
    nlohmann::json inverseArgs;
    inverseArgs[domain == "page" ? "page" : "element"] = result["deleted"];
    if (result.contains("boardId")) inverseArgs["boardId"] = result["boardId"];
    else if (args.contains("boardId")) inverseArgs["boardId"] = args["boardId"];
    return MakeCall(domain, "create", std::move(inverseArgs));
  }
  if (op == "update" && result.contains("previous") && result["previous"].is_object()) {
    nlohmann::json inverseArgs;
    inverseArgs["patch"] = result["previous"];
    if (!idKey.empty()) inverseArgs[idKey] = idValue;
    return MakeCall(domain, "update", std::move(inverseArgs));
  }
  if (op == "move" && result.contains("previousIndex") && result["previousIndex"].is_number()) {
    nlohmann::json inverseArgs;
    inverseArgs["newIndex"] = result["previousIndex"];
    if (!idKey.empty()) inverseArgs[idKey] = idValue;
    return MakeCall(domain, "move", std::move(inverseArgs));
  }
  return nlohmann::json();  // null: not undoable
}

// --- Single command execution -------------------------------------------------

struct Outcome {
  std::string response;
  bool ok = false;
  nlohmann::json result;
  nlohmann::json inverse;
  std::string errorCode;
  std::string errorMessage;
};

Outcome RunCommand(uint64_t handle, const nlohmann::json& command) {
  Outcome outcome;
  if (!command.is_object()) {
    outcome.response = domainError("InvalidArgument", "command must be an object");
    return outcome;
  }
  const std::string type = command.value("type", std::string());
  if (type.empty()) {
    outcome.response = domainError("InvalidArgument", "command.type is required");
    return outcome;
  }
  const std::size_t dot = type.find('.');
  if (dot == std::string::npos || dot == 0 || dot + 1 >= type.size()) {
    outcome.response =
        domainError("InvalidArgument", "command.type must be 'domain.op': " + type);
    return outcome;
  }
  const std::string domain = MapDomain(type.substr(0, dot));
  const std::string op = type.substr(dot + 1);

  nlohmann::json cmdArgs = nlohmann::json::object();
  if (command.contains("params") && command["params"].is_object()) {
    cmdArgs = command["params"];
  } else {
    for (auto it = command.begin(); it != command.end(); ++it) {
      if (it.key() != "type" && it.key() != "params") cmdArgs[it.key()] = it.value();
    }
  }
  if (domain == "command") {
    cmdArgs["handle"] = handle;  // pass-through for undo/redo/history
  }

  outcome.response = invokeDomain(domain, op, cmdArgs.dump());
  const auto parsed = nlohmann::json::parse(outcome.response, nullptr, false);
  if (!parsed.is_discarded() && parsed.is_object()) {
    outcome.ok = parsed.value("ok", false);
    if (outcome.ok) {
      outcome.result = parsed.value("result", nlohmann::json::object());
      outcome.inverse = InferInverse(domain, op, cmdArgs, outcome.result);
    } else if (parsed.contains("error") && parsed["error"].is_object()) {
      outcome.errorCode = parsed["error"].value("code", std::string("InternalError"));
      outcome.errorMessage = parsed["error"].value("message", std::string());
    }
  } else {
    outcome.response = domainError("InternalError", "domain replied with invalid JSON");
  }
  return outcome;
}

void RecordEntry(uint64_t handle, const std::string& type, const std::string& domain,
                 const std::string& op, const nlohmann::json& args,
                 const nlohmann::json& inverse) {
  std::lock_guard<std::mutex> lock(HistoryMutex());
  BoardHistory& history = Histories()[handle];
  Entry entry;
  entry.type = type;
  entry.domain = domain;
  entry.op = op;
  entry.args = args;
  entry.inverse = inverse;
  history.undo.push_back(std::move(entry));
  history.redo.clear();
}

// --- Batch -------------------------------------------------------------------

std::string ExecuteBatch(uint64_t handle, const nlohmann::json& opsJson) {
  if (!opsJson.is_array() || opsJson.empty()) {
    return domainError("InvalidArgument", "params.ops must be a non-empty array");
  }
  std::vector<Entry> executed;
  for (std::size_t i = 0; i < opsJson.size(); ++i) {
    const Outcome outcome = RunCommand(handle, opsJson[i]);
    if (!outcome.ok) {
      // Roll back already-executed sub-commands in reverse order.
      for (auto it = executed.rbegin(); it != executed.rend(); ++it) {
        if (it->inverse.is_object()) {
          const std::string rollback = invokeDomain(
              it->inverse.value("domain", std::string()),
              it->inverse.value("op", std::string()),
              it->inverse.value("args", nlohmann::json::object()).dump());
          const auto parsed = nlohmann::json::parse(rollback, nullptr, false);
          if (parsed.is_discarded() || !parsed.value("ok", false)) {
            Logger::instance().warn(kTag, "batch rollback step failed for " + it->type);
          }
        }
      }
      nlohmann::json detail;
      detail["failedIndex"] = i;
      detail["failedType"] = opsJson[i].is_object()
                                 ? opsJson[i].value("type", std::string())
                                 : std::string();
      detail["cause"] = {{"code", outcome.errorCode}, {"message", outcome.errorMessage}};
      nlohmann::json response;
      response["ok"] = false;
      response["error"] = {{"code", "Conflict"},
                           {"message", "batch failed; executed ops were rolled back"},
                           {"detail", detail}};
      return response.dump();
    }
    Entry entry;
    entry.type = opsJson[i].is_object() ? opsJson[i].value("type", std::string())
                                        : std::string();
    const std::size_t dot = entry.type.find('.');
    entry.domain = MapDomain(entry.type.substr(0, dot));
    entry.op = entry.type.substr(dot + 1);
    if (opsJson[i].is_object() && opsJson[i].contains("params")) {
      entry.args = opsJson[i]["params"];
    }
    entry.inverse = outcome.inverse;
    executed.push_back(std::move(entry));
  }
  {
    std::lock_guard<std::mutex> lock(HistoryMutex());
    BoardHistory& history = Histories()[handle];
    for (auto& entry : executed) {
      history.undo.push_back(std::move(entry));
    }
    history.redo.clear();
  }
  return domainOk(nlohmann::json{{"executed", opsJson.size()}}.dump());
}

// --- Undo / redo / history ----------------------------------------------------

std::string DoUndo(uint64_t handle) {
  Entry entry;
  bool hasEntry = false;
  {
    std::lock_guard<std::mutex> lock(HistoryMutex());
    BoardHistory& history = Histories()[handle];
    if (history.undo.empty()) {
      return domainError("NotFound", "nothing to undo");
    }
    entry = std::move(history.undo.back());
    history.undo.pop_back();
    hasEntry = true;
  }
  if (!hasEntry) {
    return domainError("InternalError", "internal undo state error");
  }
  if (!entry.inverse.is_object()) {
    // Not undoable: discard the entry to keep stacks consistent.
    return domainError("Conflict", "command is not undoable: " + entry.type);
  }
  const std::string response =
      invokeDomain(entry.inverse.value("domain", std::string()),
                   entry.inverse.value("op", std::string()),
                   entry.inverse.value("args", nlohmann::json::object()).dump());
  const auto parsed = nlohmann::json::parse(response, nullptr, false);
  if (parsed.is_discarded() || !parsed.value("ok", false)) {
    // Restore the entry so the user can retry after fixing the state.
    std::lock_guard<std::mutex> lock(HistoryMutex());
    Histories()[handle].undo.push_back(std::move(entry));
    return domainError("Conflict", "undo failed: " + response);
  }
  {
    std::lock_guard<std::mutex> lock(HistoryMutex());
    Histories()[handle].redo.push_back(std::move(entry));
  }
  return domainOk(nlohmann::json{{"undone", 1}}.dump());
}

std::string DoRedo(uint64_t handle) {
  Entry entry;
  {
    std::lock_guard<std::mutex> lock(HistoryMutex());
    BoardHistory& history = Histories()[handle];
    if (history.redo.empty()) {
      return domainError("NotFound", "nothing to redo");
    }
    entry = std::move(history.redo.back());
    history.redo.pop_back();
  }
  const std::string response =
      invokeDomain(entry.domain, entry.op, entry.args.dump());
  const auto parsed = nlohmann::json::parse(response, nullptr, false);
  if (parsed.is_discarded() || !parsed.value("ok", false)) {
    std::lock_guard<std::mutex> lock(HistoryMutex());
    Histories()[handle].redo.push_back(std::move(entry));
    return domainError("Conflict", "redo failed: " + response);
  }
  std::lock_guard<std::mutex> lock(HistoryMutex());
  Histories()[handle].undo.push_back(std::move(entry));
  return domainOk(nlohmann::json{{"redone", 1}}.dump());
}

std::string DoHistory(uint64_t handle) {
  std::lock_guard<std::mutex> lock(HistoryMutex());
  BoardHistory& history = Histories()[handle];
  nlohmann::json undo = nlohmann::json::array();
  for (auto it = history.undo.rbegin(); it != history.undo.rend(); ++it) {
    undo.push_back({{"type", it->type},
                    {"undoable", it->inverse.is_object()}});
  }
  nlohmann::json redo = nlohmann::json::array();
  for (auto it = history.redo.rbegin(); it != history.redo.rend(); ++it) {
    redo.push_back({{"type", it->type}});
  }
  nlohmann::json result;
  result["undo"] = std::move(undo);
  result["redo"] = std::move(redo);
  result["undoCount"] = history.undo.size();
  result["redoCount"] = history.redo.size();
  return domainOk(result.dump());
}

// --- Domain handler ----------------------------------------------------------

class CommandDomain : public DomainHandler {
 public:
  std::string name() const override { return "command"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (!args.contains("handle") || !args["handle"].is_number()) {
      // undo/redo/history/execute all need a board handle.
      return domainError("InvalidArgument", "args.handle (board handle) is required");
    }
    const uint64_t handle = args["handle"].get<uint64_t>();

    if (op == "execute") {
      if (!args.contains("command")) {
        return domainError("InvalidArgument", "args.command is required");
      }
      const nlohmann::json& command = args["command"];
      if (command.is_object() && command.value("type", std::string()) == "batch") {
        const nlohmann::json ops =
            command.contains("params") && command["params"].is_object() &&
                    command["params"].contains("ops")
                ? command["params"]["ops"]
                : nlohmann::json::array();
        return ExecuteBatch(handle, ops);
      }
      const Outcome outcome = RunCommand(handle, command);
      if (outcome.ok) {
        const std::string type = command.is_object() ? command.value("type", std::string())
                                                     : std::string();
        const std::size_t dot = type.find('.');
        if (dot != std::string::npos) {
          const std::string domain = MapDomain(type.substr(0, dot));
          if (domain != "command") {
            nlohmann::json cmdArgs = nlohmann::json::object();
            if (command.contains("params") && command["params"].is_object()) {
              cmdArgs = command["params"];
            } else {
              for (auto it = command.begin(); it != command.end(); ++it) {
                if (it.key() != "type" && it.key() != "params") {
                  cmdArgs[it.key()] = it.value();
                }
              }
            }
            RecordEntry(handle, type, domain, type.substr(dot + 1), cmdArgs,
                        outcome.inverse);
          }
        }
      }
      return outcome.response;
    }
    if (op == "undo") return DoUndo(handle);
    if (op == "redo") return DoRedo(handle);
    if (op == "history") return DoHistory(handle);
    return domainError("NotFound", "unknown command op: " + op);
  }
};

}  // namespace

WB_REGISTER_DOMAIN(CommandDomain)

}  // namespace wb
