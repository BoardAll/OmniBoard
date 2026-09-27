// tests/unit/geometry/geometry_test.cpp — domain "geometry" (task package 1.3).

#include <catch2/catch_test_macros.hpp>

#include <string>

#include "wb/ffi/domain.h"

#include "../support/scene_probe.h"

namespace {

std::string HitTest(const std::string& pageId, const std::string& tail) {
  return wb::invokeDomain("geometry", "hitTest",
                          "{\"pageId\":\"" + pageId + "\"," + tail + "}");
}

std::string Bounds(const std::string& pageId, const std::string& tail) {
  std::string args = "{\"pageId\":\"" + pageId + "\"";
  if (!tail.empty()) args += "," + tail;
  args += "}";
  return wb::invokeDomain("geometry", "bounds", args);
}

}  // namespace

TEST_CASE("hitTest finds shapes and reports local coordinates", "[geometry]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);
  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  REQUIRE(!a.empty());

  std::string response = HitTest(pageId, "\"x\":50,\"y\":25");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonBool(response, "hit", true));
  REQUIRE(JsonString(response, "elementId") == a);
  REQUIRE(JsonContains(response, "\"type\":\"sticky\""));
  REQUIRE(JsonNumber(response, "localX") == 50.0);
  REQUIRE(JsonNumber(response, "localY") == 25.0);

  response = HitTest(pageId, "\"x\":150,\"y\":25");
  REQUIRE(JsonBool(response, "hit", false));
  REQUIRE(JsonContains(response, "\"pageId\":\"" + pageId + "\""));
}

TEST_CASE("hitTest honours the tolerance argument", "[geometry]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);
  SceneCreateElement(pageId,
                     "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
                     "\"size\":{\"width\":100,\"height\":50}}");

  // 5px outside the rect: a miss by default, a hit with tolerance 10.
  REQUIRE(JsonBool(HitTest(pageId, "\"x\":105,\"y\":25"), "hit", false));
  const std::string response = HitTest(pageId, "\"x\":105,\"y\":25,\"tolerance\":10");
  REQUIRE(JsonBool(response, "hit", true));
  REQUIRE(JsonNumber(response, "localX") == 105.0);
}

TEST_CASE("hitTest prefers the topmost element and skips hidden ones",
          "[geometry]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);
  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  const std::string b = SceneCreateElement(
      pageId,
      "{\"type\":\"text\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  REQUIRE(!a.empty());
  REQUIRE(!b.empty());

  REQUIRE(JsonString(HitTest(pageId, "\"x\":50,\"y\":25"), "elementId") == b);

  // Hiding the top element falls through to the one below.
  const std::string hide =
      wb::invokeDomain("element", "update",
                       "{\"elementId\":\"" + b + "\",\"patch\":{\"hidden\":true}}");
  REQUIRE(JsonBool(hide, "ok", true));
  REQUIRE(JsonString(HitTest(pageId, "\"x\":50,\"y\":25"), "elementId") == a);
}

TEST_CASE("hitTest picks connectors within 6px of the line", "[geometry]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);
  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  const std::string b = SceneCreateElement(
      pageId,
      "{\"type\":\"text\",\"position\":{\"x\":200,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  const std::string connector = SceneCreateElement(
      pageId, "{\"type\":\"connector\",\"data\":{\"fromElementId\":\"" + a +
                  "\",\"toElementId\":\"" + b + "\",\"style\":\"straight\"}}");
  REQUIRE(!connector.empty());

  // Centres are (50,25) and (250,25): 3px off the line is a hit...
  std::string response = HitTest(pageId, "\"x\":150,\"y\":28");
  REQUIRE(JsonBool(response, "hit", true));
  REQUIRE(JsonString(response, "elementId") == connector);
  REQUIRE(JsonContains(response, "\"type\":\"connector\""));
  REQUIRE(JsonNumber(response, "distance") == 3.0);
  REQUIRE(JsonNumber(response, "segmentIndex") == 0.0);

  // ...15px is not.
  response = HitTest(pageId, "\"x\":150,\"y\":40");
  REQUIRE(JsonBool(response, "hit", false));
}

TEST_CASE("hitTest inverse-rotates probes around the element centre",
          "[geometry]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);
  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"shape\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50},\"rotation\":90}");
  REQUIRE(!a.empty());

  // Rotated 90 degrees, the probe (55,5) lands at local (30,20).
  std::string response = HitTest(pageId, "\"x\":55,\"y\":5");
  REQUIRE(JsonBool(response, "hit", true));
  REQUIRE(JsonNumber(response, "localX") == 30.0);
  REQUIRE(JsonNumber(response, "localY") == 20.0);

  // (110,25) maps to local (50,-35): outside.
  REQUIRE(JsonBool(HitTest(pageId, "\"x\":110,\"y\":25"), "hit", false));
}

TEST_CASE("bounds unions rotation-aware AABBs", "[geometry]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);
  const std::string a = SceneCreateElement(
      pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  const std::string b = SceneCreateElement(
      pageId,
      "{\"type\":\"text\",\"position\":{\"x\":200,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":50}}");
  REQUIRE(!a.empty());
  REQUIRE(!b.empty());

  std::string response = Bounds(pageId, "");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonNumber(response, "count") == 2.0);
  REQUIRE(JsonNumber(response, "x") == 0.0);
  REQUIRE(JsonNumber(response, "y") == 0.0);
  REQUIRE(JsonNumber(response, "width") == 300.0);
  REQUIRE(JsonNumber(response, "height") == 50.0);

  response = Bounds(pageId, "\"elementIds\":" + JsonIdArray({b}));
  REQUIRE(JsonNumber(response, "count") == 1.0);
  REQUIRE(JsonNumber(response, "x") == 200.0);
  REQUIRE(JsonNumber(response, "width") == 100.0);

  response = Bounds(pageId, "\"elementIds\":[]");
  REQUIRE(JsonNumber(response, "count") == 0.0);
  REQUIRE(JsonNumber(response, "width") == 0.0);

  response = Bounds(pageId, "\"elementIds\":[\"element-nope\"]");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonContains(response, "\"code\":\"NotFound\""));
}

TEST_CASE("geometry ops report NotFound for unknown pages", "[geometry]") {
  REQUIRE(JsonBool(HitTest("page-nope", "\"x\":0,\"y\":0"), "ok", false));
  REQUIRE(JsonBool(Bounds("page-nope", ""), "ok", false));
}
