// tests/unit/sync/outbound_queue_test.cpp — OutboundQueue / HysteresisSlots
// (M1 T1.1): the 100 ms batching window, the 3 s x3 ack resend timeline,
// failure transfer and the depth-1 preview slots, all driven by injected
// clocks so the tests never sleep.

#include <cstdint>

#include <catch2/catch_test_macros.hpp>

#include <nlohmann/json.hpp>

#include "../../../src/sync/outbound_queue.h"

namespace {

nlohmann::json Op(int n) { return nlohmann::json::object({{"n", n}}); }

}  // namespace

TEST_CASE("outbound queue batches within the 100ms window", "[sync]") {
  wb::sync::OutboundQueue queue;
  queue.Enqueue(Op(1), 0);
  queue.Enqueue(Op(2), 30);
  CHECK_FALSE(queue.Tick(99).has_value());
  const auto action = queue.Tick(100);
  REQUIRE(action.has_value());
  REQUIRE(action->attempt == 1);
  REQUIRE(action->ops.size() == 2u);
  REQUIRE(action->ops[0]["n"] == 1);
  REQUIRE(action->ops[1]["n"] == 2);
  CHECK(queue.inFlight());
  CHECK(queue.pendingSize() == 0u);
}

TEST_CASE("outbound queue window starts with the first enqueue", "[sync]") {
  wb::sync::OutboundQueue queue;
  queue.Enqueue(Op(1), 0);
  queue.Enqueue(Op(2), 60);  // joins the same window, does not reset it
  CHECK_FALSE(queue.Tick(99).has_value());
  const auto action = queue.Tick(100);
  REQUIRE(action.has_value());
  REQUIRE(action->ops.size() == 2u);
}

TEST_CASE("outbound queue resends on the 3s ack timeout then fails", "[sync]") {
  wb::sync::OutboundQueue queue;
  queue.Enqueue(Op(1), 0);
  const auto first = queue.Tick(100);
  REQUIRE(first.has_value());
  REQUIRE(first->attempt == 1);

  CHECK_FALSE(queue.Tick(3099).has_value());  // still inside the 3 s window
  const auto resend1 = queue.Tick(3100);
  REQUIRE(resend1.has_value());
  REQUIRE(resend1->attempt == 2);

  const auto resend2 = queue.Tick(6100);
  REQUIRE(resend2.has_value());
  REQUIRE(resend2->attempt == 3);

  const auto resend3 = queue.Tick(9100);
  REQUIRE(resend3.has_value());
  REQUIRE(resend3->attempt == 4);

  // First send + 3 resends all unanswered: the op moves to the failure list.
  CHECK_FALSE(queue.Tick(12100).has_value());
  CHECK_FALSE(queue.inFlight());
  const auto failed = queue.DrainFailures();
  REQUIRE(failed.size() == 1u);
  REQUIRE(failed[0]["n"] == 1);
  CHECK(queue.DrainFailures().empty());
}

TEST_CASE("outbound queue ack clears the batch and samples rtt", "[sync]") {
  wb::sync::OutboundQueue queue;
  queue.Enqueue(Op(1), 0);
  const auto first = queue.Tick(100);
  REQUIRE(first.has_value());
  const std::int64_t batchId = first->batchId;

  CHECK_FALSE(queue.OnAck(batchId + 99, 250).has_value());  // stale id ignored
  const auto rtt = queue.OnAck(batchId, 250);
  REQUIRE(rtt.has_value());
  REQUIRE(*rtt == 150);  // 250 - 100 (last send)
  CHECK_FALSE(queue.inFlight());

  // A late ack of a finished batch must not confirm a newer one.
  queue.Enqueue(Op(2), 1000);
  const auto second = queue.Tick(1100);
  REQUIRE(second.has_value());
  CHECK_FALSE(queue.OnAck(batchId, 1200).has_value());
  CHECK(queue.inFlight());
  REQUIRE(queue.OnAck(second->batchId, 1200).has_value());
}

TEST_CASE("outbound queue FailAll preserves order into failures", "[sync]") {
  wb::sync::OutboundQueue queue;
  queue.Enqueue(Op(1), 0);
  queue.Enqueue(Op(2), 0);
  const auto action = queue.Tick(100);  // ops 1,2 in flight
  REQUIRE(action.has_value());
  queue.Enqueue(Op(3), 150);  // waits behind the in-flight batch

  queue.FailAll();
  const auto failed = queue.DrainFailures();
  REQUIRE(failed.size() == 3u);
  REQUIRE(failed[0]["n"] == 1);
  REQUIRE(failed[1]["n"] == 2);
  REQUIRE(failed[2]["n"] == 3);
  CHECK_FALSE(queue.inFlight());
  CHECK(queue.pendingSize() == 0u);
}

TEST_CASE("outbound queue requeues an in-flight batch on refusal", "[sync]") {
  wb::sync::OutboundQueue queue;
  queue.Enqueue(Op(1), 0);
  REQUIRE(queue.Tick(100).has_value());
  queue.RequeueInFlight(200);
  CHECK_FALSE(queue.inFlight());
  CHECK(queue.pendingSize() == 1u);

  CHECK_FALSE(queue.Tick(299).has_value());  // window restarts at 200
  const auto again = queue.Tick(300);
  REQUIRE(again.has_value());
  REQUIRE(again->ops.size() == 1u);
  REQUIRE(again->ops[0]["n"] == 1);
}

TEST_CASE("outbound queue honours custom settings", "[sync]") {
  wb::sync::OutboundSettings settings;
  settings.batchWindowMs = 50;
  settings.ackTimeoutMs = 1000;
  settings.maxResends = 0;  // fail after the first unanswered send
  wb::sync::OutboundQueue queue(settings);
  queue.Enqueue(Op(1), 0);
  CHECK_FALSE(queue.Tick(49).has_value());
  REQUIRE(queue.Tick(50).has_value());
  CHECK_FALSE(queue.Tick(1049).has_value());
  CHECK_FALSE(queue.Tick(1050).has_value());  // budget spent -> failure list
  REQUIRE(queue.DrainFailures().size() == 1u);
}

TEST_CASE("preview hysteresis keeps only the freshest frame per kind",
          "[sync]") {
  wb::sync::HysteresisSlots slots;
  slots.Offer("transform", nlohmann::json::object({{"x", 1}}));
  slots.Offer("transform", nlohmann::json::object({{"x", 2}}));
  slots.Offer("ink", nlohmann::json::object({{"p", 1}}));

  const auto drained = slots.TakeAll();
  REQUIRE(drained.size() == 2u);
  CHECK(drained[0].first == "ink");
  CHECK(drained[0].second["p"] == 1);
  CHECK(drained[1].first == "transform");
  CHECK(drained[1].second["x"] == 2);  // the older x=1 frame was replaced
  CHECK(slots.empty());
  CHECK(slots.TakeAll().empty());
}
