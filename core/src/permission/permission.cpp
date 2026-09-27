// permission/permission.cpp — domain "permission" (task package 1.7).
// Owns: core/src/permission.
//
// Ops (《C++ 核心引擎接口设计》§13.1 + FFI forwarding): check, grant,
// revoke, list. The ACL is a process-wide map keyed by (boardId, userId)
// holding the *highest* granted level; the level hierarchy is Read <
// Write < Share < Admin, so a higher level implicitly satisfies lower
// permission requests (design doc §13.1). Permission names are matched
// case-insensitively; unknown names are rejected with InvalidArgument.
//
// grant keeps the maximum of the current and requested levels (granting
// never lowers). revoke removes the whole grant when the current level
// covers the requested one, mirroring PermissionManager::revoke; a
// revoke for a level that is not held is an idempotent no-op.

#include <algorithm>
#include <cctype>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "wb/ffi/domain.h"

namespace wb {
namespace {

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

// --- permission levels ------------------------------------------------------

enum class Level {
  None = 0,
  Read = 1,
  Write = 2,
  Share = 3,
  Admin = 4,
};

const char* LevelName(Level level) {
  switch (level) {
    case Level::Read: return "read";
    case Level::Write: return "write";
    case Level::Share: return "share";
    case Level::Admin: return "admin";
    default: return "none";
  }
}

/// Case-insensitive name -> level. Returns Level::None for unknown names;
/// `ok` distinguishes the "none" name from a parse failure.
Level ParseLevel(const std::string& name, bool* ok) {
  std::string lower = name;
  std::transform(lower.begin(), lower.end(), lower.begin(),
                 [](unsigned char c) { return static_cast<char>(::tolower(c)); });
  *ok = true;
  if (lower == "read") return Level::Read;
  if (lower == "write") return Level::Write;
  if (lower == "share") return Level::Share;
  if (lower == "admin") return Level::Admin;
  if (lower == "none") return Level::None;
  *ok = false;
  return Level::None;
}

// --- process-wide ACL -------------------------------------------------------

struct AclState {
  std::mutex mutex;
  // boardId -> userId -> highest granted level.
  std::map<std::string, std::map<std::string, Level>> acl;
};

AclState& State() {
  static AclState state;
  return state;
}

}  // namespace

class PermissionDomain : public DomainHandler {
 public:
  std::string name() const override { return "permission"; }

  std::string handle(const std::string& op,
                     const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "check") return Check(args);
    if (op == "grant" || op == "set") return Grant(args);
    if (op == "revoke" || op == "remove") return Revoke(args);
    if (op == "list") return List(args);
    if (op == "levels" || op == "hierarchy") return Levels(args);
    return domainError("NotFound", "unknown permission op: " + op);
  }

 private:
  /// Reads and validates userId / boardId / permission from args.
  /// Returns false and fills *response with the error JSON on failure.
  static bool ReadKey(const nlohmann::json& args, std::string* userId,
                      std::string* boardId, Level* level, bool* hasLevel,
                      std::string* response) {
    *userId = args.value("userId", std::string());
    if (userId->empty()) {
      *response = domainError("InvalidArgument", "args.userId is required");
      return false;
    }
    *boardId = args.value("boardId", std::string());
    if (boardId->empty()) {
      *response = domainError("InvalidArgument", "args.boardId is required");
      return false;
    }
    *hasLevel = false;
    if (args.contains("permission")) {
      if (!args["permission"].is_string()) {
        *response = domainError("InvalidArgument",
                                "args.permission must be a string");
        return false;
      }
      bool ok = false;
      *level = ParseLevel(args["permission"].get<std::string>(), &ok);
      if (!ok) {
        *response = domainError(
            "InvalidArgument",
            "unknown permission: " + args["permission"].get<std::string>());
        return false;
      }
      *hasLevel = true;
    }
    return true;
  }

  std::string Check(const nlohmann::json& args) {
    std::string userId;
    std::string boardId;
    Level requested = Level::Read;
    bool hasLevel = false;
    std::string response;
    if (!ReadKey(args, &userId, &boardId, &requested, &hasLevel, &response)) {
      return response;
    }
    if (!hasLevel) requested = Level::Read;  // FFI default: read

    AclState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    Level held = Level::None;
    auto board = state.acl.find(boardId);
    if (board != state.acl.end()) {
      auto user = board->second.find(userId);
      if (user != board->second.end()) held = user->second;
    }
    nlohmann::json result;
    result["allowed"] = static_cast<int>(held) >= static_cast<int>(requested);
    result["boardId"] = boardId;
    result["level"] = LevelName(held);
    result["userId"] = userId;
    return domainOk(result.dump());
  }

  std::string Grant(const nlohmann::json& args) {
    std::string userId;
    std::string boardId;
    Level requested = Level::None;
    bool hasLevel = false;
    std::string response;
    if (!ReadKey(args, &userId, &boardId, &requested, &hasLevel, &response)) {
      return response;
    }
    if (!hasLevel || requested == Level::None) {
      return domainError("InvalidArgument", "args.permission is required");
    }

    AclState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    Level& held = state.acl[boardId][userId];
    const bool raised = static_cast<int>(requested) > static_cast<int>(held);
    if (raised) held = requested;
    nlohmann::json result;
    result["boardId"] = boardId;
    result["granted"] = true;
    result["level"] = LevelName(held);
    result["raised"] = raised;
    result["userId"] = userId;
    return domainOk(result.dump());
  }

  std::string Revoke(const nlohmann::json& args) {
    std::string userId;
    std::string boardId;
    Level requested = Level::None;
    bool hasLevel = false;
    std::string response;
    if (!ReadKey(args, &userId, &boardId, &requested, &hasLevel, &response)) {
      return response;
    }
    if (!hasLevel || requested == Level::None) {
      return domainError("InvalidArgument", "args.permission is required");
    }

    AclState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    bool revoked = false;
    auto board = state.acl.find(boardId);
    if (board != state.acl.end()) {
      auto user = board->second.find(userId);
      if (user != board->second.end() &&
          static_cast<int>(user->second) >= static_cast<int>(requested)) {
        board->second.erase(user);
        if (board->second.empty()) state.acl.erase(board);
        revoked = true;
      }
    }
    nlohmann::json result;
    result["boardId"] = boardId;
    result["revoked"] = revoked;
    result["userId"] = userId;
    return domainOk(result.dump());
  }

  std::string List(const nlohmann::json& args) {
    const std::string boardId = args.value("boardId", std::string());
    const std::string userId = args.value("userId", std::string());

    AclState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    nlohmann::json entries = nlohmann::json::array();
    for (const auto& [board, users] : state.acl) {
      if (!boardId.empty() && board != boardId) continue;
      for (const auto& [user, level] : users) {
        if (!userId.empty() && user != userId) continue;
        nlohmann::json item;
        item["boardId"] = board;
        item["level"] = LevelName(level);
        item["value"] = static_cast<int>(level);
        item["userId"] = user;
        entries.push_back(std::move(item));
      }
    }
    nlohmann::json result;
    result["count"] = static_cast<int>(entries.size());
    result["entries"] = std::move(entries);
    return domainOk(result.dump());
  }

  std::string Levels(const nlohmann::json& args) {
    (void)args;
    nlohmann::json levels = nlohmann::json::array();
    for (const Level level : {Level::Read, Level::Write, Level::Share,
                              Level::Admin}) {
      nlohmann::json item;
      item["name"] = LevelName(level);
      item["value"] = static_cast<int>(level);
      levels.push_back(std::move(item));
    }
    nlohmann::json result;
    result["levels"] = std::move(levels);
    return domainOk(result.dump());
  }
};

WB_REGISTER_DOMAIN(PermissionDomain)

}  // namespace wb
