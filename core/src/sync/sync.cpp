// sync/sync.cpp — domain "sync" (task package 1.7 / M1 T1.1 + T1.2).
// Owns: core/src/sync.
//
// Ops (《C++ 核心引擎接口设计》§12.2 + FFI forwarding): connect, disconnect,
// status, setOffline, join, sendOperation, sendPreview, sync (flush),
// events (drain), queue, capabilities.
//
// M1 wires the real Socket.IO transport (socketio_transport.{h,cpp}) behind
// this domain. The domain itself stays transport-agnostic through
// sync::Transport + MakeTransport(); the FFI caller thread owns every domain
// call, while transport worker threads only queue data (sioxx callbacks and
// the transport pump never call invokeDomain). Cross-domain calls
// (crdt.applyRemote inside "events") happen outside every module lock.

#include <algorithm>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

#include "providers.h"
#include "transport.h"
#include "wb/ffi/domain.h"

namespace wb {
namespace {

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

nlohmann::json DefaultRoom() {
  nlohmann::json room;
  room["locks"] = nlohmann::json::array();
  room["mode"] = "";
  room["participants"] = nlohmann::json::array();
  return room;
}

/// Process-wide SyncManager state (one whiteboard session per process).
struct SyncState {
  std::mutex mutex;
  bool offline = false;
  std::string endpoint;
  std::string boardId;
  std::string pageId;
  /// Server-issued per-connection identity (board:session). Cleared on a
  /// fresh connect / disconnect; survives board joins within one session.
  std::string selfUserId;
  std::vector<nlohmann::json> pending;
  int syncedCount = 0;
  int sentCount = 0;
  std::shared_ptr<sync::Transport> transport;
  nlohmann::json room = DefaultRoom();
};

SyncState& State() {
  static SyncState state;
  return state;
}

const char* StateName(reserved::TransportState state) {
  switch (state) {
    case reserved::TransportState::Disconnected:
      return "disconnected";
    case reserved::TransportState::Connecting:
      return "connecting";
    case reserved::TransportState::Connected:
      return "connected";
    case reserved::TransportState::Reconnecting:
      return "reconnecting";
    case reserved::TransportState::Failed:
      return "failed";
  }
  return "disconnected";
}

const char* TypeName(reserved::TransportType type) {
  switch (type) {
    case reserved::TransportType::WebSocket:
      return "websocket";
    case reserved::TransportType::TCP:
      return "tcp";
    case reserved::TransportType::SocketIO:
      return "socketio";
    case reserved::TransportType::WebRTC:
      return "webrtc";
    case reserved::TransportType::QUIC:
      return "quic";
  }
  return "socketio";
}

bool ConnectedLocked(const SyncState& state) {
  return state.transport != nullptr &&
         state.transport->getState() == reserved::TransportState::Connected;
}

int RoomParticipantCount(const nlohmann::json& room) {
  const nlohmann::json participants =
      room.value("participants", nlohmann::json::array());
  return participants.is_array() ? static_cast<int>(participants.size()) : 0;
}

/// Caller must hold state.mutex. Reads transport observables (one-way lock
/// order: sync -> transport).
nlohmann::json StatusJsonLocked(const SyncState& state) {
  nlohmann::json result;
  result["connected"] = ConnectedLocked(state);
  result["endpoint"] = state.endpoint;
  result["latencyMs"] =
      state.transport != nullptr ? state.transport->latencyMs() : 0;
  result["offline"] = state.offline;
  result["participants"] = RoomParticipantCount(state.room);
  result["pendingCount"] = static_cast<int>(state.pending.size());
  result["reconnectCount"] =
      state.transport != nullptr ? state.transport->reconnectCount() : 0;
  result["sentCount"] = state.sentCount;
  result["syncedCount"] = state.syncedCount;
  result["transport"] = state.transport != nullptr
                            ? TypeName(state.transport->getType())
                            : "socketio";
  result["transportState"] = state.transport != nullptr
                                 ? StateName(state.transport->getState())
                                 : "disconnected";
  return result;
}

/// Moves exhausted reliable deliveries back into the offline queue. Called at
/// the top of every op (poll model: the domain never reacts from a network
/// thread) and outside all transport locks.
void ReclaimFailures() {
  SyncState& state = State();
  std::shared_ptr<sync::Transport> transport;
  {
    std::lock_guard<std::mutex> lock(state.mutex);
    transport = state.transport;
  }
  if (transport == nullptr) return;
  std::vector<nlohmann::json> failed = transport->drainFailures();
  if (failed.empty()) return;
  std::lock_guard<std::mutex> lock(state.mutex);
  // Failed ops predate everything still pending; prepend to keep order.
  state.pending.insert(state.pending.begin(), failed.begin(), failed.end());
}

/// Applies one inbound remote op through the crdt domain (FFI caller thread,
/// no module locks held). Only ops the crdt domain reports as applied are
/// surfaced; a missing local document is lazily created once (join may race
/// the first broadcast — snapshot/backfill arrives in M2).
void ApplyInboundOp(const std::string& docId, const nlohmann::json& op,
                    nlohmann::json* appliedOps) {
  const nlohmann::json args = {{"docId", docId}, {"operation", op}};
  std::string response = invokeDomain("crdt", "applyRemote", args.dump());
  nlohmann::json parsed = nlohmann::json::parse(response, nullptr, false);
  if (!parsed.is_object()) return;
  if (!parsed.value("ok", false)) {
    const nlohmann::json error = parsed.value("error", nlohmann::json::object());
    if (error.value("code", std::string()) != "NotFound") return;
    invokeDomain("crdt", "create", nlohmann::json{{"docId", docId}}.dump());
    response = invokeDomain("crdt", "applyRemote", args.dump());
    parsed = nlohmann::json::parse(response, nullptr, false);
    if (!parsed.is_object() || !parsed.value("ok", false)) return;
  }
  const nlohmann::json result = parsed.value("result", nlohmann::json::object());
  if (result.value("applied", false)) appliedOps->push_back(op);
}

/// Folds one `board:participants` delta into the cached room roster:
/// `joined` entries append (deduplicated by socketId), `left` entries
/// remove by socketId. Entries without a socketId are appended verbatim
/// (no identity to deduplicate on).
void ApplyParticipantsDelta(nlohmann::json& room, const nlohmann::json& delta) {
  nlohmann::json& participants = room["participants"];
  if (!participants.is_array()) participants = nlohmann::json::array();

  const nlohmann::json joined = delta.value("joined", nlohmann::json::array());
  if (joined.is_array()) {
    for (const nlohmann::json& entry : joined) {
      if (!entry.is_object()) continue;
      const std::string socketId = entry.value("socketId", std::string());
      if (!socketId.empty()) {
        bool exists = false;
        for (const nlohmann::json& existing : participants) {
          if (existing.is_object() &&
              existing.value("socketId", std::string()) == socketId) {
            exists = true;
            break;
          }
        }
        if (exists) continue;
      }
      participants.push_back(entry);
    }
  }

  const nlohmann::json left = delta.value("left", nlohmann::json::array());
  if (left.is_array()) {
    for (const nlohmann::json& entry : left) {
      if (!entry.is_object()) continue;
      const std::string socketId = entry.value("socketId", std::string());
      if (socketId.empty()) continue;
      participants.erase(
          std::remove_if(participants.begin(), participants.end(),
                         [&socketId](const nlohmann::json& existing) {
                           return existing.is_object() &&
                                  existing.value("socketId", std::string()) ==
                                      socketId;
                         }),
          participants.end());
    }
  }
}

}  // namespace

class SyncDomain : public DomainHandler {
 public:
  std::string name() const override { return "sync"; }

  std::string handle(const std::string& op,
                     const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    ReclaimFailures();
    if (op == "connect") return Connect(args);
    if (op == "disconnect") return Disconnect(args);
    if (op == "status") return Status(args);
    if (op == "setOffline" || op == "set_offline") return SetOffline(args);
    if (op == "join") return Join(args);
    if (op == "sendOperation" || op == "send_operation") {
      return SendOperation(args);
    }
    if (op == "sendPreview" || op == "send_preview") {
      return SendPreview(args);
    }
    if (op == "sync") return Sync(args);
    if (op == "events" || op == "drainEvents") return Events(args);
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
    const std::string token = args.value("token", std::string());
    const std::string clientVersion =
        args.value("clientVersion", std::string("1.0.0"));

    SyncState& state = State();
    std::shared_ptr<sync::Transport> stale;
    std::string boardId;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      if (state.transport != nullptr) {
        const reserved::TransportState current = state.transport->getState();
        if (current == reserved::TransportState::Connecting ||
            current == reserved::TransportState::Connected ||
            current == reserved::TransportState::Reconnecting) {
          return domainError("Conflict",
                             "already connected to " + state.endpoint);
        }
        // A failed/stopped session is replaced below.
        stale = std::move(state.transport);
      }
      state.endpoint = endpoint;
      boardId = state.boardId;  // rejoin the last board after a failure
      // A fresh transport starts a fresh server session: the previous
      // board:session identity no longer applies (the new one arrives with
      // the next handshake).
      state.selfUserId.clear();
    }
    if (stale != nullptr) {
      stale->disconnect();
      stale.reset();
    }

    std::shared_ptr<sync::Transport> transport = sync::MakeTransport();
    const bool started =
        transport->connectBoard(endpoint, token, boardId, clientVersion);
    if (!started) {
      transport->disconnect();
      return domainError("NotSupported",
                         "sync transport failed to start for " + endpoint);
    }

    bool raced = false;
    nlohmann::json result;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      if (state.transport != nullptr) {
        raced = true;  // a concurrent connect won the race
      } else {
        state.transport = transport;
        result = StatusJsonLocked(state);
      }
    }
    if (raced) {
      transport->disconnect();
      return domainError("Conflict", "already connected to " + endpoint);
    }
    return domainOk(result.dump());
  }

  std::string Disconnect(const nlohmann::json& args) {
    (void)args;
    SyncState& state = State();
    std::shared_ptr<sync::Transport> transport;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      transport = std::move(state.transport);
      state.endpoint.clear();
      state.boardId.clear();
      state.pageId.clear();
      state.room = DefaultRoom();
      state.selfUserId.clear();
    }
    if (transport != nullptr) {
      // Teardown moves unacknowledged ops to the failure list; reclaim them
      // so an explicit disconnect never drops data (pending is kept).
      transport->disconnect();
      std::vector<nlohmann::json> unsent = transport->drainFailures();
      if (!unsent.empty()) {
        std::lock_guard<std::mutex> lock(state.mutex);
        state.pending.insert(state.pending.begin(),
                             std::make_move_iterator(unsent.begin()),
                             std::make_move_iterator(unsent.end()));
      }
    }
    std::lock_guard<std::mutex> lock(state.mutex);
    return domainOk(StatusJsonLocked(state).dump());
  }

  std::string Status(const nlohmann::json& args) {
    (void)args;
    SyncState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    return domainOk(StatusJsonLocked(state).dump());
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
    return domainOk(StatusJsonLocked(state).dump());
  }

  std::string Join(const nlohmann::json& args) {
    const std::string boardId = args.value("boardId", std::string());
    if (boardId.empty()) {
      return domainError("InvalidArgument", "args.boardId is required");
    }
    const std::string pageId = args.value("pageId", std::string());

    SyncState& state = State();
    std::shared_ptr<sync::Transport> transport;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      if (state.offline) {
        return domainError("Conflict", "offline mode defers join");
      }
      transport = state.transport;
      if (transport == nullptr ||
          transport->getState() != reserved::TransportState::Connected) {
        return domainError("Conflict", "sync transport is not connected");
      }
      state.boardId = boardId;
      state.pageId = pageId;
      state.room = DefaultRoom();
    }

    if (!transport->joinBoard(boardId, pageId)) {
      return domainError("Conflict", "sync transport is not connected");
    }
    nlohmann::json result;
    result["boardId"] = boardId;
    result["joined"] = true;
    if (!pageId.empty()) result["pageId"] = pageId;
    return domainOk(result.dump());
  }

  std::string SendOperation(const nlohmann::json& args) {
    nlohmann::json op;
    if (args.contains("op")) {
      op = args["op"];
    } else if (args.contains("operation")) {
      op = args["operation"];  // legacy key, kept for compatibility
    } else {
      return domainError("InvalidArgument", "args.op is required");
    }
    if (!op.is_object() || op.empty()) {
      return domainError("InvalidArgument",
                         "args.op must be a non-empty object");
    }

    SyncState& state = State();
    std::shared_ptr<sync::Transport> transport;
    bool online = false;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      transport = state.transport;
      online = !state.offline && transport != nullptr &&
               transport->getState() == reserved::TransportState::Connected;
      if (!online) {
        state.pending.push_back(op);
        nlohmann::json result;
        result["pendingCount"] = static_cast<int>(state.pending.size());
        result["queued"] = true;
        result["sent"] = false;
        result["syncedCount"] = state.syncedCount;
        return domainOk(result.dump());
      }
    }

    // The network call happens outside the lock (transport synchronizes
    // internally).
    const bool accepted = transport->sendReliable(op);
    nlohmann::json result;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      if (accepted) {
        // Optimistic acceptance tally; a later delivery failure reclaims the
        // op into `pending` without decrementing the counters (M1 semantics,
        // exact ack-based counters arrive with the M2 watermark work).
        state.sentCount += 1;
        state.syncedCount += 1;
        result["pendingCount"] = static_cast<int>(state.pending.size());
        result["sent"] = true;
        result["syncedCount"] = state.syncedCount;
      } else {
        state.pending.push_back(op);
        result["pendingCount"] = static_cast<int>(state.pending.size());
        result["queued"] = true;
        result["sent"] = false;
        result["syncedCount"] = state.syncedCount;
      }
    }
    return domainOk(result.dump());
  }

  std::string SendPreview(const nlohmann::json& args) {
    if (!args.contains("preview")) {
      return domainError("InvalidArgument", "args.preview is required");
    }
    const nlohmann::json preview = args["preview"];
    if (!preview.is_object() || preview.value("kind", std::string()).empty()) {
      return domainError("InvalidArgument", "args.preview.kind is required");
    }

    SyncState& state = State();
    std::shared_ptr<sync::Transport> transport;
    bool offline = false;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      transport = state.transport;
      offline = state.offline;
    }
    nlohmann::json result;
    if (transport == nullptr || offline) {
      result["dropped"] = true;
    } else if (transport->sendPreview(preview)) {
      if (transport->getState() == reserved::TransportState::Connected) {
        result["sent"] = true;
      } else {
        result["queued"] = true;  // hysteresis slot drains after connect
      }
    } else {
      result["dropped"] = true;
    }
    return domainOk(result.dump());
  }

  std::string Sync(const nlohmann::json& args) {
    (void)args;
    SyncState& state = State();
    std::shared_ptr<sync::Transport> transport;
    std::vector<nlohmann::json> batch;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      if (state.offline) {
        return domainError("Conflict", "offline mode defers sync");
      }
      transport = state.transport;
      if (transport == nullptr ||
          transport->getState() != reserved::TransportState::Connected) {
        return domainError("Conflict", "sync transport is not connected");
      }
      batch.swap(state.pending);
    }

    int synced = 0;
    std::vector<nlohmann::json> refused;
    for (nlohmann::json& op : batch) {
      if (transport->sendReliable(op)) {
        synced += 1;
      } else {
        refused.push_back(std::move(op));
      }
    }

    nlohmann::json result;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      if (!refused.empty()) {
        state.pending.insert(state.pending.begin(),
                             std::make_move_iterator(refused.begin()),
                             std::make_move_iterator(refused.end()));
      }
      state.syncedCount += synced;
      result["pendingCount"] = static_cast<int>(state.pending.size());
      result["synced"] = synced;
      result["syncedCount"] = state.syncedCount;
    }
    return domainOk(result.dump());
  }

  std::string Events(const nlohmann::json& args) {
    (void)args;
    SyncState& state = State();
    std::shared_ptr<sync::Transport> transport;
    std::string docId;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      transport = state.transport;
      docId = state.boardId;  // D-D: docId is the joined board id
    }

    nlohmann::json ops = nlohmann::json::array();
    nlohmann::json previews = nlohmann::json::array();
    nlohmann::json roomPatch = nlohmann::json::object();
    std::vector<nlohmann::json> participantDeltas;
    std::string sessionUserId;
    bool hasSessionUserId = false;

    if (transport != nullptr) {
      // Cross-domain calls below run on the FFI caller thread with no module
      // lock held (threading contract).
      const std::vector<sync::InboundEvent> events = transport->drainInbound();
      for (const sync::InboundEvent& event : events) {
        if (event.event == "board:ops") {
          if (docId.empty()) continue;  // not joined yet: nothing to route
          if (!event.payload.is_array()) continue;
          for (const nlohmann::json& op : event.payload) {
            if (!op.is_object()) continue;
            ApplyInboundOp(docId, op, &ops);
          }
        } else if (event.event == "presence:preview") {
          previews.push_back(event.payload);
        } else if (event.event == "board:joined" ||
                   event.event == "board:joinAck") {
          if (event.payload.value("ok", true) == false) continue;
          for (const char* key : {"participants", "mode", "locks"}) {
            if (event.payload.contains(key)) {
              roomPatch[key] = event.payload[key];
            }
          }
        } else if (event.event == "board:participants") {
          // Roster deltas (other members joining / leaving): applied in
          // arrival order after the full snapshot above.
          if (event.payload.is_object()) {
            participantDeltas.push_back(event.payload);
          }
        } else if (event.event == "board:session") {
          // Handshake identity (per-connection anonymous user id): surfaced
          // as room.selfUserId so the UI marks "me" precisely instead of
          // inferring from roster order.
          const nlohmann::json userId =
              event.payload.value("userId", nlohmann::json());
          if (userId.is_string() && !userId.get<std::string>().empty()) {
            sessionUserId = userId.get<std::string>();
            hasSessionUserId = true;
          }
        }
        // connect_error carries no M1 payload; ignored.
      }
    }

    std::lock_guard<std::mutex> lock(state.mutex);
    for (auto& item : roomPatch.items()) {
      state.room[item.key()] = item.value();
    }
    for (const nlohmann::json& delta : participantDeltas) {
      ApplyParticipantsDelta(state.room, delta);
    }
    if (hasSessionUserId) {
      state.selfUserId = sessionUserId;
    }
    nlohmann::json room = state.room;
    room["selfUserId"] = state.selfUserId;
    nlohmann::json result;
    result["ops"] = std::move(ops);
    result["previews"] = std::move(previews);
    result["room"] = std::move(room);
    result["status"] = StatusJsonLocked(state);
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
      // M1 ships Socket.IO (sioxx); the other transports stay reserved.
      item["implemented"] = std::string(type) == "socketio";
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
