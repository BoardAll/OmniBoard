// tests/unit/toolbar/toolbar_test.cpp — domain "toolbar" (task package 1.4).
// Context resolution per 《可扩展工具栏设计》§4: 0 ids -> default,
// 1 id -> toolbar for the element type, >1 -> multiSelect.

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

}  // namespace

TEST_CASE("toolbar list returns the six default items", "[toolbar]") {
  const std::string response = wb::invokeDomain("toolbar", "list", "{}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonContains(response, "\"id\":\"default\""));
  REQUIRE(JsonContains(response, "\"id\":\"canvas.background\""));
  REQUIRE(JsonContains(response, "\"id\":\"canvas.grid\""));
  REQUIRE(JsonContains(response, "\"id\":\"view.zoom\""));
  REQUIRE(JsonContains(response, "\"id\":\"view.navigate\""));
  REQUIRE(JsonContains(response, "\"id\":\"ai.open\""));
  REQUIRE(JsonContains(response, "\"id\":\"more.settings\""));
}

TEST_CASE("toolbar context resolves default for an empty selection", "[toolbar]") {
  const std::string response =
      wb::invokeDomain("toolbar", "context", "{\"elementIds\":[]}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonString(response, "resolved") == "default");
  REQUIRE(JsonNumber(response, "count") == 0.0);
  REQUIRE(JsonContains(response, "canvas.background"));
}

TEST_CASE("toolbar context resolves per element type", "[toolbar]") {
  const Scene scene = NewScene();
  const std::string sticky = SceneCreateElement(
      scene.pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":100}}");
  const std::string shape = SceneCreateElement(
      scene.pageId,
      "{\"type\":\"shape\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":100}}");
  const std::string connector = SceneCreateElement(
      scene.pageId,
      "{\"type\":\"connector\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":100}}");
  REQUIRE(!sticky.empty());
  REQUIRE(!shape.empty());
  REQUIRE(!connector.empty());

  const std::string stickyToolbar = wb::invokeDomain(
      "toolbar", "context", "{\"elementIds\":[\"" + sticky + "\"]}");
  REQUIRE(JsonString(stickyToolbar, "resolved") == "sticky");
  REQUIRE(JsonContains(stickyToolbar, "sticky.color"));
  REQUIRE(JsonContains(stickyToolbar, "\"types\":[\"sticky\"]"));

  const std::string shapeToolbar = wb::invokeDomain(
      "toolbar", "context", "{\"elementIds\":[\"" + shape + "\"]}");
  REQUIRE(JsonString(shapeToolbar, "resolved") == "shape");
  REQUIRE(JsonContains(shapeToolbar, "shape.fill"));

  const std::string connectorToolbar = wb::invokeDomain(
      "toolbar", "context", "{\"elementIds\":[\"" + connector + "\"]}");
  REQUIRE(JsonString(connectorToolbar, "resolved") == "connector");
  REQUIRE(JsonContains(connectorToolbar, "connector.lineStyle"));
}

TEST_CASE("toolbar context resolves multiSelect for several elements",
          "[toolbar]") {
  const Scene scene = NewScene();
  const std::string a = SceneCreateElement(
      scene.pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":10,\"height\":10}}");
  const std::string b = SceneCreateElement(
      scene.pageId,
      "{\"type\":\"shape\",\"position\":{\"x\":20,\"y\":0},"
      "\"size\":{\"width\":10,\"height\":10}}");

  const std::string response = wb::invokeDomain(
      "toolbar", "context",
      "{\"elementIds\":" + JsonIdArray({a, b}) + "}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonString(response, "resolved") == "multiSelect");
  REQUIRE(JsonNumber(response, "count") == 2.0);
  REQUIRE(JsonContains(response, "align.left"));
  REQUIRE(JsonContains(response, "distribute.horizontal"));
  REQUIRE(JsonContains(response, "zorder.front"));
  REQUIRE(JsonContains(response, "delete"));
}

TEST_CASE("toolbar context reports unknown element ids", "[toolbar]") {
  const std::string response = wb::invokeDomain(
      "toolbar", "context", "{\"elementIds\":[\"element-nope\"]}");
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonString(response, "code") == "NotFound");
}

TEST_CASE("toolbar invoke forwards to the tool executor", "[toolbar]") {
  const std::string response = wb::invokeDomain(
      "toolbar", "invoke", "{\"toolId\":\"theme.list\"}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonContains(response, "清爽专业"));
  REQUIRE(JsonNumber(response, "count") == 9.0);
}

TEST_CASE("toolbar invoke validates toolId and forwards unknown domains",
          "[toolbar]") {
  const std::string empty =
      wb::invokeDomain("toolbar", "invoke", "{\"toolId\":\"\"}");
  REQUIRE(JsonBool(empty, "ok", false));
  REQUIRE(JsonString(empty, "code") == "InvalidArgument");

  const std::string unknown =
      wb::invokeDomain("toolbar", "invoke", "{\"toolId\":\"nope.op\"}");
  REQUIRE(JsonBool(unknown, "ok", false));
  REQUIRE(JsonString(unknown, "code") == "NotFound");

  const std::string malformed =
      wb::invokeDomain("toolbar", "invoke", "{\"toolId\":\"nodot\"}");
  REQUIRE(JsonBool(malformed, "ok", false));
  REQUIRE(JsonString(malformed, "code") == "InvalidArgument");
}

TEST_CASE("toolbar invoke forwards args to the target op", "[toolbar]") {
  std::string board;
  SceneNewBoard(&board);
  const std::string pageId = SceneFirstPageId(board);

  const std::string response = wb::invokeDomain(
      "toolbar", "invoke",
      "{\"toolId\":\"background.set\",\"args\":{\"pageId\":\"" + pageId +
          "\",\"preset\":\"grid\"}}");
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonString(response, "preset") == "grid");
}
