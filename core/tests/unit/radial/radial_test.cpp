// tests/unit/radial/radial_test.cpp — domain "radial" (task package 1.4).
// Geometry per 《齿轮圆盘交互详细设计》: centre 0..28, inner ring 28..72 with
// the fixed six tools (60 deg apart, first at the top), outer ring 72..120
// with the eight groups (45 deg apart), sub ring 120..180.

#include <string>

#include <catch2/catch_test_macros.hpp>

#include "../support/scene_probe.h"

namespace {

std::string HitTest(float x, float y) {
  wb::invokeDomain("radial", "layout", "{\"cx\":100,\"cy\":100,\"size\":240}");
  return wb::invokeDomain(
      "radial", "hitTest",
      "{\"layout\":{\"cx\":100,\"cy\":100,\"size\":240},\"x\":" +
          std::to_string(x) + ",\"y\":" + std::to_string(y) + "}");
}

}  // namespace

TEST_CASE("radial layout exposes rings, items and angles", "[radial]") {
  const std::string response = wb::invokeDomain(
      "radial", "layout", "{\"cx\":100,\"cy\":100,\"size\":240}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonNumber(response, "cx") == 100.0);
  REQUIRE(JsonNumber(response, "collapsedSize") == 56.0);
  REQUIRE(JsonNumber(response, "centerRadius") == 28.0);
  REQUIRE(JsonContains(response, "\"stepDeg\":60"));
  REQUIRE(JsonContains(response, "\"stepDeg\":45"));
  // Inner: six fixed tools starting with select at the top (angle -90).
  REQUIRE(JsonContains(response, "\"id\":\"select\""));
  REQUIRE(JsonContains(response, "\"id\":\"sticky\""));
  REQUIRE(JsonContains(response, "\"id\":\"shape\""));
  REQUIRE(JsonContains(response, "\"id\":\"pen\""));
  REQUIRE(JsonContains(response, "\"id\":\"image\""));
  REQUIRE(JsonContains(response, "\"id\":\"more\""));
  REQUIRE(JsonContains(response, "\"angle\":-90"));
  // Outer: eight fixed groups.
  REQUIRE(JsonContains(response, "\"id\":\"select-hand\""));
  REQUIRE(JsonContains(response, "\"id\":\"sticky-text\""));
  REQUIRE(JsonContains(response, "\"id\":\"shape-connector\""));
  REQUIRE(JsonContains(response, "\"id\":\"flowchart-ai\""));
  // Recent strip default and collapsed 0..28 centre.
  REQUIRE(JsonContains(
      response, "\"recent\":[\"select\",\"sticky\",\"shape\"]"));
  REQUIRE(JsonBool(response, "visible", false));  // sub ring hidden by default
}

TEST_CASE("radial hitTest resolves centre and inner tools", "[radial]") {
  const std::string centre = HitTest(100, 100);
  REQUIRE(JsonString(centre, "zone") == "center");
  REQUIRE(JsonString(centre, "action") == "toggle");

  const std::string top = HitTest(100, 60);  // r=40, top -> select
  REQUIRE(JsonBool(top, "hit", true));
  REQUIRE(JsonString(top, "zone") == "inner");
  REQUIRE(JsonString(top, "toolId") == "select");

  const std::string right = HitTest(140, 100);  // r=40 -> sector 2
  REQUIRE(JsonString(right, "toolId") == "shape");

  // 60 deg clockwise from the top: (sin60, -cos60) * 40.
  const std::string sector1 = HitTest(134.6f, 80.0f);
  REQUIRE(JsonString(sector1, "toolId") == "sticky");
}

TEST_CASE("radial hitTest resolves outer groups and tolerance", "[radial]") {
  const std::string outerTop = HitTest(100, 10);  // r=90 -> group 0
  REQUIRE(JsonBool(outerTop, "hit", true));
  REQUIRE(JsonString(outerTop, "zone") == "outer");
  REQUIRE(JsonString(outerTop, "groupId") == "select-hand");

  const std::string outerRight = HitTest(190, 100);  // r=90 -> group 2
  REQUIRE(JsonString(outerRight, "groupId") == "shape-connector");

  const std::string edge = HitTest(100, -25);  // r=125 within 120+8
  REQUIRE(JsonBool(edge, "hit", true));
  REQUIRE(JsonString(edge, "zone") == "outer");

  const std::string miss = HitTest(100, -200);  // r=300 well outside
  REQUIRE(JsonBool(miss, "hit", false));
}

TEST_CASE("radial hitTest scales with the dial size", "[radial]") {
  const std::string response = wb::invokeDomain(
      "radial", "hitTest",
      "{\"layout\":{\"cx\":0,\"cy\":0,\"size\":480},\"x\":0,\"y\":-230}");
  wb::invokeDomain("radial", "layout", "{}");  // keep the log tidy
  REQUIRE(JsonBool(response, "hit", true));
  REQUIRE(JsonString(response, "zone") == "outer");
}

TEST_CASE("radial state create/get/update lifecycle", "[radial]") {
  const std::string created =
      wb::invokeDomain("radial", "stateCreate", "{}");
  REQUIRE(JsonBool(created, "ok", true));
  const std::string stateId = JsonString(created, "id");
  REQUIRE(stateId.rfind("radial-", 0) == 0);
  REQUIRE(JsonBool(created, "collapsed", true));
  REQUIRE(JsonBool(created, "locked", false));
  REQUIRE(JsonString(created, "activeTool") == "select");
  REQUIRE(JsonContains(created, "\"corner\":\"bottom-right\""));

  const std::string fetched = wb::invokeDomain(
      "radial", "stateGet", "{\"stateId\":\"" + stateId + "\"}");
  REQUIRE(JsonString(fetched, "id") == stateId);

  const std::string updated = wb::invokeDomain(
      "radial", "stateUpdate",
      "{\"stateId\":\"" + stateId +
          "\",\"patch\":{\"collapsed\":false,\"activeTool\":\"pen\","
          "\"position\":{\"x\":10,\"y\":20}}}");
  REQUIRE(JsonBool(updated, "collapsed", false));
  REQUIRE(JsonString(updated, "activeTool") == "pen");
  REQUIRE(JsonContains(updated, "\"position\":{\"x\":10"));
  REQUIRE(JsonString(updated, "id") == stateId);  // id is protected

  const std::string unknown =
      wb::invokeDomain("radial", "stateGet", "{\"stateId\":\"radial-nope\"}");
  REQUIRE(JsonBool(unknown, "ok", false));
  REQUIRE(JsonString(unknown, "code") == "NotFound");
}

TEST_CASE("radial recent tools dedupe, cap at three and clear", "[radial]") {
  const std::string created =
      wb::invokeDomain("radial", "stateCreate", "{}");
  const std::string stateId = JsonString(created, "id");
  REQUIRE(JsonContains(created, "\"recent\":[\"select\",\"sticky\",\"shape\"]"));

  const auto remember = [&stateId](const std::string& tool) {
    return wb::invokeDomain(
        "radial", "rememberTool",
        "{\"stateId\":\"" + stateId + "\",\"toolId\":\"" + tool + "\"}");
  };
  REQUIRE(JsonContains(remember("text"), "\"recent\":[\"text\",\"select\",\"sticky\"]"));
  REQUIRE(JsonContains(remember("select"), "\"recent\":[\"select\",\"text\",\"sticky\"]"));
  REQUIRE(JsonContains(remember("image"), "\"recent\":[\"image\",\"select\",\"text\"]"));
  REQUIRE(JsonContains(remember("pen"), "\"recent\":[\"pen\",\"image\",\"select\"]"));

  const std::string cleared = wb::invokeDomain(
      "radial", "clearRecent", "{\"stateId\":\"" + stateId + "\"}");
  REQUIRE(JsonContains(cleared, "\"recent\":[\"select\",\"sticky\",\"shape\"]"));

  const std::string bad = wb::invokeDomain(
      "radial", "rememberTool", "{\"stateId\":\"" + stateId + "\"}");
  REQUIRE(JsonBool(bad, "ok", false));
  REQUIRE(JsonString(bad, "code") == "InvalidArgument");
}
