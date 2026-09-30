#pragma once

// sync/outbound_queue.h — reliable outbound batching for the sync domain
// (M1). Header-only and clock-injected (all times in milliseconds) so unit
// tests drive the exact 100 ms / 3 s / x3 timeline without sleeping.
//
// Timeline for one batch (design §5.4 "100ms 攒批 + ack 超时 3s + 重发最多
// 3 次"):
//   t0        enqueue            (batching window opens)
//   t0+100ms  send #1
//   +3s       send #2   (resend 1)
//   +3s       send #3   (resend 2)
//   +3s       send #4   (resend 3)
//   +3s       delivery failed -> ops move to the failure list (offline queue)
//
// One batch is in flight at a time, so op order is preserved; ops enqueued
// while a batch is in flight wait for it to finish. Batch ids rise
// monotonically so a late ack can never confirm a newer batch.

#include <cstdint>
#include <deque>
#include <map>
#include <optional>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

namespace wb {
namespace sync {

struct OutboundSettings {
  std::int64_t batchWindowMs = 100;
  std::int64_t ackTimeoutMs = 3000;
  int maxResends = 3;
};

/// One due send action returned by OutboundQueue::Tick.
struct OutboundAction {
  std::int64_t batchId = 0;
  int attempt = 0;  // 1-based; attempt 1 is the first send
  std::vector<nlohmann::json> ops;
};

/// Serial batching + ack retry state machine. Not thread-safe by itself; the
/// transport guards it with its own mutex.
class OutboundQueue {
 public:
  OutboundQueue() = default;
  explicit OutboundQueue(OutboundSettings settings) : settings_(settings) {}

  /// Queues one op. Starts the batching window when the queue was idle.
  void Enqueue(nlohmann::json op, std::int64_t nowMs) {
    if (pending_.empty()) windowStartMs_ = nowMs;
    pending_.push_back(std::move(op));
  }

  /// Drives the state machine at `nowMs`; at most one send is due per call.
  std::optional<OutboundAction> Tick(std::int64_t nowMs) {
    if (inFlight()) {
      if (nowMs - lastSendMs_ < settings_.ackTimeoutMs) return std::nullopt;
      if (resendsUsed_ < settings_.maxResends) {
        resendsUsed_ += 1;
        lastSendMs_ = nowMs;
        return MakeAction();
      }
      // Ack never arrived and the resend budget is exhausted.
      FailAll();
      return std::nullopt;
    }
    if (!pending_.empty() &&
        nowMs - windowStartMs_ >= settings_.batchWindowMs) {
      batchId_ = ++nextBatchId_;
      currentOps_.assign(std::make_move_iterator(pending_.begin()),
                         std::make_move_iterator(pending_.end()));
      pending_.clear();
      resendsUsed_ = 0;
      lastSendMs_ = nowMs;
      return MakeAction();
    }
    return std::nullopt;
  }

  /// Marks the in-flight batch as acknowledged. Returns the ack round-trip
  /// when `batchId` matches; stale/unknown ids are ignored (a late ack must
  /// not confirm a newer batch).
  std::optional<std::int64_t> OnAck(std::int64_t batchId,
                                    std::int64_t nowMs) {
    if (!inFlight() || batchId != batchId_) return std::nullopt;
    const std::int64_t rtt = nowMs - lastSendMs_;
    currentOps_.clear();
    batchId_ = 0;
    resendsUsed_ = 0;
    return rtt;
  }

  /// Returns the in-flight batch to the front of the pending queue (e.g. the
  /// send path was not connected); the batching window restarts.
  void RequeueInFlight(std::int64_t nowMs) {
    if (!inFlight()) return;
    pending_.insert(pending_.begin(),
                    std::make_move_iterator(currentOps_.begin()),
                    std::make_move_iterator(currentOps_.end()));
    currentOps_.clear();
    batchId_ = 0;
    resendsUsed_ = 0;
    windowStartMs_ = nowMs;
  }

  /// Moves the in-flight batch plus everything pending to the failure list,
  /// preserving original order (in-flight ops are older than queued ones).
  void FailAll() {
    for (nlohmann::json& op : currentOps_) failures_.push_back(std::move(op));
    currentOps_.clear();
    for (nlohmann::json& op : pending_) failures_.push_back(std::move(op));
    pending_.clear();
    batchId_ = 0;
    resendsUsed_ = 0;
  }

  /// Takes the failed ops (drain semantics).
  std::vector<nlohmann::json> DrainFailures() {
    std::vector<nlohmann::json> out = std::move(failures_);
    failures_.clear();
    return out;
  }

  bool inFlight() const { return batchId_ != 0; }
  std::size_t pendingSize() const { return pending_.size(); }

 private:
  OutboundAction MakeAction() {
    OutboundAction action;
    action.batchId = batchId_;
    action.attempt = resendsUsed_ + 1;
    action.ops = currentOps_;
    return action;
  }

  OutboundSettings settings_;
  std::deque<nlohmann::json> pending_;
  std::vector<nlohmann::json> currentOps_;
  std::vector<nlohmann::json> failures_;
  std::int64_t nextBatchId_ = 0;
  std::int64_t batchId_ = 0;
  std::int64_t windowStartMs_ = 0;
  std::int64_t lastSendMs_ = 0;
  int resendsUsed_ = 0;
};

/// Depth-1 sticky slots for volatile previews (design §5.4): a new value
/// replaces the un-sent older one, so only the freshest frame per kind
/// (transform / ink) survives. Not thread-safe by itself.
class HysteresisSlots {
 public:
  void Offer(const std::string& key, nlohmann::json payload) {
    slots_[key] = std::move(payload);
  }

  /// Takes every slot (drain semantics); the slots end up empty.
  std::vector<std::pair<std::string, nlohmann::json>> TakeAll() {
    std::vector<std::pair<std::string, nlohmann::json>> out;
    out.reserve(slots_.size());
    for (auto& entry : slots_) {
      out.emplace_back(entry.first, std::move(entry.second));
    }
    slots_.clear();
    return out;
  }

  bool empty() const { return slots_.empty(); }

 private:
  std::map<std::string, nlohmann::json> slots_;
};

}  // namespace sync
}  // namespace wb
