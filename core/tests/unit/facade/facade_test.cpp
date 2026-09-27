// tests/unit/facade/facade_test.cpp — C++ facade layer (task package 1.2).
// Tags: [facade]
//
// The facade header lives in the module directory (core/src/facade); the
// test includes it relatively, the same way internal C++ callers do.

#include <catch2/catch_test_macros.hpp>

#include <string>

#include "../../../src/facade/facade.h"

TEST_CASE("facade isOk parses response JSON", "[facade]") {
  REQUIRE(wb::facade::isOk("{\"ok\":true,\"result\":{}}"));
  REQUIRE_FALSE(wb::facade::isOk("{\"ok\":false,\"error\":{}}"));
  REQUIRE_FALSE(wb::facade::isOk("not json"));
  REQUIRE_FALSE(wb::facade::isOk(""));
}

TEST_CASE("facade call forwards and never throws", "[facade]") {
  const std::string unknown = wb::facade::call("no_such_domain_zz", "op");
  REQUIRE(unknown.find("\"ok\":false") != std::string::npos);

  // Unknown tool forward stays an error response.
  const std::string tool = wb::facade::executeTool("nope.never");
  REQUIRE_FALSE(wb::facade::isOk(tool));

  // Default arguments produce valid calls.
  const std::string pageList = wb::facade::pageList("no-such-board-zz");
  REQUIRE(pageList.find("\"ok\"") != std::string::npos);
}
