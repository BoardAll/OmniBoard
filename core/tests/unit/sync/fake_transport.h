#pragma once

// tests/unit/sync/fake_transport.h — deterministic transport double for the
// sync domain (M1 T1.1).
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
  std::vector<nlohmann::json> sentOps;
  std::vector<nlohmann::json> sentPreviews;

  // Queues the test drives / inspects.
  std::vector<InboundEvent> inbound;     // drained by the sync domain
  std::vector<nlohmann::json> failures;  // reclaimed into `pending`
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

  bool joinBoard(const std::string& boardId,
                 const std::string& pageId) override {
    FakeTransportState& state = FakeState();
    state.joinCalls += 1;
    state.lastJoinedBoard = boardId;
    state.lastJoinedPage = pageId;
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
