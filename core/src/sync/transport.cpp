// sync/transport.cpp — transport factory, the WASM degradation (M1) and the
// shared M3 interactive wire mapping (T3.2).
// Owns: core/src/sync.
//
// Desktop: MakeTransport() returns the sioxx-based SocketIOTransport (its
// implementation lives in socketio_transport.cpp, desktop-only).
// WASM: sioxx is not fetched (third_party/CMakeLists.txt guards it), so the
// transport degrades to UnavailableTransport: connectBoard() fails cleanly
// and the sync domain maps that to a "NotSupported" response; the M3
// channels degrade to refused requests (requested=false), like lock.

#include "transport.h"

#include <memory>
#include <string>

#if !defined(__EMSCRIPTEN__)
#include "socketio_transport.h"
#endif

namespace wb {
namespace sync {
namespace {

TransportFactory g_factory = nullptr;

#if defined(__EMSCRIPTEN__)
/// WASM stub: the realtime transport is unavailable in this build.
class UnavailableTransport : public Transport {
 public:
  bool connect(const std::string&, const std::string&) override {
    return false;
  }
  bool connectBoard(const std::string&, const std::string&,
                    const std::string&, const std::string&) override {
    return false;
  }
  void disconnect() override {}
  reserved::TransportState getState() const override {
    return reserved::TransportState::Disconnected;
  }
  bool send(const std::string&) override { return false; }
  reserved::TransportType getType() const override {
    return reserved::TransportType::SocketIO;
  }
  bool joinBoard(const std::string&, const std::string&,
                 const nlohmann::json&) override {
    return false;
  }
  bool sendReliable(const nlohmann::json&) override { return false; }
  bool sendPreview(const nlohmann::json&) override { return false; }
  bool sendLock(const nlohmann::json&) override { return false; }
  // M3 channels are unavailable in this build: the domain degrades every
  // request to requested=false / failed (same as lock).
  bool sendInteractive(const nlohmann::json&) override { return false; }
  bool sendCheckpoint(const nlohmann::json&) override { return false; }
  std::vector<InboundEvent> drainInbound() override { return {}; }
  std::vector<nlohmann::json> drainFailures() override { return {}; }
  int latencyMs() const override { return 0; }
  int reconnectCount() const override { return 0; }
};
#endif  // defined(__EMSCRIPTEN__)

/// M3 interactive wire mapping table (T3.2): one row per known action
/// (action → wire event name → extra payload key).
struct InteractiveWire {
  const char* action;
  const char* event;
  const char* field;
};

constexpr InteractiveWire kInteractiveWire[] = {
    {"raiseHand", "interactive:raiseHand", ""},
    {"lowerHand", "interactive:lowerHand", ""},
    {"startPresent", "interactive:startPresent", ""},
    {"stopPresent", "interactive:stopPresent", ""},
    {"grantControl", "interactive:grantControl", "userId"},
    {"revokeControl", "interactive:revokeControl", "userId"},
    {"removeUser", "interactive:removeUser", "userId"},
    {"follow", "interactive:follow", "targetUserId"},
    {"unfollow", "interactive:unfollow", "targetUserId"},
};

}  // namespace

const char* InteractiveWireEvent(const std::string& action) {
  for (const InteractiveWire& entry : kInteractiveWire) {
    if (action == entry.action) return entry.event;
  }
  return "";
}

const char* InteractiveWireField(const std::string& action) {
  for (const InteractiveWire& entry : kInteractiveWire) {
    if (action == entry.action) return entry.field;
  }
  return nullptr;
}

void SetTransportFactory(TransportFactory factory) { g_factory = factory; }

std::shared_ptr<Transport> MakeTransport() {
  if (g_factory != nullptr) return g_factory();
#if defined(__EMSCRIPTEN__)
  return std::make_shared<UnavailableTransport>();
#else
  return std::make_shared<SocketIOTransport>();
#endif
}

}  // namespace sync
}  // namespace wb
