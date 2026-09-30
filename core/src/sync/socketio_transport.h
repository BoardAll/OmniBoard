#pragma once

// sync/socketio_transport.h — Socket.IO (sioxx) transport (M1 T1.1).
// Owns: core/src/sync.
//
// Declaration only: sioxx/Boost headers stay in the .cpp so callers never
// take a dependency on them. Desktop-only — WASM builds do not fetch sioxx
// and degrade through UnavailableTransport (transport.cpp).
//
// Threading: one io worker thread (sioxx) plus one pump thread (25 ms tick).
// Both only move protocol data and queue it; the sync domain drains on the
// FFI caller thread. Lifecycle state is published through lock-free atomics.

#include <memory>

#include "transport.h"

namespace wb {
namespace sync {

class SocketIOTransport : public Transport {
 public:
  SocketIOTransport();
  ~SocketIOTransport() override;

  SocketIOTransport(const SocketIOTransport&) = delete;
  SocketIOTransport& operator=(const SocketIOTransport&) = delete;

  // reserved::Transport -------------------------------------------------------
  bool connect(const std::string& url, const std::string& token) override;
  void disconnect() override;
  reserved::TransportState getState() const override;
  bool send(const std::string& message) override;
  reserved::TransportType getType() const override;

  // wb::sync::Transport -------------------------------------------------------
  bool connectBoard(const std::string& url, const std::string& token,
                    const std::string& boardId,
                    const std::string& clientVersion) override;
  bool joinBoard(const std::string& boardId,
                 const std::string& pageId) override;
  bool sendReliable(const nlohmann::json& op) override;
  bool sendPreview(const nlohmann::json& payload) override;
  std::vector<InboundEvent> drainInbound() override;
  std::vector<nlohmann::json> drainFailures() override;
  int latencyMs() const override;
  int reconnectCount() const override;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace sync
}  // namespace wb
