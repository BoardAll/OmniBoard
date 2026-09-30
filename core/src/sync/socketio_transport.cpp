// sync/socketio_transport.cpp — Socket.IO (sioxx v0.3.0) transport (M1).
// Owns: core/src/sync.
//
// POC-proven sioxx behaviours this implementation adapts to (T0.1b record):
//   - client->socket("/board", auth) must be registered before connect();
//   - ack callbacks arrive on the io worker thread with argument-list JSON;
//   - the library has no ack timeout / auto-resend -> the 100 ms batch +
//     3 s x3 resend timeline lives here (OutboundQueue);
//   - the library's internal send_buffer_ keeps ordering across a drop and
//     flushes on reconnect -> we only emit while connected (no double
//     scheduling) and rely on the server's (actor, seq) dedup for the rare
//     disconnect race;
//   - same-name on() overwrites (never call sync_close from a callback);
//   - a namespace rejection arrives as a regular "connect_error" event;
//   - the WS -> polling downgrade is one-way (accepted, recorded);
//   - reconnect_attempts defaults to 0 -> explicitly configured below.
//
// WASM builds do not fetch sioxx: this translation unit is empty and
// transport.cpp degrades to UnavailableTransport.

#if !defined(__EMSCRIPTEN__)

#include "socketio_transport.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <sioxx/sioxx.hpp>

#include "outbound_queue.h"

namespace wb {
namespace sync {
namespace {

std::int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// sioxx delivers event/ack arguments as a JSON array; tolerate the bare
// object shape as well (single-argument convenience).
const sioxx::message* FirstArgument(const sioxx::message& data) {
  if (data.is_array() && !data.empty()) return &data[0];
  return &data;
}

// Normalizes one object-shaped event into an InboundEvent.
InboundEvent ObjectEvent(const char* name, const sioxx::message& data) {
  InboundEvent event;
  event.event = name;
  const sioxx::message* first = FirstArgument(data);
  event.payload = first->is_object() ? *first : nlohmann::json::object();
  return event;
}

// Canonical board:ops payload is one ops array ([op...]); tolerate a bare op
// object and a multi-argument spread for robustness.
InboundEvent OpsEvent(const sioxx::message& data) {
  InboundEvent event;
  event.event = "board:ops";
  event.payload = nlohmann::json::array();
  if (data.is_array()) {
    if (!data.empty() && data[0].is_array()) {
      event.payload = data[0];
    } else {
      for (const nlohmann::json& item : data) {
        if (item.is_object()) event.payload.push_back(item);
      }
    }
  } else if (data.is_object()) {
    event.payload.push_back(data);
  }
  return event;
}

// An ack reply counts as delivered unless it explicitly says ok:false (a
// server-side {"ok":false,...} means "not accepted": keep retrying).
bool AckAccepted(const sioxx::message& data) {
  const sioxx::message* first = FirstArgument(data);
  if (first->is_object()) return first->value("ok", true);
  return true;
}

constexpr auto kPumpInterval = std::chrono::milliseconds(25);
constexpr int kReconnectAttempts = 5;  // design §5.12: 5 failures -> standalone

}  // namespace

struct SocketIOTransport::Impl {
  using State = reserved::TransportState;

  // ---- lifecycle -----------------------------------------------------------
  std::atomic<bool> stopping{false};
  std::atomic<bool> intentional{false};  // set by Disconnect(): silence events
  std::atomic<int> state{static_cast<int>(State::Disconnected)};
  std::atomic<int> latency{0};
  std::atomic<int> reconnects{0};
  std::atomic<bool> everConnected{false};

  // sioxx objects: created by ConnectBoard, released by Disconnect. The
  // instance is never reconnected in place (the domain replaces transports).
  std::unique_ptr<sioxx::client> client;
  std::shared_ptr<sioxx::socket> board;
  std::thread pump;

  // ---- queues --------------------------------------------------------------
  // Guarded by `mutex`; producers are the io worker (callbacks), the pump
  // thread and the FFI caller thread, consumers are the pump and drain calls.
  std::mutex mutex;
  OutboundQueue outbound;
  HysteresisSlots previews;

  struct PendingAck {
    std::int64_t batchId = 0;
    bool accepted = true;
    std::int64_t atMs = 0;
  };
  std::vector<PendingAck> acks;
  std::vector<InboundEvent> inbound;

  State GetState() const { return static_cast<State>(state.load()); }

  bool ConnectBoard(const std::string& url, const std::string& token,
                    const std::string& boardId,
                    const std::string& clientVersion) {
    if (client != nullptr) return false;  // one session per instance

    intentional.store(false);
    stopping.store(false);
    state.store(static_cast<int>(State::Connecting));
    everConnected.store(false);
    reconnects.store(0);
    latency.store(0);

    sioxx::client_options options;
    options.reconnect_attempts = kReconnectAttempts;
    options.reconnect_delay = std::chrono::milliseconds(1000);
    options.reconnect_delay_max = std::chrono::milliseconds(30000);
    options.reconnect_randomization_factor = 0.2;

    client = std::make_unique<sioxx::client>(std::move(options));
    client->set_fail_listener([this] {
      // Fires once when the reconnect budget is exhausted (POC record).
      state.store(static_cast<int>(State::Failed));
    });
    client->set_error_listener([](const std::string&) {
      // Transport-level errors fire repeatedly during back-off; the state
      // machine reacts to close / fail / connect_error instead.
    });

    sioxx::message auth = sioxx::message::object();
    auth["boardId"] = boardId;
    if (!clientVersion.empty()) auth["clientVersion"] = clientVersion;
    if (!token.empty()) auth["token"] = token;

    // Register before connect(): client_impl auto-CONNECTs registered
    // sockets on every Engine.IO open, including reconnects (POC record).
    board = client->socket("/board", std::move(auth));
    board->on_connect([this] {
      if (everConnected.exchange(true)) reconnects.fetch_add(1);
      state.store(static_cast<int>(State::Connected));
    });
    board->on_disconnect([this](const std::string&) {
      if (intentional.load()) return;
      OnBoardDisconnect();
    });
    board->on("board:ops",
              [this](const std::string&, sioxx::message data) {
                PushInbound(OpsEvent(data));
              });
    board->on("board:joined",
              [this](const std::string&, sioxx::message data) {
                PushInbound(ObjectEvent("board:joined", data));
              });
    // Incremental roster updates (other members joining / leaving); the
    // domain folds these into the cached room roster.
    board->on("board:participants",
              [this](const std::string&, sioxx::message data) {
                PushInbound(ObjectEvent("board:participants", data));
              });
    board->on("board:session",
              [this](const std::string&, sioxx::message data) {
                PushInbound(ObjectEvent("board:session", data));
              });
    board->on("presence:preview",
              [this](const std::string&, sioxx::message data) {
                PushInbound(ObjectEvent("presence:preview", data));
              });
    board->on("connect_error",
              [this](const std::string&, sioxx::message data) {
                // Namespace rejection (bad token / incompatible version). Only
                // the first handshake flips the state; reconnect-phase
                // rejections keep Reconnecting until the back-off exhausts.
                if (GetState() == State::Connecting) {
                  state.store(static_cast<int>(State::Failed));
                }
                PushInbound(ObjectEvent("connect_error", data));
              });

    // Bare host:port endpoints default to http:// (sioxx accepts http/ws;
    // see the transport.h contract: normalization happens here).
    std::string target = url;
    if (target.find("://") == std::string::npos) {
      target = "http://" + target;
    }

    try {
      client->connect(target);
    } catch (...) {
      // e.g. an invalid endpoint: report a failed start; the domain cleans
      // up through disconnect().
      state.store(static_cast<int>(State::Failed));
      return false;
    }
    StartPump();
    return true;
  }

  void Disconnect() {
    intentional.store(true);
    stopping.store(true);
    if (pump.joinable()) pump.join();
    // Unacknowledged work moves to the failure list before teardown: the
    // domain reclaims it through drainFailures() on an explicit disconnect,
    // so a session teardown never silently drops operations.
    {
      std::lock_guard<std::mutex> lock(mutex);
      outbound.FailAll();
    }
    if (client != nullptr) {
      try {
        client->sync_close();
      } catch (...) {
        // Teardown errors must not escape; the transport is dead regardless.
      }
      client.reset();
    }
    {
      std::lock_guard<std::mutex> lock(mutex);
      board.reset();
    }
    state.store(static_cast<int>(State::Disconnected));
  }

  // Called on the sioxx worker thread: queue-only, never calls the domain.
  void OnBoardDisconnect() {
    std::lock_guard<std::mutex> lock(mutex);
    outbound.FailAll();
    state.store(static_cast<int>(State::Reconnecting));
  }

  // Called on the sioxx worker thread: queue-only.
  void PushInbound(InboundEvent event) {
    std::lock_guard<std::mutex> lock(mutex);
    inbound.push_back(std::move(event));
  }

  bool JoinBoard(const std::string& boardId, const std::string& pageId) {
    if (GetState() != State::Connected) return false;
    std::shared_ptr<sioxx::socket> socket;
    {
      std::lock_guard<std::mutex> lock(mutex);
      socket = board;
    }
    if (socket == nullptr) return false;
    nlohmann::json payload = nlohmann::json::object();
    payload["boardId"] = boardId;
    if (!pageId.empty()) payload["pageId"] = pageId;
    // M1 keeps no watermark yet: an empty vector makes the server replay the
    // full op log to this socket (late-join catch-up). CRDT (actor, seq)
    // dedup filters anything already applied, so replays stay idempotent.
    payload["lastSeenVersion"] = nlohmann::json::object();
    socket->emit("board:join", payload, [this](sioxx::message data) {
      PushInbound(ObjectEvent("board:joinAck", data));
    });
    return true;
  }

  bool SendReliable(const nlohmann::json& op) {
    if (GetState() != State::Connected) return false;
    std::lock_guard<std::mutex> lock(mutex);
    outbound.Enqueue(op, NowMs());
    return true;
  }

  bool SendPreview(const nlohmann::json& payload) {
    const State current = GetState();
    if (current == State::Disconnected || current == State::Failed) {
      return false;
    }
    std::lock_guard<std::mutex> lock(mutex);
    previews.Offer(payload.value("kind", std::string()), payload);
    return true;
  }

  std::vector<InboundEvent> DrainInbound() {
    std::lock_guard<std::mutex> lock(mutex);
    std::vector<InboundEvent> out = std::move(inbound);
    inbound.clear();
    return out;
  }

  std::vector<nlohmann::json> DrainFailures() {
    std::lock_guard<std::mutex> lock(mutex);
    return outbound.DrainFailures();
  }

  // ---- pump ------------------------------------------------------------------

  void StartPump() { pump = std::thread([this] { PumpLoop(); }); }

  void PumpLoop() {
    while (!stopping.load()) {
      Tick();
      std::this_thread::sleep_for(kPumpInterval);
    }
  }

  void Tick() {
    const std::int64_t now = NowMs();
    std::lock_guard<std::mutex> lock(mutex);

    // 1) Acks captured on the io worker thread.
    std::vector<PendingAck> ackBatch;
    ackBatch.swap(acks);
    for (const PendingAck& ack : ackBatch) {
      if (!ack.accepted) continue;  // explicit reject: retry clock keeps running
      const std::optional<std::int64_t> rtt =
          outbound.OnAck(ack.batchId, ack.atMs);
      if (rtt.has_value()) {
        // The contract reserves 0 for "not sampled yet"; a sub-millisecond
        // ack (NowMs has 1 ms resolution) is floored to 1 ms.
        latency.store(static_cast<int>(*rtt > 0 ? *rtt : 1));
      }
    }

    // 2) Reliable outbound: batching window / resend timeline.
    if (const std::optional<OutboundAction> action = outbound.Tick(now);
        action.has_value()) {
      EmitBatch(*action);
    }

    // 3) Volatile previews: flush the depth-1 slots while connected.
    if (GetState() == State::Connected && board != nullptr &&
        board->connected()) {
      for (auto& entry : previews.TakeAll()) {
        board->emit("presence:preview", entry.second);
      }
    }
  }

  void EmitBatch(const OutboundAction& action) {
    if (board == nullptr || !board->connected()) {
      outbound.RequeueInFlight(NowMs());
      return;
    }
    // Socket.IO argument list: the ops array itself is the single argument,
    // hence the extra wrapping array (emit spreads top-level arrays).
    nlohmann::json ops = nlohmann::json::array();
    for (const nlohmann::json& op : action.ops) ops.push_back(op);
    const std::int64_t batchId = action.batchId;
    board->emit("board:ops", nlohmann::json::array({ops}),
                [this, batchId](sioxx::message data) {
                  PendingAck ack;
                  ack.batchId = batchId;
                  ack.accepted = AckAccepted(data);
                  ack.atMs = NowMs();
                  std::lock_guard<std::mutex> lock(mutex);
                  acks.push_back(ack);
                });
  }
};

SocketIOTransport::SocketIOTransport() : impl_(std::make_unique<Impl>()) {}

SocketIOTransport::~SocketIOTransport() {
  if (impl_ != nullptr) impl_->Disconnect();
}

bool SocketIOTransport::connect(const std::string& url,
                                const std::string& token) {
  // Base-interface entry point (reserved::Transport). The board flow always
  // goes through connectBoard() which carries the auth boardId.
  return impl_->ConnectBoard(url, token, std::string(), std::string());
}

void SocketIOTransport::disconnect() { impl_->Disconnect(); }

reserved::TransportState SocketIOTransport::getState() const {
  return impl_->GetState();
}

bool SocketIOTransport::send(const std::string& message) {
  // Reserved for future raw-message use; M1 board traffic goes through
  // sendReliable / sendPreview only.
  (void)message;
  return false;
}

reserved::TransportType SocketIOTransport::getType() const {
  return reserved::TransportType::SocketIO;
}

bool SocketIOTransport::connectBoard(const std::string& url,
                                     const std::string& token,
                                     const std::string& boardId,
                                     const std::string& clientVersion) {
  return impl_->ConnectBoard(url, token, boardId, clientVersion);
}

bool SocketIOTransport::joinBoard(const std::string& boardId,
                                  const std::string& pageId) {
  return impl_->JoinBoard(boardId, pageId);
}

bool SocketIOTransport::sendReliable(const nlohmann::json& op) {
  return impl_->SendReliable(op);
}

bool SocketIOTransport::sendPreview(const nlohmann::json& payload) {
  return impl_->SendPreview(payload);
}

std::vector<InboundEvent> SocketIOTransport::drainInbound() {
  return impl_->DrainInbound();
}

std::vector<nlohmann::json> SocketIOTransport::drainFailures() {
  return impl_->DrainFailures();
}

int SocketIOTransport::latencyMs() const { return impl_->latency.load(); }

int SocketIOTransport::reconnectCount() const {
  return impl_->reconnects.load();
}

}  // namespace sync
}  // namespace wb

#endif  // !defined(__EMSCRIPTEN__)
