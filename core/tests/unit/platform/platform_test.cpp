// tests/unit/platform/platform_test.cpp — host abstraction (task package 1.1).
// Tags: [platform]

#include <catch2/catch_test_macros.hpp>

#include <filesystem>
#include <string>

#include "wb/platform/platform.h"

TEST_CASE("clock and thread count are sane", "[platform]") {
  const std::int64_t millis = wb::timeMillis();
  const std::int64_t micros = wb::timeMicros();
  REQUIRE(millis > 0);
  REQUIRE(micros > 0);
  // The two clocks agree within a generous window (5 seconds).
  const std::int64_t delta = micros / 1000 - millis;
  REQUIRE(delta >= -5000);
  REQUIRE(delta <= 5000);
  REQUIRE(wb::threadCount() >= 1);
}

TEST_CASE("platform identification is consistent", "[platform]") {
  const int osCount = (wb::isWindows() ? 1 : 0) + (wb::isMacOS() ? 1 : 0) +
                      (wb::isLinux() ? 1 : 0);
#if defined(_WIN32)
  REQUIRE(wb::isWindows());
  REQUIRE(osCount == 1);
#else
  REQUIRE(osCount >= 1);
#endif
}

TEST_CASE("directories and executable path resolve", "[platform]") {
  REQUIRE_FALSE(wb::executablePath().empty());
  if (wb::isWindows()) {
    REQUIRE_FALSE(wb::configDir().empty());
    REQUIRE_FALSE(wb::dataDir().empty());
  }
}

TEST_CASE("ensureDir creates directories", "[platform]") {
  const std::filesystem::path target =
      std::filesystem::temp_directory_path() / "wb_platform_test" / "nested";
  std::error_code ec;
  std::filesystem::remove_all(target, ec);  // clean slate
  REQUIRE(wb::ensureDir(target.string()));
  REQUIRE(std::filesystem::is_directory(target));
  REQUIRE(wb::ensureDir(target.string()));  // idempotent
  REQUIRE_FALSE(wb::ensureDir(""));
  std::filesystem::remove_all(target, ec);
}
