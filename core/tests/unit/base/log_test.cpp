// tests/unit/base/log_test.cpp — Logger facade (task package 1.1).
// Tags: [base]

#include <catch2/catch_test_macros.hpp>

#include <string>
#include <vector>

#include "wb/base/log.h"

namespace {

std::vector<std::string> g_records;

void CaptureSink(wb::LogLevel /*level*/, const char* tag, const char* msg) {
  g_records.emplace_back(std::string(tag != nullptr ? tag : "") + "|" +
                         (msg != nullptr ? msg : ""));
}

struct SinkGuard {
  SinkGuard() {
    g_records.clear();
    wb::Logger::instance().setSink(&CaptureSink);
  }
  ~SinkGuard() {
    wb::Logger::instance().setSink(nullptr);
    wb::Logger::instance().setLevel(wb::LogLevel::Info);
  }
};

}  // namespace

TEST_CASE("Logger filters by level and forwards to sink", "[base]") {
  SinkGuard guard;
  wb::Logger& logger = wb::Logger::instance();

  logger.setLevel(wb::LogLevel::Debug);
  REQUIRE(logger.level() == wb::LogLevel::Debug);

  logger.debug("t", "debug-msg");
  logger.info("t", "info-msg");
  logger.error("t", "error-msg");
  REQUIRE(g_records.size() == 3);
  REQUIRE(g_records[0] == "t|debug-msg");
  REQUIRE(g_records[2] == "t|error-msg");

  // Below the configured level is dropped.
  logger.setLevel(wb::LogLevel::Error);
  const std::size_t before = g_records.size();
  logger.warn("t", "warn-msg");
  logger.info("t", "info-msg");
  REQUIRE(g_records.size() == before);
  logger.error("t", "kept");
  REQUIRE(g_records.size() == before + 1);

  // Convenience methods delegate correctly.
  const std::size_t mark = g_records.size();
  logger.trace("t", "trace-msg");
  REQUIRE(g_records.size() == mark);  // trace < error
}
