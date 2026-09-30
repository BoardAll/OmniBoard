#pragma once

// sync/providers.h — reserved collaboration provider interfaces (1.7).
// Owns: core/src/sync.
//
// 《互动白板预留接口设计》M10.1: AVProvider / InteractiveProvider /
// Transport / RecordingProvider / PlaybackProvider are reserved this
// phase ("不实现，只预留"). The interfaces below mirror the design doc
// signatures so later waves (M10.2-M10.5: mediasoup, TCP/Socket.IO
// integration, recording) can provide real implementations without
// touching call sites. `ReservedProviders()` feeds the sync domain's
// "capabilities" op so the UI can report what is not implemented yet.
//
// M1 exception: the Transport seam is live — SocketIOTransport
// (core/src/sync/socketio_transport.{h,cpp}) implements it over sioxx, so
// its descriptor below reports implemented=true while the rest stay false.

#include <string>
#include <vector>

namespace wb {
namespace reserved {

enum class TransportType {
  WebSocket,
  TCP,
  SocketIO,
  WebRTC,
  QUIC,
};

enum class TransportState {
  Disconnected,
  Connecting,
  Connected,
  Reconnecting,
  Failed,
};

class AVProvider {
 public:
  virtual ~AVProvider() = default;
  virtual void startCall(const std::string& roomId) = 0;
  virtual void joinCall(const std::string& roomId) = 0;
  virtual void leaveCall() = 0;
  virtual void shareScreen(bool enable) = 0;
  virtual void startRecording() = 0;
  virtual void stopRecording() = 0;
};

class InteractiveProvider {
 public:
  virtual ~InteractiveProvider() = default;
  virtual void startSession(const std::string& sessionId) = 0;
  virtual void endSession() = 0;
  virtual void syncBoard(const std::string& boardId) = 0;
  virtual void sendEvent(const std::string& eventJson) = 0;
};

class Transport {
 public:
  virtual ~Transport() = default;
  virtual bool connect(const std::string& url, const std::string& token) = 0;
  virtual void disconnect() = 0;
  virtual TransportState getState() const = 0;
  virtual bool send(const std::string& message) = 0;
  virtual TransportType getType() const = 0;
};

class RecordingProvider {
 public:
  virtual ~RecordingProvider() = default;
  virtual bool start() = 0;
  virtual void stop() = 0;
  virtual bool isRecording() const = 0;
  virtual std::vector<std::string> listRecordings() const = 0;
};

class PlaybackProvider {
 public:
  virtual ~PlaybackProvider() = default;
  virtual bool load(const std::string& recordingId) = 0;
  virtual void unload() = 0;
  virtual bool play() = 0;
  virtual bool pause() = 0;
  virtual bool seek(long long timestamp) = 0;
  virtual bool setSpeed(float speed) = 0;
  virtual long long getCurrentTime() const = 0;
  virtual long long getDuration() const = 0;
};

struct ProviderDescriptor {
  std::string name;
  std::vector<std::string> methods;
  bool implemented;
};

/// Machine-readable descriptor list for the "capabilities" op.
inline std::vector<ProviderDescriptor> ReservedProviders() {
  return {
      {"AVProvider",
       {"startCall", "joinCall", "leaveCall", "shareScreen",
        "startRecording", "stopRecording"},
       false},
      {"InteractiveProvider",
       {"startSession", "endSession", "syncBoard", "sendEvent"},
       false},
      {"Transport", {"connect", "disconnect", "getState", "send", "getType"},
       true},  // M1: Socket.IO (sioxx) transport is live
      {"RecordingProvider",
       {"start", "stop", "isRecording", "listRecordings"},
       false},
      {"PlaybackProvider",
       {"load", "unload", "play", "pause", "seek", "setSpeed"},
       false},
  };
}

}  // namespace reserved
}  // namespace wb
