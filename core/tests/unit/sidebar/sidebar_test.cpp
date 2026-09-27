// tests/unit/sidebar/sidebar_test.cpp — domain "sidebar" (task package 1.4).
// States are process-wide, so each TEST_CASE uses its own stateId.

#include <string>

#include <catch2/catch_test_macros.hpp>

#include "../support/scene_probe.h"

TEST_CASE("sidebar defaults", "[sidebar]") {
  const std::string response =
      wb::invokeDomain("sidebar", "get", "{\"stateId\":\"sidebar-test-defaults\"}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonString(response, "stateId") == "sidebar-test-defaults");
  REQUIRE(JsonBool(response, "collapsed", false));
  REQUIRE(JsonNumber(response, "width") == 240.0);
  REQUIRE(JsonNumber(response, "effectiveWidth") == 240.0);
}

TEST_CASE("sidebar empty stateId resolves to default state", "[sidebar]") {
  const std::string response = wb::invokeDomain("sidebar", "get", "{}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonString(response, "stateId") == "sidebar-1");
}

TEST_CASE("sidebar toggle flips collapsed and reports strip width", "[sidebar]") {
  const std::string stateId = "sidebar-test-toggle";
  const std::string collapsed = wb::invokeDomain(
      "sidebar", "toggle", "{\"stateId\":\"" + stateId + "\"}");
  REQUIRE(JsonBool(collapsed, "collapsed", true));
  REQUIRE(JsonNumber(collapsed, "width") == 240.0);
  REQUIRE(JsonNumber(collapsed, "effectiveWidth") == 56.0);

  const std::string expanded = wb::invokeDomain(
      "sidebar", "toggle", "{\"stateId\":\"" + stateId + "\"}");
  REQUIRE(JsonBool(expanded, "collapsed", false));
  REQUIRE(JsonNumber(expanded, "effectiveWidth") == 240.0);
}

TEST_CASE("sidebar setWidth clamps to the drag range 200..320", "[sidebar]") {
  const std::string stateId = "sidebar-test-width";
  const std::string wide = wb::invokeDomain(
      "sidebar", "setWidth",
      "{\"stateId\":\"" + stateId + "\",\"width\":300}");
  REQUIRE(JsonNumber(wide, "width") == 300.0);

  const std::string tooSmall = wb::invokeDomain(
      "sidebar", "setWidth",
      "{\"stateId\":\"" + stateId + "\",\"width\":120}");
  REQUIRE(JsonNumber(tooSmall, "width") == 200.0);

  const std::string tooLarge = wb::invokeDomain(
      "sidebar", "setWidth",
      "{\"stateId\":\"" + stateId + "\",\"width\":999}");
  REQUIRE(JsonNumber(tooLarge, "width") == 320.0);
}

TEST_CASE("sidebar states are isolated per stateId and reset restores", "[sidebar]") {
  const std::string responseA = wb::invokeDomain(
      "sidebar", "toggle", "{\"stateId\":\"sidebar-test-a\"}");
  REQUIRE(JsonBool(responseA, "collapsed", true));

  const std::string responseB =
      wb::invokeDomain("sidebar", "get", "{\"stateId\":\"sidebar-test-b\"}");
  REQUIRE(JsonBool(responseB, "collapsed", false));

  wb::invokeDomain("sidebar", "setWidth",
                   "{\"stateId\":\"sidebar-test-b\",\"width\":280}");
  const std::string reset = wb::invokeDomain(
      "sidebar", "reset", "{\"stateId\":\"sidebar-test-b\"}");
  REQUIRE(JsonBool(reset, "collapsed", false));
  REQUIRE(JsonNumber(reset, "width") == 240.0);
}
