// tests/unit/render/render_test.cpp — domain "render" (task package 1.4).
// Cache and perf counters are process-wide; the tests use clear+delta
// assertions so they stay order-independent.

#include <string>

#include <catch2/catch_test_macros.hpp>

#include "../support/scene_probe.h"

namespace {

struct Scene {
  std::string board;
  std::string pageId;
};

Scene NewScene() {
  Scene scene;
  SceneNewBoard(&scene.board);
  scene.pageId = SceneFirstPageId(scene.board);
  return scene;
}

std::string MakeSticky(const Scene& scene, float x, float y, bool hidden) {
  return SceneCreateElement(
      scene.pageId,
      std::string("{\"type\":\"sticky\",\"hidden\":") + (hidden ? "true" : "false") +
          ",\"position\":{\"x\":" + std::to_string(x) + ",\"y\":" +
          std::to_string(y) +
          "},\"size\":{\"width\":100,\"height\":50}}");
}

}  // namespace

TEST_CASE("render getDisplayList returns z-ordered items with layers",
          "[render]") {
  const Scene scene = NewScene();
  const std::string sticky = MakeSticky(scene, 10, 10, false);
  const std::string solid = SceneCreateElement(
      scene.pageId,
      "{\"type\":\"render3d\",\"position\":{\"x\":200,\"y\":100},"
      "\"size\":{\"width\":50,\"height\":50}}");
  const std::string hidden = MakeSticky(scene, 500, 500, true);
  REQUIRE(!sticky.empty());
  REQUIRE(!solid.empty());
  REQUIRE(!hidden.empty());

  const std::string response = wb::invokeDomain(
      "render", "getDisplayList", "{\"pageId\":\"" + scene.pageId + "\"}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonNumber(response, "count") == 2.0);  // hidden element skipped
  REQUIRE(JsonContains(response, "\"layer\":\"Dynamic\""));
  REQUIRE(JsonContains(response, "\"layer\":\"Render3D\""));
  REQUIRE(!JsonContains(response, hidden));
  REQUIRE(JsonBool(response, "pageHidden", false));

  // Dirty rect unions the two visible rotation-aware AABBs.
  const std::size_t dirty = response.find("\"dirtyRect\"");
  REQUIRE(dirty != std::string::npos);
  REQUIRE(JsonNumberAt(response, "width", dirty) == 240.0);
  REQUIRE(JsonNumberAt(response, "height", dirty) == 140.0);
  REQUIRE(JsonNumberAt(response, "x", dirty) == 10.0);
}

TEST_CASE("render getDisplayList filters by layer name", "[render]") {
  const Scene scene = NewScene();
  MakeSticky(scene, 0, 0, false);
  SceneCreateElement(scene.pageId,
                     "{\"type\":\"render3d\",\"position\":{\"x\":0,\"y\":0},"
                     "\"size\":{\"width\":10,\"height\":10}}");

  const std::string solidOnly = wb::invokeDomain(
      "render", "getDisplayList",
      "{\"pageId\":\"" + scene.pageId + "\",\"layer\":\"render3d\"}");
  REQUIRE(JsonNumber(solidOnly, "count") == 1.0);
  REQUIRE(JsonContains(solidOnly, "\"layer\":\"render3d\""));

  const std::string empty = wb::invokeDomain(
      "render", "getDisplayList",
      "{\"pageId\":\"" + scene.pageId + "\",\"layer\":\"Document\"}");
  REQUIRE(JsonNumber(empty, "count") == 0.0);
  REQUIRE(JsonContains(empty, "\"dirtyRect\":null"));
}

TEST_CASE("render getDisplayList reports unknown pages", "[render]") {
  const std::string response = wb::invokeDomain(
      "render", "getDisplayList", "{\"pageId\":\"page-nope\"}");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonString(response, "code") == "NotFound");
}

TEST_CASE("render thumbnail defaults and caching", "[render]") {
  const Scene scene = NewScene();
  MakeSticky(scene, 0, 0, false);
  SceneCreateElement(scene.pageId,
                     "{\"type\":\"render3d\",\"position\":{\"x\":0,\"y\":0},"
                     "\"size\":{\"width\":10,\"height\":10}}");
  SceneCreateElement(scene.pageId,
                     "{\"type\":\"function\",\"position\":{\"x\":0,\"y\":0},"
                     "\"size\":{\"width\":10,\"height\":10}}");

  wb::invokeDomain("render", "cacheClear", "{}");
  const std::string statsBefore =
      wb::invokeDomain("render", "cacheStats", "{}");
  const double missesBefore = JsonNumber(statsBefore, "misses");
  const double hitsBefore = JsonNumber(statsBefore, "hits");

  const std::string first = wb::invokeDomain(
      "render", "thumbnail", "{\"pageId\":\"" + scene.pageId + "\"}");
  REQUIRE(JsonBool(first, "ok", true));
  REQUIRE(JsonNumber(first, "width") == 200.0);
  REQUIRE(JsonNumber(first, "height") == 125.0);
  REQUIRE(JsonNumber(first, "bytes") == 100000.0);
  REQUIRE(JsonNumber(first, "elementCount") == 3.0);
  REQUIRE(JsonString(first, "cacheKey") ==
          "thumb:" + scene.pageId + ":200x125");
  REQUIRE(JsonString(first, "format") == "rgba");

  // Same key again: a cache hit.
  wb::invokeDomain("render", "thumbnail",
                   "{\"pageId\":\"" + scene.pageId + "\"}");

  const std::string statsAfter =
      wb::invokeDomain("render", "cacheStats", "{}");
  REQUIRE(JsonNumber(statsAfter, "entries") == 1.0);
  REQUIRE(JsonNumber(statsAfter, "maxEntries") == 256.0);
  REQUIRE(JsonNumber(statsAfter, "misses") == missesBefore + 1.0);
  REQUIRE(JsonNumber(statsAfter, "hits") == hitsBefore + 1.0);
  REQUIRE(JsonNumber(statsAfter, "bytes") == 100000.0);

  const std::string cleared =
      wb::invokeDomain("render", "cacheClear", "{}");
  REQUIRE(JsonNumber(cleared, "cleared") == 1.0);
  REQUIRE(JsonNumber(cleared, "bytes") == 100000.0);

  const std::string statsEmpty =
      wb::invokeDomain("render", "cacheStats", "{}");
  REQUIRE(JsonNumber(statsEmpty, "entries") == 0.0);
}

TEST_CASE("render thumbnail rejects unknown pages", "[render]") {
  const std::string response = wb::invokeDomain(
      "render", "thumbnail", "{\"pageId\":\"page-nope\"}");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonString(response, "code") == "NotFound");
}

TEST_CASE("render perf stats accumulate recorded frames", "[render]") {
  const std::string before = wb::invokeDomain("render", "perfStats", "{}");
  const double framesBefore = JsonNumber(before, "frames");
  const double callsBefore = JsonNumber(before, "drawCalls");

  wb::invokeDomain("render", "recordFrame",
                   "{\"frameMs\":10,\"drawCalls\":5}");
  const std::string recorded =
      wb::invokeDomain("render", "recordFrame",
                       "{\"frameMs\":20,\"drawCalls\":10}");
  REQUIRE(JsonNumber(recorded, "frames") == framesBefore + 2.0);
  REQUIRE(JsonNumber(recorded, "lastFrameMs") == 20.0);
  REQUIRE(JsonNumber(recorded, "drawCalls") == callsBefore + 15.0);

  bool ok = false;
  const double fps = JsonNumber(recorded, "fps", &ok);
  REQUIRE(ok);
  REQUIRE(fps > 0.0);
}
