// audit/audit.cpp — domain "audit" (task package 1.7).
// Owns: core/src/audit.
//
// Ops (《C++ 核心引擎接口设计》§13.2 + FFI forwarding): log, query,
// export, clear. AuditLog is a process-wide append-only list of entries;
// `log` stamps a monotonic "audit-N" id and a millisecond timestamp.
// `query` filters by userId / toolId / fromAI / since / until / limit in
// insertion (chronological) order. `export` writes JSON-lines (one
// `entry.dump()` per line) exactly as the design doc's exportToFile.
//
// The tool layer and the AI/MCP domains are expected to call
// invokeDomain("audit", "log", ...) after each tool execution; the FFI
// only exposes query/export today.

#include <cstdint>
#include <fstream>
#include <mutex>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "wb/ffi/domain.h"
#include "wb/platform/platform.h"

namespace wb {
namespace {

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

/// Process-wide audit log; guarded by its own mutex (no scene dependency).
struct AuditState {
  std::mutex mutex;
  nlohmann::json entries = nlohmann::json::array();
  int nextId = 0;
};

AuditState& State() {
  static AuditState state;
  return state;
}

}  // namespace

class AuditDomain : public DomainHandler {
 public:
  std::string name() const override { return "audit"; }

  std::string handle(const std::string& op,
                     const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "log" || op == "append") return Log(args);
    if (op == "query" || op == "list") return Query(args);
    if (op == "export") return Export(args);
    if (op == "clear") return Clear(args);
    return domainError("NotFound", "unknown audit op: " + op);
  }

 private:
  std::string Log(const nlohmann::json& args) {
    nlohmann::json entry =
        args.value("entry", nlohmann::json::object());
    if (!entry.is_object() || entry.empty()) {
      return domainError("InvalidArgument", "args.entry is required");
    }
    const std::string userId = entry.value("userId", std::string());
    if (userId.empty()) {
      return domainError("InvalidArgument", "entry.userId is required");
    }
    const std::string toolId = entry.value("toolId", std::string());
    if (toolId.empty()) {
      return domainError("InvalidArgument", "entry.toolId is required");
    }

    AuditState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    // Normalize optional fields so every stored entry has a stable shape.
    if (!entry.contains("argsJson")) entry["argsJson"] = "";
    if (!entry.contains("resultJson")) entry["resultJson"] = "";
    if (!entry.contains("fromAI")) entry["fromAI"] = false;
    if (!entry.contains("ip")) entry["ip"] = "";
    if (!entry.contains("userAgent")) entry["userAgent"] = "";
    if (!entry.contains("timestamp")) entry["timestamp"] = timeMillis();
    entry["id"] = "audit-" + std::to_string(++state.nextId);
    state.entries.push_back(entry);

    nlohmann::json result;
    result["count"] = static_cast<int>(state.entries.size());
    result["id"] = entry["id"];
    result["timestamp"] = entry["timestamp"];
    return domainOk(result.dump());
  }

  std::string Query(const nlohmann::json& args) {
    nlohmann::json filter = args.value("filter", nlohmann::json::object());
    if (!filter.is_object()) {
      return domainError("InvalidArgument", "args.filter must be an object");
    }
    const std::string userId = filter.value("userId", std::string());
    const std::string toolId = filter.value("toolId", std::string());
    const std::int64_t since = filter.value("since", std::int64_t(0));
    const std::int64_t until =
        filter.value("until", std::int64_t(INT64_MAX));
    int limit = 0;
    if (filter.contains("limit")) {
      if (!filter["limit"].is_number_integer()) {
        return domainError("InvalidArgument", "filter.limit must be an integer");
      }
      limit = filter["limit"].get<int>();
      if (limit < 1) {
        return domainError("InvalidArgument", "filter.limit must be >= 1");
      }
    }
    const bool hasFromAI = filter.contains("fromAI");
    bool fromAI = false;
    if (hasFromAI) {
      if (filter["fromAI"].is_boolean()) {
        fromAI = filter["fromAI"].get<bool>();
      } else if (filter["fromAI"].is_number()) {
        fromAI = filter["fromAI"].get<double>() != 0.0;
      } else {
        return domainError("InvalidArgument",
                           "filter.fromAI must be a boolean");
      }
    }

    AuditState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    nlohmann::json entries = nlohmann::json::array();
    for (const nlohmann::json& entry : state.entries) {
      if (!userId.empty() &&
          entry.value("userId", std::string()) != userId) {
        continue;
      }
      if (!toolId.empty() &&
          entry.value("toolId", std::string()) != toolId) {
        continue;
      }
      if (hasFromAI && entry.value("fromAI", false) != fromAI) continue;
      const std::int64_t timestamp =
          entry.value("timestamp", std::int64_t(0));
      if (timestamp < since || timestamp > until) continue;
      entries.push_back(entry);
      if (limit > 0 && static_cast<int>(entries.size()) >= limit) break;
    }
    nlohmann::json result;
    result["count"] = static_cast<int>(entries.size());
    result["entries"] = std::move(entries);
    return domainOk(result.dump());
  }

  std::string Export(const nlohmann::json& args) {
    const std::string path = args.value("path", std::string());
    if (path.empty()) {
      return domainError("InvalidArgument", "args.path is required");
    }

    AuditState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file.is_open()) {
      return domainError("InternalError", "cannot open file: " + path);
    }
    std::size_t bytes = 0;
    for (const nlohmann::json& entry : state.entries) {
      const std::string line = entry.dump();
      file << line << '\n';
      bytes += line.size() + 1;
    }
    file.flush();
    if (!file.good()) {
      return domainError("InternalError", "cannot write file: " + path);
    }
    file.close();

    nlohmann::json result;
    result["bytes"] = static_cast<double>(bytes);
    result["exported"] = static_cast<int>(state.entries.size());
    result["path"] = path;
    return domainOk(result.dump());
  }

  std::string Clear(const nlohmann::json& args) {
    (void)args;
    AuditState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    const int removed = static_cast<int>(state.entries.size());
    state.entries = nlohmann::json::array();
    nlohmann::json result;
    result["removed"] = removed;
    return domainOk(result.dump());
  }
};

WB_REGISTER_DOMAIN(AuditDomain)

}  // namespace wb
