// tests/unit/ffi/ffi_api_test.cpp — C ABI export surface (task package 1.1).
// Tags: [ffi]
//
// Only wave-stable assertions live here: lifecycle + error-path behavior that
// stays valid no matter which domain implementations have landed. Domain
// happy-paths are covered by the owning module's tests.

#include <catch2/catch_test_macros.hpp>

#include <cstring>
#include <string>

#include "wb/wb.h"

namespace {

bool Contains(const std::string& haystack, const std::string& needle) {
  return haystack.find(needle) != std::string::npos;
}

std::string TakeAndFree(const char* owned) {
  REQUIRE(owned != nullptr);
  std::string copy(owned);
  wb_free(owned);
  return copy;
}

}  // namespace

TEST_CASE("wb_version returns the engine version and is freeable", "[ffi]") {
  const std::string version = TakeAndFree(wb_version());
  REQUIRE(version == "1.0.0");
}

TEST_CASE("wb_init accepts valid config and rejects malformed JSON", "[ffi]") {
  REQUIRE(wb_init(nullptr) == 0);
  REQUIRE(wb_init("{}") == 0);
  REQUIRE(wb_init("{\"logLevel\":\"error\"}") == 0);
  REQUIRE(wb_init("{\"logLevel\":\"info\"}") == 0);  // restore shared state
  REQUIRE(wb_init("{definitely not json") == 1);
  wb_shutdown();
}

TEST_CASE("wb_free is safe on null", "[ffi]") {
  wb_free(nullptr);
  REQUIRE(true);
}

TEST_CASE("unknown-domain calls return error JSON instead of crashing", "[ffi]") {
  // No page is ever registered under this id, so every wave must reply
  // {"ok":false,...} rather than throwing or crashing.
  const std::string pageList = TakeAndFree(wb_page_list("no-such-board-ever"));
  REQUIRE(Contains(pageList, "\"ok\":false"));

  const std::string unknownTool = TakeAndFree(wb_execute_tool("nope.never", "{}"));
  REQUIRE(Contains(unknownTool, "\"ok\":false"));

  const std::string unknownToolGet = TakeAndFree(wb_tool_get("nope.never"));
  REQUIRE(Contains(unknownToolGet, "\"ok\":false"));
}

TEST_CASE("malformed args JSON does not crash forwarding", "[ffi]") {
  const std::string response =
      TakeAndFree(wb_execute_command(0, "{broken json"));
  REQUIRE_FALSE(response.empty());
  REQUIRE(Contains(response, "\"ok\""));
}
