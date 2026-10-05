#pragma once

// tests/unit/sync/fake_transport.h — deterministic transport double for the
// sync domain (M1 T1.1; M2 T2b adds lock + re-join watermark observations;
// M3 T3.2/T3.5 adds the interactive channel + checkpoint upload).
//
// The fake completes synchronously: connectBoard lands "Connected" right
// away, so the sync-domain assertions keep their pre-M1 semantics (the old
// placeholder transport also "connected" instantly). All queues are plain
// shared state; catch_discover_tests runs each TEST_CASE in its own process,
// and InstallFakeTransport() resets the state for runs that execute several
// cases in one process.
//
// Usage:
//   InstallFakeTransport();                       // first line of the case
//   FakePushInbound("board:ops", opsArray);       // feed the inbound queue
//   FakeQueueFailure(op);                         // simulate exhausted acks
//   FakeQueueLockReply(ackPayload);               // preload a lock:reply ack
//   FakeQueueInteractiveReply(ackPayload);        // preload an interactive:reply
//   FakeQueueCheckpointReply(ackPayload);         // preload a checkpoint:reply
//   FakeState().state = ...::Reconnecting;        // simulate a drop/recover
//                                                 // (Events drives re-join)

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "../../../src/sync/transport.h"

namespace wb {
namespace sync {
namespace test {

/// State shared between a test case and the installed FakeTransport.
struct FakeTransportState {
  // Behaviour switches.
  bool connectSucceeds = true;   // connectBoard outcome
  bool joinAccepted = true;      // joinBoard outcome
  bool reliableAccepted = true;  // sendReliable outcome
  bool previewAccepted = true;   // sendPreview outcome
  bool lockAccepted = true;      // sendLock outcome
  bool interactiveAccepted = true;  // sendInteractive outcome (M3 T3.2)
  bool checkpointAccepted = true;   // sendCheckpoint outcome (M3 T3.5)
  reserved::TransportState state = reserved::TransportState::Disconnected;
  int latency = 0;
  int reconnectCount = 0;

  // Observations.
  int connectCalls = 0;
  int disconnectCalls = 0;
  int joinCalls = 0;
  std::string lastEndpoint;
  std::string lastToken;
  std::string lastClientVersion;
  std::string lastJoinedBoard;
  std::string lastJoinedPage;
  /// Watermark of the most recent (and every) joinBoard call (D2-D).
  nlohmann::json lastJoinedWatermark = nlohmann::json::object();
  std::vector<nlohmann::json> joinWatermarks;
  std::vector<nlohmann::json> sentOps;
  std::vector<nlohmann::json> sentPreviews;
  std::vector<nlohmann::json> sentLocks;  // accepted sendLock payloads, in order
  /// Accepted sendInteractive payloads, in order (M3 T3.2).
  std::vector<nlohmann::json> sentInteractives;
  /// Accepted sendCheckpoint payloads, in order (M3 T3.5).
  std::vector<nlohmann::json> sentCheckpoints;

  // Queues the test drives / inspects.
  std::vector<InboundEvent> inbound;        // drained by the sync domain
  std::vector<nlohmann::json> failures;     // reclaimed into `pending`
  std::vector<nlohmann::json> lockReplies;  // preloaded acks, FIFO (sendLock)
  /// Preloaded interactive acks (FIFO): the next accepted sendInteractive()
  /// pushes one as an inbound "interactive:reply" with the request action
  /// stamped on (parity with the real transport's ack callback).
  std::vector<nlohmann::json> interactiveReplies;
  /// Preloaded checkpoint acks (FIFO): the next accepted sendCheckpoint()
  /// pushes one as an inbound "checkpoint:reply" (the real transport does
  /// this from its io thread, or injects a timeout failure from its pump).
  std::vector<nlohmann::json> checkpointReplies;
};

inline FakeTransportState& FakeState() {
  static FakeTransportState state;
  return state;
}

/// Pushes one inbound event (returned by the next "events" call).
inline void FakePushInbound(std::string event, nlohmann::json payload) {
  InboundEvent item;
  item.event = std::move(event);
  item.payload = std::move(payload);
  FakeState().inbound.push_back(std::move(item));
}

/// Queues one op into the failure list (exhausted acks / dropped link).
inline void FakeQueueFailure(nlohmann::json op) {
  FakeState().failures.push_back(std::move(op));
}

/// Preloads one lock ack: the next accepted sendLock() pushes it as an
/// inbound "lock:reply" event (the real transport does the same from its io
/// worker thread; the fake keeps the instant semantics).
inline void FakeQueueLockReply(nlohmann::json payload) {
  FakeState().lockReplies.push_back(std::move(payload));
}

/// Preloads one interactive ack (M3 T3.2): the next accepted
/// sendInteractive() pushes it as an inbound "interactive:reply" event.
inline void FakeQueueInteractiveReply(nlohmann::json payload) {
  FakeState().interactiveReplies.push_back(std::move(payload));
}

/// Preloads one checkpoint ack (M3 T3.5): the next accepted
/// sendCheckpoint() pushes it as an inbound "checkpoint:reply" event.
inline void FakeQueueCheckpointReply(nlohmann::json payload) {
  FakeState().checkpointReplies.push_back(std::move(payload));
}

class FakeTransport : public Transport {
 public:
  bool connect(const std::string& url, const std::string& token) override {
    return connectBoard(url, token, std::string(), std::string());
  }

  bool connectBoard(const std::string& url, const std::string& token,
                    const std::string& boardId,
                    const std::string& clientVersion) override {
    FakeTransportState& state = FakeState();
    state.connectCalls += 1;
    state.lastEndpoint = url;
    state.lastToken = token;
    state.lastClientVersion = clientVersion;
    if (!state.connectSucceeds) {
      state.state = reserved::TransportState::Failed;
      return false;
    }
    state.state = reserved::TransportState::Connected;
    return true;
  }

  void disconnect() override {
    FakeTransportState& state = FakeState();
    state.disconnectCalls += 1;
    state.state = reserved::TransportState::Disconnected;
  }

  reserved::TransportState getState() const override {
    return FakeState().state;
  }

  bool send(const std::string&) override { return false; }

  reserved::TransportType getType() const override {
    return reserved::TransportType::SocketIO;
  }

  bool joinBoard(const std::string& boardId, const std::string& pageId,
                 const nlohmann::json& lastSeenVersion) override {
    FakeTransportState& state = FakeState();
    state.joinCalls += 1;
    state.lastJoinedBoard = boardId;
    state.lastJoinedPage = pageId;
    state.lastJoinedWatermark = lastSeenVersion;
    state.joinWatermarks.push_back(lastSeenVersion);
    if (!state.joinAccepted) return false;
    return state.state == reserved::TransportState::Connected;
  }

  bool sendReliable(const nlohmann::json& op) override {
    FakeTransportState& state = FakeState();
    if (!state.reliableAccepted) return false;
    state.sentOps.push_back(op);
    return true;
  }

  bool sendPreview(const nlohmann::json& payload) override {
    FakeTransportState& state = FakeState();
    if (!state.previewAccepted) return false;
    state.sentPreviews.push_back(payload);
    return true;
  }

  bool sendLock(const nlohmann::json& payload) override {
    FakeTransportState& state = FakeState();
    // Parity with the real transport: refuses while not connected.
    if (state.state != reserved::TransportState::Connected) return false;
    if (!state.lockAccepted) return false;
    state.sentLocks.push_back(payload);
    if (!state.lockReplies.empty()) {
      nlohmann::json reply = state.lockReplies.front();
      state.lockReplies.erase(state.lockReplies.begin());
      FakePushInbound("lock:reply", std::move(reply));
    }
    return true;
  }

  bool sendInteractive(const nlohmann::json& payload) override {
    FakeTransportState& state = FakeState();
    // Parity with the real transport (M3 T3.2): refuses while not connected,
    // for unknown actions, and when the action's extra field is missing; the
    // action -> wire mapping comes from the shared source of truth.
    if (state.state != reserved::TransportState::Connected) return false;
    if (!state.interactiveAccepted) return false;
    if (!payload.is_object()) return false;
    const std::string action = payload.value("action", std::string());
    const char* event = InteractiveWireEvent(action);
    if (event == nullptr || *event == '\0') return false;
    const char* field = InteractiveWireField(action);
    if (field != nullptr && *field != '\0' &&
        payload.value(field, std::string()).empty()) {
      return false;
    }
    state.sentInteractives.push_back(payload);
    if (!state.interactiveReplies.empty()) {
      nlohmann::json reply = state.interactiveReplies.front();
      state.interactiveReplies.erase(state.interactiveReplies.begin());
      if (reply.is_object() && !reply.contains("action")) {
        reply["action"] = action;  // ack stamping parity with the real path
      }
      FakePushInbound("interactive:reply", std::move(reply));
    }
    return true;
  }

  bool sendCheckpoint(const nlohmann::json& payload) override {
    FakeTransportState& state = FakeState();
    // Parity with the real transport (M3 T3.5): refuses while not connected.
    if (state.state != reserved::TransportState::Connected) return false;
    if (!state.checkpointAccepted) return false;
    state.sentCheckpoints.push_back(payload);
    if (!state.checkpointReplies.empty()) {
      nlohmann::json reply = state.checkpointReplies.front();
      state.checkpointReplies.erase(state.checkpointReplies.begin());
      FakePushInbound("checkpoint:reply", std::move(reply));
    }
    return true;
  }

  std::vector<InboundEvent> drainInbound() override {
    std::vector<InboundEvent> out = std::move(FakeState().inbound);
    FakeState().inbound.clear();
    return out;
  }

  std::vector<nlohmann::json> drainFailures() override {
    std::vector<nlohmann::json> out = std::move(FakeState().failures);
    FakeState().failures.clear();
    return out;
  }

  int latencyMs() const override { return FakeState().latency; }

  int reconnectCount() const override { return FakeState().reconnectCount; }
};

/// Resets the shared state and installs the fake factory. The lambda spells
/// out the abstract return type so it converts to the plain TransportFactory
/// function pointer (implicit return-type narrowing would break that
/// conversion).
inline void InstallFakeTransport() {
  FakeState() = FakeTransportState{};
  SetTransportFactory([]() -> std::shared_ptr<Transport> {
    return std::make_shared<FakeTransport>();
  });
}

}  // namespace test
}  // namespace sync
}  // namespace wb
