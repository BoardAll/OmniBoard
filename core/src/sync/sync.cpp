// sync/sync.cpp — domain "sync" (task package 1.7).
// Owns: core/src/sync.
//
// Ops (《C++ 核心引擎接口设计》§12.2 + ffI forwarding): connect,
// disconnect, status, setOffline, sendOperation, sync, queue,
// capabilities. The transport itself is a placeholder (互动预留
// M10.1/M10.2): operations sent while offline are queued locally and
// drained by `sync`, which is exactly the behaviour SyncManager needs
// once a real TCP / Socket.IO transport lands.

#include <mutex>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "providers.h"
#include "wb/ffi/domain.h"

namespace wb {
namespace {

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

/// Process-wide SyncManager placeholder state.
struct SyncState {
  std::mutex mutex;
  bool connected = false;
  bool offline = false;
  std::string endpoint;
  std::vector<nlohmann::json> pending;
  int syncedCount = 0;
  int sentCount = 0;
};

SyncState& State() {
  static SyncState state;
  return state;
}

nlohmann::json StatusJson(const SyncState& state) {
  nlohmann::json result;
  result["connected"] = state.connected;
  result["endpoint"] = state.endpoint;
  result["offline"] = state.offline;
  result["pendingCount"] = static_cast<int>(state.pending.size());
  result["sentCount"] = state.sentCount;
  result["syncedCount"] = state.syncedCount;
  result["transport"] = "websocket";  // placeholder type (M10.1)
  return result;
}

}  // namespace

class SyncDomain : public DomainHandler {
 public:
  std::string name() const override { return "sync"; }

  std::string handle(const std::string& op,
                     const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "connect") return Connect(args);
    if (op == "disconnect") return Disconnect(args);
    if (op == "status") return Status(args);
    if (op == "setOffline" || op == "set_offline") return SetOffline(args);
    if (op == "sendOperation" || op == "send_operation") {
      return SendOperation(args);
    }
    if (op == "sync") return Sync(args);
    if (op == "queue" || op == "pending") return Queue(args);
    if (op == "capabilities" || op == "providers") return Capabilities(args);
    return domainError("NotFound", "unknown sync op: " + op);
  }

 private:
  std::string Connect(const nlohmann::json& args) {
    const std::string endpoint = args.value("endpoint", std::string());
    if (endpoint.empty()) {
      return domainError("InvalidArgument", "args.endpoint is required");
    }
    SyncState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.connected) {
      return domainError("Conflict", "already connected to " + state.endpoint);
    }
    // Placeholder transport: the handshake succeeds immediately.
    state.connected = true;
    state.endpoint = endpoint;
    return domainOk(StatusJson(state).dump());
  }

  std::string Disconnect(const nlohmann::json& args) {
    (void)args;
    SyncState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    state.connected = false;
    state.endpoint.clear();
    return domainOk(StatusJson(state).dump());
  }

  std::string Status(const nlohmann::json& args) {
    (void)args;
    SyncState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    return domainOk(StatusJson(state).dump());
  }

  std::string SetOffline(const nlohmann::json& args) {
    if (!args.contains("offline")) {
      return domainError("InvalidArgument", "args.offline is required");
    }
    bool offline = false;
    if (args["offline"].is_boolean()) {
      offline = args["offline"].get<bool>();
    } else if (args["offline"].is_number()) {
      offline = args["offline"].get<double>() != 0.0;
    } else {
      return domainError("InvalidArgument",
                         "args.offline must be a boolean");
    }
    SyncState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    state.offline = offline;
    return domainOk(StatusJson(state).dump());
  }

  std::string SendOperation(const nlohmann::json& args) {
    if (!args.contains("operation")) {
      return domainError("InvalidArgument", "args.operation is required");
    }
    SyncState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    nlohmann::json result;
    if (state.connected && !state.offline) {
      state.sentCount += 1;
      state.syncedCount += 1;
      result["sent"] = true;
    } else {
      state.pending.push_back(args["operation"]);
      result["queued"] = true;
      result["sent"] = false;
    }
    result["pendingCount"] = static_cast<int>(state.pending.size());
    result["syncedCount"] = state.syncedCount;
    return domainOk(result.dump());
  }

  std::string Sync(const nlohmann::json& args) {
    (void)args;
    SyncState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.connected) {
      return domainError("Conflict", "sync transport is not connected");
    }
    if (state.offline) {
      return domainError("Conflict", "offline mode defers sync");
    }
    const int synced = static_cast<int>(state.pending.size());
    state.pending.clear();
    state.syncedCount += synced;
    nlohmann::json result;
    result["pendingCount"] = 0;
    result["synced"] = synced;
    result["syncedCount"] = state.syncedCount;
    return domainOk(result.dump());
  }

  std::string Queue(const nlohmann::json& args) {
    (void)args;
    SyncState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    nlohmann::json operations = nlohmann::json::array();
    for (const nlohmann::json& op : state.pending) operations.push_back(op);
    nlohmann::json result;
    result["operations"] = std::move(operations);
    result["pendingCount"] = static_cast<int>(result["operations"].size());
    return domainOk(result.dump());
  }

  std::string Capabilities(const nlohmann::json& args) {
    (void)args;
    nlohmann::json providers = nlohmann::json::array();
    for (const reserved::ProviderDescriptor& descriptor :
         reserved::ReservedProviders()) {
      nlohmann::json item;
      item["implemented"] = descriptor.implemented;
      item["methods"] = descriptor.methods;
      item["name"] = descriptor.name;
      providers.push_back(std::move(item));
    }
    nlohmann::json transports = nlohmann::json::array();
    for (const char* type :
         {"websocket", "tcp", "socketio", "webrtc", "quic"}) {
      nlohmann::json item;
      item["implemented"] = false;
      item["type"] = type;
      transports.push_back(std::move(item));
    }
    nlohmann::json result;
    result["providers"] = std::move(providers);
    result["providerCount"] =
        static_cast<int>(result["providers"].size());
    result["reserved"] = true;
    result["transports"] = std::move(transports);
    return domainOk(result.dump());
  }
};

WB_REGISTER_DOMAIN(SyncDomain)

}  // namespace wb
