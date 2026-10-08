#pragma once

// sync/transport.h — collaboration transport seam of the sync domain
// (M1/M2/M3).
// Owns: core/src/sync.
//
// reserved::Transport (providers.h) is the long-term, transport-agnostic
// contract from《互动白板预留接口设计》M10.1. The sync domain needs a few
// more capabilities than its five base methods offer (board join with a
// rejoin watermark, reliable batch send with ack bookkeeping, software-lock
// transitions, interactive-mode requests, checkpoint upload, inbound event
// drain, failure reclaim), so wb::sync::Transport extends it.
// SocketIOTransport is the production implementation (sioxx);
// tests swap in a FakeTransport through SetTransportFactory
// (catch_discover_tests runs every TEST_CASE in its own process, so a
// per-process factory install is isolated).
//
// Threading contract: every method is callable from any thread and
// implementations synchronize internally. Implementations must never call
// back into the sync domain from their worker threads — network threads only
// move protocol data and queue it; the domain drains on the FFI caller
// thread.

#include <memory>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "providers.h"

namespace wb {
namespace sync {

/// One normalized inbound event drained from the transport. `payload` is the
/// first object argument of the event; "board:ops" keeps its canonical shape
/// of one ops array. Drained by the sync domain's "events" op.
struct InboundEvent {
  std::string event;
  nlohmann::json payload;
};

/// Transport seam consumed by the sync domain.
class Transport : public reserved::Transport {
 public:
  /// Opens the transport and starts the /board namespace handshake for
  /// `boardId`. `url` accepts ws://, wss://, http://, https:// or a bare
  /// host:port (normalized by the implementation); an empty `clientVersion`
  /// or `token` is omitted from the auth payload.
  virtual bool connectBoard(const std::string& url, const std::string& token,
                            const std::string& boardId,
                            const std::string& clientVersion) = 0;

  /// Joins `boardId` (board:join + ack). `lastSeenVersion` is the re-join
  /// watermark `{actor: contiguousSeq}`: an empty object (first join) asks
  /// the server for a full replay, a populated vector only for the delta
  /// after those seqs. The ack lands on the inbound queue as a
  /// "board:joinAck" event. Returns false when not connected.
  virtual bool joinBoard(const std::string& boardId,
                         const std::string& pageId,
                         const nlohmann::json& lastSeenVersion) = 0;

  /// Enqueues one CRDT op for reliable delivery: 100 ms batching window,
  /// ack with a 3 s timeout and up to 3 resends, then the op moves to the
  /// failure list (drained by the sync domain into its offline queue).
  virtual bool sendReliable(const nlohmann::json& op) = 0;

  /// Offers a volatile preview to the depth-1 hysteresis slot (a newer value
  /// replaces the un-sent older one; flushed while connected).
  virtual bool sendPreview(const nlohmann::json& payload) = 0;

  /// Requests one software-lock transition (M2 D2-C). `payload` carries
  /// `{action: acquire|release|renew, elementId}`; the transport emits
  /// `lock:acquire` / `lock:release` / `lock:renew` with an ack callback.
  /// The ack lands on the inbound queue as a "lock:reply" event. Returns
  /// false when not connected (or the action is unknown).
  virtual bool sendLock(const nlohmann::json& payload) = 0;

  /// Requests one interactive-mode action (M3 T3.2). `payload` carries
  /// `{action, userId?, targetUserId?}`; the nine known actions emit
  /// `interactive:<action>` with `{}` (raiseHand / lowerHand / startPresent /
  /// stopPresent), `{userId}` (grantControl / revokeControl / removeUser) or
  /// `{targetUserId}` (follow / unfollow). The per-request ack lands on the
  /// inbound queue as an "interactive:reply" event. Returns false when not
  /// connected (or the action / a required field is missing).
  virtual bool sendInteractive(const nlohmann::json& payload) = 0;

  /// Uploads one checkpoint blob (M3 T3.5): emits `board:checkpoint` with
  /// `{stateVector, payload}`. The ack lands on the inbound queue as a
  /// "checkpoint:reply" event — `{ok:true}` on acceptance, `{ok:false,
  /// reason:"timeout"}` when the ack deadline elapses unanswered. Returns
  /// false when not connected.
  virtual bool sendCheckpoint(const nlohmann::json& payload) = 0;

  /// Takes every inbound event queued since the last drain (drain semantics).
  virtual std::vector<InboundEvent> drainInbound() = 0;

  /// Takes the ops whose reliable delivery was exhausted, in original order.
  virtual std::vector<nlohmann::json> drainFailures() = 0;

  /// Last observed ack round-trip in milliseconds (0 = not sampled yet).
  virtual int latencyMs() const = 0;

  /// Reconnects observed since connectBoard (0 = never reconnected).
  virtual int reconnectCount() const = 0;
};

/// M3 T3.2 interactive action → wire mapping, shared by the Socket.IO
/// transport, the fakes and their tests (single source of truth). Returns
/// the event name "interactive:<action>" for the nine known actions
/// (raiseHand / lowerHand / startPresent / stopPresent / grantControl /
/// revokeControl / removeUser / follow / unfollow), "" otherwise.
const char* InteractiveWireEvent(const std::string& action);

/// The extra payload key one interactive action carries: "userId" for
/// grantControl / revokeControl / removeUser, "targetUserId" for follow /
/// unfollow, "" when the action carries no extra field. nullptr for unknown
/// actions.
const char* InteractiveWireField(const std::string& action);

/// Factory used by the sync domain to create transports; tests install a
/// fake one. Returns a fresh instance per call.
using TransportFactory = std::shared_ptr<Transport> (*)();

/// Process-wide factory override (pass nullptr to restore the default).
void SetTransportFactory(TransportFactory factory);

/// Creates a transport: the installed factory when present, otherwise the
/// production SocketIOTransport (UnavailableTransport on WASM builds).
std::shared_ptr<Transport> MakeTransport();

}  // namespace sync
}  // namespace wb
