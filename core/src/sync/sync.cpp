// sync/sync.cpp — domain "sync" (task package 1.7 / M1 T1.1 + T1.2 /
// M2 T2b / M3 T3.2 + T3.5).
// Owns: core/src/sync.
//
// Ops (《C++ 核心引擎接口设计》§12.2 + FFI forwarding): connect, disconnect,
// status, setOffline, join, sendOperation, sendPreview, lock, interactive,
// sync (flush), events (drain), queue, capabilities.
//
// M1 wired the real Socket.IO transport (socketio_transport.{h,cpp}) behind
// this domain; M2 T2b adds `lock` (D2-C software-lock pass-through: the per
// request ack surfaces as room.lockAcks, broadcasts fold into room.locks)
// and passive-reconnect recovery (D2-D: per-actor delivery watermarks, an
// automatic re-join carrying `lastSeenVersion`, and the pull-before-push
// hold `awaitingReplay`); M3 adds the interactive channel (T3.2: the
// `interactive` forward, interactive:reply / modeChanged / roleChanged /
// hostChanged / follow / unfollow / room:removed folds) and the checkpoint
// engine side (T3.5: board:checkpointRequest → crdt.encodeState →
// board:checkpoint upload, plus the guarded join-snapshot restore). The
// domain stays transport-agnostic through sync::Transport + MakeTransport();
// the FFI caller thread owns every domain call, while transport worker
// threads only queue data (sioxx callbacks and the transport pump never call
// invokeDomain). Cross-domain calls (crdt.applyRemote / encodeState /
// decodeState inside "events") happen outside every module lock.

#include <algorithm>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
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
  // Software-lock table (M2 D2-C): elementId → {userId, expiresAt}.
  room["locks"] = nlohmann::json::object();
  room["mode"] = "";
  // M3 interactive snapshot state (T3.2): own role, temporary write grant,
  // presenter / host pins — refreshed by joins and the interactive:* folds.
  room["selfRole"] = "";
  room["presenterId"] = "";
  room["hostUserId"] = "";
  room["grantedWrite"] = false;
  // M3 checkpoint markers (T3.5): idle → requested → uploaded | failed,
  // plus the snapshot-restore flag.
  room["checkpointStatus"] = "idle";
  room["recovered"] = false;
  room["participants"] = nlohmann::json::array();
  return room;
}

/// Process-wide SyncManager state (one whiteboard session per process).
struct SyncState {
  /// Per-actor delivery watermark (D2-D): `contiguousSeq` is the largest seq
  /// with no gaps below it; a seq that arrives early waits in `pendingSeqs`
  /// until the missing predecessor closes the gap.
  struct Watermark {
    int contiguousSeq = 0;
    std::set<int> pendingSeqs;
  };

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
  /// Delivery watermarks, serialized as `{actor: contiguousSeq}` into the
  /// re-join `lastSeenVersion` (D2-D). Cleared on disconnect (new session)
  /// and on a board switch (seqs are per-board documents).
  std::map<std::string, Watermark> watermarks;
  /// Last transport state observed by `events`; the Reconnecting→Connected
  /// edge on it triggers the automatic re-join. Reset to nullopt on a fresh
  /// connect / disconnect (the first handshake is never a re-join).
  std::optional<reserved::TransportState> lastTransportState;
  /// Pull-before-push hold (D2-D): true between the automatic re-join and
  /// the join round trip completing; new ops queue instead of going out and
  /// the pending backlog flushes only after the replayed delta arrived.
  bool awaitingReplay = false;
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

/// Caller must hold state.mutex. Advances one actor's delivery watermark:
/// the contiguous seq moves only through a gapless run, successors buffered
/// while the gap was open get absorbed on the way, and replays
/// (seq <= contiguousSeq) are ignored — the update is idempotent (D2-D).
void AdvanceWatermarkLocked(SyncState& state, const std::string& actor,
                            int seq) {
  if (actor.empty() || seq <= 0) return;
  SyncState::Watermark& mark = state.watermarks[actor];
  if (seq <= mark.contiguousSeq) return;  // replay: already counted
  if (seq != mark.contiguousSeq + 1) {
    mark.pendingSeqs.insert(seq);
    return;
  }
  mark.contiguousSeq = seq;
  auto next = mark.pendingSeqs.begin();
  while (next != mark.pendingSeqs.end() && *next == mark.contiguousSeq + 1) {
    mark.contiguousSeq = *next;
    next = mark.pendingSeqs.erase(next);
  }
}

/// Caller must hold state.mutex. Locally accepted ops (the applyLocal
/// response op the caller forwards) advance their actor's watermark right
/// away: the local copy already carries the op, even while it waits in
/// `pending` for delivery.
void AdvanceWatermarkFromOpLocked(SyncState& state, const nlohmann::json& op) {
  const std::string actor = op.value("actor", std::string());
  if (actor.empty()) return;
  const nlohmann::json seq = op.value("seq", nlohmann::json());
  if (!seq.is_number_integer()) return;
  AdvanceWatermarkLocked(state, actor, seq.get<int>());
}

/// Caller must hold state.mutex. Serializes the watermarks as the wire
/// `lastSeenVersion` vector `{actor: contiguousSeq}`; an empty object keeps
/// the full-replay semantics of a first join.
nlohmann::json WatermarkJsonLocked(const SyncState& state) {
  nlohmann::json vector = nlohmann::json::object();
  for (const auto& entry : state.watermarks) {
    vector[entry.first] = entry.second.contiguousSeq;
  }
  return vector;
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

/// Drains `pending` through `transport->sendReliable` (transport calls stay
/// outside the module lock). Refused ops return to the front of `pending` in
/// their original order; returns how many were accepted. Shared by the
/// explicit `sync` op and the re-join replay flush (D2-D 先拉后推).
int FlushPending(SyncState& state,
                 const std::shared_ptr<sync::Transport>& transport) {
  std::vector<nlohmann::json> batch;
  {
    std::lock_guard<std::mutex> lock(state.mutex);
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
  std::lock_guard<std::mutex> lock(state.mutex);
  if (!refused.empty()) {
    state.pending.insert(state.pending.begin(),
                         std::make_move_iterator(refused.begin()),
                         std::make_move_iterator(refused.end()));
  }
  state.syncedCount += synced;
  return synced;
}

/// Applies one inbound remote op through the crdt domain (FFI caller thread,
/// no module locks held). Returns true when the op is reflected in the local
/// copy — applied, duplicate, or logged-but-LWW-lost — and reports the
/// canonical seq (owned by the merge response) so the caller can advance the
/// delivery watermark. A missing local document is lazily created once (join
/// may race the first broadcast — snapshot/backfill arrives in a later wave).
bool ApplyInboundOp(const std::string& docId, const nlohmann::json& op,
                    nlohmann::json* appliedOps, int* seqOut) {
  const nlohmann::json args = {{"docId", docId}, {"operation", op}};
  std::string response = invokeDomain("crdt", "applyRemote", args.dump());
  nlohmann::json parsed = nlohmann::json::parse(response, nullptr, false);
  if (!parsed.is_object()) return false;
  if (!parsed.value("ok", false)) {
    const nlohmann::json error =
        parsed.value("error", nlohmann::json::object());
    if (error.value("code", std::string()) != "NotFound") return false;
    invokeDomain("crdt", "create", nlohmann::json{{"docId", docId}}.dump());
    response = invokeDomain("crdt", "applyRemote", args.dump());
    parsed = nlohmann::json::parse(response, nullptr, false);
    if (!parsed.is_object() || !parsed.value("ok", false)) return false;
  }
  const nlohmann::json result =
      parsed.value("result", nlohmann::json::object());
  if (result.value("applied", false)) appliedOps->push_back(op);
  *seqOut = result.value("seq", 0);
  return true;
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

  // `updated` entries (M3 T3.2): merge fields (role / grantedWrite /
  // handRaised / ...) into the matching roster entry — matched by socketId,
  // falling back to userId. Unknown members are ignored; a join snapshot
  // always precedes its own updates on the wire.
  const nlohmann::json updated =
      delta.value("updated", nlohmann::json::array());
  if (updated.is_array()) {
    for (const nlohmann::json& entry : updated) {
      if (!entry.is_object()) continue;
      const std::string socketId = entry.value("socketId", std::string());
      const std::string userId = entry.value("userId", std::string());
      if (socketId.empty() && userId.empty()) continue;
      for (nlohmann::json& existing : participants) {
        if (!existing.is_object()) continue;
        const bool matches =
            !socketId.empty()
                ? existing.value("socketId", std::string()) == socketId
                : existing.value("userId", std::string()) == userId;
        if (!matches) continue;
        for (auto& item : entry.items()) existing[item.key()] = item.value();
        break;
      }
    }
  }
}

/// Replaces the room lock table from a board:joined / joinAck snapshot
/// (M2 D2-C). M2 servers send the elementId → {userId, expiresAt} object
/// map; a legacy pre-M2 array (or any other shape) normalizes to {}.
void ApplyLockSnapshot(nlohmann::json& room, const nlohmann::json& snapshot) {
  room["locks"] = snapshot.is_object() ? snapshot : nlohmann::json::object();
}

/// Folds one `lock:changed` broadcast into the room lock table: `acquired`
/// adds `{userId, expiresAt}`, `released` / `expired` removes the entry.
/// Locks are session state — they never enter the CRDT.
void ApplyLockChange(nlohmann::json& room, const nlohmann::json& change) {
  if (!change.is_object()) return;
  const std::string elementId = change.value("elementId", std::string());
  if (elementId.empty()) return;
  nlohmann::json& locks = room["locks"];
  if (!locks.is_object()) locks = nlohmann::json::object();
  const std::string action = change.value("action", std::string());
  if (action == "acquired") {
    nlohmann::json entry;
    entry["userId"] = change.value("userId", std::string());
    entry["expiresAt"] = change.value("expiresAt", nlohmann::json());
    locks[elementId] = std::move(entry);
  } else if (action == "released" || action == "expired") {
    locks.erase(elementId);
  }
}

/// Restores the local crdt document from a join snapshot (M3 T3.5 checkpoint
/// path). `snapshot` is `{stateVector, payload}` as delivered on board:joined
/// to a new member.
///
/// Guard (contract): decodeState is a whole-state replacement — it may ONLY
/// run when the local crdt document does not exist yet. On an existing
/// document it would clobber local edits the server has not replayed/merged
/// back, so the restore is skipped entirely; the incremental board:ops that
/// follow the join cover that case instead. Runs on the FFI caller thread
/// with no module lock held; cross-domain calls stay outside every lock.
void TryRestoreSnapshot(const std::string& docId,
                        const nlohmann::json& snapshot) {
  if (docId.empty() || !snapshot.is_object()) return;
  if (!snapshot.contains("payload")) return;

  // Probe: only a NotFound answer opens the restore path; any other outcome
  // (existing document, unexpected error) keeps the local copy untouched.
  const std::string probeResponse = invokeDomain(
      "crdt", "encodeState", nlohmann::json{{"docId", docId}}.dump());
  const nlohmann::json probe =
      nlohmann::json::parse(probeResponse, nullptr, false);
  if (!probe.is_object() || probe.value("ok", false)) return;
  const nlohmann::json probeError =
      probe.value("error", nlohmann::json::object());
  if (probeError.value("code", std::string()) != "NotFound") return;

  // Create first, then decode: create doubles as an existence re-check — if
  // a concurrent writer won the race, the restore backs off (no overwrite).
  const std::string createResponse = invokeDomain(
      "crdt", "create", nlohmann::json{{"docId", docId}}.dump());
  const nlohmann::json created =
      nlohmann::json::parse(createResponse, nullptr, false);
  if (!created.is_object() || !created.value("ok", false)) return;

  nlohmann::json decodeArgs;
  decodeArgs["docId"] = docId;
  decodeArgs["state"] = snapshot["payload"];
  const std::string decodeResponse =
      invokeDomain("crdt", "decodeState", decodeArgs.dump());
  const nlohmann::json decoded =
      nlohmann::json::parse(decodeResponse, nullptr, false);
  if (!decoded.is_object() || !decoded.value("ok", false)) return;

  SyncState& state = State();
  std::lock_guard<std::mutex> lock(state.mutex);
  // The snapshot's vector is the replay baseline: the server replays only the
  // ops after it and the watermark absorbs that increment gaplessly (the
  // new-member path has no local ops, so replacing the vector is safe).
  const nlohmann::json vector =
      snapshot.value("stateVector", nlohmann::json::object());
  if (vector.is_object()) {
    state.watermarks.clear();
    for (auto& item : vector.items()) {
      if (!item.value().is_number()) continue;
      state.watermarks[item.key()].contiguousSeq = item.value().get<int>();
    }
  }
  state.room["recovered"] = true;
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
    if (op == "lock") return Lock(args);
    if (op == "interactive") return Interactive(args);
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
        // Fresh observation window: the re-join detector starts from an
        // unknown snapshot, so the first handshake never counts as re-join.
        state.lastTransportState = std::nullopt;
        state.awaitingReplay = false;
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
      // New session: the delivery watermark restarts (D2-D) and any re-join
      // hold dies with the connection.
      state.watermarks.clear();
      state.awaitingReplay = false;
      state.lastTransportState = std::nullopt;
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
    nlohmann::json watermark = nlohmann::json::object();
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
      if (state.boardId != boardId) {
        // actor seqs are per-board documents: a board switch starts a fresh
        // watermark; a re-join of the same board keeps the delta vector.
        state.watermarks.clear();
      }
      state.boardId = boardId;
      state.pageId = pageId;
      state.room = DefaultRoom();
      watermark = WatermarkJsonLocked(state);
    }

    if (!transport->joinBoard(boardId, pageId, watermark)) {
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
      // While a re-join replay is in flight the op queues instead of going
      // out: the server must not see new writes before it replayed the
      // delta ("pull before push", D2-D); the replay flush drains it.
      online = !state.offline && !state.awaitingReplay &&
               transport != nullptr &&
               transport->getState() == reserved::TransportState::Connected;
      // The op carries its applyLocal-produced (actor, seq): it advances our
      // own delivery watermark right away — the local copy already has it,
      // even while the op waits in `pending` for delivery (D2-D).
      AdvanceWatermarkFromOpLocked(state, op);
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
        // op into `pending` without decrementing the counters (delivery is
        // idempotent through (actor, seq) dedup on both ends).
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

  /// Software-lock request (M2 D2-C): forwards `{action, elementId}` to the
  /// transport, which emits lock:acquire / lock:release / lock:renew with an
  /// ack callback. The outcome is asynchronous: it lands in the inbound
  /// queue as "lock:reply" and surfaces via `events` (room.lockAcks).
  std::string Lock(const nlohmann::json& args) {
    const std::string action = args.value("action", std::string());
    const std::string elementId = args.value("elementId", std::string());
    if (action.empty() || elementId.empty()) {
      return domainError("InvalidArgument",
                         "args.action and args.elementId are required");
    }
    if (action != "acquire" && action != "release" && action != "renew") {
      return domainError("InvalidArgument",
                         "args.action must be acquire|release|renew");
    }

    SyncState& state = State();
    std::shared_ptr<sync::Transport> transport;
    bool online = false;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      transport = state.transport;
      online = !state.offline && transport != nullptr &&
               transport->getState() == reserved::TransportState::Connected;
    }
    nlohmann::json result;
    if (!online) {
      // Degrades quietly (sendPreview's dropped semantics): the request
      // surface stays a stable {requested} envelope, never Conflict.
      result["requested"] = false;
    } else {
      nlohmann::json payload;
      payload["action"] = action;
      payload["elementId"] = elementId;
      // Transport call outside the lock; the ack arrives asynchronously.
      result["requested"] = transport->sendLock(payload);
    }
    return domainOk(result.dump());
  }

  /// Interactive-mode request (M3 T3.2): forwards `{action, userId?,
  /// targetUserId?}` to the transport, which maps the action onto its
  /// `interactive:<action>` wire event with an ack callback. The outcome is
  /// asynchronous: it lands in the inbound queue as "interactive:reply" and
  /// surfaces via `events` (interactiveAcks). Same stable `{requested}`
  /// envelope as `lock` — a deferred request is never an error.
  std::string Interactive(const nlohmann::json& args) {
    const std::string action = args.value("action", std::string());
    if (action.empty()) {
      return domainError("InvalidArgument", "args.action is required");
    }
    const char* event = sync::InteractiveWireEvent(action);
    if (*event == '\0') {
      return domainError(
          "InvalidArgument",
          "args.action must be raiseHand|lowerHand|startPresent|stopPresent|"
          "grantControl|revokeControl|removeUser|follow|unfollow");
    }
    // grantControl / revokeControl / removeUser carry {userId};
    // follow / unfollow carry {targetUserId} (shared wire mapping).
    const char* field = sync::InteractiveWireField(action);
    std::string extra;
    if (field != nullptr && *field != '\0') {
      extra = args.value(field, std::string());
      if (extra.empty()) {
        return domainError("InvalidArgument",
                           std::string("args.") + field + " is required for " +
                               action);
      }
    }

    SyncState& state = State();
    std::shared_ptr<sync::Transport> transport;
    bool online = false;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      transport = state.transport;
      online = !state.offline && transport != nullptr &&
               transport->getState() == reserved::TransportState::Connected;
    }
    nlohmann::json result;
    if (!online) {
      // Degrades quietly (sendPreview's dropped / lock's requested:false
      // semantics): the request surface stays stable, never Conflict.
      result["requested"] = false;
    } else {
      nlohmann::json payload;
      payload["action"] = action;
      if (field != nullptr && *field != '\0') payload[field] = extra;
      // Transport call outside the lock; the ack arrives asynchronously.
      result["requested"] = transport->sendInteractive(payload);
    }
    return domainOk(result.dump());
  }

  std::string Sync(const nlohmann::json& args) {
    (void)args;
    SyncState& state = State();
    std::shared_ptr<sync::Transport> transport;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      if (state.offline) {
        return domainError("Conflict", "offline mode defers sync");
      }
      if (state.awaitingReplay) {
        // Pull-before-push (D2-D): the backlog waits for the re-join delta.
        return domainError("Conflict", "rejoin replay defers sync");
      }
      transport = state.transport;
      if (transport == nullptr ||
          transport->getState() != reserved::TransportState::Connected) {
        return domainError("Conflict", "sync transport is not connected");
      }
    }
    const int synced = FlushPending(state, transport);
    nlohmann::json result;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
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
    bool rejoinNeeded = false;
    std::string rejoinBoard;
    std::string rejoinPage;
    nlohmann::json rejoinWatermark = nlohmann::json::object();
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      transport = state.transport;
      docId = state.boardId;  // D-D: docId is the joined board id
      if (transport != nullptr) {
        const std::optional<reserved::TransportState> previous =
            state.lastTransportState;
        const reserved::TransportState current = transport->getState();
        state.lastTransportState = current;
        // Passive-recovery re-join (D2-D): only the Reconnecting→Connected
        // edge on the same transport re-joins. A fresh connect resets the
        // snapshot (the first handshake can never match), Failed never
        // reaches Connected, and a manual disconnect tears the transport
        // down entirely — so none of those paths re-join.
        if (previous.has_value() &&
            *previous == reserved::TransportState::Reconnecting &&
            current == reserved::TransportState::Connected &&
            !state.boardId.empty()) {
          rejoinNeeded = true;
          state.awaitingReplay = true;
          rejoinBoard = state.boardId;
          rejoinPage = state.pageId;
          rejoinWatermark = WatermarkJsonLocked(state);
        }
      }
    }

    if (rejoinNeeded) {
      // Outside every lock (the transport synchronizes internally). The
      // re-join carries the watermark so the server replays only the delta
      // the client missed while disconnected.
      if (!transport->joinBoard(rejoinBoard, rejoinPage, rejoinWatermark)) {
        // The link is already gone again: no replay will arrive this round;
        // the next Reconnecting→Connected edge re-triggers the re-join.
        std::lock_guard<std::mutex> lock(state.mutex);
        state.awaitingReplay = false;
      }
    }

    nlohmann::json ops = nlohmann::json::array();
    nlohmann::json previews = nlohmann::json::array();
    nlohmann::json roomPatch = nlohmann::json::object();
    std::vector<nlohmann::json> participantDeltas;
    std::vector<nlohmann::json> lockChanges;
    nlohmann::json lockAcks = nlohmann::json::array();
    nlohmann::json lockSnapshot;
    bool hasLockSnapshot = false;
    std::vector<std::pair<std::string, int>> watermarkUpdates;
    std::string sessionUserId;
    bool hasSessionUserId = false;
    bool replayDone = false;
    // M3 T3.2 interactive drain batches: acks settle once per call (drain
    // semantics like lockAcks); the follow / mode / role / host / removal
    // inputs fold into the room cache below.
    nlohmann::json interactiveAcks = nlohmann::json::array();
    nlohmann::json incomingFollows = nlohmann::json::array();
    nlohmann::json removed = nlohmann::json::object();
    std::vector<nlohmann::json> modeChanges;
    std::vector<nlohmann::json> roleChanges;
    std::vector<nlohmann::json> hostChanges;
    std::vector<std::pair<std::string, nlohmann::json>> followEvents;
    // M3 T3.5 checkpoint inputs (replies settle the status; a request drives
    // the encode + upload after the fold below).
    std::vector<nlohmann::json> checkpointReplies;
    bool checkpointRequested = false;

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
            int seq = 0;
            if (ApplyInboundOp(docId, op, &ops, &seq)) {
              watermarkUpdates.emplace_back(op.value("actor", std::string()),
                                            seq);
            }
          }
        } else if (event.event == "presence:preview") {
          previews.push_back(event.payload);
        } else if (event.event == "board:joined" ||
                   event.event == "board:joinAck") {
          if (event.payload.value("ok", true) == false) continue;
          for (const char* key :
               {"participants", "mode", "presenterId", "hostUserId"}) {
            if (event.payload.contains(key)) {
              roomPatch[key] = event.payload[key];
            }
          }
          // The own role ships with the join snapshot (M3 T3.2).
          if (event.payload.contains("role") &&
              event.payload["role"].is_string()) {
            roomPatch["selfRole"] = event.payload["role"];
          }
          // The lock table snapshot is an elementId → {userId, expiresAt}
          // object map (M2 D2-C); legacy array shapes normalize on fold.
          if (event.payload.contains("locks")) {
            lockSnapshot = event.payload["locks"];
            hasLockSnapshot = true;
          }
          // M3 T3.5 snapshot restore (new-member path). Handled right here so
          // the increments that follow this join in the same drain replay on
          // top of the restored state; the guard inside TryRestoreSnapshot
          // keeps decodeState away from any existing local document.
          if (event.payload.contains("snapshot")) {
            TryRestoreSnapshot(docId, event.payload["snapshot"]);
          }
          // The join round trip completed: a pending re-join replay is done.
          replayDone = true;
        } else if (event.event == "board:participants") {
          // Roster deltas (other members joining / leaving): applied in
          // arrival order after the full snapshot above.
          if (event.payload.is_object()) {
            participantDeltas.push_back(event.payload);
          }
        } else if (event.event == "lock:changed") {
          // Lock lifecycle broadcast (M2 D2-C): session state only, folded
          // after the join snapshot in arrival order.
          if (event.payload.is_object()) {
            lockChanges.push_back(event.payload);
          }
        } else if (event.event == "lock:reply") {
          // Per-request lock ack (acquire / release / renew): surfaced once
          // via room.lockAcks of this very drain (drain semantics).
          lockAcks.push_back(event.payload);
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
        } else if (event.event == "interactive:reply") {
          // Per-request interactive ack: settled once per drain as
          // {action, ok, reason?} (the transport stamps the request action
          // onto the reply).
          nlohmann::json ack;
          ack["action"] = event.payload.value("action", std::string());
          ack["ok"] = event.payload.value("ok", false);
          if (event.payload.contains("reason")) {
            ack["reason"] = event.payload["reason"];
          }
          interactiveAcks.push_back(std::move(ack));
        } else if (event.event == "interactive:modeChanged") {
          if (event.payload.is_object()) {
            modeChanges.push_back(event.payload);
          }
        } else if (event.event == "interactive:roleChanged") {
          if (event.payload.is_object()) {
            roleChanges.push_back(event.payload);
          }
        } else if (event.event == "interactive:hostChanged") {
          if (event.payload.is_object()) {
            hostChanges.push_back(event.payload);
          }
        } else if (event.event == "interactive:follow" ||
                   event.event == "interactive:unfollow") {
          if (event.payload.is_object()) {
            followEvents.emplace_back(event.event, event.payload);
          }
        } else if (event.event == "room:removed") {
          // The server removed this client from the room (unicast, sent right
          // before the forced disconnect): surfaced once per drain.
          removed["reason"] = event.payload.value("reason", std::string());
        } else if (event.event == "checkpoint:reply") {
          if (event.payload.is_object()) {
            checkpointReplies.push_back(event.payload);
          }
        } else if (event.event == "board:checkpointRequest") {
          // M3 T3.5: the server asks this client for a checkpoint; the
          // encode + upload runs after the fold below (lock-free).
          checkpointRequested = true;
        }
        // connect_error carries no M1 payload; ignored.
      }
    }

    bool replayWasPending = false;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      for (auto& item : roomPatch.items()) {
        state.room[item.key()] = item.value();
      }
      for (const nlohmann::json& delta : participantDeltas) {
        ApplyParticipantsDelta(state.room, delta);
      }
      if (hasLockSnapshot) ApplyLockSnapshot(state.room, lockSnapshot);
      for (const nlohmann::json& change : lockChanges) {
        ApplyLockChange(state.room, change);
      }
      for (const auto& update : watermarkUpdates) {
        AdvanceWatermarkLocked(state, update.first, update.second);
      }
      if (hasSessionUserId) {
        state.selfUserId = sessionUserId;
      }
      // M3 T3.2 interactive folds. Ordered after the roster pass so the
      // own-entry mirror below sees the merged participant updates.
      for (const nlohmann::json& change : roleChanges) {
        const std::string userId = change.value("userId", std::string());
        if (!userId.empty() && !state.selfUserId.empty() &&
            userId != state.selfUserId) {
          continue;  // roleChanged is a unicast addressed at one user
        }
        const std::string role = change.value("role", std::string());
        if (!role.empty()) state.room["selfRole"] = role;
      }
      for (const nlohmann::json& change : modeChanges) {
        const std::string mode = change.value("mode", std::string());
        if (mode.empty()) continue;
        state.room["mode"] = mode;
        if (mode == "present") {
          const std::string by = change.value("by", std::string());
          if (!by.empty()) state.room["presenterId"] = by;
        } else {
          state.room["presenterId"] = "";  // present left: no presenter
        }
      }
      for (const nlohmann::json& change : hostChanges) {
        const std::string host = change.value("newHostId", std::string());
        if (!host.empty()) state.room["hostUserId"] = host;
      }
      for (const auto& follow : followEvents) {
        const nlohmann::json& payload = follow.second;
        const std::string target =
            payload.value("targetUserId", std::string());
        if (!target.empty() && !state.selfUserId.empty() &&
            target != state.selfUserId) {
          continue;  // only the follow target counts its incoming followers
        }
        nlohmann::json item;
        item["followerUserId"] =
            payload.value("followerUserId",
                          payload.value("userId", std::string()));
        item["action"] =
            follow.first == "interactive:follow" ? "follow" : "unfollow";
        incomingFollows.push_back(std::move(item));
      }
      // The own temporary write grant (surfaced by participant updates)
      // mirrors at room level for the UI gate.
      if (!state.selfUserId.empty()) {
        const nlohmann::json& roster = state.room["participants"];
        if (roster.is_array()) {
          for (const nlohmann::json& entry : roster) {
            if (!entry.is_object() ||
                entry.value("userId", std::string()) != state.selfUserId) {
              continue;
            }
            if (entry.contains("grantedWrite")) {
              state.room["grantedWrite"] = entry["grantedWrite"];
            }
            break;
          }
        }
      }
      // M3 T3.5 checkpoint ack: settles a pending upload; a stale reply
      // (nothing in flight) is ignored.
      for (const nlohmann::json& reply : checkpointReplies) {
        if (state.room.value("checkpointStatus", std::string()) !=
            "requested") {
          continue;
        }
        state.room["checkpointStatus"] =
            reply.value("ok", false) ? "uploaded" : "failed";
      }
      if (replayDone) {
        // Re-join replay finished: release the pull-before-push hold (D2-D).
        replayWasPending = state.awaitingReplay;
        state.awaitingReplay = false;
      }
    }

    // --- M3 T3.5 checkpoint: answer a server checkpoint request -----------
    // Everything below runs outside every module lock: crdt.encodeState is a
    // cross-domain call and the transport emit is a network call (threading
    // contract). The increments applied above are already in the encoded
    // state and in the watermarks, so the upload reflects this drain's view.
    if (checkpointRequested && transport != nullptr) {
      bool sent = false;
      if (!docId.empty()) {
        nlohmann::json stateVector;
        {
          std::lock_guard<std::mutex> lock(state.mutex);
          stateVector = WatermarkJsonLocked(state);
        }
        const std::string encoded = invokeDomain(
            "crdt", "encodeState", nlohmann::json{{"docId", docId}}.dump());
        const nlohmann::json parsed =
            nlohmann::json::parse(encoded, nullptr, false);
        if (parsed.is_object() && parsed.value("ok", false)) {
          const nlohmann::json encodeResult =
              parsed.value("result", nlohmann::json::object());
          nlohmann::json upload;
          upload["stateVector"] = std::move(stateVector);
          upload["payload"] = encodeResult.value("state", std::string());
          sent = transport->sendCheckpoint(upload);
        }
      }
      std::lock_guard<std::mutex> lock(state.mutex);
      // 'requested' while the ack is in flight ('uploaded' / 'failed' when
      // the checkpoint:reply drains); a refused / unencodable upload settles
      // at 'failed' right away.
      state.room["checkpointStatus"] = sent ? "requested" : "failed";
    }

    // The re-join backlog flush runs in the same drain call that completed
    // the replay: everything the server replayed is applied above, so the
    // queued ops go out strictly after the delta (transport calls stay
    // outside the lock). Only a cleared re-join hold triggers it — a plain
    // first join keeps the explicit `sync` flush (M1 semantics).
    if (replayWasPending && transport != nullptr) {
      bool canFlush = false;
      {
        std::lock_guard<std::mutex> lock(state.mutex);
        canFlush = !state.offline &&
                   transport->getState() ==
                       reserved::TransportState::Connected;
      }
      if (canFlush) FlushPending(state, transport);
    }

    nlohmann::json result;
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      nlohmann::json room = state.room;
      room["selfUserId"] = state.selfUserId;
      room["lockAcks"] = std::move(lockAcks);
      result["ops"] = std::move(ops);
      result["previews"] = std::move(previews);
      result["room"] = std::move(room);
      result["status"] = StatusJsonLocked(state);
      result["interactiveAcks"] = std::move(interactiveAcks);
      result["incomingFollows"] = std::move(incomingFollows);
      result["removed"] = std::move(removed);
    }
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
