// tests/unit/render2d/render2d_test.cpp — domain "render2d" (1.4).

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

std::string Create2d(const Scene& scene, const std::string& body) {
  const std::string response = wb::invokeDomain(
      "render2d", "create",
      "{\"pageId\":\"" + scene.pageId + "\",\"element\":" + body + "}");
  return JsonBool(response, "ok", true) ? JsonString(response, "elementId")
                                        : std::string();
}

}  // namespace

TEST_CASE("render2d create forces the render2d type and z-order insert",
          "[render2d]") {
  const Scene scene = NewScene();
  const std::string first = Create2d(
      scene, "{\"position\":{\"x\":0,\"y\":0},\"size\":{\"width\":100,\"height\":100}}");
  REQUIRE(!first.empty());
  const std::string second = Create2d(
      scene,
      "{\"position\":{\"x\":10,\"y\":10},\"size\":{\"width\":50,\"height\":50},"
      "\"zIndex\":0,\"type\":\"table\"}");
  REQUIRE(!second.empty());

  const std::string response = wb::invokeDomain(
      "render2d", "create",
      "{\"pageId\":\"" + scene.pageId +
          "\",\"element\":{\"position\":{\"x\":0,\"y\":0},"
          "\"size\":{\"width\":10,\"height\":10}}}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonString(response, "type") == "render2d");
  REQUIRE(JsonString(response, "elementId").rfind("element-", 0) == 0);

  // zIndex 0 element was inserted at the bottom of the z-order.
  const std::string list = wb::invokeDomain(
      "render2d", "list", "{\"pageId\":\"" + scene.pageId + "\"}");
  REQUIRE(JsonNumber(list, "count") == 3.0);
  REQUIRE(JsonString(list, "id") == second);
}

TEST_CASE("render2d setStyle merges style keys and guards the element type",
          "[render2d]") {
  const Scene scene = NewScene();
  const std::string drawing = Create2d(
      scene, "{\"position\":{\"x\":0,\"y\":0},\"size\":{\"width\":100,\"height\":100}}");
  REQUIRE(!drawing.empty());

  const std::string styled = wb::invokeDomain(
      "render2d", "setStyle",
      "{\"elementId\":\"" + drawing +
          "\",\"style\":{\"stroke\":\"#000000\",\"width\":2}}");
  REQUIRE(JsonBool(styled, "ok", true));
  REQUIRE(JsonContains(styled, "\"stroke\":\"#000000\""));

  const std::string second = wb::invokeDomain(
      "render2d", "setStyle",
      "{\"elementId\":\"" + drawing + "\",\"style\":{\"fill\":\"#FF0000\"}}");
  REQUIRE(JsonContains(second, "\"stroke\":\"#000000\""));
  REQUIRE(JsonContains(second, "\"fill\":\"#FF0000\""));

  // The element domain sees the merged style block.
  const std::string elements = wb::invokeDomain(
      "element", "list", "{\"pageId\":\"" + scene.pageId + "\"}");
  REQUIRE(JsonContains(elements, "\"stroke\":\"#000000\""));
  REQUIRE(JsonContains(elements, "\"fill\":\"#FF0000\""));

  // A non-2D element is refused, as is a missing one.
  const std::string sticky = SceneCreateElement(
      scene.pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":10,\"height\":10}}");
  const std::string wrongType = wb::invokeDomain(
      "render2d", "setStyle",
      "{\"elementId\":\"" + sticky + "\",\"style\":{\"stroke\":\"#000000\"}}");
  REQUIRE(JsonBool(wrongType, "ok", false));
  REQUIRE(JsonString(wrongType, "code") == "InvalidArgument");

  const std::string missing = wb::invokeDomain(
      "render2d", "setStyle",
      "{\"elementId\":\"element-nope\",\"style\":{\"stroke\":\"#000000\"}}");
  REQUIRE(JsonBool(missing, "ok", false));
  REQUIRE(JsonString(missing, "code") == "NotFound");

  const std::string noStyle = wb::invokeDomain(
      "render2d", "setStyle", "{\"elementId\":\"" + drawing + "\"}");
  REQUIRE(JsonBool(noStyle, "ok", false));
  REQUIRE(JsonString(noStyle, "code") == "InvalidArgument");
}

TEST_CASE("render2d annotate appends to data.annotations", "[render2d]") {
  const Scene scene = NewScene();
  const std::string drawing = Create2d(
      scene, "{\"position\":{\"x\":0,\"y\":0},\"size\":{\"width\":100,\"height\":100}}");

  const std::string one = wb::invokeDomain(
      "render2d", "annotate",
      "{\"elementId\":\"" + drawing +
          "\",\"annotation\":{\"kind\":\"ink\",\"text\":\"a\"}}");
  REQUIRE(JsonBool(one, "ok", true));
  REQUIRE(JsonNumber(one, "annotationCount") == 1.0);

  const std::string two = wb::invokeDomain(
      "render2d", "annotate",
      "{\"elementId\":\"" + drawing +
          "\",\"annotation\":{\"kind\":\"note\",\"text\":\"b\"}}");
  REQUIRE(JsonNumber(two, "annotationCount") == 2.0);
  REQUIRE(JsonContains(two, "\"kind\":\"ink\""));

  const std::string list = wb::invokeDomain(
      "render2d", "list", "{\"pageId\":\"" + scene.pageId + "\"}");
  REQUIRE(JsonContains(list, "\"annotationCount\":2"));

  const std::string missing = wb::invokeDomain(
      "render2d", "annotate", "{\"elementId\":\"" + drawing + "\"}");
  REQUIRE(JsonBool(missing, "ok", false));
  REQUIRE(JsonString(missing, "code") == "InvalidArgument");
}

TEST_CASE("render2d create and annotate refuse locked pages", "[render2d]") {
  const Scene scene = NewScene();
  const std::string drawing = Create2d(
      scene, "{\"position\":{\"x\":0,\"y\":0},\"size\":{\"width\":10,\"height\":10}}");
  wb::invokeDomain("page", "lock",
                   "{\"pageId\":\"" + scene.pageId + "\",\"locked\":true}");

  const std::string created = wb::invokeDomain(
      "render2d", "create",
      "{\"pageId\":\"" + scene.pageId +
          "\",\"element\":{\"position\":{\"x\":0,\"y\":0},"
          "\"size\":{\"width\":10,\"height\":10}}}");
  REQUIRE(JsonBool(created, "ok", false));
  REQUIRE(JsonString(created, "code") == "Conflict");

  const std::string annotated = wb::invokeDomain(
      "render2d", "annotate",
      "{\"elementId\":\"" + drawing + "\",\"annotation\":{\"text\":\"a\"}}");
  REQUIRE(JsonBool(annotated, "ok", false));
  REQUIRE(JsonString(annotated, "code") == "Conflict");
}

TEST_CASE("render2d list filters by type and reports unknown pages",
          "[render2d]") {
  const Scene scene = NewScene();
  Create2d(scene, "{\"position\":{\"x\":0,\"y\":0},\"size\":{\"width\":10,\"height\":10}}");
  SceneCreateElement(scene.pageId,
                     "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
                     "\"size\":{\"width\":10,\"height\":10}}");

  const std::string list = wb::invokeDomain(
      "render2d", "list", "{\"pageId\":\"" + scene.pageId + "\"}");
  REQUIRE(JsonNumber(list, "count") == 1.0);
  REQUIRE(JsonContains(list, "\"type\":\"render2d\""));

  const std::string bad = wb::invokeDomain(
      "render2d", "list", "{\"pageId\":\"page-nope\"}");
  REQUIRE(JsonBool(bad, "ok", false));
  REQUIRE(JsonString(bad, "code") == "NotFound");
}
